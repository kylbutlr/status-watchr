import XCTest
import SQLite3
@testable import StatusWatchr

final class HistoryIdentityTests: XCTestCase {
    private let task = "11111111-1111-7111-8111-111111111111"
    private let history = "22222222-2222-7222-8222-222222222222"

    func testFilenameMappingRejectsUnrelatedAndMalformedPointers() {
        let prefix = "/test/rollout-2026-09-21T08-14-40-"
        XCTAssertEqual(CodexThreadStore.historyID(taskID: task, rolloutPath: prefix + task + ".jsonl"), task)
        XCTAssertEqual(CodexThreadStore.historyID(taskID: task, rolloutPath: prefix + task + "_" + history + ".jsonl"), history)
        XCTAssertEqual(CodexThreadStore.historyID(taskID: task, rolloutPath: prefix + history + "_" + history + ".jsonl"), task)
        XCTAssertEqual(CodexThreadStore.historyID(taskID: task, rolloutPath: prefix + task + "_not-a-uuid.jsonl"), task)
        XCTAssertEqual(CodexThreadStore.historyID(taskID: task, rolloutPath: nil), task)
    }

    private func execute(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testRotatedHistoryRemainsAttachedToOriginalTask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try execute(directory.appendingPathComponent("state_5.sqlite"), """
            CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, archived INTEGER, updated_at INTEGER, rollout_path TEXT);
            INSERT INTO threads VALUES ('\(task)', 'Test task', '', '/test', 0, 100,
            '/unused/rollout-2026-09-21T08-14-40-\(task)_\(history).jsonl');
            """)
        let database = directory.appendingPathComponent("thread_history_1.sqlite")
        try execute(database, """
            CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, started_at INTEGER, completed_at INTEGER, rollout_ordinal INTEGER);
            INSERT INTO thread_turns VALUES ('\(task)', 'old-run', 'interrupted', 10, 11, 1);
            INSERT INTO thread_turns VALUES ('\(history)', 'new-run', 'inProgress', 20, NULL, 2);
            """)
        let threads = try XCTUnwrap(CodexThreadStore(codexHome: directory).threads())
        let store = CodexTurnStateStore(databaseURL: database)
        let runs = store.histories(forThreads: threads)
        XCTAssertEqual(threads.first?["id"] as? String, task)
        XCTAssertEqual(runs[task]?.first?.marker, "new-run")
        if case .working = runs[task]?.first {} else { XCTFail("Active rotated run must appear under original task") }
        XCTAssertNil(runs[history], "Never create a second hosted task for the history ID")
        XCTAssertFalse(String(describing: threads).contains("/unused/"), "Raw rollout path stays inside inventory reader")
        try execute(database, "UPDATE thread_turns SET status='completed', completed_at=30 WHERE thread_id='\(history)';")
        if case .finished = store.histories(forThreads: threads)[task]?.first {} else { XCTFail("Completion must retain the same mapping") }
        try execute(database, "DELETE FROM thread_turns WHERE thread_id='\(history)';")
        XCTAssertNil(store.histories(forThreads: threads)[task], "Missing new history must not resurrect the old interrupted run")
    }
}
