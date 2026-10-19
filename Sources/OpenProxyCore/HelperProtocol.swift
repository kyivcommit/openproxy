import Foundation

/// The contract between the app and its root launch daemon. It is deliberately tiny:
/// the only privileged operation is adding or removing the single managed `/etc/hosts`
/// line. No arbitrary script, command or path ever crosses this boundary — a root helper
/// that runs caller-supplied input is a privilege-escalation hole.
public enum HelperConstants {
    /// The Mach service the daemon advertises and the app connects to. Must match
    /// `MachServices` in `Resources/dev.openproxy.helperd3.plist`.
    public static let machServiceName = "dev.openproxy.helper"

    /// The only client the daemon accepts: a process signed as the OpenProxy app.
    /// Ad-hoc signing is enough — the bundle identifier is what the requirement pins.
    /// This is the fallback when the helper cannot read its own parent app's identifier.
    public static let connectionRequirement = "identifier \"dev.openproxy.app\""

    public enum RequirementError: Error, Equatable, Sendable {
        case emptyIdentifier
        case invalidTeamIdentifier
    }

    /// Builds the code-signing requirement for the helper's only client. Ad-hoc builds pin the
    /// bundle identifier alone; a signed build also pins the Team ID, so a local process cannot
    /// sign itself with our identifier and talk to the daemon. Quotes and backslashes are
    /// escaped so a crafted value cannot break out of the string literal.
    public static func requirement(
        forAppIdentifier identifier: String,
        teamIdentifier: String? = nil
    ) throws -> String {
        guard !identifier.isEmpty else { throw RequirementError.emptyIdentifier }
        let escapedIdentifier = escaped(identifier)
        guard let teamIdentifier else {
            return "identifier \"\(escapedIdentifier)\""
        }
        guard isPlausibleTeamIdentifier(teamIdentifier) else {
            throw RequirementError.invalidTeamIdentifier
        }
        return "identifier \"\(escapedIdentifier)\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(escaped(teamIdentifier))\""
    }

    /// Apple Team IDs are 10 alphanumerics; anything else is rejected so a crafted value cannot
    /// widen the requirement.
    static func isPlausibleTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

@objc public protocol HelperProtocol {
    /// Adds (`present == true`) or removes the managed openproxy line, then flushes the DNS
    /// cache. `reply` is nil on success, otherwise a short error text.
    func setHostsEntry(present: Bool, reply: @escaping (String?) -> Void)

    /// Marks this connection as the live app session. The helper removes the managed hosts
    /// line when the last session connection is invalidated, so a crashed app cannot leave
    /// `openrouter.ai` routed to a dead proxy. The call also forces the otherwise lazy XPC
    /// connection open, which cancels the helper's boot-time stale-route cleanup.
    func beginSession(reply: @escaping (String?) -> Void)
}
