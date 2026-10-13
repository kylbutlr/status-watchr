import Foundation
import SQLite3

/// Explicit-column, read-only inventory. Never selects preview, first_user_message, or item bodies.
struct CodexThreadStore {
    let codexHome: URL
    init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) { self.codexHome = codexHome }

    func threads() -> [[String: Any]]? {
        guard case .available(let threads) = read() else { return nil }
        return threads
    }

    func read() -> CodexThreadInventoryRead { read(selection: .inventory) }

    /// A completion's ancestor can be archived or outside the recent discovery window.
    func thread(id: String) -> [String: Any]? {
        guard case .available(let rows) = read(selection: .thread(id)) else { return nil }
        return rows.first
    }

    /// Title-only repair includes archived subtasks beyond the lifecycle discovery limit.
    func subagentTitleRepairs() -> [[String: Any]]? {
        guard case .available(let rows) = read(selection: .titleRepairs) else { return nil }
        return rows
    }

    /// ID-only parent links include named, archived and older subtasks for retained dashboard history.
    func conversationRelationships() -> [[String: Any]]? {
        guard case .available(let rows) = read(selection: .relationships) else { return nil }
        return rows
    }

    /// Includes archived reviews so previously uploaded history can be hidden by identity.
    func internalReviewIDs() -> Set<String>? {
        guard case .available(let rows) = read(selection: .reviews) else { return nil }
        return Set(rows.compactMap { $0["id"] as? String })
    }

    func permitsHook(threadID: String) -> Bool {
        guard case .available(let rows) = read(selection: .observableID(threadID)) else { return false }
        return !rows.isEmpty
    }

    private enum Selection { case inventory, titleRepairs, relationships, thread(String), reviews, observableID(String) }

    private func read(selection: Selection) -> CodexThreadInventoryRead {
        let candidates = (try? FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: nil)) ?? []
        let latest = candidates.compactMap { url -> (Int, URL)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, url)
        }.max { $0.0 < $1.0 }
        guard let latest else { return .unavailable(.databaseMissing) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(latest.1.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            return .unavailable(.openFailed)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_000)
        var schema: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &schema, nil) == SQLITE_OK else {
            if let schema { sqlite3_finalize(schema) }
            return .unavailable(.queryFailed(CodexSQLiteFailureDetails.capture(from: db, databaseVersion: latest.0)))
        }
        var columns = Set<String>()
        while sqlite3_step(schema) == SQLITE_ROW {
            if let name = sqlite3_column_text(schema, 1) { columns.insert(String(cString: name)) }
        }
        sqlite3_finalize(schema)
        var classifications: [String] = []
        if columns.contains("thread_source") { classifications.append("coalesce(t.thread_source, '') = 'guardian_review'") }
        if columns.contains("source") {
            classifications.append("CASE WHEN json_valid(t.source) THEN coalesce(json_extract(t.source, '$.subagent.other'), '') ELSE '' END = 'guardian'")
        }
        let internalReview = classifications.isEmpty ? "0" : "(" + classifications.joined(separator: " OR ") + ")"
        let query: String
        switch selection {
        case .relationships:
            let parentID = columns.contains("source") ? "CASE WHEN json_valid(t.source) THEN json_extract(t.source, '$.subagent.thread_spawn.parent_thread_id') END" : "NULL"
            query = "SELECT t.id, \(parentID) FROM threads t WHERE \(parentID) IS NOT NULL AND NOT \(internalReview) ORDER BY t.id"
        case .inventory, .titleRepairs, .thread:
            let rollout = columns.contains("rollout_path") ? "t.rollout_path" : "NULL"
            func spawn(_ field: String) -> String {
                columns.contains("source") ? "CASE WHEN json_valid(t.source) THEN json_extract(t.source, '$.subagent.thread_spawn.\(field)') END" : "NULL"
            }
            func metadata(_ field: String) -> String {
                columns.contains(field) ? "coalesce(nullif(trim(t.\(field)), ''), \(spawn(field)))" : spawn(field)
            }
            let subagent = columns.contains("thread_source") ? "t.thread_source = 'subagent' OR" : ""
            let isSubagent = "CASE WHEN \(subagent) \(spawn("parent_thread_id")) IS NOT NULL THEN 1 ELSE 0 END"
            let scope: String
            if case .thread = selection {
                scope = "t.id = ? AND NOT \(internalReview) LIMIT 1"
            } else if case .titleRepairs = selection {
                scope = "\(isSubagent) = 1 AND coalesce(nullif(trim(t.name), ''), nullif(trim(t.title), ''), 'Untitled task') = 'Untitled task' AND NOT \(internalReview) ORDER BY t.id"
            } else {
                scope = "t.archived = 0 AND NOT \(internalReview) ORDER BY t.updated_at DESC LIMIT 100"
            }
            query = """
                SELECT t.id, t.name, t.title, t.cwd, \(rollout), parent.name, parent.title,
                       \(metadata("agent_path")), \(metadata("agent_nickname")),
                       \(isSubagent), \(spawn("parent_thread_id"))
                FROM threads t LEFT JOIN threads parent ON parent.id = \(spawn("parent_thread_id"))
                WHERE \(scope)
                """
        case .reviews:
            query = "SELECT t.id, NULL, NULL, NULL, NULL FROM threads t WHERE \(internalReview) ORDER BY t.id"
        case .observableID:
            query = "SELECT t.id, NULL, NULL, NULL, NULL FROM threads t WHERE t.id = ? AND NOT \(internalReview) LIMIT 1"
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            let details = CodexSQLiteFailureDetails.capture(from: db, databaseVersion: latest.0)
            if let statement { sqlite3_finalize(statement) }
            return .unavailable(.queryFailed(details))
        }
        guard let statement else {
            return .unavailable(.queryFailed(CodexSQLiteFailureDetails.capture(from: db, databaseVersion: latest.0)))
        }
        defer { sqlite3_finalize(statement) }
        let selectedID: String?
        switch selection {
        case .observableID(let id), .thread(let id): selectedID = id
        default: selectedID = nil
        }
        if let id = selectedID {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, id, -1, transient)
        }
        var threads: [[String: Any]] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            func text(_ index: Int32) -> String? { sqlite3_column_text(statement, index).map { String(cString: $0) } }
            if let id = text(0) {
                switch selection {
                case .relationships:
                    if let parentID = text(1) { threads.append(["id": id, "parentThreadId": parentID]) }
                case .inventory, .titleRepairs, .thread:
                    let title = Self.conversationTitle(id: id, name: text(1), title: text(2), parentName: text(5), parentTitle: text(6),
                                                       agentPath: text(7), nickname: text(8), isSubagent: sqlite3_column_int(statement, 9) == 1)
                    if case .titleRepairs = selection { threads.append(["id": id, "title": title]) }
                    else {
                        var row: [String: Any] = ["id": id, "historyId": Self.historyID(taskID: id, rolloutPath: text(4)),
                                                 "title": title, "cwd": text(3) ?? "", "isSubagent": sqlite3_column_int(statement, 9) == 1]
                        if let parentID = text(10) { row["parentThreadId"] = parentID }
                        threads.append(row)
                    }
                default: threads.append(["id": id])
                }
            }
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? .available(threads) : .unavailable(.readFailed)
    }

    /// Spawn metadata names otherwise unnamed subtasks. Never infer a name from prompts or rollout contents.
    private static func conversationTitle(id: String, name: String?, title: String?, parentName: String?, parentTitle: String?,
                                          agentPath: String?, nickname: String?, isSubagent: Bool) -> String {
        let authored = activityTitle(name, title)
        guard authored == "Untitled task", isSubagent else { return authored }
        let pathLabel = agentPath.flatMap { path -> String? in
            guard path.hasPrefix("/root/"), path.count <= 250,
                  path.range(of: "^/root/(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
            return path.split(separator: "/").last.map { String($0).replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ") }
        }
        let label = activityTitle(pathLabel, nickname, "Subagent \(id.prefix(8))")
        let parent = activityTitle(parentName, parentTitle)
        return activityTitle(parent == "Untitled task" ? label : "\(parent): \(label)")
    }

    /// The current rollout filename links a stable task to its resumed history.
    /// Inspect only the filename, never the rollout contents or arbitrary paths.
    static func historyID(taskID: String, rolloutPath: String?) -> String {
        guard UUID(uuidString: taskID) != nil, let rolloutPath else { return taskID }
        let filename = URL(fileURLWithPath: rolloutPath).lastPathComponent.lowercased()
        let pattern = "^rollout-[0-9]{4}-[0-9]{2}-[0-9]{2}t[0-9]{2}-[0-9]{2}-[0-9]{2}-"
            + NSRegularExpression.escapedPattern(for: taskID.lowercased())
            + "_([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\\.jsonl$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let range = Range(match.range(at: 1), in: filename) else { return taskID }
        return String(filename[range])
    }
}
