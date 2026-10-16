import Foundation

public struct RewriteResult: Sendable {
    public var body: Data
    public var model: String?
    public var wantsFlex: Bool
    public var applied: [String]
    public var skipped: [String: String]
    /// The Smart-price endpoint tag pinned for this request, when one was injected.
    public var endpointTag: String?

    public init(
        body: Data, model: String? = nil, wantsFlex: Bool = false,
        applied: [String] = [], skipped: [String: String] = [:], endpointTag: String? = nil
    ) {
        self.body = body
        self.model = model
        self.wantsFlex = wantsFlex
        self.applied = applied
        self.skipped = skipped
        self.endpointTag = endpointTag
    }
}

/// The `provider` policy the server computed for a Smart-price request. An empty `order`
/// means the ranking was unavailable; `unavailableReason` says why (fail-open).
public struct SmartPriceInjection: Sendable {
    public var order: [String]
    public var quantizations: [String]
    public var unavailableReason: String?

    public init(order: [String] = [], quantizations: [String] = [], unavailableReason: String? = nil) {
        self.order = order
        self.quantizations = quantizations
        self.unavailableReason = unavailableReason
    }
}

public enum Rewriter {
    public static let rewritablePaths: Set<String> = [
        "/api/v1/chat/completions",
        "/api/v1/responses",
        "/api/v1/messages",
    ]

    private static let sortSuffixes: [SortMode: String] = [
        .throughput: ":nitro",
        .price: ":floor",
        .exacto: ":exacto",
    ]

    public static func model(in body: Data) -> String? {
        parse(body)?["model"] as? String
    }

    public static func rewrite(
        path: String, body: Data, settings: Settings, availability: TierAvailability?,
        smartPrice: SmartPriceInjection? = nil
    ) -> RewriteResult {
        let parsed = parse(body)
        let model = parsed?["model"] as? String
        guard settings.enabled, rewritablePaths.contains(path), let model, var object = parsed else {
            return RewriteResult(body: body, model: model)
        }

        var applied: [String] = []
        var skipped: [String: String] = [:]
        var wantsFlex = false
        var endpointTag: String?

        if let suffix = sortSuffixes[settings.sort] {
            if model.contains(":") || model.hasPrefix("@preset/") {
                skipped["sort"] = "model_variant"
            } else if clientControlsProvider(object) {
                skipped["sort"] = "client_provider"
            } else {
                object["model"] = model + suffix
                applied.append("sort")
            }
        }

        // Smart price routes by an explicit endpoint order, so it adds no model suffix.
        if settings.sort == .smartPrice {
            if model.contains(":") || model.hasPrefix("@preset/") {
                skipped["provider"] = "model_variant"
            } else if clientControlsRouting(object) {
                skipped["provider"] = "client_provider"
            } else if let order = smartPrice?.order, !order.isEmpty {
                var provider = object["provider"] as? [String: Any] ?? [:]
                provider["order"] = order
                provider["quantizations"] = smartPrice?.quantizations ?? []
                // A client that explicitly set allow_fallbacks (even false) keeps its choice.
                if provider["allow_fallbacks"] == nil { provider["allow_fallbacks"] = true }
                object["provider"] = provider
                applied.append("provider")
                endpointTag = order.first
            } else {
                skipped["provider"] = smartPrice?.unavailableReason ?? "no_endpoint_data"
            }
        }

        // "speed" is a client policy field for the same slot, so it suppresses tier injection too.
        if settings.tier != .auto, object["service_tier"] != nil || object["speed"] != nil {
            skipped["service_tier"] = "client"
        } else {
            switch settings.tier {
            case .auto:
                break
            case .default:
                object["service_tier"] = "default"
                applied.append("service_tier")
            case .priority:
                if availability?.hasPriority == true {
                    object["service_tier"] = "priority"
                    applied.append("service_tier")
                } else {
                    skipped["service_tier"] = "unavailable"
                }
            case .flex:
                if availability?.hasFlex == true {
                    object["service_tier"] = "flex"
                    applied.append("service_tier")
                    wantsFlex = true
                } else {
                    skipped["service_tier"] = "unavailable"
                }
            }
        }

        guard !applied.isEmpty,
              let rewritten = try? JSONSerialization.data(withJSONObject: object) else {
            return RewriteResult(body: body, model: model, skipped: skipped)
        }
        return RewriteResult(
            body: rewritten, model: object["model"] as? String,
            wantsFlex: wantsFlex, applied: applied, skipped: skipped, endpointTag: endpointTag)
    }

    public static func stripServiceTier(from body: Data) -> Data {
        guard var object = parse(body), object["service_tier"] != nil else { return body }
        object.removeValue(forKey: "service_tier")
        return (try? JSONSerialization.data(withJSONObject: object)) ?? body
    }

    private static func parse(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func clientControlsProvider(_ object: [String: Any]) -> Bool {
        guard let provider = object["provider"] as? [String: Any] else { return false }
        return provider["order"] != nil || provider["sort"] != nil || provider["only"] != nil
    }

    /// Smart price also defers to a client `provider.quantizations`.
    private static func clientControlsRouting(_ object: [String: Any]) -> Bool {
        guard let provider = object["provider"] as? [String: Any] else { return false }
        return provider["quantizations"] != nil || clientControlsProvider(object)
    }
}
