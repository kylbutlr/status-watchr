import Foundation
import CryptoKit

/// Titles are display metadata, never inferred from conversation contents.
func activityTitle(_ candidates: String?...) -> String {
    let title = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "Untitled task"
    // The hosted contract counts UTF-16 units, not Swift grapheme clusters.
    var result = ""
    var length = 0
    for character in title {
        let part = String(character)
        guard length + part.utf16.count <= 500 else { break }
        result += part
        length += part.utf16.count
    }
    return result.isEmpty ? "Untitled task" : result
}

func preparedEventBody(_ original: Data) throws -> Data {
    guard var event = try JSONSerialization.jsonObject(with: original) as? [String: Any],
          let title = event["title"] as? String else { throw CocoaError(.fileReadCorruptFile) }
    event["title"] = activityTitle(title)
    return try JSONSerialization.data(withJSONObject: event)
}

func deliveryRejectionMessage(_ status: Int) -> String {
    switch status {
    case 401, 403: "Delivery authentication rejected (HTTP \(status)). Events are saved locally. Check the saved ingest token."
    case 400, 422: "Event rejected or storage unavailable (HTTP \(status)). Kept locally for retry; other events can continue."
    case 413: "Event too large (HTTP 413). Kept locally for review; other events can continue."
    case 429: "Server rate limit reached (HTTP 429). Events are saved locally and will retry."
    case 500...599: "Server unavailable (HTTP \(status)). Events are saved locally and will retry."
    default: "Delivery rejected (HTTP \(status)). Events are saved locally; check the server configuration."
    }
}

struct DeliveryBatchResult {
    var sent = 0
    var pending = 0
    var error: String?
}

/// In-memory identity only, never written to the activity journal.
@MainActor final class DeliveryAttempts {
    private var attempted: [URL: SHA256.Digest] = [:]
    func retain(_ files: [URL]) { let paths = Set(files); attempted = attempted.filter { paths.contains($0.key) } }
    func begin(_ file: URL, original: Data) -> Bool {
        let digest = SHA256.hash(data: original)
        let retry = attempted[file].map { Array($0) == Array(digest) } ?? false
        attempted[file] = digest
        return retry
    }
    func completed(_ file: URL) { attempted.removeValue(forKey: file) }
}

/// Transport is injectable so recovery uses the same path in offline tests and the app.
@MainActor
func deliverBatch(outbox: EventOutbox, shouldContinue: () -> Bool, diagnostics: DiagnosticHistory? = nil, attempts: DeliveryAttempts? = nil,
                  send: (Data) async throws -> Int) async -> DeliveryBatchResult {
    var result = DeliveryBatchResult()
    do {
        // Classify previously queued reviews before replaying their old activity events.
        let pending = try outbox.pending()
        let files = pending.filter { $0.lastPathComponent.hasPrefix("codex-exclusion-") }
            + pending.filter { !$0.lastPathComponent.hasPrefix("codex-exclusion-") }
        attempts?.retain(files)
        for file in files.prefix(50) {
            guard shouldContinue() else { break }
            let original: Data
            let body: Data
            do {
                original = try Data(contentsOf: file)
                body = try preparedEventBody(original)
            } catch {
                result.error = "Unreadable queued event kept locally for review; other events can continue."
                diagnostics?.record(.delivery, category: .localStorage, queued: files.count)
                if file.lastPathComponent.hasPrefix("codex-exclusion-") {
                    result.error = "Internal review exclusions are unreadable. Activity replay is paused; diagnostics are available."
                    break
                }
                continue
            }
            let status: Int
            do {
                let retry = attempts?.begin(file, original: original) ?? false
                status = try await ConnectionContext.$retry.withValue(retry) { try await send(body) }
            }
            catch {
                diagnostics?.record(.delivery, category: DiagnosticHistory.category(for: error), queued: files.count - result.sent)
                result.error = "Delivery unavailable. Events are saved locally and will retry."
                break
            }
            guard (200..<300).contains(status) else {
                result.error = deliveryRejectionMessage(status)
                diagnostics?.record(.delivery, category: .http, httpStatus: status, queued: files.count - result.sent)
                if file.lastPathComponent.hasPrefix("codex-exclusion-") {
                    result.error = "Internal review exclusions rejected (HTTP \(status)). Activity replay is paused; check the server update."
                    break
                }
                if [400, 413, 422].contains(status) { continue }
                break
            }
            // The file remains original until acknowledgment. Never erase a newer heartbeat.
            if (try? Data(contentsOf: file)) == original { try FileManager.default.removeItem(at: file) }
            attempts?.completed(file)
            result.sent += 1
        }
        result.pending = try outbox.pending().count
        // An empty queue or stopped batch does not prove that transport recovered.
        if result.error == nil && result.sent > 0 { diagnostics?.success(.delivery, queued: result.pending) }
    } catch {
        result.error = "Delivery unavailable. Events are saved locally and will retry."
        result.pending = (try? outbox.pending().count) ?? 0
        diagnostics?.record(.delivery, category: .localStorage, queued: result.pending)
    }
    return result
}
