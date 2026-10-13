import XCTest
import SQLite3
@testable import StatusWatchr

final class QuestionRequestTests: XCTestCase {
    private let task = "00000000-0000-4000-8000-000000000001"
    private let history = "00000000-0000-4000-8000-000000000002"

    func testReceiverAcceptsOnlyConfirmedAsyncQuestionsAndDropsContent() throws {
        let payload: [String: Any] = ["hook_event_name": "PostToolUse", "session_id": task,
          "turn_id": "run", "tool_name": "request_user_input_async", "tool_use_id": "call_fixture",
          "tool_input": ["questions": [["title": "SECRET QUESTION", "options": ["SECRET OPTION"]]]],
          "tool_response": ["accepted": true], "prompt": "SECRET PROMPT"]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = Data("POST /codex-hook HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        request.append(body)
        let metadata = try XCTUnwrap(CodexHookServer.parseRequest(request))
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("SECRET"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        XCTAssertEqual(value["questionCount"] as? Int, 1)
        XCTAssertEqual(value["tool_use_id"] as? String, "call_fixture")
        for patch: [String: Any] in [["tool_response": ["accepted": false]], ["tool_response": ["accepted": 1]],
                                  ["tool_name": "Bash"], ["hook_event_name": "PreToolUse"]] {
            XCTAssertTrue(QuestionHookMetadata.extract(payload.merging(patch) { _, new in new }).isEmpty)
        }
    }

    @MainActor func testFiveSecondQuestionSurvivesWorkAndFinishWithoutRepeating() throws {
        try withFixture { home, controller, events in
            controller.handleHook(hook(session: history))
            controller.confirmQuestions(now: Date().addingTimeInterval(4))
            XCTAssertFalse(events().contains { $0["eventType"] as? String == "local/question/opened" })
            controller.handleHook(Data("{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"\(task)\",\"turn_id\":\"run\",\"tool_name\":\"Bash\"}".utf8))
            controller.handleHook(Data("{\"hook_event_name\":\"Stop\",\"session_id\":\"\(task)\",\"turn_id\":\"run\"}".utf8))
            controller.confirmQuestions(now: Date().addingTimeInterval(5))
            controller.confirmQuestions(now: Date().addingTimeInterval(10))
            controller.handleHook(hook(session: history))
            controller.confirmQuestions(now: Date().addingTimeInterval(10))
            let opens = events().filter { $0["eventType"] as? String == "local/question/opened" }
            XCTAssertEqual(opens.count, 1)
            XCTAssertEqual(opens.first?["threadId"] as? String, task)
            XCTAssertEqual(opens.first?["attentionId"] as? String, "call_fixture:0")
            XCTAssertEqual(opens.first?["status"] as? String, "working")
            XCTAssertFalse(String(describing: opens).contains("SECRET"))
            _ = home
        }
    }

    @MainActor func testMatchingAnswerSuppressesQuickAlertAndOtherQuestionRemainsPending() throws {
        try withFixture { home, controller, events in
            controller.handleHook(hook(session: history, count: 2))
            try addAnswer(home, index: 0)
            controller.confirmQuestions(now: Date().addingTimeInterval(5))
            let opens = events().filter { $0["eventType"] as? String == "local/question/opened" }
            XCTAssertEqual(opens.map { $0["attentionId"] as? String }, ["call_fixture:1"])
            XCTAssertTrue(events().contains { $0["eventType"] as? String == "local/question/answered" && $0["attentionId"] as? String == "call_fixture:0" })
            XCTAssertFalse(String(describing: events()).contains("SECRET"))
        }
    }

    @MainActor func testUnavailableAnswerSourceWithholdsAlert() throws {
        try withFixture { home, controller, events in
            controller.handleHook(hook(session: task))
            try FileManager.default.removeItem(at: home.appendingPathComponent("thread_history_1.sqlite"))
            controller.confirmQuestions(now: Date().addingTimeInterval(5))
            XCTAssertFalse(events().contains { $0["eventType"] as? String == "local/question/opened" })
        }
    }

    func testIdentityValidation() throws {
        XCTAssertNil(QuestionAnswerStore.attentionID(#"["request_user_input_async","call_fixture",true]"#))
        XCTAssertNil(QuestionAnswerStore.attentionID(#"["request_user_input_async","call_fixture",0.5]"#))
        XCTAssertNil(QuestionAnswerStore.attentionID(#"["Bash","call_fixture",0]"#))
        XCTAssertNil(QuestionAnswerStore.attentionID(#"["request_user_input_async","call_fixture",64]"#))
    }

    @MainActor func testOrdinaryMessagesAndMalformedReplyEnvelopesDoNotResolveQuestions() throws {
        try withFixture { home, controller, events in
            controller.handleHook(hook(session: history))
            for text in ["Ordinary answer or question", "<send_user_message_question_reply>malformed</send_user_message_question_reply>",
                         "<send_user_message_question_reply>{\"x\":{\"questionItemId\":\"PRIVATE\"}}</send_user_message_question_reply>"] {
                let message: [String: Any] = ["content": [["type": "text", "text": text]]]
                let json = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
                try execute(home.appendingPathComponent("thread_history_1.sqlite"), "INSERT INTO thread_items VALUES ('\(history)', 'run', 'userMessage', \(Int(Date().timeIntervalSince1970*1_000)), '\(json)');")
            }
            controller.confirmQuestions(now: Date().addingTimeInterval(5))
            XCTAssertEqual(events().filter { $0["eventType"] as? String == "local/question/opened" }.count, 1)
            XCTAssertFalse(events().contains { $0["eventType"] as? String == "local/question/answered" })
        }
    }

    @MainActor func testHookBeforeDiscoveryUsesVerifiedMetadataWithoutAddingDashboardLifecycle() throws {
        try withFixture { home, controller, events in
            let other = "00000000-0000-4000-8000-000000000003"
            try execute(home.appendingPathComponent("state_5.sqlite"), "INSERT INTO threads VALUES ('\(other)', 'Other question', '', '/test', 0, 101, NULL);")
            controller.handleHook(hook(session: other))
            controller.confirmQuestions(now: Date().addingTimeInterval(5))
            let opens = events().filter { $0["eventType"] as? String == "local/question/opened" }
            XCTAssertEqual(opens.count, 1)
            XCTAssertEqual(opens.first?["threadId"] as? String, other)
            XCTAssertFalse(events().contains { $0["threadId"] as? String == other && $0["eventType"] as? String != "local/question/opened" })
        }
    }

    private func hook(session: String, count: Int = 1) -> Data {
        Data("{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"\(session)\",\"turn_id\":\"run\",\"tool_name\":\"request_user_input_async\",\"tool_use_id\":\"call_fixture\",\"questionCount\":\(count)}".utf8)
    }

    @MainActor private func withFixture(_ body: (URL, ConnectorController, () -> [[String: Any]]) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try execute(home.appendingPathComponent("state_5.sqlite"), """
          CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, archived INTEGER, updated_at INTEGER, rollout_path TEXT);
          INSERT INTO threads VALUES ('\(task)', 'Question fixture', '', '/test', 0, 100,
            '/test/rollout-2026-10-11T00-00-00-\(task)_\(history).jsonl');
          """)
        try execute(home.appendingPathComponent("thread_history_1.sqlite"), """
          CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, started_at INTEGER, completed_at INTEGER, rollout_ordinal INTEGER);
          CREATE TABLE thread_items(thread_id TEXT, turn_id TEXT, item_type TEXT, created_at_ms INTEGER, item_json TEXT);
          INSERT INTO thread_turns VALUES ('\(history)', 'run', 'inProgress', 10, NULL, 1);
          """)
        var events: [[String: Any]] = []
        let controller = ConnectorController(previewOnly: true, codexHome: home,
            questionAlertsEnabled: true, eventSink: { events.append($0) })
        controller.start()
        defer { controller.stop() }
        try body(home, controller, { events })
    }

    private func addAnswer(_ home: URL, index: Int) throws {
        let identity = String(data: try JSONSerialization.data(withJSONObject: ["request_user_input_async", "call_fixture", index]), encoding: .utf8)!
        let reply = String(data: try JSONSerialization.data(withJSONObject: [["questionItemId": identity, "question": "SECRET QUESTION", "answer": "SECRET ANSWER"]]), encoding: .utf8)!
        let message: [String: Any] = ["content": [["type": "text", "text": "<send_user_message_question_reply>\n\(reply)\n</send_user_message_question_reply>"]]]
        let json = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
        try execute(home.appendingPathComponent("thread_history_1.sqlite"), "INSERT INTO thread_items VALUES ('\(history)', 'run', 'userMessage', \(Int(Date().timeIntervalSince1970 * 1_000)), '\(json)');")
    }

    private func execute(_ url: URL, _ query: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
    }
}
