import Foundation
import ServiceManagement

/// What the legacy-service migration managed to remove. Only a failed daemon removal blocks
/// routing: a still-registered old daemon can win `dev.openproxy.helper` against the new one.
public struct LegacyServiceCleanupReport: Equatable, Sendable {
    public let daemonFailure: String?
    public let agentFailure: String?
    public init(daemonFailure: String? = nil, agentFailure: String? = nil) {
        self.daemonFailure = daemonFailure
        self.agentFailure = agentFailure
    }

    public var blocksRouting: Bool { daemonFailure != nil }
    public var hasFailures: Bool { daemonFailure != nil || agentFailure != nil }

    /// The failures, joined for the single menu warning.
    public var message: String? {
        let failures = [daemonFailure, agentFailure].compactMap { $0 }
        return failures.isEmpty ? nil : failures.joined(separator: " ")
    }
}

/// Removes the autostart and helper services registered by the build that predates
/// `SMAppService.mainApp` and `dev.openproxy.helperd3`.
public protocol LegacyServiceCleaning: Sendable {
    func removeLegacyRegistrations() -> LegacyServiceCleanupReport
}

/// The production cleanup. Its plists live under `Resources/legacy/` and are bundled only so
/// `unregister()` can find them; the new app never registers them.
public struct SMAppServiceLegacyCleanup: LegacyServiceCleaning {
    public init() {}

    public func removeLegacyRegistrations() -> LegacyServiceCleanupReport {
        // Remove the old daemon first so it releases dev.openproxy.helper before the new
        // helper registers. The agent has no Mach service to fight over, so its failure is
        // reported but does not block the route.
        let daemon = SMAppService.daemon(plistName: "dev.openproxy.helper.plist")
        let agent = SMAppService.agent(plistName: "dev.openproxy.app.plist")
        return LegacyServiceCleanupReport(
            daemonFailure: Self.remove(
                name: "dev.openproxy.helper legacy daemon",
                status: { daemon.status },
                unregister: { try daemon.unregister() }),
            agentFailure: Self.remove(
                name: "dev.openproxy.app legacy agent",
                status: { agent.status },
                unregister: { try agent.unregister() }))
    }

    /// Removes one legacy service. Returns nil only when it is confirmed gone: a missing plist
    /// or any other unregister failure means the service may still be registered.
    static func remove(
        name: String,
        status: () -> SMAppService.Status,
        unregister: () throws -> Void
    ) -> String? {
        switch status() {
        case .notRegistered:
            return nil
        case .notFound:
            return "\(name): legacy plist is missing from the bundle, so it cannot be "
                + "unregistered. Remove it in System Settings -> Login Items."
        case .enabled, .requiresApproval:
            break
        @unknown default:
            break
        }
        do {
            try unregister()
        } catch {
            // 113 is kSMErrorJobNotFound: the job is already gone, which is the outcome we want.
            let error = error as NSError
            if error.domain == "SMAppServiceErrorDomain", error.code == 113 { return nil }
            return "\(name): could not be unregistered: \(error). Remove it in "
                + "System Settings -> Login Items."
        }
        switch status() {
        case .notRegistered, .notFound:
            return nil
        default:
            return "\(name): still registered after unregister. Remove it in "
                + "System Settings -> Login Items."
        }
    }
}

/// No-op cleanup for tests and contexts with nothing to migrate.
public struct NoLegacyServiceCleaning: LegacyServiceCleaning {
    public init() {}
    public func removeLegacyRegistrations() -> LegacyServiceCleanupReport { LegacyServiceCleanupReport() }
}
