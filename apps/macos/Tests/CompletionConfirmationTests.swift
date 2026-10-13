import XCTest
import SQLite3
@testable import StatusWatchr

final class CompletionConfirmationTests: XCTestCase {
    private func execute(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func fixture(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try execute(directory.appendingPathComponent("state_5.sqlite"), """
            CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, archived INTEGER, updated_at INTEGER);
            INSERT INTO threads VALUES ('thread', 'Task', '', '/test', 0, 100);
            """)
        try execute(directory.appendingPathComponent("thread_history_1.sqlite"), """
            CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, started_at INTEGER, completed_at INTEGER, rollout_ordinal INTEGER);
            INSERT INTO thread_turns VALUES ('thread', 'run', 'inProgress', 10, NULL, 1);
            """)
    }

    @MainActor func testCompletionIsHeldBeforeQueuedFollowUpCanResume() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { events.append($0) })
        controller.start()
        defer { controller.stop() }
        controller.handleHook(Data(#"{"hook_event_name":"Stop","session_id":"thread","turn_id":"run"}"#.utf8))
        controller.handleHook(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"thread","turn_id":"next"}"#.utf8))
        XCTAssertFalse(events.contains { $0["status"] as? String == "finished" && $0["notificationEligible"] as? Bool != false },
                       "A queued follow-up must resume before a completion becomes notification eligible")
        try execute(directory.appendingPathComponent("thread_history_1.sqlite"), "UPDATE thread_turns SET status='completed', completed_at=11;")
        controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
        XCTAssertEqual(events.filter { $0["status"] as? String == "finished" }.count, 1)
        XCTAssertEqual(events.last?["notificationEligible"] as? Bool, false, "A start hook must suppress even before SQLite catches up")
    }

    @MainActor func testSubtaskCompletionStaysQuietWhileParentWorksAndParentFinalStillAlerts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try subtaskFixture(directory)
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { events.append($0) })
        controller.start()
        defer { controller.stop() }
        controller.handleHook(Data(#"{"hook_event_name":"Stop","session_id":"child","turn_id":"child-run"}"#.utf8))
        controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
        let children = events.filter { $0["threadId"] as? String == "child" && $0["status"] as? String == "finished" }
        XCTAssertFalse(children.isEmpty, "Keep the subtask completion in the dashboard")
        XCTAssertTrue(children.allSatisfy { $0["notificationEligible"] as? Bool == false },
                      "A completed subtask does not need the owner while its parent still works")
        try execute(directory.appendingPathComponent("state_5.sqlite"), "UPDATE threads SET name='Renamed parent' WHERE id='thread';")
        controller.refresh()
        controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
        XCTAssertTrue(events.filter { $0["threadId"] as? String == "child" && $0["status"] as? String == "finished" }
            .allSatisfy { $0["notificationEligible"] as? Bool == false }, "Title repair cannot restore a suppressed child alert")
        try execute(directory.appendingPathComponent("thread_history_1.sqlite"), "UPDATE thread_turns SET status='completed', completed_at=20 WHERE thread_id='thread';")
        controller.refresh()
        controller.confirmPendingCompletions(now: Date().addingTimeInterval(4))
        XCTAssertFalse(events.contains { $0["threadId"] as? String == "thread" && $0["status"] as? String == "finished" })
        controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
        XCTAssertTrue(events.contains { $0["threadId"] as? String == "thread" && $0["status"] as? String == "finished" && $0["notificationEligible"] as? Bool != false })
        XCTAssertTrue(events.filter { $0["threadId"] as? String == "child" && $0["status"] as? String == "finished" }
            .allSatisfy { $0["notificationEligible"] as? Bool == false }, "The suppressed child must not replay when its parent finishes")
    }

    private func subtaskFixture(_ directory: URL) throws {
        try fixture(directory)
        try execute(directory.appendingPathComponent("state_5.sqlite"), """
            ALTER TABLE threads ADD COLUMN source TEXT;
            ALTER TABLE threads ADD COLUMN thread_source TEXT;
            INSERT INTO threads VALUES ('child', NULL, '', '/test', 0, 101,
              '{"subagent":{"thread_spawn":{"parent_thread_id":"thread","agent_path":"/root/review"}}}', 'subagent');
            """)
        try execute(directory.appendingPathComponent("thread_history_1.sqlite"), "INSERT INTO thread_turns VALUES ('child', 'child-run', 'completed', 11, 12, 1);")
    }

    @MainActor func testSubtaskCanAlertWithIdleParentOutsideDiscoveryWindow() throws {
        try checkSubtask { directory, _ in
            try self.execute(directory.appendingPathComponent("state_5.sqlite"), """
                UPDATE threads SET archived=1 WHERE id='thread';
                UPDATE threads SET updated_at=1000 WHERE id='child';
                WITH RECURSIVE recent(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM recent WHERE n<101)
                INSERT INTO threads(id, name, title, cwd, archived, updated_at)
                SELECT 'recent-' || n, 'Recent', '', '/test', 0, 200+n FROM recent;
                """)
            try self.execute(directory.appendingPathComponent("thread_history_1.sqlite"), "UPDATE thread_turns SET status='completed', completed_at=12 WHERE thread_id='thread';")
            return { events in XCTAssertTrue(events.contains { $0["threadId"] as? String == "child" && $0["status"] as? String == "finished" && $0["notificationEligible"] as? Bool != false }) }
        }
    }

    @MainActor func testSubtaskWaitsForResumedParentHistoryRatherThanOldStableIdentity() throws {
        try checkSubtask { directory, _ in
            let parent = "00000000-0000-4000-8000-000000000001"
            let resumed = "00000000-0000-4000-8000-000000000002"
            try self.execute(directory.appendingPathComponent("state_5.sqlite"), """
                ALTER TABLE threads ADD COLUMN rollout_path TEXT;
                UPDATE threads SET id='\(parent)', rollout_path='/ignored/rollout-2026-10-11T12-00-00-\(parent)_\(resumed).jsonl' WHERE id='thread';
                UPDATE threads SET source='{"subagent":{"thread_spawn":{"parent_thread_id":"\(parent)"}}}' WHERE id='child';
                """)
            try self.execute(directory.appendingPathComponent("thread_history_1.sqlite"), """
                UPDATE thread_turns SET thread_id='\(parent)', status='completed', completed_at=11 WHERE thread_id='thread';
                INSERT INTO thread_turns VALUES ('\(resumed)', 'resumed-run', 'inProgress', 13, NULL, 2);
                """)
            return { events in XCTAssertTrue(events.filter { $0["threadId"] as? String == "child" && $0["status"] as? String == "finished" }.allSatisfy { $0["notificationEligible"] as? Bool == false }) }
        }
    }

    @MainActor func testNestedSubtaskStaysQuietWhileRootStillWorks() throws {
        try checkSubtask { directory, _ in
            try self.execute(directory.appendingPathComponent("state_5.sqlite"), """
                INSERT INTO threads VALUES ('middle', 'Middle', '', '/test', 0, 102,
                  '{"subagent":{"thread_spawn":{"parent_thread_id":"thread"}}}', 'subagent');
                UPDATE threads SET source='{"subagent":{"thread_spawn":{"parent_thread_id":"middle"}}}' WHERE id='child';
                """)
            try self.execute(directory.appendingPathComponent("thread_history_1.sqlite"), "INSERT INTO thread_turns VALUES ('middle', 'middle-run', 'completed', 11, 12, 1);")
            return { events in XCTAssertTrue(events.filter { $0["threadId"] as? String == "child" && $0["status"] as? String == "finished" }.allSatisfy { $0["notificationEligible"] as? Bool == false }) }
        }
    }

    @MainActor func testSubtaskMissingOrCyclicParentCannotBecomeNotificationEligible() throws {
        for source in ["{}", #"{"subagent":{"thread_spawn":{"parent_thread_id":"missing"}}}"#,
                       #"{"subagent":{"thread_spawn":{"parent_thread_id":"child"}}}"#] {
            try checkSubtask { directory, _ in
                try self.execute(directory.appendingPathComponent("state_5.sqlite"), "UPDATE threads SET source='\(source)' WHERE id='child';")
                return { events in XCTAssertTrue(events.filter { $0["threadId"] as? String == "child" && $0["status"] as? String == "finished" }.allSatisfy { $0["notificationEligible"] as? Bool == false }) }
            }
        }
    }

    @MainActor func testParentStartBeforeProjectionSuppressesChildCompletion() throws {
        try checkSubtask(afterStart: { controller in
            // The parent follow-up is already running, but only the old final turn is projected.
            controller.handleHook(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"thread","turn_id":"next"}"#.utf8))
        }) { directory, _ in
            try self.execute(directory.appendingPathComponent("thread_history_1.sqlite"), "UPDATE thread_turns SET status='completed', completed_at=11 WHERE thread_id='thread';")
            return { events in XCTAssertTrue(events.filter { $0["threadId"] as? String == "child" && $0["status"] as? String == "finished" }.allSatisfy { $0["notificationEligible"] as? Bool == false }) }
        }
    }

    @MainActor private func checkSubtask(afterStart: (ConnectorController) -> Void = { _ in }, _ setup: (URL, ConnectorController) throws -> (([[String: Any]]) -> Void)) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try subtaskFixture(directory)
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { events.append($0) })
        let verify = try setup(directory, controller)
        controller.start()
        defer { controller.stop() }
        afterStart(controller)
        controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
        XCTAssertFalse(events.filter { $0["threadId"] as? String == "child" && $0["status"] as? String == "finished" }.isEmpty)
        verify(events)
    }

    @MainActor func testFreshMetadataSuppressesResumeWithoutAStartHook() throws {
        try checkCompletion { directory, controller, events in
            try self.execute(directory.appendingPathComponent("thread_history_1.sqlite"), """
                UPDATE thread_turns SET status='completed', completed_at=11;
                INSERT INTO thread_turns VALUES ('thread', 'next', 'inProgress', 12, NULL, 2);
                """)
            controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
            XCTAssertEqual(events().last?["notificationEligible"] as? Bool, false)
            XCTAssertEqual(events().last?["turnId"] as? String, "run", "Keep the original completion in history")
        }
    }

    @MainActor func testFollowUpStartBeforeDelayedStopSuppressesCompletionWithLaggingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { events.append($0) })
        controller.start()
        defer { controller.stop() }
        controller.handleHook(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"thread","turn_id":"next"}"#.utf8))
        controller.handleHook(Data(#"{"hook_event_name":"Stop","session_id":"thread","turn_id":"run"}"#.utf8))
        // Projection has the old completion, but not the follow-up already observed by hook.
        try execute(directory.appendingPathComponent("thread_history_1.sqlite"), "UPDATE thread_turns SET status='completed', completed_at=11;")
        controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
        let completions = events.filter { $0["status"] as? String == "finished" }
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?["notificationEligible"] as? Bool, false,
                       "A delayed Stop must not alert while a follow-up is already running")
    }

    @MainActor func testTitleRefreshCannotRestoreEligibilityAfterFollowUpStarts() throws {
        try checkCompletion { directory, controller, events in
            try self.execute(directory.appendingPathComponent("thread_history_1.sqlite"), "UPDATE thread_turns SET status='completed', completed_at=11;")
            controller.refresh() // Both the Stop hook and history poll are pending.
            controller.handleHook(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"thread","turn_id":"next"}"#.utf8))
            try self.execute(directory.appendingPathComponent("state_5.sqlite"), "UPDATE threads SET name='Renamed task';")
            controller.refresh()
            controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
            let completions = events().filter { $0["status"] as? String == "finished" }
            XCTAssertFalse(completions.isEmpty)
            XCTAssertTrue(completions.allSatisfy { $0["notificationEligible"] as? Bool == false },
                          "Title repair must not undo queued-follow-up suppression")
        }
    }

    @MainActor func testStartSeenBeforeHistoryDiscoverySuppressesOldCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        let database = directory.appendingPathComponent("thread_history_1.sqlite")
        try execute(database, "DELETE FROM thread_turns;")
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { events.append($0) })
        controller.start()
        defer { controller.stop() }
        controller.handleHook(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"thread","turn_id":"next"}"#.utf8))
        controller.handleHook(Data(#"{"hook_event_name":"Stop","session_id":"thread","turn_id":"run"}"#.utf8))
        try execute(database, "INSERT INTO thread_turns VALUES ('thread', 'run', 'inProgress', 10, NULL, 1);")
        controller.refresh() // The first recovered row is older than the live Start.
        try execute(database, "UPDATE thread_turns SET status='completed', completed_at=11;")
        controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
        XCTAssertEqual(events.last?["notificationEligible"] as? Bool, false)
    }

    @MainActor func testLaggingPollCannotUndoResumeAndLatestCompletionStillAlerts() throws {
        try checkCompletion { directory, controller, events in
            controller.handleHook(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"thread","turn_id":"next"}"#.utf8))
            // A stale poll still reports the previous working turn after the new start.
            controller.refresh()
            try self.execute(directory.appendingPathComponent("thread_history_1.sqlite"), "UPDATE thread_turns SET status='completed', completed_at=11;")
            controller.refresh()
            controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
            let oldCompletions = events().filter { $0["status"] as? String == "finished" && $0["turnId"] as? String == "run" }
            XCTAssertFalse(oldCompletions.isEmpty)
            XCTAssertTrue(oldCompletions.allSatisfy { $0["notificationEligible"] as? Bool == false })

            try self.execute(directory.appendingPathComponent("thread_history_1.sqlite"), "INSERT INTO thread_turns VALUES ('thread', 'next', 'completed', 12, 13, 2);")
            controller.handleHook(Data(#"{"hook_event_name":"Stop","session_id":"thread","turn_id":"next"}"#.utf8))
            controller.confirmPendingCompletions(now: Date().addingTimeInterval(4))
            XCTAssertFalse(events().contains { $0["status"] as? String == "finished" && $0["turnId"] as? String == "next" })
            controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
            XCTAssertEqual(events().filter { $0["status"] as? String == "finished" && $0["turnId"] as? String == "next" && $0["notificationEligible"] as? Bool != false }.count, 1)
        }
    }

    @MainActor func testIdleCompletionWaitsFiveSecondsAndDoesNotRepeatConfirmedEvents() throws {
        try checkCompletion { directory, controller, events in
            try self.execute(directory.appendingPathComponent("thread_history_1.sqlite"), "UPDATE thread_turns SET status='completed', completed_at=11;")
            controller.refresh() // The poll and Stop hook both observed the same completion.
            controller.confirmPendingCompletions(now: Date().addingTimeInterval(4))
            XCTAssertFalse(events().contains { $0["status"] as? String == "finished" })
            controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
            let completions = events().filter { $0["status"] as? String == "finished" }
            XCTAssertFalse(completions.isEmpty)
            XCTAssertTrue(completions.allSatisfy { $0["notificationEligible"] as? Bool != false })
            controller.confirmPendingCompletions(now: Date().addingTimeInterval(10))
            XCTAssertEqual(events().filter { $0["status"] as? String == "finished" }.count, completions.count)
        }
    }

    @MainActor func testRecoveredCompletionIsSuppressedWhenFollowUpAlreadyFinished() throws {
        try checkCompletion { directory, controller, events in
            try self.execute(directory.appendingPathComponent("thread_history_1.sqlite"), """
                UPDATE thread_turns SET status='completed', completed_at=11;
                INSERT INTO thread_turns VALUES ('thread', 'next', 'completed', 12, 13, 2);
                """)
            controller.refresh()
            controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
            let completions = events().filter { $0["status"] as? String == "finished" }
            XCTAssertTrue(completions.contains { $0["turnId"] as? String == "run" && $0["notificationEligible"] as? Bool == false })
            XCTAssertTrue(completions.contains { $0["turnId"] as? String == "next" && $0["notificationEligible"] as? Bool != false })
        }
    }

    @MainActor func testMissingMetadataWaitsForRecovery() throws {
        try checkCompletion { directory, controller, events in
            let database = directory.appendingPathComponent("thread_history_1.sqlite")
            try FileManager.default.removeItem(at: database)
            controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
            XCTAssertFalse(events().contains { $0["status"] as? String == "finished" })
            try self.execute(database, """
                CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, started_at INTEGER, completed_at INTEGER, rollout_ordinal INTEGER);
                INSERT INTO thread_turns VALUES ('thread', 'run', 'completed', 10, 11, 1);
                """)
            controller.confirmPendingCompletions(now: Date().addingTimeInterval(10))
            XCTAssertTrue(events().contains { $0["status"] as? String == "finished" && $0["notificationEligible"] as? Bool != false })
        }
    }

    @MainActor func testStopAndStandbyCancelPendingConfirmation() throws {
        for standby in [false, true] {
            try checkCompletion { _, controller, events in
                if standby {
                    controller.acceptWorkPermission(WorkSwitchPermission(configured: true, state: "standby", revision: 1, leaseSeconds: 60))
                } else { controller.stop() }
                controller.confirmPendingCompletions(now: Date().addingTimeInterval(5))
                XCTAssertFalse(events().contains { $0["status"] as? String == "finished" })
            }
        }
    }

    @MainActor private func checkCompletion(_ check: (URL, ConnectorController, () -> [[String: Any]]) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: directory, eventSink: { events.append($0) })
        controller.start()
        defer { controller.stop() }
        controller.handleHook(Data(#"{"hook_event_name":"Stop","session_id":"thread","turn_id":"run"}"#.utf8))
        try check(directory, controller, { events })
    }
}
