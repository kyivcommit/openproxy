import Dispatch
import Foundation

/// Keeps a live XPC connection to the root helper while the app runs. The helper treats the
/// connection's invalidation as "the app is gone" and removes the managed `/etc/hosts` line,
/// so a crash cannot leave `openrouter.ai` routed to a dead proxy. Injected so `AppModel` is
/// testable without a real daemon.
public protocol HelperSessionKeeping: Sendable {
    /// Idempotent: opens the session if needed, does nothing when it is already open.
    func start()
    /// Closes the session. The helper removes the managed hosts line when the last connection
    /// closes, so this is also a safety action.
    func stop()
}

/// For tests and unbundled runs: no daemon, no session.
public struct NoHelperSession: HelperSessionKeeping {
    public init() {}
    public func start() {}
    public func stop() {}
}

/// Pure counter behind the helper's dead-man switch. All edits and this state run on one
/// serial queue in the helper; this type is the testable part of the policy.
public struct HelperConnectionTracker: Equatable, Sendable {
    public private(set) var active = 0

    public init() {}

    public mutating func opened() {
        active += 1
    }

    /// Returns true when that was the last live connection: the app has gone away.
    @discardableResult
    public mutating func closed() -> Bool {
        active = max(0, active - 1)
        return active == 0
    }

    public var isIdle: Bool { active == 0 }
}

/// Bounded backoff for the dead-man cleanup. The helper retries a failed hosts removal a few
/// times; if every attempt fails it logs a persistent failure and stops instead of spinning.
public struct HelperCleanupRetry: Equatable, Sendable {
    public let maxAttempts: Int

    public init(maxAttempts: Int = 3) {
        self.maxAttempts = max(1, maxAttempts)
    }

    /// Delay before the next attempt after `attempt` failed attempts, or nil when the budget
    /// is exhausted. Attempts 1 and 2 back off by 1 s and 2 s for the default budget.
    public func delay(afterFailedAttempt attempt: Int) -> DispatchTimeInterval? {
        guard attempt >= 1, attempt < maxAttempts else { return nil }
        return .seconds(1 << (attempt - 1))
    }
}
