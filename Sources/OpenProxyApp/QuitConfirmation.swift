import AppKit
import OpenProxyAppModel

/// The production quit gate: ask before quitting while `openrouter.ai` is still
/// routed here, then really terminate. `AppModel` owns the decision logic.
@MainActor
struct AlertQuitDecision: QuitDecision {
    func decide() -> QuitChoice {
        let alert = NSAlert()
        alert.messageText = "openrouter.ai is still routed to this proxy"
        alert.informativeText = "Quitting without uninstalling leaves openrouter.ai pointed at "
            + "127.0.0.1, so every client loses access until the proxy runs again."
        alert.addButton(withTitle: "Uninstall and quit")
        alert.addButton(withTitle: "Quit anyway")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .uninstallAndQuit
        case .alertSecondButtonReturn: return .quitAnyway
        default: return .cancel
        }
    }

    func terminate() {
        NSApplication.shared.terminate(nil)
    }
}
