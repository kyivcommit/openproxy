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

    @Test func uninstallDeletesCertificatesBySHA1Hash() async throws {
        // Two CAs can share the CN (a reinstall): `delete-certificate -c <CN>` fails as
        // "ambiguous", so every match is deleted by its SHA-1 hash instead.
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).uninstall()

        let script = try #require(runner.scripts.first)
        #expect(script.contains("security find-certificate -a -Z -c 'OpenProxy Local CA'"))
        #expect(script.contains("SHA-1 hash:"))
        #expect(script.contains("for hash in $hashes"))
        #expect(script.contains("security delete-certificate -Z \"$hash\""))
        #expect(!script.contains("security delete-certificate -c"))
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

    // MARK: - Finding (a): stop at the first error, never mask it with flushcache

    @Test func installScriptStopsAtFirstErrorAndOrdersSteps() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).install()

        let script = try #require(runner.scripts.first)
        // Without `set -e` the always-succeeding trailing flushcache made the whole script
        // report success even when security/hosts failed; the script must abort at step one.
        #expect(script.hasPrefix("set -e\n"))
        let security = try #require(script.range(of: "security add-trusted-cert"))
        let hostsReplace = try #require(script.range(of: "mv \"$tmp\" \"$hosts\""))
        let flush = try #require(script.range(of: "dscacheutil -flushcache"))
        #expect(security.lowerBound < hostsReplace.lowerBound)
        #expect(hostsReplace.lowerBound < flush.lowerBound)
    }

    // MARK: - Finding (b): hosts edit runs privileged, re-reads, replaces atomically

    @Test func installDoesNotEmbedStaleHostsSnapshot() async throws {
        let hostsPath = try makeHostsFile("STALE-SENTINEL-98765\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).install()

        let script = try #require(runner.scripts.first)
        #expect(!script.contains("STALE-SENTINEL-98765"))
        // Re-reads /etc/hosts as root and swaps in a temp file instead of truncating it.
        #expect(script.contains("cat \"$hosts\" > \"$tmp\""))
        #expect(script.contains("mktemp"))
        #expect(script.contains("mv \"$tmp\" \"$hosts\""))
    }

    @Test func uninstallDoesNotEmbedStaleHostsSnapshot() async throws {
        let hostsPath = try makeHostsFile("STALE-SENTINEL-98765\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).uninstall()

        let script = try #require(runner.scripts.first)
        #expect(!script.contains("STALE-SENTINEL-98765"))
        #expect(!script.contains(hostsEntry))
        #expect(script.contains("sed -E"))
        #expect(script.contains("mv \"$tmp\" \"$hosts\""))
    }

    @Test func hostsEditScriptRunsPrivilegedAndNeverTruncatesInPlace() async throws {
        let hostsPath = try makeHostsFile("")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).install()

        let script = try #require(runner.scripts.first)
        // The old `printf '%s' <text> > /etc/hosts` wrote "" on a read error; the rewrite
        // never truncates the real file: it writes a temp and moves it into place.
        #expect(!script.contains("> \(shellQuoted(hostsPath))"))
        #expect(script.contains(">> \"$tmp\""))
    }

    @Test func hostsEditScriptIsAtomicIdempotentAndFailsClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hosts-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostsPath = dir.appending(path: "hosts").path
        try Data("127.0.0.1 localhost\n".utf8).write(to: URL(fileURLWithPath: hostsPath))

        let add = "set -e\n" + Installer.hostsEditScript(hostsPath: hostsPath, adding: true)
        try runShell(add)
        try runShell(add) // idempotent
        var text = try String(contentsOfFile: hostsPath, encoding: .utf8)
        #expect(text.components(separatedBy: hostsEntry).count - 1 == 1)

        let remove = "set -e\n" + Installer.hostsEditScript(hostsPath: hostsPath, adding: false)
        try runShell(remove)
        text = try String(contentsOfFile: hostsPath, encoding: .utf8)
        #expect(text == "127.0.0.1 localhost\n")

        // A failed read aborts before the atomic replace and leaves no file behind.
        let missing = dir.appending(path: "does-not-exist").path
        #expect(throws: (any Error).self) {
            try runShell("set -e\n" + Installer.hostsEditScript(hostsPath: missing, adding: true))
        }
        #expect(!FileManager.default.fileExists(atPath: missing))
    }

    // MARK: - Quoting: spaces and single quotes must survive the AppleScript/shell layers

    @Test func hostsEditScriptAddsNewlineBeforeAppendingWhenMissing() throws {
        // `/etc/hosts` without a trailing newline must not have the entry glued onto the last line.
        let dir = FileManager.default.temporaryDirectory.appending(path: "hosts-nonl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostsPath = dir.appending(path: "hosts").path
        try Data("127.0.0.1 localhost".utf8).write(to: URL(fileURLWithPath: hostsPath))

        try runShell("set -e\n" + Installer.hostsEditScript(hostsPath: hostsPath, adding: true))

        let text = try String(contentsOfFile: hostsPath, encoding: .utf8)
        #expect(text == "127.0.0.1 localhost\n\(hostsEntry)\n")
        #expect(!text.contains("localhost\(hostsEntry)"))
    }
    @Test func quotesPathsWithSpacesAndSingleQuotes() {
        let path = "/tmp/a b'c/ca.pem"
        let command = Installer.nodeCAEnvCommand(caPEMURL: URL(fileURLWithPath: path))
        #expect(command == "launchctl setenv NODE_EXTRA_CA_CERTS '/tmp/a b'\\''c/ca.pem'")

        let wrapped = OsascriptRunner.appleScript(forShellScript: command)
        #expect(wrapped.hasPrefix("do shell script "))
        #expect(wrapped.hasSuffix(" with administrator privileges"))
        // AppleScript doubles the backslash so the shell still sees the original `'\''`.
        #expect(wrapped.contains("'/tmp/a b'\\\\''c/ca.pem'"))
    }

    @Test func installQuotesCaAndHostsPathsWithSpacesAndSingleQuotes() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "a b'c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hostsPath = dir.appending(path: "my hosts").path
        try Data("127.0.0.1 localhost\n".utf8).write(to: URL(fileURLWithPath: hostsPath))
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = RecordingRunner()
        let caPath = "/tmp/a b'c/ca.pem"

        try await Installer(
            caPEMURL: URL(fileURLWithPath: caPath), runner: runner, hostsPath: hostsPath
        ).install()

        let script = try #require(runner.scripts.first)
        #expect(script.contains(shellQuoted(caPath)))
        #expect(script.contains(shellQuoted(hostsPath)))
    }
}

/// The POSIX single-quote escaping the installer must produce for arbitrary paths.
private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func runShell(_ script: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw InstallError.commandFailed(command: script, status: process.terminationStatus)
    }
}
