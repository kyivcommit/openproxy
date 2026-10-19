import Foundation
import ServiceManagement

/// Autostart registration as the UI needs it, behind a protocol so the menu can
/// be tested without a real signed bundle or SMAppService.
public protocol LoginItemRegistering: Sendable {
    func register() throws
    func unregister() throws
    var status: LoginItemStatus { get }
}

public enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown(Int)

    /// Human-readable text for the menu's status line and warnings.
    public var label: String {
        switch self {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "needs approval in System Settings"
        case .notFound: "not found"
        case .unknown(let raw): "unknown (\(raw))"
        }
    }
}

/// The production registrar: `SMAppService.mainApp`, macOS's Login Item for the app itself.
/// It avoids a bundled LaunchAgent and its stored code requirement, which went stale every
/// time the ad-hoc-signed app bundle was rebuilt. The approved root helper removes the
/// `/etc/hosts` line when the app exits or crashes, so the route is safe without `KeepAlive`.
public struct SMAppServiceLoginItem: LoginItemRegistering {
    public init() {}

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown(-1)
        }
    }
}
