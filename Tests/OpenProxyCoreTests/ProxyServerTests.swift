import Foundation
import Testing
import Security
import SQLite3
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

    init(data: Data) { self.data = data }

    func fetch(modelId: String, authorization: String?) async throws -> Data {
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

/// A connector whose connect never completes, standing in for a black-holed
/// upstream; `started` fires once the connect has been attempted. `finish()`
/// fails the pending connect so the test's future is not left unfulfilled (NIO
/// traps on an unfulfilled promise in debug builds).
private final class HangingConnector: UpstreamConnector, @unchecked Sendable {
    let started: Signal
    private let lock = NSLock()
    private var promise: EventLoopPromise<Channel>?

    init(started: Signal) { self.started = started }

    func connect(
        host: String, port: Int, group: EventLoopGroup,
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        let promise = group.next().makePromise(of: Channel.self)
        lock.withLock { self.promise = promise }
        started.send()
        return promise.futureResult
    }

    func finish() {
        let promise = lock.withLock { () -> EventLoopPromise<Channel>? in
            defer { self.promise = nil }
            return self.promise
        }
        promise?.fail(TestFailure())
    }
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

/// Records the leaf the server presents, then accepts any certificate, so a test can
/// observe which leaf a handshake got without depending on wall-clock validity.
private final class LeafCaptureDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _leaves: [Data] = []

    var leaves: [Data] { lock.withLock { _leaves } }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            lock.withLock { _leaves.append(SecCertificateCopyData(leaf) as Data) }
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ now: Date) { self.value = now }

    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
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

/// Counts the application-level flushes the client issues. The client's response
/// handler closes the channel as soon as a response ends, so flushing the request
/// in more than one write lets that close race a still-pending write.
private final class FlushCountingHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = Any

    private let lock = NSLock()
    private var _flushes = 0

    var flushes: Int { lock.withLock { _flushes } }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        lock.withLock { _flushes += 1 }
        context.flush()
    }
}

/// Installs a `FlushCountingHandler` at the tail of the client pipeline.
private struct FlushCountingConnector: UpstreamConnector {
    let counter: FlushCountingHandler

    func connect(
        host: String, port: Int, group: EventLoopGroup,
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        ClientBootstrapConnector().connect(host: host, port: port, group: group) { channel in
            initializer(channel).flatMap { channel.pipeline.addHandler(counter) }
        }
    }
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
    statsStore: StatsStore? = nil,
    maxBodyBytes: Int = 32 * 1024 * 1024,
    maxQueuedRequests: Int = 8,
    maxQueuedBytes: Int = 64 * 1024 * 1024
) async throws -> Harness {
    let directory = FileManager.default.temporaryDirectory.appending(path: "openproxy-proxy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ca = CertAuthority(directory: directory)
    try ca.loadOrCreate()
    let caPEM = try String(contentsOf: ca.caCertificatePEMURL)

    let upstream = FakeUpstreamClient(replies)
    let stats = try statsStore ?? StatsStore(path: ":memory:")
    let server = ProxyServer(
        config: ProxyConfig(
            bindHost: "127.0.0.1", port: 0, maxBodyBytes: maxBodyBytes,
            maxQueuedRequests: maxQueuedRequests, maxQueuedBytes: maxQueuedBytes),
        ca: ca,
        upstream: upstream,
        catalog: EndpointCatalog(fetcher: fetcher),
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
    statsStore: StatsStore? = nil,
    maxBodyBytes: Int = 32 * 1024 * 1024,
    maxQueuedRequests: Int = 8,
    maxQueuedBytes: Int = 64 * 1024 * 1024,
    _ body: (Harness) async throws -> Void
) async throws {
    let harness = try await startHarness(
        settings: settings, replies: replies, fetcher: fetcher, statsStore: statsStore,
        maxBodyBytes: maxBodyBytes,
        maxQueuedRequests: maxQueuedRequests, maxQueuedBytes: maxQueuedBytes)
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
    stats: StatsStore,
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
        catalog: EndpointCatalog(fetcher: FakeEndpointsFetcher(hasFlex: true)),
        stats: stats,
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

private func scalarText(_ path: String, sql: String) -> String? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
    defer { sqlite3_close_v2(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
    return String(cString: text)
}

/// One endpoint in the `/endpoints` shape. Cost arguments are USD per million tokens.
private func endpointJSON(
    _ tag: String, prompt: Double, completion: Double = 0,
    quant: String? = "unknown", tier: String? = nil, uptime: Double? = 100
) -> [String: Any] {
    var endpoint: [String: Any] = [
        "tag": tag, "provider_name": tag,
        "pricing": ["prompt": prompt / 1_000_000, "completion": completion / 1_000_000],
    ]
    if let quant { endpoint["quantization"] = quant }
    if let tier { endpoint["service_tier"] = tier }
    if let uptime { endpoint["uptime_last_30m"] = uptime }
    return endpoint
}

private func endpointsJSON(_ endpoints: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["data": ["endpoints": endpoints]])
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

    // MARK: - Smart price

    @Test func smartPriceInjectsEndpointOrderAndRecordsTag() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = try StatsStore(path: url.path)
        let endpoints = endpointsJSON([
            endpointJSON("cheap-fp8", prompt: 0.01, completion: 0.2, quant: "fp8"), // excluded
            endpointJSON("best-unquantized", prompt: 0.5, completion: 0.6), // key 0.6
            endpointJSON("second-unquantized", prompt: 0.3, completion: 0.9), // key 0.9
        ])
        try await withServer(
            settings: Settings(sort: .smartPrice), replies: [FakeReply()],
            fetcher: FakeEndpointsFetcher(data: endpoints), statsStore: stats
        ) { harness in
            let body = Data(#"{"model":"deepseek/deepseek-v4.1-flash"}"#.utf8)
            let response = try await harness.request(
                "POST", chatPath, body: body, headers: ["Authorization": "Bearer k"])
            #expect(response.status == 200)
            let provider = json(harness.upstream.requests[0].body)["provider"] as? [String: Any]
            #expect(provider?["order"] as? [String] == ["best-unquantized", "second-unquantized"])
            #expect(provider?["quantizations"] as? [String] == ["unknown"])
            #expect(provider?["allow_fallbacks"] as? Bool == true)
            #expect(await waitUntil({ harness.stats.summary(since: .distantPast).total == 1 }, timeout: 2))
        }
        #expect(scalarText(url.path, sql: "SELECT endpoint_tag FROM requests LIMIT 1") == "best-unquantized")
    }

    @Test func smartPriceDefersToClientProviderOrder() async throws {
        let endpoints = endpointsJSON([endpointJSON("deepinfra", prompt: 0.14, completion: 0.42)])
        try await withServer(
            settings: Settings(sort: .smartPrice), replies: [FakeReply()],
            fetcher: FakeEndpointsFetcher(data: endpoints)
        ) { harness in
            let body = Data(#"{"model":"m","provider":{"order":["client/x"]}}"#.utf8)
            _ = try await harness.request("POST", chatPath, body: body)
            let provider = json(harness.upstream.requests[0].body)["provider"] as? [String: Any]
            #expect(provider?["order"] as? [String] == ["client/x"])
            #expect(provider?["quantizations"] == nil) // untouched
        }
    }

    @Test func smartPriceFailsOpenWithoutEndpointData() async throws {
        try await withServer(
            settings: Settings(sort: .smartPrice), replies: [FakeReply()],
            fetcher: FakeEndpointsFetcher(data: Data())
        ) { harness in
            let body = Data(#"{"model":"m"}"#.utf8)
            _ = try await harness.request("POST", chatPath, body: body)
            #expect(harness.upstream.requests[0].body == body)
        }
    }

    @Test func smartPriceFailsOpenWithNoEligibleEndpoint() async throws {
        let endpoints = endpointsJSON([endpointJSON("cheap", prompt: 0.01, quant: "fp4")])
        try await withServer(
            settings: Settings(sort: .smartPrice), replies: [FakeReply()],
            fetcher: FakeEndpointsFetcher(data: endpoints)
        ) { harness in
            let body = Data(#"{"model":"m"}"#.utf8)
            _ = try await harness.request("POST", chatPath, body: body)
            #expect(harness.upstream.requests[0].body == body)
        }
    }

    @Test func leaderMemoryKeepsIncumbentWithinTenPercent() async {
        let leaders = EndpointLeaders()
        let incumbent = Endpoint(tag: "incumbent", promptUSDPerMillion: 1, uptimeLast30m: 100)
        let cheaper = Endpoint(tag: "slightlyCheaper", promptUSDPerMillion: 0.95, uptimeLast30m: 100)

        #expect(await leaders.rank(model: "m", endpoints: [incumbent], tier: .auto).leader == "incumbent")
        // A later 5%-cheaper endpoint does not flip the remembered leader.
        #expect(await leaders.rank(
            model: "m", endpoints: [incumbent, cheaper], tier: .auto).leader == "incumbent")
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
        try await withWireServer(settings: settings) { wire in
            let body = Data(#"{"model":"openai/gpt-5","input":"hi"}"#.utf8)
            let response = try await wire.request(
                "POST", "/api/v1/embeddings", body: body,
                headers: ["Content-Type": "application/json", "X-Trace": "abc"])
            #expect(response.status == 200)
            // Assert on what actually reached the wire through the real NIO client.
            let received = try #require(wire.upstream.received.first)
            #expect(received.method == "POST")
            #expect(received.uri == "/api/v1/embeddings")
            #expect(received.body == body)
            #expect(received.header("content-length") == String(body.count))
            #expect(received.header("transfer-encoding") == nil)
            #expect(received.header("content-type") == "application/json")
            #expect(received.header("x-trace") == "abc")
            #expect(received.header("host") == "openrouter.ai:\(wire.upstream.port)")
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

    /// A first response whose body stays open until `gate` is signaled, so the
    /// request stays "in flight" while later pipelined requests queue up.
    private func gatedFirstReply(_ gate: Signal) -> FakeReply {
        FakeReply(
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
    }

    @Test func pipelinedRequestsBeyondQueueCountAreClosed() async throws {
        let gate = Signal()
        try await withServer(
            replies: [gatedFirstReply(gate), FakeReply(), FakeReply()], maxQueuedRequests: 1
        ) { harness in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { group.shutdownGracefully(queue: .global()) { _ in } }
            let (channel, monitor) = try await openRawTLSChannel(
                port: harness.port, group: group, monitor: true)
            try await writePipelinedRequests(
                [
                    (path: chatPath, body: Data(#"{"model":"a"}"#.utf8)),
                    (path: chatPath, body: Data(#"{"model":"b"}"#.utf8)),
                    (path: chatPath, body: Data(#"{"model":"c"}"#.utf8)),
                ],
                on: channel)
            // Request 1 is in flight, request 2 fills the single queue slot, and
            // request 3 exceeds the cap: the proxy closes rather than buffering it.
            #expect(await waitUntil({ monitor.closed }, timeout: 2))
            #expect(harness.upstream.requests.count == 1)
            try? await channel.close().get()
        }
    }

    @Test func pipelinedRequestsBeyondQueueBytesAreClosed() async throws {
        let gate = Signal()
        let largeBody = Data(repeating: 0x41, count: 64)
        try await withServer(
            replies: [gatedFirstReply(gate), FakeReply()], maxQueuedBytes: 16
        ) { harness in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { group.shutdownGracefully(queue: .global()) { _ in } }
            let (channel, monitor) = try await openRawTLSChannel(
                port: harness.port, group: group, monitor: true)
            try await writePipelinedRequests(
                [
                    (path: chatPath, body: Data(#"{"model":"a"}"#.utf8)),
                    (path: chatPath, body: largeBody),
                ],
                on: channel)
            // The queued 64-byte body exceeds the 16-byte cap: close, don't buffer.
            #expect(await waitUntil({ monitor.closed }, timeout: 2))
            #expect(harness.upstream.requests.count == 1)
            try? await channel.close().get()
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
        try await withCustomUpstream(
            settings: settings, upstream: upstream, stats: try StatsStore(path: ":memory:")
        ) { _, port in
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

    /// A bodyless GET is complete at the request head, so the upstream can reply (and the
    /// client close the channel) before the client has flushed the trailing `.end`. The
    /// request must therefore go out as a single flush, or the `end` write races the
    /// response-driven close and fails with "I/O on closed channel".
    @Test func requestIsWrittenInASingleFlushSoTheResponseCloseCannotRaceIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "openproxy-flush-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ca = CertAuthority(directory: directory)
        try ca.loadOrCreate()
        let upstream = try RecordingUpstream(ca: ca)
        do {
            try await upstream.start()
            let counter = FlushCountingHandler()
            let client = NIOUpstreamClient(
                resolver: StaticResolver(addresses: ["127.0.0.1"]),
                host: "openrouter.ai", port: upstream.port,
                trustRoots: [upstream.caCertificate], allowLoopback: true,
                connector: FlushCountingConnector(counter: counter))
            let response = try await client.send(UpstreamRequest(
                method: "GET", path: "/api/v1/models", headers: [], body: Data()))
            for try await _ in response.body {}
            _ = try #require(upstream.received.first)
            #expect(counter.flushes == 1)
        } catch {
            await upstream.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await upstream.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func timeoutNanosecondsClampsHugeAndNaNValues() {
        // `UInt64(1e11 * 1e9)` and `UInt64(NaN)` both trap; the timeout must clamp instead.
        #expect(ProxyServer.timeoutNanoseconds(1e11) == 3600 * 1_000_000_000)
        #expect(ProxyServer.timeoutNanoseconds(.nan) == 0)
        #expect(ProxyServer.timeoutNanoseconds(-5) == 0)
        #expect(ProxyServer.timeoutNanoseconds(0.5) == 500_000_000)
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

    /// A leaf issued once at `start()` would expire after 90 days of uptime; the server must
    /// fetch the current leaf per handshake so a regenerated one is served without a restart.
    @Test func tlsLeafIsRefreshedWithoutRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "openproxy-leaf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clock = MutableClock(Date())
        let ca = CertAuthority(directory: directory, clock: { clock.now })
        try ca.loadOrCreate()
        let server = ProxyServer(
            config: ProxyConfig(bindHost: "127.0.0.1", port: 0),
            ca: ca,
            upstream: FakeUpstreamClient([FakeReply()]),
            catalog: EndpointCatalog(fetcher: FakeEndpointsFetcher(hasFlex: false)),
            stats: try StatsStore(path: ":memory:"),
            settings: { Settings() })
        do {
            try await server.start()
            let delegate = LeafCaptureDelegate()
            let url = URL(string: "https://127.0.0.1:\(server.boundPort)/api/v1/models")!

            func fetchLeaf() async -> Data? {
                let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                _ = try? await session.data(from: url)
                return delegate.leaves.last
            }

            let first = await fetchLeaf()
            clock.advance(61 * 86_400)  // past the 30-day renewal window
            let second = await fetchLeaf()

            #expect(first != nil)
            #expect(second != nil)
            #expect(first != second, "the server must present a regenerated leaf without a restart")
        } catch {
            await server.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func flexFailureRecordsRealAttemptsAndFallback() async throws {
        let settings = Settings(
            enabled: true, sort: .balanced, tier: .flex,
            flex: FlexPolicy(
                fallback: true, attempts: 2, firstByteTimeout: 0.05, nonStreamingTimeout: 0.05))
        let upstream = SlowCancelClient()
        let stats = try StatsStore(path: ":memory:")
        try await withCustomUpstream(settings: settings, upstream: upstream, stats: stats) { _, port in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { group.shutdownGracefully(queue: .global()) { _ in } }
            let (channel, monitor) = try await openRawTLSChannel(
                port: port, group: group, monitor: true)
            let body = Data(#"{"model":"openai/gpt-5","stream":true}"#.utf8)
            var buffer = channel.allocator.buffer(capacity: 256)
            buffer.writeString(
                "POST \(chatPath) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer x\r\n"
                    + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n")
            buffer.writeBytes(body)
            try await channel.writeAndFlush(buffer).get()

            #expect(await waitUntil({ monitor.received.range(of: Data("502".utf8)) != nil }, timeout: 3))
            #expect(upstream.count == 3)  // 2 flex attempts + 1 fallback
            #expect(await waitUntil({ stats.summary(since: .distantPast).total == 1 }, timeout: 2))
            // usedFallback was previously always false on the error path.
            #expect(stats.summary(since: .distantPast).fallbackCount == 1)
            try? await channel.close().get()
        }
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

    @Test func cancelDuringConnectReturnsWithinOneSecond() async throws {
        let started = Signal()
        let connector = HangingConnector(started: started)
        defer { connector.finish() }
        let client = NIOUpstreamClient(
            resolver: StaticResolver(addresses: ["93.184.216.34"]),
            host: "openrouter.ai", port: 443, trustRoots: nil, allowLoopback: false,
            connector: connector)
        let task = Task {
            try await client.send(UpstreamRequest(method: "GET", path: "/", headers: [], body: Data()))
        }
        // Wait until the connect is actually in flight (a fixed sleep would be flaky).
        await started.wait()

        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        _ = await task.result
        // Without the cancellation fix this would block for the 10 s connect timeout.
        #expect(clock.now - start < .seconds(1))
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
