import Foundation
import Testing
import Security
import NIOCore
import NIOPosix
import NIOSSL

@testable import OpenProxyCore

// MARK: - Fakes

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.withLock { flag = true } }
    var cancelled: Bool { lock.withLock { flag } }
}

private struct FakeReply {
    var status = 200
    var headers: [(String, String)] = [("content-type", "application/json")]
    var body = Data("{}".utf8)
    var stream: (@Sendable (CancelFlag) -> AsyncThrowingStream<Data, Error>)?
}

private final class FakeUpstreamClient: UpstreamClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [UpstreamRequest] = []
    private var _cancels: [CancelFlag] = []
    private let replies: [FakeReply]

    init(_ replies: [FakeReply]) { self.replies = replies }

    func send(_ request: UpstreamRequest) async throws -> UpstreamResponse {
        let index = lock.withLock { () -> Int in
            _requests.append(request)
            return _requests.count - 1
        }
        let reply = replies.count == 1 ? replies[0] : replies[min(index, replies.count - 1)]
        let flag = CancelFlag()
        lock.withLock { _cancels.append(flag) }
        let stream: AsyncThrowingStream<Data, Error>
        if let build = reply.stream {
            stream = build(flag)
        } else {
            let body = reply.body
            stream = AsyncThrowingStream { continuation in
                continuation.yield(body)
                continuation.finish()
            }
        }
        return UpstreamResponse(
            status: reply.status, headers: reply.headers, body: stream, onCancel: { flag.cancel() })
    }

    var requests: [UpstreamRequest] { lock.withLock { _requests } }
    var cancels: [CancelFlag] { lock.withLock { _cancels } }
}

private final class FakeEndpointsFetcher: EndpointsFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private let data: Data

    init(hasFlex: Bool, hasPriority: Bool = false) {
        var endpoints: [[String: Any]] = []
        if hasFlex { endpoints.append(["service_tier": "flex"]) }
        if hasPriority { endpoints.append(["service_tier": "priority"]) }
        self.data = try! JSONSerialization.data(withJSONObject: ["data": ["endpoints": endpoints]])
    }

    func fetch(modelId: String, authorization: String) async throws -> Data {
        lock.withLock { _calls.append(modelId) }
        return data
    }

    var calls: [String] { lock.withLock { _calls } }
}

private struct StaticResolver: HostResolver {
    let addresses: [String]
    func resolve(_ host: String) async throws -> [String] { addresses }
}

// MARK: - Test client

/// Trusts the test CA without hostname pinning (the client dials 127.0.0.1 while
/// the leaf is issued for openrouter.ai).
private class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let anchors: [SecCertificate]

    init(caPEM: String) {
        self.anchors = TrustDelegate.secCertificates(fromPEM: caPEM)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    static func secCertificates(fromPEM pem: String) -> [SecCertificate] {
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return [] }
        return [certificate]
    }
}

/// Trusts the CA and reports each body chunk as it arrives, so a test can observe
/// streaming without `URLSession.bytes(for:)` (which skips the trust delegate here).
private final class StreamingDelegate: TrustDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    /// Called with the accumulated body each time more data arrives.
    var onData: (@Sendable (Data) -> Void)?

    override init(caPEM: String) { super.init(caPEM: caPEM) }

    var received: Data { lock.withLock { buffer } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let accumulated = lock.withLock { () -> Data in
            buffer.append(data)
            return buffer
        }
        onData?(accumulated)
    }
}

/// Flags the first byte read from a raw client connection.
private final class FirstDataProbe: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var _received = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        lock.withLock { _received = true }
    }

    var received: Bool { lock.withLock { _received } }
}

// MARK: - Harness

private struct Harness: @unchecked Sendable {
    let server: ProxyServer
    let upstream: FakeUpstreamClient
    let fetcher: FakeEndpointsFetcher
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

private func startHarness(
    settings: Settings,
    replies: [FakeReply],
    fetcher: FakeEndpointsFetcher = FakeEndpointsFetcher(hasFlex: true)
) async throws -> Harness {
    let directory = FileManager.default.temporaryDirectory.appending(path: "openproxy-proxy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ca = CertAuthority(directory: directory)
    try ca.loadOrCreate()
    let caPEM = try String(contentsOf: ca.caCertificatePEMURL)

    let upstream = FakeUpstreamClient(replies)
    let stats = try StatsStore(path: ":memory:")
    let server = ProxyServer(
        config: ProxyConfig(bindHost: "127.0.0.1", port: 0),
        ca: ca,
        upstream: upstream,
        catalog: TierCatalog(fetcher: fetcher),
        stats: stats,
        settings: { settings })
    try await server.start()

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 10
    let session = URLSession(configuration: configuration, delegate: TrustDelegate(caPEM: caPEM), delegateQueue: nil)

    return Harness(
        server: server,
        upstream: upstream,
        fetcher: fetcher,
        stats: stats,
        session: session,
        port: server.boundPort,
        directory: directory)
}

private func withServer(
    settings: Settings = Settings(),
    replies: [FakeReply],
    fetcher: FakeEndpointsFetcher = FakeEndpointsFetcher(hasFlex: true),
    _ body: (Harness) async throws -> Void
) async throws {
    let harness = try await startHarness(settings: settings, replies: replies, fetcher: fetcher)
    do {
        try await body(harness)
    } catch {
        harness.session.invalidateAndCancel()
        await harness.server.stop()
        try? FileManager.default.removeItem(at: harness.directory)
        throw error
    }
    harness.session.invalidateAndCancel()
    await harness.server.stop()
    try? FileManager.default.removeItem(at: harness.directory)
}

// MARK: - Helpers

private struct TimeoutError: Error {}

private func waitUntil(_ condition: @Sendable () -> Bool, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

private func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

private let chatPath = "/api/v1/chat/completions"

// MARK: - Tests

@Suite("ProxyServer")
struct ProxyServerTests {
    @Test func rewriteAppliedBeforeForwarding() async throws {
        let settings = Settings(enabled: true, sort: .throughput)
        try await withServer(settings: settings, replies: [FakeReply()]) { harness in
            let body = Data(#"{"model":"openai/gpt-5"}"#.utf8)
            let response = try await harness.request("POST", chatPath, body: body)
            #expect(response.status == 200)
            #expect(json(harness.upstream.requests[0].body)["model"] as? String == "openai/gpt-5:nitro")
            #expect(harness.stats.summary(since: .distantPast).total == 1)  // one record per request
        }
    }

    @Test func nonRewritablePathPassesThroughByteIdentical() async throws {
        let settings = Settings(enabled: true, sort: .throughput)
        try await withServer(settings: settings, replies: [FakeReply()]) { harness in
            let body = Data(#"{"model":"openai/gpt-5","input":"hi"}"#.utf8)
            _ = try await harness.request("POST", "/api/v1/embeddings", body: body)
            #expect(harness.upstream.requests[0].body == body)
        }
    }

    @Test func nonPostRequestNotRewritten() async throws {
        let settings = Settings(enabled: true, sort: .throughput)
        try await withServer(settings: settings, replies: [FakeReply()]) { harness in
            let body = Data(#"{"model":"openai/gpt-5"}"#.utf8)
            _ = try await harness.request("PUT", chatPath, body: body)
            #expect(harness.upstream.requests[0].body == body)
        }
    }

    @Test func disabledSettingForwardsUnchanged() async throws {
        let settings = Settings(enabled: false, sort: .throughput)
        try await withServer(settings: settings, replies: [FakeReply()]) { harness in
            let body = Data(#"{"model":"openai/gpt-5"}"#.utf8)
            _ = try await harness.request("POST", chatPath, body: body)
            #expect(harness.upstream.requests[0].body == body)
        }
    }

    @Test func sseChunksArriveIncrementally() async throws {
        let signal = Signal()
        let reply = FakeReply(
            status: 200,
            headers: [("content-type", "text/event-stream")],
            stream: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(Data("first\n".utf8))
                    let task = Task {
                        await signal.wait()
                        continuation.yield(Data("second\n".utf8))
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            })
        try await withServer(replies: [reply]) { harness in
            let caPEM = try String(contentsOf: harness.directory.appending(path: "ca.pem"))
            let delegate = StreamingDelegate(caPEM: caPEM)
            // Release the second chunk as soon as the first is seen on the client. A
            // buffering proxy would never deliver the first, so this times out instead.
            delegate.onData = { received in
                if received.contains(Data("first".utf8)) { signal.send() }
            }
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }

            var request = URLRequest(url: URL(string: "https://127.0.0.1:\(harness.port)\(chatPath)")!)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"model":"x","stream":true}"#.utf8)
            session.dataTask(with: request).resume()

            let gotFirst = await waitUntil({ delegate.received.contains(Data("first".utf8)) }, timeout: 5)
            #expect(gotFirst)
            let gotSecond = await waitUntil({ delegate.received.contains(Data("second".utf8)) }, timeout: 5)
            #expect(gotSecond)
        }
    }

    @Test func upstreamErrorReturnedUnchanged() async throws {
        let errorBody = Data(#"{"error":{"message":"boom"}}"#.utf8)
        let reply = FakeReply(
            status: 500, headers: [("content-type", "application/json")], body: errorBody)
        try await withServer(replies: [reply]) { harness in
            let response = try await harness.request("POST", chatPath, body: Data(#"{"model":"x"}"#.utf8))
            #expect(response.status == 500)
            #expect(response.body == errorBody)
        }
    }

    @Test func missingAuthorizationServedWithoutTierInjection() async throws {
        let settings = Settings(enabled: true, sort: .balanced, tier: .flex)
        try await withServer(settings: settings, replies: [FakeReply()]) { harness in
            let body = Data(#"{"model":"openai/gpt-5"}"#.utf8)
            let response = try await harness.request("POST", chatPath, body: body)
            #expect(response.status == 200)
            #expect(harness.upstream.requests[0].body == body)  // no service_tier added
            #expect(harness.fetcher.calls.isEmpty)             // catalog never consulted
        }
    }

    @Test func clientCancelMidStreamCancelsUpstream() async throws {
        let reply = FakeReply(
            status: 200,
            headers: [("content-type", "text/event-stream")],
            stream: { _ in
                // Yields one chunk, then stays open until the proxy abandons it.
                AsyncThrowingStream { continuation in
                    continuation.yield(Data("chunk\n".utf8))
                }
            })
        try await withServer(replies: [reply]) { harness in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { group.shutdownGracefully(queue: .global()) { _ in } }
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.certificateVerification = .none
            let context = try NIOSSLContext(configuration: tls)
            let probe = FirstDataProbe()

            let channel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(context: context, serverHostname: "openrouter.ai"))
                        try channel.pipeline.syncOperations.addHandler(probe)
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .connect(host: "127.0.0.1", port: harness.port).get()

            let body = Data(#"{"model":"x","stream":true}"#.utf8)
            var buffer = channel.allocator.buffer(capacity: 256)
            buffer.writeString(
                "POST \(chatPath) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.count)\r\n\r\n")
            buffer.writeBytes(body)
            try await channel.writeAndFlush(buffer).get()

            let gotData = await waitUntil({ probe.received }, timeout: 2)
            #expect(gotData)

            // Closing the socket mid-stream must cancel the upstream connection within 1s.
            try await channel.close().get()
            let upstreamCancelled = await waitUntil(
                { harness.upstream.cancels.contains { $0.cancelled } }, timeout: 1)
            #expect(upstreamCancelled)
        }
    }

    @Test func flexRetriesCapacityFailureThenSucceeds() async throws {
        let settings = Settings(enabled: true, sort: .balanced, tier: .flex)
        let replies = [FakeReply(status: 503), FakeReply(status: 200, body: Data(#"{"ok":true}"#.utf8))]
        try await withServer(settings: settings, replies: replies) { harness in
            let response = try await harness.request(
                "POST", chatPath, body: Data(#"{"model":"openai/gpt-5"}"#.utf8),
                headers: ["Authorization": "Bearer test"])
            #expect(response.status == 200)
            #expect(harness.upstream.requests.count == 2)
            #expect(harness.upstream.requests.allSatisfy {
                json($0.body)["service_tier"] as? String == "flex"
            })
        }
    }

    @Test func flexFallsBackToPlainBodyAfterExhaustingAttempts() async throws {
        let settings = Settings(enabled: true, sort: .balanced, tier: .flex)
        let replies = [
            FakeReply(status: 503), FakeReply(status: 503),
            FakeReply(status: 200, body: Data(#"{"ok":true}"#.utf8)),
        ]
        try await withServer(settings: settings, replies: replies) { harness in
            let response = try await harness.request(
                "POST", chatPath, body: Data(#"{"model":"openai/gpt-5"}"#.utf8),
                headers: ["Authorization": "Bearer test"])
            #expect(response.status == 200)
            let requests = harness.upstream.requests
            #expect(requests.count == 3)
            #expect(json(requests[0].body)["service_tier"] as? String == "flex")
            #expect(json(requests[2].body)["service_tier"] == nil)  // fallback drops flex
        }
    }

    @Test func nonLoopbackPeerRejected() throws {
        let foreign = try SocketAddress(ipAddress: "10.0.0.1", port: 1234)
        let loopback = try SocketAddress(ipAddress: "127.0.0.1", port: 1234)
        #expect(!ProxyServer.isAllowedPeer(foreign, allowNonLoopback: false))
        #expect(ProxyServer.isAllowedPeer(loopback, allowNonLoopback: false))
        #expect(ProxyServer.isAllowedPeer(foreign, allowNonLoopback: true))
        #expect(!ProxyServer.isAllowedPeer(nil, allowNonLoopback: false))
    }

    @Test func nioUpstreamClientRejectsLoopbackResolverAnswer() async {
        let client = NIOUpstreamClient(resolver: StaticResolver(addresses: ["127.0.0.1"]))
        await #expect(throws: UpstreamError.self) {
            _ = try await client.send(UpstreamRequest(method: "GET", path: "/", headers: [], body: Data()))
        }
    }
}

private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var signaled = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if signaled {
                    continuation.resume()
                } else {
                    continuations.append(continuation)
                }
            }
        }
    }

    func send() {
        lock.withLock {
            signaled = true
            continuations.forEach { $0.resume() }
            continuations.removeAll()
        }
    }
}
