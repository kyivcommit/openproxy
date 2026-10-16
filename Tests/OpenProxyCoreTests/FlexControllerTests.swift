import Foundation
import Testing

@testable import OpenProxyCore

private final class FakeResponse: FlexResponse, @unchecked Sendable {
    let status: Int
    private let lock = NSLock()
    private var cancelledState = false

    init(status: Int) { self.status = status }

    func cancel() { lock.withLock { cancelledState = true } }
    var cancelled: Bool { lock.withLock { cancelledState } }
}

/// Records every `send` and plays back a fixed script of outcomes.
private final class ScriptedSender: @unchecked Sendable {
    enum Step { case respond(Int), timeout }
    enum ScriptError: Error { case exhausted }

    private let lock = NSLock()
    private var steps: [Step]
    private var _bodies: [Data] = []
    private var _timeouts: [TimeInterval] = []
    private var _responses: [FakeResponse] = []
    private var _timeoutsCancelled = 0

    init(_ steps: [Step]) { self.steps = steps }

    func send(_ body: Data, _ timeout: TimeInterval) async throws -> FakeResponse {
        let step: Step = try lock.withLock {
            _bodies.append(body)
            _timeouts.append(timeout)
            guard !steps.isEmpty else { throw ScriptError.exhausted }
            return steps.removeFirst()
        }
        switch step {
        case .respond(let status):
            let response = FakeResponse(status: status)
            lock.withLock { _responses.append(response) }
            return response
        case .timeout:
            throw FlexTimeout(cancelUpstream: { [self] in
                lock.withLock { _timeoutsCancelled += 1 }
            })
        }
    }

    var bodies: [Data] { lock.withLock { _bodies } }
    var timeouts: [TimeInterval] { lock.withLock { _timeouts } }
    var responses: [FakeResponse] { lock.withLock { _responses } }
    var timeoutsCancelled: Int { lock.withLock { _timeoutsCancelled } }
}

@Suite("FlexController")
struct FlexControllerTests {
    private let flexBody = Data(#"{"model":"x","service_tier":"flex"}"#.utf8)
    private let plainBody = Data(#"{"model":"x"}"#.utf8)

    private func run(
        _ sender: ScriptedSender,
        policy: FlexPolicy = FlexPolicy(),
        streaming: Bool = true
    ) async throws -> FlexOutcome<FakeResponse> {
        try await FlexController.run(
            policy: policy, streaming: streaming,
            flexBody: flexBody, plainBody: plainBody
        ) { body, timeout in
            try await sender.send(body, timeout)
        }
    }

    @Test func successOnFirstAttempt() async throws {
        let sender = ScriptedSender([.respond(200)])
        let outcome = try await run(sender)
        #expect(outcome.attempts == 1)
        #expect(!outcome.usedFallback)
        #expect(outcome.response.status == 200)
        #expect(sender.bodies == [flexBody])
    }

    @Test func retriesOn429ThenSucceeds() async throws {
        let sender = ScriptedSender([.respond(429), .respond(200)])
        let outcome = try await run(sender)
        #expect(outcome.attempts == 2)
        #expect(!outcome.usedFallback)
        #expect(outcome.response.status == 200)
        #expect(sender.bodies.allSatisfy { $0 == flexBody })
        #expect(sender.responses.count == 2)
        #expect(sender.responses[0].cancelled)   // failed capacity attempt is closed
        #expect(!sender.responses[1].cancelled)
    }

    @Test func fallsBackToPlainBodyAfterExhaustingAttempts() async throws {
        let policy = FlexPolicy(fallback: true, attempts: 2)
        let sender = ScriptedSender([.respond(503), .respond(503), .respond(200)])
        let outcome = try await run(sender, policy: policy)
        #expect(outcome.usedFallback)
        #expect(outcome.attempts == 3)
        #expect(outcome.response.status == 200)
        #expect(sender.bodies == [flexBody, flexBody, plainBody])  // final call drops flex
        #expect(sender.responses[0].cancelled)
        #expect(sender.responses[1].cancelled)   // exhausted flex response closed before fallback
    }

    @Test func noFallbackReturnsLastCapacityResponse() async throws {
        let policy = FlexPolicy(fallback: false, attempts: 2)
        let sender = ScriptedSender([.respond(503), .respond(503)])
        let outcome = try await run(sender, policy: policy)
        #expect(!outcome.usedFallback)
        #expect(outcome.attempts == 2)
        #expect(outcome.response.status == 503)
        #expect(sender.bodies == [flexBody, flexBody])  // no plain call
        #expect(!sender.responses[1].cancelled)         // returned to client unchanged
    }

    @Test func timeoutCountsAsFailedAttemptAndCancelsUpstream() async throws {
        let sender = ScriptedSender([.timeout, .respond(200)])
        let outcome = try await run(sender)
        #expect(outcome.attempts == 2)
        #expect(!outcome.usedFallback)
        #expect(outcome.response.status == 200)
        #expect(sender.timeoutsCancelled == 1)
    }

    @Test func timeoutExhaustsThenFallsBack() async throws {
        let policy = FlexPolicy(fallback: true, attempts: 2)
        let sender = ScriptedSender([.timeout, .timeout, .respond(200)])
        let outcome = try await run(sender, policy: policy)
        #expect(outcome.usedFallback)
        #expect(outcome.attempts == 3)
        #expect(sender.timeoutsCancelled == 2)
        #expect(sender.bodies.last == plainBody)
    }

    @Test func timeoutWithFallbackOffThrows() async throws {
        let policy = FlexPolicy(fallback: false, attempts: 1)
        let sender = ScriptedSender([.timeout])
        await #expect(throws: FlexTimeout.self) {
            try await run(sender, policy: policy)
        }
        #expect(sender.timeoutsCancelled == 1)
    }

    @Test func streamingUsesFirstByteTimeout() async throws {
        let policy = FlexPolicy(fallback: true, attempts: 2, firstByteTimeout: 5, nonStreamingTimeout: 99)
        let sender = ScriptedSender([.respond(200)])
        _ = try await run(sender, policy: policy, streaming: true)
        #expect(sender.timeouts == [5])
    }

    @Test func nonStreamingUsesNonStreamingTimeout() async throws {
        let policy = FlexPolicy(fallback: true, attempts: 2, firstByteTimeout: 5, nonStreamingTimeout: 99)
        let sender = ScriptedSender([.respond(200)])
        _ = try await run(sender, policy: policy, streaming: false)
        #expect(sender.timeouts == [99])
    }

    @Test(arguments: [400, 401, 500])
    func nonCapacityErrorReturnedImmediately(status: Int) async throws {
        let sender = ScriptedSender([.respond(status)])
        let outcome = try await run(sender)
        #expect(outcome.attempts == 1)
        #expect(!outcome.usedFallback)
        #expect(outcome.response.status == status)
    }
}
