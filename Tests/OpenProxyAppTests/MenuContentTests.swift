import Foundation
import Testing
import OpenProxyCore
@testable import OpenProxyAppModel

@Suite
struct MenuContentTests {
    private func summary(
        modelRequests: Int = 0, otherRequests: Int = 0,
        byProvider: [String: Int] = [:], byActualTier: [String: Int] = [:],
        flexRequests: Int = 0, fallbackCount: Int = 0, totalCostUSD: Double = 0
    ) -> StatsSummary {
        StatsSummary(
            modelRequests: modelRequests, otherRequests: otherRequests,
            byProvider: byProvider, byActualTier: byActualTier,
            flexRequests: flexRequests, fallbackCount: fallbackCount,
            totalCostUSD: totalCostUSD)
    }

    private func status(
        caTrusted: Bool = false, caPresent: Bool = false, hostsEntry: Bool = false,
        portListening: Bool = false, nodeCAEnv: Bool = false
    ) -> InstallStatus {
        InstallStatus(
            caTrusted: caTrusted, caPresent: caPresent, hostsEntry: hostsEntry,
            portListening: portListening, nodeCAEnv: nodeCAEnv)
    }

    @Test func statsLinesCarryCountsTierFallbacksAndCost() {
        let lines = MenuContent.statsLines(summary(
            modelRequests: 12, otherRequests: 3,
            byActualTier: ["default": 4], flexRequests: 5, fallbackCount: 2,
            totalCostUSD: 0.123456))

        #expect(lines.map(\.text) == [
            "Model requests: 12",
            "Other requests: 3",
            "Service tier used: default 4",
            "Fallbacks: 2 of 5 flex requests",
            "Cost: $0.1235",
        ])
        #expect(lines.allSatisfy { $0.marker == .none })
    }

    @Test func statsLinesOmitTheProvidersSectionWhenEmpty() {
        let lines = MenuContent.statsLines(summary())
        #expect(!lines.contains { $0.text == "Providers" })
        #expect(lines.map(\.text).contains("Fallbacks: -"))
    }

    @Test func topProvidersKeepsTheFiveHighestAndBreaksTiesByName() {
        let summary = summary(byProvider: [
            "e": 1, "b": 9, "a": 9, "f": 2, "c": 8, "d": 3,
        ])

        #expect(MenuContent.topProviders(summary).map { "\($0.name):\($0.count)" }
            == ["a:9", "b:9", "c:8", "d:3", "f:2"])
    }

    @Test func providersRowsAreListedUnderTheHeaderInTopOrder() {
        let lines = MenuContent.statsLines(summary(byProvider: ["zai": 4, "openai": 7]))

        #expect(lines.map(\.text) == [
            "Model requests: 0",
            "Other requests: 0",
            "Providers",
            "• openai: 7",
            "• zai: 4",
            "Service tier used: none",
            "Fallbacks: -",
            "Cost: $0.0000",
        ])
    }

    @Test func serviceTiersUseAFixedOrderAndNoneWhenAbsent() {
        #expect(MenuContent.serviceTiersUsed(summary(byActualTier: [
            "default": 1, "flex": 2, "priority": 3,
        ])) == "flex 2 · priority 3 · default 1")
        #expect(MenuContent.serviceTiersUsed(summary()) == "none")
    }

    @Test func fallbackLineIsADashWithoutFlexRequests() {
        #expect(MenuContent.fallbackLine(summary()) == "Fallbacks: -")
        #expect(MenuContent.fallbackLine(summary(flexRequests: 4, fallbackCount: 1))
            == "Fallbacks: 1 of 4 flex requests")
    }

    @Test func caLineCoversTrustedPresentUntrustedAndMissing() {
        #expect(MenuContent.caLine(status(caTrusted: true))
            == MenuLine("CA trusted", marker: .check))
        #expect(MenuContent.caLine(status(caPresent: true))
            == MenuLine("CA present but not trusted", marker: .cross, warning: true))
        #expect(MenuContent.caLine(status())
            == MenuLine("CA not installed", marker: .cross))
    }

    @Test func statusLinesMarkTheRuntimeChecks() {
        let lines = MenuContent.statusLines(
            status(caTrusted: true, hostsEntry: true, portListening: false),
            loginItem: .enabled, helper: .notRegistered, routingLabel: "active")

        #expect(lines.map(\.text) == [
            "CA trusted",
            "Hosts entry",
            "Port 443 listening",
            "Node CA env",
            "Autostart: enabled",
            "Hosts helper: not installed",
            "Routing: active",
        ])
        #expect(lines.map(\.marker) == [.check, .check, .cross, .cross, .none, .none, .none])
    }

    @Test func nodeCAEnvSetWithMissingCAReadsAsANoteAndStillHintsAtRestart() {
        let lines = MenuContent.statusLines(
            status(caPresent: false, nodeCAEnv: true),
            loginItem: .notRegistered, helper: .notFound, routingLabel: "inactive")

        #expect(lines.contains(MenuLine("Node CA env: set (CA not installed)")))
        // Install sets the variable for later processes; the hint follows the variable, not the CA.
        #expect(lines.contains(MenuLine(MenuContent.nodeRestartHint)))
    }

    @Test func nodeCAEnvSetWithTheCAInstalledAddsTheRestartHint() {
        let lines = MenuContent.statusLines(
            status(caTrusted: true, caPresent: true, nodeCAEnv: true),
            loginItem: .enabled, helper: .enabled, routingLabel: "active")

        #expect(lines.contains(MenuLine("Node CA env", marker: .check)))
        #expect(lines.contains(MenuLine(MenuContent.nodeRestartHint)))
    }

    @Test func minuteChoicesKeepPresetsAndAppendANonPresetCurrent() {
        #expect(MenuContent.minuteChoices(current: 10) == [1, 5, 10, 15, 30, 60])
        #expect(MenuContent.minuteChoices(current: 7) == [1, 5, 10, 15, 30, 60, 7])
    }

    @Test func timeoutChoicesKeepPresetsAndAppendANonPresetCurrent() {
        #expect(MenuContent.timeoutChoices(current: 30) == [5, 10, 20, 30, 60])
        #expect(MenuContent.timeoutChoices(current: 12.5) == [5, 10, 20, 30, 60, 12.5])
    }

    @Test func warningLinesOrderAndMarkOnlyTheFirstWrappedLine() {
        let long = String(repeating: "word ", count: 20).trimmingCharacters(in: .whitespaces)
        let lines = MenuContent.warningLines(
            unreachable: "routed to a dead proxy",
            untrustedCA: "CA not trusted",
            warnings: [Warning(key: .install, message: long)])

        #expect(lines[0] == MenuLine("routed to a dead proxy", marker: .alert, warning: true))
        #expect(lines[1] == MenuLine("CA not trusted", marker: .alert, warning: true))
        #expect(lines[2].marker == .alert)
        #expect(lines[2].warning)
        #expect(lines[2].text.hasPrefix("word word"))
        #expect(lines[3].marker == .none)
        #expect(lines[3].warning)
        #expect(lines.allSatisfy { $0.text.count <= 60 })
    }

    @Test func wrappedBreaksOnWidthAndKeepsLongWordsWhole() {
        #expect(MenuContent.wrapped("one two three four", width: 7) == ["one two", "three", "four"])
        #expect(MenuContent.wrapped("averyverylongword short", width: 5)
            == ["averyverylongword", "short"])
        #expect(MenuContent.wrapped("first\nsecond", width: 60) == ["first", "second"])
        #expect(MenuContent.wrapped("") == [])
    }
}
