import Foundation
import Testing

@testable import OpenProxyCore

@Suite("AliasResolver")
struct AliasResolverTests {
    @Test func learnedAliasResolves() async {
        let resolver = AliasResolver()
        #expect(await resolver.resolve("~deepseek/deepseek-flash-latest") == nil)
        await resolver.learn(
            alias: "~deepseek/deepseek-flash-latest",
            concrete: "deepseek/deepseek-v4.1-flash-20261017")
        #expect(
            await resolver.resolve("~deepseek/deepseek-flash-latest")
                == "deepseek/deepseek-v4.1-flash-20261017")
    }

    @Test func nonAliasIdsNeverResolve() async {
        let resolver = AliasResolver()
        await resolver.learn(alias: "deepseek/deepseek-flash-latest", concrete: "x/y-2026")
        #expect(await resolver.resolve("deepseek/deepseek-flash-latest") == nil)
    }

    @Test func emptyOrSelfValuesAreIgnored() async {
        let resolver = AliasResolver()
        await resolver.learn(alias: "~a", concrete: "")
        await resolver.learn(alias: "~b", concrete: "~b")
        #expect(await resolver.resolve("~a") == nil)
        #expect(await resolver.resolve("~b") == nil)
    }

    @Test func entriesAreBounded() async {
        let resolver = AliasResolver()
        for index in 0..<100 { await resolver.learn(alias: "~m\(index)", concrete: "vendor/m\(index)") }
        #expect(await resolver.resolve("~m99") == "vendor/m99")
        #expect(await resolver.resolve("~m36") == "vendor/m36")
        #expect(await resolver.resolve("~m35") == nil)  // oldest entries dropped
    }
}
