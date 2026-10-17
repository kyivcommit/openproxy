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
public protocol HelperRegistering: Sendable {
    func register() throws
    var status: HelperStatus { get }
    func unregister() throws
    /// Opens System Settings -> Login Items so the user can flip the one-time switch.
    func openApprovalSettings()
}

/// The production registrar: `SMAppService.daemon(plistName:)` over the launch daemon bundled
/// at `Contents/Library/LaunchDaemons/<plistName>`.
public struct SMAppServiceDaemon: HelperRegistering {
    private let plistName: String

    public init(plistName: String = "dev.openproxy.helper.plist") {
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

    public func unregister() throws {
        try service.unregister()
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
    public func unregister() throws {}
    public func openApprovalSettings() {}
}
