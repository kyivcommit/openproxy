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

@Suite("DoHResolver")
struct DoHResolverTests {
    private func resolver(
        clock: MutableClock, failing: BoolBox, ttl: TimeInterval?, maxStale: TimeInterval = 3600
    ) -> DoHResolver {
        DoHResolver(
            endpoint: URL(string: "https://example.invalid")!,
            now: { clock.now },
            maxStale: maxStale,
            fetch: { _ in
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
}
