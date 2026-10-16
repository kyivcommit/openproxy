import Foundation
import Testing

@testable import OpenProxyCore

private final class RecordingFetcher: EndpointsFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private let result: Result<Data, any Error>

    init(result: Result<Data, any Error>) {
        self.result = result
    }

    var modelIds: [String] { lock.withLock { calls } }
    var callCount: Int { lock.withLock { calls.count } }

    func fetch(modelId: String, authorization: String) async throws -> Data {
        lock.withLock { calls.append(modelId) }
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

@Suite("TierCatalog")
struct TierCatalogTests {
    static func fixtureData() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "endpoints-with-tiers", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func parsesFlexAndPriority() throws {
        let availability = try #require(TierCatalog.parseAvailability(try Self.fixtureData()))
        #expect(availability.hasFlex)
        #expect(availability.hasPriority)
    }

    @Test func ignoresUnknownTier() throws {
        let json = Data(#"{"data":{"endpoints":[{"service_tier":"ultrafast"},{"service_tier":null}]}}"#.utf8)
        let availability = try #require(TierCatalog.parseAvailability(json))
        #expect(!availability.hasFlex)
        #expect(!availability.hasPriority)
    }

    @Test func cachesWithinTTL() async throws {
        let fetcher = RecordingFetcher(result: .success(try Self.fixtureData()))
        let catalog = TierCatalog(fetcher: fetcher)

        let first = await catalog.availability(model: "google/gemini-2.5-pro", authorization: "Bearer k")
        let second = await catalog.availability(model: "google/gemini-2.5-pro", authorization: "Bearer k")

        #expect(first == TierAvailability(hasFlex: true, hasPriority: true))
        #expect(second == first)
        #expect(fetcher.callCount == 1)
    }

    @Test func refetchesAfterTTL() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let fetcher = RecordingFetcher(result: .success(try Self.fixtureData()))
        let catalog = TierCatalog(fetcher: fetcher, ttl: 600, now: { clock.now })

        _ = await catalog.availability(model: "m", authorization: "k")
        clock.now = Date(timeIntervalSince1970: 599)
        _ = await catalog.availability(model: "m", authorization: "k")
        #expect(fetcher.callCount == 1)

        clock.now = Date(timeIntervalSince1970: 601)
        _ = await catalog.availability(model: "m", authorization: "k")
        #expect(fetcher.callCount == 2)
    }

    @Test func nilWhenAuthorizationMissing() async {
        let fetcher = RecordingFetcher(result: .success(Data()))
        let catalog = TierCatalog(fetcher: fetcher)

        let availability = await catalog.availability(model: "google/gemini-2.5-pro", authorization: nil)

        #expect(availability == nil)
        #expect(fetcher.callCount == 0)
    }

    @Test func nilWhenFetcherThrows() async {
        let fetcher = RecordingFetcher(result: .failure(Boom()))
        let catalog = TierCatalog(fetcher: fetcher)

        let availability = await catalog.availability(model: "google/gemini-2.5-pro", authorization: "Bearer k")

        #expect(availability == nil)
    }

    @Test func modelVariantStrippedBeforeFetch() async throws {
        let fetcher = RecordingFetcher(result: .success(try Self.fixtureData()))
        let catalog = TierCatalog(fetcher: fetcher)

        _ = await catalog.availability(model: "openai/gpt-5:nitro", authorization: "Bearer k")

        #expect(fetcher.modelIds == ["openai/gpt-5"])
    }
}
