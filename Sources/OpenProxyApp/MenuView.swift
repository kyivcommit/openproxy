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
            Text("Requests: \(model.summary.total)")
            ForEach(model.summary.byProvider.sorted(by: { $0.value > $1.value }), id: \.key) { provider, count in
                Text("• \(provider): \(count)").font(.caption)
            }
            ForEach(model.summary.byActualTier.sorted(by: { $0.value > $1.value }), id: \.key) { tier, count in
                Text("• tier \(tier): \(count)").font(.caption)
            }
            let share = model.summary.total == 0
                ? 0
                : Double(model.summary.fallbackCount) / Double(model.summary.total)
            Text(String(format: "Fallback: %.0f%%  Cost: $%.4f", share * 100, model.summary.totalCostUSD))
                .font(.caption)
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status").font(.headline)
            statusRow("CA trusted", model.status.caTrusted)
            statusRow("Hosts entry", model.status.hostsEntry)
            statusRow("Port 443 listening", model.status.portListening)
            statusRow("Node CA env", model.status.nodeCAEnv)
            Text("Autostart: \(model.loginItemStatus.label)").font(.caption)
        }
    }

    private func statusRow(_ label: String, _ ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
            Text(label)
        }
        .font(.caption)
    }

    private func unreachableBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("⚠︎ \(message)").font(.caption).foregroundStyle(.orange)
            Button("Uninstall") { Task { await model.uninstall() } }
        }
    }

    private var warningBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Warnings").font(.headline)
            ForEach(model.warnings, id: \.self) { warning in
                Text("⚠︎ \(warning)").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
