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

    /// Unquantized by default: that is the only quantization Smart price keeps.
    func endpoint(
        _ tag: String, quant: String? = "unknown", tier: String? = nil,
        prompt: Double, completion: Double = 0, uptime: Double? = 100
    ) -> Endpoint {
        Endpoint(
            tag: tag, providerName: tag, quantization: quant, serviceTier: tier,
            promptUSDPerMillion: prompt, completionUSDPerMillion: completion, uptimeLast30m: uptime)
    }

    @Test func realFixtureKeepsOnlyUnquantizedEndpoints() throws {
        let ranking = EndpointRanking.rank(endpoints: try Self.fixture(), tier: .auto)

        // Only endpoints with no declared precision stay; the fp8 providers are gone too.
        #expect(ranking.leader == "alibaba")
        #expect(ranking.order.first == "alibaba")
        #expect(ranking.order == ["alibaba", "deepseek", "relace", "phala", "cloudflare"])
        #expect(!ranking.order.contains(where: { $0.contains("fp") || $0.contains("int") }))
    }

    @Test func realFixtureFlexHasNoEligibleEndpoint() throws {
        // The only flex endpoint is fp8, so Flex must fail open rather than route to it.
        let ranking = EndpointRanking.rank(endpoints: try Self.fixture(), tier: .flex)
        #expect(ranking == Ranking())
        #expect(ranking.leader == nil)
    }

    @Test func realFixturePriorityFallsBackToStandardEndpoints() throws {
        // The priority endpoints are fp8 / below the uptime floor, so only standard ones remain.
        let ranking = EndpointRanking.rank(endpoints: try Self.fixture(), tier: .priority)
        #expect(ranking.leader == "alibaba")
        #expect(!ranking.order.contains("deepinfra/fp8/priority"))
        #expect(!ranking.order.contains("baseten/fast"))
    }

    @Test func realFixtureDefaultMatchesAuto() throws {
        let ranking = EndpointRanking.rank(endpoints: try Self.fixture(), tier: .default)
        #expect(ranking.leader == "alibaba")
    }

    @Test func declaredPrecisionsAreSkipped() {
        let endpoints = [
            endpoint("fp4", quant: "fp4", prompt: 0.01),
            endpoint("int4", quant: "int4", prompt: 0.01),
            endpoint("fp6", quant: "fp6", prompt: 0.01),
            endpoint("int8", quant: "int8", prompt: 0.01),
            endpoint("mxfp4", quant: "mxfp4", prompt: 0.01),
            endpoint("nvfp4", quant: "nvfp4", prompt: 0.01),
            endpoint("fp8", quant: "fp8", prompt: 0.01),
            endpoint("bf16", quant: "bf16", prompt: 0.01),
            endpoint("nullQuant", quant: nil, prompt: 2),
            endpoint("unknown", quant: "unknown", prompt: 1),
        ]
        let ranking = EndpointRanking.rank(endpoints: endpoints, tier: .auto)
        #expect(ranking.leader == "unknown")
        #expect(Set(ranking.order) == ["unknown", "nullQuant"])
    }

    @Test func allowedQuantizationsConstant() {
        #expect(EndpointRanking.allowedQuantizations == ["unknown"])
    }

    @Test func lowUptimeExcludedButNullAllowed() {
        let endpoints = [
            endpoint("low", prompt: 0.01, uptime: 89.9),
            endpoint("atThreshold", prompt: 1, uptime: 90),
            endpoint("unknownUptime", prompt: 2, uptime: nil),
        ]
        let ranking = EndpointRanking.rank(endpoints: endpoints, tier: .auto)
        #expect(ranking.leader == "atThreshold") // cheaper of the two survivors by cost key
        #expect(!ranking.order.contains("low"))
        #expect(ranking.order.contains("unknownUptime"))
    }

    @Test func costKeyIsTheMoreExpensiveSide() {
        let endpoints = [
            endpoint("cheapInput", prompt: 0.1, completion: 5), // key 5
            endpoint("balanced", prompt: 1.5, completion: 2), // key 2
        ]
        #expect(EndpointRanking.rank(endpoints: endpoints, tier: .auto).leader == "balanced")
    }

    @Test func tiesBreakBySumThenUptimeThenTag() {
        let endpoints = [
            endpoint("b", prompt: 1, uptime: 100), // key 1, sum 1
            endpoint("a", prompt: 1, uptime: 100), // key 1, sum 1
            endpoint("high", prompt: 1, uptime: 99.5), // key 1, sum 1, lower uptime
            endpoint("lowerSum", prompt: 1, completion: 0.1), // same key 1, higher sum 1.1, appends last
        ]
        #expect(EndpointRanking.rank(endpoints: endpoints, tier: .auto).order == ["a", "b", "high", "lowerSum"])
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
