import Foundation

/// The contract between the app and its root launch daemon. It is deliberately tiny:
/// the only privileged operation is adding or removing the single managed `/etc/hosts`
/// line. No arbitrary script, command or path ever crosses this boundary — a root helper
/// that runs caller-supplied input is a privilege-escalation hole.
public enum HelperConstants {
    /// The Mach service the daemon advertises and the app connects to. Must match
    /// `MachServices` in `Resources/dev.openproxy.helper.plist`.
    public static let machServiceName = "dev.openproxy.helper"

    /// The only client the daemon accepts: a process signed as the OpenProxy app.
    /// Ad-hoc signing is enough — the bundle identifier is what the requirement pins.
    public static let connectionRequirement = "identifier \"dev.openproxy.app\""
}

@objc public protocol HelperProtocol {
    /// Adds (`present == true`) or removes the managed openproxy line, then flushes the DNS
    /// cache. `reply` is nil on success, otherwise a short error text.
    func setHostsEntry(present: Bool, reply: @escaping (String?) -> Void)
}
