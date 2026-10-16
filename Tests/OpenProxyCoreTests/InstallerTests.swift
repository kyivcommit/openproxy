import Foundation
import Testing

@testable import OpenProxyCore

private let hostsEntry = "127.0.0.1 openrouter.ai # openproxy"
private let fakeCAPath = "/tmp/openproxy-test/ca.pem"

/// A real on-disk CA, so install()'s fingerprint check has a certificate to read.
private enum TestCA {
    static let directory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "openproxy-installer-ca-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ca = CertAuthority(directory: dir)
        try? ca.loadOrCreate()
        return dir
    }()

    static var pemURL: URL { directory.appending(path: "ca.pem") }
}

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

/// Records the unprivileged commands and answers them from a handler, so the login-keychain
/// trust phase and the status probes never touch a real keychain.
private final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let handler: @Sendable (String) -> CommandResult

    init(handler: @escaping @Sendable (String) -> CommandResult = { _ in CommandResult(status: 0) }) {
        self.handler = handler
    }

    var commands: [String] { lock.withLock { recorded } }

    func run(_ command: String) async -> CommandResult {
        lock.withLock { recorded.append(command) }
        return handler(command)
    }
}

@Suite("Installer")
struct InstallerTests {
    private func makeInstaller(
        runner: PrivilegedRunner,
        commandRunner: CommandRunning = FakeCommandRunner(),
        hostsPath: String
    ) -> Installer {
        Installer(caPEMURL: TestCA.pemURL, runner: runner, commandRunner: commandRunner, hostsPath: hostsPath)
    }

    private func makeHostsFile(_ content: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).hosts")
        try Data(content.utf8).write(to: url)
        return url.path
    }

    /// Extracts the private temp copy path (`/…/openproxy-ca-…/ca.pem`) from a command.
    private func tempCopyPath(in command: String) -> String? {
        command.range(of: "/[^']*openproxy-ca-[^']*/ca\\.pem", options: .regularExpression)
            .map { String(command[$0]) }
    }

    // MARK: - Item 1: two-phase install

    @Test func installTrustsInUserKeychainThenEditsHostsWithoutKeychainInScript() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let commands = FakeCommandRunner()

        try await makeInstaller(runner: runner, commandRunner: commands, hostsPath: hostsPath).install()

        // Phase 1: unprivileged, user-domain trust in the login keychain, then verify.
        #expect(commands.commands.count == 2)
        let add = try #require(commands.commands.first)
        #expect(add.contains(#"security add-trusted-cert -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db""#))
        #expect(!add.contains(" -d "))
        #expect(!add.contains("System.keychain"))
        let verify = try #require(commands.commands.last)
        #expect(verify.contains("security verify-cert -c"))
        #expect(verify.contains("-p basic"))
        // Both commands act on the same private temp copy, never the user-writable ca.pem directly.
        let copied = try #require(tempCopyPath(in: add))
        #expect(copied == tempCopyPath(in: verify))
        #expect(copied != TestCA.pemURL.path)

        // Phase 2: one admin script with the hosts entry and the flush only.
        #expect(runner.scripts.count == 1)
        let script = try #require(runner.scripts.first)
        #expect(script.hasPrefix("set -e\n"))
        #expect(script.contains(hostsEntry))
        #expect(script.contains(hostsPath))
        #expect(script.contains("dscacheutil -flushcache"))
        #expect(!script.contains("security add-trusted-cert"))
        #expect(!script.contains("System.keychain"))
        #expect(!script.contains("verify-cert"))
    }

    @Test func installFailsClosedWhenTrustIsNotVerified() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let commands = FakeCommandRunner(handler: { command in
            command.contains("verify-cert")
                ? CommandResult(status: 1, standardError: "CSSMERR_TP_NOT_TRUSTED")
                : CommandResult(status: 0)
        })
        let installer = makeInstaller(runner: runner, commandRunner: commands, hostsPath: hostsPath)

        await #expect(throws: InstallError.self) { try await installer.install() }
        // The hosts entry is never routed to a proxy the clients cannot trust.
        #expect(runner.scripts.isEmpty)
    }

    @Test func installFailsClosedWhenTrustCannotBeAdded() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let commands = FakeCommandRunner(handler: { command in
            command.contains("add-trusted-cert")
                ? CommandResult(status: 1, standardError: "SecTrustSettingsSetTrustSettings: denied")
                : CommandResult(status: 0)
        })
        let installer = makeInstaller(runner: runner, commandRunner: commands, hostsPath: hostsPath)

        await #expect(throws: InstallError.self) { try await installer.install() }
        #expect(runner.scripts.isEmpty)
    }

    @Test func installFailsBeforeRunningAnythingWhenTheCAIsMissingOrInvalid() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        let badCA = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pem")
        try Data("not a certificate".utf8).write(to: badCA)
        defer {
            try? FileManager.default.removeItem(atPath: hostsPath)
            try? FileManager.default.removeItem(at: badCA)
        }
        let runner = RecordingRunner()
        let commands = FakeCommandRunner()
        let installer = Installer(
            caPEMURL: badCA, runner: runner, commandRunner: commands, hostsPath: hostsPath)

        await #expect(throws: InstallError.self) { try await installer.install() }
        #expect(commands.commands.isEmpty)
        #expect(runner.scripts.isEmpty)
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

    // MARK: - Item 2: uninstall

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

    @Test func statusProbesTheKeychainThroughTheCommandRunner() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let present = FakeCommandRunner()
        let absent = FakeCommandRunner(handler: { command in
            command.contains("find-certificate") ? CommandResult(status: 1) : CommandResult(status: 0)
        })

        #expect(await makeInstaller(runner: runner, commandRunner: present, hostsPath: hostsPath).status().caTrusted)
        #expect(await makeInstaller(runner: runner, commandRunner: absent, hostsPath: hostsPath).status().caTrusted == false)
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

    // MARK: - Hosts edit: stop at the first error, never mask it with flushcache

    @Test func installScriptStopsAtFirstErrorAndOrdersSteps() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).install()

        let script = try #require(runner.scripts.first)
        // Without `set -e` the always-succeeding trailing flushcache made the whole script
        // report success even when hosts failed; the script must abort at step one.
        #expect(script.hasPrefix("set -e\n"))
        let hostsReplace = try #require(script.range(of: "mv \"$tmp\" \"$hosts\""))
        let flush = try #require(script.range(of: "dscacheutil -flushcache"))
        #expect(hostsReplace.lowerBound < flush.lowerBound)
    }

    // MARK: - Hosts edit runs privileged, re-reads, replaces atomically

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

    @Test func installQuotesHostsPathWithSpacesAndSingleQuotes() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "a b'c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hostsPath = dir.appending(path: "my hosts").path
        try Data("127.0.0.1 localhost\n".utf8).write(to: URL(fileURLWithPath: hostsPath))
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).install()

        let script = try #require(runner.scripts.first)
        #expect(script.contains(shellQuoted(hostsPath)))
    }

    // MARK: - Validate the CA PEM before trusting it from a user-writable path

    @Test func sha256FingerprintMatchesOpenssl() throws {
        let pem = try String(contentsOf: TestCA.pemURL, encoding: .utf8)
        let fingerprint = try #require(Installer.sha256Fingerprint(ofPEM: pem))
        #expect(fingerprint.count == 64)
        #expect(fingerprint == fingerprint.lowercased())
        #expect(Installer.sha256Fingerprint(ofPEM: "not a certificate") == nil)

        guard let openssl = opensslPath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = ["x509", "-in", TestCA.pemURL.path, "-noout", "-fingerprint", "-sha256"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let opensslFingerprint = text.split(separator: "=").last.map(String.init)?
            .replacingOccurrences(of: ":", with: "").lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(opensslFingerprint == fingerprint)
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
