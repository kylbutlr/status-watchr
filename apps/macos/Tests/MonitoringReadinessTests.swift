import XCTest
import SQLite3
@testable import StatusWatchr

final class MonitoringReadinessTests: XCTestCase {
    func testUnnamedInventoryHasSafeFallbackWithoutReadingPrompt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
          CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, archived INTEGER, updated_at INTEGER);
          INSERT INTO threads VALUES ('unnamed', NULL, '', '/test', 0, 3);
          INSERT INTO threads VALUES ('spaces', '  ', 'Actual title', '/test', 0, 2);
          INSERT INTO threads VALUES ('missing', NULL, NULL, '/test', 0, 1);
          """, nil, nil, nil), SQLITE_OK)
        let rows = try XCTUnwrap(CodexThreadStore(codexHome: directory).threads())
        XCTAssertEqual(rows[0]["title"] as? String, "Untitled task")
        XCTAssertEqual(rows[1]["title"] as? String, "Actual title")
        XCTAssertEqual(rows[2]["title"] as? String, "Untitled task")
    }

    func testDeliveryRetryBacksOffWithoutBlockingLocalObservation() {
        XCTAssertEqual(connectorRetryDelay(failures: 1), 10)
        XCTAssertEqual(connectorRetryDelay(failures: 3), 40)
        XCTAssertEqual(connectorRetryDelay(failures: 20), 300)
    }

    func testAttentionIdentitySurvivesRestartAndExpires() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pending = PendingAttention(turn: "run", marker: "request", tool: "Bash")
        try AttentionStateStore(directory: directory).save(["thread": pending])
        XCTAssertEqual(try AttentionStateStore(directory: directory).load()["thread"], pending)
        XCTAssertTrue(try AttentionStateStore(directory: directory).load(now: Date().addingTimeInterval(8 * 86_400)).isEmpty)
        try AttentionStateStore(directory: directory).save([:])
        XCTAssertTrue(try AttentionStateStore(directory: directory).load().isEmpty)
    }

    func testThreadInventorySelectsMetadataWithoutPromptColumns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
          CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, archived INTEGER, updated_at INTEGER, preview TEXT, first_user_message TEXT);
          INSERT INTO threads VALUES ('thread', 'Approved title', 'Fallback title', '/projects/test', 0, 1, 'SECRET_PREVIEW', 'SECRET_PROMPT');
          """, nil, nil, nil), SQLITE_OK)
        let threads = try XCTUnwrap(CodexThreadStore(codexHome: directory).threads())
        XCTAssertEqual(threads.first?["title"] as? String, "Approved title")
        XCTAssertFalse(String(describing: threads).contains("SECRET"))
        XCTAssertNil(CodexThreadStore(codexHome: directory.appendingPathComponent("missing")).threads())
    }

    func testLiveMetadataSourceWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["WATCHR_VERIFY_LOCAL_METADATA"] == "1",
              let threadID = ProcessInfo.processInfo.environment["CODEX_THREAD_ID"] else { throw XCTSkip("Live source check is opt-in.") }
        let threads = try XCTUnwrap(CodexThreadStore().threads())
        XCTAssertTrue(threads.contains { $0["id"] as? String == threadID })
        let history = try XCTUnwrap(CodexTurnStateStore().histories(forThreads: threads)[threadID])
        if case .working = history.first {} else { XCTFail("Current task must resolve to its active run") }
        XCTAssertTrue(history.contains { if case .finished = $0 { true } else { false } })
    }

    func testHookReceiverStripsBodiesAndRejectsBrowserRequests() throws {
        let body = Data("{\"hook_event_name\":\"Stop\",\"session_id\":\"thread\",\"turn_id\":\"run\",\"prompt\":\"SECRET_PROMPT\",\"tool_response\":\"SECRET_OUTPUT\"}".utf8)
        func request(origin: String = "", method: String = "POST /codex-hook") -> Data {
            Data("\(method) HTTP/1.1\r\nContent-Type: application/json\r\n\(origin)Content-Length: \(body.count)\r\n\r\n".utf8) + body
        }
        let sanitized = try XCTUnwrap(CodexHookServer.parseRequest(request()))
        XCTAssertFalse(String(decoding: sanitized, as: UTF8.self).contains("SECRET"))
        XCTAssertNil(CodexHookServer.parseRequest(request(origin: "Origin: https://attacker.test\r\n")))
        XCTAssertNil(CodexHookServer.parseRequest(request(method: "GET /codex-hook")))
        XCTAssertNil(CodexHookServer.parseRequest(request(method: "POST /other")))
    }

    private func inventory(trust: String = "trusted", enabled: Bool = true) -> [[String: Any]] {
        CodexHookInstaller.eventNames.map { ["command": CodexHookInstaller.command, "eventName": $0.prefix(1).lowercased() + $0.dropFirst(), "trustStatus": trust, "enabled": enabled] }
    }

    func testInstalledButUntrustedHooksAreNotReady() {
        XCTAssertEqual(HookReadiness.inspect(["data": [["hooks": inventory(trust: "untrusted")]]]), .untrusted)
        XCTAssertEqual(HookReadiness.inspect(["data": [["hooks": inventory(enabled: false)]]]), .untrusted)
        XCTAssertEqual(HookReadiness.inspect(["data": [["hooks": inventory()]]]), .ready)
    }

    func testDuplicateDefinitionsCannotHideMissingEvents() {
        let one = inventory()[0]
        XCTAssertEqual(HookReadiness.inspect(["data": [["hooks": Array(repeating: one, count: 10)]]]), .missing)
        XCTAssertEqual(HookReadiness.inspect([:]), .missing)
    }

    func testOutboxSurvivesRestartWithoutNetworkAndExpiresOnlyItsOwnEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = EventOutbox(directory: directory)
        let body = Data("{\"status\":\"finished\"}".utf8)
        try first.enqueue(id: "event-1", body: body)
        let second = EventOutbox(directory: directory)
        XCTAssertEqual(try second.pending().count, 1)
        XCTAssertEqual(try Data(contentsOf: second.pending()[0]), body)
        try second.enqueue(id: "event-1", body: body)
        XCTAssertEqual(try second.pending().count, 1)
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        XCTAssertEqual(try second.pending(now: Date().addingTimeInterval(8 * 86_400)).count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertThrowsError(try second.enqueue(id: "../outside", body: body))
    }

    func testOutboxFilesAreOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = EventOutbox(directory: directory)
        try outbox.enqueue(id: "event", body: Data("{}".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: outbox.pending()[0].path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
