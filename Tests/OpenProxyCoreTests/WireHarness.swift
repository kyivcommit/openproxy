import Foundation
import Testing
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import X509

@testable import OpenProxyCore

/// A real TLS HTTP/1.1 upstream on loopback that records the request the proxy
/// actually put on the wire (method, target, headers, body).
final class RecordingUpstream: @unchecked Sendable {
    struct Received: Sendable {
        var method: String
        var uri: String
        var headers: [(String, String)]
        var body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.0.lowercased() == name.lowercased() }?.1
        }
    }

    private let lock = NSLock()
    private var _received: [Received] = []
    private let group: EventLoopGroup
    private var channel: Channel?
    private let sslContext: NIOSSLContext
    private let replyStatus: Int
    private let replyHeaders: [(String, String)]
    private let replyBody: Data
    let caCertificate: Certificate
    private(set) var port = 0

    init(
        ca: CertAuthority,
        status: Int = 200,
        headers: [(String, String)] = [("content-type", "application/json")],
        body: Data = Data(#"{"ok":true}"#.utf8)
    ) throws {
        let leaf = try ca.leaf()
        let certificate = try NIOSSLCertificate(bytes: Array(leaf.certificatePEM.utf8), format: .pem)
        let key = try NIOSSLPrivateKey(bytes: Array(leaf.privateKeyPEM.utf8), format: .pem)
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)], privateKey: .privateKey(key))
        tls.applicationProtocols = ["http/1.1"]
        self.sslContext = try NIOSSLContext(configuration: tls)
        self.caCertificate = try Certificate(pemEncoded: String(contentsOf: ca.caCertificatePEMURL))
        self.replyStatus = status
        self.replyHeaders = headers
        self.replyBody = body
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func start() async throws {
        let sslContext = self.sslContext
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(RecordingHandler(owner: self))
                }
            }
        let bound = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        self.channel = bound
        self.port = bound.localAddress?.port ?? 0
    }

    func stop() async {
        let bound = channel
        channel = nil
        if let bound { try? await bound.close().get() }
        try? await group.shutdownGracefully()
    }

    var received: [Received] { lock.withLock { _received } }

    fileprivate func record(_ r: Received) { lock.withLock { _received.append(r) } }
    fileprivate var reply: (Int, [(String, String)], Data) { (replyStatus, replyHeaders, replyBody) }
}

private final class RecordingHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart

    private let owner: RecordingUpstream
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(owner: RecordingUpstream) { self.owner = owner }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let incoming):
            self.head = incoming
            self.body.clear()
        case .body(var buffer):
            self.body.writeBuffer(&buffer)
        case .end:
            guard let head else { return }
            owner.record(RecordingUpstream.Received(
                method: head.method.rawValue, uri: head.uri,
                headers: head.headers.map { ($0.name, $0.value) },
                body: Data(body.readableBytesView)))
            let (status, headers, bodyData) = owner.reply
            var responseHeaders = HTTPHeaders()
            for (name, value) in headers { responseHeaders.add(name: name, value: value) }
            responseHeaders.add(name: "Content-Length", value: String(bodyData.count))
            context.write(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(
                version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: responseHeaders))),
                promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
            buffer.writeBytes(bodyData)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
        }
    }
}

struct NoopEndpointsFetcher: EndpointsFetcher {
    func fetch(modelId: String, authorization: String?) async throws -> Data { Data() }
}

/// ProxyServer wired to the real `NIOUpstreamClient` and a loopback TLS upstream,
/// so tests can assert what actually reached the wire.
struct WireHarness: @unchecked Sendable {
    let server: ProxyServer
    let upstream: RecordingUpstream
    let fetcher: NoopEndpointsFetcher
    let stats: StatsStore
    let session: URLSession
    let port: Int
    let directory: URL

    func request(
        _ method: String, _ path: String, body: Data = Data(), headers: [String: String] = [:]
    ) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }
}

func withWireServer(
    settings: Settings = Settings(),
    _ body: (WireHarness) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "openproxy-wire-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ca = CertAuthority(directory: directory)
    try ca.loadOrCreate()
    let caPEM = try String(contentsOf: ca.caCertificatePEMURL)

    let upstream = try RecordingUpstream(ca: ca)
    try await upstream.start()
    let stats = try StatsStore(path: ":memory:")
    let server = ProxyServer(
        config: ProxyConfig(bindHost: "127.0.0.1", port: 0),
        ca: ca,
        upstream: NIOUpstreamClient(
            resolver: StaticResolver(addresses: ["127.0.0.1"]),
            host: "openrouter.ai",
            port: upstream.port,
            trustRoots: [upstream.caCertificate],
            allowLoopback: true),
        catalog: EndpointCatalog(fetcher: NoopEndpointsFetcher()),
        stats: stats,
        settings: { settings })
    try await server.start()

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 10
    let session = URLSession(configuration: configuration, delegate: TrustDelegate(caPEM: caPEM), delegateQueue: nil)
    let harness = WireHarness(
        server: server, upstream: upstream, fetcher: NoopEndpointsFetcher(), stats: stats,
        session: session, port: server.boundPort, directory: directory)
    do {
        try await body(harness)
    } catch {
        session.invalidateAndCancel()
        await server.stop()
        await upstream.stop()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
    session.invalidateAndCancel()
    await server.stop()
    await upstream.stop()
    try? FileManager.default.removeItem(at: directory)
}
