import Foundation
import SwiftUI
import OpenProxyAppModel

@main
struct OpenProxyApp: App {
    /// Left click shows the policy, stats and status menu, right click the app-management
    /// menu; the AppKit item is built here because `MenuBarExtra` cannot see right clicks.
    private let statusItem: StatusItemController

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
            let built = try AppGraph.makeModel(
                quitDecision: AlertQuitDecision(),
                setupDecision: AlertSetupDecision(),
                uninstallDecision: AlertUninstallDecision())
            statusItem = StatusItemController(model: built)
            // Never registers autostart, installs or touches hosts on launch; only the user's
            // Install button does, so OpenProxy only appears in Login Items while installed.
            Task { @MainActor in
                await built.start()
                await built.refresh()
            }
        } catch {
            // Spec 9: still show the menu bar with the reason and a way out, not nothing.
            statusItem = StatusItemController(model: nil, startupError: String(describing: error))
        }
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}
