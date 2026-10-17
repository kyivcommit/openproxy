import Foundation

/// Bounded, best-effort DNS cache flush for the root helper. The old implementation used
/// `Process.waitUntilExit()`, which hung the helper's XPC reply (the same failure this project
/// hit before, see `ProcessExitWaiter`). This waits on a semaphore signalled by the termination
/// handler, with a hard timeout and a kill, and never throws: a slow or missing `dscacheutil`
/// must never delay the reply or fail the hosts edit.
public enum DNSCacheFlusher {
    public enum Outcome: Equatable, Sendable {
        case exited(Int32)
        case timedOut
        case failedToLaunch(String)
    }

    /// Flushes the DNS cache at `executablePath` (normally `/usr/bin/dscacheutil -flushcache`).
    /// Returns within roughly `timeout` (plus a short SIGKILL grace) on every path.
    @discardableResult
    public static func flush(
        executablePath: String = "/usr/bin/dscacheutil",
        arguments: [String] = ["-flushcache"],
        timeout: Duration = .seconds(3)
    ) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        // The flush has no useful output; discarding it also avoids pipe-buffer deadlocks.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Handler before `run()`: an instant exit must not race past it, and it never spins a
        // run loop on the calling thread (the `waitUntilExit()` hang).
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failedToLaunch(String(describing: error))
        }

        if exited.wait(timeout: .now() + Self.seconds(timeout)) == .timedOut {
            process.terminate()
            // Give SIGTERM a moment, then force it; the reply must not wait on a stuck child.
            _ = exited.wait(timeout: .now() + 0.5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return .timedOut
        }
        return .exited(process.terminationStatus)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
