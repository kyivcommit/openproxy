import Foundation
import Crypto

/// Runs a shell script with administrator privileges. Injected so tests can record
/// the script without triggering the real macOS authorization dialog.
public protocol PrivilegedRunner: Sendable {
    func run(script: String) async throws
}

/// The production runner: `osascript -e 'do shell script … with administrator privileges'`
/// produces the single system authorization prompt for all privileged steps.
public struct OsascriptRunner: PrivilegedRunner {
    public init() {}

    public func run(script: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.appleScript(forShellScript: script)]
        do {
            try process.run()
        } catch {
            throw InstallError.runnerFailed(String(describing: error))
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            // The user cancelling the admin dialog also lands here; the UI reports the refusal.
            throw InstallError.runnerFailed("osascript exited with status \(process.terminationStatus)")
        }
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
    public var caTrusted: Bool
    public var hostsEntry: Bool
    public var portListening: Bool
    public var nodeCAEnv: Bool

    public init(caTrusted: Bool, hostsEntry: Bool, portListening: Bool, nodeCAEnv: Bool) {
        self.caTrusted = caTrusted
        self.hostsEntry = hostsEntry
        self.portListening = portListening
        self.nodeCAEnv = nodeCAEnv
    }
}

public enum InstallError: Error, Equatable, Sendable {
    case runnerFailed(String)
    case commandFailed(command: String, status: Int32)
}

/// Installs the CA into the System keychain and the hosts entry for `openrouter.ai`.
/// All privileged steps run inside a single admin script so the user sees one prompt.
public final class Installer: @unchecked Sendable {
    private let caPEMURL: URL
    private let caCommonName: String
    private let runner: PrivilegedRunner
    private let hostsPath: String

    public init(
        caPEMURL: URL,
        caCommonName: String = "OpenProxy Local CA",
        runner: PrivilegedRunner,
        hostsPath: String = "/etc/hosts"
    ) {
        self.caPEMURL = caPEMURL
        self.caCommonName = caCommonName
        self.runner = runner
        self.hostsPath = hostsPath
    }

    public func install() async throws {
        // The unprivileged app computes the expected digest; the privileged script re-derives it
        // from a root-owned copy before trusting it, so a swapped `ca.pem` (TOCTOU) can never be
        // trusted. An unreadable/malformed CA yields no expected value and the script fails closed.
        let expected = (try? String(contentsOf: caPEMURL, encoding: .utf8))
            .flatMap(Self.sha256Fingerprint(ofPEM:)) ?? ""
        // `set -e` aborts at the first failed step, so the trailing flushcache can no longer
        // mask an earlier security/hosts failure; the script reports success only if all ran.
        let script = """
        set -e
        ca=\(Self.quoted(caPEMURL.path))
        expected=\(Self.quoted(expected))
        tmpca=$(mktemp /tmp/openproxy-ca.XXXXXX)
        trap 'rm -f "$tmpca"' EXIT
        cp "$ca" "$tmpca"
        chmod 400 "$tmpca"
        actual=$(openssl x509 -in "$tmpca" -noout -fingerprint -sha256 | sed 's/.*=//' | tr -d ':' | tr 'A-Z' 'a-z')
        if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
            echo "openproxy: CA certificate missing or changed; refusing to install" >&2
            exit 1
        fi
        security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$tmpca"
        \(Self.hostsEditScript(hostsPath: hostsPath, adding: true))
        trap 'rm -f "$tmpca" "$tmp"' EXIT
        dscacheutil -flushcache
        """
        do {
            try await runner.run(script: script)
        } catch {
            throw InstallError.runnerFailed(String(describing: error))
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

    public func uninstall() async throws {
        let script = """
        set -e
        \(Self.hostsEditScript(hostsPath: hostsPath, adding: false))
        \(Self.deleteCertificatesScript(commonName: caCommonName))
        dscacheutil -flushcache
        """
        do {
            try await runner.run(script: script)
        } catch {
            throw InstallError.runnerFailed(String(describing: error))
        }
    }

    /// Deletes every certificate with our common name by its SHA-1 hash. `security
    /// delete-certificate -c <CN>` fails with "ambiguous" when two CAs share the CN — the
    /// normal reinstall case — so each match returned by `find-certificate` is deleted by hash.
    static func deleteCertificatesScript(commonName: String) -> String {
        """
        hashes=$(security find-certificate -a -Z -c \(quoted(commonName)) /Library/Keychains/System.keychain 2>/dev/null | awk '/SHA-1 hash:/ { print $NF }')
        for hash in $hashes; do
            security delete-certificate -Z "$hash" /Library/Keychains/System.keychain
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
        InstallStatus(
            caTrusted: Self.shell("security find-certificate -c \(Self.quoted(caCommonName)) /Library/Keychains/System.keychain").status == 0,
            hostsEntry: HostsFile.isPresent(in: Self.readHosts(hostsPath)),
            portListening: Self.shell("nc -z -G 1 127.0.0.1 443").status == 0,
            nodeCAEnv: !Self.shell("launchctl getenv NODE_EXTRA_CA_CERTS").output
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    /// Points new processes at the CA for Node clients. Unprivileged, so toggling it never prompts.
    public func applyNodeCAEnv() throws {
        let command = Self.nodeCAEnvCommand(caPEMURL: caPEMURL)
        let status = Self.shell(command).status
        guard status == 0 else {
            throw InstallError.commandFailed(command: command, status: status)
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

    private static func shell(_ command: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

extension Installer {
    public convenience init(ca: CertAuthority, runner: PrivilegedRunner, hostsPath: String = "/etc/hosts") {
        self.init(caPEMURL: ca.caCertificatePEMURL, runner: runner, hostsPath: hostsPath)
    }
}
