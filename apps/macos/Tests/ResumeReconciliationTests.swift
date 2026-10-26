import XCTest
import SQLite3
@testable import StatusWatchr

final class ResumeReconciliationTests: XCTestCase {
    private func execute(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    private func fixture(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Int(Date().timeIntervalSince1970)
        try execute(directory.appendingPathComponent("state_5.sqlite"), """
            CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, archived INTEGER, updated_at INTEGER);
            INSERT INTO threads VALUES ('thread', 'Existing active conversation', '', '/fixture', 0, \(now));
            """)
        try execute(directory.appendingPathComponent("thread_history_1.sqlite"), """
            CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, started_at INTEGER, completed_at INTEGER, rollout_ordinal INTEGER);
            INSERT INTO thread_turns VALUES ('thread', 'old-finished', 'completed', \(now - 7200), \(now - 7100), 1);
            INSERT INTO thread_turns VALUES ('thread', 'already-running', 'inProgress', \(now - 3600), NULL, 2);
            """)
    }

    @MainActor func testStartPublishesAlreadyRunningConversationWithoutANewHook() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { events.append($0) })
        controller.start()
        defer { controller.stop() }
        XCTAssertTrue(events.contains { $0["threadId"] as? String == "thread" && $0["status"] as? String == "working" && $0["turnId"] as? String == "already-running" },
                      "Starting monitoring must reconcile work that was already in progress, without a new state transition or hook")
        XCTAssertFalse(events.contains { $0["status"] as? String == "finished" && $0["notificationEligible"] as? Bool != false },
                       "Startup history must not replay old completion alerts")
    }

    @MainActor func testStandbyResumePublishesAnUnchangedActiveRunImmediately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { events.append($0) })
        controller.start()
        defer { controller.stop() }
        controller.acceptWorkPermission(WorkSwitchPermission(configured: true, state: "active", revision: 1, leaseSeconds: 60))
        controller.acceptWorkPermission(WorkSwitchPermission(configured: true, state: "standby", revision: 2, leaseSeconds: 60))
        events.removeAll()
        controller.acceptWorkPermission(WorkSwitchPermission(configured: true, state: "active", revision: 3, leaseSeconds: 60))
        XCTAssertTrue(events.contains { $0["status"] as? String == "working" && $0["turnId"] as? String == "already-running" },
                      "Resuming must publish the unchanged active run immediately instead of waiting for a state transition or heartbeat window")
        events.removeAll()
        controller.scheduledLocalScan()
        XCTAssertFalse(events.contains { $0["status"] as? String == "working" }, "Normal heartbeat throttling resumes after the reconciliation")
    }

    @MainActor func testStartIncludesAnActiveConversationOutsideTheRecentHundred() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        try execute(directory.appendingPathComponent("state_5.sqlite"), """
            UPDATE threads SET updated_at = 1 WHERE id = 'thread';
            WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 100)
            INSERT INTO threads SELECT 'recent-' || n, 'Recent completed conversation', '', '/fixture', 0, 1000 + n FROM numbers;
            """)
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { events.append($0) })
        controller.start()
        defer { controller.stop() }
        XCTAssertTrue(events.contains { $0["threadId"] as? String == "thread" && $0["status"] as? String == "working" },
                      "An active conversation must not disappear just because 100 other conversations were updated more recently")
        XCTAssertEqual(controller.scannedThreadCount, 101)
    }

    @MainActor func testStopThenStartReconcilesTheSameActiveRun() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { events.append($0) })
        controller.start(); controller.stop(); events.removeAll()
        controller.start()
        defer { controller.stop() }
        XCTAssertEqual(events.filter { $0["status"] as? String == "working" && $0["turnId"] as? String == "already-running" }.count, 1)
    }

    func testDiscoveryRejectsAnOldOrphanedActiveTurnAndReportsSourceFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        let database = directory.appendingPathComponent("thread_history_1.sqlite")
        try execute(database, """
            INSERT INTO thread_turns VALUES ('finished-thread', 'old-orphan', 'inProgress', 1, NULL, 1);
            INSERT INTO thread_turns VALUES ('finished-thread', 'latest', 'completed', 2, 3, 2);
            """)
        XCTAssertEqual(CodexTurnStateStore(codexHome: directory).readActiveThreadIDs(), .available(["thread"]))
        try FileManager.default.removeItem(at: database)
        XCTAssertEqual(CodexTurnStateStore(codexHome: directory).readActiveThreadIDs(), .unavailable(.databaseMissing))
        try execute(database, "CREATE TABLE unrelated(value TEXT);")
        guard case .unavailable(.queryFailed(let details)) = CodexTurnStateStore(codexHome: directory).readActiveThreadIDs() else {
            return XCTFail("An unreadable active-work projection must report a source failure")
        }
        XCTAssertEqual(details.resultCode, SQLITE_ERROR)
    }

    @MainActor func testActiveHistoryAliasesAreIncludedButArchivedAndReviewThreadsStayExcluded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        let task = "00000000-0000-4000-8000-000000000001"
        let history = "00000000-0000-4000-8000-000000000002"
        try execute(directory.appendingPathComponent("state_5.sqlite"), """
            ALTER TABLE threads ADD COLUMN rollout_path TEXT;
            ALTER TABLE threads ADD COLUMN thread_source TEXT;
            UPDATE threads SET updated_at = 1 WHERE id = 'thread';
            INSERT INTO threads VALUES ('\(task)', 'Resumed task', '', '/fixture', 0, 0,
                '/fixture/rollout-2026-10-26T00-00-00-\(task)_\(history).jsonl', NULL);
            INSERT INTO threads VALUES ('archived', 'Archived', '', '/fixture', 1, 0, NULL, NULL);
            INSERT INTO threads VALUES ('review', 'Review', '', '/fixture', 0, 0, NULL, 'guardian_review');
            """)
        try execute(directory.appendingPathComponent("thread_history_1.sqlite"), """
            INSERT INTO thread_turns VALUES ('\(history)', 'alias-run', 'inProgress', 100, NULL, 1);
            INSERT INTO thread_turns VALUES ('archived', 'archived-run', 'inProgress', 100, NULL, 1);
            INSERT INTO thread_turns VALUES ('review', 'review-run', 'inProgress', 100, NULL, 1);
            """)
        // A zero timestamp places the alias outside a full recent-inventory window.
        try execute(directory.appendingPathComponent("state_5.sqlite"), """
            WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 100)
            INSERT INTO threads(id, name, title, cwd, archived, updated_at)
            SELECT 'recent-' || n, 'Recent', '', '/fixture', 0, 1000 + n FROM numbers;
            """)
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { events.append($0) })
        controller.start()
        defer { controller.stop() }
        XCTAssertTrue(events.contains { $0["threadId"] as? String == task && $0["status"] as? String == "working" })
        XCTAssertFalse(events.contains { ["archived", "review"].contains($0["threadId"] as? String ?? "") })
        XCTAssertEqual(controller.scannedThreadCount, 102) // Recent 100 plus both current active conversations.
    }

    @MainActor func testUnavailableActiveDiscoveryShowsDegradedStateAndRecovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { _ in })
        controller.start()
        defer { controller.stop() }
        let database = directory.appendingPathComponent("thread_history_1.sqlite")
        try execute(database, "ALTER TABLE thread_turns RENAME TO temporarily_unavailable;")
        controller.refresh()
        XCTAssertNotNil(controller.sourceFreshness.degradedSince)
        XCTAssertEqual(controller.state, .failed("Local run metadata is unavailable."))
        try execute(database, "ALTER TABLE temporarily_unavailable RENAME TO thread_turns;")
        controller.refresh()
        XCTAssertNil(controller.sourceFreshness.degradedSince)
        XCTAssertEqual(controller.state, .connected)
    }
}
