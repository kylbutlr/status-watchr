import SQLite3
import XCTest
@testable import StatusWatchr

final class AttentionResolutionTests: XCTestCase {
    @MainActor func testUnresolvedPermissionHookAloneDoesNotClaimUserAttention() async throws {
        let (home, history, controller) = try makeFixture()
        defer {
            controller.stop()
            sqlite3_close(history)
            try? FileManager.default.removeItem(at: home)
        }
        controller.start()
        controller.handleHook(Data(#"{"hook_event_name":"PermissionRequest","session_id":"thread-1","turn_id":"turn-1","tool_name":"Bash"}"#.utf8))
        try await Task.sleep(for: .milliseconds(550))

        XCTAssertTrue(controller.attentionConversations.isEmpty)
        XCTAssertEqual(controller.state, .connected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("attention/attention.json").path))
    }

    func testPreviouslyPersistedHookAttentionIsDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AttentionStateStore(directory: directory)
        try store.save(["thread-1": PendingAttention(turn: "turn-1", marker: "old-marker", tool: "Bash")])

        try discardUnconfirmedAttention(store)

        XCTAssertTrue(try store.load().isEmpty)
    }

    @MainActor func testCompletedBashBeforeConfirmationDoesNotClaimAttention() async throws {
        let (home, history, controller) = try makeFixture()
        defer {
            controller.stop()
            sqlite3_close(history)
            try? FileManager.default.removeItem(at: home)
        }
        controller.start()
        controller.handleHook(Data(#"{"hook_event_name":"PermissionRequest","session_id":"thread-1","turn_id":"turn-1","tool_name":"Bash"}"#.utf8))

        try await Task.sleep(for: .milliseconds(50))
        let completedAt = Int(Date().timeIntervalSince1970 * 1_000)
        XCTAssertEqual(sqlite3_exec(history, "INSERT INTO thread_items VALUES ('thread-1', 'turn-1', 'commandExecution', \(completedAt), \(completedAt))", nil, nil, nil), SQLITE_OK)
        try await Task.sleep(for: .milliseconds(550))

        XCTAssertTrue(controller.attentionConversations.isEmpty)
        XCTAssertEqual(controller.state, .connected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("attention/attention.json").path))
    }

    @MainActor func testUnrelatedProgressCannotTurnAnAmbiguousHookIntoAttention() async throws {
        let (home, history, controller) = try makeFixture()
        defer {
            controller.stop()
            sqlite3_close(history)
            try? FileManager.default.removeItem(at: home)
        }
        controller.start()
        controller.handleHook(Data(#"{"hook_event_name":"PermissionRequest","session_id":"thread-1","turn_id":"turn-1","tool_name":"Bash"}"#.utf8))
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(controller.state, .connected)
        XCTAssertTrue(controller.attentionConversations.isEmpty)

        let oldTime = Int((Date().timeIntervalSince1970 - 30) * 1_000)
        XCTAssertEqual(sqlite3_exec(history, "INSERT INTO thread_items VALUES ('thread-1', 'turn-1', 'commandExecution', \(oldTime), \(oldTime))", nil, nil, nil), SQLITE_OK)
        let laterTime = Int(Date().timeIntervalSince1970 * 1_000)
        XCTAssertEqual(sqlite3_exec(history, "INSERT INTO thread_items VALUES ('thread-1', 'turn-1', 'reasoning', \(laterTime), \(laterTime))", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(history, "INSERT INTO thread_items VALUES ('thread-1', 'other-turn', 'commandExecution', \(laterTime), \(laterTime))", nil, nil, nil), SQLITE_OK)
        controller.scheduledLocalScan()
        XCTAssertEqual(controller.state, .connected)
        XCTAssertTrue(controller.attentionConversations.isEmpty)

        XCTAssertEqual(sqlite3_exec(history, "INSERT INTO thread_items VALUES ('thread-1', 'turn-1', 'commandExecution', \(laterTime), NULL)", nil, nil, nil), SQLITE_OK)
        controller.scheduledLocalScan()
        XCTAssertEqual(controller.state, .connected)
        XCTAssertTrue(controller.attentionConversations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("attention/attention.json").path))
    }

    @MainActor private func makeFixture() throws -> (URL, OpaquePointer, ConnectorController) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var inventory: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &inventory) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        let inventoryResult = sqlite3_exec(inventory, """
            CREATE TABLE threads (id TEXT, name TEXT, title TEXT, cwd TEXT, rollout_path TEXT, archived INTEGER, updated_at INTEGER);
            INSERT INTO threads VALUES ('thread-1', 'Fixture', '', '', NULL, 0, 1);
            """, nil, nil, nil)
        sqlite3_close(inventory)
        guard inventoryResult == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }

        var history: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("thread_history_1.sqlite").path, &history) == SQLITE_OK,
              let history else { throw CocoaError(.fileReadUnknown) }
        guard sqlite3_exec(history, """
            CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, status TEXT, started_at INTEGER, completed_at INTEGER);
            CREATE TABLE thread_items (thread_id TEXT, turn_id TEXT, item_type TEXT, started_at_ms INTEGER, completed_at_ms INTEGER);
            INSERT INTO thread_turns VALUES ('thread-1', 'turn-1', 1, 'inProgress', 1788927841, NULL);
            """, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(history)
            throw CocoaError(.fileReadUnknown)
        }
        let attentionStore = AttentionStateStore(directory: home.appendingPathComponent("attention"))
        let controller = ConnectorController(
            diagnostics: DiagnosticHistory(directory: home.appendingPathComponent("diagnostics")),
            previewOnly: true,
            codexHome: home,
            attentionStateStore: attentionStore,
            confirmationDelay: 0.4
        )
        return (home, history, controller)
    }
}
