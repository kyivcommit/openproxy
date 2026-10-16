import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

public struct ProxyConfig: Sendable {
    public var bindHost = "0.0.0.0"
    public var port = 443
    public var allowNonLoopbackPeers = false
    /// Largest request body buffered for rewriting; larger requests get a 413.
    public var maxBodyBytes = 32 * 1024 * 1024
    /// Most pipelined requests buffered behind the one in flight; beyond this
    /// (or `maxQueuedBytes`) the connection is closed.
    public var maxQueuedRequests = 8
    /// Most request-body bytes buffered across queued pipelined requests.
    public var maxQueuedBytes = 64 * 1024 * 1024

    public init() {}

    public init(
        bindHost: String, port: Int, allowNonLoopbackPeers: Bool = false,
        maxBodyBytes: Int = 32 * 1024 * 1024,
        maxQueuedRequests: Int = 8, maxQueuedBytes: Int = 64 * 1024 * 1024
    ) {
        self.bindHost = bindHost
        self.port = port
        self.allowNonLoopbackPeers = allowNonLoopbackPeers
        self.maxBodyBytes = maxBodyBytes
        self.maxQueuedRequests = maxQueuedRequests
        self.maxQueuedBytes = maxQueuedBytes
    }
}

/// The TLS interceptor: terminates the client's TLS, applies the Sort/Tier policy,
/// forwards to the real OpenRouter, and streams the response back untouched.
public final class ProxyServer: @unchecked Sendable {
    private let config: ProxyConfig
    private let ca: CertAuthority
    private let upstream: UpstreamClient
    private let catalog: TierCatalog
    private let stats: StatsStore
    private let settings: @Sendable () -> Settings
    private let group: EventLoopGroup
    private var channel: Channel?

    public private(set) var boundPort = 0

    var maxBodyBytes: Int { config.maxBodyBytes }
    var maxQueuedRequests: Int { config.maxQueuedRequests }
    var maxQueuedBytes: Int { config.maxQueuedBytes }

    public init(
        config: ProxyConfig = ProxyConfig(),
        ca: CertAuthority,
        upstream: UpstreamClient,
        catalog: TierCatalog,
        stats: StatsStore,
        settings: @escaping @Sendable () -> Settings
    ) {
        self.config = config
        self.ca = ca
        self.upstream = upstream
        self.catalog = catalog
        self.stats = stats
        self.settings = settings
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    public func start() async throws {
        let sslContext = try Self.makeSSLContext(ca.leaf())
        let config = self.config
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self,
                      Self.isAllowedPeer(channel.remoteAddress, allowNonLoopback: config.allowNonLoopbackPeers)
                else {
                    return channel.close()
                }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                    // Pipelining assistance stays off: it pauses socket reads until the
                    // response completes, which would hide a client disconnect mid-stream.
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withPipeliningAssistance: false, withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(ProxyConnectionHandler(server: self))
                }
            }
        let bound = try await bootstrap.bind(host: config.bindHost, port: config.port).get()
        self.channel = bound
        self.boundPort = bound.localAddress?.port ?? config.port
    }

    public func stop() async {
        let bound = channel
        channel = nil
        if let bound { try? await bound.close().get() }
        try? await group.shutdownGracefully()
    }

    // MARK: - Accept policy

    static func isAllowedPeer(_ address: SocketAddress?, allowNonLoopback: Bool) -> Bool {
        guard let ip = address?.ipAddress else { return false }
        return allowNonLoopback || isLoopback(ip)
    }

    static func isLoopback(_ ip: String) -> Bool {
        ip.hasPrefix("127.") || ip.hasPrefix("::ffff:127.")
            || ip == "::1" || ip == "0:0:0:0:0:0:0:1"
    }

    // MARK: - Request handling

    func handle(head requestHead: HTTPRequestHead, body: Data, channel: Channel) async {
        let started = Date()
        let settings = self.settings()
        let path = requestHead.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestHead.uri
        let authorization = requestHead.headers.first(name: "Authorization")
        let model = Rewriter.model(in: body)

        // The policy applies only to POSTs to the rewritable paths; everything else
        // passes through byte-for-byte and never triggers a TierCatalog lookup.
        let isRewritable = requestHead.method == .POST
        // Only consult the catalog when the policy could actually inject a tier.
        let needsAvailability = isRewritable
            && settings.enabled
            && Rewriter.rewritablePaths.contains(path)
            && (settings.tier == .priority || settings.tier == .flex)
        var availability: TierAvailability?
        if needsAvailability, let model {
            // Missing Authorization makes the catalog return nil without a fetch.
            availability = await catalog.availability(model: model, authorization: authorization)
        }
        let rewrite = isRewritable
            ? Rewriter.rewrite(path: path, body: body, settings: settings, availability: availability)
            : RewriteResult(body: body, model: model)

        let method = requestHead.method.rawValue
        // Framing is ours: the client's Content-Length describes its body, not the
        // rewritten one, and we always forward a fixed-length (buffered) body.
        let declaresBody = requestHead.headers.contains {
            let name = $0.name.lowercased()
            return name == "content-length" || name == "transfer-encoding"
        }
        let baseHeaders = HeaderFilter.stripHopByHop(requestHead.headers.map { ($0.name, $0.value) })
            .filter { header in
                let name = header.0.lowercased()
                // `expect` is consumed here (we answered 100 ourselves); forwarding
                // it would make the upstream wait for a continuation that never comes.
                return name != "content-length" && name != "expect"
            }
        let response: UpstreamResponse
        var retries = 0
        var usedFallback = false
        do {
            if settings.tier == .flex, rewrite.wantsFlex {
                let plain = Rewriter.stripServiceTier(from: rewrite.body)
                let outcome = try await FlexController.run(
                    policy: settings.flex, streaming: Self.isStreaming(body),
                    flexBody: rewrite.body, plainBody: plain
                ) { [self] body, timeout in
                    try await sendUpstream(
                        Self.upstreamRequest(
                            method: method, uri: requestHead.uri, baseHeaders: baseHeaders,
                            declaresBody: declaresBody, body: body),
                        timeout: timeout)
                }
                response = outcome.response
                retries = max(0, outcome.attempts - 1)
                usedFallback = outcome.usedFallback
            } else {
                response = try await upstream.send(
                    Self.upstreamRequest(
                        method: method, uri: requestHead.uri, baseHeaders: baseHeaders,
                        declaresBody: declaresBody, body: rewrite.body))
            }
        } catch {
            // A cancelled request is a client disconnect, not an upstream failure:
            // do not fabricate a 502 or record one.
            if Task.isCancelled || error is CancellationError { return }
            let failure = error as? FlexFailure
            await writeError(status: 502, message: "upstream unavailable", channel: channel)
            record(started: started, path: path, rewrite: rewrite, settings: settings,
                   status: 502, retries: max(0, (failure?.attempts ?? 0) - 1),
                   usedFallback: failure?.usedFallback ?? false,
                   ttfbMs: Int(Date().timeIntervalSince(started) * 1000))
            return
        }

        let ttfbMs = Int(Date().timeIntervalSince(started) * 1000)
        writeResponseHead(response, channel: channel)
        var finalStatus = response.status
        let tap = ResponseTap(streaming: Self.isStreaming(body))
        do {
            try await withTaskCancellationHandler {
                for try await chunk in response.body {
                    try Task.checkCancellation()
                    // Forward before tapping: parsing SSE JSON must not delay the client.
                    if !chunk.isEmpty { try await writeBody(chunk, channel: channel) }
                    tap.consume(chunk)
                }
            } onCancel: {
                // Client went away mid-stream: close the upstream connection.
                response.cancel()
            }
            try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        } catch {
            // The upstream body failed after the head: no clean terminator is
            // possible, so close the connection and record the failure.
            if !(error is CancellationError) && !Task.isCancelled { finalStatus = 502 }
            channel.close(promise: nil)
        }
        record(started: started, path: path, rewrite: rewrite, settings: settings,
               status: finalStatus, retries: retries, usedFallback: usedFallback, ttfbMs: ttfbMs,
               facts: tap.finish())
    }

    /// Runs one upstream send with a first-byte timeout, surfacing a `FlexTimeout`
    /// that the Flex policy can treat as a failed attempt.
    private func sendUpstream(_ request: UpstreamRequest, timeout: TimeInterval) async throws -> UpstreamResponse {
        let sendTask = Task { try await upstream.send(request) }
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            sendTask.cancel()
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            do {
                return try await sendTask.value
            } catch {
                // A client disconnect cancels this task; that is not a retryable
                // upstream timeout, so surface it as cancellation and stop the
                // Flex policy from retrying or falling back.
                if Task.isCancelled { throw CancellationError() }
                if sendTask.isCancelled { throw FlexTimeout(cancelUpstream: { sendTask.cancel() }) }
                throw error
            }
        } onCancel: {
            sendTask.cancel()
        }
    }

    // MARK: - Response writing

    /// Builds the forward request with our own framing: the buffered body's
    /// Content-Length, and no client Transfer-Encoding.
    private static func upstreamRequest(
        method: String, uri: String, baseHeaders: [(String, String)],
        declaresBody: Bool, body: Data
    ) -> UpstreamRequest {
        var headers = baseHeaders
        if declaresBody || !body.isEmpty { headers.append(("Content-Length", String(body.count))) }
        return UpstreamRequest(method: method, path: uri, headers: headers, body: body)
    }

    private func writeResponseHead(_ response: UpstreamResponse, channel: Channel) {
        var headers = HTTPHeaders()
        var hasLength = false
        for (name, value) in HeaderFilter.stripHopByHop(response.headers) {
            if name.lowercased() == "content-length" { hasLength = true }
            headers.add(name: name, value: value)
        }
        // Without a length NIO must use chunked framing; the body is streamed, not buffered.
        if !hasLength { headers.add(name: "Transfer-Encoding", value: "chunked") }
        let head = HTTPResponseHead(
            version: .http1_1, status: HTTPResponseStatus(statusCode: response.status), headers: headers)
        channel.writeAndFlush(HTTPServerResponsePart.head(head), promise: nil)
    }

    private func writeBody(_ data: Data, channel: Channel) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
    }

    func writeError(status: Int, message: String, channel: Channel) async {
        let body = Data(#"{"error":"\#(message)"}"#.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(body.count))
        channel.write(
            HTTPServerResponsePart.head(HTTPResponseHead(
                version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers)),
            promise: nil)
        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
    }

    private func record(
        started: Date, path: String, rewrite: RewriteResult, settings: Settings,
        status: Int, retries: Int, usedFallback: Bool, ttfbMs: Int = 0,
        facts: ResponseFacts = ResponseFacts()
    ) {
        stats.record(RequestRecord(
            time: started, path: path, model: rewrite.model, sort: settings.sort, tier: settings.tier,
            actualTier: facts.actualTier, provider: facts.provider, status: status, ttfbMs: ttfbMs,
            retries: retries, usedFallback: usedFallback,
            skippedReason: rewrite.skipped["service_tier"] ?? rewrite.skipped.values.first,
            promptTokens: facts.promptTokens, completionTokens: facts.completionTokens,
            costUSD: facts.costUSD))
    }

    static func isStreaming(_ body: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        return object["stream"] as? Bool == true
    }

    static func serverTLSConfiguration(
        _ leaf: (certificatePEM: String, privateKeyPEM: String)
    ) throws -> TLSConfiguration {
        let certificate = try NIOSSLCertificate(bytes: Array(leaf.certificatePEM.utf8), format: .pem)
        let key = try NIOSSLPrivateKey(bytes: Array(leaf.privateKeyPEM.utf8), format: .pem)
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)], privateKey: .privateKey(key))
        tls.applicationProtocols = ["http/1.1"]
        tls.minimumTLSVersion = .tlsv12
        return tls
    }

    private static func makeSSLContext(
        _ leaf: (certificatePEM: String, privateKeyPEM: String)
    ) throws -> NIOSSLContext {
        try NIOSSLContext(configuration: serverTLSConfiguration(leaf))
    }
}

/// Buffers one request at a time, then hands it to the server. Requests are
/// serialized per connection (a response is fully written before the next
/// request starts), and closing the client connection cancels the in-flight work.
private final class ProxyConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart

    private struct Request {
        var head: HTTPRequestHead
        var body: Data
    }

    private weak var server: ProxyServer?
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var pending: [Request] = []
    private var queuedBytes = 0
    private var current: Task<Void, Never>?
    private var exceededBodyLimit = false

    init(server: ProxyServer) { self.server = server }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            self.body.clear()
            self.exceededBodyLimit = false
            if let server = self.server,
               let length = head.headers.first(name: "Content-Length").flatMap(Int.init),
               length > server.maxBodyBytes {
                exceededBodyLimit = true
                rejectTooLarge(context: context, server: server)
                return
            }
            // Release a waiting client before it sends the body; otherwise the
            // client blocks forever and the request never completes.
            if head.headers.first(name: "Expect")?.lowercased() == "100-continue" {
                context.writeAndFlush(
                    NIOAny(HTTPServerResponsePart.head(
                        HTTPResponseHead(version: .http1_1, status: .continue))),
                    promise: nil)
            }
        case .body(var buffer):
            guard !exceededBodyLimit, let server = self.server else { return }
            // Chunked bodies have no Content-Length, so cap as bytes accumulate.
            if body.readableBytes + buffer.readableBytes > server.maxBodyBytes {
                exceededBodyLimit = true
                body.clear()
                rejectTooLarge(context: context, server: server)
                return
            }
            self.body.writeBuffer(&buffer)
        case .end:
            guard let head = self.head, let server = self.server else { return }
            guard !exceededBodyLimit else { return }
            // Pipelined requests queue behind the one in flight; cap both their
            // count and total bytes so a slow upstream cannot make this grow
            // without bound. A 429 written now would arrive out of order with the
            // serialized responses, so the connection is closed instead.
            let bytes = body.readableBytes
            if pending.count >= server.maxQueuedRequests || queuedBytes + bytes > server.maxQueuedBytes {
                overloaded(context: context)
                return
            }
            queuedBytes += bytes
            pending.append(Request(head: head, body: Data(body.readableBytesView)))
            pump(channel: context.channel, server: server)
        }
    }

    private func rejectTooLarge(context: ChannelHandlerContext, server: ProxyServer) {
        let channel = context.channel
        Task {
            await server.writeError(status: 413, message: "request body too large", channel: channel)
            try? await channel.close().get()
        }
    }

    private func overloaded(context: ChannelHandlerContext) {
        // A 429 cannot be written while the in-flight response is still open (NIO
        // forbids a second head before the first ends), so the connection is closed
        // instead: the client sees the truncated response and must back off.
        context.close(promise: nil)
    }

    /// Starts the next queued request only when nothing else is in flight, so
    /// responses stay ordered and a client close cancels the one running.
    private func pump(channel: Channel, server: ProxyServer) {
        guard current == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        queuedBytes -= request.body.count
        current = Task { [weak self] in
            await server.handle(head: request.head, body: request.body, channel: channel)
            await self?.finished(channel: channel, server: server)
        }
    }

    private func finished(channel: Channel, server: ProxyServer) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            channel.eventLoop.execute {
                self.current = nil
                self.pump(channel: channel, server: server)
                continuation.resume()
            }
        }
    }

    private func cancelAll() {
        current?.cancel()
        current = nil
        pending.removeAll()
        queuedBytes = 0
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelAll()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        cancelAll()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        cancelAll()
        context.close(promise: nil)
    }
}
