import Foundation

public protocol EndpointsFetcher: Sendable {
    func fetch(modelId: String, authorization: String) async throws -> Data
}

public actor TierCatalog {
    private struct Entry {
        var availability: TierAvailability
        var fetchedAt: Date
    }

    private let fetcher: EndpointsFetcher
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [String: Entry] = [:]

    public init(
        fetcher: EndpointsFetcher,
        ttl: TimeInterval = 600,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fetcher = fetcher
        self.ttl = ttl
        self.now = now
    }

    /// nil when there is no usable Authorization header or the lookup fails (fail-open: no tier injection).
    public func availability(model: String, authorization: String?) async -> TierAvailability? {
        guard let authorization, !authorization.isEmpty else { return nil }

        let bare = Self.bareModel(model)
        if let entry = cache[bare], now().timeIntervalSince(entry.fetchedAt) < ttl {
            return entry.availability
        }

        guard let data = try? await fetcher.fetch(modelId: bare, authorization: authorization),
              let availability = Self.parseAvailability(data)
        else {
            return nil
        }
        cache[bare] = Entry(availability: availability, fetchedAt: now())
        return availability
    }

    /// Reads `data.endpoints[].service_tier`; nil when the payload has no `data.endpoints` array.
    public static func parseAvailability(_ json: Data) -> TierAvailability? {
        guard let object = try? JSONSerialization.jsonObject(with: json),
              let root = object as? [String: Any],
              let data = root["data"] as? [String: Any],
              let endpoints = data["endpoints"] as? [[String: Any]]
        else {
            return nil
        }

        var availability = TierAvailability(hasFlex: false, hasPriority: false)
        for endpoint in endpoints {
            switch endpoint["service_tier"] as? String {
            case "flex": availability.hasFlex = true
            case "priority": availability.hasPriority = true
            default: break
            }
        }
        return availability
    }

    private static func bareModel(_ model: String) -> String {
        model.split(separator: ":", maxSplits: 1).first.map(String.init) ?? model
    }
}
