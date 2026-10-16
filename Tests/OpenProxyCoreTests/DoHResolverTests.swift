import Foundation
import Testing

@testable import OpenProxyCore

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ now: Date) { self.value = now }

    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class EndpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _attempts: [URL] = []

    func record(_ url: URL) { lock.withLock { _attempts.append(url) } }
    var attempts: [URL] { lock.withLock { _attempts } }
}

@Suite("DoHResolver")
struct DoHResolverTests {
    private func resolver(
        clock: MutableClock, failing: BoolBox, ttl: TimeInterval?, maxStale: TimeInterval = 3600
    ) -> DoHResolver {
        DoHResolver(
            endpoints: [URL(string: "https://example.invalid")!],
            now: { clock.now },
            maxStale: maxStale,
            fetch: { _, _ in
                if failing.value { throw UpstreamError.noAddress("x") }
                return DoHResolver.Record(addresses: ["9.9.9.9"], ttl: ttl)
            })
    }

    @Test func servesCacheWithinRecordTTL() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let failing = BoolBox()
        let resolver = resolver(clock: clock, failing: failing, ttl: 30)

        #expect(try await resolver.resolve("x") == ["9.9.9.9"])
        failing.value = true
        clock.advance(29)
        #expect(try await resolver.resolve("x") == ["9.9.9.9"])   // still within TTL
        clock.advance(2)                                            // 31s > 30s
        await #expect(throws: UpstreamError.self) { _ = try await resolver.resolve("x") }
    }

    @Test func staleFallbackIsCappedEvenWithLongTTL() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let failing = BoolBox()
        let resolver = resolver(clock: clock, failing: failing, ttl: 100_000)

        #expect(try await resolver.resolve("x") == ["9.9.9.9"])
        failing.value = true
        clock.advance(3601)                                         // beyond the 1h cap
        await #expect(throws: UpstreamError.self) { _ = try await resolver.resolve("x") }
    }

    @Test func missingTTLFallsBackWithinTheCap() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let failing = BoolBox()
        let resolver = resolver(clock: clock, failing: failing, ttl: nil)

        #expect(try await resolver.resolve("x") == ["9.9.9.9"])
        failing.value = true
        clock.advance(3599)
        #expect(try await resolver.resolve("x") == ["9.9.9.9"])
        clock.advance(2)                                            // > 3600
        await #expect(throws: UpstreamError.self) { _ = try await resolver.resolve("x") }
    }

    @Test func defaultsTryCloudflareThenGoogle() {
        #expect(DoHResolver.defaultEndpoints.count == 2)
        #expect(DoHResolver.defaultEndpoints[0].host() == "cloudflare-dns.com")
        #expect(DoHResolver.defaultEndpoints[1].host() == "dns.google")
    }

    @Test func fallsBackToSecondProviderWhenFirstFails() async throws {
        let first = URL(string: "https://first.invalid")!
        let second = URL(string: "https://second.invalid")!
        let recorder = EndpointRecorder()
        let resolver = DoHResolver(
            endpoints: [first, second], now: Date.init, maxStale: 3600,
            fetch: { endpoint, _ in
                recorder.record(endpoint)
                if endpoint == first { throw UpstreamError.noAddress("x") }
                return DoHResolver.Record(addresses: ["9.9.9.9"], ttl: 30)
            })

        #expect(try await resolver.resolve("x") == ["9.9.9.9"])
        #expect(recorder.attempts == [first, second])
    }

    @Test func firstProviderWinsAndSecondIsNotContacted() async throws {
        let first = URL(string: "https://first.invalid")!
        let second = URL(string: "https://second.invalid")!
        let recorder = EndpointRecorder()
        let resolver = DoHResolver(
            endpoints: [first, second], now: Date.init, maxStale: 3600,
            fetch: { endpoint, _ in
                recorder.record(endpoint)
                return DoHResolver.Record(addresses: ["1.2.3.4"], ttl: 30)
            })

        #expect(try await resolver.resolve("x") == ["1.2.3.4"])
        #expect(recorder.attempts == [first])
    }

    @Test func bothProvidersFailingFallBackToTheCachedAnswer() async throws {
        let first = URL(string: "https://first.invalid")!
        let second = URL(string: "https://second.invalid")!
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let fail = BoolBox()
        let resolver = DoHResolver(
            endpoints: [first, second], now: { clock.now }, maxStale: 3600,
            fetch: { _, _ in
                if fail.value { throw UpstreamError.noAddress("x") }
                return DoHResolver.Record(addresses: ["9.9.9.9"], ttl: 30)
            })

        #expect(try await resolver.resolve("x") == ["9.9.9.9"])
        fail.value = true
        clock.advance(29)
        #expect(try await resolver.resolve("x") == ["9.9.9.9"])   // stale within TTL
    }
}
