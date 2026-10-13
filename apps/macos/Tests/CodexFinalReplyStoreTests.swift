import Foundation
import SQLite3
import XCTest
@testable import StatusWatchr

final class CodexFinalReplyStoreTests: XCTestCase {
    private let threadID = "11111111-1111-7111-8111-111111111111"

    func testReadsOnlyTheExactTurnsFinalAnswer() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("sessions/2026/09/25")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rollout = directory.appendingPathComponent("rollout-2026-09-25T10-00-00-\(threadID).jsonl")
        let records: [[String: Any]] = [
            ["type": "turn_context", "payload": ["turn_id": "older"]],
            message("final_answer", "Other turn reply"),
            ["type": "turn_context", "payload": ["turn_id": "target"]],
            message("commentary", "Progress is not the reply"),
            message("final_answer", "**Finished** the watched task. More details follow."),
            ["type": "turn_context", "payload": ["turn_id": "later"]],
            message("final_answer", "Later turn reply")
        ]
        let lines = try records.map { try String(data: JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n"
        try lines.write(to: rollout, atomically: true, encoding: .utf8)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE threads(id TEXT, rollout_path TEXT)", nil, nil, nil), SQLITE_OK)
        let escaped = rollout.path.replacingOccurrences(of: "'", with: "''")
        XCTAssertEqual(sqlite3_exec(database, "INSERT INTO threads VALUES ('\(threadID)', '\(escaped)')", nil, nil, nil), SQLITE_OK)

        let store = CodexFinalReplyStore(codexHome: home)
        XCTAssertEqual(store.preview(threadID: threadID, turnID: "target"), "Finished the watched task. More details follow.")
        XCTAssertNil(store.preview(threadID: threadID, turnID: "missing"))
        XCTAssertNil(store.preview(threadID: "invalid", turnID: "target"))
        let outside = home.appendingPathComponent("rollout-2026-09-25T10-00-00-\(threadID).jsonl")
        try lines.write(to: outside, atomically: true, encoding: .utf8)
        XCTAssertNil(CodexFinalReplyStore.preview(at: outside, codexHome: home, threadID: threadID, turnID: "target"))
    }

    func testSkipsCodeAndBoundsPreview() {
        XCTAssertEqual(CodexFinalReplyStore.previewText("```swift\nlet secret = 1\n```\n# Result\nA short answer."), "A short answer.")
        XCTAssertEqual(CodexFinalReplyStore.previewText("[Open the report](https://example.test/report) for details."), "Open the report for details.")
        XCTAssertEqual(CodexFinalReplyStore.previewText(String(repeating: "😀", count: 200))?.utf16.count, 180)
        XCTAssertNil(CodexFinalReplyStore.previewText("```\ncode only\n```"))
    }

    private func message(_ phase: String, _ text: String) -> [String: Any] {
        ["type": "response_item", "payload": ["type": "message", "role": "assistant", "phase": phase,
                                               "content": [["type": "output_text", "text": text]]]]
    }
}
