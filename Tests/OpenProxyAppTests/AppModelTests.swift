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

@MainActor
private struct Harness {
    let directory: URL
    let settingsStore: SettingsStore
    let stats: StatsStore
    let runner: FakeRunner
    let installer: Installer
    let server: FakeServer

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
    }

    func model() -> AppModel {
        AppModel(settingsStore: settingsStore, stats: stats, installer: installer, server: server)
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
