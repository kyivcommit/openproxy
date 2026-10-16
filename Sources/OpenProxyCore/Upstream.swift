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

/// Tracks bytes read from the upstream socket that have not yet been handed to
/// the consumer, so a slow client cannot make the proxy buffer without bound.
public final class UpstreamByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    public init() {}

    func add(_ count: Int) { lock.withLock { value += count } }
    func subtract(_ count: Int) { lock.withLock { value = max(0, value - count) } }
    public var count: Int { lock.withLock { value } }
}

/// The upstream response head plus a stream of body chunks. Only the head is
/// available up front, so the Flex policy can still abandon a capacity failure
/// before the first body byte.
public final class UpstreamResponse: FlexResponse, @unchecked Sendable {
    public let status: Int
    public let headers: [(String, String)]
    public let body: AsyncThrowingStream<Data, Error>
    private let onCancel: @Sendable () -> Void
    let byteCounter: UpstreamByteCounter

    /// Bytes read from upstream and not yet delivered to the consumer.
    public var bufferedBytes: Int { byteCounter.count }

    public init(
        status: Int,
        headers: [(String, String)],
        body: AsyncThrowingStream<Data, Error>,
        onCancel: @Sendable @escaping () -> Void = {},
        byteCounter: UpstreamByteCounter = UpstreamByteCounter()
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.onCancel = onCancel
        self.byteCounter = byteCounter
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
    struct Record: Sendable {
        var addresses: [String]
        /// Minimum record TTL, or nil when the answer carried none.
        var ttl: TimeInterval?
    }

    private let endpoint: URL
    private let now: @Sendable () -> Date
    private let maxStale: TimeInterval
    private let fetch: @Sendable (String) async throws -> Record
    private let lock = NSLock()
    private var cache: [String: (record: Record, storedAt: Date)] = [:]

    public convenience init(endpoint: URL = URL(string: "https://cloudflare-dns.com/dns-query")!) {
        self.init(endpoint: endpoint, now: Date.init, maxStale: 3600)
    }

    /// `fetch`, `now` and `maxStale` are injection points for tests; production
    /// uses the Cloudflare query and a one-hour cap on stale answers.
    init(
        endpoint: URL,
        now: @escaping @Sendable () -> Date,
        maxStale: TimeInterval,
        fetch: (@Sendable (String) async throws -> Record)? = nil
    ) {
        self.endpoint = endpoint
        self.now = now
        self.maxStale = maxStale
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        self.fetch = fetch ?? { host in try await Self.query(host, endpoint: endpoint, session: session) }
    }

    public func resolve(_ host: String) async throws -> [String] {
        if let record = try? await fetch(host), !record.addresses.isEmpty {
            lock.withLock { cache[host] = (record, now()) }
            return record.addresses
        }
        // A failed lookup may fall back to the last good answer, but no further
        // than the record's TTL (or the cap when the answer had none).
        if let entry = lock.withLock({ cache[host] }), !entry.record.addresses.isEmpty {
            let age = now().timeIntervalSince(entry.storedAt)
            let allowedAge = min(entry.record.ttl ?? maxStale, maxStale)
            if age <= allowedAge { return entry.record.addresses }
        }
        throw UpstreamError.noAddress(host)
    }

    private static func query(_ host: String, endpoint: URL, session: URLSession) async throws -> Record {
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
        // Only A records carry an address; a CNAME's target is a name, not an IP.
        let addresses = answers.compactMap { answer in
            (answer["type"] as? Int) == 1 ? answer["data"] as? String : nil
        }
        let ttl = answers.compactMap { $0["TTL"] as? Double }.min()
        return Record(addresses: addresses, ttl: ttl)
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
    private let allowLoopback: Bool
    private let group: EventLoopGroup

    public convenience init(
        resolver: HostResolver,
        host: String = "openrouter.ai",
        port: Int = 443,
        trustRoots: [Certificate]? = nil
    ) {
        self.init(resolver: resolver, host: host, port: port, trustRoots: trustRoots, allowLoopback: false)
    }

    /// `allowLoopback` is a test hook: it lets the wire tests point the real client at a
    /// loopback TLS server. Production callers use the public init, which never allows it.
    init(
        resolver: HostResolver,
        host: String,
        port: Int,
        trustRoots: [Certificate]?,
        allowLoopback: Bool
    ) {
        self.resolver = resolver
        self.host = host
        self.port = port
        self.allowLoopback = allowLoopback
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

        let counter = UpstreamByteCounter()
        let body = BackpressuredBody(counter: counter)
        let promise = group.next().makePromise(of: HTTPResponseHead.self)
        let handler = UpstreamHTTPHandler(promise: promise, body: body)

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
        body.attach(channel: channel)

        return try await withTaskCancellationHandler {
            do {
                var head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: request.method), uri: request.path)
                for (name, value) in request.headers { head.headers.add(name: name, value: value) }
                // The client's Host is meaningless to us (we dial a resolved IP);
                // use the configured authority, matching the TLS SNI.
                head.headers.replaceOrAdd(name: "Host", value: port == 443 ? host : "\(host):\(port)")
                try await channel.writeAndFlush(HTTPClientRequestPart.head(head)).get()
                if !request.body.isEmpty {
                    var buffer = channel.allocator.buffer(capacity: request.body.count)
                    buffer.writeBytes(request.body)
                    try await channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(buffer))).get()
                }
                try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

                let responseHead = try await promise.futureResult.get()
                let headers = responseHead.headers.map { ($0.name, $0.value) }
                return UpstreamResponse(
                    status: Int(responseHead.status.code), headers: headers, body: body.makeStream(),
                    onCancel: { channel.close(promise: nil) }, byteCounter: counter)
            } catch {
                channel.close(promise: nil)
                throw error
            }
        } onCancel: {
            // Cancel during connect/write/head-wait: drop the connection so the
            // in-flight future fails promptly instead of running to completion.
            channel.close(promise: nil)
        }
    }

    /// Loopback and the machine's own interface addresses are refused: OpenRouter
    /// can never live there, and dialing one would loop back into this proxy.
    func isForbidden(_ address: String) -> Bool {
        if allowLoopback { return false }
        return NIOUpstreamClient.isForbiddenAddress(address) || localAddresses.contains(address)
    }

    /// Refuses address literals that cannot be the real OpenRouter: unspecified,
    /// loopback, link-local, multicast, reserved, and IPv4-mapped/compatible
    /// forms of them. Anything that fails to parse is refused too.
    static func isForbiddenAddress(_ address: String) -> Bool {
        // Drop an IPv6 zone id ("fe80::1%en0") before parsing.
        let host = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return isForbiddenIPv4(withUnsafeBytes(of: v4) { Array($0) })
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return isForbiddenIPv6(withUnsafeBytes(of: v6) { Array($0) })
        }
        return true
    }

    private static func isForbiddenIPv4(_ b: [UInt8]) -> Bool {
        if b[0] == 0 { return true }                            // 0.0.0.0/8 "this network"
        if b[0] == 127 { return true }                          // 127.0.0.0/8 loopback
        if b[0] == 169 && b[1] == 254 { return true }           // 169.254.0.0/16 link-local
        if (b[0] & 0xf0) == 224 { return true }                 // 224.0.0.0/4 multicast
        if (b[0] & 0xf0) == 240 { return true }                 // 240.0.0.0/4 reserved + broadcast
        return false
    }

    private static func isForbiddenIPv6(_ b: [UInt8]) -> Bool {
        if b.allSatisfy({ $0 == 0 }) { return true }            // ::
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }  // fe80::/10 link-local
        if b[0] == 0xff { return true }                         // ff00::/8 multicast
        // IPv4-compatible (::/96) and IPv4-mapped (::ffff:0:0/96) forms carry
        // an IPv4 address in the last four bytes; inherit its verdict.
        if b[0..<10].allSatisfy({ $0 == 0 }),
           (b[10] == 0 && b[11] == 0) || (b[10] == 0xff && b[11] == 0xff) {
            return isForbiddenIPv4(Array(b[12..<16]))
        }
        return false
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

/// Bridges the upstream channel to the response stream with a bounded buffer.
/// Reads pause once `highWaterMark` bytes are queued and resume as the consumer
/// drains, so a slow client cannot make the proxy buffer without bound.
final class BackpressuredBody: @unchecked Sendable {
    private static let highWaterMark = 64 * 1024

    private let lock = NSLock()
    private let counter: UpstreamByteCounter
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data?, Error>?
    private var finished = false
    private var failure: Error?
    private var paused = false
    private var channel: Channel?

    init(counter: UpstreamByteCounter) { self.counter = counter }

    func makeStream() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(unfolding: { [self] in try await next() })
    }

    func attach(channel: Channel) { lock.withLock { self.channel = channel } }

    /// Called on the event loop for each decoded body chunk.
    func receive(_ data: Data) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: data)
            return
        }
        counter.add(data.count)
        queue.append(data)
        let shouldPause = !paused && counter.count >= Self.highWaterMark
        if shouldPause { paused = true }
        lock.unlock()
        if shouldPause { _ = channel?.setOption(ChannelOptions.autoRead, value: false) }
    }

    func finish() {
        lock.lock()
        finished = true
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: nil)
            return
        }
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        failure = error
        finished = true
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(throwing: error)
            return
        }
        lock.unlock()
    }

    private func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            if !queue.isEmpty {
                let data = queue.removeFirst()
                counter.subtract(data.count)
                let shouldResume = paused && counter.count < Self.highWaterMark
                if shouldResume { paused = false }
                lock.unlock()
                if shouldResume { _ = channel?.setOption(ChannelOptions.autoRead, value: true) }
                continuation.resume(returning: data)
                return
            }
            if finished {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}

/// Collects the response head once, hands body chunks to the bounded body, and
/// fails the head promise if the connection dies before any response.
private final class UpstreamHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<HTTPResponseHead>
    private let body: BackpressuredBody
    private var responded = false

    init(promise: EventLoopPromise<HTTPResponseHead>, body: BackpressuredBody) {
        self.promise = promise
        self.body = body
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            responded = true
            promise.succeed(head)
        case .body(let buffer):
            body.receive(Data(buffer.readableBytesView))
        case .end:
            body.finish()
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !responded { responded = true; promise.fail(error) }
        body.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !responded { responded = true; promise.fail(UpstreamError.noAddress("upstream closed")) }
        body.finish()
    }
}
