import SwiftUI
import AppKit
import ServiceManagement
import OpenProxyAppModel

@main
struct OpenProxyApp: App {
    @State private var model: AppModel?

    init() {
        let built = try? AppGraph.makeModel()
        _model = State(initialValue: built)
        guard let built else { return }
        // Autostart + KeepAlive watchdog; best effort, only succeeds for a bundled signed app.
        try? SMAppService.agent(plistName: "dev.openproxy.app.plist").register()
        // Never installs and never touches hosts on launch; only the user's Install button does.
        Task { @MainActor in
            await built.start()
            await built.refresh()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if let model {
                MenuView(model: model)
            } else {
                Text("openproxy could not start (see Console)")
                    .padding()
            }
        } label: {
            Image(systemName: "shield.lefthalf.filled")
        }
        .menuBarExtraStyle(.window)
    }
}
