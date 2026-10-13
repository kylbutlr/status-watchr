import Foundation

struct PendingAttention: Codable, Equatable {
    let turn: String
    let marker: String
    let tool: String
    var createdAt = Date()
}

struct AttentionStateStore {
    let directory: URL
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Status Watchr")) {
        self.directory = directory
    }
    private var file: URL { directory.appendingPathComponent("attention.json") }

    func load(now: Date = Date()) throws -> [String: PendingAttention] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let saved = try JSONDecoder().decode([String: PendingAttention].self, from: Data(contentsOf: file))
        let retained = saved.filter { now.timeIntervalSince($0.value.createdAt) < 7 * 86_400 }
        if retained.count != saved.count { try save(retained) }
        return retained
    }

    func save(_ entries: [String: PendingAttention]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let retained = entries.filter { Date().timeIntervalSince($0.value.createdAt) < 7 * 86_400 }
        try JSONEncoder().encode(retained).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
