import Foundation
import Testing

@testable import OpenProxyCore

@Suite("Stats")
struct StatsTests {
    private func record(
        time: Date = Date(),
        path: String = "/api/v1/chat/completions",
        model: String? = "openai/gpt-5",
        actualTier: String? = nil,
        provider: String? = nil,
        status: Int = 200,
        userFallback: Bool = false,
        costUSD: Double? = nil
    ) -> RequestRecord {
        RequestRecord(
            time: time, path: path, model: model, sort: .balanced, tier: .auto,
            actualTier: actualTier, provider: provider, status: status, ttfbMs: 12,
            retries: 0, usedFallback: userFallback, skippedReason: nil,
            promptTokens: 10, completionTokens: 20, costUSD: costUSD)
    }

    @Test func summaryAggregates() throws {
        let store = try StatsStore(path: ":memory:")
        store.record(record(actualTier: "flex", provider: "openai", costUSD: 0.01))
        store.record(record(
            model: "anthropic/claude", actualTier: "flex", provider: "anthropic",
            userFallback: true, costUSD: 0.02))

        let summary = store.summary(since: .distantPast)
        #expect(summary.total == 2)
        #expect(summary.byProvider == ["openai": 1, "anthropic": 1])
        #expect(summary.byActualTier == ["flex": 2])
        #expect(summary.fallbackCount == 1)
        #expect(abs(summary.totalCostUSD - 0.03) < 1e-9)
    }

    @Test func sinceExcludesOlderRows() throws {
        let now = Date()
        let store = try StatsStore(path: ":memory:")
        store.record(record(time: now.addingTimeInterval(-3600), actualTier: "default", provider: "old"))
        store.record(record(time: now, actualTier: "flex", provider: "new"))

        let summary = store.summary(since: now.addingTimeInterval(-60))
        #expect(summary.total == 1)
        #expect(summary.byProvider == ["new": 1])
        #expect(summary.byActualTier == ["flex": 1])
    }

    @Test func reopeningFileKeepsRows() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = try StatsStore(path: url.path)
            store.record(record(actualTier: "flex", provider: "openai", costUSD: 0.5))
        }

        let reopened = try StatsStore(path: url.path)
        let summary = reopened.summary(since: .distantPast)
        #expect(summary.total == 1)
        #expect(summary.totalCostUSD == 0.5)
    }

    @Test func missingProviderAndTierExcluded() throws {
        let store = try StatsStore(path: ":memory:")
        store.record(record(actualTier: nil, provider: nil, costUSD: nil))

        let summary = store.summary(since: .distantPast)
        #expect(summary.total == 1)
        #expect(summary.byProvider.isEmpty)
        #expect(summary.byActualTier.isEmpty)
        #expect(summary.fallbackCount == 0)
        #expect(summary.totalCostUSD == 0)
    }

    @Test func largeIntegerFieldsDoNotTrap() throws {
        // Tokens and millisecond durations routinely exceed Int32.max; the old
        // `Int32(...)` binds trapped. A record must round-trip without crashing.
        let store = try StatsStore(path: ":memory:")
        store.record(RequestRecord(
            time: Date(), path: "/api/v1/chat/completions", model: "m", sort: .balanced, tier: .auto,
            status: 200, ttfbMs: 3_000_000_000, retries: 0, usedFallback: false,
            promptTokens: 3_000_000_000, completionTokens: 3_000_000_000, costUSD: 1))

        #expect(store.summary(since: .distantPast).total == 1)
    }
}
