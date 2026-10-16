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

    static func speedFixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "endpoints-with-speed", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// Unquantized by default: that is the only quantization Smart price keeps.
    func endpoint(
        _ tag: String, quant: String? = "unknown", tier: String? = nil,
        prompt: Double, completion: Double = 0, uptime: Double? = 100,
        uptime1d: Double? = nil, throughput: Double? = nil, latency: Double? = nil
    ) -> Endpoint {
        Endpoint(
            tag: tag, providerName: tag, quantization: quant, serviceTier: tier,
            promptUSDPerMillion: prompt, completionUSDPerMillion: completion,
            uptimeLast30m: uptime, uptimeLast1d: uptime1d,
            throughput: throughput, latency: latency)
    }

    @Test func realFixtureKeepsOnlyUnquantizedEndpoints() throws {
        let ranking = EndpointRanking.rank(endpoints: try Self.fixture(), tier: .auto)

        // Only endpoints with no declared precision stay; the fp8 providers are gone too.
        // The keyless fixture carries no speed, so the tie-break falls to 1d uptime then sum.
        #expect(ranking.leader == "deepseek")
        #expect(ranking.order.first == "deepseek")
        #expect(ranking.order == ["deepseek", "relace", "alibaba", "phala", "digitalocean"])
        #expect(!ranking.order.contains(where: { $0.contains("fp") || $0.contains("int") }))
    }

    @Test func syntheticFixtureBreaksCostTiesByThroughput() throws {
        // Equal cost key max(prompt, completion): Relace (155 tps) wins over Alibaba (116) and
        // DeepSeek (53), matching the screenshot order.
        let endpoints = try #require(EndpointCatalog.parseEndpoints(try Self.speedFixture()))
        let ranking = EndpointRanking.rank(endpoints: endpoints, tier: .auto)
        #expect(ranking.order == ["relace", "alibaba", "deepseek"])
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
        #expect(ranking.leader == "deepseek")
        #expect(!ranking.order.contains("deepinfra/fp8/priority"))
        #expect(!ranking.order.contains("baseten/fast"))
    }

    @Test func realFixtureDefaultMatchesAuto() throws {
        let ranking = EndpointRanking.rank(endpoints: try Self.fixture(), tier: .default)
        #expect(ranking.leader == "deepseek")
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

    @Test func tiesBreakByUptimeThenSumThenTag() {
        // No speed anywhere (keyless fetch): 1d uptime first, then the sum, then the tag.
        let endpoints = [
            endpoint("b", prompt: 1, uptime: 100), // key 1, uptime 100, sum 1
            endpoint("a", prompt: 1, uptime: 100), // key 1, uptime 100, sum 1
            endpoint("high", prompt: 1, uptime: 99.5), // key 1, lower uptime
            endpoint("lowerSum", prompt: 1, completion: 0.1), // key 1, uptime 100, sum 1.1
        ]
        #expect(EndpointRanking.rank(endpoints: endpoints, tier: .auto).order == ["a", "b", "lowerSum", "high"])
    }

    @Test func uptimeFallsBackTo30mWhen1dIsMissing() {
        let endpoints = [
            endpoint("recent1d", prompt: 1, uptime: 90, uptime1d: 99), // 1d wins
            endpoint("high30m", prompt: 1, uptime: 100), // fallback to 30m at 100
        ]
        #expect(EndpointRanking.rank(endpoints: endpoints, tier: .auto).order == ["high30m", "recent1d"])
    }

    @Test func speedTiesBreakByLatencyThenThroughput() {
        let endpoints = [
            endpoint("slow", prompt: 1, throughput: 100, latency: 2),
            endpoint("fast", prompt: 1, throughput: 100, latency: 0.5), // same throughput, lower latency
            endpoint("slower", prompt: 1, throughput: 50, latency: 0.1), // lowest latency but less throughput
        ]
        #expect(EndpointRanking.rank(endpoints: endpoints, tier: .auto).order == ["fast", "slow", "slower"])
    }

    @Test func mixedSpeedRowsSortMeasuredFirst() {
        let endpoints = [
            endpoint("keyless", prompt: 1, throughput: nil, latency: nil),
            endpoint("measured", prompt: 1, throughput: 10, latency: 5),
        ]
        // A keyless row has no speed but must not outrank a measured one on the speed criteria.
        #expect(EndpointRanking.rank(endpoints: endpoints, tier: .auto).order == ["measured", "keyless"])
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
