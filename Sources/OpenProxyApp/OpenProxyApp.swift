import Foundation
import SwiftUI
import AppKit
import OpenProxyAppModel

@main
struct OpenProxyApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?

    init() {
        // Single instance: the autostart LaunchAgent (RunAtLoad) makes launchd start a second
        // copy while the manually started one keeps running. Yield silently with exit(0) — so
        // launchd does not treat it as a crash and restart it — before building the graph,
        // binding port 443 or showing a second menu bar icon.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           SingleInstanceGuard.shouldYield(
               using: RunningApplicationInstances(),
               bundleIdentifier: bundleIdentifier,
               ownPID: ownPID) {
            exit(0)
        }
        do {
            let built = try AppGraph.makeModel(quitDecision: AlertQuitDecision())
            _model = State(initialValue: built)
            // Never registers autostart, installs or touches hosts on launch; only the user's
            // Install button does, so OpenProxy only appears in Login Items while installed.
            Task { @MainActor in
                await built.start()
                await built.refresh()
            }
        } catch {
            // Spec 9: still show the menu bar with the reason and a way out, not nothing.
            _startupError = State(initialValue: String(describing: error))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if let model {
                MenuView(model: model)
            } else {
                startupErrorView
            }
        } label: {
            Image(systemName: "shield.lefthalf.filled")
        }
        .menuBarExtraStyle(.window)
    }

    private var startupErrorView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("openproxy could not start").font(.headline)
            Text(startupError ?? "Unknown error")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
