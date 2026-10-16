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

struct StaticResolver: HostResolver {
    let addresses: [String]
    func resolve(_ host: String) async throws -> [String] { addresses }
}

/// An upstream whose `send` blocks until cancelled, standing in for a slow
/// connect / write / head wait; records how many sends were attempted.
final class SlowCancelClient: UpstreamClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    func send(_ request: UpstreamRequest) async throws -> UpstreamResponse {
        lock.withLock { _count += 1 }
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return UpstreamResponse(status: 200, headers: [], body: AsyncThrowingStream { $0.finish() })
    }

    var count: Int { lock.withLock { _count } }
}

// MARK: - Test client

/// Trusts the test CA without hostname pinning (the client dials 127.0.0.1 while
/// the leaf is issued for openrouter.ai).
class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
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
    fetcher: FakeEndpointsFetcher = FakeEndpointsFetcher(hasFlex: true),
    maxBodyBytes: Int = 32 * 1024 * 1024
) async throws -> Harness {
    let directory = FileManager.default.temporaryDirectory.appending(path: "openproxy-proxy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ca = CertAuthority(directory: directory)
    try ca.loadOrCreate()
    let caPEM = try String(contentsOf: ca.caCertificatePEMURL)

    let upstream = FakeUpstreamClient(replies)
    let stats = try StatsStore(path: ":memory:")
    let server = ProxyServer(
        config: ProxyConfig(bindHost: "127.0.0.1", port: 0, maxBodyBytes: maxBodyBytes),
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
    maxBodyBytes: Int = 32 * 1024 * 1024,
    _ body: (Harness) async throws -> Void
) async throws {
    let harness = try await startHarness(
        settings: settings, replies: replies, fetcher: fetcher, maxBodyBytes: maxBodyBytes)
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

/// Starts a ProxyServer with an arbitrary (non-fake) upstream, for tests that
/// need to control cancellation or slow behaviour in `send`.
private func withCustomUpstream(
    settings: Settings,
    upstream: UpstreamClient,
    _ body: (ProxyServer, Int) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "openproxy-cust-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ca = CertAuthority(directory: directory)
    try ca.loadOrCreate()
    let server = ProxyServer(
        config: ProxyConfig(bindHost: "127.0.0.1", port: 0),
        ca: ca,
        upstream: upstream,
        catalog: TierCatalog(fetcher: FakeEndpointsFetcher(hasFlex: true)),
        stats: try StatsStore(path: ":memory:"),
        settings: { settings })
    try await server.start()
    do {
        try await body(server, server.boundPort)
    } catch {
        await server.stop()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
    await server.stop()
    try? FileManager.default.removeItem(at: directory)
}

// MARK: - Helpers

private struct TimeoutError: Error {}

private struct TestFailure: Error {}

private func openRawTLSChannel(port: Int, group: EventLoopGroup) async throws -> Channel {
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.certificateVerification = .none
    let context = try NIOSSLContext(configuration: tls)
    return try await ClientBootstrap(group: group)
        .channelInitializer { channel in
            do {
                try channel.pipeline.syncOperations.addHandler(
                    NIOSSLClientHandler(context: context, serverHostname: "openrouter.ai"))
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }
        .connect(host: "127.0.0.1", port: port).get()
}

/// Same as `openRawTLSChannel` but appends a monitor that records every byte the
/// server sends, so a test can read the raw response stream.
private func openRawTLSChannel(
    port: Int, group: EventLoopGroup, monitor: Bool
) async throws -> (Channel, ByteMonitor) {
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.certificateVerification = .none
    let context = try NIOSSLContext(configuration: tls)
    let monitor = ByteMonitor()
    let channel = try await ClientBootstrap(group: group)
        .channelInitializer { channel in
            do {
                try channel.pipeline.syncOperations.addHandler(
                    NIOSSLClientHandler(context: context, serverHostname: "openrouter.ai"))
                try channel.pipeline.syncOperations.addHandler(monitor)
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }
        .connect(host: "127.0.0.1", port: port).get()
    return (channel, monitor)
}

final class ByteMonitor: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NSLock()
    private var _received = Data()
    private var _closed = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        lock.withLock { _received.append(Data(unwrapInboundIn(data).readableBytesView)) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.withLock { _closed = true }
    }

    var received: Data { lock.withLock { _received } }
    var closed: Bool { lock.withLock { _closed } }
}

private func writePipelinedRequests(
    _ requests: [(path: String, body: Data)], on channel: Channel
) async throws {
    var buffer = channel.allocator.buffer(capacity: 512)
    for request in requests {
        buffer.writeString(
            "POST \(request.path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(request.body.count)\r\n\r\n")
        buffer.writeBytes(request.body)
    }
    try await channel.writeAndFlush(buffer).get()
}

private func waitUntil(_ condition: @Sendable () -> Bool, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// Polls a condition that must stay false for the window (e.g. "no second request
/// was started"). A bounded wait is the only way to assert a non-event.
private func staysFalse(_ condition: @Sendable () -> Bool, within timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return !condition()
}

private func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

private let chatPath = "/api/v1/chat/completions"

// MARK: - Tests

@Suite("ProxyServer")
struct ProxyServerTests {
    @Test func nonStreamingResponseFactsAreRecorded() async throws {
        let factsBody = Data(
            #"{"service_tier":"flex","provider":"Anthropic","usage":{"prompt_tokens":12,"completion_tokens":7,"cost":0.0021}}"#.utf8)
        let reply = FakeReply(status: 200, headers: [("content-type", "application/json")], body: factsBody)
        try await withServer(replies: [reply]) { harness in
            let response = try await harness.request(
                "POST", chatPath, body: Data(#"{"model":"openai/gpt-5"}"#.utf8))
            #expect(response.status == 200)
            #expect(await waitUntil({ harness.stats.summary(since: .distantPast).total == 1 }, timeout: 2))
            let summary = harness.stats.summary(since: .distantPast)
            #expect(summary.byActualTier["flex"] == 1)
            #expect(summary.byProvider["Anthropic"] == 1)
            #expect(abs(summary.totalCostUSD - 0.0021) < 1e-9)
        }
    }

    @Test func streamingResponseFactsAreRecordedAcrossChunkBoundaries() async throws {
        let reply = FakeReply(
            status: 200, headers: [("content-type", "text/event-stream")],
            stream: { _ in
                AsyncThrowingStream { continuation in
                    // Lines are split mid-JSON to exercise the rolling window.
                    continuation.yield(Data("data: {\"service_tier\":\"fl".utf8))
                    continuation.yield(Data("ex\",\"provider\":\"Anthropic\"}\n\n".utf8))
                    continuation.yield(Data("data: {\"usage\":{\"cost\":0.001}}\n\n".utf8))
                    continuation.finish()
                }
            })
        try await withServer(replies: [reply]) { harness in
            _ = try await harness.request(
                "POST", chatPath, body: Data(#"{"model":"openai/gpt-5","stream":true}"#.utf8))
            #expect(await waitUntil({ harness.stats.summary(since: .distantPast).total == 1 }, timeout: 2))
            let summary = harness.stats.summary(since: .distantPast)
            #expect(summary.byActualTier["flex"] == 1)
            #expect(summary.byProvider["Anthropic"] == 1)
            #expect(abs(summary.totalCostUSD - 0.001) < 1e-9)
        }
    }

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

    @Test func rewrittenBodyReframesContentLengthForRealUpstream() async throws {
        let settings = Settings(enabled: true, sort: .throughput)
        try await withWireServer(settings: settings) { wire in
            let body = Data(#"{"model":"openai/gpt-5"}"#.utf8)
            let response = try await wire.request("POST", chatPath, body: body)
            #expect(response.status == 200)
            let received = try #require(wire.upstream.received.first)
            let rewritten = received.body
            #expect(json(rewritten)["model"] as? String == "openai/gpt-5:nitro")
            #expect(rewritten.count != body.count)  // the rewrite changed the length
            #expect(received.header("content-length") == String(rewritten.count))
            #expect(received.header("transfer-encoding") == nil)
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

    @Test func expect100ContinueIsAnsweredAndStrippedUpstream() async throws {
        let body = Data(#"{"model":"x"}"#.utf8)
        try await withServer(replies: [FakeReply(status: 200, body: Data("ok".utf8))]) { harness in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { group.shutdownGracefully(queue: .global()) { _ in } }
            let (channel, monitor) = try await openRawTLSChannel(port: harness.port, group: group, monitor: true)

            var head = channel.allocator.buffer(capacity: 256)
            head.writeString(
                "POST \(chatPath) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
                    + "Expect: 100-continue\r\nContent-Length: \(body.count)\r\n\r\n")
            try await channel.writeAndFlush(head).get()

            // The client waits for 100 before sending the body; the proxy must release it.
            #expect(await waitUntil({ monitor.received.range(of: Data("100 Continue".utf8)) != nil }, timeout: 2))
            var bodyBuffer = channel.allocator.buffer(capacity: body.count)
            bodyBuffer.writeBytes(body)
            try await channel.writeAndFlush(bodyBuffer).get()

            #expect(await waitUntil({ monitor.received.range(of: Data("200 OK".utf8)) != nil }, timeout: 2))
            let received = try #require(harness.upstream.requests.first)
            #expect(received.body == body)
            #expect(!received.headers.contains { $0.0.lowercased() == "expect" })
            try await channel.close().get()
        }
    }

    @Test func pipelinedRequestsAreSerializedPerConnection() async throws {
        let gate = Signal()
        let first = FakeReply(
            status: 200, headers: [("content-type", "application/json")],
            stream: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(Data("first".utf8))
                    let task = Task {
                        await gate.wait()
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            })
        let second = FakeReply(
            status: 200, headers: [("content-type", "application/json")], body: Data("second".utf8))
        try await withServer(replies: [first, second]) { harness in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { group.shutdownGracefully(queue: .global()) { _ in } }
            let channel = try await openRawTLSChannel(port: harness.port, group: group)
            try await writePipelinedRequests(
                [
                    (path: chatPath, body: Data(#"{"model":"a"}"#.utf8)),
                    (path: chatPath, body: Data(#"{"model":"b"}"#.utf8)),
                ],
                on: channel)

            #expect(await waitUntil({ harness.upstream.requests.count >= 1 }, timeout: 2))
            // The second pipelined request must not reach upstream while the first response is open.
            #expect(await staysFalse({ harness.upstream.requests.count >= 2 }, within: 0.4))

            // Closing the socket cancels the in-flight request; the queued one never runs.
            try await channel.close().get()
            #expect(await waitUntil({ harness.upstream.cancels.contains { $0.cancelled } }, timeout: 1))
            #expect(harness.upstream.requests.count == 1)
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

    @Test func slowConsumerDoesNotBufferResponseUnboundedly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "openproxy-big-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ca = CertAuthority(directory: directory)
        try ca.loadOrCreate()
        let upstream = try RecordingUpstream(ca: ca, body: Data(repeating: 0x41, count: 4 * 1024 * 1024))
        do {
            try await upstream.start()
            let client = NIOUpstreamClient(
                resolver: StaticResolver(addresses: ["127.0.0.1"]),
                host: "openrouter.ai", port: upstream.port,
                trustRoots: [upstream.caCertificate], allowLoopback: true)
            let response = try await client.send(
                UpstreamRequest(method: "GET", path: "/big", headers: [], body: Data()))
            var iterator = response.body.makeAsyncIterator()
            _ = try await iterator.next()  // read one chunk, then stop pulling
            // An unbounded reader would have the whole 4 MiB in memory by now.
            #expect(await staysFalse({ response.bufferedBytes > 512 * 1024 }, within: 0.4))
            while try await iterator.next() != nil {}
        } catch {
            await upstream.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await upstream.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func upstreamBodyErrorClosesDownstream() async throws {
        let reply = FakeReply(
            status: 200, headers: [("content-type", "text/event-stream")],
            stream: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(Data("partial".utf8))
                    continuation.finish(throwing: TestFailure())
                }
            })
        try await withServer(replies: [reply]) { harness in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { group.shutdownGracefully(queue: .global()) { _ in } }
            let (channel, monitor) = try await openRawTLSChannel(
                port: harness.port, group: group, monitor: true)
            let body = Data(#"{"model":"x","stream":true}"#.utf8)
            var buffer = channel.allocator.buffer(capacity: 256)
            buffer.writeString(
                "POST \(chatPath) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.count)\r\n\r\n")
            buffer.writeBytes(body)
            try await channel.writeAndFlush(buffer).get()

            #expect(await waitUntil({ monitor.received.range(of: Data("partial".utf8)) != nil }, timeout: 2))
            // A failed upstream body must not end with a clean terminator: the
            // proxy closes the connection so the client sees a truncated response.
            #expect(await waitUntil({ monitor.closed }, timeout: 2))
            #expect(monitor.received.range(of: Data("0\r\n\r\n".utf8)) == nil)
            try? await channel.close().get()
        }
    }

    @Test func clientDisconnectBeforeHeadDoesNotRetryOrFallback() async throws {
        let settings = Settings(
            enabled: true, sort: .balanced, tier: .flex,
            flex: FlexPolicy(fallback: true, attempts: 3))
        let upstream = SlowCancelClient()
        try await withCustomUpstream(settings: settings, upstream: upstream) { _, port in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { group.shutdownGracefully(queue: .global()) { _ in } }
            let channel = try await openRawTLSChannel(port: port, group: group)
            let body = Data(#"{"model":"openai/gpt-5","stream":true}"#.utf8)
            var buffer = channel.allocator.buffer(capacity: 256)
            buffer.writeString(
                "POST \(chatPath) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer x\r\n"
                    + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n")
            buffer.writeBytes(body)
            try await channel.writeAndFlush(buffer).get()

            #expect(await waitUntil({ upstream.count >= 1 }, timeout: 2))
            try await channel.close().get()
            // A client disconnect must cancel, not trigger a retry or a fallback send.
            #expect(await staysFalse({ upstream.count > 1 }, within: 0.4))
        }
    }

    @Test func requestHopByHopHeadersAreStripped() async throws {
        try await withServer(replies: [FakeReply()]) { harness in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { group.shutdownGracefully(queue: .global()) { _ in } }
            let channel = try await openRawTLSChannel(port: harness.port, group: group)
            let body = Data(#"{"model":"openai/gpt-5"}"#.utf8)
            var buffer = channel.allocator.buffer(capacity: 512)
            buffer.writeString(
                "POST \(chatPath) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Connection: keep-alive, x-custom\r\nX-Custom: secret\r\n"
                    + "Proxy-Authorization: Basic abc\r\nTE: trailers\r\nUpgrade: h2c\r\n"
                    + "X-Keep: yes\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n")
            buffer.writeBytes(body)
            try await channel.writeAndFlush(buffer).get()

            #expect(await waitUntil({ !harness.upstream.requests.isEmpty }, timeout: 2))
            let names = Set(harness.upstream.requests[0].headers.map { $0.0.lowercased() })
            for gone in ["connection", "x-custom", "proxy-authorization", "te", "upgrade"] {
                #expect(!names.contains(gone))
            }
            #expect(names.contains("x-keep"))
            try? await channel.close().get()
        }
    }

    @Test func responseConnectionNominatedHeadersAreStripped() async throws {
        let reply = FakeReply(
            status: 200,
            headers: [
                ("content-type", "application/json"),
                ("connection", "close, x-resp"),
                ("x-resp", "up"),
                ("proxy-authenticate", "Basic realm=x"),
                ("keep-alive", "timeout=5"),
            ],
            body: Data("{}".utf8))
        try await withServer(replies: [reply]) { harness in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { group.shutdownGracefully(queue: .global()) { _ in } }
            let (channel, monitor) = try await openRawTLSChannel(
                port: harness.port, group: group, monitor: true)
            let body = Data(#"{"model":"openai/gpt-5"}"#.utf8)
            var buffer = channel.allocator.buffer(capacity: 256)
            buffer.writeString(
                "POST \(chatPath) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.count)\r\n\r\n")
            buffer.writeBytes(body)
            try await channel.writeAndFlush(buffer).get()

            #expect(await waitUntil({ monitor.received.range(of: Data("200 OK".utf8)) != nil }, timeout: 2))
            let head = String(decoding: monitor.received, as: UTF8.self).lowercased()
            #expect(head.contains("content-type"))
            #expect(!head.contains("x-resp"))
            #expect(!head.contains("proxy-authenticate"))
            #expect(!head.contains("keep-alive"))
            try? await channel.close().get()
        }
    }

    @Test func oversizedRequestBodyIsRejectedWith413() async throws {
        try await withServer(replies: [FakeReply()], maxBodyBytes: 64) { harness in
            let response = try await harness.request(
                "POST", chatPath, body: Data(repeating: 0x41, count: 1024))
            #expect(response.status == 413)
            #expect(harness.upstream.requests.isEmpty)
        }
    }

    @Test func catalogNotConsultedUnlessRewritableEnabledAndTiered() async throws {
        let fetcher = FakeEndpointsFetcher(hasFlex: true)
        let body = Data(#"{"model":"openai/gpt-5"}"#.utf8)
        let auth = ["Authorization": "Bearer x"]

        // Non-rewritable path: no lookup even for a tier that needs availability.
        try await withServer(
            settings: Settings(enabled: true, tier: .flex), replies: [FakeReply()], fetcher: fetcher
        ) { harness in
            _ = try await harness.request("POST", "/api/v1/embeddings", body: body, headers: auth)
        }
        #expect(fetcher.calls.isEmpty)

        // Disabled: no lookup.
        try await withServer(
            settings: Settings(enabled: false, tier: .flex), replies: [FakeReply()], fetcher: fetcher
        ) { harness in
            _ = try await harness.request("POST", chatPath, body: body, headers: auth)
        }
        #expect(fetcher.calls.isEmpty)

        // auto tier needs no availability.
        try await withServer(
            settings: Settings(enabled: true, tier: .auto), replies: [FakeReply()], fetcher: fetcher
        ) { harness in
            _ = try await harness.request("POST", chatPath, body: body, headers: auth)
        }
        #expect(fetcher.calls.isEmpty)

        // Flex on a rewritable enabled path does look up.
        try await withServer(
            settings: Settings(enabled: true, tier: .flex), replies: [FakeReply()], fetcher: fetcher
        ) { harness in
            _ = try await harness.request("POST", chatPath, body: body, headers: auth)
        }
        #expect(fetcher.calls == ["openai/gpt-5"])
    }

    @Test func upstreamHostHeaderIsTheConfiguredAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "openproxy-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ca = CertAuthority(directory: directory)
        try ca.loadOrCreate()
        let upstream = try RecordingUpstream(ca: ca)
        do {
            try await upstream.start()
            let client = NIOUpstreamClient(
                resolver: StaticResolver(addresses: ["127.0.0.1"]),
                host: "openrouter.ai", port: upstream.port,
                trustRoots: [upstream.caCertificate], allowLoopback: true)
            _ = try await client.send(UpstreamRequest(
                method: "GET", path: "/api/v1/models",
                headers: [("Host", "evil.example.com")], body: Data()))
            let received = try #require(upstream.received.first)
            #expect(received.header("host") == "openrouter.ai:\(upstream.port)")
        } catch {
            await upstream.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await upstream.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func tlsMinimumVersionIs12OnServerAndClient() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "openproxy-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CertAuthority(directory: directory)
        try ca.loadOrCreate()

        let serverConfig = try ProxyServer.serverTLSConfiguration(ca.leaf())
        #expect(serverConfig.minimumTLSVersion == .tlsv12)
        let client = NIOUpstreamClient(resolver: StaticResolver(addresses: []))
        #expect(client.minimumTLSVersion == .tlsv12)
    }

    @Test func nonLoopbackPeerRejected() throws {        let foreign = try SocketAddress(ipAddress: "10.0.0.1", port: 1234)
        let loopback = try SocketAddress(ipAddress: "127.0.0.1", port: 1234)
        #expect(!ProxyServer.isAllowedPeer(foreign, allowNonLoopback: false))
        #expect(ProxyServer.isAllowedPeer(loopback, allowNonLoopback: false))
        #expect(ProxyServer.isAllowedPeer(foreign, allowNonLoopback: true))
        #expect(!ProxyServer.isAllowedPeer(nil, allowNonLoopback: false))
    }

    @Test(arguments: [
        "0.0.0.0", "127.0.0.1", "127.5.0.1", "169.254.1.1", "224.0.0.1",
        "255.255.255.255", "240.0.0.1", "::", "::1", "fe80::1", "fe80::1%en0",
        "::ffff:127.0.0.1", "ff02::1", "not-an-ip", "999.1.1.1",
    ])
    func forbiddenAddressRejected(address: String) {
        #expect(NIOUpstreamClient.isForbiddenAddress(address))
    }

    @Test(arguments: ["1.2.3.4", "8.8.8.8", "2606:4700:4700::1111", "2001:4860:4860::8888"])
    func publicAddressAllowed(address: String) {
        #expect(!NIOUpstreamClient.isForbiddenAddress(address))
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
