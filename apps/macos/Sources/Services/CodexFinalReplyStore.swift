import Foundation
import SQLite3

/// Reads only the final answer for one completed turn. Missing or unfamiliar history yields no preview.
struct CodexFinalReplyStore {
    let codexHome: URL
    private static let maxTailBytes = 2_000_000

    init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.codexHome = codexHome
    }

    func preview(threadID: String, turnID: String) -> String? {
        guard UUID(uuidString: threadID) != nil, !turnID.isEmpty, turnID.utf8.count <= 250,
              let databaseURL = Self.latestDatabase(in: codexHome) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, threadID, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0) else { return nil }
        let path = String(cString: pointer)
        return Self.preview(at: URL(fileURLWithPath: path), codexHome: codexHome, threadID: threadID, turnID: turnID)
    }

    private static func latestDatabase(in codexHome: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> (Int, URL)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, url)
        }.max { $0.0 < $1.0 }?.1
    }

    static func preview(at rollout: URL, codexHome: URL, threadID: String, turnID: String) -> String? {
        let sessions = codexHome.appendingPathComponent("sessions").resolvingSymlinksInPath().standardizedFileURL
        let file = rollout.resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(sessions.path + "/"), file.pathExtension == "jsonl" else { return nil }
        let escapedID = NSRegularExpression.escapedPattern(for: threadID.lowercased())
        let name = file.lastPathComponent.lowercased()
        let pattern = "^rollout-[0-9]{4}-[0-9]{2}-[0-9]{2}t[0-9]{2}-[0-9]{2}-[0-9]{2}-"
            + escapedID + "(_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?\\.jsonl$"
        guard name.range(of: pattern, options: .regularExpression) != nil,
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 0,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let offset = max(0, size - maxTailBytes)
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.read(upToCount: min(size, maxTailBytes)) else { return nil }
        let lines = data.split(separator: 10)
        var currentTurn: String?
        var answer: String?
        for line in lines.dropFirst(offset > 0 ? 1 : 0) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = record["payload"] as? [String: Any] else { continue }
            if record["type"] as? String == "turn_context" {
                currentTurn = payload["turn_id"] as? String
                continue
            }
            guard currentTurn == turnID,
                  record["type"] as? String == "response_item",
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "assistant",
                  payload["phase"] as? String == "final_answer",
                  let content = payload["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { part -> String? in
                guard part["type"] as? String == "output_text" else { return nil }
                return part["text"] as? String
            }.joined(separator: " ")
            answer = Self.previewText(text)
        }
        return answer
    }

    static func previewText(_ answer: String) -> String? {
        var inCode = false
        for rawLine in String(answer.prefix(8_000)).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || line.isEmpty || line.hasPrefix("#") || line.hasPrefix("|") || line.hasPrefix(">") { continue }
            let plain = line.replacingOccurrences(of: "^[-*]\\s+", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "[`*_]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "[\\u0000-\\u001f\\u007f-\\u009f]", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.isEmpty { continue }
            var result = ""
            for character in plain {
                let piece = String(character)
                if result.utf16.count + piece.utf16.count > 180 { break }
                result += piece
            }
            return result.isEmpty ? nil : result
        }
        return nil
    }
}
