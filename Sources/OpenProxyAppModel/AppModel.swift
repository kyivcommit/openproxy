import Foundation
import Observation
import OpenProxyCore

/// The proxy server as the UI needs it: start and stop, nothing more.
public protocol ProxyServerControlling: Sendable {
    func start() async throws
    func stop() async
}

extension ProxyServer: ProxyServerControlling {}

extension InstallStatus {
    /// Spec 9: with the hosts entry installed but nothing listening on 443, every
    /// client's `openrouter.ai` is broken until the proxy runs or the user uninstalls.
    public var unreachableWarning: String? {
        guard hostsEntry, !portListening else { return nil }
        return "openrouter.ai is routed to 127.0.0.1 but the proxy is not listening, "
            + "so all clients are blocked. Press Uninstall to restore access."
    }
}

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
            do {
                try settingsStore.save()
            } catch {
                // The in-memory value still drives the UI and each request; only the
                // disk copy is stale, so warn and keep the shown value.
                warn("Could not save settings: \(error).")
            }
        }
    }

    public private(set) var status: InstallStatus
    public private(set) var summary: StatsSummary
    public private(set) var warnings: [String] = []
    public private(set) var loginItemStatus: LoginItemStatus = .notRegistered

    /// Derived from `status`, so it stays visible for as long as the danger lasts
    /// (proxy quit/crashed with the hosts entry still routed) and clears itself.
    public var unreachableWarning: String? { status.unreachableWarning }

    /// How often an open menu refreshes the summary and status.
    public let refreshInterval: Duration

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Whether `server.start()` already bound the port. Guards Install from a
    /// second bind (and from installing hosts before anything listens).
    private var serverRunning = false

    private var currentSettings: Settings
    private let settingsStore: SettingsStore
    private let stats: StatsStore
    private let installer: Installer
    private let server: ProxyServerControlling
    private let loginItem: LoginItemRegistering

    public init(
        settingsStore: SettingsStore,
        stats: StatsStore,
        installer: Installer,
        server: ProxyServerControlling,
        loginItem: LoginItemRegistering,
        refreshInterval: Duration = .seconds(5)
    ) {
        self.settingsStore = settingsStore
        self.stats = stats
        self.installer = installer
        self.server = server
        self.loginItem = loginItem
        self.refreshInterval = refreshInterval
        self.currentSettings = settingsStore.settings
        self.status = InstallStatus(caTrusted: false, hostsEntry: false, portListening: false, nodeCAEnv: false)
        self.summary = StatsSummary()
    }

    public func start() async {
        _ = await startServer(ifFailed: "The hosts entry was left unchanged.")
    }

    public func stop() async {
        await server.stop()
        serverRunning = false
    }

    /// Starts the proxy unless it is already listening. Returns false (with a
    /// warning) when it cannot bind, so callers never proceed as if it listens.
    @discardableResult
    private func startServer(ifFailed suffix: String) async -> Bool {
        if serverRunning { return true }
        do {
            try await server.start()
            serverRunning = true
            return true
        } catch {
            warn("Proxy server failed to start: \(error). \(suffix)")
            return false
        }
    }

    public func install() async {
        // Spec 9 / finding: installing the hosts entry before the proxy listens
        // would black-hole openrouter.ai for every client, so start first.
        guard await startServer(ifFailed: "Install was skipped; the hosts entry was left unchanged.") else {
            await refresh()
            return
        }
        do {
            try await installer.install()
        } catch {
            warn("Install failed: \(error). The system was not fully changed.")
        }
        await refresh()
    }

    public func uninstall() async {
        do {
            try await installer.uninstall()
        } catch {
            warn("Uninstall failed: \(error).")
        }
        await refresh()
    }

    public func refresh() async {
        summary = stats.summary(since: Date(timeIntervalSinceNow: -86_400))
        status = await installer.status()
        loginItemStatus = loginItem.status
    }

    /// Called by the menu on appear/disappear: refresh once right away, then on
    /// `refreshInterval` while the menu stays open so a crashed proxy or new
    /// traffic shows up without reopening the menu.
    public func menuVisibilityChanged(_ visible: Bool) {
        refreshTask?.cancel()
        refreshTask = nil
        guard visible else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: self.refreshInterval)
            }
        }
    }

    /// Registers the login item and reports both the thrown error and the
    /// post-registration status, which the plain `try?` used to hide.
    public func registerLoginItem() {
        do {
            try loginItem.register()
        } catch {
            loginItemStatus = loginItem.status
            warn("Autostart registration failed: \(error).")
            return
        }
        loginItemStatus = loginItem.status
        if loginItemStatus != .enabled {
            warn("Autostart is \(loginItemStatus.label).")
        }
    }

    /// Appends a warning once; repeated failures of the same kind must not flood the menu.
    private func warn(_ message: String) {
        guard !warnings.contains(message) else { return }
        warnings.append(message)
    }
}
