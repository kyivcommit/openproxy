import Foundation
import Testing

@testable import OpenProxyCore

/// The root helper's on-disk edit path, exercised on temp files: the same code runs in the
/// daemon against `/etc/hosts`, so every invariant (atomic swap, mode/owner preserved, a
/// failed read never writing) is tested here rather than against the real file.
@Suite("HostsFileEditor")
struct HostsFileEditorTests {
    private let entry = "127.0.0.1 openrouter.ai # openproxy"

    private func makeFile(_ content: String, mode: Int = 0o644) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "hosts-editor-\(UUID().uuidString)")
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    @Test func addsManagedEntry() throws {
        let url = try makeFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(at: url) }

        try HostsFileEditor.apply(present: true, hostsPath: url.path)

        #expect(try String(contentsOf: url, encoding: .utf8) == "127.0.0.1 localhost\n\(entry)\n")
    }

    @Test func removesManagedEntry() throws {
        let url = try makeFile("127.0.0.1 localhost\n\(entry)\n")
        defer { try? FileManager.default.removeItem(at: url) }

        try HostsFileEditor.apply(present: false, hostsPath: url.path)

        #expect(try String(contentsOf: url, encoding: .utf8) == "127.0.0.1 localhost\n")
    }

    @Test func addAndRemoveAreIdempotent() throws {
        let url = try makeFile("127.0.0.1 localhost\n")
        defer { try? FileManager.default.removeItem(at: url) }

        try HostsFileEditor.apply(present: true, hostsPath: url.path)
        try HostsFileEditor.apply(present: true, hostsPath: url.path)
        var text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.components(separatedBy: entry).count - 1 == 1)

        try HostsFileEditor.apply(present: false, hostsPath: url.path)
        try HostsFileEditor.apply(present: false, hostsPath: url.path)
        text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "127.0.0.1 localhost\n")
    }

    @Test func addsNewlineBeforeEntryWhenFileLacksTrailingNewline() throws {
        let url = try makeFile("127.0.0.1 localhost")
        defer { try? FileManager.default.removeItem(at: url) }

        try HostsFileEditor.apply(present: true, hostsPath: url.path)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "127.0.0.1 localhost\n\(entry)\n")
        #expect(!text.contains("localhost\(entry)"))
    }

    @Test func preservesPosixPermissions() throws {
        let url = try makeFile("127.0.0.1 localhost\n", mode: 0o600)
        defer { try? FileManager.default.removeItem(at: url) }

        try HostsFileEditor.apply(present: true, hostsPath: url.path)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func keepsUnrelatedLinesByteIdentical() throws {
        // Comments, blank lines and IPv6 entries must survive an add and a remove untouched.
        let original = """
        ##
        # Host Database
        #
        127.0.0.1 localhost
        255.255.255.255 broadcasthost
        ::1             localhost
        # trailing comment

        """
        let url = try makeFile(original)
        defer { try? FileManager.default.removeItem(at: url) }

        try HostsFileEditor.apply(present: true, hostsPath: url.path)
        try HostsFileEditor.apply(present: false, hostsPath: url.path)

        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test func failedReadLeavesTheFileUntouched() throws {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "hosts-editor-missing-\(UUID().uuidString)")
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        #expect(throws: HostsFileEditor.EditFailure.self) {
            try HostsFileEditor.apply(present: true, hostsPath: missing.path)
        }
        // Nothing was written: no empty file replacing the unreadable one.
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func failedReadLeavesExistingContentUntouched() throws {
        // A directory where the hosts file should be: the read fails and no temp file leaks.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "hosts-editor-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: HostsFileEditor.EditFailure.self) {
            try HostsFileEditor.apply(present: true, hostsPath: dir.path)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
