import Foundation
import CryptoKit

/// Only confirmed identifiers leave the Mac. No review titles, messages, or tool data.
func internalReviewExclusionEvents(ids: Set<String>) -> [(id: String, body: Data)] {
    let valid = ids.filter { UUID(uuidString: $0) != nil }.map { $0.lowercased() }.sorted()
    return stride(from: 0, to: valid.count, by: 100).compactMap { offset in
        let batch = Array(valid[offset..<min(offset + 100, valid.count)])
        let hash = SHA256.hash(data: Data(batch.joined(separator: ",").utf8)).map { String(format: "%02x", $0) }.joined()
        let id = "codex-exclusion-\(hash.prefix(32))"
        let event: [String: Any] = [
            "sessionId": "internal-reviews", "eventId": id, "eventType": "local/threads/excluded",
            "title": "Codex internal reviews", "status": "stale", "excludedThreadIds": batch
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: event) else { return nil }
        return (id, body)
    }
}
