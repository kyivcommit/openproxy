import Foundation
import Testing

@testable import OpenProxyCore

@Suite("HostsFile")
struct HostsFileTests {
    private let entry = "127.0.0.1 openrouter.ai # openproxy"

    @Test func addsEntryWhenMissing() {
        let text = "127.0.0.1 localhost\n"
        let result = HostsFile.adding(to: text)
        #expect(result == "127.0.0.1 localhost\n\(entry)\n")
    }

    @Test func addsEntryWhenFileLacksTrailingNewline() {
        // Review Focus: /etc/hosts lacks a trailing newline must still be a valid, separate line.
        let text = "127.0.0.1 localhost"
        let result = HostsFile.adding(to: text)
        #expect(result == "127.0.0.1 localhost\n\(entry)\n")
        #expect(!result.contains("localhost\(entry)"))
    }

    @Test func addsEntryToEmptyFile() {
        #expect(HostsFile.adding(to: "") == "\(entry)\n")
    }

    @Test func addIsIdempotent() {
        let once = HostsFile.adding(to: "127.0.0.1 localhost\n")
        let twice = HostsFile.adding(to: once)
        #expect(twice == once)
    }

    @Test func removingDeletesOnlyMarkedLine() {
        let text = """
        ##
        # Host Database
        #
        127.0.0.1 localhost
        255.255.255.255 broadcasthost
        ::1             localhost
        \(entry)

        """
        let result = HostsFile.removing(from: text)
        #expect(!result.contains(entry))
        #expect(result == """
        ##
        # Host Database
        #
        127.0.0.1 localhost
        255.255.255.255 broadcasthost
        ::1             localhost

        """)
    }

    @Test func removingIsIdempotentAndKeepsUnmarkedText() {
        let text = "# comment\n\(entry)\n127.0.0.1 localhost\n"
        let once = HostsFile.removing(from: text)
        #expect(once == "# comment\n127.0.0.1 localhost\n")
        #expect(HostsFile.removing(from: once) == once)
    }

    @Test func isPresentIgnoresMentionsWithoutMarker() {
        #expect(!HostsFile.isPresent(in: "127.0.0.1 openrouter.ai\n"))
        #expect(!HostsFile.isPresent(in: "# openrouter.ai is proxied\n"))
        #expect(HostsFile.isPresent(in: "127.0.0.1 openrouter.ai # openproxy\n"))
    }

    @Test func isPresentRejectsUnrelatedMarkerComment() {
        // Finding (c): only the exact managed line counts; a stray marker comment must never
        // be treated as ours (and so must never be deleted by `removing`).
        #expect(!HostsFile.isPresent(in: "# openproxy\n"))
        #expect(!HostsFile.isPresent(in: "# openproxy is our marker\n"))
        #expect(!HostsFile.isPresent(in: "127.0.0.1 openrouter.ai # openproxy-backup\n"))
        #expect(!HostsFile.isPresent(in: "10.0.0.1 openrouter.ai # openproxy\n"))
    }

    @Test func isPresentMatchesWhitespaceTolerantManagedLine() {
        #expect(HostsFile.isPresent(in: "  127.0.0.1\topenrouter.ai   #  openproxy  \n"))
    }

    @Test func removingKeepsUnrelatedMarkerComment() {
        let text = "# openproxy is our marker\n127.0.0.1 localhost\n"
        #expect(HostsFile.removing(from: text) == text)
    }

    @Test func addThenRemoveRoundTrips() {
        let text = "127.0.0.1 localhost\n"
        #expect(HostsFile.removing(from: HostsFile.adding(to: text)) == text)
    }
}
