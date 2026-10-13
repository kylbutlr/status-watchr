import XCTest
@testable import StatusWatchr

final class ConnectionIntegrationTests: XCTestCase {
    func testIdleAppAnswersHealthAndReportsCurrentPermission() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/confirmation-test/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ConnectionRecorder(app: .watchr, directory: directory, version: "test")
        let health = ConnectionHealth()
        for state in [ConnectionPermission.off, .active] {
            recorder.setPermission(state, revision: 18, remaining: state == .active ? 60 : 0)
            let request = recorder.start(.workState, trigger: .control)
            recorder.finish(request, status: 200)
            recorder.flush()
            XCTAssertFalse(recorder.storageFailed, "Fixture journal must be writable: \(directory.path)")
            for _ in 0..<30 {
                health.refresh()
                try await Task.sleep(for: .milliseconds(100))
                if health.failed(for: .watchr) == false { break }
            }
            XCTAssertEqual(health.failed(for: .watchr), false)
            let history = ConnectionJournal.read(app: .watchr, directory: directory)
            XCTAssertEqual(history.starts.last?.permission, state)
            XCTAssertEqual(history.starts.last?.revision, 18)
            XCTAssertEqual(history.starts.last?.session, history.manifest?.session)
            XCTAssertFalse(history.incomplete)
        }
    }

    @MainActor func testRetriesBelongToTheSameQueuedBody() {
        let attempts = DeliveryAttempts()
        let first = URL(fileURLWithPath: "/fixture/first"), second = URL(fileURLWithPath: "/fixture/second")
        XCTAssertFalse(attempts.begin(first, original: Data("a".utf8)))
        XCTAssertTrue(attempts.begin(first, original: Data("a".utf8)))
        XCTAssertFalse(attempts.begin(second, original: Data("b".utf8)))
        XCTAssertFalse(attempts.begin(first, original: Data("changed".utf8)))
        attempts.completed(first)
        XCTAssertFalse(attempts.begin(first, original: Data("changed".utf8)))
        attempts.retain([])
        XCTAssertFalse(attempts.begin(second, original: Data("b".utf8)))
    }

    @MainActor func testOffRetainsEventAndOnReportsEachDeliveryAttempt() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/connections-test/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = EventOutbox(directory: root.appendingPathComponent("queue"))
        try outbox.enqueue(id: "fixture", body: JSONSerialization.data(withJSONObject: ["eventId":"fixture", "sessionId":"test", "status":"finished", "title":"Private fixture title"]))
        let directory = root.appendingPathComponent("journal")
        let recorder = ConnectionRecorder(app: .watchr, directory: directory, version: "test", automaticFlush: false)
        recorder.setPermission(.off)
        let off = await deliverBatch(outbox: outbox, shouldContinue: { false }) { _ in
            XCTFail("Off must not reach transport"); return 202
        }
        recorder.flush(); XCTAssertEqual(off.pending, 1)
        XCTAssertEqual(ConnectionJournal.read(app: .watchr, directory: directory).starts.count, 0)
        recorder.setPermission(.active, revision: 2, remaining: 60)
        let attempts = DeliveryAttempts()
        for status in [503, 202] {
            _ = await deliverBatch(outbox: outbox, shouldContinue: { true }, attempts: attempts) { _ in
                let attempt = recorder.start(.upload, trigger: .automatic, retry: ConnectionContext.retry)
                recorder.finish(attempt, status: status); return status
            }
        }
        recorder.flush(cleanShutdown: true)
        let history = ConnectionJournal.read(app: .watchr, directory: directory)
        XCTAssertEqual(history.starts.count, 2)
        XCTAssertEqual(history.starts.filter(\.violation).count, 0)
        XCTAssertEqual(history.starts.filter(\.retry).count, 1)
        XCTAssertEqual(try outbox.pending().count, 0)
    }
}
