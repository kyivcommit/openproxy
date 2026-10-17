import Foundation
import Testing

@testable import OpenProxyCore

/// The helper's DNS flush must never delay the XPC reply: real child processes are used here
/// so the termination handler, the hard timeout and the kill are exercised, not just the code.
@Suite("DNSCacheFlusher")
struct DNSCacheFlusherTests {
    @Test func promptChildReportsItsExit() {
        let outcome = DNSCacheFlusher.flush(executablePath: "/usr/bin/true")
        #expect(outcome == .exited(0))
    }

    @Test func nonZeroExitIsReportedNotSwallowed() {
        #expect(DNSCacheFlusher.flush(executablePath: "/usr/bin/false") == .exited(1))
    }

    @Test func stuckChildIsKilledWithinTheBoundAndNeverThrows() {
        // The observed hang was an unbounded wait on a child; the flush is best effort and
        // must return shortly after its timeout, whatever the child does.
        let started = Date()
        let outcome = DNSCacheFlusher.flush(
            executablePath: "/bin/sleep", arguments: ["30"], timeout: .seconds(1))
        let elapsed = Date().timeIntervalSince(started)

        #expect(outcome == .timedOut)
        #expect(elapsed < 2.5, "a 1 s flush timeout must not wait for the child")
    }

    @Test func missingExecutableDoesNotThrow() {
        let outcome = DNSCacheFlusher.flush(
            executablePath: "/nonexistent/openproxy-no-such-binary", timeout: .seconds(1))
        guard case .failedToLaunch = outcome else {
            Issue.record("expected failedToLaunch, got \(outcome)")
            return
        }
    }
}
