import XCTest
import SQLite3
@testable import StatusWatchr

final class InternalReviewFilteringTests: XCTestCase {
    func testLiveInventoryExcludesReviewsWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["WATCHR_VERIFY_INTERNAL_REVIEWS"] == "1" else { throw XCTSkip("Live metadata check is opt-in.") }
        let store = CodexThreadStore()
        let reviews = try XCTUnwrap(store.internalReviewIDs())
        let rows = try XCTUnwrap(store.threads())
        XCTAssertFalse(reviews.isEmpty)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(reviews.isDisjoint(with: Set(rows.compactMap { $0["id"] as? String })))
        print("Verified live inventory: \(rows.count) observable threads; \(reviews.count) internal reviews excluded.")
    }

    func testReviewsDoNotConsumeDiscoverySlotsAndTitleIsNotAFilter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, archived INTEGER,
              updated_at INTEGER, thread_source TEXT, source TEXT, preview TEXT, first_user_message TEXT);
            INSERT INTO threads VALUES ('user', 'Guardian review', '', '/test', 0, 1,
              'user', 'vscode', 'SECRET_PREVIEW', 'SECRET_PROMPT');
            INSERT INTO threads VALUES ('child', 'Normal subagent', '', '/test', 0, 2,
              'subagent', '{"subagent":{"thread_spawn":{"parent_thread_id":"user"}}}', '', '');
            WITH RECURSIVE reviews(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM reviews WHERE n < 110)
            INSERT INTO threads SELECT 'review-' || n, 'Guardian review', '', '/test', 0, n+10,
              'guardian_review', '{"subagent":{"other":"guardian"}}', '', '' FROM reviews;
            INSERT INTO threads VALUES ('source-only-review', 'Another title', '', '/test', 0, 999,
              NULL, '{"subagent":{"other":"guardian"}}', '', '');
            INSERT INTO threads VALUES ('invalid-source', 'Ordinary task', '', '/test', 0, 3,
              NULL, 'not-json', '', '');
            """, nil, nil, nil), SQLITE_OK)
        let rows = try XCTUnwrap(CodexThreadStore(codexHome: directory).threads())
        XCTAssertEqual(Set(rows.compactMap { $0["id"] as? String }), ["user", "child", "invalid-source"])
        XCTAssertFalse(String(describing: rows).contains("SECRET"))
        let store = CodexThreadStore(codexHome: directory)
        XCTAssertEqual(store.internalReviewIDs()?.count, 111)
        XCTAssertTrue(store.internalReviewIDs()?.contains("source-only-review") == true)
        XCTAssertFalse(store.permitsHook(threadID: "source-only-review"))
        XCTAssertFalse(store.permitsHook(threadID: "not-yet-projected"))
        XCTAssertTrue(store.permitsHook(threadID: "user"))
        XCTAssertTrue(store.permitsHook(threadID: "child"))
        XCTAssertEqual(sqlite3_exec(db, "UPDATE threads SET archived = 1 WHERE id = 'review-1';", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(store.internalReviewIDs()?.contains("review-1") == true)
    }

    func testSourceMetadataFiltersReviewsOnOlderSchemas() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, archived INTEGER, updated_at INTEGER, source TEXT);
            INSERT INTO threads VALUES ('review', 'Other title', '', '/test', 0, 2, '{"subagent":{"other":"guardian"}}');
            INSERT INTO threads VALUES ('user', 'Guardian review', '', '/test', 0, 1, 'vscode');
            """, nil, nil, nil), SQLITE_OK)
        let rows = try XCTUnwrap(CodexThreadStore(codexHome: directory).threads())
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["user"])
    }

    @MainActor func testOfflineReplayClassifiesReviewsBeforeOlderEventsAndStopsIfClassificationRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = EventOutbox(directory: directory)
        let ids = Set((1...101).map { String(format: "00000000-0000-4000-8000-%012d", $0) })
        let reports = internalReviewExclusionEvents(ids: ids)
        XCTAssertEqual(reports.count, 2)
        try outbox.enqueue(id: "older-activity", body: Data("{\"title\":\"Guardian review\",\"eventType\":\"local/task/completed\"}".utf8), now: Date())
        for report in reports { try outbox.enqueue(id: report.id, body: report.body) }
        var attempted: [String] = []
        let rejected = await deliverBatch(outbox: outbox, shouldContinue: { true }) { body in
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            attempted.append(try XCTUnwrap(event["eventType"] as? String))
            XCTAssertNil(event["replyPreview"])
            XCTAssertNil(event["repo"])
            return 400
        }
        XCTAssertEqual(attempted, ["local/threads/excluded"])
        XCTAssertEqual(rejected.pending, 3)
        attempted = []
        let recovered = await deliverBatch(outbox: outbox, shouldContinue: { true }) { body in
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            attempted.append(try XCTUnwrap(event["eventType"] as? String))
            return 202
        }
        XCTAssertEqual(attempted, ["local/threads/excluded", "local/threads/excluded", "local/task/completed"])
        XCTAssertEqual(recovered.pending, 0)
    }
}
