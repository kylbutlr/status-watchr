import Foundation
import CoreFoundation
import SQLite3

struct QuestionAnswer: Equatable {
    let attentionID: String
    let turnID: String
    let answeredAt: Date
}

enum QuestionHookMetadata {
    static func extract(_ payload: [String: Any]) -> [String: Any] {
        guard payload["hook_event_name"] as? String == "PostToolUse",
              let tool = payload["tool_name"] as? String,
              ["request_user_input_async", "functions.request_user_input_async"].contains(tool),
              let call = payload["tool_use_id"] as? String,
              call.range(of: "^call_[A-Za-z0-9_-]{1,180}$", options: .regularExpression) != nil,
              let input = payload["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [Any], (1...64).contains(questions.count) else { return [:] }
        let response: [String: Any]?
        if let object = payload["tool_response"] as? [String: Any] { response = object }
        else if let string = payload["tool_response"] as? String, let data = string.data(using: .utf8) {
            response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else { response = nil }
        guard let accepted = response?["accepted"] as? NSNumber,
              CFGetTypeID(accepted) == CFBooleanGetTypeID(), accepted.boolValue else { return [:] }
        return ["questionCount": questions.count, "tool_use_id": call]
    }
}

/// SQLite returns only structured reply identities and timestamps. Message bodies,
/// question text and answer values never leave the read-only SQL expression.
struct QuestionAnswerStore {
    let codexHome: URL
    func read(historyID: String, since: Date) -> [QuestionAnswer]? {
        let files = (try? FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: nil)) ?? []
        guard let file = files.compactMap({ url -> (Int, URL)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("thread_history_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(15).dropLast(7)) else { return nil }
            return (version, url)
        }).max(by: { $0.0 < $1.0 })?.1 else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { if db != nil { sqlite3_close(db) }; return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_000)
        let query = """
        WITH messages AS (
          SELECT turn_id, created_at_ms,
            trim(json_extract(item_json, '$.content[0].text')) AS envelope
          FROM thread_items
          WHERE thread_id = ? AND item_type = 'userMessage' AND created_at_ms >= ?
            AND json_valid(item_json) AND json_array_length(item_json, '$.content') = 1
            AND json_extract(item_json, '$.content[0].type') = 'text'
        ), bodies AS (
          SELECT turn_id, created_at_ms,
            trim(substr(envelope, length('<send_user_message_question_reply>') + 1,
              length(envelope) - length('<send_user_message_question_reply>')
                - length('</send_user_message_question_reply>'))) AS body
          FROM messages
          WHERE substr(envelope, 1, length('<send_user_message_question_reply>')) = '<send_user_message_question_reply>'
            AND substr(envelope, -length('</send_user_message_question_reply>')) = '</send_user_message_question_reply>'
        )
        SELECT json_extract(reply.value, '$.questionItemId'), turn_id, created_at_ms
        FROM bodies, json_each(CASE WHEN json_valid(body) THEN
          CASE WHEN json_type(body) = 'array' THEN body ELSE '[]' END ELSE '[]' END) reply
        WHERE reply.type = 'object'
        ORDER BY created_at_ms DESC LIMIT 200
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            if statement != nil { sqlite3_finalize(statement) }; return nil
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, historyID, -1, transient)
        sqlite3_bind_int64(statement, 2, Int64(since.timeIntervalSince1970 * 1_000))
        var result: [QuestionAnswer] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let identity = sqlite3_column_text(statement, 0), let turn = sqlite3_column_text(statement, 1),
               let answerID = Self.attentionID(String(cString: identity)) {
                result.append(QuestionAnswer(attentionID: answerID, turnID: String(cString: turn),
                    answeredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2) / 1_000)))
            }
            step = sqlite3_step(statement)
        }
        return step == SQLITE_DONE ? result : nil
    }

    static func attentionID(_ value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let identity = (try? JSONSerialization.jsonObject(with: data)) as? [Any], identity.count == 3,
              identity[0] as? String == "request_user_input_async",
              let call = identity[1] as? String,
              call.range(of: "^call_[A-Za-z0-9_-]{1,180}$", options: .regularExpression) != nil,
              let index = identity[2] as? NSNumber, CFGetTypeID(index) != CFBooleanGetTypeID(),
              index.doubleValue == Double(index.intValue), (0..<64).contains(index.intValue) else { return nil }
        return "\(call):\(index.intValue)"
    }
}

struct PendingQuestion {
    let threadID: String
    let turnID: String
    let attentionID: String
    let requestedAt: Date
    var announced = false
}
