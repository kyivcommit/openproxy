import Foundation
import Testing

@testable import OpenProxyCore

@Suite("EndpointRanking")
struct EndpointRankingTests {
    static func fixture() throws -> [Endpoint] {
        let url = try #require(
            Bundle.module.url(
                forResource: "deepseek-v4.1-flash-endpoints", withExtension: "json",
                subdirectory: "Fixtures"))
        return try #require(EndpointCatalog.parseEndpoints(try Data(contentsOf: url)))
    }

    func endpoint(
        _ tag: String, quant: String? = "fp8", tier: String? = nil,
        prompt: Double, completion: Double = 0, uptime: Double? = 100
    ) -> Endpoint {
        Endpoint(
            tag: tag, providerName: tag, quantization: quant, serviceTier: tier,
            promptUSDPerMillion: prompt, completionUSDPerMillion: completion, uptimeLast30m: uptime)
    }

    @Test func realFixturePicksCheapestNonQuantizedEndpoint() throws {
        let ranking = EndpointRanking.rank(endpoints: try Self.fixture(), tier: .auto)

        // The bug the feature fixes: OpenInference (fp4) is cheapest by input price alone.
        #expect(ranking.leader == "deepinfra/fp8")
        #expect(ranking.order.first == "deepinfra/fp8")
        #expect(!ranking.order.contains("open-inference/fp4"))
        #expect(!ranking.order.contains(where: { $0.hasSuffix("/fp4") }))
    }

    @Test func realFixtureFlexRanksOnlyFlexEndpoints() throws {
        let ranking = EndpointRanking.rank(endpoints: try Self.fixture(), tier: .flex)
        #expect(ranking.leader == "deepinfra/fp8/flex")
        #expect(ranking.order == ["deepinfra/fp8/flex"])
    }

    @Test func realFixturePriorityPrefersPriorityEndpoints() throws {
        let ranking = EndpointRanking.rank(endpoints: try Self.fixture(), tier: .priority)
        // baseten/fast is cheaper but reports 86.7% uptime, below the 90% floor.
        #expect(ranking.leader == "deepinfra/fp8/priority")
        #expect(ranking.order.first == "deepinfra/fp8/priority")
        #expect(!ranking.order.contains("baseten/fast"))
        // Standard endpoints follow the priority one.
        #expect(ranking.order.contains("deepinfra/fp8"))
    }

    @Test func defaultTierRanksStandardEndpointsOnly() throws {
        let ranking = EndpointRanking.rank(endpoints: try Self.fixture(), tier: .default)
        #expect(ranking.leader == "deepinfra/fp8")
    }

    @Test func excludedQuantizationsAreSkipped() {
        let endpoints = [
            endpoint("fp4", quant: "fp4", prompt: 0.01),
            endpoint("int4", quant: "int4", prompt: 0.01),
            endpoint("fp6", quant: "fp6", prompt: 0.01),
            endpoint("int8", quant: "int8", prompt: 0.01),
            endpoint("mxfp4", quant: "mxfp4", prompt: 0.01),
            endpoint("nvfp4", quant: "nvfp4", prompt: 0.01),
            endpoint("fp8", quant: "fp8", prompt: 1),
            endpoint("unknown", quant: "unknown", prompt: 2),
            endpoint("bf16", quant: "bf16", prompt: 3),
        ]
        let ranking = EndpointRanking.rank(endpoints: endpoints, tier: .auto)
        #expect(ranking.leader == "fp8")
        #expect(Set(ranking.order) == ["fp8", "unknown", "bf16"])
    }

    @Test func allowedQuantizationsConstant() {
        #expect(EndpointRanking.allowedQuantizations == ["bf16", "fp16", "fp32", "fp8", "unknown"])
    }

    @Test func lowUptimeExcludedButNullAllowed() {
        let endpoints = [
            endpoint("low", prompt: 0.01, uptime: 89.9),
            endpoint("atThreshold", prompt: 1, uptime: 90),
            endpoint("unknownUptime", prompt: 2, uptime: nil),
        ]
        let ranking = EndpointRanking.rank(endpoints: endpoints, tier: .auto)
        #expect(ranking.leader == "atThreshold") // cheaper of the two survivors by cost
        #expect(!ranking.order.contains("low"))
        #expect(ranking.order.contains("unknownUptime"))
    }

    @Test func costIsPromptPlusCompletion() {
        let endpoints = [
            endpoint("cheapInput", prompt: 0.1, completion: 5), // 5.1
            endpoint("cheapOutput", prompt: 1, completion: 1), // 2.0
        ]
        #expect(EndpointRanking.rank(endpoints: endpoints, tier: .auto).leader == "cheapOutput")
    }

    @Test func tiesBreakByUptimeThenTag() {
        let endpoints = [
            endpoint("b", prompt: 1, uptime: 100),
            endpoint("a", prompt: 1, uptime: 100),
            endpoint("high", prompt: 1, uptime: 99.5),
        ]
        // Same cost: higher uptime wins, then the tag.
        #expect(EndpointRanking.rank(endpoints: endpoints, tier: .auto).order == ["a", "b", "high"])
    }

    @Test func hysteresisKeepsLeaderWithinTenPercent() {
        // 8% cheaper: not enough, keep the incumbent first so its cache stays warm.
        let kept = EndpointRanking.rank(
            endpoints: [endpoint("incumbent", prompt: 1.0), endpoint("slightlyCheaper", prompt: 0.92)],
            tier: .auto, previousLeader: "incumbent")
        #expect(kept.leader == "incumbent")
        #expect(kept.order.first == "incumbent")

        // 11% cheaper: switch.
        let switched = EndpointRanking.rank(
            endpoints: [endpoint("incumbent", prompt: 1.0), endpoint("muchCheaper", prompt: 0.89)],
            tier: .auto, previousLeader: "incumbent")
        #expect(switched.leader == "muchCheaper")
        #expect(switched.order.first == "muchCheaper")
    }

    @Test func hysteresisSwitchesAtExactlyTenPercent() {
        let endpoints = [endpoint("incumbent", prompt: 1.0), endpoint("tenOff", prompt: 0.9)]
        let ranking = EndpointRanking.rank(
            endpoints: endpoints, tier: .auto, previousLeader: "incumbent")
        #expect(ranking.leader == "tenOff")
    }

    @Test func previousLeaderNotEligibleFallsBackToBest() {
        let endpoints = [
            endpoint("gone", quant: "fp4", prompt: 0.01),
            endpoint("best", prompt: 1),
        ]
        let ranking = EndpointRanking.rank(
            endpoints: endpoints, tier: .auto, previousLeader: "gone")
        #expect(ranking.leader == "best")
    }

    @Test func noEligibleEndpointYieldsEmptyRanking() {
        let endpoints = [endpoint("fp4", quant: "fp4", prompt: 0.01)]
        #expect(EndpointRanking.rank(endpoints: endpoints, tier: .auto) == Ranking())
        #expect(EndpointRanking.rank(endpoints: [], tier: .flex) == Ranking())
    }

    @Test func orderIsCappedAtFiveEndpoints() {
        let endpoints = (1...8).map { endpoint("e\($0)", prompt: Double($0)) }
        let ranking = EndpointRanking.rank(endpoints: endpoints, tier: .auto)
        #expect(ranking.order.count == 5)
        #expect(ranking.order.first == "e1")
    }
}
