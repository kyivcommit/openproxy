import Foundation
import Observation
import OpenProxyCore

/// The proxy server as the UI needs it: start and stop, nothing more.
public protocol ProxyServerControlling: Sendable {
    func start() async throws
    func stop() async
}

extension ProxyServer: ProxyServerControlling {}

/// UI-free view model. It owns the live settings, the stats summary and the
/// install status, and turns failures into `warnings` instead of throwing, so the
/// menu always has something to show.
@MainActor
@Observable
public final class AppModel {
    /// Reading/writing goes through the store so a per-request settings reader
    /// (the `ProxyServer` closure) sees UI changes immediately; writes are saved.
    public var settings: Settings {
        get { currentSettings }
        set {
            currentSettings = newValue
            settingsStore.settings = newValue
            try? settingsStore.save()
        }
    }

    public private(set) var status: InstallStatus
    public private(set) var summary: StatsSummary
    public private(set) var warnings: [String] = []

    private var currentSettings: Settings
    private let settingsStore: SettingsStore
    private let stats: StatsStore
    private let installer: Installer
    private let server: ProxyServerControlling

    public init(
        settingsStore: SettingsStore,
        stats: StatsStore,
        installer: Installer,
        server: ProxyServerControlling
    ) {
        self.settingsStore = settingsStore
        self.stats = stats
        self.installer = installer
        self.server = server
        self.currentSettings = settingsStore.settings
        self.status = InstallStatus(caTrusted: false, hostsEntry: false, portListening: false, nodeCAEnv: false)
        self.summary = StatsSummary()
    }

    public func start() async {
        do {
            try await server.start()
        } catch {
            // Spec 9: a busy port must not change the hosts entry, and the user must see why.
            warnings.append("Proxy server failed to start: \(error). The hosts entry was left unchanged.")
        }
    }

    public func stop() async {
        await server.stop()
    }

    public func install() async {
        do {
            try await installer.install()
        } catch {
            warnings.append("Install failed: \(error). The system was not fully changed.")
        }
        await refresh()
    }

    public func uninstall() async {
        do {
            try await installer.uninstall()
        } catch {
            warnings.append("Uninstall failed: \(error).")
        }
        await refresh()
    }

    public func refresh() async {
        summary = stats.summary(since: Date(timeIntervalSinceNow: -86_400))
        status = await installer.status()
    }
}
