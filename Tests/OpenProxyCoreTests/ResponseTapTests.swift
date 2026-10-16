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
