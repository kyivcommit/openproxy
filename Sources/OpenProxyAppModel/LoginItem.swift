import Foundation
import ServiceManagement

/// Autostart registration as the UI needs it, behind a protocol so the menu can
/// be tested without a real signed bundle or SMAppService.
public protocol LoginItemRegistering: Sendable {
    func register() throws
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
        case .notFound: "LaunchAgent missing from the bundle"
        case .unknown(let raw): "unknown (\(raw))"
        }
    }
}

/// The production registrar: `SMAppService.agent(plistName:)` over the LaunchAgent
/// bundled at `Contents/Library/LaunchAgents/<plistName>`.
public struct SMAppServiceLoginItem: LoginItemRegistering {
    private let plistName: String

    public init(plistName: String = "dev.openproxy.app.plist") {
        self.plistName = plistName
    }

    public func register() throws {
        try SMAppService.agent(plistName: plistName).register()
    }

    public var status: LoginItemStatus {
        switch SMAppService.agent(plistName: plistName).status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown(-1)
        }
    }
}
