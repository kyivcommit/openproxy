import Foundation

/// Applies the hosts edit as the UI/installer needs it: async, and able to fail. Injected so
/// the Installer path is testable without a running daemon.
public protocol HostsEditing: Sendable {
    func setHostsEntry(present: Bool) async throws
}

public enum HostsEditingError: Error, Equatable, Sendable, CustomStringConvertible {
    case connectionFailed(String)
    case helperFailed(String)
    case timedOut

    public var description: String {
        switch self {
        case .connectionFailed(let detail): return "could not reach the root helper: \(detail)"
        case .helperFailed(let detail): return "the root helper could not edit /etc/hosts: \(detail)"
        case .timedOut: return "the root helper did not answer in time"
        }
    }
}

/// The production editor: a privileged XPC connection to the approved launch daemon. Bounded
/// by `timeout` so an unresponsive helper cannot hang Install/Uninstall/Quit.
public final class XPCHostsEditor: HostsEditing {
    public let timeout: Duration

    public init(timeout: Duration = .seconds(5)) {
        self.timeout = timeout
    }

    public func setHostsEntry(present: Bool) async throws {
        let connection = NSXPCConnection(
            machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        defer { connection.invalidate() }
        connection.resume()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let gate = ReplyGate(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                gate.fail(HostsEditingError.connectionFailed(String(describing: error)))
            }
            guard let helper = proxy as? HelperProtocol else {
                gate.fail(HostsEditingError.connectionFailed("the helper interface is unavailable"))
                return
            }
            helper.setHostsEntry(present: present) { error in
                if let error { gate.fail(HostsEditingError.helperFailed(error)) }
                else { gate.succeed() }
            }
            Task {
                try? await Task.sleep(for: timeout)
                gate.fail(HostsEditingError.timedOut)
            }
        }
    }
}

/// Resumes the continuation exactly once: the XPC reply, the error handler and the timeout
/// race, and only the first of them may win.
private final class ReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<Void, any Error>

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func succeed() { finish(.success(())) }
    func fail(_ error: any Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Void, any Error>) {
        let shouldResume = lock.withLock { () -> Bool in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldResume else { return }
        continuation.resume(with: result)
    }
}
