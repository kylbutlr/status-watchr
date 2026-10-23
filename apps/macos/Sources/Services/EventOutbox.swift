import Foundation

/// Contains normalized metadata and an optional bounded final-reply preview. Never persist hook input or HTTP response bodies.
struct EventOutbox {
    let directory: URL
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Status Watchr Public/outbox")) {
        self.directory = directory
    }

    func enqueue(id: String, body: Data, now: Date = Date()) throws {
        guard id.range(of: "^[a-zA-Z0-9-]{1,100}$", options: .regularExpression) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = try pending(now: now)
        let target = directory.appendingPathComponent(id + ".json")
        guard files.count < 5_000 || FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteOutOfSpace) }
        try body.write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    func pending(now: Date = Date()) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
        var retained: [(URL, Date)] = []
        for file in files {
            let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > 7 * 86_400 { try FileManager.default.removeItem(at: file) }
            else { retained.append((file, date)) }
        }
        return retained.sorted { $0.1 < $1.1 }.map(\.0)
    }
}
