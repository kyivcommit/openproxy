import Foundation
import Testing

@testable import OpenProxyCore

/// Installer routing through the approved root helper. The legacy osascript path is the
/// fallback; these tests pin which path runs for each `HelperStatus`, and that an enabled
/// helper's XPC failure is surfaced instead of silently prompting for a password.
@Suite("InstallerHelperRouting")
struct InstallerHelperRoutingTests {
    private let hostsEntry = "127.0.0.1 openrouter.ai # openproxy"

    private final class RecordingRunner: PrivilegedRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var error: Error?

        var scripts: [String] { lock.withLock { recorded } }

        func run(script: String) async throws {
            lock.withLock { recorded.append(script) }
            if let error { throw error }
        }
    }

    private final class SucceedingCommandRunner: CommandRunning, @unchecked Sendable {
        func run(_ command: String, timeout: Duration) async -> CommandResult {
            CommandResult(status: 0)
        }
    }

    private final class FakeHostsEditor: HostsEditing, @unchecked Sendable {
        var error: Error?
        private let lock = NSLock()
        private var recorded: [Bool] = []

        var requests: [Bool] { lock.withLock { recorded } }

        func setHostsEntry(present: Bool) async throws {
            lock.withLock { recorded.append(present) }
            if let error { throw error }
        }
    }

    private final class FakeHelper: HelperRegistering, @unchecked Sendable {
        var status: HelperStatus
        /// What `register()` reports the status as on the immediate re-read.
        var statusAfterRegister: HelperStatus?
        var registerError: Error?
        var unregisterError: Error?
        private(set) var registerCount = 0
        private(set) var unregisterCount = 0
        private(set) var openApprovalCount = 0

        init(status: HelperStatus) { self.status = status }

        func register() throws {
            registerCount += 1
            if let registerError { throw registerError }
            if let statusAfterRegister { status = statusAfterRegister }
        }

        func unregister() throws {
            unregisterCount += 1
            if let unregisterError { throw unregisterError }
        }

        func openApprovalSettings() { openApprovalCount += 1 }
    }

    private struct EditorFailure: Error {}

    /// A real on-disk CA so `install()`'s fingerprint check has a certificate to read.
    private static let caURL: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "openproxy-helper-ca-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ca = CertAuthority(directory: dir)
        try? ca.loadOrCreate()
        return ca.caCertificatePEMURL
    }()

    private func makeHostsFile(_ content: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).hosts")
        try Data(content.utf8).write(to: url)
        return url.path
    }

    private func makeInstaller(
        runner: RecordingRunner,
        hostsPath: String,
        editor: HostsEditing? = nil,
        helper: HelperRegistering? = nil
    ) -> Installer {
        Installer(
            caPEMURL: Self.caURL,
            runner: runner,
            commandRunner: SucceedingCommandRunner(),
            hostsPath: hostsPath,
            hostsEditor: editor,
            helper: helper)
    }

    // MARK: - Install

    @Test func installUsesTheHelperWhenEnabledAndSkipsOsascript() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let editor = FakeHostsEditor()
        let helper = FakeHelper(status: .enabled)

        try await makeInstaller(runner: runner, hostsPath: hostsPath, editor: editor, helper: helper).install()

        #expect(editor.requests == [true])
        #expect(runner.scripts.isEmpty)
    }

    @Test func installRegistersThenUsesTheHelperOnceEnabled() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let editor = FakeHostsEditor()
        let helper = FakeHelper(status: .notRegistered)
        helper.statusAfterRegister = .enabled

        try await makeInstaller(runner: runner, hostsPath: hostsPath, editor: editor, helper: helper).install()

        #expect(helper.registerCount == 1)
        #expect(editor.requests == [true])
        #expect(runner.scripts.isEmpty)
    }

    @Test func installAsksForApprovalWithoutPromptingForAPassword() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let editor = FakeHostsEditor()
        let helper = FakeHelper(status: .notRegistered)
        helper.statusAfterRegister = .requiresApproval

        var thrown: InstallError?
        do {
            try await makeInstaller(runner: runner, hostsPath: hostsPath, editor: editor, helper: helper).install()
        } catch let error as InstallError {
            thrown = error
        }

        #expect(helper.registerCount == 1)
        #expect(helper.openApprovalCount == 1)
        #expect(editor.requests.isEmpty)
        // Never falls back to the admin-password dialog the helper is meant to replace.
        #expect(runner.scripts.isEmpty)
        let message = try #require(thrown?.description)
        #expect(message.contains("Login Items"))
        #expect(message.contains("Install again"))
    }

    @Test func installOpensApprovalSettingsWhenApprovalIsAlreadyRequired() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let editor = FakeHostsEditor()
        let helper = FakeHelper(status: .requiresApproval)

        await #expect(throws: InstallError.self) {
            try await makeInstaller(runner: runner, hostsPath: hostsPath, editor: editor, helper: helper).install()
        }

        #expect(helper.openApprovalCount == 1)
        #expect(helper.registerCount == 0)
        #expect(runner.scripts.isEmpty)
    }

    @Test func installFallsBackToOsascriptWhenTheHelperIsNotFound() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let editor = FakeHostsEditor()
        let helper = FakeHelper(status: .notFound)

        try await makeInstaller(runner: runner, hostsPath: hostsPath, editor: editor, helper: helper).install()

        #expect(editor.requests.isEmpty)
        #expect(runner.scripts.count == 1)
        #expect(runner.scripts.first?.contains(hostsEntry) == true)
    }

    @Test func installFallsBackToOsascriptWhenTheHelperStatusIsUnknown() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let helper = FakeHelper(status: .unknown)

        try await makeInstaller(runner: runner, hostsPath: hostsPath, editor: FakeHostsEditor(), helper: helper).install()

        #expect(runner.scripts.count == 1)
    }

    @Test func enabledHelperFailureIsSurfacedAndNeverFallsBackToOsascript() async throws {
        // The bug this prevents: an enabled helper whose XPC call fails must not quietly
        // open an admin-password dialog, which would hide the real failure.
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let editor = FakeHostsEditor()
        editor.error = EditorFailure()
        let helper = FakeHelper(status: .enabled)

        var thrown: InstallError?
        do {
            try await makeInstaller(runner: runner, hostsPath: hostsPath, editor: editor, helper: helper).install()
        } catch let error as InstallError {
            thrown = error
        }

        #expect(thrown != nil)
        #expect(editor.requests == [true])
        #expect(runner.scripts.isEmpty)
    }

    // MARK: - Uninstall

    @Test func uninstallRemovesOnlyHostsThroughTheHelperAndLeavesTheCA() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let editor = FakeHostsEditor()
        let helper = FakeHelper(status: .enabled)

        try await makeInstaller(runner: runner, hostsPath: hostsPath, editor: editor, helper: helper).uninstall()

        #expect(editor.requests == [false])
        // The CA trust and keychain sweep moved to removeCA(); uninstall touches hosts only.
        #expect(runner.scripts.isEmpty)
    }

    @Test func uninstallFallsBackToOsascriptForTheHostsEntryOnly() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let helper = FakeHelper(status: .notFound)

        try await makeInstaller(runner: runner, hostsPath: hostsPath, editor: FakeHostsEditor(), helper: helper).uninstall()

        let script = try #require(runner.scripts.first)
        #expect(script.contains("sed -E"))
        #expect(!script.contains("delete-certificate"))
        #expect(!script.contains("remove-trusted-cert"))
    }

    @Test func enabledHelperUninstallFailureIsSurfacedAndNeverFallsBackToOsascript() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let editor = FakeHostsEditor()
        editor.error = EditorFailure()
        let helper = FakeHelper(status: .enabled)

        await #expect(throws: InstallError.self) {
            try await makeInstaller(runner: runner, hostsPath: hostsPath, editor: editor, helper: helper).uninstall()
        }
        #expect(runner.scripts.isEmpty)
    }

    // MARK: - removeCA

    @Test func removeCARunsTheFullLegacyCleanupAndUnregistersTheHelper() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let helper = FakeHelper(status: .enabled)

        try await makeInstaller(runner: runner, hostsPath: hostsPath, editor: FakeHostsEditor(), helper: helper).removeCA()

        let script = try #require(runner.scripts.first)
        #expect(script.contains("sed -E"))
        #expect(script.contains("remove-trusted-cert -d"))
        #expect(script.contains("delete-certificate"))
        #expect(script.contains("dscacheutil -flushcache"))
        #expect(helper.unregisterCount == 1)
    }

    @Test func removeCAWithoutAHelperStillRunsTheLegacyCleanup() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).removeCA()

        #expect(runner.scripts.count == 1)
        #expect(runner.scripts.first?.contains("delete-certificate") == true)
    }
}
