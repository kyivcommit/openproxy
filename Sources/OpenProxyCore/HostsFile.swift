import Foundation

/// Pure text edits for `/etc/hosts`. The privileged installer script owns the file I/O;
/// these functions match the same managed line so tests and status agree with it.
public enum HostsFile {
    public static let marker = "# openproxy"
    static let entry = "127.0.0.1 openrouter.ai \(marker)"

    /// ERE (also a valid ICU regex) matching *only* the managed entry, tolerating any
    /// whitespace between fields. Shared with the privileged `grep`/`sed` edit so the two
    /// can never disagree about which line is ours; a stray `# openproxy` comment is not ours.
    static let managedLinePattern =
        "^[[:space:]]*127\\.0\\.0\\.1[[:space:]]+openrouter\\.ai[[:space:]]+#[[:space:]]+openproxy[[:space:]]*$"

    /// True when a line is exactly our managed entry, not merely a line that mentions the marker.
    public static func isPresent(in text: String) -> Bool {
        lines(of: text).contains(where: isManaged)
    }

    /// Appends the marked entry as its own line, normalizing a missing trailing newline.
    /// Returns `text` unchanged when the entry is already present.
    public static func adding(to text: String) -> String {
        guard !isPresent(in: text) else { return text }
        let prefix = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        return prefix + entry + "\n"
    }

    /// Drops the managed line; every other line is preserved byte-for-byte.
    public static func removing(from text: String) -> String {
        guard isPresent(in: text) else { return text }
        return lines(of: text).filter { !isManaged($0) }.joined(separator: "\n")
    }

    private static func isManaged(_ line: Substring) -> Bool {
        line.range(of: managedLinePattern, options: .regularExpression) != nil
    }

    private static func lines(of text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }
}
