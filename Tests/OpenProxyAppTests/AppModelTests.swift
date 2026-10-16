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
/// touches the keychain or `/etc/hosts` in tests.
private final class FakeRunner: PrivilegedRunner, @unchecked Sendable {
    var error: Error?
    private(set) var scripts: [String] = []

    func run(script: String) async throws {
        scripts.append(script)
        if let error { throw error }
    }
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

@MainActor
private struct Harness {
    let directory: URL
    let settingsStore: SettingsStore
    let stats: StatsStore
    let runner: FakeRunner
    let installer: Installer
    let server: FakeServer
    let loginItem: FakeLoginItem

    init(hostsText: String? = nil) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "openproxy-app-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hostsURL = directory.appending(path: "hosts")
        if let hostsText { try hostsText.write(to: hostsURL, atomically: true, encoding: .utf8) }
        self.directory = directory
        self.settingsStore = SettingsStore(url: directory.appending(path: "settings.json"))
        self.stats = try StatsStore(path: ":memory:")
        self.runner = FakeRunner()
        self.installer = Installer(
            caPEMURL: directory.appending(path: "ca.pem"),
            runner: runner,
            hostsPath: hostsURL.path)
        self.server = FakeServer()
        self.loginItem = FakeLoginItem()
    }

    func model(refreshInterval: Duration = .seconds(5)) -> AppModel {
        AppModel(
            settingsStore: settingsStore, stats: stats, installer: installer,
            server: server, loginItem: loginItem, refreshInterval: refreshInterval)
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
        #expect(model.warnings[0].contains("Install"))
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

    @Test func graphCreatesSupportDirectoryWithOwnerOnlyPermissions() throws {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "openproxy-graph-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        // A clean install has no openproxy directory yet; the graph must create it
        // before the SQLite store tries to open stats.sqlite inside it.
        let base = parent.appending(path: "openproxy")

        _ = try AppGraph.makeModel(baseDirectory: base)

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
        #expect(model.warnings.contains { $0.contains("Autostart") })
    }

    @Test func loginItemRequiringApprovalBecomesWarning() throws {
        let h = try Harness()
        h.loginItem.status = .requiresApproval
        let model = h.model()

        model.registerLoginItem()

        #expect(model.loginItemStatus == .requiresApproval)
        #expect(model.warnings.contains { $0.contains("Autostart") })
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
                hostsPath: dir.appending(path: "hosts").path),
            server: FakeServer(),
            loginItem: FakeLoginItem())

        model.settings.sort = .price

        // The in-memory value (UI and per-request reader) stays consistent; only the disk write failed.
        #expect(model.settings.sort == .price)
        #expect(store.settings.sort == .price)
        #expect(model.warnings.contains { $0.contains("settings") })
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

    @Test func portInUseBecomesWarningAndLeavesHostsUntouched() async throws {
        let h = try Harness()
        h.server.startError = PortInUse()
        let model = h.model()

        await model.start()

        #expect(model.warnings.count == 1)
        #expect(model.warnings[0].lowercased().contains("start"))
        #expect(h.runner.scripts.isEmpty)
    }
}
