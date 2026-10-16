import Foundation
import Testing

@testable import OpenProxyCore

private let hostsEntry = "127.0.0.1 openrouter.ai # openproxy"
private let fakeCAPath = "/tmp/openproxy-test/ca.pem"

private final class RecordingRunner: PrivilegedRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var failure: Error?

    var scripts: [String] { lock.withLock { recorded } }

    func run(script: String) async throws {
        lock.withLock { recorded.append(script) }
        if let failure { throw failure }
    }
}

@Suite("Installer")
struct InstallerTests {
    private func makeInstaller(runner: PrivilegedRunner, hostsPath: String) -> Installer {
        Installer(caPEMURL: URL(fileURLWithPath: fakeCAPath), runner: runner, hostsPath: hostsPath)
    }

    private func makeHostsFile(_ content: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).hosts")
        try Data(content.utf8).write(to: url)
        return url.path
    }

    @Test func installRunsOneScriptWithAllSteps() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).install()

        #expect(runner.scripts.count == 1)
        let script = try #require(runner.scripts.first)
        #expect(script.contains("security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain"))
        #expect(script.contains(fakeCAPath))
        #expect(script.contains(hostsEntry))
        #expect(script.contains(hostsPath))
        #expect(script.contains("dscacheutil -flushcache"))
    }

    @Test func installIsIdempotentForHostsContent() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).install()

        let script = try #require(runner.scripts.first)
        #expect(script.components(separatedBy: hostsEntry).count - 1 == 1)
    }

    @Test func installPropagatesRunnerFailureAsTypedError() async throws {
        let hostsPath = try makeHostsFile("")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        runner.failure = URLError(.userCancelledAuthentication)
        let installer = makeInstaller(runner: runner, hostsPath: hostsPath)

        await #expect(throws: InstallError.self) { try await installer.install() }
    }

    @Test func uninstallRemovesHostsLineAndDeletesCertificate() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).uninstall()

        #expect(runner.scripts.count == 1)
        let script = try #require(runner.scripts.first)
        #expect(!script.contains(hostsEntry))
        #expect(script.contains("security delete-certificate"))
        #expect(script.contains("OpenProxy Local CA"))
        #expect(script.contains(hostsPath))
    }

    @Test func uninstallPropagatesRunnerFailureAsTypedError() async throws {
        let hostsPath = try makeHostsFile("\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        runner.failure = URLError(.userCancelledAuthentication)
        let installer = makeInstaller(runner: runner, hostsPath: hostsPath)

        await #expect(throws: InstallError.self) { try await installer.uninstall() }
    }

    @Test func statusReportsHostsEntry() async throws {
        let withEntry = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        let withoutEntry = try makeHostsFile("127.0.0.1 localhost\n")
        defer {
            try? FileManager.default.removeItem(atPath: withEntry)
            try? FileManager.default.removeItem(atPath: withoutEntry)
        }
        let runner = RecordingRunner()

        #expect(await makeInstaller(runner: runner, hostsPath: withEntry).status().hostsEntry)
        #expect(await makeInstaller(runner: runner, hostsPath: withoutEntry).status().hostsEntry == false)
    }

    @Test func nodeCAEnvCommandTargetsLaunchctl() {
        let command = Installer.nodeCAEnvCommand(caPEMURL: URL(fileURLWithPath: fakeCAPath))
        #expect(command.contains("launchctl setenv NODE_EXTRA_CA_CERTS"))
        #expect(command.contains(fakeCAPath))
    }

    @Test func appleScriptEscapesInputAndRequestsAdmin() {
        let appleScript = OsascriptRunner.appleScript(forShellScript: "echo \"hi\" \\ bye")
        #expect(appleScript.hasPrefix("do shell script"))
        #expect(appleScript.hasSuffix("with administrator privileges"))
        #expect(appleScript.contains("\\\"hi\\\""))
        #expect(appleScript.contains("\\\\ bye"))
    }
}
