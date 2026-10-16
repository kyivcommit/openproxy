import Foundation

/// A response head from the upstream. Only the head is modelled here: the
/// FlexController switches on `status` and abandons a losing attempt via
/// `cancel()` before the body starts streaming.
public protocol FlexResponse: Sendable {
    var status: Int { get }
    func cancel()
}

/// Thrown by a `send` closure when no response head arrived within its timeout.
/// Carries the hook that closes the still-open upstream connection.
public struct FlexTimeout: Error, Sendable {
    private let cancelUpstream: @Sendable () -> Void

    public init(cancelUpstream: @Sendable @escaping () -> Void = {}) {
        self.cancelUpstream = cancelUpstream
    }

    /// Closes the upstream connection of the attempt that timed out.
    public func cancelTimedOutUpstream() { cancelUpstream() }
}

public struct FlexOutcome<R: FlexResponse>: Sendable {
    public var response: R
    public var usedFallback: Bool
    /// Total number of upstream `send` calls that were made, including the
    /// fallback call when `usedFallback` is true.
    public var attempts: Int

    public init(response: R, usedFallback: Bool, attempts: Int) {
        self.response = response
        self.usedFallback = usedFallback
        self.attempts = attempts
    }
}

/// Executes the Flex policy (spec §6): retry capacity failures up to
/// `policy.attempts`, then optionally fall back to a request without
/// `service_tier`. Switching is only possible before the first response byte.
public enum FlexController {
    public static func run<R: FlexResponse>(
        policy: FlexPolicy,
        streaming: Bool,
        flexBody: Data,
        plainBody: Data,
        send: @Sendable (Data, TimeInterval) async throws -> R
    ) async throws -> FlexOutcome<R> {
        let timeout = streaming ? policy.firstByteTimeout : policy.nonStreamingTimeout
        var lastResponse: R?
        var lastTimeout: FlexTimeout?

        for attempt in 1...policy.attempts {
            do {
                let response = try await send(flexBody, timeout)
                // shortcut: capacity is detected by status only (429/503); body-based
                // detection is deferred until OpenRouter's error shapes are pinned down.
                if response.status == 429 || response.status == 503 {
                    if attempt < policy.attempts {
                        response.cancel()
                        continue
                    }
                    lastResponse = response
                } else {
                    return FlexOutcome(response: response, usedFallback: false, attempts: attempt)
                }
            } catch let timedOut as FlexTimeout {
                timedOut.cancelTimedOutUpstream()
                lastTimeout = timedOut
                lastResponse = nil
            }
        }

        if policy.fallback {
            lastResponse?.cancel()
            let response = try await send(plainBody, timeout)
            return FlexOutcome(response: response, usedFallback: true, attempts: policy.attempts + 1)
        }
        if let response = lastResponse {
            return FlexOutcome(response: response, usedFallback: false, attempts: policy.attempts)
        }
        throw lastTimeout ?? FlexTimeout()
    }
}
