import XCTest
import SQLite3
@testable import StatusWatchr

final class ConnectorControllerTests: XCTestCase {
    func testLocalSourceFreshnessPreservesLastSuccessAcrossFailureAndClearsDegradedState() {
        let first = Date(timeIntervalSince1970: 1_000)
        var freshness = LocalSourceFreshness()
        freshness.observe(available: true, at: first)
        freshness.observe(available: false, at: first.addingTimeInterval(5))
        freshness.observe(available: false, at: first.addingTimeInterval(30))

        XCTAssertEqual(freshness.lastSuccessfulScanAt, first)
        XCTAssertEqual(freshness.degradedSince, first.addingTimeInterval(5))
        XCTAssertEqual(freshness.degradedDuration(at: first.addingTimeInterval(65)), 60)

        freshness.observe(available: true, at: first.addingTimeInterval(70))
        XCTAssertEqual(freshness.lastSuccessfulScanAt, first.addingTimeInterval(70))
        XCTAssertNil(freshness.degradedSince)

        freshness.observe(available: false, at: first.addingTimeInterval(75))
        freshness.stop()
        XCTAssertNil(freshness.degradedSince)
        XCTAssertEqual(freshness.lastSuccessfulScanAt, first.addingTimeInterval(70))
    }

    func testEventDeduperRejectsRepeatedScanState() {
        var deduper = ConnectorEventDeduper()
        let key = connectorEventKey(threadID: "thread-1", method: "local/task/aborted", status: "stale", marker: "turn-1")

        XCTAssertTrue(deduper.insert(key))
        XCTAssertFalse(deduper.insert(key))
    }

    func testHeartbeatThrottleAllowsTheFirstObservationAndWaitsForRecoveryWindow() {
        var throttle = ConnectorHeartbeatThrottle()
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(throttle.shouldSend("thread-1", now: now, minimumInterval: connectorMinimumHeartbeatInterval))
        XCTAssertFalse(throttle.shouldSend("thread-1", now: now.addingTimeInterval(59), minimumInterval: connectorMinimumHeartbeatInterval))
        XCTAssertTrue(throttle.shouldSend("thread-1", now: now.addingTimeInterval(60), minimumInterval: connectorMinimumHeartbeatInterval))
    }

    func testHeartbeatThrottleLetsMetadataChangesAndManualRefreshThrough() {
        var throttle = ConnectorHeartbeatThrottle()
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(throttle.shouldSend("thread-1:Old title", now: now, minimumInterval: 120))
        XCTAssertTrue(throttle.shouldSend("thread-1:New title", now: now.addingTimeInterval(1), minimumInterval: 120))
        throttle.reset()
        XCTAssertTrue(throttle.shouldSend("thread-1:New title", now: now.addingTimeInterval(2), minimumInterval: 120))
    }

    func testLocalLifecycleMarkerWinsOverGenericActiveThreadStatus() {
        XCTAssertEqual(connectorStatus(threadType: "active", localState: .stale(marker: "turn-1", occurredAt: nil)), "stale")
        XCTAssertEqual(connectorStatus(threadType: "active", localState: .finished(marker: "turn-1", occurredAt: nil)), "finished")
        XCTAssertEqual(connectorStatus(threadType: "active", localState: .failed(marker: "turn-1", occurredAt: nil)), "failed")
    }

    func testActiveConversationDoesNotImplyManualAttention() {
        let state = LocalSessionState.working(marker: "turn-1", occurredAt: nil)
        XCTAssertEqual(connectorStatus(threadType: "active", localState: state), "working")
        XCTAssertEqual(connectorStatus(threadType: "active", localState: .unknown), "working")
    }

    func testGuiPathIncludesCodexInstalledWithChatGPT() {
        let path = ConnectorEnvironment.path(home: "/Users/test", existingPath: "/usr/bin")

        XCTAssertTrue(path.contains("/Applications/ChatGPT.app/Contents/Resources"))
    }

    func testCodexHookEventsMapToStatusWatchrStates() {
        XCTAssertEqual(statusForHookEvent("UserPromptSubmit"), "working")
        XCTAssertNil(statusForHookEvent("PermissionRequest"))
        XCTAssertEqual(statusForHookEvent("Stop"), "finished")
        XCTAssertEqual(statusForHookEvent("Interrupt"), "stale")
        XCTAssertNil(statusForHookEvent("Unknown"))
    }

    func testInterruptedTurnMapsToStale() {
        XCTAssertEqual(turnStatusForCompletion("interrupted"), "stale")
        XCTAssertEqual(turnStatusForCompletion("completed"), "finished")
        XCTAssertEqual(turnStatusForCompletion("failed"), "failed")
    }

    func testCodexHookInstallerUsesLoopbackOnly() {
        XCTAssertTrue(CodexHookInstaller.command.contains("127.0.0.1:48732/codex-hook"))
        XCTAssertTrue(CodexHookInstaller.eventNames.contains("PermissionRequest"))
    }

    func testRecoveryScanOptionsAvoidAggressiveBackgroundPolling() {
        XCTAssertEqual(connectorRecoveryIntervalOptions, [15, 30, 60])
        XCTAssertEqual(connectorDefaultRecoveryInterval, 60)
        XCTAssertEqual(connectorMinimumHeartbeatInterval, 60)
    }

    func testThreadListPrioritizesRecentlyUpdatedTasks() {
        let firstPage = threadListParameters(cursor: nil)

        XCTAssertEqual(firstPage["archived"] as? Bool, false)
        XCTAssertEqual(firstPage["limit"] as? Int, 100)
        XCTAssertEqual(firstPage["sortKey"] as? String, "updated_at")
        XCTAssertEqual(firstPage["sortDirection"] as? String, "desc")
        XCTAssertNil(firstPage["cursor"])
        XCTAssertEqual(threadListParameters(cursor: "next-page")["cursor"] as? String, "next-page")
    }

    func testThreadListUsesOnlyTheNewestRecordForEachTask() {
        let threads: [[String: Any]] = [
            ["id": "thread-1", "path": "new"],
            ["id": "thread-2", "path": "other"],
            ["id": "thread-1", "path": "old"]
        ]

        let unique = uniqueThreadsByID(threads)
        XCTAssertEqual(unique.count, 2)
        XCTAssertEqual(unique.first?["path"] as? String, "new")
    }

    func testLocalSessionStateUsesLatestTaskMarkerWhenAppServerReportsNotLoaded() {
        let data = Data("""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_1"}}
        {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning"}}}
        """.utf8)

        XCTAssertEqual(LocalSessionState.from(jsonl: data), .working(marker: "turn_1", occurredAt: nil))
    }

    func testLocalSessionStateRecognizesCompletionAfterWork() {
        let data = Data("""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_1"}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn_1"}}
        """.utf8)

        XCTAssertEqual(LocalSessionState.from(jsonl: data), .finished(marker: "turn_1", occurredAt: nil))
    }

    func testLocalSessionStateInfersWorkWhenTaskStartFallsOutsideTheReadWindow() {
        let data = Data("""
        {"type":"event_msg","timestamp":"2026-09-09T05:13:27.910Z","payload":{"type":"item_completed","turn_id":"turn_live"}}
        {"type":"event_msg","timestamp":"2026-09-09T05:13:36.308Z","payload":{"type":"item_completed","turn_id":"turn_live"}}
        """.utf8)

        XCTAssertEqual(LocalSessionState.from(jsonl: data), .working(marker: "turn_live", occurredAt: "2026-09-09T05:13:27.910Z"))
    }

    func testLocalSessionStateDoesNotReopenATerminalTurnFromTrailingActivity() {
        let data = Data("""
        {"type":"event_msg","timestamp":"2026-09-09T05:13:27.910Z","payload":{"type":"task_complete","turn_id":"turn_done"}}
        {"type":"event_msg","timestamp":"2026-09-09T05:13:28.910Z","payload":{"type":"item_completed","turn_id":"turn_done"}}
        """.utf8)

        XCTAssertEqual(LocalSessionState.from(jsonl: data), .finished(marker: "turn_done", occurredAt: "2026-09-09T05:13:27.910Z"))
    }

    func testLocalSessionStateIgnoresDelayedActivityFromAnOlderTurn() {
        let data = Data("""
        {"type":"event_msg","timestamp":"2026-09-08T01:19:41.218Z","payload":{"type":"task_complete","turn_id":"01a07e94-6801-7430-9260-429bcebe42c7"}}
        {"type":"event_msg","timestamp":"2026-09-08T03:07:16.863Z","payload":{"type":"item_completed","turn_id":"01a07e64-7e17-7790-8333-106c10556b16"}}
        """.utf8)

        XCTAssertEqual(LocalSessionState.from(jsonl: data), .finished(marker: "01a07e94-6801-7430-9260-429bcebe42c7", occurredAt: "2026-09-08T01:19:41.218Z"))
    }

    func testTurnSessionIDSeparatesTurnsWithinOneThread() {
        XCTAssertEqual(turnSessionID(threadID: "thread-1", turnID: "turn-1"), "thread-1:turn:turn-1")
        XCTAssertEqual(turnSessionID(threadID: "thread-1", turnID: "unknown"), "thread-1")
    }

    func testLocalSessionStatePreservesSourceTimestamp() {
        let data = Data("""
        {"type":"event_msg","timestamp":"2026-09-02T10:05:00.000Z","payload":{"type":"turn_aborted","turn_id":"turn_1","completed_at":"2026-09-02T10:05:00.000Z"}}
        """.utf8)

        XCTAssertEqual(LocalSessionState.from(jsonl: data), .stale(marker: "turn_1", occurredAt: "2026-09-02T10:05:00.000Z"))
    }

    func testProjectedTurnStateReadsTheLatestInProgressTurn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("thread_history_1.sqlite")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE thread_turns (
                thread_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                rollout_ordinal INTEGER NOT NULL,
                status TEXT NOT NULL,
                started_at INTEGER,
                completed_at INTEGER
            );
            INSERT INTO thread_turns VALUES ('thread-1', 'turn-old', 1, 'completed', 1788920000, 1788920100);
            INSERT INTO thread_turns VALUES ('thread-1', 'turn-live', 2, 'inProgress', 1788927841, NULL);
            """, nil, nil, nil), SQLITE_OK)

        let store = CodexTurnStateStore(databaseURL: databaseURL)
        XCTAssertEqual(store.state(for: "thread-1"), .working(marker: "turn-live", occurredAt: "2026-09-09T04:24:01.000Z"))
    }

    func testProjectedTurnStateDoesNotPreferAnOldOrphanedInProgressTurn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("thread_history_1.sqlite")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE thread_turns (
                thread_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                rollout_ordinal INTEGER NOT NULL,
                status TEXT NOT NULL,
                started_at INTEGER,
                completed_at INTEGER
            );
            INSERT INTO thread_turns VALUES ('thread-1', 'turn-orphaned', 1, 'inProgress', 1788920000, NULL);
            INSERT INTO thread_turns VALUES ('thread-1', 'turn-current', 2, 'completed', 1788927841, 1788927901);
            """, nil, nil, nil), SQLITE_OK)

        let store = CodexTurnStateStore(databaseURL: databaseURL)
        XCTAssertEqual(store.state(for: "thread-1"), .finished(marker: "turn-current", occurredAt: "2026-09-09T04:25:01.000Z"))
    }

    func testProjectedTurnStateSkipsANewerEmptyDatabaseAndRechecksOnEveryScan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let populatedDatabaseURL = directory.appendingPathComponent("thread_history_1.sqlite")
        let emptyDatabaseURL = directory.appendingPathComponent("thread_history_5.sqlite")
        FileManager.default.createFile(atPath: emptyDatabaseURL.path, contents: Data())

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(populatedDatabaseURL.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE thread_turns (
                thread_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                rollout_ordinal INTEGER NOT NULL,
                status TEXT NOT NULL,
                started_at INTEGER,
                completed_at INTEGER
            );
            INSERT INTO thread_turns VALUES ('thread-1', 'turn-live', 1, 'inProgress', 1788927841, NULL);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = CodexTurnStateStore(codexHome: directory)
        XCTAssertEqual(store.state(for: "thread-1"), .working(marker: "turn-live", occurredAt: "2026-09-09T04:24:01.000Z"))
    }

    func testStateResolutionUsesTheNewestObservationAcrossProjectionAndRollout() {
        let oldProjection = LocalSessionState.stale(marker: "turn-old", occurredAt: "2026-09-06T21:48:15.000Z")
        let liveRollout = LocalSessionState.working(marker: "turn-live", occurredAt: "2026-09-09T04:19:59.864Z")

        XCTAssertEqual(mostRecentLocalSessionState(oldProjection, liveRollout), liveRollout)
        XCTAssertEqual(mostRecentLocalSessionState(.unknown, liveRollout), liveRollout)
        XCTAssertEqual(mostRecentLocalSessionState(.working(marker: "unknown-time", occurredAt: nil), liveRollout), liveRollout)
    }

    func testStateResolutionPrefersANewerCompletedTurnOverALaterReplayFromAnOlderTurn() {
        let projectedCompletion = LocalSessionState.finished(marker: "01a07e94-6801-7430-9260-429bcebe42c7", occurredAt: "2026-09-08T01:19:41.218Z")
        let delayedOldReplay = LocalSessionState.working(marker: "01a07e64-7e17-7790-8333-106c10556b16", occurredAt: "2026-09-08T03:07:16.863Z")

        XCTAssertEqual(mostRecentLocalSessionState(projectedCompletion, delayedOldReplay), projectedCompletion)
    }
}
