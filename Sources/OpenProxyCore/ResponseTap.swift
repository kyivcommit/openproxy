import Foundation

/// Facts the stats store wants out of a response body, gathered without ever
/// blocking forwarding.
struct ResponseFacts: Equatable, Sendable {
    var actualTier: String?
    var provider: String?
    /// The concrete model the response served, which an alias request only reveals here.
    var model: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var costUSD: Double?
}

/// A bounded, non-blocking tap over a response body. Non-streaming JSON is
/// buffered up to 1 MiB; SSE is scanned line by line as chunks arrive, keeping
/// only the current partial line. `consume` never awaits, so forwarding is never
/// held up by the tap.
final class ResponseTap: @unchecked Sendable {
    static let maxBufferedBytes = 1024 * 1024

    private let lock = NSLock()
    private let streaming: Bool
    private var buffer = Data()
    private var lineBuffer = Data()
    private var facts = ResponseFacts()

    init(streaming: Bool) { self.streaming = streaming }

    func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if streaming {
            consumeStreaming(chunk)
        } else if buffer.count < Self.maxBufferedBytes {
            buffer.append(contentsOf: chunk.prefix(Self.maxBufferedBytes - buffer.count))
        }
    }

    func finish() -> ResponseFacts {
        lock.lock()
        defer { lock.unlock() }
        if !streaming,
           let object = (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any] {
            merge(Self.facts(from: object))
        }
        return facts
    }

    private func consumeStreaming(_ chunk: Data) {
        lineBuffer.append(chunk)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = Data(lineBuffer[lineBuffer.startIndex..<newline])
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            process(line)
        }
        // A peer that never sends a newline must not grow this without bound.
        if lineBuffer.count > Self.maxBufferedBytes { lineBuffer.removeAll(keepingCapacity: true) }
    }

    private func process(_ line: Data) {
        guard let text = String(data: line, encoding: .utf8) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload.hasPrefix("{"), let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        merge(Self.facts(from: object))
    }

    /// Later non-nil values win, so a final usage chunk overrides the header chunk.
    private func merge(_ new: ResponseFacts) {
        if let value = new.actualTier { facts.actualTier = value }
        if let value = new.provider { facts.provider = value }
        if let value = new.model { facts.model = value }
        if let value = new.promptTokens { facts.promptTokens = value }
        if let value = new.completionTokens { facts.completionTokens = value }
        if let value = new.costUSD { facts.costUSD = value }
    }

    static func facts(from object: [String: Any]) -> ResponseFacts {
        var facts = ResponseFacts()
        facts.actualTier = object["service_tier"] as? String
        let usage = object["usage"] as? [String: Any]
        if facts.actualTier == nil {
            // /api/v1/messages reports the served tier under `usage`.
            facts.actualTier = (usage?["service_tier"] as? String) ?? (usage?["speed"] as? String)
        }
        facts.provider = object["provider"] as? String
        // /api/v1/responses and /api/v1/messages report the served model nested in an event
        // (`response.created`, `message_start`); the top-level field wins when both are present.
        facts.model = (object["model"] as? String)
            ?? ((object["response"] as? [String: Any])?["model"] as? String)
            ?? ((object["message"] as? [String: Any])?["model"] as? String)
        // /api/v1/messages (Anthropic) names these input/output_tokens.
        facts.promptTokens = (usage?["prompt_tokens"] as? Int) ?? (usage?["input_tokens"] as? Int)
        facts.completionTokens = (usage?["completion_tokens"] as? Int) ?? (usage?["output_tokens"] as? Int)
        facts.costUSD = usage?["cost"] as? Double
        return facts
    }
}
