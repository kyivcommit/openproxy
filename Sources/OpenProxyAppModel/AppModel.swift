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
    /// Restore access: remove the hosts entry and autostart, then quit. The CA, its trust,
    /// the root helper and the local data stay; the menu's Uninstall OpenProxy... removes
    /// everything.
    case restoreAccessAndQuit
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
            + "so all clients are blocked."
    }

    /// Spec 9: with the hosts entry installed but the CA absent or untrusted, every
    /// client's TLS handshake fails — independent of whether the proxy is listening.
    public var untrustedCAWarning: String? {
        guard hostsEntry, !caTrusted else { return nil }
        return "openrouter.ai is routed to 127.0.0.1 but the CA is missing or not trusted, "
            + "so every client's TLS handshake fails."
    }

    /// The Node-env row text when `NODE_EXTRA_CA_CERTS` is set but no CA is installed (for
    /// example a leftover from an install whose CA was later removed): the value is set, but
    /// it is not usable, so the row must not read as a clean check mark.
    public var nodeCAEnvNote: String? {
        nodeCAEnv && !caPresent ? "set (CA not installed)" : nil
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
    /// The root helper's registration state, refreshed with the rest of the status.
    public private(set) var helperStatus: HelperStatus = .notFound
    /// The compact "Routing:" line: inactive / setting up... / waiting for approval... / active.
    public private(set) var routingState: RoutingState = .inactive
    public var routingLabel: String { routingState.label }

    /// Derived from `status`, so it stays visible for as long as the danger lasts
    /// (proxy quit/crashed with the hosts entry still routed) and clears itself.
    public var unreachableWarning: String? { status.unreachableWarning }

    /// Derived from `status`: hosts routed here with the CA missing or untrusted, shown
    /// independently of the listener state because TLS fails for every client either way.
    public var untrustedCAWarning: String? { status.untrustedCAWarning }

    /// How often an open menu refreshes the summary and status.
    public let refreshInterval: Duration

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Refresh requests waiting for the next round of status probes. Coalescing means at
    /// most one `installer.status()` runs at a time; requesters that arrive mid-round get a
    /// fresh round, so an Install/Uninstall refresh is neither concurrent nor starved.
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var refreshRunning = false

    /// Whether `server.start()` already bound the port. Guards Install from a
    /// second bind (and from installing hosts before anything listens).
    private var serverRunning = false

    private var currentSettings: Settings
    private let settingsStore: SettingsStore
    private let stats: StatsStore
    private let installer: Installer
    private let server: ProxyServerControlling
    private let loginItem: LoginItemRegistering
    private let helper: HelperRegistering
    private let quitDecision: QuitDecision
    private let setupDecision: SetupDecision
    private let uninstallDecision: UninstallDecision
    private let dataRemover: AppDataRemoving
    private let waiting: SetupWaiting
    private let maxApprovalPolls: Int

    public init(
        settingsStore: SettingsStore,
        stats: StatsStore,
        installer: Installer,
        server: ProxyServerControlling,
        loginItem: LoginItemRegistering,
        quitDecision: QuitDecision,
        helper: HelperRegistering = NoHelperRegistration(),
        setupDecision: SetupDecision = NoSetupDecision(),
        uninstallDecision: UninstallDecision = NoUninstallDecision(),
        dataRemover: AppDataRemoving = NoAppDataRemoving(),
        waiting: SetupWaiting = ImmediateSetupWaiting(),
        maxApprovalPolls: Int = 300,
        caWasRegenerated: Bool = false,
        refreshInterval: Duration = .seconds(5)
    ) {
        self.settingsStore = settingsStore
        self.stats = stats
        self.installer = installer
        self.server = server
        self.loginItem = loginItem
        self.helper = helper
        self.quitDecision = quitDecision
        self.setupDecision = setupDecision
        self.uninstallDecision = uninstallDecision
        self.dataRemover = dataRemover
        self.waiting = waiting
        self.maxApprovalPolls = maxApprovalPolls
        self.refreshInterval = refreshInterval
        self.currentSettings = settingsStore.settings
        self.status = InstallStatus(caTrusted: false, caPresent: false, hostsEntry: false, portListening: false, nodeCAEnv: false)
        self.summary = StatsSummary()
        self.helperStatus = helper.status
        if caWasRegenerated {
            warn(.legacyCA, "The local CA was regenerated because it predates this version; the trusted copy is stale. Uninstall OpenProxy, then launch again.")
        }
    }

    public func start() async {
        guard await startServer(ifFailed: "The hosts entry was left unchanged.") else { return }
        await refresh()
        await setupOrRestoreRouting()
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

    /// First launch: ask once, then run the automatic setup. Later launches: silently restore
    /// the route when the setup is already complete.
    private func setupOrRestoreRouting() async {
        guard settings.setupComplete else {
            guard setupDecision.confirmSetup() else { return }
            await install()
            return
        }
        await restoreRouting()
    }

    /// True when the menu should offer Retry setup: the setup never completed and it is not
    /// currently running.
    public var canRetrySetup: Bool {
        guard !settings.setupComplete else { return false }
        switch routingState {
        case .waitingForApproval, .error: return true
        case .inactive, .settingUp, .active: return false
        }
    }

    /// The menu's Retry setup action: the same flow as Continue, without the welcome dialog.
    public func retrySetup() async {
        guard canRetrySetup else { return }
        await install()
    }

    /// The automatic setup, in order: CA trust, helper (waiting for approval instead of
    /// failing), autostart (also a wait when approval is pending), the hosts entry, then the
    /// Node env. `setupComplete` is set only when the critical steps succeed.
    public func install() async {
        guard await startServer(ifFailed: "Setup was skipped; the hosts entry was left unchanged.") else {
            await refresh()
            return
        }
        routingState = .settingUp
        do {
            // (a) CA trust: verify first, so an already-trusted CA never shows the dialog.
            try await installer.trustCA()

            // (b) helper: register once; approval is a wait, not a failure.
            switch installer.helperReadiness() {
            case .enabled, .unavailable:
                break
            case .requiresApproval:
                installer.openHelperApprovalSettings()
                routingState = .waitingForApproval
                guard await waitForHelperApproval() else {
                    warn(.install, "Timed out waiting for approval in System Settings -> Login Items.")
                    routingState = .error("waiting for approval timed out")
                    await refresh()
                    return
                }
            }

            // (c) autostart: a LaunchAgent must be enabled before anything routes here, or a
            // crash would leave openrouter.ai pointing at a dead proxy. Pending approval is a
            // wait, not a failure, so poll it with the injected clock.
            registerLoginItem()
            if loginItemStatus != .enabled {
                routingState = .waitingForApproval
                guard await waitForAutostartEnabled() else {
                    warn(.install, "Timed out waiting for autostart approval in System Settings -> "
                        + "Login Items. The openrouter.ai route was not added; choose Retry setup "
                        + "in the OpenProxy menu once autostart is enabled.")
                    routingState = .error("waiting for autostart approval timed out")
                    await refresh()
                    return
                }
            }

            // (d) hosts entry (helper when enabled, osascript otherwise)
            try await installer.setHostsEntry(present: true)

            // (e) Node env, best effort: routing already works without it.
            do {
                try await installer.applyNodeCAEnv()
                clearWarnings([.nodeEnv])
            } catch {
                warn(.nodeEnv, "Could not set NODE_EXTRA_CA_CERTS: \(error).")
            }

            settings.setupComplete = true
            routingState = .active
            clearWarnings(Self.operationWarningKeys)
        } catch {
            warn(.install, Self.installFailureMessage(error))
            routingState = .error(String(describing: error))
        }
        await refresh()
    }

    /// Polls the helper status until it becomes enabled, or gives up after the poll budget.
    private func waitForHelperApproval() async -> Bool {
        for _ in 0..<maxApprovalPolls {
            if helper.status == .enabled {
                helperStatus = .enabled
                return true
            }
            await waiting.waitForNextApprovalPoll()
            helperStatus = helper.status
            if helperStatus == .enabled { return true }
        }
        return false
    }

    /// Polls the autostart status until it becomes enabled, or gives up after the poll budget.
    /// Approval also resolves the pending-approval warning from `registerLoginItem()`.
    private func waitForAutostartEnabled() async -> Bool {
        for _ in 0..<maxApprovalPolls {
            if loginItem.status == .enabled {
                loginItemStatus = .enabled
                clearWarnings([.autostart])
                return true
            }
            await waiting.waitForNextApprovalPoll()
            loginItemStatus = loginItem.status
            if loginItemStatus == .enabled {
                clearWarnings([.autostart])
                return true
            }
        }
        return false
    }

    /// Every later launch: if the CA is trusted, the helper is enabled, autostart is enabled and
    /// the hosts entry is missing, re-add it silently. Never runs when the proxy could not bind,
    /// and never adds the route while autostart is off.
    private func restoreRouting() async {
        guard serverRunning else { return }
        guard status.caTrusted, helperStatus == .enabled, loginItemStatus == .enabled,
              !status.hostsEntry
        else {
            if status.hostsEntry { routingState = .active }
            return
        }
        routingState = .settingUp
        do {
            try await installer.setHostsEntry(present: true)
            routingState = .active
            await refresh()
        } catch {
            warn(.install, "Could not restore the openrouter.ai route: \(error).")
            routingState = .error(String(describing: error))
        }
    }

    /// Restores `/etc/hosts` only (no CA teardown). Kept for the Quit fallback popup.
    public func uninstall() async {
        do {
            try await installer.uninstall()
            clearWarnings(Self.operationWarningKeys)
            unregisterLoginItem()
        } catch {
            warn(.uninstall, "Uninstall failed: \(error).")
        }
        await refresh()
    }

    /// The legacy CA teardown (admin trust, System keychain sweep, user-domain trust, helper
    /// unregister). Used by the full uninstall flow; kept callable for the popup safety net.
    public func removeCA() async {
        do {
            try await installer.removeCA()
            clearWarnings(Self.operationWarningKeys)
            unregisterLoginItem()
        } catch {
            warn(.uninstall, "Removing the CA failed: \(error).")
        }
        await refresh()
    }

    /// Menu "Uninstall OpenProxy...": confirm, then the full teardown. Restoring `/etc/hosts`
    /// is attempted first and is never skipped by a later failure; every step is collected so
    /// the app only wipes its data and quits when nothing is left behind.
    public func uninstallOpenProxy() async {
        guard uninstallDecision.confirmUninstall() else { return }
        routingState = .settingUp
        var failures: [String] = []

        // 1. Restore /etc/hosts first — the safety-critical step. If the call failed, only
        // continue when the entry is confirmed gone; otherwise stopping is the safe choice,
        // since continuing would drop autostart and the CA while clients are still routed to a
        // dead proxy. `unknown` (the file could not be read or decoded) stops too: it is not
        // evidence that the entry is gone.
        do {
            try await installer.setHostsEntry(present: false)
        } catch {
            switch installer.hostsEntryState() {
            case .absent:
                break // The call reported an error but the entry is really gone: step succeeded.
            case .present:
                warn(.uninstall, "Uninstall stopped: openrouter.ai is still routed to this Mac "
                    + "because /etc/hosts could not be restored: \(error). Fix it and try again.")
                routingState = .error("uninstall stopped: /etc/hosts could not be restored")
                return
            case .unknown:
                warn(.uninstall, "Uninstall stopped: could not confirm that /etc/hosts was restored "
                    + "because the file could not be read: \(error). Fix it and try again.")
                routingState = .error("uninstall stopped: /etc/hosts could not be restored")
                return
            }
        }

        // 2. Autostart off.
        if let failure = unregisterLoginItem() {
            failures.append(failure)
        }

        // 3. CA trust + keychains + helper unregister.
        do {
            try await installer.removeCA()
        } catch {
            failures.append("CA cleanup: \(error)")
        }

        // 4. Only wipe the data (removeCA reads ca.pem to retry) and quit when every step
        // succeeded.
        guard failures.isEmpty else {
            warn(.uninstall, "Uninstall incomplete: \(failures.joined(separator: "; ")). Try again.")
            routingState = .error("uninstall incomplete")
            return
        }
        do {
            try dataRemover.removeAppData()
        } catch {
            warn(.uninstall, "Uninstall incomplete: could not remove OpenProxy data: \(error). Try again.")
            routingState = .error("uninstall incomplete")
            return
        }

        // 5. Quit.
        routingState = .inactive
        quitDecision.terminate()
    }

    /// Spec 9 / finding: quitting with the hosts entry installed leaves
    /// `openrouter.ai` routed to a dead proxy, so confirm before terminating.
    public func quit() async {
        // With the approved helper, quitting silently restores access to openrouter.ai; the
        // next launch's setupComplete restore puts it back — no popup needed.
        if helperStatus == .enabled {
            do {
                try await installer.setHostsEntry(present: false)
                quitDecision.terminate()
                return
            } catch {
                // A failing helper must not trap the user in the app: fall through to the
                // confirmation popup, which still guards the routed hosts entry.
                warn(.quit, "The root helper could not restore access to openrouter.ai: \(error).")
            }
        }
        // Read the hosts entry fresh, never the cached `status`: Installer.status() maps a
        // read/decoding error to `false`, so trusting it could quit silently while
        // openrouter.ai is still routed here. Only a confirmed `.absent` is safe to quit on.
        switch installer.hostsEntryState() {
        case .absent:
            quitDecision.terminate()
        case .present:
            await quitAfterConfirmation()
        case .unknown:
            warn(.quit, "The hosts file could not be read, so OpenProxy could not confirm that "
                + "openrouter.ai is no longer routed here.")
            await quitAfterConfirmation()
        }
    }

    /// The fallback confirmation: the popup's choices, then the existing safety checks, all
    /// against the fresh hosts state rather than the cached status.
    private func quitAfterConfirmation() async {
        switch quitDecision.decide() {
        case .cancel:
            return
        case .quitAnyway:
            break
        case .restoreAccessAndQuit:
            await uninstall()
            // Terminate only once the hosts entry is confirmed gone: a cancelled or
            // failed uninstall would otherwise leave openrouter.ai pointing at a dead
            // listener the moment the app exits.
            guard installer.hostsEntryState() == .absent else {
                warn(.quit, "Quit was cancelled: openrouter.ai is still routed to this Mac, so quitting "
                    + "would break every client. Fix the uninstall problem, then quit again.")
                return
            }
            // Finding 4: hosts was restored but the leftover CA-trust cleanup failed, so
            // terminating now would drop that warning and leave per-user trust behind.
            if warnings.contains(where: { $0.key == .uninstall }) {
                warn(.quit, "Quit was cancelled: openrouter.ai access was restored, but the CA trust "
                    + "could not be fully removed, so per-user trust may remain. Fix it, then quit again.")
                return
            }
        }
        quitDecision.terminate()
    }

    /// Refreshes the summary and status. Only one round of status probes runs at a time:
    /// concurrent callers queue behind the in-flight round and are served by the next one,
    /// so the 5 s loop and an Install/Uninstall refresh neither run two `status()` probes
    /// together (two stuck child-process waits in the observed hang) nor starve each other.
    public func refresh() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            refreshWaiters.append(continuation)
            guard !refreshRunning else { return }
            refreshRunning = true
            Task { @MainActor in await self.drainRefreshes() }
        }
    }

    private func drainRefreshes() async {
        while !refreshWaiters.isEmpty {
            // Snapshot before probing: a caller that arrives during this round (an Uninstall
            // that just changed the hosts file) is served by a fresh next round instead of
            // the in-flight snapshot taken before its change.
            let waiters = refreshWaiters
            refreshWaiters.removeAll()
            summary = stats.summary(since: Date(timeIntervalSinceNow: -86_400))
            status = await installer.status()
            loginItemStatus = loginItem.status
            helperStatus = helper.status
            // The regenerated-CA warning stops being true once the current CA is trusted and
            // its hosts entry is in place; until then it stays visible.
            if status.caTrusted && status.hostsEntry {
                clearWarnings([.legacyCA])
            }
            // A later launch that already has the route shows it as active without a restore.
            if settings.setupComplete, status.hostsEntry, routingState == .inactive {
                routingState = .active
            }
            waiters.forEach { $0.resume() }
        }
        refreshRunning = false
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
            // SMAppService.register() throws "Operation not permitted" while approval is
            // pending; that is the expected one-time state, so show the approval hint, not
            // the raw error. Any other error keeps its text.
            if loginItemStatus == .requiresApproval {
                warn(.autostart, Self.autostartApprovalMessage)
            } else {
                warn(.autostart, "Autostart registration failed: \(error).")
            }
            return
        }
        loginItemStatus = loginItem.status
        if loginItemStatus == .requiresApproval {
            warn(.autostart, Self.autostartApprovalMessage)
        } else if loginItemStatus != .enabled {
            warn(.autostart, "Autostart is \(loginItemStatus.label).")
        } else {
            clearWarnings([.autostart])
        }
    }

    /// Shown instead of the raw "Operation not permitted" error while approval is pending.
    private static let autostartApprovalMessage =
        "Autostart needs approval in System Settings -> Login Items"

    /// One sentence, one period: the thrown text may already end with a period (the approval
    /// and helper-not-responding messages do), and the wrapper used to append a second.
    static func installFailureMessage(_ error: any Error) -> String {
        var detail = String(describing: error)
        while detail.hasSuffix(".") { detail.removeLast() }
        return "Install failed: \(detail). The system was not fully changed."
    }

    /// Turns autostart off, reporting a failure as a warning. Never throws: the hosts entry
    /// has already been restored, so a failed unregister must not undo that or block the flow.
    /// Turns autostart off. Never throws: returns the failure detail (and warns) when it
    /// fails, so the full uninstall can list it without aborting the flow.
    @discardableResult
    private func unregisterLoginItem() -> String? {
        do {
            try loginItem.unregister()
            loginItemStatus = loginItem.status
            clearWarnings([.autostart])
            return nil
        } catch {
            loginItemStatus = loginItem.status
            let message = "Autostart could not be turned off: \(error)."
            warn(.autostart, message)
            return message
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
