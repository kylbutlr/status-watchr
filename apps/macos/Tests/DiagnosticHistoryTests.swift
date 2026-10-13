import XCTest
import SQLite3
@testable import StatusWatchr

final class DiagnosticHistoryTests: XCTestCase {
    @MainActor
    func testAttentionTransitionsPersistWithoutConversationDetails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = DiagnosticHistory(directory: directory)
        let categories: [DiagnosticCategory] = [
            .approvalHook, .attentionChanged, .attentionCleared, .appServerAttention,
            .appServerAutoReviewStarted, .appServerAutoReviewCompleted,
            .inventoryDatabaseMissing, .inventoryDatabaseUnavailable, .inventoryQueryFailed, .inventoryReadFailed,
            .turnHistoryDatabaseMissing, .turnHistoryDatabaseUnavailable, .turnHistoryQueryFailed,
            .turnHistoryReadFailed, .turnHistoryEmpty
        ]
        for category in categories {
            history.record(.attention, category: category)
        }
        let restored = DiagnosticHistory(directory: directory)
        XCTAssertEqual(restored.entries.map(\.category), categories)
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: history.file)) as? [[String: Any]])
        let allowed = Set(["operation", "category", "firstSeen", "lastSeen", "queued", "occurrences", "httpStatus", "sqliteCode", "schemaVersion", "databaseVersion"])
        for entry in entries { XCTAssertTrue(Set(entry.keys).isSubset(of: allowed)) }
    }

    @MainActor
    func testPersistenceGroupingRecoveryRetentionAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = DiagnosticHistory(directory: directory, now: now)
        history.record(.delivery, category: .http, httpStatus: 503, queued: 2, now: now)
        history.record(.delivery, category: .http, httpStatus: 503, queued: 3, now: now.addingTimeInterval(10))
        history.flush(now: now.addingTimeInterval(10))
        let restored = DiagnosticHistory(directory: directory, now: now.addingTimeInterval(11))
        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertEqual(restored.entries[0].occurrences, 2)
        XCTAssertEqual(restored.entries[0].queued, 3)
        restored.success(.delivery, now: now.addingTimeInterval(12))
        XCTAssertEqual(restored.entries.last?.category, .recovered)
        restored.success(.delivery, now: now.addingTimeInterval(13))
        XCTAssertEqual(restored.entries.count, 2)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: restored.file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        restored.flush(now: now.addingTimeInterval(8 * 86_400))
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertEqual(String(data: try Data(contentsOf: restored.file), encoding: .utf8), "[\n\n]")
    }

    @MainActor
    func testBoundedHistoryAndSafeErrorClassification() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = DiagnosticHistory(directory: directory)
        for index in 0..<250 {
            history.record(.delivery, category: index.isMultiple(of: 2) ? .http : .offline, httpStatus: 503)
        }
        XCTAssertEqual(history.entries.count, 200)
        let secret = "SECRET_TOKEN_PROMPT_TITLE_SENTINEL"
        let error = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
            userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLStringErrorKey: "https://example.test/" + secret])
        history.record(.collectorHealth, category: DiagnosticHistory.category(for: error), queued: -1)
        XCTAssertEqual(history.entries.last?.category, .timeout)
        XCTAssertEqual(history.entries.last?.queued, 0)
        let text = try String(contentsOf: history.file, encoding: .utf8)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("https://"))
        XCTAssertLessThan(try Data(contentsOf: history.file).count, 262_144)
    }

    @MainActor
    func testSQLiteDetailsAreNumericOnlyAndDistinctFailuresDoNotCoalesce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = DiagnosticHistory(directory: directory)
        let first = CodexSQLiteFailureDetails(resultCode: SQLITE_ERROR, schemaVersion: 2, databaseVersion: 5)
        let second = CodexSQLiteFailureDetails(resultCode: SQLITE_BUSY, schemaVersion: 2, databaseVersion: 5)
        history.record(.localSource, category: .inventoryQueryFailed, sqliteDetails: first)
        history.record(.localSource, category: .inventoryQueryFailed, sqliteDetails: second)

        XCTAssertEqual(history.entries.count, 2)
        let restored = DiagnosticHistory(directory: directory)
        XCTAssertEqual(restored.entries.map(\.sqliteCode), [SQLITE_ERROR, SQLITE_BUSY])
        let export = directory.appendingPathComponent("export.json")
        try history.export(to: export)
        let text = try String(contentsOf: export, encoding: .utf8)
        XCTAssertTrue(text.contains("\"sqliteCode\""))
        XCTAssertTrue(text.contains("\"schemaVersion\""))
        XCTAssertTrue(text.contains("\"databaseVersion\""))
        XCTAssertFalse(text.contains("sqliteMessage"))
        XCTAssertFalse(text.contains("databasePath"))
        history.record(.delivery, category: .connection, sqliteDetails: first)
        XCTAssertNil(history.entries.last?.sqliteCode)
    }

    @MainActor
    func testExistingDiagnosticsWithoutSQLiteFieldsRemainReadable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = #"[{"firstSeen":"2027-01-15T08:00:00Z","lastSeen":"2027-01-15T08:00:00Z","operation":"localSource","category":"inventoryQueryFailed","queued":0,"occurrences":1}]"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("history.json"))

        let history = DiagnosticHistory(directory: directory, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertNil(history.entries[0].sqliteCode)
        XCTAssertNil(history.entries[0].schemaVersion)
        XCTAssertNil(history.entries[0].databaseVersion)
    }

    @MainActor
    func testRealDeliveryFailureAndRecoveryPathWithoutPayloadLeakage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = DiagnosticHistory(directory: directory.appendingPathComponent("diagnostics"))
        let outbox = EventOutbox(directory: directory.appendingPathComponent("outbox"))
        try outbox.enqueue(id: "test", body: Data(#"{"title":"PRIVATE_TITLE_SENTINEL","eventId":"PRIVATE_ID"}"#.utf8))
        _ = await deliverBatch(outbox: outbox, shouldContinue: { true }, diagnostics: history) { _ in 401 }
        XCTAssertEqual(history.entries.last?.httpStatus, 401)
        _ = await deliverBatch(outbox: outbox, shouldContinue: { true }, diagnostics: history) { _ in throw URLError(.timedOut) }
        XCTAssertEqual(history.entries.last?.category, .timeout)
        _ = await deliverBatch(outbox: outbox, shouldContinue: { false }, diagnostics: history) { _ in 202 }
        XCTAssertEqual(history.entries.last?.category, .timeout)
        _ = await deliverBatch(outbox: outbox, shouldContinue: { true }, diagnostics: history) { _ in 202 }
        XCTAssertEqual(history.entries.last?.category, .recovered)
        XCTAssertEqual(history.entries.last?.queued, 0)
        let text = try String(contentsOf: history.file, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_"))
    }

    @MainActor
    func testStorageFailureDoesNotPreventDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let history = DiagnosticHistory(directory: blocked)
        XCTAssertTrue(history.storageFailed)
        let outbox = EventOutbox(directory: directory.appendingPathComponent("outbox"))
        try outbox.enqueue(id: "test", body: Data(#"{"title":"test"}"#.utf8))
        let result = await deliverBatch(outbox: outbox, shouldContinue: { true }, diagnostics: history) { _ in 202 }
        XCTAssertEqual(result.sent, 1)
    }
}
