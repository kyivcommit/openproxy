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

/// The production editor: a privileged XPC connection to the approved launch daemon. The
/// connection is kept open for the app's lifetime: the helper treats its invalidation as the
/// app being gone and removes the managed hosts line, so a crashed app cannot leave clients
/// routed to a dead proxy. Bounded by `timeout` so an unresponsive helper cannot hang
/// Install/Uninstall/Quit.
public final class XPCHostsEditor: HostsEditing, HelperSessionKeeping, @unchecked Sendable {
    public let timeout: Duration

    private let lock = NSLock()
    private var connection: ConnectionHandle?
    /// Incremented for every connection so an old invalidation handler cannot clear a newer
    /// connection that was created after a timeout.
    private var generation = 0
    private var started = false
    private var sessionConnected = false
    private var sessionObserver: (@Sendable (HelperSessionEvent) -> Void)?
    private var reconnectTask: Task<Void, Never>?

    public init(timeout: Duration = .seconds(5)) {
        self.timeout = timeout
    }

    // MARK: - HelperSessionKeeping

    public func start() {
        let needsConnection = lock.withLock { () -> Bool in
            started = true
            return connection == nil && reconnectTask == nil
        }
        if needsConnection {
            connect()
        }
    }

    public func stop() {
        let current: ConnectionHandle? = lock.withLock {
            started = false
            reconnectTask?.cancel()
            reconnectTask = nil
            let current = connection
            connection = nil
            generation += 1
            return current
        }
        current?.connection.invalidate()
        markSessionDisconnected()
    }

    public func observe(_ handler: @escaping @Sendable (HelperSessionEvent) -> Void) {
        lock.withLock { sessionObserver = handler }
    }

    public var isSessionReady: Bool { lock.withLock { sessionConnected } }

    // MARK: - HostsEditing

    public func setHostsEntry(present: Bool) async throws {
        try await call { helper, gate in
            helper.setHostsEntry(present: present) { error in
                if let error { gate.fail(HostsEditingError.helperFailed(error)) }
                else { gate.succeed() }
            }
        }
        markSessionConnected()
    }

    // MARK: - Connection lifecycle

    /// Creates the connection and forces it open with `beginSession`. `NSXPCConnection` is
    /// lazy: without a message the helper never sees the session and its boot-time cleanup
    /// would remove the route while the app is running.
    private func connect() {
        guard lock.withLock({ started }) else { return }
        let connection = connectionOrCreate()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.call(on: connection) { helper, gate in
                    helper.beginSession { error in
                        if let error { gate.fail(HostsEditingError.helperFailed(error)) }
                        else { gate.succeed() }
                    }
                }
                // Stop may have won the race while beginSession was in flight. Do not
                // re-create a session after the app said stop.
                guard self.lock.withLock({ self.started }) else { return }
                self.markSessionConnected(requireStarted: true)
            } catch {
                self.discard(connection)
                self.scheduleReconnect()
            }
        }
    }

    private func connectionOrCreate() -> ConnectionHandle {
        lock.withLock {
            if let connection { return connection }
            let newConnection = NSXPCConnection(
                machServiceName: HelperConstants.machServiceName, options: .privileged)
            newConnection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            generation += 1
            let generation = generation
            newConnection.invalidationHandler = { [weak self] in
                guard let self else { return }
                let wasCurrent = self.lock.withLock { () -> Bool in
                    guard self.generation == generation else { return false }
                    self.connection = nil
                    return true
                }
                // A stale connection going away says nothing about the live session.
                if wasCurrent { self.markSessionDisconnected() }
                if self.lock.withLock({ self.started }) {
                    self.scheduleReconnect()
                }
            }
            newConnection.resume()
            let handle = ConnectionHandle(newConnection)
            connection = handle
            return handle
        }
    }

    private func call(
        _ body: @escaping (HelperProtocol, ReplyGate) -> Void
    ) async throws {
        try await call(on: nil, body)
    }

    private func call(
        on connection: ConnectionHandle?,
        _ body: @escaping (HelperProtocol, ReplyGate) -> Void
    ) async throws {
        let connection = connection ?? connectionOrCreate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let gate = ReplyGate(continuation)
            let proxy = connection.connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                self?.discard(connection)
                gate.fail(HostsEditingError.connectionFailed(String(describing: error)))
            }
            guard let helper = proxy as? HelperProtocol else {
                gate.fail(HostsEditingError.connectionFailed("the helper interface is unavailable"))
                return
            }
            body(helper, gate)
            Task {
                try? await Task.sleep(for: timeout)
                guard !gate.isFinished else { return }
                self.discard(connection)
                gate.fail(HostsEditingError.timedOut)
            }
        }
    }

    /// Drops a connection after an error/timeout so the next call creates a fresh one. The
    /// helper sees the invalidation and treats it as the app being gone.
    private func discard(_ connection: ConnectionHandle) {
        let shouldInvalidate = lock.withLock { () -> Bool in
            guard self.connection === connection else { return false }
            self.connection = nil
            generation += 1
            return true
        }
        guard shouldInvalidate else { return }
        connection.connection.invalidate()
        markSessionDisconnected()
        scheduleReconnect()
    }

    /// Notifies the observer outside the lock, only when the state actually changed, so a
    /// burst of failures cannot flood the main actor with duplicate transitions.
    private func markSessionConnected(requireStarted: Bool = false) {
        let observer = lock.withLock { () -> (@Sendable (HelperSessionEvent) -> Void)? in
            if requireStarted && !started { return nil }
            guard !sessionConnected else { return nil }
            sessionConnected = true
            return sessionObserver
        }
        observer?(.connected)
    }

    private func markSessionDisconnected() {
        let observer = lock.withLock { () -> (@Sendable (HelperSessionEvent) -> Void)? in
            guard sessionConnected else { return nil }
            sessionConnected = false
            return sessionObserver
        }
        observer?(.disconnected)
    }

    private func scheduleReconnect() {
        lock.withLock {
            guard started, reconnectTask == nil else { return }
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.lock.withLock { self.reconnectTask = nil }
                guard self.lock.withLock({ self.started }) else { return }
                self.connect()
            }
        }
    }
}

/// Wraps the non-Sendable XPC connection so it can cross into the timeout task. Every access
/// goes through this handle; `NSXPCConnection` is safe to message from multiple threads.
private final class ConnectionHandle: @unchecked Sendable {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
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

    var isFinished: Bool { lock.withLock { finished } }

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
