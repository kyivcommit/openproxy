import Foundation

public protocol EndpointsFetcher: Sendable {
    /// `authorization` is the client's raw header value, or nil when the client sent none:
    /// the `/endpoints` call works without a key, so a missing header is not an error.
    func fetch(modelId: String, authorization: String?) async throws -> Data
}

/// One routable endpoint of a model, as `GET /api/v1/models/{id}/endpoints` reports it.
public struct Endpoint: Equatable, Sendable {
    /// The endpoint's routing slug (`provider[/variant][/region][/tier]`), the value
    /// `provider.order` accepts.
    public var tag: String
    public var providerName: String
    public var quantization: String?
    public var serviceTier: String?
    /// USD per million tokens.
    public var promptUSDPerMillion: Double
    public var completionUSDPerMillion: Double
    public var uptimeLast30m: Double?
    public var uptimeLast1d: Double?
    /// Output tokens per second (p50 of `throughput_last_30m`); nil unless the fetch carried a key.
    public var throughput: Double?
    /// Seconds to first token (p50 of `latency_last_30m`); nil unless the fetch carried a key.
    public var latency: Double?

    public init(
        tag: String, providerName: String = "", quantization: String? = nil,
        serviceTier: String? = nil, promptUSDPerMillion: Double = 0,
        completionUSDPerMillion: Double = 0, uptimeLast30m: Double? = nil,
        uptimeLast1d: Double? = nil, throughput: Double? = nil, latency: Double? = nil
    ) {
        self.tag = tag
        self.providerName = providerName
        self.quantization = quantization
        self.serviceTier = serviceTier
        self.promptUSDPerMillion = promptUSDPerMillion
        self.completionUSDPerMillion = completionUSDPerMillion
        self.uptimeLast30m = uptimeLast30m
        self.uptimeLast1d = uptimeLast1d
        self.throughput = throughput
        self.latency = latency
    }
}

/// Caches the parsed endpoint list per model (one cache, two consumers: the tier
/// availability check and the Smart-price ranking). Stale-while-revalidate: an entry
/// past its TTL is served at once and refreshed in the background; a cold miss fetches
/// once; a failed refresh keeps the stale data.
public actor EndpointCatalog {
    private struct Entry {
        var endpoints: [Endpoint]
        var fetchedAt: Date
        /// Whether the fetch carried a client key, i.e. whether the list has speed metrics.
        var fetchedWithAuthorization: Bool
    }

    private let fetcher: EndpointsFetcher
    /// TTL in seconds, read per lookup so a settings change applies without a restart.
    private let ttl: @Sendable () -> TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<[Endpoint]?, Never>] = [:]
    private var generation: [String: Int] = [:]
    /// The most recent client Authorization header seen, kept in memory only: never logged or
    /// persisted, and passed to the fetcher (which sends it only to openrouter.ai) so a later
    /// refresh can pull the speed metrics that need a key. Only the latest value is kept.
    private var latestAuthorization: String?
    /// When each model's keyless list was last refetched with a key, to cap that at once per TTL.
    private var speedRefreshedAt: [String: Date] = [:]

    public init(
        fetcher: EndpointsFetcher,
        ttl: @escaping @Sendable () -> TimeInterval = { 600 },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fetcher = fetcher
        self.ttl = ttl
        self.now = now
    }

    /// The model's endpoints, or nil when there is no data at all and the fetch failed.
    /// `authorization` is optional: the endpoints call needs no key, but when the client sent
    /// one it is remembered so the next refresh can fetch the keyed speed metrics.
    public func endpoints(model: String, authorization: String?) async -> [Endpoint]? {
        let bare = Self.bareModel(model)
        if let authorization = Self.nonEmpty(authorization) { latestAuthorization = authorization }
        let authorization = Self.nonEmpty(authorization) ?? latestAuthorization

        let cached = cache[bare]
        if let cached, now().timeIntervalSince(cached.fetchedAt) < ttl() {
            // A list fetched without a key is "stale for speed": now that a key is known,
            // refetch it in the background, at most once per TTL window per model.
            if !cached.fetchedWithAuthorization, authorization != nil,
               inFlight[bare] == nil, speedRefreshDue(bare) {
                speedRefreshedAt[bare] = now()
                _ = startFetch(bare, authorization: authorization)
            }
            return cached.endpoints
        }

        // A refresh is already running: serve stale data, or wait for the in-flight cold miss.
        if let task = inFlight[bare] {
            if let cached { return cached.endpoints }
            return await task.value
        }

        let task = startFetch(bare, authorization: authorization)
        // Stale-while-revalidate: hand back the old list at once and let the refresh land later.
        if let cached { return cached.endpoints }
        return await task.value
    }

    /// The key stays in memory for the process lifetime, so a client that drops the header for
    /// one request does not lose speed data on the next refresh.
    private func speedRefreshDue(_ bare: String) -> Bool {
        guard let last = speedRefreshedAt[bare] else { return true }
        return now().timeIntervalSince(last) >= ttl()
    }

    /// Starts one fetch and schedules its commit; the caller serves stale data or awaits the task.
    private func startFetch(_ bare: String, authorization: String?) -> Task<[Endpoint]?, Never> {
        let startedAt = now()
        let generation = (self.generation[bare] ?? 0) + 1
        self.generation[bare] = generation
        let fetcher = self.fetcher
        let task = Task { () -> [Endpoint]? in
            guard let data = try? await fetcher.fetch(modelId: bare, authorization: authorization) else {
                return nil
            }
            return Self.parseEndpoints(data)
        }
        inFlight[bare] = task
        // Commit on the actor, whether or not a caller is waiting: this is the
        // revalidation half of stale-while-revalidate.
        Task { [weak self] in
            let result = await task.value
            await self?.commit(
                bare, generation: generation, startedAt: startedAt,
                fetchedWithAuthorization: authorization != nil, endpoints: result)
        }
        return task
    }

    /// nil when there is no usable Authorization header or the lookup fails (fail-open: no tier injection).
    /// Kept as before for the tier logic even though the fetch itself needs no key.
    public func availability(model: String, authorization: String?) async -> TierAvailability? {
        guard let authorization, !authorization.isEmpty else { return nil }
        guard let list = await endpoints(model: model, authorization: authorization) else { return nil }
        return TierAvailability(
            hasFlex: list.contains { $0.serviceTier == "flex" },
            hasPriority: list.contains { $0.serviceTier == "priority" })
    }

    private func commit(
        _ bare: String, generation: Int, startedAt: Date,
        fetchedWithAuthorization: Bool, endpoints: [Endpoint]?
    ) {
        // A newer fetch for this model may have started while we awaited; only the latest result may land.
        guard self.generation[bare] == generation else { return }
        inFlight[bare] = nil
        if let endpoints {
            cache[bare] = Entry(
                endpoints: endpoints, fetchedAt: startedAt,
                fetchedWithAuthorization: fetchedWithAuthorization)
        }
    }

    private static func nonEmpty(_ authorization: String?) -> String? {
        guard let authorization, !authorization.isEmpty else { return nil }
        return authorization
    }

    /// Reads `data.endpoints[]`; nil when the payload has no `data.endpoints` array.
    public static func parseEndpoints(_ json: Data) -> [Endpoint]? {
        guard let object = try? JSONSerialization.jsonObject(with: json),
              let root = object as? [String: Any],
              let data = root["data"] as? [String: Any],
              let raw = data["endpoints"] as? [[String: Any]]
        else {
            return nil
        }
        return raw.map { endpoint in
            let pricing = endpoint["pricing"] as? [String: Any]
            return Endpoint(
                tag: endpoint["tag"] as? String ?? "",
                providerName: endpoint["provider_name"] as? String ?? "",
                quantization: endpoint["quantization"] as? String,
                serviceTier: endpoint["service_tier"] as? String,
                promptUSDPerMillion: Self.perMillion(pricing?["prompt"]),
                completionUSDPerMillion: Self.perMillion(pricing?["completion"]),
                uptimeLast30m: (endpoint["uptime_last_30m"] as? NSNumber)?.doubleValue,
                uptimeLast1d: (endpoint["uptime_last_1d"] as? NSNumber)?.doubleValue,
                throughput: Self.percentileValue(endpoint["throughput_last_30m"]),
                latency: Self.percentileValue(endpoint["latency_last_30m"]))
        }
    }

    /// Reads a speed metric that the API sends either as a plain number or as an object of
    /// percentiles (`{"p50": …}`); p50 wins when present. Latency and throughput are compared
    /// only across endpoints of the same response, so the doc's ms/seconds ambiguity cancels.
    private static func percentileValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["p50", "p75", "p90", "p99"] {
            if let number = object[key] as? NSNumber { return number.doubleValue }
        }
        return nil
    }

    /// Reads `data.endpoints[].service_tier`; nil when the payload has no `data.endpoints` array.
    public static func parseAvailability(_ json: Data) -> TierAvailability? {
        guard let endpoints = parseEndpoints(json) else { return nil }
        return TierAvailability(
            hasFlex: endpoints.contains { $0.serviceTier == "flex" },
            hasPriority: endpoints.contains { $0.serviceTier == "priority" })
    }

    /// The API reports prices as USD-per-token strings; callers want USD per million.
    private static func perMillion(_ value: Any?) -> Double {
        let perToken: Double
        if let string = value as? String {
            perToken = Double(string) ?? 0
        } else if let number = value as? NSNumber {
            perToken = number.doubleValue
        } else {
            perToken = 0
        }
        return perToken * 1_000_000
    }

    private static func bareModel(_ model: String) -> String {
        model.split(separator: ":", maxSplits: 1).first.map(String.init) ?? model
    }
}
