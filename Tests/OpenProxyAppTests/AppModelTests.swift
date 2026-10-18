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
    var onRun: (() -> Void)?
    private(set) var scripts: [String] = []

    func run(script: String) async throws {
        scripts.append(script)
        onRun?()
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
    var onCommand: ((String) -> Void)?
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
        onCommand?(command)
        if let errorOnContains, command.contains(errorOnContains) {
            return CommandResult(status: 1, standardError: "denied")
        }
        return CommandResult(status: 0)
    }
}

private struct PortInUse: Error {}
private enum LoginItemTestError: Error { case denied }

/// An upstream client that fails every send, for the endpoints-fetcher error path.
private final class FailingUpstreamClient: UpstreamClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [UpstreamRequest] = []

    var requests: [UpstreamRequest] { lock.withLock { _requests } }

    func send(_ request: UpstreamRequest) async throws -> UpstreamResponse {
        lock.withLock { _requests.append(request) }
        return UpstreamResponse(status: 500, headers: [], body: AsyncThrowingStream { $0.finish() })
    }
}

/// Records autostart registration and lets a test force the reported status.
private final class FakeLoginItem: LoginItemRegistering, @unchecked Sendable {
    var registerError: Error?
    var unregisterError: Error?
    var status: LoginItemStatus = .enabled
    /// What `register()` reports on the immediate re-read, even when it throws.
    var statusAfterRegister: LoginItemStatus?
    var onRegister: (() -> Void)?
    var onUnregister: (() -> Void)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    func register() throws {
        registerCount += 1
        onRegister?()
        // SMAppService can throw and still change the status (approval pending).
        if let statusAfterRegister { status = statusAfterRegister }
        if let registerError { throw registerError }
    }

    func unregister() throws {
        unregisterCount += 1
        onUnregister?()
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

/// Records root-helper registration and lets a test force the reported status.
private final class FakeHelper: HelperRegistering, @unchecked Sendable {
    var status: HelperStatus = .notFound
    var registerError: Error?
    var statusAfterRegister: HelperStatus?
    var onRegister: (() -> Void)?
    private(set) var registerCount = 0
    private(set) var openApprovalCount = 0

    func register() throws {
        registerCount += 1
        onRegister?()
        if let registerError { throw registerError }
        if let statusAfterRegister { status = statusAfterRegister }
    }

    func openApprovalSettings() { openApprovalCount += 1 }
}

/// Records the hosts edit the installer would route through the helper.
private final class FakeHostsEditor: HostsEditing, @unchecked Sendable {
    var error: Error?
    var onRequest: (() -> Void)?
    private let lock = NSLock()
    private var recorded: [Bool] = []

    var requests: [Bool] { lock.withLock { recorded } }

    func setHostsEntry(present: Bool) async throws {
        lock.withLock { recorded.append(present) }
        onRequest?()
        if let error { throw error }
    }
}

/// Stands in for the NSAlert quit gate: records the chosen answer and any
/// termination, so a test never really quits.
@MainActor
private final class FakeQuitDecision: QuitDecision {
    var choice: QuitChoice = .quitAnyway
    var onTerminate: (() -> Void)?
    private(set) var decideCount = 0
    private(set) var terminateCount = 0

    func decide() -> QuitChoice {
        decideCount += 1
        return choice
    }

    func terminate() {
        terminateCount += 1
        onTerminate?()
    }
}

/// Records the order of setup/uninstall steps so the flows can be asserted in sequence.
private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) { lock.withLock { events.append(event) } }

    /// First occurrence of each distinct event, in order.
    var sequence: [String] {
        var seen: [String] = []
        for event in lock.withLock({ events }) where !seen.contains(event) { seen.append(event) }
        return seen
    }
}

@MainActor
private final class FakeSetupDecision: SetupDecision {
    var confirm = false
    private(set) var count = 0
    func confirmSetup() -> Bool { count += 1; return confirm }
}

@MainActor
private final class FakeUninstallDecision: UninstallDecision {
    var confirm = false
    private(set) var count = 0
    func confirmUninstall() -> Bool { count += 1; return confirm }
}

private final class FakeWaiting: SetupWaiting, @unchecked Sendable {
    var onPoll: (() -> Void)?
    private(set) var count = 0
    func waitForNextApprovalPoll() async {
        count += 1
        onPoll?()
    }
}

private final class FakeDataRemover: AppDataRemoving, @unchecked Sendable {
    var error: Error?
    var onRemove: (() -> Void)?
    private(set) var count = 0
    func removeAppData() throws {
        count += 1
        onRemove?()
        if let error { throw error }
    }
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
    let helper: FakeHelper
    let hostsEditor: FakeHostsEditor
    let quitDecision: FakeQuitDecision
    let setupDecision: FakeSetupDecision
    let uninstallDecision: FakeUninstallDecision
    let waiting: FakeWaiting
    let dataRemover: FakeDataRemover
    let orderLog: OrderLog

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
        self.hostsEditor = FakeHostsEditor()
        self.helper = FakeHelper()
        self.installer = Installer(
            caPEMURL: ca.caCertificatePEMURL,
            runner: runner,
            commandRunner: commandRunner,
            hostsPath: hostsURL.path,
            hostsEditor: hostsEditor,
            helper: helper)
        self.server = FakeServer()
        self.loginItem = FakeLoginItem()
        self.quitDecision = FakeQuitDecision()
        self.setupDecision = FakeSetupDecision()
        self.uninstallDecision = FakeUninstallDecision()
        self.waiting = FakeWaiting()
        self.dataRemover = FakeDataRemover()

        // Wire the step-order log; each fake appends its own step name as it runs.
        let orderLog = OrderLog()
        self.orderLog = orderLog
        let runner = self.runner
        runner.onRun = { [orderLog] in
            let isCA = runner.scripts.last?.contains("delete-certificate") == true
            orderLog.append(isCA ? "ca" : "hosts")
        }
        self.commandRunner.onCommand = { [orderLog] command in
            if command.contains("verify-cert") || command.contains("add-trusted-cert") {
                orderLog.append("trust")
            }
            if command.contains("setenv") { orderLog.append("nodeenv") }
        }
        self.loginItem.onRegister = { [orderLog] in orderLog.append("autostart") }
        self.loginItem.onUnregister = { [orderLog] in orderLog.append("autostart") }
        self.helper.onRegister = { [orderLog] in orderLog.append("helper") }
        self.hostsEditor.onRequest = { [orderLog] in orderLog.append("hosts") }
        self.quitDecision.onTerminate = { [orderLog] in orderLog.append("quit") }
        self.dataRemover.onRemove = { [orderLog] in orderLog.append("data") }
    }

    func model(maxApprovalPolls: Int = 1, refreshInterval: Duration = .seconds(5)) -> AppModel {
        AppModel(
            settingsStore: settingsStore, stats: stats, installer: installer,
            server: server, loginItem: loginItem, quitDecision: quitDecision,
            helper: helper,
            setupDecision: setupDecision,
            uninstallDecision: uninstallDecision,
            dataRemover: dataRemover,
            waiting: waiting,
            maxApprovalPolls: maxApprovalPolls,
            refreshInterval: refreshInterval)
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

    @Test func smartPriceAndPollMinutesPersistToDisk() throws {
        // Item 5: the Sort picker's Smart price and the refresh stepper both go through
        // the settings store, so a restart keeps them.
        let h = try Harness()
        let model = h.model()

        model.settings.sort = .smartPrice
        model.settings.pollMinutes = 30
        // The stepper range clamps out-of-range values on the way in.
        model.settings.pollMinutes = 90

        let reloaded = SettingsStore(url: h.directory.appending(path: "settings.json"))
        #expect(reloaded.settings.sort == .smartPrice)
        #expect(reloaded.settings.pollMinutes == 60)
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

    @Test func endpointsFetcherKeepsTheKeyOutOfItsErrorsAndOffKeylessCalls() async throws {
        let client = FailingUpstreamClient()
        let fetcher = UpstreamEndpointsFetcher(client: client)
        let secret = "Bearer sk-secret-key"

        // Keyed fetch: the header goes to the endpoints request only, and never into the error.
        do {
            _ = try await fetcher.fetch(modelId: "deepseek/deepseek-v4.1-flash", authorization: secret)
            Issue.record("the failing upstream should make the fetch throw")
        } catch {
            #expect(!String(describing: error).contains(secret))
        }
        let keyed = try #require(client.requests.first)
        #expect(keyed.path == "/api/v1/models/deepseek/deepseek-v4.1-flash/endpoints")
        #expect(keyed.headers.contains { $0.0 == "Authorization" && $0.1 == secret })

        // Keyless fetch: no Authorization header at all.
        _ = try? await fetcher.fetch(modelId: "m", authorization: nil)
        let keyless = try #require(client.requests.last)
        #expect(!keyless.headers.contains { $0.0.lowercased() == "authorization" })
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
        // A genuine failure keeps its raw text, not the approval hint.
        #expect(model.warnings.contains { $0.message.contains("Autostart registration failed") })
        #expect(model.warnings.contains { $0.message.contains("denied") })
        #expect(!model.warnings.contains { $0.message.contains("needs approval") })
    }

    @Test func loginItemRegisterThrowingWithApprovalPendingShowsApprovalText() throws {
        // Live bug: register() throws "Operation not permitted" while approval is pending, but
        // the status is .requiresApproval. That is the one-time approval state, not an error.
        let h = try Harness()
        h.loginItem.registerError = LoginItemTestError.denied
        h.loginItem.statusAfterRegister = .requiresApproval
        let model = h.model()

        model.registerLoginItem()

        #expect(model.loginItemStatus == .requiresApproval)
        #expect(model.warnings.contains { $0.message.contains("needs approval") })
        #expect(!model.warnings.contains { $0.message.contains("denied") })
    }

    @Test func autostartApprovalWarningClearsAfterALaterRegisterSucceeds() throws {
        let h = try Harness()
        h.loginItem.registerError = LoginItemTestError.denied
        h.loginItem.statusAfterRegister = .requiresApproval
        let model = h.model()
        model.registerLoginItem()
        #expect(model.warnings.contains { $0.key == .autostart })

        // The user approved; the next register succeeds and the stale hint goes away.
        h.loginItem.registerError = nil
        h.loginItem.statusAfterRegister = .enabled
        model.registerLoginItem()

        #expect(model.loginItemStatus == .enabled)
        #expect(!model.warnings.contains { $0.key == .autostart })
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

    // MARK: - Autostart is tied to Install/Uninstall, not to launch

    @Test func installApprovalPendingSkipsAutostartRegistration() async throws {
        // Install's helper step runs first. While approval is pending it throws the approval
        // message, so autostart must not be registered in that run; after the user approves,
        // the next Install registers it.
        let h = try Harness()
        h.helper.status = .requiresApproval
        let model = h.model()

        await model.install()

        #expect(h.helper.openApprovalCount == 1)
        #expect(h.loginItem.registerCount == 0)
        #expect(model.warnings.contains { $0.message.contains("Login Items") })

        h.helper.status = .enabled
        await model.install()

        #expect(h.loginItem.registerCount == 1)
    }

    @Test func installApprovalWarningRendersWithExactlyOnePeriod() async throws {
        // The thrown text ends with a period and the install wrapper adds one; the rendered
        // warning must not read ".. The system was not fully changed."
        let h = try Harness()
        h.helper.status = .enabled
        h.hostsEditor.error = HostsEditingError.timedOut
        let model = h.model()

        await model.install()

        let warning = try #require(model.warnings.first { $0.key == .install })
        #expect(!warning.message.contains(".."))
        #expect(warning.message.contains(
            "then choose Retry setup in the OpenProxy menu. The system was not fully changed."))
    }

    @Test func launchDoesNotRegisterAutostart() async throws {
        // A plain launch must not put OpenProxy in Login Items before the user installs.
        let h = try Harness()
        let model = h.model()

        await model.start()

        #expect(h.loginItem.registerCount == 0)
    }

    @Test func installRegistersAutostartOnce() async throws {
        let h = try Harness()
        let model = h.model()

        await model.install()

        #expect(h.loginItem.registerCount == 1)
        #expect(model.loginItemStatus == .enabled)
    }

    @Test func installFailureLeavesSetupIncomplete() async throws {
        // The hosts step (d) runs after autostart (c), so a hosts failure leaves autostart
        // registered but the setup incomplete: the next launch asks again.
        let h = try Harness()
        h.runner.error = InstallError.runnerFailed("boom")
        let model = h.model()

        await model.install()

        #expect(!model.settings.setupComplete)
        #expect(model.warnings.contains { $0.key == .install })
    }

    @Test func uninstallUnregistersAutostart() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()

        await model.uninstall()

        #expect(h.loginItem.unregisterCount == 1)
    }

    @Test func uninstallFailureDoesNotUnregisterAutostart() async throws {
        // The hosts entry is still routed, so the app is still installed: keep autostart on.
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.runner.error = InstallError.runnerFailed("boom")
        let model = h.model()

        await model.uninstall()

        #expect(h.loginItem.unregisterCount == 0)
    }

    @Test func removeCAUnregistersAutostart() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()

        await model.removeCA()

        #expect(h.loginItem.unregisterCount == 1)
    }

    @Test func unregisterFailureBecomesWarningAndUninstallStillCompletes() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.loginItem.unregisterError = LoginItemTestError.denied
        let model = h.model()

        await model.uninstall()

        // Restoring hosts is what matters; a failed autostart unregister only warns.
        #expect(h.runner.scripts.count == 1)
        #expect(!model.status.hostsEntry)
        #expect(model.warnings.contains { $0.message.contains("Autostart") })
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

    @Test func nodeCAEnvSetWithMissingCAReadsAsANeutralNote() {
        // Leftover env var (e.g. after the CA was removed): set, but not usable.
        let orphan = InstallStatus(
            caTrusted: false, caPresent: false, hostsEntry: false, portListening: false, nodeCAEnv: true)
        #expect(orphan.nodeCAEnvNote == "set (CA not installed)")
        let healthy = InstallStatus(
            caTrusted: true, caPresent: true, hostsEntry: true, portListening: true, nodeCAEnv: true)
        #expect(healthy.nodeCAEnvNote == nil)
        let unset = InstallStatus(
            caTrusted: false, caPresent: false, hostsEntry: false, portListening: false, nodeCAEnv: false)
        #expect(unset.nodeCAEnvNote == nil)
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
        #expect(model.warnings.contains { $0.message.contains("Setup was skipped") })
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
        h.quitDecision.choice = .restoreAccessAndQuit

        await model.quit()

        #expect(h.quitDecision.decideCount == 1)
        #expect(h.quitDecision.terminateCount == 1)
        // Restoring access restored /etc/hosts before quitting; the CA is left for Uninstall
        // OpenProxy... in the menu.
        #expect(h.runner.scripts.count == 1)
        #expect(!model.status.hostsEntry)
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
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        let model = h.model()
        await model.refresh()
        #expect(model.status.hostsEntry == false)

        await model.quit()

        #expect(h.quitDecision.decideCount == 0)
        #expect(h.quitDecision.terminateCount == 1)
    }

    @Test func quitWithFailingHelperAndAbsentHostsTerminatesWithoutPopup() async throws {
        // The helper failed, but the fresh read proves the entry is gone: no popup is needed.
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        h.helper.status = .enabled
        h.hostsEditor.error = InstallError.runnerFailed("helper unavailable")
        let model = h.model()
        await model.refresh()

        await model.quit()

        #expect(h.hostsEditor.requests == [false])
        #expect(h.quitDecision.decideCount == 0)
        #expect(h.quitDecision.terminateCount == 1)
        #expect(model.warnings.contains { $0.key == .quit && $0.message.contains("could not restore") })
    }

    @Test func quitWithFailingHelperAndPresentHostsShowsThePopup() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.helper.status = .enabled
        h.hostsEditor.error = InstallError.runnerFailed("helper unavailable")
        h.quitDecision.choice = .cancel
        let model = h.model()
        await model.refresh()

        await model.quit()

        #expect(h.quitDecision.decideCount == 1)
        #expect(h.quitDecision.terminateCount == 0)
    }

    @Test func quitWithFailingHelperAndUnreadableHostsShowsThePopup() async throws {
        // unknown is not absent: quitting could still break every client.
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.helper.status = .enabled
        h.hostsEditor.error = InstallError.runnerFailed("helper unavailable")
        h.quitDecision.choice = .cancel
        try FileManager.default.removeItem(at: h.directory.appending(path: "hosts"))
        try FileManager.default.createDirectory(
            at: h.directory.appending(path: "hosts"), withIntermediateDirectories: true)
        let model = h.model()
        await model.refresh()

        await model.quit()

        #expect(h.quitDecision.decideCount == 1)
        #expect(h.quitDecision.terminateCount == 0)
        #expect(model.warnings.contains {
            $0.key == .quit && $0.message.contains("could not confirm that openrouter.ai is no longer routed here")
        })
    }

    @Test func quitUsesAFreshHostsStateNotTheCachedStatus() async throws {
        // The cached status was probed while the file was clean; the entry appeared since.
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        let model = h.model()
        await model.refresh()
        #expect(model.status.hostsEntry == false)
        try "127.0.0.1 localhost\n127.0.0.1 openrouter.ai # openproxy\n".write(
            to: h.directory.appending(path: "hosts"), atomically: true, encoding: .utf8)
        h.quitDecision.choice = .cancel

        await model.quit()

        #expect(h.quitDecision.decideCount == 1)
        #expect(h.quitDecision.terminateCount == 0)
    }

    @Test func quitWithUnreadableHostsWithoutAHelperShowsThePopup() async throws {
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        try FileManager.default.removeItem(at: h.directory.appending(path: "hosts"))
        try FileManager.default.createDirectory(
            at: h.directory.appending(path: "hosts"), withIntermediateDirectories: true)
        h.quitDecision.choice = .cancel
        let model = h.model()
        await model.refresh()

        await model.quit()

        #expect(h.quitDecision.decideCount == 1)
        #expect(h.quitDecision.terminateCount == 0)
        #expect(model.warnings.contains { $0.key == .quit && $0.message.contains("could not confirm") })
    }

    @Test func restoreAccessAndQuitStaysRunningWhenHostsRemovalFails() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()
        await model.refresh()
        #expect(model.status.hostsEntry)
        // The admin prompt for the hosts edit is dismissed: hosts is never restored.
        h.runner.error = InstallError.runnerFailed("the administrator prompt was dismissed")
        h.quitDecision.choice = .restoreAccessAndQuit

        await model.quit()

        // Terminating would leave openrouter.ai routed to a dead proxy, so stay running
        // and surface why instead.
        #expect(h.quitDecision.terminateCount == 0)
        #expect(model.status.hostsEntry)
        #expect(model.warnings.contains { $0.message.contains("still routed") })
    }

    @Test func quitWithHelperEnabledRemovesHostsSilentlyWithoutAPrompt() async throws {
        // With the approved helper, quitting must not show the destructive-route popup: it
        // silently restores access; the next launch's setupComplete restore puts it back.
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.helper.status = .enabled
        let model = h.model()
        await model.refresh()

        await model.quit()

        #expect(h.hostsEditor.requests == [false])
        #expect(h.quitDecision.decideCount == 0)
        #expect(h.quitDecision.terminateCount == 1)
        #expect(h.runner.scripts.isEmpty)
    }

    @Test func quitWithFailingHelperFallsBackToThePopupInsteadOfTrappingTheUser() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.helper.status = .enabled
        h.hostsEditor.error = InstallError.runnerFailed("helper unavailable")
        h.quitDecision.choice = .cancel
        let model = h.model()
        await model.refresh()

        await model.quit()

        #expect(h.quitDecision.decideCount == 1)
        #expect(h.quitDecision.terminateCount == 0)
        #expect(model.warnings.contains { $0.key == .quit })

        h.quitDecision.choice = .quitAnyway
        await model.quit()

        #expect(h.quitDecision.terminateCount == 1)
    }

    // MARK: - Automatic setup

    @Test func installSetsSetupCompleteAndRoutingActive() async throws {
        let h = try Harness()
        let model = h.model()

        await model.install()

        #expect(model.settings.setupComplete)
        #expect(model.routingState == .active)
    }

    @Test func setupRunsStepsInOrder() async throws {
        let h = try Harness()
        // Register enables the helper, so step (b) is exercised and the hosts edit goes via XPC.
        h.helper.status = .notRegistered
        h.helper.statusAfterRegister = .enabled
        let model = h.model()

        await model.install()

        #expect(h.orderLog.sequence == ["trust", "helper", "autostart", "hosts", "nodeenv"])
    }

    @Test func installWaitsForAutostartApprovalBeforeAddingHosts() async throws {
        // Autostart must be enabled before anything routes here: an approved-but-pending
        // registration is a wait, and the hosts entry/Node env follow once it flips.
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        h.loginItem.status = .requiresApproval
        h.loginItem.statusAfterRegister = .requiresApproval
        h.waiting.onPoll = { h.loginItem.status = .enabled }
        let model = h.model()

        await model.install()

        #expect(h.loginItem.registerCount == 1)
        #expect(h.waiting.count == 1)
        #expect(h.helper.openApprovalCount == 1)
        #expect(h.runner.scripts.count == 1)
        #expect(model.settings.setupComplete)
        #expect(model.routingState == .active)
        #expect(!model.warnings.contains { $0.key == .autostart })
        #expect(h.orderLog.sequence == ["trust", "helper", "autostart", "hosts", "nodeenv"])
    }

    @Test func installDoesNotRouteWhenAutostartNeedsApproval() async throws {
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        h.loginItem.status = .requiresApproval
        h.loginItem.statusAfterRegister = .requiresApproval
        let model = h.model()

        await model.install()

        #expect(h.runner.scripts.isEmpty)
        #expect(h.hostsEditor.requests.isEmpty)
        #expect(!model.settings.setupComplete)
        #expect(model.routingState == .error("waiting for autostart approval timed out"))
        #expect(model.warnings.contains { $0.key == .autostart })
        #expect(model.warnings.contains { $0.key == .install && $0.message.contains("Timed out") })
        #expect(!model.status.hostsEntry)
    }

    @Test func installContinuesWhenAutostartIsApprovedLater() async throws {
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        h.loginItem.status = .requiresApproval
        h.loginItem.statusAfterRegister = .requiresApproval
        let model = h.model()
        await model.install()
        #expect(!model.settings.setupComplete)

        h.loginItem.status = .enabled
        h.loginItem.statusAfterRegister = .enabled
        await model.install()

        #expect(model.settings.setupComplete)
        #expect(model.routingState == .active)
        #expect(h.runner.scripts.count == 1)
    }

    @Test func installDoesNotRouteOrWaitWhenAutostartRegistrationFails() async throws {
        // Only .requiresApproval is a wait; any other non-enabled status is a real failure and
        // must finish at once with the registration error, no clock poll and no Login Items hop.
        for status in [LoginItemStatus.notRegistered, .notFound, .unknown(1)] {
            let h = try Harness(hostsText: "127.0.0.1 localhost\n")
            h.loginItem.registerError = LoginItemTestError.denied
            h.loginItem.status = status
            let model = h.model()

            await model.install()

            #expect(h.runner.scripts.isEmpty)
            #expect(h.hostsEditor.requests.isEmpty)
            #expect(!model.settings.setupComplete)
            #expect(model.routingState == .error("autostart is \(status.label)"))
            #expect(h.waiting.count == 0)
            #expect(h.helper.openApprovalCount == 0)
            #expect(model.canRetrySetup)
            #expect(model.warnings.contains {
                $0.key == .autostart && $0.message.contains("Autostart registration failed")
            })
        }
    }

    @Test func laterLaunchDoesNotRestoreHostsWithoutAutostart() async throws {
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        h.helper.status = .enabled
        h.loginItem.status = .requiresApproval
        let model = h.model()
        model.settings.setupComplete = true

        await model.start()

        #expect(h.hostsEditor.requests.isEmpty)
        #expect(h.runner.scripts.isEmpty)
        #expect(!model.status.hostsEntry)
    }

    // MARK: - Start at login (Control window)

    @Test func setStartAtLoginOnDelegatesToSetup() async throws {
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        h.helper.status = .enabled
        h.loginItem.status = .notRegistered
        h.loginItem.statusAfterRegister = .enabled
        let model = h.model()
        model.settings.setupComplete = true

        await model.setStartAtLogin(true)

        #expect(h.loginItem.registerCount == 1)
        #expect(model.loginItemStatus == .enabled)
        #expect(h.hostsEditor.requests == [true])
        #expect(model.routingState == .active)
    }

    @Test func setStartAtLoginOnBeforeFirstLaunchAsksTheWelcomeAndSetsUpWhenAccepted() async throws {
        // "Not now" on first launch leaves setupComplete false and no route; turning Start at
        // login on must ask the welcome question rather than silently do nothing.
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        h.helper.status = .enabled
        h.loginItem.status = .notRegistered
        h.loginItem.statusAfterRegister = .enabled
        h.setupDecision.confirm = true
        let model = h.model()

        await model.setStartAtLogin(true)

        #expect(h.setupDecision.count == 1)
        #expect(h.loginItem.registerCount == 1)
        #expect(h.hostsEditor.requests == [true])
        #expect(model.settings.setupComplete)
        #expect(model.routingState == .active)
    }

    @Test func setStartAtLoginOnBeforeFirstLaunchDoesNothingWhenDeclinedAgain() async throws {
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        h.helper.status = .enabled
        h.loginItem.status = .notRegistered
        h.loginItem.statusAfterRegister = .enabled
        h.setupDecision.confirm = false
        let model = h.model()

        await model.setStartAtLogin(true)

        #expect(h.setupDecision.count == 1)
        #expect(h.loginItem.registerCount == 0)
        #expect(h.hostsEditor.requests.isEmpty)
        #expect(!model.settings.setupComplete)
        #expect(model.routingState == .inactive)
    }

    @Test func canRetrySetupIsFalseWhileTheSetupIsRunning() async throws {
        // With a completed setup but autostart off, turning Start at login on runs the setup
        // again; while it runs the toggle must not offer a second, concurrent setup.
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        h.helper.status = .enabled
        h.loginItem.status = .notRegistered
        h.loginItem.statusAfterRegister = .enabled
        h.commandRunner.delay = .milliseconds(200)
        let model = h.model()
        model.settings.setupComplete = true

        let run = Task { await model.setStartAtLogin(true) }
        let settingUp = await h.waitUntil {
            model.routingState == .settingUp && model.loginItemStatus != .enabled
        }
        #expect(settingUp)
        #expect(model.canRetrySetup == false)

        await run.value
        #expect(model.routingState == .active)
    }

    @Test func setStartAtLoginOffRemovesHostsBeforeUnregistering() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()
        model.settings.setupComplete = true

        await model.setStartAtLogin(false)

        #expect(h.orderLog.sequence.filter { $0 == "hosts" || $0 == "autostart" } == ["hosts", "autostart"])
        #expect(h.runner.scripts.count == 1)
        #expect(h.loginItem.unregisterCount == 1)
        #expect(model.loginItemStatus == .notRegistered)
        #expect(model.settings.setupComplete)
        #expect(model.routingState == .inactive)
        #expect(!model.status.hostsEntry)
    }

    @Test func setStartAtLoginOffKeepsAutostartWhenHostsRemovalFails() async throws {
        // Hosts must never stay routed with autostart off: a failed removal keeps autostart on.
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.runner.error = InstallError.runnerFailed("boom")
        let model = h.model()
        model.settings.setupComplete = true
        await model.refresh()

        await model.setStartAtLogin(false)

        #expect(h.loginItem.unregisterCount == 0)
        #expect(model.loginItemStatus == .enabled)
        #expect(model.warnings.contains { $0.key == .autostart })
    }

    @Test func relaunchAfterStartAtLoginOffDoesNotReAddHosts() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        let model = h.model()
        model.settings.setupComplete = true
        await model.setStartAtLogin(false)
        #expect(!model.status.hostsEntry)

        // Everything else the restore needs is in place; only autostart is off.
        h.helper.status = .enabled
        let relaunched = h.model()
        await relaunched.start()

        #expect(h.runner.scripts.count == 1) // the OFF removal only, no re-add
        #expect(!relaunched.status.hostsEntry)
    }

    @Test func retrySetupRunsTheSetupWithoutTheWelcomeDialog() async throws {
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        h.loginItem.status = .requiresApproval
        h.loginItem.statusAfterRegister = .requiresApproval
        let model = h.model()
        await model.install()
        #expect(!model.settings.setupComplete)
        #expect(model.canRetrySetup)
        #expect(h.setupDecision.count == 0)

        h.loginItem.status = .enabled
        h.loginItem.statusAfterRegister = .enabled
        await model.retrySetup()

        #expect(h.setupDecision.count == 0)
        #expect(model.settings.setupComplete)
        #expect(h.runner.scripts.count == 1)
    }

    @Test func retrySetupIsNotOfferedOrRunWhenSetupIsComplete() async throws {
        let h = try Harness()
        let model = h.model()
        await model.install()
        #expect(model.settings.setupComplete)
        #expect(model.canRetrySetup == false)
        let scripts = h.runner.scripts.count

        await model.retrySetup()

        #expect(h.runner.scripts.count == scripts)
    }

    @Test func retrySetupIsNotOfferedBeforeSetupHasEverRun() async throws {
        let h = try Harness()
        let model = h.model()
        #expect(model.routingState == .inactive)
        #expect(model.canRetrySetup == false)

        await model.retrySetup()

        #expect(h.runner.scripts.isEmpty)
        #expect(h.loginItem.registerCount == 0)
        #expect(h.setupDecision.count == 0)
    }

    @Test func reinstallWithAnAlreadyEnabledHelperSkipsRegistration() async throws {
        // Uninstall keeps the helper registered, so the next setup finds it .enabled and must
        // not register again: re-registering an enabled daemon is what made launchd refuse to
        // spawn it until the user toggled OpenProxy in Login Items by hand.
        let h = try Harness(hostsText: "127.0.0.1 localhost\n")
        h.helper.status = .enabled
        let model = h.model()

        await model.install()

        #expect(h.helper.registerCount == 0)
        #expect(h.hostsEditor.requests == [true])
        #expect(h.runner.scripts.isEmpty)
        #expect(model.settings.setupComplete)
        #expect(model.routingState == .active)
    }

    @Test func setupSkipsTheTrustDialogWhenTheCAIsAlreadyTrusted() async throws {
        let h = try Harness()
        let model = h.model()

        await model.install()

        #expect(!h.commandRunner.commands.contains { $0.contains("add-trusted-cert") })
    }

    @Test func approvalPendingThenEnabledContinuesAutomatically() async throws {
        let h = try Harness()
        h.helper.status = .requiresApproval
        h.waiting.onPoll = { [weak helper = h.helper] in helper?.status = .enabled }
        let model = h.model(maxApprovalPolls: 3)

        await model.install()

        #expect(h.helper.openApprovalCount == 1)
        #expect(h.waiting.count >= 1)
        #expect(model.settings.setupComplete)
        #expect(model.routingState == .active)
        #expect(h.hostsEditor.requests == [true])
    }

    @Test func approvalTimeoutLeavesSetupIncomplete() async throws {
        let h = try Harness()
        h.helper.status = .requiresApproval
        let model = h.model(maxApprovalPolls: 2)

        await model.install()

        #expect(!model.settings.setupComplete)
        #expect(model.warnings.contains { $0.message.contains("Login Items") })
        #expect(h.loginItem.registerCount == 0)
    }

    @Test func laterLaunchRestoresRoutingWhenSetupComplete() async throws {
        let h = try Harness()
        h.helper.status = .enabled
        let model = h.model()
        model.settings.setupComplete = true

        await model.start()

        #expect(h.hostsEditor.requests == [true])
        #expect(model.routingState == .active)
        #expect(h.runner.scripts.isEmpty)
    }

    @Test func launchDoesNotRestoreWhenTheProxyCannotListen() async throws {
        let h = try Harness()
        h.helper.status = .enabled
        h.server.startError = PortInUse()
        let model = h.model()
        model.settings.setupComplete = true

        await model.start()

        // Routing to a dead listener would block every client, so the entry is never added.
        #expect(h.hostsEditor.requests.isEmpty)
    }

    @Test func launchDoesNotRestoreWithoutAHelper() async throws {
        let h = try Harness()
        h.helper.status = .notFound
        let model = h.model()
        model.settings.setupComplete = true

        await model.start()

        #expect(h.hostsEditor.requests.isEmpty)
        #expect(h.runner.scripts.isEmpty)
    }

    @Test func launchDoesNotRestoreBeforeSetupComplete() async throws {
        let h = try Harness()
        h.helper.status = .enabled
        let model = h.model()

        await model.start()

        #expect(h.hostsEditor.requests.isEmpty)
    }

    // MARK: - Welcome alert

    @Test func firstLaunchAsksWelcomeAndSetupCompletes() async throws {
        let h = try Harness()
        h.setupDecision.confirm = true
        let model = h.model()

        await model.start()

        #expect(h.setupDecision.count == 1)
        #expect(model.settings.setupComplete)
    }

    @Test func notNowSkipsSetupAndAsksAgainNextLaunch() async throws {
        let h = try Harness()
        h.setupDecision.confirm = false
        let first = h.model()
        await first.start()
        #expect(first.settings.setupComplete == false)
        #expect(h.loginItem.registerCount == 0)
        #expect(h.hostsEditor.requests.isEmpty)

        h.setupDecision.confirm = true
        let second = h.model()
        await second.start()

        #expect(h.setupDecision.count == 2)
        #expect(second.settings.setupComplete)
    }

    // MARK: - Uninstall OpenProxy

    @Test func uninstallCancelDoesNothing() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.uninstallDecision.confirm = false
        let model = h.model()

        await model.uninstallOpenProxy()

        #expect(h.uninstallDecision.count == 1)
        #expect(h.hostsEditor.requests.isEmpty)
        #expect(h.quitDecision.terminateCount == 0)
    }

    @Test func uninstallRunsTheFullTeardownInOrderAndTerminates() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.helper.status = .enabled
        h.uninstallDecision.confirm = true
        let model = h.model()

        await model.uninstallOpenProxy()

        #expect(h.orderLog.sequence == ["hosts", "autostart", "ca", "data", "quit"])
        #expect(h.dataRemover.count == 1)
        #expect(h.quitDecision.terminateCount == 1)
        // Uninstall keeps the helper: unregistering it would make the next setup toggle
        // OpenProxy in Login Items through the launch-constraint dance.
        #expect(h.helper.status == .enabled)
        #expect(h.helper.registerCount == 0)
    }

    @Test func uninstallStopsWhenHostsRemovalFailedAndEntryRemains() async throws {
        // The safety-critical step: if /etc/hosts still routes openrouter.ai, continuing would
        // drop autostart and the CA while every client is pointed at a dead proxy.
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.helper.status = .enabled
        h.hostsEditor.error = InstallError.runnerFailed("hosts locked")
        h.uninstallDecision.confirm = true
        let model = h.model()

        await model.uninstallOpenProxy()

        #expect(h.loginItem.unregisterCount == 0)
        #expect(h.runner.scripts.isEmpty)
        #expect(h.dataRemover.count == 0)
        #expect(h.quitDecision.terminateCount == 0)
        #expect(model.warnings.contains { $0.key == .uninstall && $0.message.contains("Uninstall stopped") })
        #expect(model.routingState == .error("uninstall stopped: /etc/hosts could not be restored"))
    }

    @Test func uninstallContinuesWhenHostsRemovalThrewButEntryIsGone() async throws {
        // The call reported an error, but the entry really is gone: the step succeeded.
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.helper.status = .enabled
        h.hostsEditor.error = InstallError.runnerFailed("hosts locked")
        h.uninstallDecision.confirm = true
        try "127.0.0.1 localhost\n".write(
            to: h.directory.appending(path: "hosts"), atomically: true, encoding: .utf8)
        let model = h.model()

        await model.uninstallOpenProxy()

        #expect(h.loginItem.unregisterCount == 1)
        #expect(h.dataRemover.count == 1)
        #expect(h.quitDecision.terminateCount == 1)
        #expect(!model.warnings.contains { $0.key == .uninstall })
    }

    @Test func uninstallStopsWhenHostsStateIsUnknownAfterFailedRemoval() async throws {
        // The removal failed and the state cannot be confirmed (undecodable bytes): the only
        // safe choice is to stop, exactly as when the entry is known to remain.
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.helper.status = .enabled
        h.hostsEditor.error = InstallError.runnerFailed("hosts locked")
        h.uninstallDecision.confirm = true
        try Data([0xFF, 0xFE, 0x00]).write(to: h.directory.appending(path: "hosts"))
        let model = h.model()

        await model.uninstallOpenProxy()

        #expect(h.loginItem.unregisterCount == 0)
        #expect(h.runner.scripts.isEmpty)
        #expect(h.dataRemover.count == 0)
        #expect(h.quitDecision.terminateCount == 0)
        #expect(model.warnings.contains {
            $0.key == .uninstall && $0.message.contains("could not confirm that /etc/hosts was restored")
        })
        #expect(model.routingState == .error("uninstall stopped: /etc/hosts could not be restored"))
    }

    @Test func uninstallStopsWhenHostsFileIsUnreadableAfterFailedRemoval() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.helper.status = .enabled
        h.hostsEditor.error = InstallError.runnerFailed("hosts locked")
        h.uninstallDecision.confirm = true
        // The file is gone and a directory (unreadable as hosts text) sits at the path.
        try FileManager.default.removeItem(at: h.directory.appending(path: "hosts"))
        try FileManager.default.createDirectory(
            at: h.directory.appending(path: "hosts"), withIntermediateDirectories: true)
        let model = h.model()

        await model.uninstallOpenProxy()

        #expect(h.loginItem.unregisterCount == 0)
        #expect(h.dataRemover.count == 0)
        #expect(h.quitDecision.terminateCount == 0)
        #expect(model.warnings.contains { $0.key == .uninstall && $0.message.contains("could not confirm") })
    }

    @Test func uninstallWithAnyFailingStepDoesNotWipeDataOrTerminate() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.helper.status = .enabled
        h.uninstallDecision.confirm = true
        // The CA teardown's osascript fails.
        h.runner.error = InstallError.runnerFailed("boom")
        let model = h.model()

        await model.uninstallOpenProxy()

        #expect(h.hostsEditor.requests == [false])
        #expect(h.loginItem.unregisterCount == 1)
        #expect(h.dataRemover.count == 0)
        #expect(h.quitDecision.terminateCount == 0)
        #expect(model.warnings.contains { $0.key == .uninstall && $0.message.contains("Uninstall incomplete") })
        #expect(model.routingState == .error("uninstall incomplete"))
    }

    @Test func uninstallDataFailureKeepsRunningAndListsTheStep() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.helper.status = .enabled
        h.uninstallDecision.confirm = true
        h.dataRemover.error = InstallError.runnerFailed("locked")
        let model = h.model()

        await model.uninstallOpenProxy()

        #expect(h.dataRemover.count == 1)
        #expect(h.quitDecision.terminateCount == 0)
        #expect(model.warnings.contains { $0.key == .uninstall && $0.message.contains("OpenProxy data") })
    }

    @Test func removeCAClearsWarningsOnSuccessAndKeepsTheHelperRegistered() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.helper.status = .enabled
        let model = h.model()

        await model.removeCA()

        #expect(h.helper.status == .enabled)
        #expect(h.helper.registerCount == 0)
        #expect(model.warnings.isEmpty)
    }

    @Test func removeCAFailureBecomesWarning() async throws {
        let h = try Harness(hostsText: "127.0.0.1 openrouter.ai # openproxy\n")
        h.runner.error = InstallError.runnerFailed("boom")
        let model = h.model()

        await model.removeCA()

        #expect(model.warnings.contains {
            $0.key == .uninstall && $0.message.contains("Removing the CA")
        })
    }

    @Test func refreshReportsHelperStatus() async throws {
        let h = try Harness()
        h.helper.status = .requiresApproval
        let model = h.model()

        await model.refresh()

        #expect(model.helperStatus == .requiresApproval)
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

    // MARK: - Item 1: Install sets NODE_EXTRA_CA_CERTS

    @Test func successfulInstallSetsNodeCAEnv() async throws {
        let h = try Harness()
        let model = h.model()

        await model.install()

        #expect(h.commandRunner.commands.contains {
            $0.contains("launchctl setenv NODE_EXTRA_CA_CERTS")
        })
        #expect(!model.warnings.contains { $0.key == .nodeEnv })
    }

    @Test func installStaysSuccessfulWhenNodeCAEnvFails() async throws {
        let h = try Harness()
        h.commandRunner.errorOnContains = "launchctl setenv"
        let model = h.model()

        await model.install()

        // The CA and hosts install succeeded; only the env step warned.
        #expect(h.runner.scripts.count == 1)
        #expect(model.warnings.contains { $0.key == .nodeEnv })
        #expect(!model.warnings.contains { $0.key == .install })
    }
}

@Suite("AppGraph")
struct AppGraphTests {
    @Test func aBundleShippingTheDaemonPlistIsTreatedAsBundled() throws {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "Fake-\(UUID().uuidString).app")
        let daemonDir = bundle.appending(path: "Contents/Library/LaunchDaemons")
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        #expect(AppGraph.helperIsBundled(inBundleAt: bundle) == false)
        try Data().write(to: daemonDir.appending(path: "dev.openproxy.helper.plist"))
        #expect(AppGraph.helperIsBundled(inBundleAt: bundle))
    }
}

/// The production full-uninstall wipe against real temp directories: only a missing directory
/// is a success, every other listing or removal error must surface so the app does not quit
/// with its data still on disk.
@Suite("AppSupportDataRemover")
struct AppSupportDataRemoverTests {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "openproxy-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func removesEveryFileInTheDirectory() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        try Data("ca".utf8).write(to: dir.appending(path: "ca.pem"))
        try Data("stats".utf8).write(to: dir.appending(path: "stats.sqlite"))

        try AppSupportDataRemover(directory: dir).removeAppData()

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func aMissingDirectoryIsFine() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "openproxy-data-\(UUID().uuidString)")
        try AppSupportDataRemover(directory: dir).removeAppData()
    }

    @Test func anUnreadableDirectoryThrows() throws {
        guard getuid() != 0 else { return } // chmod does not restrict root
        let dir = try makeDirectory()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)

        #expect(throws: (any Error).self) {
            try AppSupportDataRemover(directory: dir).removeAppData()
        }
    }

    @Test func aRemovalFailureThrows() throws {
        guard getuid() != 0 else { return }
        // Listing works (r-x) but unlinking needs write on the parent, so the removal fails.
        let dir = try makeDirectory()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        try Data("ca".utf8).write(to: dir.appending(path: "ca.pem"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

        #expect(throws: (any Error).self) {
            try AppSupportDataRemover(directory: dir).removeAppData()
        }
    }

    @Test func aSymlinkedDirectoryIsRefusedAndItsTargetUntouched() throws {
        let target = try makeDirectory()
        let precious = target.appending(path: "precious.txt")
        try Data("keep me".utf8).write(to: precious)
        let link = FileManager.default.temporaryDirectory.appending(path: "openproxy-data-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: target) }

        #expect(throws: DataRemovalError.self) {
            try AppSupportDataRemover(directory: link).removeAppData()
        }

        #expect(FileManager.default.fileExists(atPath: precious.path))
        #expect(try String(contentsOf: precious, encoding: .utf8) == "keep me")
    }

    @Test func aPathThatIsNotADirectoryIsRefused() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "openproxy-data-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(throws: DataRemovalError.self) {
            try AppSupportDataRemover(directory: file).removeAppData()
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aSymlinkInsideIsRemovedAsALinkAndItsTargetUntouched() throws {
        let dir = try makeDirectory()
        let target = try makeDirectory()
        let precious = target.appending(path: "precious.txt")
        try Data("keep me".utf8).write(to: precious)
        try FileManager.default.createSymbolicLink(
            at: dir.appending(path: "linked"), withDestinationURL: target)
        try Data("ca".utf8).write(to: dir.appending(path: "ca.pem"))
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: target) }

        try AppSupportDataRemover(directory: dir).removeAppData()

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: precious.path))
    }
}
