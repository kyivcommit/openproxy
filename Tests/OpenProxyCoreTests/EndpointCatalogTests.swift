import Foundation
import Testing

@testable import OpenProxyCore

private final class RecordingFetcher: EndpointsFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var auths: [String?] = []
    private var result: Result<Data, any Error>

    init(result: Result<Data, any Error>) {
        self.result = result
    }

    func setResult(_ result: Result<Data, any Error>) { lock.withLock { self.result = result } }

    var modelIds: [String] { lock.withLock { calls } }
    var authorizations: [String?] { lock.withLock { auths } }
    var callCount: Int { lock.withLock { calls.count } }

    func fetch(modelId: String, authorization: String?) async throws -> Data {
        let result = lock.withLock { () -> Result<Data, any Error> in
            calls.append(modelId)
            auths.append(authorization)
            return self.result
        }
        return try result.get()
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ date: Date) { self.value = date }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private struct Boom: Error {}

/// Suspends inside `fetch` until `release()` so tests can force overlapping lookups.
private final class SuspendingFetcher: EndpointsFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private let data: Data

    init(data: Data) { self.data = data }

    var modelIds: [String] { lock.withLock { calls } }

    func fetch(modelId: String, authorization: String?) async throws -> Data {
        let alreadyReleased = lock.withLock { () -> Bool in
            calls.append(modelId)
            return released
        }
        if alreadyReleased { return data }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if released { continuation.resume() } else { waiters.append(continuation) }
            }
        }
        return data
    }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            let w = waiters
            waiters = []
            return w
        }
        pending.forEach { $0.resume() }
    }
}

/// A fetcher that throws an error built from the Authorization it saw, to prove the catalog
/// never surfaces that error (and so never the key) to its caller.
private final class ThrowingFetcher: EndpointsFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _auths: [String?] = []

    var authorizations: [String?] { lock.withLock { _auths } }

    func fetch(modelId: String, authorization: String?) async throws -> Data {
        lock.withLock { _auths.append(authorization) }
        throw LeakyError(received: authorization)
    }

    private struct LeakyError: Error, CustomStringConvertible {
        var received: String?
        var description: String { "endpoints fetch failed with Authorization=\(received ?? "none")" }
    }
}

/// Polls until `condition` holds (or a second passes); newer = the background revalidation landed.
private func waitUntil(_ condition: @Sendable () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@Suite("EndpointCatalog")
struct EndpointCatalogTests {
    static func fixtureData() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "endpoints-with-tiers", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func deepseekFixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "deepseek-v4.1-flash-endpoints", withExtension: "json",
                subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func speedFixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "endpoints-with-speed", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func parsesUptimeLast1d() throws {
        let endpoints = try #require(EndpointCatalog.parseEndpoints(try Self.deepseekFixture()))
        let alibaba = try #require(endpoints.first { $0.tag == "alibaba" })
        #expect(alibaba.uptimeLast1d != nil)
        #expect(alibaba.uptimeLast30m == 100)
        // Keyless fetches carry no speed metrics.
        #expect(alibaba.throughput == nil)
        #expect(alibaba.latency == nil)
    }

    @Test func parsesSpeedPercentileObjects() throws {
        let endpoints = try #require(EndpointCatalog.parseEndpoints(try Self.speedFixture()))
        let relace = try #require(endpoints.first { $0.tag == "relace" })
        // Object shape: the p50 percentile wins.
        #expect(relace.throughput == 155)
        #expect(abs((relace.latency ?? 0) - 0.59) < 1e-9)
    }

    @Test func parsesPlainNumberSpeedMetrics() throws {
        let json = Data(#"""
        {"data":{"endpoints":[{"tag":"x","throughput_last_30m":42.5,"latency_last_30m":0.25}]}}
        """#.utf8)
        let endpoints = try #require(EndpointCatalog.parseEndpoints(json))
        #expect(endpoints.first?.throughput == 42.5)
        #expect(endpoints.first?.latency == 0.25)
    }

    @Test func parsesFlexAndPriority() throws {
        let availability = try #require(EndpointCatalog.parseAvailability(try Self.fixtureData()))
        #expect(availability.hasFlex)
        #expect(availability.hasPriority)
    }

    @Test func ignoresUnknownTier() throws {
        let json = Data(#"{"data":{"endpoints":[{"service_tier":"ultrafast"},{"service_tier":null}]}}"#.utf8)
        let availability = try #require(EndpointCatalog.parseAvailability(json))
        #expect(!availability.hasFlex)
        #expect(!availability.hasPriority)
    }

    @Test func parsesRealFixtureFields() throws {
        let endpoints = try #require(EndpointCatalog.parseEndpoints(try Self.deepseekFixture()))
        #expect(endpoints.count == 35)
        let flex = try #require(endpoints.first { $0.tag == "deepinfra/fp8/flex" })
        #expect(flex.providerName == "DeepInfra")
        #expect(flex.quantization == "fp8")
        #expect(flex.serviceTier == "flex")
        #expect(abs(flex.promptUSDPerMillion - 0.112) < 1e-9)
        #expect(abs(flex.completionUSDPerMillion - 0.336) < 1e-9)
        #expect(flex.uptimeLast30m == 100)
        let fp4 = try #require(endpoints.first { $0.tag == "open-inference/fp4" })
        #expect(fp4.serviceTier == nil)
        #expect(fp4.quantization == "fp4")
    }

    @Test func cachesWithinTTL() async throws {
        let fetcher = RecordingFetcher(result: .success(try Self.fixtureData()))
        let catalog = EndpointCatalog(fetcher: fetcher)

        let first = await catalog.availability(model: "google/gemini-2.5-pro", authorization: "Bearer k")
        let second = await catalog.availability(model: "google/gemini-2.5-pro", authorization: "Bearer k")

        #expect(first == TierAvailability(hasFlex: true, hasPriority: true))
        #expect(second == first)
        #expect(fetcher.callCount == 1)
    }

    @Test func refetchesAfterTTL() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let fetcher = RecordingFetcher(result: .success(try Self.fixtureData()))
        let catalog = EndpointCatalog(fetcher: fetcher, ttl: { 600 }, now: { clock.now })

        _ = await catalog.endpoints(model: "m", authorization: "k")
        clock.now = Date(timeIntervalSince1970: 599)
        _ = await catalog.endpoints(model: "m", authorization: "k")
        #expect(fetcher.callCount == 1)

        // Past the TTL the stale list is served at once and a background refresh is kicked off.
        clock.now = Date(timeIntervalSince1970: 601)
        let stale = await catalog.endpoints(model: "m", authorization: "k")
        #expect(stale != nil)
        await waitUntil { fetcher.callCount == 2 }
        #expect(fetcher.callCount == 2)
    }

    @Test func ttlIsReadPerLookup() async throws {
        // A settings change (TTL provider) must take effect without rebuilding the catalog.
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let fetcher = RecordingFetcher(result: .success(try Self.fixtureData()))
        let ttl = Clock(Date(timeIntervalSince1970: 600))
        let catalog = EndpointCatalog(
            fetcher: fetcher, ttl: { ttl.now.timeIntervalSince1970 }, now: { clock.now })

        _ = await catalog.endpoints(model: "m", authorization: nil)
        clock.now = Date(timeIntervalSince1970: 1)
        _ = await catalog.endpoints(model: "m", authorization: nil)
        #expect(fetcher.callCount == 1) // still inside the 600 s TTL

        // Lowering the TTL to the minimum makes the same cached entry stale: refresh in the background.
        ttl.now = Date(timeIntervalSince1970: 0)
        clock.now = Date(timeIntervalSince1970: 2)
        _ = await catalog.endpoints(model: "m", authorization: nil)
        await waitUntil { fetcher.callCount == 2 }
        #expect(fetcher.callCount == 2)
    }

    @Test func staleServedThenRefreshReplacesIt() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let v1 = Data(#"{"data":{"endpoints":[{"tag":"a","service_tier":null}]}}"#.utf8)
        let v2 = Data(#"{"data":{"endpoints":[{"tag":"b","service_tier":null}]}}"#.utf8)
        let fetcher = RecordingFetcher(result: .success(v1))
        let catalog = EndpointCatalog(fetcher: fetcher, ttl: { 600 }, now: { clock.now })

        #expect(await catalog.endpoints(model: "m", authorization: nil)?.map(\.tag) == ["a"])
        fetcher.setResult(.success(v2))
        clock.now = Date(timeIntervalSince1970: 601)
        // Served stale immediately…
        #expect(await catalog.endpoints(model: "m", authorization: nil)?.map(\.tag) == ["a"])
        // …and the background revalidation lands.
        await waitUntil { fetcher.callCount == 2 }
        #expect(await catalog.endpoints(model: "m", authorization: nil)?.map(\.tag) == ["b"])
    }

    @Test func fetchFailureKeepsStaleData() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let v1 = Data(#"{"data":{"endpoints":[{"tag":"a","service_tier":null}]}}"#.utf8)
        let fetcher = RecordingFetcher(result: .success(v1))
        let catalog = EndpointCatalog(fetcher: fetcher, ttl: { 600 }, now: { clock.now })

        _ = await catalog.endpoints(model: "m", authorization: nil)
        fetcher.setResult(.failure(Boom()))
        clock.now = Date(timeIntervalSince1970: 601)
        #expect(await catalog.endpoints(model: "m", authorization: nil)?.map(\.tag) == ["a"])
        await waitUntil { fetcher.callCount == 2 }
        // The failed refresh left the stale entry in place.
        #expect(await catalog.endpoints(model: "m", authorization: nil)?.map(\.tag) == ["a"])
    }

    @Test func fetchesWithoutAuthorization() async throws {
        // The endpoints call needs no key, so Smart price works for unauthenticated clients.
        let fetcher = RecordingFetcher(result: .success(try Self.fixtureData()))
        let catalog = EndpointCatalog(fetcher: fetcher)

        let endpoints = await catalog.endpoints(model: "m", authorization: nil)

        #expect(endpoints?.isEmpty == false)
        #expect(fetcher.authorizations == [nil])
    }

    @Test func remembersAndRefetchesKeylessEntryWithTheKey() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let keyless = Data(#"{"data":{"endpoints":[{"tag":"a"}]}}"#.utf8)
        let keyed = Data(#"{"data":{"endpoints":[{"tag":"a","throughput_last_30m":{"p50":10}}]}}"#.utf8)
        let fetcher = RecordingFetcher(result: .success(keyless))
        let catalog = EndpointCatalog(fetcher: fetcher, ttl: { 600 }, now: { clock.now })

        // Keyless first: the list is cached with no speed data.
        #expect(await catalog.endpoints(model: "m", authorization: nil)?.first?.throughput == nil)
        #expect(fetcher.authorizations == [nil])

        // The next request carries a key: the stale keyless list is served, then refreshed with the key.
        fetcher.setResult(.success(keyed))
        #expect(await catalog.endpoints(model: "m", authorization: "Bearer k")?.first?.throughput == nil)
        await waitUntil { fetcher.callCount == 2 }
        #expect(fetcher.authorizations == [nil, "Bearer k"])
        // A keyless lookup now sees the keyed (speed-bearing) list without another fetch.
        #expect(await catalog.endpoints(model: "m", authorization: nil)?.first?.throughput == 10)
        #expect(fetcher.callCount == 2)
    }

    @Test func reusesRememberedAuthorizationForKeylessRefresh() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let fetcher = RecordingFetcher(result: .success(try Self.fixtureData()))
        let catalog = EndpointCatalog(fetcher: fetcher, ttl: { 600 }, now: { clock.now })

        _ = await catalog.endpoints(model: "m", authorization: "Bearer k")
        clock.now = Date(timeIntervalSince1970: 601) // stale: this lookup refreshes
        _ = await catalog.endpoints(model: "m", authorization: nil)
        await waitUntil { fetcher.callCount == 2 }
        #expect(fetcher.authorizations == ["Bearer k", "Bearer k"])
    }

    @Test func refetchesKeylessEntryWithKeyOnlyOncePerTTL() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let fetcher = RecordingFetcher(result: .success(try Self.fixtureData()))
        let catalog = EndpointCatalog(fetcher: fetcher, ttl: { 600 }, now: { clock.now })

        _ = await catalog.endpoints(model: "m", authorization: nil)
        _ = await catalog.endpoints(model: "m", authorization: "Bearer k")
        await waitUntil { fetcher.callCount == 2 }
        // Further keyed lookups inside the TTL do not refetch again.
        _ = await catalog.endpoints(model: "m", authorization: "Bearer k")
        _ = await catalog.endpoints(model: "m", authorization: "Bearer k")
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(fetcher.callCount == 2)
    }

    @Test func authorizationNeverSurfacesInAnErrorDescription() async {
        // A fetcher that echoes the header it saw, standing in for any downstream that might
        // put the value in an error: the catalog must swallow it, never rethrow or expose it.
        let secret = "Bearer sk-secret-key"
        let fetcher = ThrowingFetcher()
        let catalog = EndpointCatalog(fetcher: fetcher)

        let result = await catalog.endpoints(model: "m", authorization: secret)

        #expect(result == nil) // fail-open
        #expect(fetcher.authorizations == [secret])
        #expect(!String(describing: result).contains(secret))
    }

    @Test func nilWhenAuthorizationMissing() async {
        let fetcher = RecordingFetcher(result: .success(Data()))
        let catalog = EndpointCatalog(fetcher: fetcher)

        let availability = await catalog.availability(model: "google/gemini-2.5-pro", authorization: nil)

        #expect(availability == nil)
        #expect(fetcher.callCount == 0)
    }

    @Test func nilWhenFetcherThrows() async {
        let fetcher = RecordingFetcher(result: .failure(Boom()))
        let catalog = EndpointCatalog(fetcher: fetcher)

        let availability = await catalog.availability(model: "google/gemini-2.5-pro", authorization: "Bearer k")

        #expect(availability == nil)
    }

    @Test func modelVariantStrippedBeforeFetch() async throws {
        let fetcher = RecordingFetcher(result: .success(try Self.fixtureData()))
        let catalog = EndpointCatalog(fetcher: fetcher)

        _ = await catalog.availability(model: "openai/gpt-5:nitro", authorization: "Bearer k")

        #expect(fetcher.modelIds == ["openai/gpt-5"])
    }

    @Test func coalescesConcurrentLookupsForSameModel() async throws {
        let fetcher = SuspendingFetcher(data: try Self.fixtureData())
        let catalog = EndpointCatalog(fetcher: fetcher)

        async let first = catalog.availability(model: "m", authorization: "k")
        async let second = catalog.availability(model: "m", authorization: "k")

        // Let both callers reach the actor while the single fetch is still suspended.
        try await Task.sleep(nanoseconds: 100_000_000)
        fetcher.release()

        let (firstResult, secondResult) = await (first, second)
        #expect(firstResult == TierAvailability(hasFlex: true, hasPriority: true))
        #expect(secondResult == firstResult)
        #expect(fetcher.modelIds == ["m"])
    }
}
