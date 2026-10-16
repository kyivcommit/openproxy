import Darwin
import Foundation
import X509
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

/// A request as it should reach the real OpenRouter: method, target path, all
/// client headers unchanged, and the (possibly rewritten) body.
public struct UpstreamRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [(String, String)]
    public var body: Data

    public init(method: String, path: String, headers: [(String, String)], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

/// The upstream response head plus a stream of body chunks. Only the head is
/// available up front, so the Flex policy can still abandon a capacity failure
/// before the first body byte.
public final class UpstreamResponse: FlexResponse, @unchecked Sendable {
    public let status: Int
    public let headers: [(String, String)]
    public let body: AsyncThrowingStream<Data, Error>
    private let onCancel: @Sendable () -> Void

    public init(
        status: Int,
        headers: [(String, String)],
        body: AsyncThrowingStream<Data, Error>,
        onCancel: @Sendable @escaping () -> Void = {}
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.onCancel = onCancel
    }

    public func cancel() { onCancel() }
}

public protocol UpstreamClient: Sendable {
    func send(_ request: UpstreamRequest) async throws -> UpstreamResponse
}

public protocol HostResolver: Sendable {
    func resolve(_ host: String) async throws -> [String]
}

public enum UpstreamError: Error, Equatable, Sendable {
    case noAddress(String)
    case forbiddenAddress(String)
}

/// Resolves via Cloudflare's DNS-over-HTTPS JSON API, so `/etc/hosts` (which
/// points `openrouter.ai` at the proxy) cannot feed us our own address, and
/// keeps the last known good answer for offline/DoS fallbacks.
public final class DoHResolver: HostResolver, @unchecked Sendable {
    private let endpoint: URL
    private let session: URLSession
    private let lock = NSLock()
    private var cache: [String: [String]] = [:]

    public init(endpoint: URL = URL(string: "https://cloudflare-dns.com/dns-query")!) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: configuration)
    }

    public func resolve(_ host: String) async throws -> [String] {
        if let addresses = try? await query(host), !addresses.isEmpty {
            lock.withLock { cache[host] = addresses }
            return addresses
        }
        if let cached = lock.withLock({ cache[host] }), !cached.isEmpty {
            return cached
        }
        throw UpstreamError.noAddress(host)
    }

    private func query(_ host: String) async throws -> [String] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "name", value: host),
            URLQueryItem(name: "type", value: "A"),
        ]
        guard let url = components?.url else { throw UpstreamError.noAddress(host) }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw UpstreamError.noAddress(host)
        }
        let answers = object["Answer"] as? [[String: Any]] ?? []
        // type 1 == A record; AAAA answers are skipped so the client stays IPv4.
        return answers.compactMap { answer in
            (answer["type"] as? Int) == 1 ? answer["data"] as? String : nil
        }
    }
}

/// The production upstream client: connects to a resolved IP (never a loopback
/// or local address, to avoid talking to the proxy itself), speaks TLS with the
/// host's SNI, and streams the HTTP/1.1 response back chunk by chunk.
public final class NIOUpstreamClient: UpstreamClient, @unchecked Sendable {
    private let resolver: HostResolver
    private let host: String
    private let port: Int
    private let tlsConfiguration: TLSConfiguration
    private let localAddresses: Set<String>
    private let group: EventLoopGroup

    public init(
        resolver: HostResolver,
        host: String = "openrouter.ai",
        port: Int = 443,
        trustRoots: [Certificate]? = nil
    ) {
        self.resolver = resolver
        self.host = host
        self.port = port
        var tls = TLSConfiguration.makeClientConfiguration()
        if let trustRoots {
            // A caller-supplied trust anchor is expected to be a valid certificate; a
            // conversion failure would only be possible from a programming error.
            tls.trustRoots = .certificates(trustRoots.compactMap {
                try? NIOSSLCertificate(bytes: Array($0.serializeAsPEM().pemString.utf8), format: .pem)
            })
        }
        self.tlsConfiguration = tls
        self.localAddresses = Self.localAddresses()
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public func send(_ request: UpstreamRequest) async throws -> UpstreamResponse {
        let answers = try await resolver.resolve(host)
        guard let address = answers.first(where: { !isForbidden($0) }) else {
            throw UpstreamError.forbiddenAddress(answers.first ?? host)
        }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let promise = group.next().makePromise(of: HTTPResponseHead.self)
        let handler = UpstreamHTTPHandler(promise: promise, continuation: continuation)

        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                do {
                    let context = try NIOSSLContext(configuration: self.tlsConfiguration)
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSLClientHandler(context: context, serverHostname: self.host))
                    try channel.pipeline.syncOperations.addHandler(HTTPRequestEncoder())
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPResponseDecoder()))
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: address, port: port)
            .get()

        var head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: request.method), uri: request.path)
        for (name, value) in request.headers { head.headers.add(name: name, value: value) }
        if head.headers.first(name: "Host") == nil { head.headers.add(name: "Host", value: host) }
        try await channel.writeAndFlush(HTTPClientRequestPart.head(head)).get()
        if !request.body.isEmpty {
            var buffer = channel.allocator.buffer(capacity: request.body.count)
            buffer.writeBytes(request.body)
            try await channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(buffer))).get()
        }
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

        let responseHead = try await withTaskCancellationHandler {
            try await promise.futureResult.get()
        } onCancel: {
            channel.close(promise: nil)
        }
        let headers = responseHead.headers.map { ($0.name, $0.value) }
        return UpstreamResponse(
            status: Int(responseHead.status.code), headers: headers, body: stream,
            onCancel: { channel.close(promise: nil) })
    }

    /// Loopback and the machine's own interface addresses are refused: OpenRouter
    /// can never live there, and dialing one would loop back into this proxy.
    func isForbidden(_ address: String) -> Bool {
        NIOUpstreamClient.isLoopback(address) || localAddresses.contains(address)
    }

    static func isLoopback(_ address: String) -> Bool {
        address.hasPrefix("127.") || address.hasPrefix("::ffff:127.")
            || address == "::1" || address == "0:0:0:0:0:0:0:1"
    }

    static func localAddresses() -> Set<String> {
        var addresses = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return addresses }
        defer { freeifaddrs(head) }
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let socketAddress = interface.pointee.ifa_addr else { continue }
            let family = socketAddress.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(socketAddress.pointee.sa_len)
            if getnameinfo(socketAddress, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                addresses.insert(String(decoding: bytes, as: UTF8.self))
            }
        }
        return addresses
    }
}

/// Collects the response head once, forwards body chunks into the async stream,
/// and fails the head promise if the connection dies before any response.
private final class UpstreamHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<HTTPResponseHead>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var responded = false

    init(promise: EventLoopPromise<HTTPResponseHead>, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.promise = promise
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            responded = true
            promise.succeed(head)
        case .body(let buffer):
            continuation.yield(Data(buffer.readableBytesView))
        case .end:
            continuation.finish()
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !responded { responded = true; promise.fail(error) }
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !responded { responded = true; promise.fail(UpstreamError.noAddress("upstream closed")) }
        continuation.finish()
    }
}
