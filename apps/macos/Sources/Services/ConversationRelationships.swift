import Foundation
import CryptoKit

/// Metadata-only backfill. It never creates a run, event history or notification.
func conversationRelationshipEvents(_ rows: [[String: Any]]) -> [(id: String, body: Data)] {
    let links = rows.compactMap { row -> [String: String]? in
        guard let child = row["id"] as? String, UUID(uuidString: child) != nil,
              let parent = row["parentThreadId"] as? String, UUID(uuidString: parent) != nil,
              child.lowercased() != parent.lowercased() else { return nil }
        return ["threadId": child.lowercased(), "parentThreadId": parent.lowercased()]
    }.sorted { $0["threadId"]! < $1["threadId"]! }
    return stride(from: 0, to: links.count, by: 100).compactMap { start in
        let batch = Array(links[start..<min(start + 100, links.count)])
        guard let encoded = try? JSONSerialization.data(withJSONObject: batch, options: [.sortedKeys]) else { return nil }
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let id = "codex-relationships-\(digest.prefix(32))"
        let event: [String: Any] = ["sessionId": "conversation-relationships", "eventId": id,
                                  "eventType": "local/threads/relationships", "title": "Conversation relationships",
                                  "status": "stale", "threadRelationships": batch]
        guard let body = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return nil }
        return (id, body)
    }
}
