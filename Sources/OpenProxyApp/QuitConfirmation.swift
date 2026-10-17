import AppKit
import OpenProxyAppModel

/// The production quit gate: ask before quitting while `openrouter.ai` is still
/// routed here, then really terminate. `AppModel` owns the decision logic.
@MainActor
struct AlertQuitDecision: QuitDecision {
    func decide() -> QuitChoice {
        let alert = NSAlert()
        alert.messageText = "openrouter.ai is still routed to this proxy"
        alert.informativeText = "Restoring access removes the openrouter.ai hosts entry and turns "
            + "autostart off; the certificate and the root helper stay, so setup is not repeated. "
            + "To remove those as well, use Uninstall OpenProxy... in the menu."
        alert.addButton(withTitle: "Restore access and quit")
        alert.addButton(withTitle: "Quit anyway")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .restoreAccessAndQuit
        case .alertSecondButtonReturn: return .quitAnyway
        default: return .cancel
        }
    }

    func terminate() {
        NSApplication.shared.terminate(nil)
    }
}
