import Foundation
import Testing
import OpenProxyCore
@testable import OpenProxyAppModel

/// A fake server that records lifecycle calls and can fail on `start()`.
private final class FakeServer: ProxyServerControlling, @unchecked Sendable {
    var startError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() async throws {
        startCount += 1
        if let startError { throw startError }
    }

    func stop() async { stopCount += 1 }
}

/// A privileged runner that records scripts and can fail, so `Installer` never
/// touches the keychain or `/etc/hosts` in tests. When `hostsPath` is set it also
/// models the one externally visible effect of the privileged script on that temp
/// file: install adds the managed line, uninstall removes it. Without this the
/// post-install `status()` would still read a routed hosts file and mislead the
/// quit gate that re-checks it.
private final class FakeRunner: PrivilegedRunner, @unchecked Sendable {
    var error: Error?
    var hostsPath: String?
    private(set) var scripts: [String] = []

    func run(script: String) async throws {
        scripts.append(script)
        if let error { throw error }
        guard let hostsPath else { return }
        let text = (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
        let updated = script.contains("127.0.0.1 openrouter.ai # openproxy")
            ? HostsFile.adding(to: text)
            : HostsFile.removing(from: text)
        try? updated.write(toFile: hostsPath, atomically: true, encoding: .utf8)
    }
}

/// An unprivileged command runner that records commands and succeeds by default, so the
/// login-keychain trust phase in `Installer` never touches a real keychain in tests.
/// `errorOnContains` makes one command fail, for the Node-env error path; `delay` slows
/// each command so the refresh-coalescing test can observe overlapping probes.
private final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    var errorOnContains: String?
    var delay: Duration?
    private let lock = NSLock()
    private var recorded: [String] = []
    private var current = 0
    private var peak = 0

    var commands: [String] { lock.withLock { recorded } }
    var maxConcurrent: Int { lock.withLock { peak } }

    func run(_ command: String, timeout: Duration) async -> CommandResult {
        lock.withLock { current += 1; peak = max(peak, current) }
        defer { lock.withLock { current -= 1 } }
        if let delay { try? await Task.sleep(for: delay) }
        lock.withLock { recorded.append(command) }
        if let errorOnContains, command.contains(errorOnContains) {
            return CommandResult(status: 1, standardError: "denied")
        }
        return CommandResult(status: 0)
    }
}

/// Records what would go on the clipboard, so tests never touch the real pasteboard.
@MainActor
private final class FakePasteboard: PasteboardWriting {
    private(set) var copied: [String] = []

    func copy(_ string: String) { copied.append(string) }
}

private struct PortInUse: Error {}
private enum LoginItemTestError: Error { case denied }

/// Records autostart registration and lets a test force the reported status.
private final class FakeLoginItem: LoginItemRegistering, @unchecked Sendable {
    var registerError: Error?
    var status: LoginItemStatus = .enabled
    private(set) var registerCount = 0

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
    }
}

/// Stands in for the NSAlert quit gate: records the chosen answer and any
/// termination, so a test never really quits.
@MainActor
private final class FakeQuitDecision: QuitDecision {
    var choice: QuitChoice = .quitAnyway
    private(set) var decideCount = 0
    private(set) var terminateCount = 0

    func decide() -> QuitChoice {
        decideCount += 1
        return choice
    }

    func terminate() { terminateCount += 1 }
}

@MainActor
private struct Harness {
    let directory: URL
    let settingsStore: SettingsStore
    let stats: StatsStore
    let runner: FakeRunner
    let commandRunner: FakeCommandRunner
    let installer: Installer
    let server: FakeServer
    let loginItem: FakeLoginItem
    let quitDecision: FakeQuitDecision
    let pasteboard: FakePasteboard

    init(hostsText: String? = nil) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "openproxy-app-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hostsURL = directory.appending(path: "hosts")
        if let hostsText { try hostsText.write(to: hostsURL, atomically: true, encoding: .utf8) }
        self.directory = directory
        self.settingsStore = SettingsStore(url: directory.appending(path: "settings.json"))
        self.stats = try StatsStore(path: ":memory:")
        // A real CA so install()'s fingerprint check has a certificate to read.
        let ca = CertAuthority(directory: directory)
        try ca.loadOrCreate()
        self.runner = FakeRunner()
        self.runner.hostsPath = hostsURL.path
        self.commandRunner = FakeCommandRunner()
        self.installer = Installer(
            caPEMURL: ca.caCertificatePEMURL,
            runner: runner,
            commandRunner: commandRunner,
            hostsPath: hostsURL.path)
        self.server = FakeServer()
        self.loginItem = FakeLoginItem()
        self.quitDecision = FakeQuitDecision()
        self.pasteboard = FakePasteboard()
    }

    func model(refreshInterval: Duration = .seconds(5)) -> AppModel {
        AppModel(
            settingsStore: settingsStore, stats: stats, installer: installer,
            server: server, loginItem: loginItem, quitDecision: quitDecision,
            pasteboard: pasteboard, refreshInterval: refreshInterval)
    }

    /// Bounded polling helper: returns false after `timeout` so a missing
    /// background refresh fails the test instead of hanging it.
    @MainActor
    func waitUntil(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

@Suite(.serialized)
@MainActor
struct AppModelTests {
    @Test func settingsPersistToStoreAndDisk() throws {
        let h = try Harness()
        let model = h.model()

        model.settings.sort = .price
        model.settings.tier = .flex

        #expect(h.settingsStore.settings.sort == .price)
        #expect(h.settingsStore.settings.tier == .flex)
        // A fresh store reads the file the first one wrote.
        let reloaded = SettingsStore(url: h.directory.appending(path: "settings.json"))
        #expect(reloaded.settings.sort == .price)
    }

    @Test func enabledFalseLeavesServerRunning() async throws {
        let h = try Harness()
        let model = h.model()
        await model.start()

        model.settings.enabled = false

        #expect(model.settings.enabled == false)
        #expect(h.server.stopCount == 0)
        #expect(h.server.startCount == 1)
    }

    @Test func installFailureBecomesWarningAndDoesNotThrow() async throws {
        let h = try Harness()
        h.runner.error = InstallError.runnerFailed("user cancelled")
        let model = h.model()

        await model.install()

        #expect(model.warnings.count == 1)
        #expect(model.warnings[0].message.contains("Install"))
        // InstallError renders as its message, so the stderr/cancel reason stays readable.
        #expect(model.warnings[0].message.contains("user cancelled"))
        #expect(h.runner.scripts.count == 1)
    }

    @Test func refreshUpdatesSummaryAndStatus() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()
        h.stats.record(RequestRecord(
            time: Date(), path: "/api/v1/chat/completions", sort: .balanced, tier: .auto,
            status: 200, ttfbMs: 12, retries: 0))

        let before = model.summary.total
        await model.refresh()

        #expect(before == 0)
        #expect(model.summary.total == 1)
        #expect(model.status.hostsEntry == true)
    }

    @Test func concurrentRefreshesNeverProbeStatusTogether() async throws {
        // The observed hang: two refresh() rounds ran `installer.status()` at once, leaving
        // two cooperative-pool threads stuck in the child-process wait. Coalescing must
        // serialise the probes.
        let h = try Harness()
        h.commandRunner.delay = .milliseconds(20)
        let model = h.model()

        async let first: Void = model.refresh()
        async let second: Void = model.refresh()
        _ = await (first, second)

        #expect(h.commandRunner.maxConcurrent == 1)
    }

    @Test func refreshTriggeredByUninstallIsNotStarvedByAnInFlightRefresh() async throws {
        // A refresh already in flight (the 5 s loop) must not leave the Uninstall refresh
        // reporting the pre-uninstall hosts state.
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.commandRunner.delay = .milliseconds(20)
        let model = h.model()

        async let loop: Void = model.refresh()
        async let uninstall: Void = model.uninstall()
        _ = await (loop, uninstall)

        #expect(model.status.hostsEntry == false)
    }

    @Test func graphCreatesSupportDirectoryWithOwnerOnlyPermissions() throws {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "openproxy-graph-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        // A clean install has no openproxy directory yet; the graph must create it
        // before the SQLite store tries to open stats.sqlite inside it.
        let base = parent.appending(path: "openproxy")

        _ = try AppGraph.makeModel(baseDirectory: base, quitDecision: FakeQuitDecision())

        #expect(FileManager.default.fileExists(atPath: base.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: base.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
        #expect(FileManager.default.fileExists(atPath: base.appending(path: "stats.sqlite").path))
    }

    @Test func agentPlistUsesBundleRelativeProgramAndConditionalKeepAlive() throws {
        // Guards the LaunchAgent contract: the program path must follow the signed
        // bundle wherever it lives, and KeepAlive must not fight Quit.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenProxyAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let data = try Data(contentsOf: root.appending(path: "Resources/dev.openproxy.app.plist"))
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        #expect(dict["ProgramArguments"] == nil)
        #expect(dict["BundleProgram"] as? String == "Contents/MacOS/OpenProxyApp")
        #expect((dict["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool == false)
    }

    @Test func loginItemRegistrationFailureBecomesWarning() throws {
        let h = try Harness()
        h.loginItem.registerError = LoginItemTestError.denied
        h.loginItem.status = .notFound
        let model = h.model()

        model.registerLoginItem()

        #expect(h.loginItem.registerCount == 1)
        #expect(model.loginItemStatus == .notFound)
        #expect(model.warnings.contains { $0.message.contains("Autostart") })
    }

    @Test func loginItemRequiringApprovalBecomesWarning() throws {
        let h = try Harness()
        h.loginItem.status = .requiresApproval
        let model = h.model()

        model.registerLoginItem()

        #expect(model.loginItemStatus == .requiresApproval)
        #expect(model.warnings.contains { $0.message.contains("Autostart") })
    }

    @Test func loginItemEnabledAddsNoWarning() throws {
        let h = try Harness()
        h.loginItem.status = .enabled
        let model = h.model()

        model.registerLoginItem()

        #expect(model.loginItemStatus == .enabled)
        #expect(model.warnings.isEmpty)
    }

    @Test func refreshReportsLoginItemStatus() async throws {
        let h = try Harness()
        h.loginItem.status = .requiresApproval
        let model = h.model()

        await model.refresh()

        #expect(model.loginItemStatus == .requiresApproval)
    }

    @Test func failedSettingsSaveBecomesWarningAndKeepsValue() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "openproxy-save-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A regular file where the settings directory should be makes createDirectory fail.
        let blocker = dir.appending(path: "blocker")
        try Data("x".utf8).write(to: blocker)

        let store = SettingsStore(url: blocker.appending(path: "settings.json"))
        let model = AppModel(
            settingsStore: store,
            stats: try StatsStore(path: ":memory:"),
            installer: Installer(
                caPEMURL: dir.appending(path: "ca.pem"),
                runner: FakeRunner(),
                commandRunner: FakeCommandRunner(),
                hostsPath: dir.appending(path: "hosts").path),
            server: FakeServer(),
            loginItem: FakeLoginItem(),
            quitDecision: FakeQuitDecision())

        model.settings.sort = .price

        // The in-memory value (UI and per-request reader) stays consistent; only the disk write failed.
        #expect(model.settings.sort == .price)
        #expect(store.settings.sort == .price)
        #expect(model.warnings.contains { $0.message.contains("settings") })
    }

    @Test func legacyCARegenerationBecomesWarning() throws {
        // Item 2: a legacy CA is rotated on load; the app must tell the user their trusted copy is stale.
        let h = try Harness()
        let model = AppModel(
            settingsStore: h.settingsStore, stats: h.stats, installer: h.installer,
            server: h.server, loginItem: h.loginItem, quitDecision: h.quitDecision,
            caWasRegenerated: true)

        #expect(h.model().warnings.isEmpty)
        #expect(model.warnings.contains { $0.message.contains("Uninstall") })
    }

    @Test func menuVisibilityDrivesPeriodicRefresh() async throws {
        let h = try Harness()
        // Default cadence is 5 s; the test uses a fast one instead of sleeping for it.
        #expect(h.model().refreshInterval == .seconds(5))

        let model = h.model(refreshInterval: .milliseconds(5))
        h.stats.record(RequestRecord(
            time: Date(), path: "/api/v1/chat/completions", sort: .balanced, tier: .auto,
            status: 200, ttfbMs: 3, retries: 0))

        model.menuVisibilityChanged(true)
        #expect(await h.waitUntil { model.summary.total == 1 })

        // Hidden again: no further refreshes, so a newly recorded row is not picked up.
        model.menuVisibilityChanged(false)
        try await Task.sleep(for: .milliseconds(50))
        let settled = model.summary.total
        h.stats.record(RequestRecord(
            time: Date(), path: "/api/v1/chat/completions", sort: .balanced, tier: .auto,
            status: 200, ttfbMs: 3, retries: 0))
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.summary.total == settled)
    }

    @Test func hostsEntryWithoutListenerProducesWarning() {
        // Spec 9: hosts routed with no listener blocks every client until Uninstall.
        let down = InstallStatus(caTrusted: false, caPresent: false, hostsEntry: true, portListening: false, nodeCAEnv: false)
        #expect(down.unreachableWarning != nil)
        let up = InstallStatus(caTrusted: false, caPresent: false, hostsEntry: true, portListening: true, nodeCAEnv: false)
        #expect(up.unreachableWarning == nil)
        let notInstalled = InstallStatus(caTrusted: true, caPresent: true, hostsEntry: false, portListening: false, nodeCAEnv: true)
        #expect(notInstalled.unreachableWarning == nil)
    }

    @Test func hostsEntryWithUntrustedCAProducesWarningIndependentOfListener() {
        // Spec 9: hosts routed here with the CA absent or untrusted makes every client's TLS
        // handshake fail, whether or not the proxy is listening.
        let untrusted = InstallStatus(caTrusted: false, caPresent: false, hostsEntry: true, portListening: true, nodeCAEnv: false)
        #expect(untrusted.untrustedCAWarning != nil)
        let presentButUntrusted = InstallStatus(caTrusted: false, caPresent: true, hostsEntry: true, portListening: true, nodeCAEnv: false)
        #expect(presentButUntrusted.untrustedCAWarning != nil)
        let trusted = InstallStatus(caTrusted: true, caPresent: true, hostsEntry: true, portListening: true, nodeCAEnv: false)
        #expect(trusted.untrustedCAWarning == nil)
        let noHosts = InstallStatus(caTrusted: false, caPresent: false, hostsEntry: false, portListening: true, nodeCAEnv: false)
        #expect(noHosts.untrustedCAWarning == nil)
    }

    @Test func modelExposesUntrustedCAWarningFromStatus() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()
        await model.refresh()
        // The fake runner answers `verify-cert` with success, so trust reads as OK here.
        #expect(model.untrustedCAWarning == nil)
    }

    @Test func portInUseBecomesWarningAndLeavesHostsUntouched() async throws {
        let h = try Harness()
        h.server.startError = PortInUse()
        let model = h.model()

        await model.start()

        #expect(model.warnings.count == 1)
        #expect(model.warnings[0].message.lowercased().contains("start"))
        #expect(h.runner.scripts.isEmpty)
    }

    @Test func installStartsServerBeforeTouchingHosts() async throws {
        let h = try Harness()
        let model = h.model()

        await model.install()

        #expect(h.server.startCount == 1)
        #expect(h.runner.scripts.count == 1)
    }

    @Test func installSkippedWhenServerCannotListen() async throws {
        let h = try Harness()
        h.server.startError = PortInUse()
        let model = h.model()

        await model.install()

        // No privileged step ran and the hosts file is left routed as it was.
        #expect(h.runner.scripts.isEmpty)
        #expect(model.warnings.contains { $0.message.contains("Install was skipped") })
    }

    @Test func installDoesNotStartAnAlreadyRunningServer() async throws {
        let h = try Harness()
        let model = h.model()
        await model.start()

        await model.install()

        #expect(h.server.startCount == 1)
        #expect(h.runner.scripts.count == 1)
    }

    @Test func quitWithHostsEntryCanUninstallFirst() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()
        await model.refresh()
        #expect(model.status.hostsEntry)
        h.quitDecision.choice = .uninstallAndQuit

        await model.quit()

        #expect(h.quitDecision.decideCount == 1)
        #expect(h.quitDecision.terminateCount == 1)
        // Uninstall ran before quitting, so the hosts entry and CA are removed.
        #expect(h.runner.scripts.contains { $0.contains("delete-certificate") })
    }

    @Test func quitAnywayLeavesHostsEntryAsIs() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()
        await model.refresh()
        h.quitDecision.choice = .quitAnyway

        await model.quit()

        #expect(h.quitDecision.terminateCount == 1)
        #expect(h.runner.scripts.isEmpty)
    }

    @Test func quitCancelStopsWithoutTerminating() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()
        await model.refresh()
        h.quitDecision.choice = .cancel

        await model.quit()

        #expect(h.quitDecision.decideCount == 1)
        #expect(h.quitDecision.terminateCount == 0)
        #expect(h.runner.scripts.isEmpty)
    }

    @Test func quitWithoutHostsEntryTerminatesWithoutPrompt() async throws {
        let h = try Harness()
        let model = h.model()
        await model.refresh()
        #expect(model.status.hostsEntry == false)

        await model.quit()

        #expect(h.quitDecision.decideCount == 0)
        #expect(h.quitDecision.terminateCount == 1)
    }

    @Test func uninstallAndQuitStaysRunningWhenHostsRemovalFails() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()
        await model.refresh()
        #expect(model.status.hostsEntry)
        // The admin prompt for the hosts edit is dismissed: hosts is never restored.
        h.runner.error = InstallError.runnerFailed("the administrator prompt was dismissed")
        h.quitDecision.choice = .uninstallAndQuit

        await model.quit()

        // Terminating would leave openrouter.ai routed to a dead proxy, so stay running
        // and surface why instead.
        #expect(h.quitDecision.terminateCount == 0)
        #expect(model.status.hostsEntry)
        #expect(model.warnings.contains { $0.message.contains("still routed") })
    }

    @Test func uninstallAndQuitStaysRunningWhenTrustCleanupFails() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()
        await model.refresh()
        #expect(model.status.hostsEntry)
        // The hosts entry is restored, but the login-keychain trust cleanup fails.
        h.commandRunner.errorOnContains = "remove-trusted-cert"
        h.quitDecision.choice = .uninstallAndQuit

        await model.quit()

        // Terminating would silently drop the trustCleanupFailed warning while per-user trust
        // may remain, so stay running and surface it.
        #expect(h.quitDecision.terminateCount == 0)
        #expect(!model.status.hostsEntry)
        #expect(model.warnings.contains { $0.key == .uninstall })
        #expect(model.warnings.contains { $0.key == .quit })
    }

    // MARK: - Item 1: keyed warnings clear on success

    @Test func successfulInstallClearsStaleOperationWarnings() async throws {
        // The real-install bug: a failed Uninstall left "Uninstall failed: …" visible even
        // after a later Install succeeded.
        let h = try Harness()
        let model = h.model()
        h.runner.error = InstallError.runnerFailed("boom")
        await model.uninstall()
        #expect(model.warnings.contains { $0.key == .uninstall })

        h.runner.error = nil
        await model.install()

        #expect(!model.warnings.contains { $0.key == .uninstall })
        #expect(!model.warnings.contains { $0.key == .install })
        #expect(!model.warnings.contains { $0.key == .serverStart })
    }

    @Test func successfulUninstallClearsStaleInstallWarning() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()
        h.runner.error = InstallError.runnerFailed("boom")
        await model.install()
        #expect(model.warnings.contains { $0.key == .install })

        h.runner.error = nil
        await model.uninstall()

        #expect(model.warnings.isEmpty)
    }

    @Test func successfulInstallClearsLegacyCAWarningOnceTrustedAndRouted() async throws {
        let h = try Harness()
        let model = AppModel(
            settingsStore: h.settingsStore, stats: h.stats, installer: h.installer,
            server: h.server, loginItem: h.loginItem, quitDecision: h.quitDecision,
            caWasRegenerated: true)
        #expect(model.warnings.contains { $0.key == .legacyCA })

        await model.install()

        #expect(!model.warnings.contains { $0.key == .legacyCA })
    }

    @Test func legacyCAWarningStaysUntilTrustedAndRouted() async throws {
        let h = try Harness()
        let model = AppModel(
            settingsStore: h.settingsStore, stats: h.stats, installer: h.installer,
            server: h.server, loginItem: h.loginItem, quitDecision: h.quitDecision,
            caWasRegenerated: true)

        await model.refresh()

        #expect(model.warnings.contains { $0.key == .legacyCA })
    }

    // MARK: - Item 2: Node CA env actions

    @Test func copyNodeCALinePutsExportOnPasteboard() throws {
        let h = try Harness()
        let model = h.model()

        model.copyNodeCALine()

        #expect(h.pasteboard.copied == ["export NODE_EXTRA_CA_CERTS=\"\(h.installer.caPEMPath)\""])
    }

    @Test func setNodeCAEnvForGUIAppsRunsLaunchctl() async throws {
        let h = try Harness()
        let model = h.model()

        await model.setNodeCAEnvForGUIApps()

        #expect(h.commandRunner.commands.contains {
            $0.contains("launchctl setenv NODE_EXTRA_CA_CERTS")
        })
        #expect(model.warnings.isEmpty)
    }

    @Test func setNodeCAEnvFailureBecomesWarning() async throws {
        let h = try Harness()
        h.commandRunner.errorOnContains = "launchctl setenv"
        let model = h.model()

        await model.setNodeCAEnvForGUIApps()

        #expect(model.warnings.contains { $0.key == .nodeEnv })
    }

    // MARK: - Item 3: one-time restart notice after Install

    @Test func successfulInstallShowsRestartNotice() async throws {
        let h = try Harness()
        let model = h.model()

        await model.install()

        #expect(model.installNotice?.contains("opencode service restart") == true)
    }

    @Test func failedInstallShowsNoRestartNotice() async throws {
        let h = try Harness()
        h.runner.error = InstallError.runnerFailed("user cancelled")
        let model = h.model()

        await model.install()

        #expect(model.installNotice == nil)
    }

    @Test func dismissInstallNoticeClearsIt() async throws {
        let h = try Harness()
        let model = h.model()
        await model.install()

        model.dismissInstallNotice()

        #expect(model.installNotice == nil)
    }

    @Test func uninstallClearsInstallNotice() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()
        await model.install()
        #expect(model.installNotice != nil)

        await model.uninstall()

        #expect(model.installNotice == nil)
    }
}
