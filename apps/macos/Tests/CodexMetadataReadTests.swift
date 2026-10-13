import XCTest
import SQLite3
@testable import StatusWatchr

final class CodexMetadataReadTests: XCTestCase {
    func testThreadInventoryReportsUnavailableDatabaseWithoutLeakingDetails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard case .unavailable(.databaseMissing) = CodexThreadStore(codexHome: directory).read() else {
            return XCTFail("A missing state database must be reported as unavailable metadata, not as an empty inventory.")
        }
    }

    func testThreadInventoryReportsUnreadableSchemaSeparatelyFromMissingDatabase() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createDatabase(at: directory.appendingPathComponent("state_7.sqlite"), sql: "CREATE TABLE unrelated(value TEXT);")

        guard case .unavailable(.queryFailed(let details)) = CodexThreadStore(codexHome: directory).read() else {
            return XCTFail("An unreadable inventory schema must be distinguishable from a missing database.")
        }
        XCTAssertEqual(details.resultCode, SQLITE_ERROR)
        XCTAssertEqual(details.databaseVersion, 7)
        XCTAssertNotNil(details.schemaVersion)
    }

    func testTurnHistoryDistinguishesAnEmptyProjectionFromAnUnreadableDatabase() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("thread_history_1.sqlite")
        try createDatabase(at: databaseURL, sql: """
            CREATE TABLE thread_turns (
                thread_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                rollout_ordinal INTEGER NOT NULL,
                status TEXT NOT NULL,
                started_at INTEGER,
                completed_at INTEGER
            );
            """)
        let threads: [[String: Any]] = [["id": "safe-test-id", "historyId": "safe-test-id"]]

        XCTAssertEqual(CodexTurnStateStore(databaseURL: databaseURL).readHistories(forThreads: threads), .available([:]))

        let invalidDatabaseURL = directory.appendingPathComponent("thread_history_2.sqlite")
        try createDatabase(at: invalidDatabaseURL, sql: "CREATE TABLE unrelated(value TEXT);")
        guard case .unavailable(.queryFailed(let details)) = CodexTurnStateStore(databaseURL: invalidDatabaseURL).readHistories(forThreads: threads) else {
            return XCTFail("An unreadable turn-history schema must retain safe SQLite details.")
        }
        XCTAssertEqual(details.resultCode, SQLITE_ERROR)
        XCTAssertEqual(details.databaseVersion, 2)
        XCTAssertNotNil(details.schemaVersion)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func createDatabase(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }
}
