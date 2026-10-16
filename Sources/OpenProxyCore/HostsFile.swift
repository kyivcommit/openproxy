import Foundation

/// Pure text edits for `/etc/hosts`. The installer owns the file I/O; this type
/// only computes the new text so the tricky newline and idempotency cases are testable.
public enum HostsFile {
    public static let marker = "# openproxy"
    private static let entry = "127.0.0.1 openrouter.ai \(marker)"

    /// True when some line carries the marker. A bare `openrouter.ai` mention does not count.
    public static func isPresent(in text: String) -> Bool {
        lines(of: text).contains { $0.contains(marker) }
    }

    /// Appends the marked entry as its own line, normalizing a missing trailing newline.
    /// Returns `text` unchanged when the entry is already present.
    public static func adding(to text: String) -> String {
        guard !isPresent(in: text) else { return text }
        let prefix = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        return prefix + entry + "\n"
    }

    /// Drops the marked line; every other line is preserved byte-for-byte.
    public static func removing(from text: String) -> String {
        guard isPresent(in: text) else { return text }
        return lines(of: text).filter { !$0.contains(marker) }.joined(separator: "\n")
    }

    private static func lines(of text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }
}
