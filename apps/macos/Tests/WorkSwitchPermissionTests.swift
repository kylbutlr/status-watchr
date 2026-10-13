import XCTest
@testable import StatusWatchr

final class WorkSwitchPermissionTests: XCTestCase {
    @MainActor func testConfirmedOffSkipsScheduledCodexReadsButPendingStillObserves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let diagnostics = DiagnosticHistory(directory: directory.appendingPathComponent("diagnostics"))
        let controller = ConnectorController(diagnostics: diagnostics, previewOnly: true, codexHome: directory)
        controller.start()
        defer { controller.stop() }

        controller.acceptWorkPermission(WorkSwitchPermission(configured: true, state: "standby", revision: 1, leaseSeconds: 60))
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.state, .paused)
        let failureCount = diagnostics.entries.filter { $0.operation == .localSource && $0.category != .recovered }.count
        controller.scheduledInventoryScan()
        XCTAssertNil(controller.sourceFreshness.degradedSince)
        XCTAssertEqual(diagnostics.entries.filter { $0.operation == .localSource && $0.category != .recovered }.count, failureCount)
        controller.handleHook(Data(#"{"hook_event_name":"Stop","session_id":"thread","turn_id":"run"}"#.utf8))
        XCTAssertNil(controller.lastHookAt)

        controller.acceptWorkPermission(WorkSwitchPermission(configured: true, state: "unavailable", revision: 2, leaseSeconds: 0))
        XCTAssertNotNil(controller.sourceFreshness.degradedSince)
        XCTAssertTrue(diagnostics.entries.contains { $0.operation == .localSource && $0.category == .inventoryDatabaseMissing })
    }

    @MainActor func testOffToOnScansImmediatelyAndResumesHookProcessing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = ConnectorController(diagnostics: DiagnosticHistory(directory: directory.appendingPathComponent("diagnostics")),
                                             previewOnly: true, codexHome: directory)
        controller.start()
        defer { controller.stop() }
        controller.acceptWorkPermission(WorkSwitchPermission(configured: true, state: "standby", revision: 1, leaseSeconds: 60))
        XCTAssertNil(controller.sourceFreshness.degradedSince)

        controller.acceptWorkPermission(WorkSwitchPermission(configured: true, state: "active", revision: 2, leaseSeconds: 60))
        XCTAssertNotNil(controller.sourceFreshness.degradedSince)
        XCTAssertEqual(controller.state, .failed("Local run metadata is unavailable."))
        controller.handleHook(Data(#"{"hook_event_name":"Stop","session_id":"thread","turn_id":"run"}"#.utf8))
        XCTAssertNotNil(controller.lastHookAt)
    }

    func testPermissionRequiresFreshWallAndMonotonicLease() {
        let now = Date(timeIntervalSince1970: 100)
        var lease = WorkSwitchLease()
        XCTAssertFalse(lease.allowsWork(now: now, uptime: 100))
        lease.accept(WorkSwitchPermission(configured: true, state: "active", revision: 1, leaseSeconds: 60), elapsed: 5, now: now, uptime: 100)
        XCTAssertTrue(lease.allowsWork(now: now, uptime: 100))
        XCTAssertFalse(lease.isConfirmedStandby(now: now, uptime: 100))
        XCTAssertFalse(lease.allowsWork(now: now.addingTimeInterval(56), uptime: 100))
        XCTAssertFalse(lease.allowsWork(now: now.addingTimeInterval(-100), uptime: 156))
        lease.invalidate()
        XCTAssertFalse(lease.allowsWork(now: now, uptime: 100))
        XCTAssertEqual(lease.label, "Switchr: Pending")
    }

    func testConfirmedStandbyExpiresAndPendingDoesNotSuppressLocalObservation() {
        let now = Date(timeIntervalSince1970: 1_000)
        var lease = WorkSwitchLease()
        lease.accept(WorkSwitchPermission(configured: true, state: "standby", revision: 1, leaseSeconds: 60), elapsed: 0, now: now, uptime: 100)
        XCTAssertTrue(lease.isConfirmedStandby(now: now, uptime: 100))
        XCTAssertFalse(lease.isConfirmedStandby(now: now.addingTimeInterval(60), uptime: 100))
        XCTAssertFalse(lease.isConfirmedStandby(now: now, uptime: 160))
        lease.invalidate()
        XCTAssertFalse(lease.isConfirmedStandby(now: now, uptime: 100))
        lease.accept(WorkSwitchPermission(configured: true, state: "standby", revision: 2, leaseSeconds: 0), elapsed: 0)
        XCTAssertEqual(lease.label, "Switchr: Pending")
    }

    func testStandbyEventsCanUpdateTimelineWithoutPhoneAlerts() {
        let start = Date(timeIntervalSince1970: 1_000)
        let interval = DateInterval(start: start, duration: 300)
        let formatter = ISO8601DateFormatter()
        XCTAssertFalse(occurredDuringStandby(formatter.string(from: start.addingTimeInterval(-1)), interval: interval))
        XCTAssertTrue(occurredDuringStandby(formatter.string(from: start.addingTimeInterval(120)), interval: interval))
        XCTAssertFalse(occurredDuringStandby(formatter.string(from: start.addingTimeInterval(301)), interval: interval))
    }
    @MainActor func testOffPreservesOutboxAndOnDeliversSameEventOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = EventOutbox(directory: directory)
        let body = try JSONSerialization.data(withJSONObject: ["eventId": "completion", "title": "Task", "status": "finished"])
        try outbox.enqueue(id: "completion", body: body)
        var lease = WorkSwitchLease()
        lease.accept(WorkSwitchPermission(configured: true, state: "standby", revision: 1, leaseSeconds: 60), elapsed: 0)
        var sends = 0
        let paused = await deliverBatch(outbox: outbox, shouldContinue: { lease.allowsWork() }) { _ in sends += 1; return 202 }
        XCTAssertEqual(sends, 0); XCTAssertEqual(paused.pending, 1)
        XCTAssertEqual(try Data(contentsOf: outbox.pending()[0]), body)
        lease.accept(WorkSwitchPermission(configured: true, state: "active", revision: 2, leaseSeconds: 60), elapsed: 0)
        let resumed = await deliverBatch(outbox: outbox, shouldContinue: { lease.allowsWork() }) { _ in sends += 1; return 202 }
        XCTAssertEqual(sends, 1); XCTAssertEqual(resumed.pending, 0)
    }
}
