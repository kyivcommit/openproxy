import ServiceManagement

/// Removes the autostart and helper services registered by the build that predates
/// `SMAppService.mainApp` and `dev.openproxy.helperd3`.
public protocol LegacyServiceCleaning: Sendable {
    func removeLegacyRegistrations()
}

/// The production cleanup. Its plists live under `Resources/legacy/` and are bundled only so
/// `unregister()` can find them; the new app never registers them.
public struct SMAppServiceLegacyCleanup: LegacyServiceCleaning {
    public init() {}

    public func removeLegacyRegistrations() {
        // Remove the old daemon first so it releases dev.openproxy.helper before the new
        // helper registers. Ignore not-found/already-removed errors.
        try? SMAppService.daemon(plistName: "dev.openproxy.helper.plist").unregister()
        try? SMAppService.agent(plistName: "dev.openproxy.app.plist").unregister()
    }
}

/// No-op cleanup for tests and contexts with nothing to migrate.
public struct NoLegacyServiceCleaning: LegacyServiceCleaning {
    public init() {}
    public func removeLegacyRegistrations() {}
}
