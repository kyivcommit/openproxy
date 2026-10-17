import AppKit
import OpenProxyAppModel

/// The production first-launch welcome gate: one NSAlert with Continue / Not now.
@MainActor
struct AlertSetupDecision: SetupDecision {
    func confirmSetup() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Set up OpenProxy"
        alert.informativeText = "OpenProxy creates a local certificate trusted only for "
            + "openrouter.ai, adds a background helper so it can edit /etc/hosts without a "
            + "password, and starts at login."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not now")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The production full-uninstall confirmation.
@MainActor
struct AlertUninstallDecision: UninstallDecision {
    func confirmUninstall() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove OpenProxy?"
        alert.informativeText = "This removes the certificate, autostart and all "
            + "OpenProxy data, then quits. The root helper stays registered but idle, and goes "
            + "away when you delete the app."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
