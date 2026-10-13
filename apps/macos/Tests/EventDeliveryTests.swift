import XCTest
@testable import StatusWatchr

final class EventDeliveryTests: XCTestCase {
    private func fixture(title: String = "", id: String = "event") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["eventId": id, "sessionId": "thread:run", "title": title, "status": "finished"])
    }

    func testTitleNormalizationMatchesServerUTF16Limit() {
        XCTAssertEqual(activityTitle(nil, " \n "), "Untitled task")
        XCTAssertEqual(activityTitle(" ", " Real title "), "Real title")
        XCTAssertEqual(activityTitle(String(repeating: "😀", count: 500)).utf16.count, 500)
        XCTAssertFalse(activityTitle("a" + String(repeating: "\u{301}", count: 501)).isEmpty)
    }

    @MainActor
    func testRestartRecoversBlankQueuedEventWithoutChangingIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try fixture()
        try EventOutbox(directory: directory).enqueue(id: "event", body: original)
        let outbox = EventOutbox(directory: directory)
        var delivered = 0
        let result = await deliverBatch(outbox: outbox, shouldContinue: { true }) { body in
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(event["title"], "Untitled task")
            XCTAssertEqual(event["eventId"], "event")
            XCTAssertEqual(event["sessionId"], "thread:run")
            XCTAssertEqual(try Data(contentsOf: outbox.pending()[0]), original)
            delivered += 1
            return 202
        }
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(result.sent, 1)
        XCTAssertEqual(result.pending, 0)
        XCTAssertNil(result.error)
    }

    @MainActor
    func testBadEventCannotBlockHealthyEventAndIsRetained() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = EventOutbox(directory: directory)
        try outbox.enqueue(id: "bad", body: fixture(id: "bad"))
        try outbox.enqueue(id: "good", body: fixture(id: "good"))
        try outbox.enqueue(id: "corrupt", body: Data("not-json".utf8))
        let result = await deliverBatch(outbox: outbox, shouldContinue: { true }) { body in
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            return event["eventId"] == "bad" ? 400 : 202
        }
        XCTAssertEqual(result.sent, 1)
        XCTAssertEqual(result.pending, 2)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("bad.json").path))
    }

    @MainActor
    func testAuthenticationAndServerErrorsStopBatchWithoutDeleting() async throws {
        for status in [401, 403, 429, 503] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let outbox = EventOutbox(directory: directory)
            try outbox.enqueue(id: "a", body: fixture())
            try outbox.enqueue(id: "b", body: fixture())
            var calls = 0
            let result = await deliverBatch(outbox: outbox, shouldContinue: { true }) { _ in calls += 1; return status }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(result.pending, 2)
            XCTAssertEqual(result.error, deliveryRejectionMessage(status))
        }
    }

    @MainActor
    func testOfflineThenReconnectAndNewerHeartbeatPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = EventOutbox(directory: directory)
        try outbox.enqueue(id: "event", body: fixture())
        let offline = await deliverBatch(outbox: outbox, shouldContinue: { true }) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(offline.pending, 1)
        let newer = try fixture(title: "Renamed task")
        let recovered = await deliverBatch(outbox: outbox, shouldContinue: { true }) { _ in
            try outbox.enqueue(id: "event", body: newer)
            return 202
        }
        XCTAssertEqual(recovered.sent, 1)
        XCTAssertEqual(recovered.pending, 1)
        XCTAssertEqual(try Data(contentsOf: outbox.pending()[0]), newer)
    }
}
