import Foundation
import CryptoKit

/// Separate from lifecycle events so repairing retained titles never replays completions.
func conversationTitleRepairEvents(_ rows: [[String: Any]]) -> [(id: String, body: Data)] {
    let titles = rows.compactMap { row -> [String: String]? in
        guard let id = row["id"] as? String, UUID(uuidString: id) != nil,
              let title = row["title"] as? String, title != "Untitled task" else { return nil }
        return ["threadId": id.lowercased(), "title": activityTitle(title)]
    }.sorted { $0["threadId"]! < $1["threadId"]! }
    var batches: [[[String: String]]] = []
    var batch: [[String: String]] = []
    for row in titles {
        let candidate = batch + [row]
        let bytes = (try? JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys]).count) ?? Int.max
        // The ingestion body cap is 16 KiB, including JSON escaping and UTF-8 headers.
        if !batch.isEmpty, candidate.count > 100 || bytes > 12_000 {
            batches.append(batch)
            batch = []
        }
        batch.append(row)
    }
    if !batch.isEmpty { batches.append(batch) }
    return batches.compactMap { batch in
        guard let encoded = try? JSONSerialization.data(withJSONObject: batch, options: [.sortedKeys]) else { return nil }
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let id = "codex-titles-\(digest.prefix(32))"
        let event: [String: Any] = ["sessionId": "title-repairs", "eventId": id, "eventType": "local/threads/titles",
                                  "title": "Conversation titles", "status": "stale", "threadTitles": batch]
        guard let body = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return nil }
        return (id, body)
    }
}
