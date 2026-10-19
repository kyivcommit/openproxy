import AppKit
import Foundation
import OpenProxyAppModel

/// Pure AppKit entry point: a menu bar agent with no SwiftUI scenes, so no empty Settings
/// window can ever open on activate/reopen/Cmd+,.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `NSApplication.delegate` is weak, so the delegate must be kept alive for the run loop.
    private static let shared = AppDelegate()
    private var statusItem: StatusItemController?

    static func main() {
        let app = NSApplication.shared
        // Both a plain `swift run` (no Info.plist) and the built app must be an agent with no
        // Dock icon. The built app already sets LSUIElement, so only add the policy without it.
        if Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true {
            _ = app.setActivationPolicy(.accessory)
        }
        app.delegate = shared
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: the autostart LaunchAgent (RunAtLoad) makes launchd start a second
        // copy while the manually started one keeps running. Yield silently with exit(0) — so
        // launchd does not treat it as a crash and restart it — before building the graph or
        // binding port 443.
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
            Task { @MainActor in
                await built.start()
                await built.refresh()
            }
        } catch {
            // Spec 9: still show the menu bar with the reason and a way out, not nothing.
            statusItem = StatusItemController(model: nil, startupError: String(describing: error))
        }
    }

    /// There are no windows to reopen; activate only re-shows nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }
}
