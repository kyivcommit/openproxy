import Foundation
import Testing

@testable import OpenProxyCore

@Suite("ResponseTap")
struct ResponseTapTests {
    @Test func anthropicStyleUsageTokensAreMapped() {
        let usage: [String: Any] = ["input_tokens": 11, "output_tokens": 5, "cost": 0.001]
        let facts = ResponseTap.facts(from: ["usage": usage])
        #expect(facts.promptTokens == 11)
        #expect(facts.completionTokens == 5)
        #expect(facts.costUSD == 0.001)
    }

    @Test func topLevelModelIsParsed() {
        let facts = ResponseTap.facts(from: ["model": "deepseek/deepseek-v4.1-flash-20261017"])
        #expect(facts.model == "deepseek/deepseek-v4.1-flash-20261017")
    }

    @Test func streamedModelSurvivesLaterChunks() {
        let tap = ResponseTap(streaming: true)
        tap.consume(Data("data: {\"model\":\"x/y-2026\"}\n\n".utf8))
        tap.consume(Data("data: {\"usage\":{\"cost\":0.002}}\n\n".utf8))
        let facts = tap.finish()
        #expect(facts.model == "x/y-2026")
        #expect(facts.costUSD == 0.002)
    }

    @Test func nonStreamingModelIsParsedOnFinish() {
        let tap = ResponseTap(streaming: false)
        tap.consume(Data(#"{"model":"x/y-2026"}"#.utf8))
        #expect(tap.finish().model == "x/y-2026")
    }

    @Test func openAIStyleTokensTakePrecedence() {
        let usage: [String: Any] = [
            "prompt_tokens": 3, "completion_tokens": 4,
            "input_tokens": 99, "output_tokens": 98,
        ]
        let facts = ResponseTap.facts(from: ["usage": usage])
        #expect(facts.promptTokens == 3)
        #expect(facts.completionTokens == 4)
    }
}
