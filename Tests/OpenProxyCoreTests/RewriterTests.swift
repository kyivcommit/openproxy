import Foundation
import Testing

@testable import OpenProxyCore

private let chatPath = "/api/v1/chat/completions"

private func encode(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func decode(_ data: Data) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}

private func payload(model: String = "openai/gpt-5", extra: [String: Any] = [:]) -> Data {
    var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "hi"]]]
    body.merge(extra) { _, new in new }
    return encode(body)
}

private let fullAvailability = TierAvailability(hasFlex: true, hasPriority: true)

private let smartInjection = SmartPriceInjection(
    order: ["deepinfra/fp8", "atlas-cloud/fp8"], quantizations: EndpointRanking.allowedQuantizations)

@Suite("Rewriter")
struct RewriterTests {
    @Test func rewritablePathsMatchSpec() {
        #expect(Rewriter.rewritablePaths == [
            "/api/v1/chat/completions",
            "/api/v1/responses",
            "/api/v1/messages",
        ])
    }

    @Test(arguments: SortMode.allCases, TierMode.allCases)
    func appliesSortAndTierMatrix(sort: SortMode, tier: TierMode) {
        let result = Rewriter.rewrite(
            path: chatPath,
            body: payload(),
            settings: Settings(sort: sort, tier: tier),
            availability: fullAvailability,
            smartPrice: smartInjection)

        let suffix = switch sort {
        case .balanced: ""
        case .throughput: ":nitro"
        case .price: ":floor"
        case .exacto: ":exacto"
        case .smartPrice: ""
        }
        let expectedModel = "openai/gpt-5" + suffix
        let expectedTier: String? = switch tier {
        case .auto: nil
        case .default: "default"
        case .priority: "priority"
        case .flex: "flex"
        }

        let body = decode(result.body)
        #expect(body["model"] as? String == expectedModel)
        #expect(result.model == expectedModel)
        #expect(body["service_tier"] as? String == expectedTier)
        #expect(result.wantsFlex == (tier == .flex))
        #expect(result.applied.contains("sort") == !suffix.isEmpty)
        #expect(result.applied.contains("service_tier") == (expectedTier != nil))
        #expect(result.skipped.isEmpty)
    }

    @Test(arguments: [SortMode.throughput, .price, .exacto])
    func noSuffixWhenModelHasVariant(sort: SortMode) {
        for model in ["openai/gpt-5:nitro", "openai/gpt-5:floor", "openai/gpt-5:free"] {
            let input = payload(model: model)
            let result = Rewriter.rewrite(
                path: chatPath, body: input,
                settings: Settings(sort: sort, tier: .auto), availability: fullAvailability)
            #expect(decode(result.body)["model"] as? String == model)
            #expect(!result.applied.contains("sort"))
            #expect(result.skipped["sort"] != nil)
        }
    }

    @Test func noSuffixWhenModelIsPreset() {
        let model = "@preset/large-context"
        let result = Rewriter.rewrite(
            path: chatPath, body: payload(model: model),
            settings: Settings(sort: .price, tier: .auto), availability: fullAvailability)
        #expect(decode(result.body)["model"] as? String == model)
        #expect(!result.applied.contains("sort"))
        #expect(result.skipped["sort"] != nil)
    }

    @Test func balancedAndAutoLeavesBodyByteIdentical() {
        let input = payload()
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .balanced, tier: .auto), availability: fullAvailability)
        #expect(result.body == input)
        #expect(result.applied.isEmpty)
        #expect(result.skipped.isEmpty)
    }

    @Test func defaultTierInjectsWithoutAvailability() {
        let result = Rewriter.rewrite(
            path: chatPath, body: payload(),
            settings: Settings(tier: .default), availability: nil)
        #expect(decode(result.body)["service_tier"] as? String == "default")
        #expect(result.applied.contains("service_tier"))
        #expect(!result.wantsFlex)
    }

    @Test func prioritySkippedWhenUnavailable() {
        for availability in [nil, TierAvailability(hasFlex: true, hasPriority: false)] {
            let input = payload()
            let result = Rewriter.rewrite(
                path: chatPath, body: input,
                settings: Settings(tier: .priority), availability: availability)
            #expect(result.body == input)
            #expect(result.skipped["service_tier"] != nil)
            #expect(!result.applied.contains("service_tier"))
        }
    }

    @Test func flexSkippedWhenUnavailable() {
        for availability in [nil, TierAvailability(hasFlex: false, hasPriority: true)] {
            let input = payload()
            let result = Rewriter.rewrite(
                path: chatPath, body: input,
                settings: Settings(tier: .flex), availability: availability)
            #expect(result.body == input)
            #expect(result.skipped["service_tier"] != nil)
            #expect(!result.wantsFlex)
        }
    }

    @Test func clientServiceTierSuppressesInjection() {
        let input = payload(extra: ["service_tier": "priority"])
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(tier: .flex), availability: fullAvailability)
        #expect(decode(result.body)["service_tier"] as? String == "priority")
        #expect(result.skipped["service_tier"] != nil)
        #expect(!result.wantsFlex)
    }

    @Test func clientSpeedSuppressesInjection() {
        let input = payload(extra: ["speed": 1.5])
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(tier: .default), availability: fullAvailability)
        #expect(decode(result.body)["service_tier"] == nil)
        #expect(result.skipped["service_tier"] != nil)
    }

    @Test(arguments: ["order", "sort", "only"])
    func clientProviderKeysSuppressSortSuffix(key: String) {
        let input = payload(extra: ["provider": [key: key == "only" ? ["A"] : "x"]])
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .throughput, tier: .auto), availability: fullAvailability)
        #expect(decode(result.body)["model"] as? String == "openai/gpt-5")
        #expect(result.skipped["sort"] != nil)
    }

    @Test func otherProviderKeysDoNotSuppressSortSuffix() {
        let input = payload(extra: ["provider": ["allow_fallbacks": false]])
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .throughput, tier: .auto), availability: fullAvailability)
        #expect(decode(result.body)["model"] as? String == "openai/gpt-5:nitro")
    }

    @Test func disabledReturnsBodyByteIdentical() {
        let input = payload()
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(enabled: false, sort: .throughput, tier: .flex),
            availability: fullAvailability)
        #expect(result.body == input)
        #expect(result.model == "openai/gpt-5")
        #expect(result.applied.isEmpty)
    }

    @Test func nonRewritablePathReturnsBodyByteIdentical() {
        let input = payload()
        for path in ["/api/v1/models", "/api/v1/chat/completions/extra", "/", "/api/v1/messages/x"] {
            let result = Rewriter.rewrite(
                path: path, body: input,
                settings: Settings(sort: .throughput, tier: .flex), availability: fullAvailability)
            #expect(result.body == input)
            #expect(result.applied.isEmpty)
        }
    }

    @Test func emptyBodyUnchanged() {
        let result = Rewriter.rewrite(
            path: chatPath, body: Data(),
            settings: Settings(sort: .throughput, tier: .flex), availability: fullAvailability)
        #expect(result.body == Data())
        #expect(result.model == nil)
    }

    @Test func nonJSONBodyUnchanged() {
        let input = Data("not json at all".utf8)
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .throughput, tier: .flex), availability: fullAvailability)
        #expect(result.body == input)
        #expect(result.model == nil)
    }

    @Test func jsonWithoutModelUnchanged() {
        let input = encode(["messages": [["role": "user", "content": "hi"]]])
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .throughput, tier: .flex), availability: fullAvailability)
        #expect(result.body == input)
        #expect(result.model == nil)
    }

    @Test func jsonArrayBodyUnchanged() {
        let input = Data("[1,2,3]".utf8)
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .throughput, tier: .flex), availability: fullAvailability)
        #expect(result.body == input)
        #expect(result.model == nil)
    }

    @Test func nonStringModelUnchanged() {
        let input = encode(["model": 5])
        #expect(Rewriter.model(in: input) == nil)
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .throughput, tier: .flex), availability: fullAvailability)
        #expect(result.body == input)
    }

    @Test func modelReadsStringModel() {
        #expect(Rewriter.model(in: payload(model: "anthropic/claude-4")) == "anthropic/claude-4")
    }

    @Test func preservesOtherFieldsAndContent() {
        let input = payload(model: "openai/gpt-5", extra: [
            "temperature": 0.7,
            "tools": [["type": "function", "function": ["name": "get_weather"]]],
            "metadata": ["session": "abc"],
        ])
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .throughput, tier: .flex), availability: fullAvailability)
        let body = decode(result.body)
        #expect(body["temperature"] as? Double == 0.7)
        #expect(body["metadata"] as? [String: String] == ["session": "abc"])
        #expect((body["messages"] as? [[String: Any]])?.count == 1)
        let tools = body["tools"] as? [[String: Any]]
        #expect((tools?.first?["function"] as? [String: Any])?["name"] as? String == "get_weather")
    }

    @Test func stripServiceTierRemovesOnlyThatKey() {
        let input = payload(model: "openai/gpt-5:nitro", extra: ["service_tier": "flex", "temperature": 0.2])
        let stripped = decode(Rewriter.stripServiceTier(from: input))
        #expect(stripped["service_tier"] == nil)
        #expect(stripped["model"] as? String == "openai/gpt-5:nitro")
        #expect(stripped["temperature"] as? Double == 0.2)
    }

    @Test func stripServiceTierLeavesBodyWithoutKeyUnchanged() {
        let input = payload()
        #expect(Rewriter.stripServiceTier(from: input) == input)
    }

    @Test func stripServiceTierOnInvalidJSONReturnsInput() {
        let input = Data("not json".utf8)
        #expect(Rewriter.stripServiceTier(from: input) == input)
    }

    // MARK: - Smart price

    @Test func smartPriceInjectsProviderOrderAndNoSuffix() {
        let result = Rewriter.rewrite(
            path: chatPath, body: payload(),
            settings: Settings(sort: .smartPrice, tier: .auto), availability: nil,
            smartPrice: smartInjection)

        let body = decode(result.body)
        #expect(body["model"] as? String == "openai/gpt-5")
        let provider = body["provider"] as? [String: Any]
        #expect(provider?["order"] as? [String] == ["deepinfra/fp8", "atlas-cloud/fp8"])
        #expect(provider?["quantizations"] as? [String] == EndpointRanking.allowedQuantizations)
        #expect(provider?["allow_fallbacks"] as? Bool == true)
        #expect(result.endpointTag == "deepinfra/fp8")
        #expect(result.applied.contains("provider"))
        #expect(result.skipped.isEmpty)
    }

    @Test func smartPriceKeepsOtherProviderFields() {
        let input = payload(extra: ["provider": ["data_collection": "deny"]])
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .smartPrice, tier: .auto), availability: nil,
            smartPrice: smartInjection)

        let provider = decode(result.body)["provider"] as? [String: Any]
        #expect(provider?["data_collection"] as? String == "deny")
        #expect(provider?["order"] != nil)
    }

    @Test func smartPriceKeepsClientAllowFallbacksFalse() {
        let input = payload(extra: ["provider": ["allow_fallbacks": false]])
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .smartPrice, tier: .auto), availability: nil,
            smartPrice: smartInjection)

        let provider = decode(result.body)["provider"] as? [String: Any]
        #expect(provider?["allow_fallbacks"] as? Bool == false)
        #expect(provider?["order"] != nil)
    }

    @Test(arguments: ["order", "sort", "only", "quantizations"])
    func smartPriceDefersToClientRoutingKeys(key: String) {
        let value: Any = (key == "sort") ? "price" : ["provider-a"]
        let input = payload(extra: ["provider": [key: value]])
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .smartPrice, tier: .auto), availability: nil,
            smartPrice: smartInjection)

        #expect(result.body == input) // untouched
        #expect(result.skipped["provider"] == "client_provider")
        #expect(result.endpointTag == nil)
        #expect(!result.applied.contains("provider"))
    }

    @Test(arguments: ["openai/gpt-5:nitro", "openai/gpt-5:free", "@preset/large-context"])
    func smartPriceSkipsModelWithVariantOrPreset(model: String) {
        let input = payload(model: model)
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .smartPrice, tier: .auto), availability: nil,
            smartPrice: smartInjection)

        #expect(result.body == input)
        #expect(result.skipped["provider"] == "model_variant")
        #expect(result.endpointTag == nil)
    }

    @Test func smartPriceFailOpenWhenNoEndpointData() {
        let input = payload()
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .smartPrice, tier: .auto), availability: nil,
            smartPrice: SmartPriceInjection(unavailableReason: "no_endpoint_data"))

        #expect(result.body == input)
        #expect(result.skipped["provider"] == "no_endpoint_data")
    }

    @Test func smartPriceFailOpenWhenNoEligibleEndpoint() {
        let input = payload()
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .smartPrice, tier: .auto), availability: nil,
            smartPrice: SmartPriceInjection(unavailableReason: "no_eligible_endpoint"))

        #expect(result.body == input)
        #expect(result.skipped["provider"] == "no_eligible_endpoint")
    }

    @Test func smartPriceWithoutInjectionRecordsNoEndpointData() {
        let input = payload()
        let result = Rewriter.rewrite(
            path: chatPath, body: input,
            settings: Settings(sort: .smartPrice, tier: .auto), availability: nil)

        #expect(result.body == input)
        #expect(result.skipped["provider"] == "no_endpoint_data")
    }

    @Test func smartPriceStillAppliesTier() {
        let result = Rewriter.rewrite(
            path: chatPath, body: payload(),
            settings: Settings(sort: .smartPrice, tier: .flex), availability: fullAvailability,
            smartPrice: smartInjection)

        let body = decode(result.body)
        #expect(body["service_tier"] as? String == "flex")
        #expect(body["provider"] != nil)
        #expect(result.wantsFlex)
    }

    @Test func smartPriceDoesNotSuppressSuffixSortsCase() {
        // Smart price is not a suffix mode: even the retry body keeps no `:floor`.
        let result = Rewriter.rewrite(
            path: chatPath, body: payload(),
            settings: Settings(sort: .price, tier: .auto), availability: nil,
            smartPrice: smartInjection)
        #expect(decode(result.body)["model"] as? String == "openai/gpt-5:floor")
        #expect(decode(result.body)["provider"] == nil)
    }
}
