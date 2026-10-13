import Foundation
import SQLite3

struct CodexTurnStateStore {
    private let explicitDatabaseURL: URL?
    private let codexHome: URL?

    init(databaseURL: URL) {
        explicitDatabaseURL = databaseURL
        codexHome = nil
    }

    init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        explicitDatabaseURL = nil
        self.codexHome = codexHome
    }

    func state(for threadID: String) -> LocalSessionState {
        states(for: [threadID])[threadID] ?? .unknown
    }

    /// Read only projected item type and timing. Never select item_json, command text, or tool output.
    func hasBashProgress(threadID: String, turnID: String, after requestAt: Date) -> Bool {
        guard let databaseURL = explicitDatabaseURL ?? codexHome.flatMap(Self.latestDatabase) else { return false }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)

        let query = """
            SELECT 1 FROM thread_items
            WHERE thread_id = ? AND turn_id = ? AND item_type = 'commandExecution'
              AND (started_at_ms > ? OR completed_at_ms > ?)
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement { sqlite3_finalize(statement) }
            return false
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let requestAtMs = Int64(requestAt.timeIntervalSince1970 * 1_000)
        guard sqlite3_bind_text(statement, 1, threadID, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, turnID, -1, transient) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, requestAtMs) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, requestAtMs) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func histories(forThreads threads: [[String: Any]]) -> [String: [LocalSessionState]] {
        guard case .available(let histories) = readHistories(forThreads: threads) else { return [:] }
        return histories
    }

    func readHistories(forThreads threads: [[String: Any]]) -> CodexTurnHistoryRead {
        let identities = threads.compactMap { thread -> (String, String)? in
            guard let id = thread["id"] as? String else { return nil }
            return (id, thread["historyId"] as? String ?? id)
        }
        return readHistories(for: identities)
    }

    private func readHistories(for identities: [(String, String)]) -> CodexTurnHistoryRead {
        let histories = readHistories(for: identities.map { $0.1 })
        guard case .available(let histories) = histories else { return histories }
        var result: [String: [LocalSessionState]] = [:]
        for (taskID, historyID) in identities { result[taskID] = histories[historyID] }
        return .available(result)
    }

    func states(for threadIDs: [String]) -> [String: LocalSessionState] {
        histories(for: threadIDs).compactMapValues { $0.first }
    }

    func histories(for threadIDs: [String]) -> [String: [LocalSessionState]] {
        guard case .available(let histories) = readHistories(for: threadIDs) else { return [:] }
        return histories
    }

    private func readHistories(for threadIDs: [String]) -> CodexTurnHistoryRead {
        let databaseURL = explicitDatabaseURL ?? codexHome.flatMap(Self.latestDatabase)
        guard !threadIDs.isEmpty else { return .available([:]) }
        guard let databaseURL else { return .unavailable(.databaseMissing) }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return .unavailable(.openFailed)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)

        let query = """
            SELECT turn_id, status, started_at, completed_at
            FROM thread_turns
            WHERE thread_id = ?
            ORDER BY COALESCE(started_at, 0) DESC,
                     rollout_ordinal DESC
            LIMIT 20
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            let details = CodexSQLiteFailureDetails.capture(
                from: database,
                databaseVersion: CodexSQLiteFailureDetails.databaseVersion(of: databaseURL, prefix: "thread_history_")
            )
            if let statement { sqlite3_finalize(statement) }
            return .unavailable(.queryFailed(details))
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: [LocalSessionState]] = [:]
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for threadID in Set(threadIDs) {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            guard sqlite3_bind_text(statement, 1, threadID, -1, transient) == SQLITE_OK else {
                return .unavailable(.readFailed)
            }
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                guard let turnPointer = sqlite3_column_text(statement, 0), let statusPointer = sqlite3_column_text(statement, 1) else {
                    return .unavailable(.readFailed)
                }
                let turnID = String(cString: turnPointer)
                let status = String(cString: statusPointer)
                let startedAt = timestamp(statement, column: 2)
                let completedAt = timestamp(statement, column: 3)
                result[threadID, default: []].append(Self.localState(status: status, turnID: turnID, startedAt: startedAt, completedAt: completedAt))
                stepResult = sqlite3_step(statement)
            }
            guard stepResult == SQLITE_DONE else { return .unavailable(.readFailed) }
        }
        return .available(result)
    }

    private static func latestDatabase(in codexHome: URL) -> URL? {
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: codexHome,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return candidates
            .compactMap { url -> (version: Int, url: URL)? in
                let name = url.lastPathComponent
                guard name.hasPrefix("thread_history_"), name.hasSuffix(".sqlite") else { return nil }
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard fileSize > 0 else { return nil }
                let version = name
                    .dropFirst("thread_history_".count)
                    .dropLast(".sqlite".count)
                guard let number = Int(version) else { return nil }
                return (number, url)
            }
            .max { $0.version < $1.version }?
            .url
    }

    private static func localState(status: String, turnID: String, startedAt: String?, completedAt: String?) -> LocalSessionState {
        switch status {
        case "inProgress": return .working(marker: turnID, occurredAt: startedAt)
        case "completed": return .finished(marker: turnID, occurredAt: completedAt ?? startedAt)
        case "failed": return .failed(marker: turnID, occurredAt: completedAt ?? startedAt)
        case "interrupted": return .stale(marker: turnID, occurredAt: completedAt ?? startedAt)
        default: return .unknown
        }
    }

    private func timestamp(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        var value = sqlite3_column_double(statement, column)
        if value > 10_000_000_000 { value /= 1_000 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: value))
    }
}
