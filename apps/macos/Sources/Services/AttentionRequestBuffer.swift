import Foundation

struct AttentionRequestBuffer {
    private(set) var candidates: [String: PendingAttention] = [:]

    mutating func stage(sessionID: String, attention: PendingAttention) {
        candidates[sessionID] = attention
    }

    mutating func promote(sessionID: String, turnID: String) -> PendingAttention? {
        guard let candidate = candidates[sessionID], candidate.turn == turnID else { return nil }
        candidates.removeValue(forKey: sessionID)
        return candidate
    }

    @discardableResult
    mutating func cancel(sessionID: String, turnID: String, tool: String? = nil) -> PendingAttention? {
        guard let candidate = candidates[sessionID], candidate.turn == turnID,
              tool == nil || candidate.tool == tool else { return nil }
        return candidates.removeValue(forKey: sessionID)
    }

    mutating func cancel(sessionID: String) {
        candidates.removeValue(forKey: sessionID)
    }

    mutating func removeAll() {
        candidates.removeAll()
    }
}
