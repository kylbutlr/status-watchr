import Foundation

enum DiagnosticOperation: String, Codable { case delivery, collectorHealth, localSource, localQueue, attention }
enum DiagnosticCategory: String, Codable {
    case http, timeout, offline, connection, localStorage, unavailable, recovered
    case approvalHook, appServerAttention, appServerAutoReviewStarted, appServerAutoReviewCompleted
    case inventoryDatabaseMissing, inventoryDatabaseUnavailable, inventoryQueryFailed, inventoryReadFailed
    case turnHistoryDatabaseMissing, turnHistoryDatabaseUnavailable, turnHistoryQueryFailed, turnHistoryReadFailed
    case turnHistoryEmpty
    case attentionChanged, attentionCleared
}

struct DiagnosticEntry: Codable, Equatable {
    var firstSeen: Date
    var lastSeen: Date
    let operation: DiagnosticOperation
    let category: DiagnosticCategory
    let httpStatus: Int?
    let sqliteCode: Int32?
    let schemaVersion: Int32?
    let databaseVersion: Int?
    var queued: Int
    var occurrences: Int
}

/// No arbitrary text, URLs, IDs, payloads, or Error descriptions cross this boundary.
@MainActor
final class DiagnosticHistory {
    let file: URL
    private(set) var entries: [DiagnosticEntry] = []
    private(set) var storageFailed = false
    private var persistedAt = Date.distantPast
    private let retention: TimeInterval = 7 * 86_400

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Status Watchr Public/diagnostics"), now: Date = Date()) {
        file = directory.appendingPathComponent("history.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 262_144 else { throw CocoaError(.fileReadTooLarge) }
                entries = try Self.decoder().decode([DiagnosticEntry].self, from: Data(contentsOf: file))
            }
            prune(now: now)
            persist(now: now)
        } catch { storageFailed = true }
    }

    static func category(for error: Error) -> DiagnosticCategory {
        guard let error = error as? URLError else { return .connection }
        switch error.code {
        case .timedOut: return .timeout
        case .notConnectedToInternet: return .offline
        default: return .connection
        }
    }

    func record(_ operation: DiagnosticOperation, category: DiagnosticCategory,
                httpStatus: Int? = nil, sqliteDetails: CodexSQLiteFailureDetails? = nil,
                queued: Int = 0, now: Date = Date()) {
        prune(now: now)
        let status = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        let details = operation == .localSource ? sqliteDetails : nil
        let count = min(5_000, max(0, queued))
        if let index = entries.lastIndex(where: { $0.operation == operation }),
           entries[index].category == category, entries[index].httpStatus == status,
           entries[index].sqliteCode == details?.resultCode,
           entries[index].schemaVersion == details?.schemaVersion,
           entries[index].databaseVersion == details?.databaseVersion {
            entries[index].lastSeen = now
            entries[index].queued = count
            entries[index].occurrences = min(1_000_000, entries[index].occurrences + 1)
            if now.timeIntervalSince(persistedAt) >= 60 { persist(now: now) }
        } else {
            entries.append(DiagnosticEntry(firstSeen: now, lastSeen: now, operation: operation,
                category: category, httpStatus: status, sqliteCode: details?.resultCode,
                schemaVersion: details?.schemaVersion, databaseVersion: details?.databaseVersion,
                queued: count, occurrences: 1))
            prune(now: now)
            persist(now: now)
        }
    }

    func success(_ operation: DiagnosticOperation, queued: Int = 0, now: Date = Date()) {
        prune(now: now)
        if let last = entries.last(where: { $0.operation == operation }), last.category != .recovered {
            record(operation, category: .recovered, queued: queued, now: now)
        } else if now.timeIntervalSince(persistedAt) >= 60 { persist(now: now) }
    }

    func flush(now: Date = Date()) { prune(now: now); persist(now: now) }

    func export(to destination: URL, now: Date = Date()) throws {
        prune(now: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func prune(now: Date) {
        entries = Array(entries.filter { now.timeIntervalSince($0.lastSeen) <= retention && $0.lastSeen <= now }.suffix(200))
    }

    private func persist(now: Date) {
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            persistedAt = now
            storageFailed = false
        } catch { storageFailed = true }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}
