import Foundation
import Observation
import OpenProxyCore

/// The proxy server as the UI needs it: start and stop, nothing more.
public protocol ProxyServerControlling: Sendable {
    func start() async throws
    func stop() async
}

extension ProxyServer: ProxyServerControlling {}

/// What the user chose when quitting with `openrouter.ai` still routed here.
public enum QuitChoice: Equatable, Sendable {
    case uninstallAndQuit
    case quitAnyway
    case cancel
}

/// Shows the quit confirmation and performs the real termination. The production
/// implementation uses `NSAlert` (app target); tests inject a fake so the menu
/// logic is exercised without quitting the test runner.
@MainActor
public protocol QuitDecision: Sendable {
    func decide() -> QuitChoice
    func terminate()
}

/// A warning's category. Keyed so a finished operation clears exactly the warnings it
/// resolves (install/uninstall/start/quit) and leaves still-true ones (settings save,
/// autostart, Node env) visible, instead of blanket-clearing on every success.
public enum WarningKey: Hashable, Sendable {
    case settingsSave
    case legacyCA
    case serverStart
    case install
    case uninstall
    case quit
    case autostart
    case nodeEnv
}

public struct Warning: Equatable, Sendable, Identifiable {
    public let key: WarningKey
    public let message: String
    public var id: WarningKey { key }

    public init(key: WarningKey, message: String) {
        self.key = key
        self.message = message
    }
}

extension InstallStatus {
    /// Spec 9: with the hosts entry installed but nothing listening on 443, every
    /// client's `openrouter.ai` is broken until the proxy runs or the user uninstalls.
    public var unreachableWarning: String? {
        guard hostsEntry, !portListening else { return nil }
        return "openrouter.ai is routed to 127.0.0.1 but the proxy is not listening, "
            + "so all clients are blocked. Press Uninstall to restore access."
    }

    /// Spec 9: with the hosts entry installed but the CA absent or untrusted, every
    /// client's TLS handshake fails — independent of whether the proxy is listening.
    public var untrustedCAWarning: String? {
        guard hostsEntry, !caTrusted else { return nil }
        return "openrouter.ai is routed to 127.0.0.1 but the CA is missing or not trusted, "
            + "so every client's TLS handshake fails. Press Uninstall to restore access, then Install again."
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
                warn(.settingsSave, "Could not save settings: \(error).")
            }
        }
    }

    public private(set) var status: InstallStatus
    public private(set) var summary: StatsSummary
    public private(set) var warnings: [Warning] = []
    public private(set) var loginItemStatus: LoginItemStatus = .notRegistered

    /// Derived from `status`, so it stays visible for as long as the danger lasts
    /// (proxy quit/crashed with the hosts entry still routed) and clears itself.
    public var unreachableWarning: String? { status.unreachableWarning }

    /// Derived from `status`: hosts routed here with the CA missing or untrusted, shown
    /// independently of the listener state because TLS fails for every client either way.
    public var untrustedCAWarning: String? { status.untrustedCAWarning }

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
    private let quitDecision: QuitDecision
    private let pasteboard: PasteboardWriting

    public init(
        settingsStore: SettingsStore,
        stats: StatsStore,
        installer: Installer,
        server: ProxyServerControlling,
        loginItem: LoginItemRegistering,
        quitDecision: QuitDecision,
        pasteboard: PasteboardWriting = NSPasteboardWriter(),
        caWasRegenerated: Bool = false,
        refreshInterval: Duration = .seconds(5)
    ) {
        self.settingsStore = settingsStore
        self.stats = stats
        self.installer = installer
        self.server = server
        self.loginItem = loginItem
        self.quitDecision = quitDecision
        self.pasteboard = pasteboard
        self.refreshInterval = refreshInterval
        self.currentSettings = settingsStore.settings
        self.status = InstallStatus(caTrusted: false, caPresent: false, hostsEntry: false, portListening: false, nodeCAEnv: false)
        self.summary = StatsSummary()
        if caWasRegenerated {
            warn(.legacyCA, "The local CA was regenerated because it predates this version; the trusted copy is stale. Run Uninstall, then Install again.")
        }
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
            warn(.serverStart, "Proxy server failed to start: \(error). \(suffix)")
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
            // The stale install/uninstall/start/quit warnings are no longer true.
            clearWarnings(Self.operationWarningKeys)
        } catch {
            warn(.install, "Install failed: \(error). The system was not fully changed.")
        }
        await refresh()
    }

    public func uninstall() async {
        do {
            try await installer.uninstall()
            clearWarnings(Self.operationWarningKeys)
        } catch {
            warn(.uninstall, "Uninstall failed: \(error).")
        }
        await refresh()
    }

    /// Spec 9 / finding: quitting with the hosts entry installed leaves
    /// `openrouter.ai` routed to a dead proxy, so confirm before terminating.
    public func quit() async {
        if status.hostsEntry {
            switch quitDecision.decide() {
            case .cancel:
                return
            case .quitAnyway:
                break
            case .uninstallAndQuit:
                await uninstall()
                // Terminate only once the hosts entry is confirmed gone: a cancelled or
                // failed uninstall would otherwise leave openrouter.ai pointing at a dead
                // listener the moment the app exits.
                if status.hostsEntry {
                    warn(.quit, "Quit was cancelled: openrouter.ai is still routed to this Mac, so quitting "
                        + "would break every client. Fix the uninstall problem, then quit again.")
                    return
                }
            }
        }
        quitDecision.terminate()
    }

    public func refresh() async {
        summary = stats.summary(since: Date(timeIntervalSinceNow: -86_400))
        status = await installer.status()
        loginItemStatus = loginItem.status
        // The regenerated-CA warning stops being true once the current CA is trusted and
        // its hosts entry is in place; until then it stays visible.
        if status.caTrusted && status.hostsEntry {
            clearWarnings([.legacyCA])
        }
    }

    /// Puts the `export NODE_EXTRA_CA_CERTS=…` line on the pasteboard for the user's shell
    /// profile. The app never edits a profile itself.
    public func copyNodeCALine() {
        pasteboard.copy(Installer.nodeCAExportLine(caPEMPath: installer.caPEMPath))
    }

    /// Sets `NODE_EXTRA_CA_CERTS` for GUI apps launched from now on. Running processes keep
    /// their old environment, which is why the menu tells the user to restart them.
    public func setNodeCAEnvForGUIApps() async {
        do {
            try await installer.applyNodeCAEnv()
        } catch {
            warn(.nodeEnv, "Could not set NODE_EXTRA_CA_CERTS: \(error).")
        }
        await refresh()
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
            warn(.autostart, "Autostart registration failed: \(error).")
            return
        }
        loginItemStatus = loginItem.status
        if loginItemStatus != .enabled {
            warn(.autostart, "Autostart is \(loginItemStatus.label).")
        }
    }

    /// Records or replaces the warning for `key`; one message per category, so repeated
    /// failures of the same kind do not flood the menu.
    private func warn(_ key: WarningKey, _ message: String) {
        warnings.removeAll { $0.key == key }
        warnings.append(Warning(key: key, message: message))
    }

    private func clearWarnings(_ keys: Set<WarningKey>) {
        warnings.removeAll { keys.contains($0.key) }
    }

    /// The warnings a completed install/uninstall resolves. The legacy-CA warning clears
    /// separately, only once the current CA is trusted and routed (see `refresh`).
    private static let operationWarningKeys: Set<WarningKey> = [.install, .uninstall, .serverStart, .quit]
}
