import Foundation
import SQLite3

public struct RequestRecord: Sendable {
    public var time: Date
    public var path: String
    public var model: String?
    public var sort: SortMode
    public var tier: TierMode
    public var actualTier: String?
    public var provider: String?
    public var status: Int
    public var ttfbMs: Int
    public var retries: Int
    public var usedFallback: Bool
    public var skippedReason: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var costUSD: Double?

    public init(
        time: Date, path: String, model: String? = nil, sort: SortMode, tier: TierMode,
        actualTier: String? = nil, provider: String? = nil, status: Int, ttfbMs: Int,
        retries: Int, usedFallback: Bool = false, skippedReason: String? = nil,
        promptTokens: Int? = nil, completionTokens: Int? = nil, costUSD: Double? = nil
    ) {
        self.time = time
        self.path = path
        self.model = model
        self.sort = sort
        self.tier = tier
        self.actualTier = actualTier
        self.provider = provider
        self.status = status
        self.ttfbMs = ttfbMs
        self.retries = retries
        self.usedFallback = usedFallback
        self.skippedReason = skippedReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.costUSD = costUSD
    }
}

public struct StatsSummary: Sendable {
    public var total: Int
    public var byProvider: [String: Int]
    public var byActualTier: [String: Int]
    public var fallbackCount: Int
    public var totalCostUSD: Double

    public init(
        total: Int = 0, byProvider: [String: Int] = [:], byActualTier: [String: Int] = [:],
        fallbackCount: Int = 0, totalCostUSD: Double = 0
    ) {
        self.total = total
        self.byProvider = byProvider
        self.byActualTier = byActualTier
        self.fallbackCount = fallbackCount
        self.totalCostUSD = totalCostUSD
    }
}

public enum StatsError: Error {
    case openFailed(String)
}

public final class StatsStore: @unchecked Sendable {
    private let db: OpaquePointer
    private let queue = DispatchQueue(label: "openproxy.stats")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            if let handle { sqlite3_close_v2(handle) }
            throw StatsError.openFailed(message)
        }
        self.db = handle
        do {
            try execute("""
                CREATE TABLE IF NOT EXISTS requests (
                    time REAL NOT NULL,
                    path TEXT NOT NULL,
                    model TEXT,
                    sort TEXT NOT NULL,
                    tier TEXT NOT NULL,
                    actual_tier TEXT,
                    provider TEXT,
                    status INTEGER NOT NULL,
                    ttfb_ms INTEGER NOT NULL,
                    retries INTEGER NOT NULL,
                    used_fallback INTEGER NOT NULL,
                    skipped_reason TEXT,
                    prompt_tokens INTEGER,
                    completion_tokens INTEGER,
                    cost_usd REAL
                )
                """)
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
    }

    deinit { sqlite3_close_v2(db) }

    /// Never throws to callers: a failed write is dropped.
    public func record(_ r: RequestRecord) {
        queue.sync { try? insert(r) }
    }

    public func summary(since: Date) -> StatsSummary {
        queue.sync { readSummary(since: since) }
    }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StatsError.openFailed(lastError)
        }
    }

    private func insert(_ r: RequestRecord) throws {
        let sql = """
            INSERT INTO requests
                (time, path, model, sort, tier, actual_tier, provider, status, ttfb_ms,
                 retries, used_fallback, skipped_reason, prompt_tokens, completion_tokens, cost_usd)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StatsError.openFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, r.time.timeIntervalSince1970)
        bindText(stmt, 2, r.path)
        bindText(stmt, 3, r.model)
        bindText(stmt, 4, r.sort.rawValue)
        bindText(stmt, 5, r.tier.rawValue)
        bindText(stmt, 6, r.actualTier)
        bindText(stmt, 7, r.provider)
        sqlite3_bind_int(stmt, 8, Int32(r.status))
        sqlite3_bind_int(stmt, 9, Int32(r.ttfbMs))
        sqlite3_bind_int(stmt, 10, Int32(r.retries))
        sqlite3_bind_int(stmt, 11, r.usedFallback ? 1 : 0)
        bindText(stmt, 12, r.skippedReason)
        bindInt(stmt, 13, r.promptTokens)
        bindInt(stmt, 14, r.completionTokens)
        if let cost = r.costUSD { sqlite3_bind_double(stmt, 15, cost) } else { sqlite3_bind_null(stmt, 15) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StatsError.openFailed(lastError)
        }
    }

    private func readSummary(since: Date) -> StatsSummary {
        let sinceValue = since.timeIntervalSince1970
        return StatsSummary(
            total: scalar("SELECT COUNT(*) FROM requests WHERE time >= ?1", sinceValue),
            byProvider: grouped(
                "SELECT provider, COUNT(*) FROM requests WHERE time >= ?1 AND provider IS NOT NULL GROUP BY provider",
                sinceValue),
            byActualTier: grouped(
                "SELECT actual_tier, COUNT(*) FROM requests WHERE time >= ?1 AND actual_tier IS NOT NULL GROUP BY actual_tier",
                sinceValue),
            fallbackCount: scalar(
                "SELECT COALESCE(SUM(used_fallback), 0) FROM requests WHERE time >= ?1", sinceValue),
            totalCostUSD: scalarDouble(
                "SELECT COALESCE(SUM(cost_usd), 0) FROM requests WHERE time >= ?1", sinceValue))
    }

    private func prepared(_ sql: String, since: Double) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        sqlite3_bind_double(stmt, 1, since)
        return stmt
    }

    private func scalar(_ sql: String, _ since: Double) -> Int {
        guard let stmt = prepared(sql, since: since) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func scalarDouble(_ sql: String, _ since: Double) -> Double {
        guard let stmt = prepared(sql, since: since) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_double(stmt, 0) : 0
    }

    private func grouped(_ sql: String, _ since: Double) -> [String: Int] {
        guard let stmt = prepared(sql, since: since) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var result: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let text = sqlite3_column_text(stmt, 0) else { continue }
            result[String(cString: text)] = Int(sqlite3_column_int64(stmt, 1))
        }
        return result
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, index, Int32(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
