import Dispatch
import Foundation
import OpenProxyCore
import os

private let helperLog = Logger(subsystem: "dev.openproxy.helper", category: "helper")

/// The root launch daemon. It accepts one connection contract from the OpenProxy app and
/// performs exactly one privileged operation: adding or removing the managed `/etc/hosts`
/// line. Nothing caller-supplied (script, command, path) is ever executed or written.
@main
enum OpenProxyHelper {
    static func main() {
        let delegate = HelperDelegate()
        let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
        // Gate connections by the app that actually shipped this helper: pin the Team ID too
        // when the build is signed, so a local process cannot re-sign itself with our identifier.
        let signing = Bundle.main.executableURL.map(HelperRequirement.appSigningInfo)
            ?? (identifier: nil, teamIdentifier: nil)
        helperLog.log("app identifier: \(signing.identifier ?? "<none>", privacy: .public)")
        helperLog.log("team identifier: \(signing.teamIdentifier ?? "<none>", privacy: .public)")
        let requirement: String
        switch (signing.identifier, signing.teamIdentifier) {
        case let (identifier?, team?):
            do {
                requirement = try HelperConstants.requirement(
                    forAppIdentifier: identifier, teamIdentifier: team)
                helperLog.log("helper requirement mode: signed, Team ID pinned")
            } catch {
                helperLog.error("invalid Team ID \(team, privacy: .public): \(String(describing: error), privacy: .public); falling back to identifier-only")
                requirement = (try? HelperConstants.requirement(forAppIdentifier: identifier))
                    ?? HelperConstants.connectionRequirement
            }
        case let (identifier?, nil):
            requirement = (try? HelperConstants.requirement(forAppIdentifier: identifier))
                ?? HelperConstants.connectionRequirement
            helperLog.log("helper requirement mode: ad-hoc, identifier-only")
        case (nil, _):
            requirement = HelperConstants.connectionRequirement
            helperLog.log("helper requirement mode: fallback constant (no parent app identifier)")
        }
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = delegate
        listener.resume()
        dispatchMain()
    }
}

private final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // The code-signing requirement already gated the connection; this line just makes the
        // acceptance visible in `log show` alongside the edit/flush/reply lines.
        helperLog.log("connection accepted")
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperService()
        // A listener delegate must resume the connection itself; otherwise no message is delivered.
        newConnection.resume()
        return true
    }
}

private final class HelperService: NSObject, HelperProtocol {
    /// The hosts edit and the flush both block their thread; never run them on the XPC
    /// delegate queue. A dedicated serial queue keeps one edit at a time and keeps the
    /// listener responsive.
    private let queue = DispatchQueue(label: "dev.openproxy.helper.work")

    func setHostsEntry(present: Bool, reply: @escaping (String?) -> Void) {
        let once = ReplyOnce(reply)
        queue.async {
            let editError: String?
            do {
                helperLog.log("hosts edit start (present: \(present, privacy: .public))")
                try HostsFileEditor.apply(present: present, hostsPath: "/etc/hosts")
                helperLog.log("hosts edit ok (present: \(present, privacy: .public))")
                editError = nil
            } catch {
                let detail = String(describing: error)
                helperLog.error("hosts edit failed: \(detail, privacy: .public)")
                editError = detail
            }
            guard editError == nil else {
                helperLog.log("reply sent (error: true)")
                once.send(editError)
                return
            }
            // Best effort and bounded: a slow or missing dscacheutil must never delay the reply.
            let outcome = DNSCacheFlusher.flush()
            helperLog.log("flush result: \(String(describing: outcome), privacy: .public)")
            helperLog.log("reply sent (error: false)")
            once.send(nil)
        }
    }
}

/// Calls the XPC reply exactly once, whichever path (edit error or success) runs first. The
/// reply block is not `Sendable`, so it is boxed to cross onto the work queue.
private final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let reply: (String?) -> Void

    init(_ reply: @escaping (String?) -> Void) {
        self.reply = reply
    }

    func send(_ error: String?) {
        let shouldSend = lock.withLock { () -> Bool in
            guard !done else { return false }
            done = true
            return true
        }
        guard shouldSend else { return }
        reply(error)
    }
}
