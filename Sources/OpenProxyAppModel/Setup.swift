import Foundation

/// The first-launch welcome gate: `true` runs the automatic setup, `false` leaves it for the
/// next launch. Injected like `QuitDecision` so tests never show a real alert.
@MainActor
public protocol SetupDecision: Sendable {
    func confirmSetup() -> Bool
}

/// The full-uninstall confirmation. Injected so tests never show a real alert.
@MainActor
public protocol UninstallDecision: Sendable {
    func confirmUninstall() -> Bool
}

/// Waits one approval poll interval. Injected so tests can advance a fake clock and flip the
/// helper status without sleeping.
public protocol SetupWaiting: Sendable {
    func waitForNextApprovalPoll() async
}

/// Deletes the CA, settings and stats files for the full uninstall. Injected so tests use a
/// temp directory instead of the real Application Support folder.
public protocol AppDataRemoving: Sendable {
    func removeAppData() throws
}

/// What the menu's compact "Routing:" line shows.
public enum RoutingState: Equatable, Sendable {
    case inactive
    case settingUp
    case waitingForApproval
    case active
    case error(String)

    public var label: String {
        switch self {
        case .inactive: "inactive"
        case .settingUp: "setting up..."
        case .waitingForApproval: "waiting for approval in System Settings -> Login Items"
        case .active: "active"
        case .error(let message): message
        }
    }
}

/// Defaults for callers that do not opt in (tests, previews): do nothing, never show an alert.
public struct NoSetupDecision: SetupDecision {
    public init() {}
    public func confirmSetup() -> Bool { false }
}

public struct NoUninstallDecision: UninstallDecision {
    public init() {}
    public func confirmUninstall() -> Bool { false }
}

public struct ImmediateSetupWaiting: SetupWaiting {
    public init() {}
    public func waitForNextApprovalPoll() async {}
}

public struct NoAppDataRemoving: AppDataRemoving {
    public init() {}
    public func removeAppData() throws {}
}

/// Production approval poll: a real 2 s wait, up to the setup flow's poll budget.
public struct RealSetupWaiting: SetupWaiting {
    private let interval: Duration

    public init(interval: Duration = .seconds(2)) {
        self.interval = interval
    }

    public func waitForNextApprovalPoll() async {
        try? await Task.sleep(for: interval)
    }
}

/// Production full-uninstall data wipe: removes every file in the app support directory
/// (ca.pem, ca.key, settings.json, stats.sqlite).
public struct AppSupportDataRemover: AppDataRemoving {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func removeAppData() throws {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else {
            return
        }
        for item in contents {
            try manager.removeItem(at: item)
        }
    }
}
