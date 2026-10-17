import Foundation

/// The privileged on-disk half of the `/etc/hosts` edit, shared by the root helper and the
/// tests. It re-reads the file itself (never trusting a caller-supplied snapshot), applies
/// only the managed line, and swaps in a temp file in the same directory so the replace is
/// atomic. A failed read aborts before anything is written, so the real file is never
/// truncated or replaced with empty text.
public enum HostsFileEditor {
    public enum EditFailure: Error, Equatable, CustomStringConvertible, Sendable {
        case readFailed(path: String, reason: String)
        case writeFailed(path: String, reason: String)

        public var description: String {
            switch self {
            case .readFailed(let path, let reason): return "could not read \(path): \(reason)"
            case .writeFailed(let path, let reason): return "could not write \(path): \(reason)"
            }
        }
    }

    /// Applies the managed-line edit at `hostsPath`. Returns immediately when the file is
    /// already in the requested state, so a no-op never rewrites the file.
    public static func apply(present: Bool, hostsPath: String) throws {
        let original: String
        do {
            original = try String(contentsOfFile: hostsPath, encoding: .utf8)
        } catch {
            throw EditFailure.readFailed(path: hostsPath, reason: String(describing: error))
        }
        let updated = present ? HostsFile.adding(to: original) : HostsFile.removing(from: original)
        guard updated != original else { return }

        let manager = FileManager.default
        let attributes = (try? manager.attributesOfItem(atPath: hostsPath)) ?? [:]
        var preserved: [FileAttributeKey: Any] = [.posixPermissions: 0o644]
        if let permissions = attributes[.posixPermissions] { preserved[.posixPermissions] = permissions }
        if let owner = attributes[.ownerAccountID] { preserved[.ownerAccountID] = owner }
        if let group = attributes[.groupOwnerAccountID] { preserved[.groupOwnerAccountID] = group }

        let directory = (hostsPath as NSString).deletingLastPathComponent
        let tempPath = (directory as NSString).appendingPathComponent(".openproxy-hosts-\(UUID().uuidString)")
        do {
            try Data(updated.utf8).write(to: URL(fileURLWithPath: tempPath))
            try manager.setAttributes(preserved, ofItemAtPath: tempPath)
        } catch {
            try? manager.removeItem(atPath: tempPath)
            throw EditFailure.writeFailed(path: hostsPath, reason: String(describing: error))
        }
        // Same-directory rename is atomic: a reader sees either the old or the new file.
        guard rename(tempPath, hostsPath) == 0 else {
            let reason = String(cString: strerror(errno))
            try? manager.removeItem(atPath: tempPath)
            throw EditFailure.writeFailed(path: hostsPath, reason: reason)
        }
    }
}
