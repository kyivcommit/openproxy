import SwiftUI
import OpenProxyCore
import OpenProxyAppModel

struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enabled", isOn: $model.settings.enabled)

            Picker("Sort", selection: $model.settings.sort) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }

            Picker("Tier", selection: $model.settings.tier) {
                ForEach(TierMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }

            if model.settings.tier == .flex {
                flexSection
            }

            Divider()
            statsBlock
            Divider()
            statusBlock
            if let unreachable = model.unreachableWarning {
                Divider()
                unreachableBlock(unreachable)
            }
            if let untrustedCA = model.untrustedCAWarning {
                Divider()
                unreachableBlock(untrustedCA)
            }
            if !model.warnings.isEmpty {
                Divider()
                warningBlock
            }

            Divider()
            HStack {
                Button("Install") { Task { await model.install() } }
                Button("Uninstall") { Task { await model.uninstall() } }
                Spacer()
                Button("Quit") { Task { await model.quit() } }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.menuVisibilityChanged(true) }
        .onDisappear { model.menuVisibilityChanged(false) }
    }

    private var flexSection: some View {
        GroupBox("Flex") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Fallback without flex", isOn: $model.settings.flex.fallback)
                Stepper("Attempts: \(model.settings.flex.attempts)", value: $model.settings.flex.attempts, in: 1...5)
                HStack {
                    Text("First byte (s)")
                    Spacer()
                    TextField("", value: $model.settings.flex.firstByteTimeout, format: .number)
                        .frame(width: 60)
                }
                HStack {
                    Text("Non-streaming (s)")
                    Spacer()
                    TextField("", value: $model.settings.flex.nonStreamingTimeout, format: .number)
                        .frame(width: 60)
                }
            }
        }
    }

    private var statsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stats (24h)").font(.headline)
            Text("Model requests: \(model.summary.modelRequests)")
                .help("Requests that carried a model id, so the Sort and Tier policy could apply.")
            Text("Other requests: \(model.summary.otherRequests)")
                .help("Requests without a model id (e.g. /models, /key); they pass through unchanged.")
            if !model.summary.byProvider.isEmpty {
                Text("Providers").font(.caption)
                    .help("The top 5 providers by request count, as OpenRouter reported them.")
                ForEach(topProviders, id: \.key) { provider, count in
                    Text("• \(provider): \(count)").font(.caption)
                }
            }
            Text("Service tier used: \(serviceTiersUsed)").font(.caption)
                .help("The service tier that actually served the request (from OpenRouter's response), not the one requested.")
            Text(fallbackLine).font(.caption)
                .help("Flex requests that exhausted their retries and fell back to a non-flex request, out of every request made with Tier=Flex.")
            Text(String(format: "Cost: $%.4f", model.summary.totalCostUSD)).font(.caption)
                .help("Sum of the costs OpenRouter reported for these requests.")
        }
    }

    private var topProviders: [(key: String, value: Int)] {
        Array(model.summary.byProvider.sorted(by: { $0.value > $1.value }).prefix(5))
    }

    /// Only the tiers OpenRouter actually served, in a fixed order; "none" when nothing was
    /// reported yet.
    private var serviceTiersUsed: String {
        let tiers = ["flex", "priority", "default"]
            .compactMap { tier in model.summary.byActualTier[tier].map { "\(tier) \($0)" } }
        return tiers.isEmpty ? "none" : tiers.joined(separator: " · ")
    }

    private var fallbackLine: String {
        let flex = model.summary.flexRequests
        guard flex > 0 else { return "Fallbacks: -" }
        return "Fallbacks: \(model.summary.fallbackCount) of \(flex) flex requests"
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status").font(.headline)
            caRow
            statusRow("Hosts entry", model.status.hostsEntry)
            statusRow("Port 443 listening", model.status.portListening)
            nodeEnvRow
            Text("Autostart: \(model.loginItemStatus.label)").font(.caption)
        }
    }

    /// Install sets `NODE_EXTRA_CA_CERTS` for processes started afterwards; the hint appears
    /// only while the variable is set, so the user knows what is already running must restart.
    private var nodeEnvRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            statusRow("Node CA env", model.status.nodeCAEnv)
            if model.status.nodeCAEnv {
                Text(Self.nodeRestartHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static let nodeRestartHint =
        "Restart your terminal app and any running agents so they pick up the CA."

    /// Distinguishes "not installed" from "present but not trusted" (the real-install bug:
    /// the certificate was in a keychain but its trust settings had not been applied).
    private var caRow: some View {
        if model.status.caTrusted {
            statusRow("CA trusted", true)
        } else if model.status.caPresent {
            statusRow("CA present but not trusted", false, warning: true)
        } else {
            statusRow("CA not installed", false)
        }
    }

    private func statusRow(_ label: String, _ ok: Bool, warning: Bool = false) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : (warning ? .orange : .secondary))
            Text(label)
        }
        .font(.caption)
    }

    private func unreachableBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("⚠︎ \(message)")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Uninstall") { Task { await model.uninstall() } }
        }
    }

    private var warningBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Warnings").font(.headline)
            ForEach(model.warnings, id: \.key) { warning in
                Text("⚠︎ \(warning.message)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    // Command stderr can be long; show it wrapped and selectable, never clipped.
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
