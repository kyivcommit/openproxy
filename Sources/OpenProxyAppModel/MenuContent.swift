import Foundation
import OpenProxyCore

/// One row of a menu section. `marker` becomes a ✓/✗/⚠︎/• prefix and `warning` an orange
/// title, so the NSMenu wiring stays thin and every string is unit-testable.
public struct MenuLine: Equatable, Sendable {
    public enum Marker: Equatable, Sendable {
        case none
        case check
        case cross
        case bullet
        case alert
    }

    public let text: String
    public let marker: Marker
    public let warning: Bool

    public init(_ text: String, marker: Marker = .none, warning: Bool = false) {
        self.text = text
        self.marker = marker
        self.warning = warning
    }
}

/// The pure content of the menu bar menus: every string and derived row, so the two NSMenus
/// are wiring only.
public enum MenuContent {
    /// The Node-env hint: install sets the variable for processes started afterwards.
    public static let nodeRestartHint =
        "Restart terminals and agents to pick up the CA."

    /// The checked set of poll-minute choices; a current value outside the presets is appended
    /// so it can still be shown as checked.
    public static func minuteChoices(current: Int) -> [Int] {
        choices(presets: [1, 5, 10, 15, 30, 60], current: current)
    }

    /// The checked set of flex timeout choices (seconds); same extra-item rule.
    public static func timeoutChoices(current: Double) -> [Double] {
        choices(presets: [5, 10, 20, 30, 60], current: current)
    }

    static func choices<T: Equatable>(presets: [T], current: T) -> [T] {
        presets.contains(current) ? presets : presets + [current]
    }

    // MARK: - Stats

    public static func statsLines(_ summary: StatsSummary) -> [MenuLine] {
        var lines = [
            MenuLine("Model requests: \(summary.modelRequests)"),
            MenuLine("Other requests: \(summary.otherRequests)"),
        ]
        if !summary.byProvider.isEmpty {
            lines.append(MenuLine("Providers"))
            for provider in topProviders(summary) {
                lines.append(MenuLine("• \(provider.name): \(provider.count)"))
            }
        }
        lines.append(MenuLine("Service tier used: \(serviceTiersUsed(summary))"))
        lines.append(MenuLine(fallbackLine(summary)))
        lines.append(MenuLine(String(format: "Cost: $%.4f", summary.totalCostUSD)))
        return lines
    }

    /// The top providers by request count; ties break by name so the order is stable.
    public static func topProviders(_ summary: StatsSummary, limit: Int = 5) -> [(name: String, count: Int)] {
        summary.byProvider
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { (name: $0.key, count: $0.value) }
    }

    /// Only the tiers OpenRouter actually served, in a fixed order; "none" when nothing was
    /// reported yet.
    public static func serviceTiersUsed(_ summary: StatsSummary) -> String {
        let tiers = ["flex", "priority", "default"]
            .compactMap { tier in summary.byActualTier[tier].map { "\(tier) \($0)" } }
        return tiers.isEmpty ? "none" : tiers.joined(separator: " · ")
    }

    public static func fallbackLine(_ summary: StatsSummary) -> String {
        guard summary.flexRequests > 0 else { return "Fallbacks: -" }
        return "Fallbacks: \(summary.fallbackCount) of \(summary.flexRequests) flex requests"
    }

    // MARK: - Status

    /// Distinguishes "not installed" from "present but not trusted" (the real-install bug:
    /// the certificate was in a keychain but its trust settings had not been applied).
    public static func caLine(_ status: InstallStatus) -> MenuLine {
        if status.caTrusted { return MenuLine("CA trusted", marker: .check) }
        if status.caPresent { return MenuLine("CA present but not trusted", marker: .cross, warning: true) }
        return MenuLine("CA not installed", marker: .cross)
    }

    public static func statusLines(
        _ status: InstallStatus,
        loginItem: LoginItemStatus,
        helper: HelperStatus,
        routingLabel: String
    ) -> [MenuLine] {
        var lines = [
            caLine(status),
            statusLine("Hosts entry", status.hostsEntry),
            statusLine("Port 443 listening", status.portListening),
        ]
        // A set variable pointing at a missing CA must not read as a clean check mark.
        if let note = status.nodeCAEnvNote {
            lines.append(MenuLine("Node CA env: \(note)"))
        } else {
            lines.append(statusLine("Node CA env", status.nodeCAEnv))
        }
        if status.nodeCAEnv {
            for part in wrapped(nodeRestartHint) { lines.append(MenuLine(part)) }
        }
        lines.append(MenuLine("Autostart: \(loginItem.label)"))
        lines.append(MenuLine("Hosts helper: \(helper.label)"))
        lines.append(MenuLine("Routing: \(routingLabel)"))
        return lines
    }

    private static func statusLine(_ label: String, _ ok: Bool) -> MenuLine {
        MenuLine(label, marker: ok ? .check : .cross)
    }

    // MARK: - Warnings

    /// The orange warning rows, in the menu's order: routing-broken, CA-untrusted, then the
    /// model's own warnings. Long messages wrap; only the first line carries the ⚠︎.
    public static func warningLines(
        unreachable: String?,
        untrustedCA: String?,
        warnings: [Warning]
    ) -> [MenuLine] {
        var lines: [MenuLine] = []
        for text in ([unreachable, untrustedCA].compactMap { $0 } + warnings.map(\.message)) {
            for (index, part) in wrapped(text).enumerated() {
                lines.append(MenuLine(part, marker: index == 0 ? .alert : .none, warning: true))
            }
        }
        return lines
    }

    /// Greedy word wrap for the disabled, non-scrolling menu rows, so no row grows the menu
    /// past roughly 300 pt at the menu font. Long words are kept whole.
    public static func wrapped(_ text: String, width: Int = 42) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            for word in paragraph.split(separator: " ") {
                if line.isEmpty {
                    line = String(word)
                } else if line.count + 1 + word.count <= width {
                    line += " " + word
                } else {
                    result.append(line)
                    line = String(word)
                }
            }
            result.append(line)
        }
        return result
    }
}
