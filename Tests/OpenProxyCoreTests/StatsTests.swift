import Foundation
import Testing
import SQLite3

@testable import OpenProxyCore

/// Reads one text value straight out of the file, to check what `record` persisted.
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

/// Writes a `requests` table in the schema of a build that predates `endpoint_tag`.
private func writeLegacyDatabase(_ path: String) {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let db else { return }
    defer { sqlite3_close_v2(db) }
    let create = """
        CREATE TABLE requests (
            time REAL NOT NULL, path TEXT NOT NULL, model TEXT, sort TEXT NOT NULL,
            tier TEXT NOT NULL, actual_tier TEXT, provider TEXT, status INTEGER NOT NULL,
            ttfb_ms INTEGER NOT NULL, retries INTEGER NOT NULL, used_fallback INTEGER NOT NULL,
            skipped_reason TEXT, prompt_tokens INTEGER, completion_tokens INTEGER, cost_usd REAL)
        """
    sqlite3_exec(db, create, nil, nil, nil)
    sqlite3_exec(db, """
        INSERT INTO requests (time, path, sort, tier, status, ttfb_ms, retries, used_fallback)
        VALUES (0, '/api/v1/chat/completions', 'balanced', 'auto', 200, 5, 0, 0)
        """, nil, nil, nil)
}

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

    @Test func summarySplitsModelAndOtherRequestsAndCountsFlex() throws {
        let store = try StatsStore(path: ":memory:")
        store.record(record(actualTier: "flex", provider: "openai"))
        // A request without a model id (e.g. /models): forwarded, not policy-managed.
        store.record(record(path: "/api/v1/models", model: nil))
        store.record(RequestRecord(
            time: Date(), path: "/api/v1/chat/completions", model: "openai/gpt-5", sort: .balanced,
            tier: .flex, status: 503, ttfbMs: 8, retries: 1, usedFallback: true, costUSD: 0.02))

        let summary = store.summary(since: .distantPast)
        #expect(summary.total == 3)
        #expect(summary.modelRequests == 2)
        #expect(summary.otherRequests == 1)
        #expect(summary.flexRequests == 1)
        #expect(summary.fallbackCount == 1)
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

    @Test func recordsEndpointTag() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try StatsStore(path: url.path)
        store.record(RequestRecord(
            time: Date(), path: "/api/v1/chat/completions", model: "deepseek/deepseek-v4.1-flash",
            sort: .smartPrice, tier: .auto, endpointTag: "deepinfra/fp8", status: 200, ttfbMs: 4,
            retries: 0))

        #expect(scalarText(url.path, sql: "SELECT endpoint_tag FROM requests LIMIT 1") == "deepinfra/fp8")
    }

    @Test func migratesEndpointsColumnOnAnOlderDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        writeLegacyDatabase(url.path)

        // Opening an older file must add the column without touching the existing rows.
        let store = try StatsStore(path: url.path)
        store.record(record(provider: "openai"))
        store.record(RequestRecord(
            time: Date(), path: "/api/v1/chat/completions", model: "m", sort: .smartPrice, tier: .auto,
            endpointTag: "deepinfra/fp8", status: 200, ttfbMs: 1, retries: 0))

        #expect(store.summary(since: .distantPast).total == 3) // legacy row + two new ones
        // The legacy row and the plain record have no tag; only the Smart-price row does.
        #expect(scalarText(url.path, sql: "SELECT COUNT(*) FROM requests WHERE endpoint_tag IS NOT NULL") == "1")
        #expect(scalarText(
            url.path, sql: "SELECT endpoint_tag FROM requests WHERE endpoint_tag IS NOT NULL")
            == "deepinfra/fp8")
    }
}
