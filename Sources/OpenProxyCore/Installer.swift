import Foundation
import Crypto

/// Runs a privileged shell script. Injected so tests can record the script without
/// triggering the real macOS authorization dialog.
public protocol PrivilegedRunner: Sendable {
    func run(script: String) async throws
}

/// Runs an unprivileged shell command and returns its exit status and output. Injected
/// so the user-domain trust steps and the status probes are unit-testable without
/// touching a real login keychain. `timeout` bounds the run so a stuck command can never
/// hang the caller: on expiry the process is terminated, then killed.
public protocol CommandRunning: Sendable {
    func run(_ command: String, timeout: Duration) async -> CommandResult
}

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var standardOutput: String
    public var standardError: String
    /// True when the command was killed for exceeding its timeout, so "unknown" reads
    /// distinctly from a genuine non-zero exit.
    public var timedOut: Bool

    public init(status: Int32, standardOutput: String = "", standardError: String = "", timedOut: Bool = false) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 }

    /// stderr (stdout when stderr is empty), trimmed and capped, for a user-facing message.
    public var failureDetail: String {
        let primary = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = primary.isEmpty ? standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) : primary
        let detail = Installer.capped(text)
        if timedOut {
            return detail.isEmpty ? "Command timed out." : "Command timed out. \(detail)"
        }
        return detail
    }
}

/// Bridges `Process.terminationHandler` to an async wait with a timeout. The handler
/// may fire before we start waiting (an instant exit), so the exit is latched.
private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var resumed = false
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Called from the termination handler.
    func markExited() {
        lock.withLock {
            exited = true
            resumeLocked(timedOut: false)
        }
    }

    /// Returns true when `timeout` elapsed before the process exited.
    func wait(timeout: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.withLock {
                if exited {
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + ProcessExitWaiter.seconds(timeout)) { [self] in
                lock.withLock { resumeLocked(timedOut: true) }
            }
        }
    }

    private func resumeLocked(timedOut: Bool) {
        guard !resumed, let continuation else { return }
        resumed = true
        self.continuation = nil
        continuation.resume(returning: timedOut)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// The production command runner: `/bin/sh -c`, capturing stdout and stderr.
public struct ShellCommandRunner: CommandRunning {
    public init() {}

    public func run(_ command: String, timeout: Duration) async -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Install the exit handler before `run()`: an instant exit must not race past it.
        // `waitUntilExit()` spins a run loop on the calling thread and can miss the
        // termination notification from a cooperative-pool thread, which is the hang this
        // replaces; the handler latches the exit instead.
        let exit = ProcessExitWaiter()
        process.terminationHandler = { _ in exit.markExited() }
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, standardError: String(describing: error))
        }
        // Drain stdout and stderr concurrently: reading stdout to EOF first deadlocks when
        // the child fills the 64 KiB stderr pipe buffer and blocks before writing stdout.
        // The blocking reads run on GCD threads, not the cooperative pool, so waiting on the
        // child cannot starve other concurrently running async work.
        let collector = PipeCollector()
        let drained = DispatchGroup()
        let outHandle = out.fileHandleForReading
        let errHandle = err.fileHandleForReading
        drained.enter()
        DispatchQueue.global().async {
            collector.setStdout(outHandle.readDataToEndOfFile())
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global().async {
            collector.setStderr(errHandle.readDataToEndOfFile())
            drained.leave()
        }

        let timedOut = await exit.wait(timeout: timeout)
        if timedOut {
            process.terminate()
            // Give SIGTERM a moment, then force it: a status probe must never hang the menu.
            try? await Task.sleep(for: .milliseconds(250))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        // Only report once both pipes reached EOF (after a kill the child is gone, so they
        // do). shortcut: a grandchild that inherited the pipes would delay EOF; no command
        // this runner issues backgrounds a child, so the direct signal is enough.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drained.notify(queue: .global()) { continuation.resume() }
        }
        return CommandResult(
            status: timedOut ? -1 : process.terminationStatus,
            standardOutput: String(decoding: collector.stdout, as: UTF8.self),
            standardError: String(decoding: collector.stderr, as: UTF8.self),
            timedOut: timedOut)
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
    /// Bounds the admin prompt: if it is never answered, the install must not hang.
    public let timeout: Duration

    public init(timeout: Duration = .seconds(300)) {
        self.timeout = timeout
    }

    public func run(script: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.appleScript(forShellScript: script)]
        let errPipe = Pipe()
        process.standardError = errPipe
        // Handler before `run()`: never block a cooperative thread on `waitUntilExit()`.
        let exit = ProcessExitWaiter()
        process.terminationHandler = { _ in exit.markExited() }
        do {
            try process.run()
        } catch {
            throw InstallError.runnerFailed(String(describing: error))
        }
        // Drain stderr on a GCD thread while waiting: a blocking read on the cooperative
        // pool would starve other async work, and the prompt can take a while.
        let errHandle = errPipe.fileHandleForReading
        async let errData = withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: errHandle.readDataToEndOfFile())
            }
        }

        let timedOut = await exit.wait(timeout: timeout)
        if timedOut {
            process.terminate()
            try? await Task.sleep(for: .milliseconds(250))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw InstallError.runnerFailed(
                "Timed out after \(Int(ProcessExitWaiter.seconds(timeout)))s waiting for the administrator prompt.")
        }
        let stderr = await errData
        guard process.terminationStatus != 0 else { return }
        throw InstallError.runnerFailed(Self.failureMessage(
            terminationStatus: process.terminationStatus,
            stderr: String(decoding: stderr, as: UTF8.self)))
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
    /// Status probes must finish promptly; a stuck probe must not stall the menu.
    static let statusTimeout: Duration = .seconds(10)
    /// Commands that can block on a system authorization dialog or a slow keychain sweep.
    static let dialogTimeout: Duration = .seconds(300)

    private let caPEMURL: URL
    private let caCommonName: String
    private let runner: PrivilegedRunner
    private let commandRunner: CommandRunning
    private let hostsPath: String
    /// Optional so every existing test/behavior keeps the legacy osascript path; when both are
    /// present the hosts edit goes through the approved root helper instead (no password).
    private let hostsEditor: HostsEditing?
    private let helper: HelperRegistering?

    public init(
        caPEMURL: URL,
        caCommonName: String = "OpenProxy Local CA",
        runner: PrivilegedRunner,
        commandRunner: CommandRunning,
        hostsPath: String = "/etc/hosts",
        hostsEditor: HostsEditing? = nil,
        helper: HelperRegistering? = nil
    ) {
        self.caPEMURL = caPEMURL
        self.caCommonName = caCommonName
        self.runner = runner
        self.commandRunner = commandRunner
        self.hostsPath = hostsPath
        self.hostsEditor = hostsEditor
        self.helper = helper
    }

    /// Phase 1 trusts the CA in the user's login keychain (user-domain trust, no `-d`) and
    /// verifies it; phase 2 adds the hosts entry. Fail closed: a trust failure throws before
    /// any hosts edit, so a client is never routed to a proxy it cannot trust.
    ///
    /// Returns non-fatal warnings: the install itself succeeded, but a best-effort follow-up
    /// (pointing `NODE_EXTRA_CA_CERTS` at the CA for Node clients) did not. Callers show them
    /// in the menu instead of failing the install.
    @discardableResult
    public func install() async throws -> [String] {
        let trustedCopy = try privateCopyOfCA()
        defer { try? FileManager.default.removeItem(at: trustedCopy.deletingLastPathComponent()) }

        // Verify first: an already-trusted CA must not reopen the Certificate Trust Settings
        // dialog, and a successful verify is itself the proof that trust is in place. Only an
        // untrusted CA runs `add-trusted-cert` (which shows the dialog), then verifies again.
        let alreadyTrusted = await commandRunner.run(
            Self.verifyTrustCommand(certPath: trustedCopy.path), timeout: Self.dialogTimeout)
        if !alreadyTrusted.succeeded {
            let add = await commandRunner.run(
                Self.addTrustCommand(certPath: trustedCopy.path), timeout: Self.dialogTimeout)
            guard add.succeeded else {
                throw InstallError.runnerFailed(Self.trustFailureMessage(add))
            }
            let verify = await commandRunner.run(
                Self.verifyTrustCommand(certPath: trustedCopy.path), timeout: Self.dialogTimeout)
            guard verify.succeeded else {
                throw InstallError.runnerFailed(
                    "The CA was added to the login keychain but could not be verified as trusted: "
                        + verify.failureDetail)
            }
        }

        // Phase 2: the hosts entry, through the approved root helper when it is available
        // (no password), otherwise the legacy osascript script.
        try await setHostsEntry(present: true)

        // Trust and hosts are in place; finally point new processes at the CA so Node clients
        // started afterwards trust it. Unprivileged and non-fatal: a failure never rolls back
        // the working routes above, it only surfaces as a warning.
        do {
            try await applyNodeCAEnv()
            return []
        } catch {
            return ["Could not set NODE_EXTRA_CA_CERTS: \(error)."]
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

    /// Item 6: `remove-trusted-cert` on a certificate that has no trust settings at all (an
    /// install that failed at the trust phase, or a rotated CA) exits non-zero with this exact
    /// Security.framework message. That is "already not trusted" — a success for cleanup —
    /// not a leftover-trust warning. Verified against a throwaway keychain.
    static func isAlreadyNotTrusted(_ result: CommandResult) -> Bool {
        let text = (result.standardError + "\n" + result.standardOutput).lowercased()
        return text.contains("the specified item could not be found in the keychain")
    }

    /// Command output can be huge; cap what reaches the menu.
    static func capped(_ text: String, limit: Int = 500) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// Adds or removes the managed `/etc/hosts` line. This is the one place the app edits
    /// hosts, shared by install/uninstall, the launch-time silent restore, and Quit.
    ///
    /// Route: an `enabled` helper edits without a password; `notRegistered` registers first
    /// and re-reads the status; `requiresApproval` opens Login Items and throws (never
    /// silently falls back to a password prompt); `notFound`/unknown use the legacy osascript
    /// path. An `enabled` helper that fails is surfaced, never downgraded to osascript.
    public func setHostsEntry(present: Bool) async throws {
        switch try resolveHostsRoute() {
        case .helper:
            guard let hostsEditor else {
                try await runHostsScript(present: present)
                return
            }
            do {
                try await hostsEditor.setHostsEntry(present: present)
            } catch {
                throw InstallError.runnerFailed(String(describing: error))
            }
        case .osascript:
            try await runHostsScript(present: present)
        }
    }

    private enum HostsRoute {
        case helper
        case osascript
    }

    private func resolveHostsRoute() throws -> HostsRoute {
        guard let helper else { return .osascript }
        switch helper.status {
        case .enabled:
            return .helper
        case .notRegistered:
            do {
                try helper.register()
            } catch {
                throw InstallError.runnerFailed("Could not register the OpenProxy helper: \(error).")
            }
            // Re-read after registering: it may be enabled or need the one-time approval.
            switch helper.status {
            case .enabled:
                return .helper
            case .requiresApproval:
                helper.openApprovalSettings()
                throw InstallError.runnerFailed(Self.approvalMessage)
            default:
                return .osascript
            }
        case .requiresApproval:
            helper.openApprovalSettings()
            throw InstallError.runnerFailed(Self.approvalMessage)
        case .notFound, .unknown:
            return .osascript
        }
    }

    /// The one-time approval is a user action, so the error tells them exactly what to do.
    static let approvalMessage =
        "OpenProxy needs one-time approval to change /etc/hosts without a password. "
        + "Open System Settings -> Login Items, turn on OpenProxy, then press Install again."

    /// The legacy privileged edit: one `osascript` shell script, `set -e` at the front so the
    /// trailing flush can never mask an earlier hosts failure.
    private func runHostsScript(present: Bool) async throws {
        let script = """
        set -e
        \(Self.hostsEditScript(hostsPath: hostsPath, adding: present))
        dscacheutil -flushcache
        """
        do {
            try await runner.run(script: script)
        } catch {
            throw InstallError.runnerFailed(String(describing: error))
        }
    }

    /// Removes only the `/etc/hosts` entry, leaving the CA in place. No keychain command runs
    /// and, when the helper is enabled, no password prompt appears.
    public func uninstall() async throws {
        try await setHostsEntry(present: false)
    }

    /// Phase A (privileged) restores `/etc/hosts` first — the critical safety path — then
    /// best-effort clears any admin trust settings an old `add-trusted-cert -d` install left,
    /// and sweeps a leftover CA from the System keychain; phase B (unprivileged) removes the
    /// user-domain trust and the login-keychain certificate. Hosts restore must never be
    /// blocked by the sweeps, and a leftover cleanup failure must be reported, not swallowed.
    /// Finally the root helper is unregistered: without the CA it has nothing left to do.
    public func removeCA() async throws {
        // Item 3 / TOCTOU: never point the privileged `remove-trusted-cert -d` at the
        // user-writable ca.pem. Validate the file against the CA's own SHA-256 fingerprint,
        // then drop admin trust for a root-owned copy, so a swap before the admin prompt
        // cannot make root untrust some other certificate.
        let fingerprint = (try? String(contentsOf: caPEMURL, encoding: .utf8))
            .flatMap(Self.sha256Fingerprint(ofPEM:))
        let script = """
        set -e
        \(Self.hostsEditScript(hostsPath: hostsPath, adding: false))
        \(Self.removeAdminTrustScript(caPEMURL: caPEMURL, expectedFingerprint: fingerprint))
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
        try? helper?.unregister()
    }

    /// Drops admin-domain trust that an older `add-trusted-cert -d` install left. The privileged
    /// script copies the user-writable `ca.pem` into a root-owned temp file and only uses it
    /// when its SHA-256 fingerprint matches the one the app embedded, so a swap between the
    /// admin prompt and this step cannot make root untrust another certificate (item 3).
    static func removeAdminTrustScript(caPEMURL: URL, expectedFingerprint: String?) -> String {
        // No fingerprint (missing/invalid ca.pem) means we cannot validate the copy: skip the
        // admin-domain step rather than hand root a file we cannot vouch for.
        guard let expectedFingerprint else { return "true" }
        return """
        ca_copy=$(mktemp "${TMPDIR:-/tmp}/openproxy-ca-admin.XXXXXX")
        if cp \(quoted(caPEMURL.path)) "$ca_copy" 2>/dev/null \\
           && [ "$(openssl x509 -in "$ca_copy" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//;s/://g' | tr 'A-F' 'a-f')" = \(quoted(expectedFingerprint)) ]; then
            chmod 600 "$ca_copy"
            security remove-trusted-cert -d "$ca_copy" || true
        fi
        rm -f "$ca_copy"
        """
    }

    /// Best-effort, unprivileged cleanup of the user-domain trust and the login-keychain
    /// certificate. The hosts entry is the safety-critical half and is already gone, so
    /// failures are collected and reported rather than thrown here. `remove-trusted-cert`
    /// reads the file, so it runs before anything else.
    private func removeUserDomainTrust() async -> String? {
        var failures: [String] = []
        let removeTrust = await commandRunner.run(
            "security remove-trusted-cert \(Self.quoted(caPEMURL.path))", timeout: Self.dialogTimeout)
        if !removeTrust.succeeded && !Self.isAlreadyNotTrusted(removeTrust) {
            failures.append("per-user trust: \(removeTrust.failureDetail)")
        }
        let deleteCerts = await commandRunner.run(Self.deleteCertificatesScript(
            commonName: caCommonName,
            keychain: "\"$HOME/Library/Keychains/login.keychain-db\"",
            removeTrustSettings: true), timeout: Self.dialogTimeout)
        if !deleteCerts.succeeded {
            failures.append("login-keychain certificate: \(deleteCerts.failureDetail)")
        }
        // Install writes NODE_EXTRA_CA_CERTS into the launchd environment, so every process
        // started until logout keeps trusting the (about to be removed) CA. Clear it, but only
        // when it still points at our ca.pem. Best effort.
        let nodeEnv = await commandRunner.run("launchctl getenv NODE_EXTRA_CA_CERTS", timeout: Self.statusTimeout)
        if nodeEnv.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == caPEMURL.path {
            let unset = await commandRunner.run("launchctl unsetenv NODE_EXTRA_CA_CERTS", timeout: Self.statusTimeout)
            if !unset.succeeded {
                failures.append("NODE_EXTRA_CA_CERTS: \(unset.failureDetail)")
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    /// Deletes every certificate whose subject common name is exactly ours, by its SHA-1 hash.
    /// `security delete-certificate -c <CN>` fails with "ambiguous" when two CAs share the CN —
    /// the normal reinstall case — and `find-certificate -c` is only a substring match, so a
    /// decoy "OpenProxy Local CA Extra" would be swept too. So each candidate hash is validated
    /// (`^[0-9A-Fa-f]{40}$`) and its subject confirmed exactly with openssl before deletion.
    /// Best-effort (`|| true`): a keychain without our cert must not fail the caller. On the
    /// login keychain `removeTrustSettings` adds `-t` so the per-user trust settings are
    /// removed with the certificate, not orphaned.
    static func deleteCertificatesScript(commonName: String, keychain: String, removeTrustSettings: Bool = false) -> String {
        let trustFlag = removeTrustSettings ? "-t " : ""
        return """
        sweep_dir=$(mktemp -d "${TMPDIR:-/tmp}/openproxy-sweep.XXXXXX")
        security find-certificate -a -Z -c \(quoted(commonName)) -p \(keychain) 2>/dev/null \
        | awk -v cn=\(quoted(commonName)) -v dir="$sweep_dir" '
          /^SHA-1 hash:/ { h = $NF; next }
          /^-----BEGIN CERTIFICATE-----/ { pem = $0 "\\n"; inblock = 1; next }
          inblock { pem = pem $0 "\\n" }
          /^-----END CERTIFICATE-----/ {
            inblock = 0
            if (h ~ /^[0-9A-Fa-f]{40}$/) {
              f = dir "/" h ".pem"
              printf "%s", pem > f; close(f)
              cmd = "openssl x509 -in " f " -noout -subject -nameopt RFC2253 2>/dev/null"
              if ((cmd | getline s) > 0) { sub(/^subject=/, "", s); if (s == "CN=" cn) print h }
              close(cmd)
            }
            pem = ""
          }
          ' \
        | while read -r hash; do
            security delete-certificate \(trustFlag)-Z "$hash" \(keychain) || true
          done
        rm -rf "$sweep_dir"
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
        let trust = await commandRunner.run(
            Self.verifyTrustCommand(certPath: caPEMURL.path), timeout: Self.statusTimeout)
        let loginFind = await commandRunner.run(
            "security find-certificate -c \(Self.quoted(caCommonName)) \"$HOME/Library/Keychains/login.keychain-db\"",
            timeout: Self.statusTimeout)
        let systemFind = await commandRunner.run(
            "security find-certificate -c \(Self.quoted(caCommonName)) /Library/Keychains/System.keychain",
            timeout: Self.statusTimeout)
        let port = await commandRunner.run("nc -z -G 1 127.0.0.1 443", timeout: Self.statusTimeout)
        let nodeEnv = await commandRunner.run("launchctl getenv NODE_EXTRA_CA_CERTS", timeout: Self.statusTimeout)
        return InstallStatus(
            caTrusted: trust.succeeded,
            caPresent: loginFind.succeeded || systemFind.succeeded,
            hostsEntry: HostsFile.isPresent(in: Self.readHosts(hostsPath)),
            portListening: port.succeeded,
            nodeCAEnv: !nodeEnv.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    /// Points new processes at the CA for Node clients. Unprivileged, so toggling it never prompts.
    public func applyNodeCAEnv() async throws {
        let command = Self.nodeCAEnvCommand(caPEMURL: caPEMURL)
        let result = await commandRunner.run(command, timeout: Self.statusTimeout)
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
