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
        // Gate connections by the app that actually shipped this helper, not a hard-coded id.
        let identifier = Bundle.main.executableURL.flatMap(HelperRequirement.appIdentifier)
        helperLog.log("app identifier: \(identifier ?? "<none>", privacy: .public)")
        let requirement = identifier.flatMap { try? HelperConstants.requirement(forAppIdentifier: $0) }
            ?? HelperConstants.connectionRequirement
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
