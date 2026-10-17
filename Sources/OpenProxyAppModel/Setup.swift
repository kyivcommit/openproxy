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

/// A refusal to wipe the app's data directory: the path is a symlink or not a directory, so
/// removing its contents would delete files somewhere other than our own data.
public enum DataRemovalError: Error, Equatable, Sendable {
    case notADirectory(String)
}

extension DataRemovalError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notADirectory(let path):
            return "The OpenProxy data path is not a real directory (symlink?): \(path)"
        }
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
        // lstat never follows the final component: a symlinked data directory would otherwise
        // make the wipe delete files wherever the link points. Refuse anything that is not a
        // real directory. A missing directory falls through to the ENOENT handling below.
        var entryStatus = stat()
        if lstat(directory.path, &entryStatus) == 0,
           entryStatus.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) {
            throw DataRemovalError.notADirectory(directory.path)
        }
        let contents: [URL]
        do {
            contents = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            // Only a directory that is not there means there is nothing to remove. Any other
            // listing error (unreadable directory, I/O failure) must surface: swallowing it
            // would let the uninstall quit with the data still on disk.
            guard Self.isMissingDirectory(error) else { throw error }
            return
        }
        // `removeItem` unlinks a symlink itself, so a linked item inside is removed as a link
        // and its target is never touched.
        for item in contents {
            try manager.removeItem(at: item)
        }
    }

    /// True only for "no such file or directory" errors, the one listing failure that means
    /// the data is already gone.
    static func isMissingDirectory(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           (nsError.code == CocoaError.fileNoSuchFile.rawValue
            || nsError.code == CocoaError.fileReadNoSuchFile.rawValue) {
            return true
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)
    }
}
