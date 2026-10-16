import Foundation
import Crypto

/// Runs a privileged shell script. Injected so tests can record the script without
/// triggering the real macOS authorization dialog.
public protocol PrivilegedRunner: Sendable {
    func run(script: String) async throws
}

/// Runs an unprivileged shell command and returns its exit status and output. Injected
/// so the user-domain trust steps and the status probes are unit-testable without
/// touching a real login keychain.
public protocol CommandRunning: Sendable {
    func run(_ command: String) async -> CommandResult
}

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var standardOutput: String
    public var standardError: String

    public init(status: Int32, standardOutput: String = "", standardError: String = "") {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { status == 0 }

    /// stderr (stdout when stderr is empty), trimmed and capped, for a user-facing message.
    public var failureDetail: String {
        let primary = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = primary.isEmpty ? standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) : primary
        return Installer.capped(text)
    }
}

/// The production command runner: `/bin/sh -c`, capturing stdout and stderr.
public struct ShellCommandRunner: CommandRunning {
    public init() {}

    public func run(_ command: String) async -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, standardError: String(describing: error))
        }
        // Drain stdout and stderr concurrently: reading stdout to EOF first deadlocks when
        // the child fills the 64 KiB stderr pipe buffer and blocks before writing stdout.
        // The blocking reads run on GCD threads, not the cooperative pool, so waiting on the
        // child cannot starve other concurrently running async work.
        let (outData, errData) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(Data, Data), Never>) in
            let collector = PipeCollector()
            let group = DispatchGroup()
            let outHandle = out.fileHandleForReading
            let errHandle = err.fileHandleForReading
            group.enter()
            DispatchQueue.global().async {
                collector.setStdout(outHandle.readDataToEndOfFile())
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                collector.setStderr(errHandle.readDataToEndOfFile())
                group.leave()
            }
            group.notify(queue: .global()) {
                continuation.resume(returning: (collector.stdout, collector.stderr))
            }
        }
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self))
    }
}

/// Holds the stdout/stderr bytes `ShellCommandRunner` drains on two background reads.
private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()

    func setStdout(_ data: Data) { lock.withLock { outData = data } }
    func setStderr(_ data: Data) { lock.withLock { errData = data } }

    var stdout: Data { lock.withLock { outData } }
    var stderr: Data { lock.withLock { errData } }
}

/// The production privileged runner: `osascript -e 'do shell script … with administrator privileges'`
/// produces the single system authorization prompt for the privileged phase.
public struct OsascriptRunner: PrivilegedRunner {
    public init() {}

    public func run(script: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.appleScript(forShellScript: script)]
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw InstallError.runnerFailed(String(describing: error))
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        throw InstallError.runnerFailed(Self.failureMessage(
            terminationStatus: process.terminationStatus,
            stderr: String(decoding: errData, as: UTF8.self)))
    }

    /// Maps a failed `osascript` run to a clear message: a dismissed admin prompt (`User
    /// canceled` / `-128`) reads as "cancelled"; anything else carries the trimmed, capped
    /// stderr so the real reason is visible in the menu.
    static func failureMessage(terminationStatus: Int32, stderr: String) -> String {
        if terminatedByUser(stderr) {
            return "Installation was cancelled: the administrator password prompt was dismissed."
        }
        let detail = Installer.capped(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        return detail.isEmpty ? "osascript exited with status \(terminationStatus)" : detail
    }

    static func terminatedByUser(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("user canceled") || lowered.contains("user cancelled")
            || lowered.contains("-128")
    }

    /// Wraps a shell script in an AppleScript `do shell script` string, escaping
    /// backslashes and quotes so arbitrary hosts text survives intact.
    static func appleScript(forShellScript script: String) -> String {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}

public struct InstallStatus: Equatable, Sendable {
    /// Really trusted (`security verify-cert -p basic`), not merely present in a keychain.
    public var caTrusted: Bool
    /// A certificate with our name is in the login or System keychain, whether or not trusted.
    public var caPresent: Bool
    public var hostsEntry: Bool
    public var portListening: Bool
    public var nodeCAEnv: Bool

    public init(caTrusted: Bool, caPresent: Bool, hostsEntry: Bool, portListening: Bool, nodeCAEnv: Bool) {
        self.caTrusted = caTrusted
        self.caPresent = caPresent
        self.hostsEntry = hostsEntry
        self.portListening = portListening
        self.nodeCAEnv = nodeCAEnv
    }
}

public enum InstallError: Error, Equatable, Sendable {
    case runnerFailed(String)
    case commandFailed(command: String, status: Int32)
    /// The safety-critical hosts restore succeeded, but leftover CA trust cleanup did not.
    case trustCleanupFailed(String)
}

extension InstallError: CustomStringConvertible {
    /// Renders the human message directly, so the menu shows `boom` and not
    /// `runnerFailed("boom")`.
    public var description: String {
        switch self {
        case .runnerFailed(let message): return message
        case .commandFailed(let command, let status): return "Command failed with status \(status): \(command)"
        case .trustCleanupFailed(let detail):
            return "openrouter.ai access was restored, but removing the CA trust did not fully "
                + "succeed: \(detail)"
        }
    }
}

/// Installs the CA and the hosts entry for `openrouter.ai`.
///
/// Two phases so each runs where the OS allows it:
/// 1. unprivileged, from the user's own GUI session: trust the CA in the login keychain
///    (`security add-trusted-cert` shows macOS's authorization dialog), then verify it;
/// 2. one admin script: the `/etc/hosts` entry and a DNS cache flush, nothing else.
public final class Installer: @unchecked Sendable {
    private let caPEMURL: URL
    private let caCommonName: String
    private let runner: PrivilegedRunner
    private let commandRunner: CommandRunning
    private let hostsPath: String

    public init(
        caPEMURL: URL,
        caCommonName: String = "OpenProxy Local CA",
        runner: PrivilegedRunner,
        commandRunner: CommandRunning,
        hostsPath: String = "/etc/hosts"
    ) {
        self.caPEMURL = caPEMURL
        self.caCommonName = caCommonName
        self.runner = runner
        self.commandRunner = commandRunner
        self.hostsPath = hostsPath
    }

    /// Phase 1 trusts the CA in the user's login keychain (user-domain trust, no `-d`) and
    /// verifies it; phase 2 adds the hosts entry. Fail closed: a trust failure throws before
    /// any hosts edit, so a client is never routed to a proxy it cannot trust.
    public func install() async throws {
        let trustedCopy = try privateCopyOfCA()
        defer { try? FileManager.default.removeItem(at: trustedCopy.deletingLastPathComponent()) }

        let add = await commandRunner.run(Self.addTrustCommand(certPath: trustedCopy.path))
        guard add.succeeded else {
            throw InstallError.runnerFailed(Self.trustFailureMessage(add))
        }
        let verify = await commandRunner.run(Self.verifyTrustCommand(certPath: trustedCopy.path))
        guard verify.succeeded else {
            throw InstallError.runnerFailed(
                "The CA was added to the login keychain but could not be verified as trusted: "
                    + verify.failureDetail)
        }

        // `set -e` aborts at the first failed step; the trailing flushcache can no longer mask
        // an earlier hosts failure. No keychain command runs privileged anymore.
        let script = """
        set -e
        \(Self.hostsEditScript(hostsPath: hostsPath, adding: true))
        dscacheutil -flushcache
        """
        do {
            try await runner.run(script: script)
        } catch {
            throw InstallError.runnerFailed(String(describing: error))
        }
    }

    /// User-domain trust (`-r trustRoot`, no `-d`) in the login keychain.
    static func addTrustCommand(certPath: String) -> String {
        "security add-trusted-cert -r trustRoot -k \"$HOME/Library/Keychains/login.keychain-db\" \(quoted(certPath))"
    }

    static func verifyTrustCommand(certPath: String) -> String {
        "security verify-cert -c \(quoted(certPath)) -p basic"
    }

    private static func trustFailureMessage(_ result: CommandResult) -> String {
        let detail = result.failureDetail
        return detail.isEmpty
            ? "Could not add the CA to the login keychain."
            : "Could not add the CA to the login keychain: \(detail)"
    }

    /// Copies `ca.pem` into a private, owner-only temp directory and re-checks the SHA-256
    /// fingerprint of the copy before anything trusts it, so a swapped, unreadable or malformed
    /// `ca.pem` is never trusted. The caller removes the returned file's directory.
    private func privateCopyOfCA() throws -> URL {
        guard let pem = try? String(contentsOf: caPEMURL, encoding: .utf8),
              let expected = Self.sha256Fingerprint(ofPEM: pem)
        else {
            throw InstallError.runnerFailed("The CA certificate is missing or is not a valid certificate.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "openproxy-ca-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let copy = directory.appending(path: "ca.pem")
            try Data(pem.utf8).write(to: copy)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: copy.path)
            guard let copiedPEM = try? String(contentsOf: copy, encoding: .utf8),
                  Self.sha256Fingerprint(ofPEM: copiedPEM) == expected
            else {
                throw InstallError.runnerFailed("The CA copy did not match the expected certificate.")
            }
            return copy
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Lower-case hex SHA-256 of the certificate DER, as `openssl x509 -fingerprint -sha256`
    /// prints it without separators. Returns nil when the text is not a single PEM certificate.
    static func sha256Fingerprint(ofPEM pem: String) -> String? {
        let base64 = pem.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: base64) else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Command output can be huge; cap what reaches the menu.
    static func capped(_ text: String, limit: Int = 500) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// Phase A (privileged) restores `/etc/hosts` first — the critical safety path — then
    /// best-effort clears any admin trust settings an old `add-trusted-cert -d` install left,
    /// and sweeps a leftover CA from the System keychain; phase B (unprivileged) removes the
    /// user-domain trust and the login-keychain certificate. Hosts restore must never be
    /// blocked by the sweeps, and a leftover cleanup failure must be reported, not swallowed.
    public func uninstall() async throws {
        let script = """
        set -e
        \(Self.hostsEditScript(hostsPath: hostsPath, adding: false))
        security remove-trusted-cert -d \(Self.quoted(caPEMURL.path)) || true
        \(Self.deleteCertificatesScript(commonName: caCommonName, keychain: "/Library/Keychains/System.keychain"))
        dscacheutil -flushcache
        """
        do {
            try await runner.run(script: script)
        } catch {
            throw InstallError.runnerFailed(String(describing: error))
        }
        // The hosts entry is already gone at this point, so this is a warning-level failure
        // (never a rollback), but it must not be reported as a clean success either.
        if let failure = await removeUserDomainTrust() {
            throw InstallError.trustCleanupFailed(failure)
        }
    }

    /// Best-effort, unprivileged cleanup of the user-domain trust and the login-keychain
    /// certificate. The hosts entry is the safety-critical half and is already gone, so
    /// failures are collected and reported rather than thrown here. `remove-trusted-cert`
    /// reads the file, so it runs before anything else.
    private func removeUserDomainTrust() async -> String? {
        var failures: [String] = []
        let removeTrust = await commandRunner.run(
            "security remove-trusted-cert \(Self.quoted(caPEMURL.path))")
        if !removeTrust.succeeded {
            failures.append("per-user trust: \(removeTrust.failureDetail)")
        }
        let deleteCerts = await commandRunner.run(Self.deleteCertificatesScript(
            commonName: caCommonName,
            keychain: "\"$HOME/Library/Keychains/login.keychain-db\"",
            removeTrustSettings: true))
        if !deleteCerts.succeeded {
            failures.append("login-keychain certificate: \(deleteCerts.failureDetail)")
        }
        // Item 1: "Set for GUI apps" writes NODE_EXTRA_CA_CERTS into the launchd environment,
        // so every GUI app launched until logout keeps trusting the (about to be removed) CA.
        // Clear it, but only when it still points at our ca.pem. Best effort.
        let nodeEnv = await commandRunner.run("launchctl getenv NODE_EXTRA_CA_CERTS")
        if nodeEnv.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == caPEMURL.path {
            let unset = await commandRunner.run("launchctl unsetenv NODE_EXTRA_CA_CERTS")
            if !unset.succeeded {
                failures.append("NODE_EXTRA_CA_CERTS: \(unset.failureDetail)")
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    /// Deletes every certificate with our common name by its SHA-1 hash. `security
    /// delete-certificate -c <CN>` fails with "ambiguous" when two CAs share the CN — the
    /// normal reinstall case — so each match returned by `find-certificate` is deleted by hash.
    /// Best-effort (`|| true`): a keychain without our cert must not fail the caller. On the
    /// login keychain `removeTrustSettings` adds `-t` so the per-user trust settings are
    /// removed with the certificate, not orphaned.
    static func deleteCertificatesScript(commonName: String, keychain: String, removeTrustSettings: Bool = false) -> String {
        let trustFlag = removeTrustSettings ? "-t " : ""
        return """
        hashes=$(security find-certificate -a -Z -c \(quoted(commonName)) \(keychain) 2>/dev/null | awk '/SHA-1 hash:/ { print $NF }')
        for hash in $hashes; do
            security delete-certificate \(trustFlag)-Z "$hash" \(keychain) || true
        done
        """
    }

    /// The privileged `/etc/hosts` edit. It re-reads the file as root instead of trusting an
    /// unprivileged snapshot, edits only the managed line, and swaps in a temp file in the
    /// same directory so the replace is atomic. A failed read aborts (with `set -e`) before
    /// anything is written, so the real file is never truncated or filled with empty text.
    static func hostsEditScript(hostsPath: String, adding: Bool) -> String {
        let edit: String
        if adding {
            edit = """
            cat "$hosts" > "$tmp"
            if ! grep -Eq \(quoted(HostsFile.managedLinePattern)) "$tmp"; then
                if [ -s "$tmp" ] && [ -n "$(tail -c 1 "$tmp")" ]; then
                    printf '\\n' >> "$tmp"
                fi
                printf '%s\\n' \(quoted(HostsFile.entry)) >> "$tmp"
            fi
            """
        } else {
            edit = "sed -E \(quoted("/" + HostsFile.managedLinePattern + "/d")) \"$hosts\" > \"$tmp\""
        }
        return """
        hosts=\(quoted(hostsPath))
        tmp=$(mktemp "${hosts}.openproxy.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        \(edit)
        chmod "$(stat -f '%Lp' "$hosts")" "$tmp"
        chown "$(stat -f '%Su:%Sg' "$hosts")" "$tmp"
        mv "$tmp" "$hosts"
        """
    }

    public func status() async -> InstallStatus {
        // Trust means actually trusted, not merely present: `verify-cert -p basic` is the only
        // check that catches a certificate that was imported but whose trust write was denied.
        let trust = await commandRunner.run(Self.verifyTrustCommand(certPath: caPEMURL.path))
        let loginFind = await commandRunner.run(
            "security find-certificate -c \(Self.quoted(caCommonName)) \"$HOME/Library/Keychains/login.keychain-db\"")
        let systemFind = await commandRunner.run(
            "security find-certificate -c \(Self.quoted(caCommonName)) /Library/Keychains/System.keychain")
        let port = await commandRunner.run("nc -z -G 1 127.0.0.1 443")
        let nodeEnv = await commandRunner.run("launchctl getenv NODE_EXTRA_CA_CERTS")
        return InstallStatus(
            caTrusted: trust.succeeded,
            caPresent: loginFind.succeeded || systemFind.succeeded,
            hostsEntry: HostsFile.isPresent(in: Self.readHosts(hostsPath)),
            portListening: port.succeeded,
            nodeCAEnv: !nodeEnv.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    /// Path to the CA certificate PEM, for the copyable Node line.
    public var caPEMPath: String { caPEMURL.path }

    /// The shell line Node clients need in their profile. The app only copies it; it never
    /// writes any shell profile.
    public static func nodeCAExportLine(caPEMPath: String) -> String {
        "export NODE_EXTRA_CA_CERTS=\"\(caPEMPath)\""
    }

    /// Points new processes at the CA for Node clients. Unprivileged, so toggling it never prompts.
    public func applyNodeCAEnv() async throws {
        let command = Self.nodeCAEnvCommand(caPEMURL: caPEMURL)
        let result = await commandRunner.run(command)
        guard result.succeeded else {
            throw InstallError.commandFailed(command: command, status: result.status)
        }
    }

    static func nodeCAEnvCommand(caPEMURL: URL) -> String {
        "launchctl setenv NODE_EXTRA_CA_CERTS \(quoted(caPEMURL.path))"
    }

    /// Read-only view for `status()` only. Never used to build a write: a read error must not
    /// become empty hosts text.
    private static func readHosts(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Single-quotes a value for `/bin/sh`, the only quoting that survives arbitrary text.
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension Installer {
    public convenience init(ca: CertAuthority, runner: PrivilegedRunner, hostsPath: String = "/etc/hosts") {
        self.init(
            caPEMURL: ca.caCertificatePEMURL,
            runner: runner,
            commandRunner: ShellCommandRunner(),
            hostsPath: hostsPath)
    }
}
