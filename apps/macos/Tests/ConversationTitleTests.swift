import XCTest
import SQLite3
@testable import StatusWatchr

final class ConversationTitleTests: XCTestCase {
    @MainActor func testFutureSubtaskActivityCarriesItsParentIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        let parent = "00000000-0000-4000-8000-000000000001"
        let child = "00000000-0000-4000-8000-000000000002"
        try execute(directory, "state_5.sqlite", """
            UPDATE threads SET id='\(parent)' WHERE id='parent';
            UPDATE threads SET id='\(child)', source='{"subagent":{"thread_spawn":{"parent_thread_id":"\(parent)"}}}' WHERE id='child';
            """)
        try execute(directory, "thread_history_1.sqlite", "UPDATE thread_turns SET thread_id='\(child)' WHERE thread_id='child';")
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { events.append($0) })
        controller.start()
        defer { controller.stop() }
        controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
        XCTAssertEqual(events.last?["parentThreadId"] as? String, parent)
    }
    @MainActor func testRelationshipReportsAreBoundedPrivateAndRetriedOffline() async throws {
        let parent = "00000000-0000-4000-8000-999999999999"
        let rows: [[String: Any]] = (1...101).map { ["id": String(format: "00000000-0000-4000-8000-%012d", $0), "parentThreadId": parent, "title": "PRIVATE_SENTINEL", "cwd": "/PRIVATE_SENTINEL"] }
        let reports = conversationRelationshipEvents(rows)
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.map(\.id), conversationRelationshipEvents(rows.reversed()).map(\.id))
        XCTAssertTrue(reports.allSatisfy { $0.body.count < 16_384 })
        XCTAssertTrue(conversationRelationshipEvents([["id": parent, "parentThreadId": parent], ["id": "bad", "parentThreadId": parent]]).isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = EventOutbox(directory: directory)
        for report in reports { try outbox.enqueue(id: report.id, body: report.body) }
        let failed = await deliverBatch(outbox: outbox, shouldContinue: { true }) { _ in 503 }
        XCTAssertEqual(failed.pending, 2)
        let delivered = await deliverBatch(outbox: outbox, shouldContinue: { true }) { body in
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("PRIVATE_SENTINEL"))
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(event["eventType"] as? String, "local/threads/relationships")
            XCTAssertNil(event["replyPreview"])
            return 202
        }
        XCTAssertEqual(delivered.sent, 2)
    }

    func testRelationshipBackfillIncludesNamedArchivedAndOlderSubtasksButExcludesReviews() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        try execute(directory, "state_5.sqlite", """
            UPDATE threads SET archived=1, name='Already named' WHERE id='child';
            INSERT INTO threads(id, name, archived, updated_at, source, thread_source)
            VALUES ('review', 'Guardian', 0, 1000,
              '{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}', 'guardian_review');
            WITH RECURSIVE recent(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM recent WHERE n<101)
            INSERT INTO threads(id, name, archived, updated_at, source, thread_source)
            SELECT 'recent-' || n, 'Recent', 0, 100+n, 'vscode', 'user' FROM recent;
            """)
        let store = CodexThreadStore(codexHome: directory)
        XCTAssertFalse(try XCTUnwrap(store.threads()).contains { $0["id"] as? String == "child" })
        let links = try XCTUnwrap(store.conversationRelationships())
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?["id"] as? String, "child")
        XCTAssertEqual(links.first?["parentThreadId"] as? String, "parent")
        XCTAssertNil(links.first?["title"])
    }
    @MainActor func testRepairBatchesStayWithinTransportLimitsAndSurviveOfflineDelivery() async throws {
        let rows: [[String: Any]] = (1...101).map { ["id": String(format: "00000000-0000-4000-8000-%012d", $0), "title": "Project: review"] }
        let reports = conversationTitleRepairEvents(rows)
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.map(\.id), conversationTitleRepairEvents(rows.reversed()).map(\.id))
        let longRows = rows.map { ["id": $0["id"]!, "title": String(repeating: "\u{0001}", count: 500)] }
        XCTAssertTrue(conversationTitleRepairEvents(longRows).allSatisfy { $0.body.count < 16_384 })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = EventOutbox(directory: directory)
        for report in reports { try outbox.enqueue(id: report.id, body: report.body) }
        let failed = await deliverBatch(outbox: outbox, shouldContinue: { true }) { _ in 503 }
        XCTAssertEqual(failed.pending, 2)
        let delivered = await deliverBatch(outbox: outbox, shouldContinue: { true }) { body in
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(report["eventType"] as? String, "local/threads/titles")
            XCTAssertNil(report["replyPreview"])
            XCTAssertNil(report["repo"])
            return 202
        }
        XCTAssertEqual(delivered.sent, 2)
        XCTAssertEqual(delivered.pending, 0)
    }
    func testLiveUnnamedSubagentWhenExplicitlyRequested() throws {
        guard let id = ProcessInfo.processInfo.environment["WATCHR_VERIFY_TITLE_THREAD_ID"] else {
            throw XCTSkip("Live title metadata check is opt-in.")
        }
        let row = try XCTUnwrap(CodexThreadStore().threads()?.first { $0["id"] as? String == id })
        let title = try XCTUnwrap(row["title"] as? String)
        XCTAssertNotEqual(title, "Untitled task")
        XCTAssertTrue(title.contains("performance review"))
        XCTAssertLessThanOrEqual(title.utf16.count, 500)
        print("Verified live subagent title: \(title)")
    }
    private func execute(_ directory: URL, _ file: String, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent(file).path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func fixture(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try execute(directory, "state_5.sqlite", """
            CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, archived INTEGER, updated_at INTEGER,
                                 source TEXT, thread_source TEXT, agent_path TEXT, agent_nickname TEXT);
            INSERT INTO threads VALUES ('parent', 'Project task', '', '/test', 1, 1, 'vscode', 'user', NULL, NULL);
            INSERT INTO threads VALUES ('child', NULL, '', '/test', 0, 2,
              '{"subagent":{"thread_spawn":{"parent_thread_id":"parent","agent_path":"/root/performance_review","agent_nickname":"Nietzsche"}}}',
              'subagent', '/root/performance_review', 'Nietzsche');
            """)
        try execute(directory, "thread_history_1.sqlite", """
            CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, started_at INTEGER, completed_at INTEGER, rollout_ordinal INTEGER);
            INSERT INTO thread_turns VALUES ('child', 'run', 'completed', 10, 11, 1);
            """)
    }

    func testUnnamedSubagentUsesParentAndSubtaskMetadataIncludingArchivedParent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        let rows = try XCTUnwrap(CodexThreadStore(codexHome: directory).threads())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["title"] as? String, "Project task: performance review")
        try execute(directory, "state_5.sqlite", "UPDATE threads SET archived=1 WHERE id='child';")
        XCTAssertEqual(CodexThreadStore(codexHome: directory).subagentTitleRepairs()?.first?["title"] as? String, "Project task: performance review")
        try execute(directory, "state_5.sqlite", "UPDATE threads SET archived=0 WHERE id='child';")
        try execute(directory, "state_5.sqlite", "UPDATE threads SET name='Authored name' WHERE id='child';")
        XCTAssertEqual(CodexThreadStore(codexHome: directory).threads()?.first?["title"] as? String, "Authored name")
    }

    func testSourceMetadataWorksWithoutNewProjectionColumnsAndMalformedSourceIsSafe() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try execute(directory, "state_5.sqlite", """
            CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, archived INTEGER, updated_at INTEGER, source TEXT);
            INSERT INTO threads VALUES ('parent', 'Project', '', '/test', 1, 1, 'vscode');
            INSERT INTO threads VALUES ('child', NULL, '', '/test', 0, 3,
              '{"subagent":{"thread_spawn":{"parent_thread_id":"parent","agent_path":"/root/cart_review"}}}');
            INSERT INTO threads VALUES ('bad', 'Named task', '', '/test', 0, 2, '{bad json');
            """)
        let rows = try XCTUnwrap(CodexThreadStore(codexHome: directory).threads())
        XCTAssertEqual(rows[0]["title"] as? String, "Project: cart review")
        XCTAssertEqual(rows[1]["title"] as? String, "Named task")
    }

    func testTitleRepairFindsSubagentsOutsideTheHundredConversationDiscoveryWindow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        try execute(directory, "state_5.sqlite", """
            WITH RECURSIVE recent(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM recent WHERE n<101)
            INSERT INTO threads(id, name, title, cwd, archived, updated_at, source, thread_source)
            SELECT 'recent-' || n, 'Recent task ' || n, '', '/test', 0, 100+n, 'vscode', 'user' FROM recent;
            """)
        let store = CodexThreadStore(codexHome: directory)
        let discovery = try XCTUnwrap(store.threads())
        XCTAssertEqual(discovery.count, 100)
        XCTAssertFalse(discovery.contains { $0["id"] as? String == "child" })
        XCTAssertEqual(store.subagentTitleRepairs()?.first?["title"] as? String, "Project task: performance review")
    }

    func testMissingParentOrPathKeepsSubagentsRecognizableAndBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        try execute(directory, "state_5.sqlite", """
            UPDATE threads SET source='{}', agent_path=NULL WHERE id='child';
            """)
        XCTAssertEqual(CodexThreadStore(codexHome: directory).threads()?.first?["title"] as? String, "Nietzsche")
        try execute(directory, "state_5.sqlite", "UPDATE threads SET agent_nickname=NULL WHERE id='child';")
        XCTAssertEqual(CodexThreadStore(codexHome: directory).threads()?.first?["title"] as? String, "Subagent child")
    }

    @MainActor func testCompletedSubagentRepairsAndRenamesWithoutCreatingAnotherLifecycleEvent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { events.append($0) })
        controller.start()
        defer { controller.stop() }
        controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
        XCTAssertEqual(events.last?["title"] as? String, "Project task: performance review")
        let eventID = try XCTUnwrap(events.last?["eventId"] as? String)
        try execute(directory, "state_5.sqlite", "UPDATE threads SET name='Renamed project' WHERE id='parent';")
        controller.refresh()
        controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
        XCTAssertEqual(events.last?["title"] as? String, "Renamed project: performance review")
        XCTAssertEqual(events.last?["eventId"] as? String, eventID)
        XCTAssertEqual(events.last?["notificationEligible"] as? Bool, false)
        XCTAssertEqual(events.last?["occurredAt"] as? String, events.first?["occurredAt"] as? String)
        let count = events.count
        controller.refresh()
        controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
        XCTAssertEqual(events.count, count)
    }
}
