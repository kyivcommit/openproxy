import Foundation

extension Endpoint {
    /// What Smart price sorts by: the more expensive side (input or output), USD per million tokens.
    public var costKeyUSDPerMillion: Double { max(promptUSDPerMillion, completionUSDPerMillion) }

    /// Input plus output price; the first tie-break when the cost key is equal.
    public var combinedUSDPerMillion: Double { promptUSDPerMillion + completionUSDPerMillion }
}

public struct Ranking: Equatable, Sendable {
    /// Endpoint tags (routing slugs) to inject as `provider.order`, best first.
    public var order: [String]
    /// The chosen endpoint: the previous leader unless a new endpoint is at least 10% cheaper.
    public var leader: String?

    public init(order: [String] = [], leader: String? = nil) {
        self.order = order
        self.leader = leader
    }
}

/// Pure Smart-price ranking (design addendum steps 2–4): filter, group by tier, sort by
/// cost, then apply the per-model hysteresis. No I/O, so it is trivially testable.
public enum EndpointRanking {
    /// The only quantization Smart price keeps: an endpoint that is not quantized at all.
    /// Everything with a declared precision (fp4, fp8, fp16, bf16, …) trades quality for price.
    public static let allowedQuantizations = ["unknown"]

    /// An endpoint with a reported uptime below this is skipped; a null uptime is unknown, not bad.
    public static let minimumUptime = 90.0

    /// Most tags to inject; OpenRouter only needs the front of the list.
    private static let maxOrder = 5

    /// Keep the previous leader while the new best is less than 10% cheaper (protects prompt caching).
    private static let hysteresisFactor = 0.9

    public static func rank(
        endpoints: [Endpoint], tier: TierMode, previousLeader: String? = nil
    ) -> Ranking {
        let eligible = endpoints.filter(isEligible)
        // Tier groups, in try-order: Priority puts priority endpoints before the standard ones.
        let groups: [[Endpoint]] = switch tier {
        case .auto, .default: [eligible.filter { $0.serviceTier == nil }]
        case .priority: [
            eligible.filter { $0.serviceTier == "priority" },
            eligible.filter { $0.serviceTier == nil },
        ]
        case .flex: [eligible.filter { $0.serviceTier == "flex" }]
        }
        let ordered = groups.flatMap { $0.sorted(by: isCheaper) }
        guard let best = ordered.first else { return Ranking() }

        let leader: Endpoint
        if let previousLeader,
           let previous = ordered.first(where: { $0.tag == previousLeader }),
           best.costKeyUSDPerMillion > previous.costKeyUSDPerMillion * hysteresisFactor {
            leader = previous
        } else {
            leader = best
        }

        let rest = ordered.filter { $0.tag != leader.tag }
        let order = ([leader] + rest).prefix(maxOrder).map(\.tag)
        return Ranking(order: Array(order), leader: leader.tag)
    }

    static func isEligible(_ endpoint: Endpoint) -> Bool {
        guard !endpoint.tag.isEmpty else { return false }
        // Only endpoints with no declared precision stay; "unknown" (or absent) means unquantized.
        let quantization = endpoint.quantization?.lowercased()
        guard quantization == nil || quantization == "unknown" else { return false }
        if let uptime = endpoint.uptimeLast30m, uptime < minimumUptime { return false }
        return true
    }

    /// Cost key ascending; ties: lower input+output, then higher uptime, then tag.
    static func isCheaper(_ a: Endpoint, _ b: Endpoint) -> Bool {
        if a.costKeyUSDPerMillion != b.costKeyUSDPerMillion {
            return a.costKeyUSDPerMillion < b.costKeyUSDPerMillion
        }
        if a.combinedUSDPerMillion != b.combinedUSDPerMillion {
            return a.combinedUSDPerMillion < b.combinedUSDPerMillion
        }
        let aUptime = a.uptimeLast30m ?? 0
        let bUptime = b.uptimeLast30m ?? 0
        if aUptime != bUptime { return aUptime > bUptime }
        return a.tag < b.tag
    }
}
