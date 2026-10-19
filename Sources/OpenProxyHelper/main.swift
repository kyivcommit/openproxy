import Dispatch
import Foundation
import OpenProxyCore
import os

private let helperLog = Logger(subsystem: "dev.openproxy.helper", category: "helper")

/// The root launch daemon. It accepts one connection contract from the OpenProxy app and
/// performs exactly one privileged operation: adding or removing the managed `/etc/hosts`
/// line. Nothing caller-supplied (script, command, path) is ever executed or written.
///
/// The daemon also acts as the route's dead-man switch: when the app's XPC session is
/// invalidated (Quit, crash, force-quit), it removes the managed hosts line, so
/// `openrouter.ai` is never left routed to a dead proxy. `RunAtLoad` lets it clean a stale
/// line at boot when the app is not running; a short grace period avoids racing the app's
/// own startup.
@main
enum OpenProxyHelper {
    static func main() {
        // Gate connections by the app that actually shipped this helper. Fail closed: a
        // requirement built without a readable signature, or without the Team ID of a
        // non-ad-hoc signature, would accept a process that only copied our identifier.
        let signing = Bundle.main.executableURL.map(HelperRequirement.appSigningInfo) ?? .unreadable
        helperLog.log("app identifier: \(signing.identifier ?? "<none>", privacy: .public)")
        helperLog.log("team identifier: \(signing.teamIdentifier ?? "<none>", privacy: .public)")
        let requirement: String
        switch HelperRequirement.decision(
            identifier: signing.identifier,
            teamIdentifier: signing.teamIdentifier,
            isAdhoc: signing.isAdhoc,
            readFailed: signing.readFailed
        ) {
        case .requirement(let built):
            requirement = built
            if signing.isAdhoc {
                helperLog.log("helper requirement mode: ad-hoc, identifier-only")
            } else {
                helperLog.log("helper requirement mode: signed, Team ID pinned")
            }
        case .refusal(let reason):
            helperLog.error("refusing to listen: \(reason, privacy: .public)")
            exit(1)
        }

        let hosts = HelperHosts()
        hosts.start()
        let delegate = HelperDelegate(hosts: hosts)
        let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = delegate
        listener.resume()
        dispatchMain()
    }
}

/// Serializes the hosts edit and connection tracking on one queue. The last connection
/// closing and a pending boot-time cleanup are the two paths that remove the route; a new
/// connection cancels the cleanup before the app edits anything.
private final class HelperHosts: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.openproxy.helper.work")
    private let hostsPath: String
    private let startupGrace: DispatchTimeInterval
    private var tracker = HelperConnectionTracker()
    private var startupCleanup: DispatchWorkItem?
    private let cleanupRetry = HelperCleanupRetry()
    private var cleanupAttempts = 0
    private var cleanupWork: DispatchWorkItem?

    init(hostsPath: String = "/etc/hosts", startupGrace: DispatchTimeInterval = .seconds(10)) {
        self.hostsPath = hostsPath
        self.startupGrace = startupGrace
    }

    /// At boot (`RunAtLoad`) no app is connected yet. If none arrives within the grace period,
    /// a hosts line left by a previous session is stale and must go.
    func start() {
        queue.async { [weak self] in
            guard let self, self.tracker.isIdle else { return }
            let cleanup = DispatchWorkItem { [weak self] in self?.removeIfIdle() }
            self.startupCleanup = cleanup
            self.queue.asyncAfter(deadline: .now() + self.startupGrace, execute: cleanup)
        }
    }

    func connectionOpened() {
        queue.async {
            self.cancelCleanup()
            self.tracker.opened()
        }
    }

    func connectionClosed() {
        queue.async {
            if self.tracker.closed() {
                self.removeIfIdle()
            }
        }
    }

    /// The app's session is established by a message, not by `NSXPCConnection.resume()`
    /// alone. This reply has no payload; its only job is to force the connection open.
    func beginSession(reply: @escaping (String?) -> Void) {
        let once = ReplyOnce(reply)
        queue.async {
            helperLog.log("session established")
            once.send(nil)
        }
    }

    func setHostsEntry(present: Bool, reply: @escaping (String?) -> Void) {
        let once = ReplyOnce(reply)
        queue.async {
            // A fresh edit cancels any pending removal: the app is clearly back.
            self.cancelCleanup()
            once.send(self.apply(present: present))
        }
    }

    private func cancelCleanup() {
        startupCleanup?.cancel()
        startupCleanup = nil
        cleanupWork?.cancel()
        cleanupWork = nil
        cleanupAttempts = 0
    }

    private func removeIfIdle() {
        cleanupWork?.cancel()
        cleanupWork = nil
        guard tracker.isIdle else {
            cleanupAttempts = 0
            return
        }
        helperLog.log("no app session: removing the managed hosts line")
        guard let error = apply(present: false) else {
            cleanupAttempts = 0
            return
        }
        cleanupAttempts += 1
        guard let delay = cleanupRetry.delay(afterFailedAttempt: cleanupAttempts) else {
            let attempts = cleanupAttempts
            cleanupAttempts = 0
            helperLog.error("could not remove the managed hosts line after \(attempts) attempts: \(error, privacy: .public)")
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.removeIfIdle() }
        cleanupWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func apply(present: Bool) -> String? {
        do {
            helperLog.log("hosts edit start (present: \(present, privacy: .public))")
            try HostsFileEditor.apply(present: present, hostsPath: hostsPath)
            helperLog.log("hosts edit ok (present: \(present, privacy: .public))")
        } catch {
            let detail = String(describing: error)
            helperLog.error("hosts edit failed: \(detail, privacy: .public)")
            return detail
        }
        // Best effort and bounded: a slow or missing dscacheutil must never delay the reply.
        let outcome = DNSCacheFlusher.flush()
        helperLog.log("flush result: \(String(describing: outcome), privacy: .public)")
        return nil
    }
}

private final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    private let hosts: HelperHosts

    init(hosts: HelperHosts) {
        self.hosts = hosts
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // The code-signing requirement already gated the connection; this line just makes the
        // acceptance visible in `log show` alongside the edit/flush/reply lines.
        helperLog.log("connection accepted")
        hosts.connectionOpened()
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperService(hosts: hosts)
        newConnection.invalidationHandler = { [weak hosts] in
            hosts?.connectionClosed()
        }
        // A listener delegate must resume the connection itself; otherwise no message is delivered.
        newConnection.resume()
        return true
    }
}

private final class HelperService: NSObject, HelperProtocol {
    private let hosts: HelperHosts

    init(hosts: HelperHosts) {
        self.hosts = hosts
    }

    func setHostsEntry(present: Bool, reply: @escaping (String?) -> Void) {
        hosts.setHostsEntry(present: present, reply: reply)
    }

    func beginSession(reply: @escaping (String?) -> Void) {
        hosts.beginSession(reply: reply)
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
