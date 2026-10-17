import AppKit
import Foundation

/// Finds the running processes that carry a bundle identifier. Injected so the
/// single-instance decision is testable without launching real processes.
public protocol RunningInstanceProviding: Sendable {
    /// PIDs of running applications with `bundleIdentifier`. May include our own PID; the
    /// caller filters it.
    func runningPIDs(bundleIdentifier: String) -> [Int32]
}

/// The production provider: every running application with our bundle identifier, including us.
public struct RunningApplicationInstances: RunningInstanceProviding {
    public init() {}

    public func runningPIDs(bundleIdentifier: String) -> [Int32] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier)
    }
}

/// Decides whether a just-launched instance should exit because another instance of the same
/// app is already running. Pure, so the policy is unit-tested without processes.
///
/// The autostart LaunchAgent (`RunAtLoad`) makes launchd start a second copy while the manually
/// started one keeps running — two menu bar icons. The duplicate yields with `exit(0)`, so
/// launchd does not treat it as a crash and restart it.
public enum SingleInstanceGuard {
    /// True when any listed PID is not our own.
    public static func shouldYield(otherPIDs: [Int32], ownPID: Int32) -> Bool {
        otherPIDs.contains { $0 != ownPID }
    }

    public static func shouldYield(
        using provider: RunningInstanceProviding,
        bundleIdentifier: String,
        ownPID: Int32
    ) -> Bool {
        shouldYield(otherPIDs: provider.runningPIDs(bundleIdentifier: bundleIdentifier), ownPID: ownPID)
    }
}
