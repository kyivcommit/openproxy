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
    static var pem: String { (try? String(contentsOf: pemURL, encoding: .utf8)) ?? "" }
}

/// A decoy certificate whose CN merely contains "OpenProxy Local CA" — the case a substring
/// `find-certificate -c` match would wrongly sweep. Generated once with openssl; `nil` when
/// openssl is absent (which also disables the sweep tests).
private let decoyCAPEM: String? = {
    guard let openssl = opensslPath else { return nil }
    let dir = FileManager.default.temporaryDirectory.appending(path: "openproxy-decoy-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = dir.appending(path: "ca.key")
    let out = dir.appending(path: "ca.pem")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: openssl)
    process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                         "-keyout", key.path, "-out", out.path, "-subj", "/CN=OpenProxy Local CA Extra"]
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return try? String(contentsOf: out, encoding: .utf8)
}()

/// One certificate the fake `security` reports, with the SHA-1 hash it announces for it.
private struct FakeCert {
    let hash: String
    let pem: String
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

    func run(_ command: String, timeout: Duration) async -> CommandResult {
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

    private func exactCert(hash: String) -> FakeCert { FakeCert(hash: hash, pem: TestCA.pem) }

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
        // Each candidate hash is validated and its subject confirmed exactly before deletion.
        #expect(script.contains("/^[0-9A-Fa-f]{40}$/"))
        #expect(script.contains("openssl x509 -in"))
        #expect(script.contains("while read -r hash"))
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

    @Test func uninstallRestoresHostsBeforeSweepingKeychains() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let commands = FakeCommandRunner()

        try await makeInstaller(runner: runner, commandRunner: commands, hostsPath: hostsPath).uninstall()

        let script = try #require(runner.scripts.first)
        let remove = try #require(script.range(of: "sed -E"))
        let sweep = try #require(script.range(of: "security find-certificate"))
        let flush = try #require(script.range(of: "dscacheutil -flushcache"))
        #expect(remove.lowerBound < sweep.lowerBound)
        #expect(sweep.lowerBound < flush.lowerBound)

        // Phase B (unprivileged): user-domain trust removal + login-keychain cert cleanup.
        #expect(commands.commands.contains { $0.contains("security remove-trusted-cert") })
        #expect(commands.commands.contains { $0.contains("login.keychain-db") })
    }

    @Test func uninstallIsIdempotentWhenNothingIsInstalled() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).uninstall()

        #expect(runner.scripts.count == 1)
        let script = try #require(runner.scripts.first)
        #expect(script.contains("sed -E"))
        #expect(!script.contains(hostsEntry))
    }

    @Test func uninstallRestoresHostsEvenWhenTrustRemovalFails() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let commands = FakeCommandRunner(handler: { _ in
            CommandResult(status: 1, standardError: "no trust settings")
        })

        // Phase B is best-effort for correctness, but the hosts restore — the safety-critical
        // half — already ran and must never be undone. The leftover failure is reported, not
        // swallowed as a clean success.
        await #expect(throws: InstallError.self) { try await makeInstaller(runner: runner, commandRunner: commands, hostsPath: hostsPath).uninstall() }

        #expect(runner.scripts.count == 1)
        #expect(commands.commands.contains { $0.contains("remove-trusted-cert") })
    }

    // MARK: - Item 6: a missing trust setting is success, not a warning

    @Test func removeTrustThatWasNeverSetIsNotAFailure() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let commands = FakeCommandRunner(handler: { command in
            command.contains("remove-trusted-cert")
                ? CommandResult(status: 1, standardError: "SecTrustSettingsRemoveTrustSettings: The specified item could not be found in the keychain.")
                : CommandResult(status: 0)
        })

        // The exact Security.framework error for "no trust settings" must not be reported.
        try await makeInstaller(runner: runner, commandRunner: commands, hostsPath: hostsPath).uninstall()
    }

    @Test func isAlreadyNotTrustedRecognisesOnlyTheMissingSettingError() {
        #expect(Installer.isAlreadyNotTrusted(CommandResult(
            status: 1,
            standardError: "SecTrustSettingsRemoveTrustSettings: The specified item could not be found in the keychain.")))
        #expect(!Installer.isAlreadyNotTrusted(CommandResult(status: 1, standardError: "SecTrustSettingsSetTrustSettings: denied")))
        #expect(!Installer.isAlreadyNotTrusted(CommandResult(status: 0)))
    }

    @Test func uninstallRemovesAdminTrustInPrivilegedPhaseBeforeSweepingSystemKeychain() async throws {
        // An older install used `add-trusted-cert -d`, which writes admin trust settings that
        // deleting the certificate item leaves behind; `remove-trusted-cert -d` clears them.
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).uninstall()

        let script = try #require(runner.scripts.first)
        let hostsRestore = try #require(script.range(of: "sed -E"))
        let removeTrust = try #require(script.range(of: "security remove-trusted-cert -d"))
        let sweep = try #require(script.range(of: "security find-certificate"))
        #expect(hostsRestore.lowerBound < removeTrust.lowerBound)
        #expect(removeTrust.lowerBound < sweep.lowerBound)
        // The CA file is passed and the step is best-effort, so a missing admin trust
        // setting cannot fail the uninstall.
        #expect(script.contains(TestCA.pemURL.path))
        let trustLine = try #require(script.split(separator: "\n").first { $0.contains("remove-trusted-cert") })
        #expect(trustLine.contains("|| true"))
    }

    // MARK: - Item 3: validate the PEM before the privileged remove-trusted-cert

    @Test func uninstallValidatesFingerprintBeforeAdminTrustRemoval() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        try await makeInstaller(runner: runner, hostsPath: hostsPath).uninstall()

        let script = try #require(runner.scripts.first)
        let fingerprint = try #require(Installer.sha256Fingerprint(ofPEM: TestCA.pem))
        // The copy is validated against the SHA-256 fingerprint embedded by the app...
        #expect(script.contains("-fingerprint -sha256"))
        #expect(script.contains(fingerprint))
        // ...and only the root-owned copy is handed to the privileged remove-trusted-cert.
        let trustLine = try #require(script.split(separator: "\n").first { $0.contains("remove-trusted-cert") })
        #expect(trustLine.contains("\"$ca_copy\""))
        #expect(!trustLine.contains(TestCA.pemURL.path))
    }

    @Test func adminTrustRemovalUsesTheCopyOnlyWhenTheFingerprintMatches() throws {
        let fingerprint = try #require(Installer.sha256Fingerprint(ofPEM: TestCA.pem))
        let dir = FileManager.default.temporaryDirectory.appending(path: "admin-trust-\(UUID().uuidString)")
        let bin = dir.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "calls.log")
        let fake = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(shellQuoted(log.path))
        """
        let executable = bin.appending(path: "security")
        try Data(fake.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        func run(_ script: String) throws -> Bool {
            try? FileManager.default.removeItem(at: log)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("remove-trusted-cert")
        }

        #expect(try run(Installer.removeAdminTrustScript(caPEMURL: TestCA.pemURL, expectedFingerprint: fingerprint)))
        // A fingerprint that does not match the file leaves the admin trust untouched.
        #expect(try !run(Installer.removeAdminTrustScript(caPEMURL: TestCA.pemURL, expectedFingerprint: String(repeating: "0", count: 64))))
        // No fingerprint: nothing is handed to root.
        #expect(try !run(Installer.removeAdminTrustScript(caPEMURL: TestCA.pemURL, expectedFingerprint: nil)))
    }


    @Test func uninstallDeletesLoginKeychainCertWithTrustSettings() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let commands = FakeCommandRunner()

        try await makeInstaller(runner: runner, commandRunner: commands, hostsPath: hostsPath).uninstall()

        // System keychain (privileged phase): no per-user trust settings to carry.
        let system = try #require(runner.scripts.first)
        #expect(system.contains("security delete-certificate -Z \"$hash\""))
        #expect(!system.contains("delete-certificate -t"))

        // Login keychain (phase B): `-t` removes the per-user trust settings with the cert.
        let login = try #require(commands.commands.first { $0.contains("login.keychain-db") })
        #expect(login.contains("security delete-certificate -t -Z \"$hash\""))
    }

    @Test func uninstallReportsLeftoverCleanupFailureAfterHostsRemoval() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let commands = FakeCommandRunner(handler: { command in
            command.contains("remove-trusted-cert")
                ? CommandResult(status: 1, standardError: "no trust settings")
                : CommandResult(status: 0)
        })

        var thrown: InstallError?
        do {
            try await makeInstaller(runner: runner, commandRunner: commands, hostsPath: hostsPath).uninstall()
        } catch let error as InstallError {
            thrown = error
        }

        // Hosts was restored first and was never blocked...
        #expect(runner.scripts.count == 1)
        #expect(runner.scripts.first?.contains("sed -E") == true)
        // ...but the leftover trust cleanup failure is reported, not hidden behind a success.
        #expect(thrown?.description.contains("trust") == true)
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

    @Test func statusTrustsOnlyWhenVerifyCertSucceeds() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()

        let trusted = FakeCommandRunner()
        let trustedStatus = await makeInstaller(
            runner: runner, commandRunner: trusted, hostsPath: hostsPath).status()
        #expect(trustedStatus.caTrusted)
        #expect(trustedStatus.caPresent)
        #expect(trusted.commands.contains { $0.contains("security verify-cert") })

        // The observed real-install bug: cert imported but trust settings denied.
        let presentButUntrusted = FakeCommandRunner(handler: { command in
            command.contains("verify-cert")
                ? CommandResult(status: 1, standardError: "CSSMERR_TP_NOT_TRUSTED")
                : CommandResult(status: 0)
        })
        let untrustedStatus = await makeInstaller(
            runner: runner, commandRunner: presentButUntrusted, hostsPath: hostsPath).status()
        #expect(untrustedStatus.caTrusted == false)
        #expect(untrustedStatus.caPresent)

        let missing = FakeCommandRunner(handler: { _ in CommandResult(status: 1) })
        let missingStatus = await makeInstaller(
            runner: runner, commandRunner: missing, hostsPath: hostsPath).status()
        #expect(missingStatus.caTrusted == false)
        #expect(missingStatus.caPresent == false)
    }

    @Test func statusTreatsATimedOutProbeAsFalseAndKeepsGoing() async throws {
        // A probe that had to be killed is "unknown", not true: it must not read as trusted
        // and must not stop the remaining probes from running.
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let commands = FakeCommandRunner(handler: { command in
            command.contains("find-certificate") || command.contains("verify-cert")
                ? CommandResult(status: -1, timedOut: true)
                : CommandResult(status: 0)
        })

        let status = await makeInstaller(
            runner: runner, commandRunner: commands, hostsPath: hostsPath).status()

        #expect(status.caTrusted == false)
        #expect(status.caPresent == false)
        #expect(status.hostsEntry == true)
        #expect(status.portListening == true)
    }

    @Test func nodeCAEnvCommandTargetsLaunchctl() {
        let command = Installer.nodeCAEnvCommand(caPEMURL: URL(fileURLWithPath: fakeCAPath))
        #expect(command.contains("launchctl setenv NODE_EXTRA_CA_CERTS"))
        #expect(command.contains(fakeCAPath))
    }

    // MARK: - Item 1: clear NODE_EXTRA_CA_CERTS when it points at our ca.pem

    @Test func uninstallClearsNodeCAEnvWhenItPointsAtOurCA() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let commands = FakeCommandRunner(handler: { command in
            command.contains("launchctl getenv")
                ? CommandResult(status: 0, standardOutput: TestCA.pemURL.path + "\n")
                : CommandResult(status: 0)
        })

        try await makeInstaller(runner: runner, commandRunner: commands, hostsPath: hostsPath).uninstall()

        #expect(commands.commands.contains { $0.contains("launchctl unsetenv NODE_EXTRA_CA_CERTS") })
    }

    @Test func uninstallLeavesNodeCAEnvWhenItIsSomeoneElses() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let commands = FakeCommandRunner(handler: { command in
            command.contains("launchctl getenv")
                ? CommandResult(status: 0, standardOutput: "/some/other/ca.pem\n")
                : CommandResult(status: 0)
        })

        try await makeInstaller(runner: runner, commandRunner: commands, hostsPath: hostsPath).uninstall()

        #expect(!commands.commands.contains { $0.contains("launchctl unsetenv") })
    }

    @Test func uninstallReportsFailureToClearNodeCAEnv() async throws {
        let hostsPath = try makeHostsFile("127.0.0.1 localhost\n\(hostsEntry)\n")
        defer { try? FileManager.default.removeItem(atPath: hostsPath) }
        let runner = RecordingRunner()
        let commands = FakeCommandRunner(handler: { command in
            if command.contains("launchctl getenv") {
                return CommandResult(status: 0, standardOutput: TestCA.pemURL.path + "\n")
            }
            if command.contains("launchctl unsetenv") {
                return CommandResult(status: 1, standardError: "launchctl: failed")
            }
            return CommandResult(status: 0)
        })

        var thrown: InstallError?
        do {
            try await makeInstaller(runner: runner, commandRunner: commands, hostsPath: hostsPath).uninstall()
        } catch let error as InstallError {
            thrown = error
        }

        #expect(thrown?.description.contains("NODE_EXTRA_CA_CERTS") == true)
    }


    @Test func appleScriptEscapesInputAndRequestsAdmin() {
        let appleScript = OsascriptRunner.appleScript(forShellScript: "echo \"hi\" \\ bye")
        #expect(appleScript.hasPrefix("do shell script"))
        #expect(appleScript.hasSuffix("with administrator privileges"))
        #expect(appleScript.contains("\\\"hi\\\""))
        #expect(appleScript.contains("\\\\ bye"))
    }

    // MARK: - Item 4: capture stderr, map cancellation, keep the menu message readable

    @Test func osascriptCancellationMapsToClearMessage() {
        for stderr in ["execution error: User canceled. (-128)", "user cancelled", "error -128"] {
            let message = OsascriptRunner.failureMessage(terminationStatus: 1, stderr: stderr)
            #expect(message.lowercased().contains("cancel"))
        }
    }

    @Test func osascriptFailureIncludesTrimmedAndCappedStderr() {
        let short = OsascriptRunner.failureMessage(
            terminationStatus: 2, stderr: "   mkdir: permission denied  ")
        #expect(short == "mkdir: permission denied")

        let long = String(repeating: "x", count: 900)
        let message = OsascriptRunner.failureMessage(terminationStatus: 1, stderr: "boom\n\(long)\n")
        #expect(message.hasPrefix("boom"))
        #expect(message.count <= 501) // capped at 500 plus the ellipsis
    }

    @Test func osascriptFailureWithoutStderrFallsBackToTheStatus() {
        let message = OsascriptRunner.failureMessage(terminationStatus: 7, stderr: "   \n")
        #expect(message.contains("7"))
    }

    @Test func installErrorDescribesAsItsMessage() {
        #expect(InstallError.runnerFailed("boom").description == "boom")
        #expect(String(describing: InstallError.runnerFailed("boom")) == "boom")
    }

    // MARK: - Item 4: drain stdout and stderr concurrently

    @Test func shellCommandRunnerDrainsBothPipesWithoutDeadlock() async {
        // A child that fills the stderr pipe buffer (>64 KiB) before writing stdout
        // deadlocks a runner that reads stdout to EOF before stderr.
        let result = await ShellCommandRunner().run(
            "yes err | head -c 100000 >&2; yes out | head -c 100000", timeout: .seconds(30))
        #expect(result.status == 0)
        #expect(result.standardError.count == 100000)
        #expect(result.standardOutput.count == 100000)
    }

    @Test func shellCommandRunnerCapturesSmallOutputAndStatus() async {
        let result = await ShellCommandRunner().run(
            "printf 'hello'; printf 'oops' >&2; exit 3", timeout: .seconds(30))
        #expect(result.status == 3)
        #expect(result.standardOutput == "hello")
        #expect(result.standardError == "oops")
    }

    // MARK: - Item 2/4: a stuck command is killed at its timeout, never hung on

    @Test func shellCommandRunnerTimesOutInsteadOfHanging() async {
        let started = Date()
        let result = await ShellCommandRunner().run("sleep 30", timeout: .seconds(1))
        let elapsed = Date().timeIntervalSince(started)
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(result.status == -1)
        #expect(elapsed < 5, "a 1 s timeout must not wait for the child")
    }

    @Test func shellCommandRunnerKeepsPartialOutputOnTimeout() async {
        let result = await ShellCommandRunner().run("printf 'partial'; sleep 30", timeout: .seconds(1))
        #expect(result.timedOut)
        #expect(result.standardOutput == "partial")
    }

    @Test func shellCommandRunnerDoesNotHangOnRepeatedInstantExit() async {
        // The observed race: a child that exits before its termination is observed left the
        // old `waitUntilExit()` spinning forever. 300 concurrent instant exits stress that
        // exact window; the deadline turns a regression into a failed test, not a hung suite.
        let completed = await withDeadline(.seconds(30)) {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<300 {
                    group.addTask {
                        await ShellCommandRunner().run("/usr/bin/true", timeout: .seconds(10)).succeeded
                    }
                }
                var allSucceeded = true
                for await succeeded in group { allSucceeded = allSucceeded && succeeded }
                return allSucceeded
            }
        }
        #expect(completed == true)
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

    // MARK: - Item 6: execute the SHA-1 sweep against a fake `security`

    private static let exactHash = "0C10AB995387345EDCE2A606EA3C358B9B3DD671"
    private static let otherHash = "B7A17CC40DA10BD0DD54F8A35B4FF98F5D46DCD7"

    @Test(.enabled(if: opensslPath != nil))
    func sweepDeletesNothingWhenNoCertificatesMatch() throws {
        let result = try runSweep(certs: [])
        #expect(result.status == 0)
        #expect(result.deletes.isEmpty)
    }

    @Test(.enabled(if: opensslPath != nil))
    func sweepDeletesSingleMatchByHash() throws {
        let result = try runSweep(certs: [self.exactCert(hash: Self.exactHash)])
        #expect(result.status == 0)
        #expect(result.deletes.count == 1)
        #expect(result.deletes.first?.contains("-Z \(Self.exactHash)") == true)
    }

    @Test(.enabled(if: opensslPath != nil))
    func sweepDeletesEachMatchingCertificateByHash() throws {
        let result = try runSweep(certs: [
            self.exactCert(hash: Self.exactHash),
            self.exactCert(hash: Self.otherHash),
        ])
        #expect(result.status == 0)
        #expect(result.deletes.count == 2)
        #expect(result.deletes.contains { $0.contains("-Z \(Self.exactHash)") })
        #expect(result.deletes.contains { $0.contains("-Z \(Self.otherHash)") })
    }

    @Test(.enabled(if: opensslPath != nil))
    func sweepSkipsCertWithMerelySimilarCommonName() throws {
        // `find-certificate -c` is a substring match: a decoy "OpenProxy Local CA Extra"
        // must not be swept, only a certificate whose subject CN is exactly ours.
        let decoy = try #require(decoyCAPEM)
        let result = try runSweep(certs: [
            self.exactCert(hash: Self.exactHash),
            FakeCert(hash: Self.otherHash, pem: decoy),
        ])
        #expect(result.status == 0)
        #expect(result.deletes.contains { $0.contains("-Z \(Self.exactHash)") })
        #expect(result.deletes.allSatisfy { !$0.contains(Self.otherHash) })
    }

    @Test(.enabled(if: opensslPath != nil))
    func sweepSkipsUnvalidatedHash() throws {
        // A crafted label line must not inject an arbitrary hash into the loop.
        let result = try runSweep(certs: [
            FakeCert(hash: "not-a-40-hex-hash", pem: TestCA.pem),
            self.exactCert(hash: Self.exactHash),
        ])
        #expect(result.deletes.allSatisfy { !$0.contains("not-a-40-hex-hash") })
        #expect(result.deletes.contains { $0.contains("-Z \(Self.exactHash)") })
    }

    @Test(.enabled(if: opensslPath != nil))
    func sweepUsesTrustFlagForLoginKeychainOnly() throws {
        let cert = self.exactCert(hash: Self.exactHash)
        let login = try runSweep(certs: [cert], removeTrustSettings: true)
        #expect(login.deletes.first?.contains("delete-certificate -t -Z \(Self.exactHash)") == true)
        let system = try runSweep(certs: [cert], removeTrustSettings: false)
        #expect(system.deletes.first?.contains("delete-certificate -Z \(Self.exactHash)") == true)
        #expect(system.deletes.first?.contains("-t ") == false)
    }

    @Test(.enabled(if: opensslPath != nil))
    func sweepKeepsGoingWhenADeleteFails() throws {
        // Best-effort: a failing delete must not abort the loop or fail the script.
        let result = try runSweep(certs: [
            self.exactCert(hash: Self.exactHash),
            self.exactCert(hash: Self.otherHash),
        ], deleteStatus: 1)
        #expect(result.status == 0)
        #expect(result.deletes.count == 2)
    }

}

/// Executes `Installer.deleteCertificatesScript` under `/bin/sh` with a fake `security`
/// executable first in `PATH`, so the sweep's real shell behaviour (hash validation, the exact
/// subject match, the trust flag, `|| true`) is exercised, not just the script text. The fake
/// reproduces the real `find-certificate -a -Z -c <CN> -p` shape: a hash line immediately
/// before each certificate's PEM block.
/// Returns the script's exit status and the arguments of every `delete-certificate` call.
private func runSweep(
    certs: [FakeCert],
    keychain: String = "login.keychain-db",
    removeTrustSettings: Bool = false,
    deleteStatus: Int32 = 0
) throws -> (status: Int32, deletes: [String]) {
    let dir = FileManager.default.temporaryDirectory.appending(path: "sweep-\(UUID().uuidString)")
    let bin = dir.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let log = dir.appending(path: "deletes.log")
    // Real `find-certificate -p` output always ends each PEM block with a newline, so the next
    // `SHA-1 hash:` starts on its own line.
    let blocks = certs.map { "SHA-1 hash: \($0.hash)\n\($0.pem.hasSuffix("\n") ? $0.pem : $0.pem + "\n")" }
        .joined(separator: "")
    let fake = """
    #!/bin/sh
    case "$1" in
      find-certificate) printf '%s\\n' \(shellQuoted(blocks));;
      delete-certificate) printf '%s\\n' "$*" >> \(shellQuoted(log.path)); exit \(deleteStatus);;
    esac
    """
    let executable = bin.appending(path: "security")
    try Data(fake.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", Installer.deleteCertificatesScript(
        commonName: "OpenProxy Local CA", keychain: keychain, removeTrustSettings: removeTrustSettings)]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    return (process.terminationStatus, logged.split(separator: "\n").map(String.init))
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

/// Runs `body`, giving up after `duration` and returning nil. Detached tasks mean a hung
/// body cannot keep the caller (and the whole suite) waiting on it.
private func withDeadline<T: Sendable>(
    _ duration: Duration,
    _ body: @escaping @Sendable () async -> T
) async -> T? {
    let once = FirstResult<T>()
    Task { once.resume(with: await body()) }
    Task {
        try? await Task.sleep(for: duration)
        once.resume(with: nil)
    }
    return await once.value()
}

/// Resolves exactly once: the first of a value or a timeout wins.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: T??
    private var continuation: CheckedContinuation<T?, Never>?

    func resume(with value: T?) {
        lock.withLock {
            guard result == nil else { return }
            result = .some(value)
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    func value() async -> T? {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let result {
                    continuation.resume(returning: result)
                    return
                }
                self.continuation = continuation
            }
        }
    }
}
