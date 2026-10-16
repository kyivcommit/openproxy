import SwiftUI
import AppKit
import OpenProxyAppModel

@main
struct OpenProxyApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?

    init() {
        do {
            let built = try AppGraph.makeModel(quitDecision: AlertQuitDecision())
            _model = State(initialValue: built)
            // Autostart + KeepAlive watchdog; best effort, only succeeds for a bundled signed app.
            // Failures and a non-enabled status surface as warnings in the menu.
            built.registerLoginItem()
            // Never installs and never touches hosts on launch; only the user's Install button does.
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
