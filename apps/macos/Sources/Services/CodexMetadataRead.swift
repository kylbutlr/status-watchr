import Foundation
import SQLite3

/// Numeric SQLite metadata only. Never retain the database path or sqlite3_errmsg.
struct CodexSQLiteFailureDetails: Equatable {
    let resultCode: Int32
    let schemaVersion: Int32?
    let databaseVersion: Int?

    static func capture(from database: OpaquePointer, databaseVersion: Int?) -> Self {
        // A later PRAGMA may replace the error from the failed application query.
        let resultCode = sqlite3_extended_errcode(database)
        var statement: OpaquePointer?
        var schemaVersion: Int32?
        if sqlite3_prepare_v2(database, "PRAGMA schema_version", -1, &statement, nil) == SQLITE_OK,
           let statement, sqlite3_step(statement) == SQLITE_ROW {
            schemaVersion = sqlite3_column_int(statement, 0)
        }
        if let statement { sqlite3_finalize(statement) }
        return Self(resultCode: resultCode, schemaVersion: schemaVersion, databaseVersion: databaseVersion)
    }

    static func databaseVersion(of url: URL, prefix: String) -> Int? {
        let name = url.lastPathComponent
        guard name.hasPrefix(prefix), name.hasSuffix(".sqlite") else { return nil }
        return Int(name.dropFirst(prefix.count).dropLast(".sqlite".count))
    }
}

enum CodexMetadataReadFailure: Equatable {
    case databaseMissing
    case openFailed
    case queryFailed(CodexSQLiteFailureDetails)
    case readFailed

    var sqliteDetails: CodexSQLiteFailureDetails? {
        guard case .queryFailed(let details) = self else { return nil }
        return details
    }
}

enum CodexThreadInventoryRead {
    case available([[String: Any]])
    case unavailable(CodexMetadataReadFailure)
}

enum CodexTurnHistoryRead: Equatable {
    case available([String: [LocalSessionState]])
    case unavailable(CodexMetadataReadFailure)
}

enum CodexActiveThreadIDsRead: Equatable {
    case available(Set<String>)
    case unavailable(CodexMetadataReadFailure)
}
