import Foundation

public struct RewriteResult: Sendable {
    public var body: Data
    public var model: String?
    public var wantsFlex: Bool
    public var applied: [String]
    public var skipped: [String: String]

    public init(
        body: Data, model: String? = nil, wantsFlex: Bool = false,
        applied: [String] = [], skipped: [String: String] = [:]
    ) {
        self.body = body
        self.model = model
        self.wantsFlex = wantsFlex
        self.applied = applied
        self.skipped = skipped
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
        path: String, body: Data, settings: Settings, availability: TierAvailability?
    ) -> RewriteResult {
        let parsed = parse(body)
        let model = parsed?["model"] as? String
        guard settings.enabled, rewritablePaths.contains(path), let model, var object = parsed else {
            return RewriteResult(body: body, model: model)
        }

        var applied: [String] = []
        var skipped: [String: String] = [:]
        var wantsFlex = false

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
            wantsFlex: wantsFlex, applied: applied, skipped: skipped)
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
}
