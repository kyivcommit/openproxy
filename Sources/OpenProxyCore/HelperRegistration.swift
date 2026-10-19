import Foundation
import ServiceManagement

/// The root helper's registration state, as the menu and installer need it.
public enum HelperStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown

    /// Human-readable text for the menu's status line.
    public var label: String {
        switch self {
        case .notRegistered: "not installed"
        case .enabled: "enabled"
        case .requiresApproval: "needs approval in System Settings"
        case .notFound: "helper missing from the bundle"
        case .unknown: "unknown"
        }
    }
}

/// Registers the privileged helper daemon. Mirrors `LoginItemRegistering`; injected so the
/// installer and menu can be tested without a signed bundle or `SMAppService`.
/// There is no `unregister`: the helper stays registered across Uninstall, because the
/// OpenProxy row in Login Items belongs to the app, and re-registering an already-enabled
/// daemon makes macOS skip the signature recording (launchd then refuses to spawn it).
public protocol HelperRegistering: Sendable {
    func register() throws
    var status: HelperStatus { get }
    /// Opens System Settings -> Login Items so the user can flip the one-time switch.
    func openApprovalSettings()
}

/// The production registrar: `SMAppService.daemon(plistName:)` over the launch daemon bundled
/// at `Contents/Library/LaunchDaemons/<plistName>`.
///
/// The plist is `dev.openproxy.helperd.plist` and its launchd label is
/// `dev.openproxy.helperd2`; the Mach service stays `dev.openproxy.helper`. The distinct
/// label gives the daemon a fresh background-item record when an ad-hoc rebuild changes its
/// signature; reusing the old label made macOS keep the previous binary's checksum and
/// launchd refused to spawn the rebuilt helper.
public struct SMAppServiceDaemon: HelperRegistering {
    private let plistName: String

    public init(plistName: String = "dev.openproxy.helperd.plist") {
        self.plistName = plistName
    }

    public func register() throws {
        try service.register()
    }

    public var status: HelperStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }
}

/// A registrar for contexts with no helper at all (unbundled runs, tests): nothing is
/// installed, so the installer keeps its legacy behavior.
public struct NoHelperRegistration: HelperRegistering {
    public init() {}

    public func register() throws {}
    public var status: HelperStatus { .notFound }
    public func openApprovalSettings() {}
}
