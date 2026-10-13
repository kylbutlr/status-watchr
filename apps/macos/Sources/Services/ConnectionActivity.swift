import Foundation

public enum ConnectionApp: String, Codable, CaseIterable, Sendable {
    case switchr = "App Switchr", todo = "Todo Trackr", watchr = "Status Watchr"
    public var destination: String { self == .switchr ? "Work-state service" : "Configured API" }
}
public enum ConnectionTrigger: String, Codable, CaseIterable, Sendable { case automatic, manual, control, reminder, unknown }
public enum ConnectionOperation: String, Codable, Sendable { case workState, command, tasks, lists, review, shortcut, catchUp, authentication, taskChange, sessions, upload, health, unknown }
public extension ConnectionOperation {
    var title: String {
        switch self {
        case .workState: return "Switch state"
        case .command: return "Switch change"
        case .tasks: return "Tasks"
        case .lists: return "Task lists"
        case .review: return "Review summary"
        case .shortcut: return "Shortcut sync"
        case .catchUp: return "Catch-up"
        case .authentication: return "Sign in"
        case .taskChange: return "Task change"
        case .sessions: return "Sessions"
        case .upload: return "Event upload"
        case .health: return "Collector health"
        case .unknown: return "Unclassified request"
        }
    }
}
public enum ConnectionPermission: String, Codable, Sendable { case active, off, unavailable, unconfigured }
public enum ConnectionOutcome: String, Codable, Sendable { case http, cancelled, timeout, offline, connection }
public enum ConnectionContext {
    @TaskLocal public static var trigger: ConnectionTrigger?
    @TaskLocal public static var retry = false
}
public struct ConnectionEvent: Codable, Sendable, Identifiable {
    public let schema: Int
    public let app: ConnectionApp
    public let session: UUID
    public let sequence: Int
    public let attempt: UUID
    public let date: Date
    public let operation: ConnectionOperation
    public let trigger: ConnectionTrigger
    public let permission: ConnectionPermission
    public let revision: Int?
    public let leaseRemaining: Double
    public let retry: Bool
    public let outcome: ConnectionOutcome?
    public let status: Int?
    public let duration: Double?
    public var id: String { "\(session):\(sequence)" }
    public var isStart: Bool { outcome == nil }
    public var violation: Bool { isStart && trigger == .automatic && (permission == .off || permission == .unavailable) }
    public var failed: Bool { outcome != nil && (outcome != .http || !(200..<400).contains(status ?? 0)) }
}
public struct ConnectionManifest: Codable, Sendable {
    public var schema = 1
    public var app: ConnectionApp
    public var version: String
    public var session: UUID
    public var reportingSince: Date
    public var updatedAt: Date
    public var incomplete: Bool
    public var dropped: Int
    public var cleanShutdown: Bool
    public var retainedSince: Date
    public var offObservedAt: Date? = nil
}
public struct ConnectionAttempt: Sendable {
    fileprivate let event: ConnectionEvent
    fileprivate let uptime: Double
}

/// Local metadata only. All request content stays outside this API.
public final class ConnectionRecorder: @unchecked Sendable {
    public let app: ConnectionApp
    public let directory: URL
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "connections.writer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var healthObserver: NSObjectProtocol?
    private var pending: [ConnectionEvent] = []
    private var sequence = 0
    private var dropped = 0
    private var scheduled = false
    private var permission: ConnectionPermission = .unavailable
    private var revision: Int?
    private var offObservedAt: Date?
    private var wallExpiry = Date.distantPast
    private var uptimeExpiry = -Double.infinity
    private let session = UUID()
    private let began = Date()
    private let version: String
    // Writer-queue-only state.
    private var manifest: ConnectionManifest?
    private var segment = UUID().uuidString + ".jsonl"
    private var initialized = false
    private var housekeeping = Date.distantPast
    private var failed = false
    private let byteLimit: Int
    public init(app: ConnectionApp, directory: URL? = nil, version: String? = nil, byteLimit: Int = 5 * 1024 * 1024, automaticFlush: Bool = true) {
        self.app = app
        self.directory = directory ?? Self.directory(for: app)
        self.version = version ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        self.byteLimit = byteLimit
        if automaticFlush {
            healthObserver = DistributedNotificationCenter.default().addObserver(forName: ConnectionHealth.query, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.publishHealth() }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 2)
            timer.setEventHandler { [weak self] in self?.writePending(clean: false) }
            self.timer = timer; timer.resume()
        }
    }
    deinit { timer?.cancel(); if let healthObserver { DistributedNotificationCenter.default().removeObserver(healthObserver) } }
    private func publishHealth() {
        DistributedNotificationCenter.default().postNotificationName(ConnectionHealth.status, object: app.rawValue, userInfo: ["failed": failed], deliverImmediately: true)
    }
    public static func directory(for app: ConnectionApp) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(app.rawValue)/connections-v1")
    }
    public func setPermission(_ value: ConnectionPermission, revision: Int? = nil, remaining: Double = 0) {
        lock.lock(); defer { lock.unlock() }
        if value == .off && permission != .off { offObservedAt = Date() }
        permission = value; self.revision = revision
        let bounded = remaining.isFinite ? min(60, max(0, remaining)) : 0
        wallExpiry = Date().addingTimeInterval(bounded)
        uptimeExpiry = ProcessInfo.processInfo.systemUptime + bounded
    }
    public func start(_ operation: ConnectionOperation, trigger: ConnectionTrigger, retry: Bool = false) -> ConnectionAttempt {
        lock.lock(); defer { lock.unlock() }
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let remaining = max(0, min(wallExpiry.timeIntervalSince(now), uptimeExpiry - uptime))
        let state: ConnectionPermission = permission == .active && remaining <= 0 ? .unavailable : permission
        sequence += 1
        let event = ConnectionEvent(schema: 1, app: app, session: session, sequence: sequence, attempt: UUID(), date: now,
                                    operation: operation, trigger: trigger, permission: state, revision: revision,
                                    leaseRemaining: remaining.isFinite ? remaining : 0, retry: retry, outcome: nil, status: nil, duration: nil)
        enqueue(event)
        return ConnectionAttempt(event: event, uptime: uptime)
    }
    public func finish(_ attempt: ConnectionAttempt, status: Int? = nil, outcome: ConnectionOutcome = .http) {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        let e = attempt.event
        enqueue(ConnectionEvent(schema: 1, app: app, session: session, sequence: sequence, attempt: e.attempt, date: Date(),
                                operation: e.operation, trigger: e.trigger, permission: e.permission, revision: e.revision,
                                leaseRemaining: e.leaseRemaining, retry: e.retry, outcome: outcome,
                                status: status.flatMap { (100...599).contains($0) ? $0 : nil },
                                duration: max(0, ProcessInfo.processInfo.systemUptime - attempt.uptime)))
    }
    public func data(for request: URLRequest, session: URLSession, operation: ConnectionOperation,
                     trigger: ConnectionTrigger, retry: Bool = false) async throws -> (Data, URLResponse) {
        let attempt = start(operation, trigger: ConnectionContext.trigger ?? trigger, retry: retry || ConnectionContext.retry)
        do {
            let result = try await session.data(for: request)
            finish(attempt, status: (result.1 as? HTTPURLResponse)?.statusCode)
            return result
        } catch {
            let code = (error as? URLError)?.code
            let outcome: ConnectionOutcome = error is CancellationError || code == .cancelled ? .cancelled : code == .timedOut ? .timeout : code == .notConnectedToInternet ? .offline : .connection
            finish(attempt, outcome: outcome); throw error
        }
    }
    // Called with lock held. At most one queued flush plus one active flush.
    private func enqueue(_ event: ConnectionEvent) {
        if pending.count < 512 { pending.append(event) } else { dropped += 1 }
        if pending.count >= 64 && !scheduled {
            scheduled = true
            queue.async { [weak self] in self?.writePending(clean: false) }
        }
    }
    public func flush(cleanShutdown: Bool = false) { queue.sync { writePending(clean: cleanShutdown) } }
    public var storageFailed: Bool { queue.sync { failed } }
    private func writePending(clean: Bool) {
        lock.lock(); let batch = pending; pending.removeAll(keepingCapacity: true); let losses = dropped; let observedOff = offObservedAt; scheduled = false; lock.unlock()
        if initialized && batch.isEmpty && losses == 0 && !clean && !failed && Date().timeIntervalSince(housekeeping) < 3600 { return }
        do {
            let fm = FileManager.default
            if !initialized {
                try ConnectionJournal.validateAncestors(directory)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try ConnectionJournal.validateFile(directory, directory: true)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                let previous = try? ConnectionJournal.readManifest(directory)
                let corruptManifest = previous == nil && fm.fileExists(atPath: directory.appendingPathComponent("manifest.json").path)
                manifest = ConnectionManifest(app: app, version: version, session: session,
                    reportingSince: previous?.reportingSince ?? began, updatedAt: began,
                    incomplete: corruptManifest || previous?.incomplete == true || previous?.cleanShutdown == false,
                    dropped: previous?.dropped ?? 0, cleanShutdown: false, retainedSince: previous?.retainedSince ?? began)
                initialized = true
            }
            guard var metadata = manifest else { return }
            metadata.updatedAt = Date(); metadata.cleanShutdown = clean; metadata.offObservedAt = observedOff
            metadata.incomplete = metadata.incomplete || failed || losses > 0
            metadata.dropped = min(1_000_000_000, metadata.dropped + losses)
            lock.lock(); dropped = max(0, dropped - losses); lock.unlock()
            var payload = Data()
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            for event in batch { payload.append(try encoder.encode(event)); payload.append(10) }
            let file = directory.appendingPathComponent(segment)
            if !payload.isEmpty {
                if fm.fileExists(atPath: file.path) { try ConnectionJournal.validateFile(file) }
                else {
                    guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                }
                let handle = try FileHandle(forWritingTo: file)
                do { try handle.seekToEnd(); try handle.write(contentsOf: payload); try handle.close() }
                catch { try? handle.close(); throw error }
                if (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) >= 256 * 1024 { segment = UUID().uuidString + ".jsonl" }
            }
            var files = try ConnectionJournal.segments(directory)
            let cutoffDate = Date().addingTimeInterval(-7 * 86400)
            for file in files {
                try ConnectionJournal.validateFile(file)
                let created = try file.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
                if created < cutoffDate {
                    let data = try Data(contentsOf: file)
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
                    let lines = data.split(separator: 10)
                    let kept = lines.filter { line in
                        guard let event = try? decoder.decode(ConnectionEvent.self, from: Data(line)) else { return false }
                        return event.date >= cutoffDate
                    }
                    if kept.count != lines.count {
                        if kept.isEmpty { try fm.removeItem(at: file) }
                        else {
                            var trimmed = Data(); for line in kept { trimmed.append(contentsOf: line); trimmed.append(10) }
                            try trimmed.write(to: file, options: .atomic)
                            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                        }
                        metadata.retainedSince = max(metadata.retainedSince, cutoffDate)
                    }
                }
            }
            files = try ConnectionJournal.segments(directory)
            var total = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            let cutoff = Date().addingTimeInterval(-7 * 86400)
            while let first = files.first {
                let attrs = try first.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard total > byteLimit || (attrs.contentModificationDate ?? .distantPast) < cutoff else { break }
                try fm.removeItem(at: first); total -= attrs.fileSize ?? 0; files.removeFirst()
                metadata.incomplete = true
                metadata.retainedSince = max(metadata.retainedSince, attrs.contentModificationDate ?? Date())
            }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            if fm.fileExists(atPath: manifestURL.path) { try ConnectionJournal.validateFile(manifestURL) }
            try encoder.encode(metadata).write(to: manifestURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            manifest = metadata; failed = false; housekeeping = Date()
        } catch { failed = true; lock.lock(); dropped += batch.count; lock.unlock() }
        publishHealth()
    }
}

public struct ConnectionHistory: Sendable {
    public var app: ConnectionApp
    public var manifest: ConnectionManifest?
    public var events: [ConnectionEvent]
    public var incomplete: Bool
    fileprivate var finishes: [UUID: ConnectionEvent] = [:]
    public var starts: [ConnectionEvent] { events.filter(\.isStart) }
    public func completion(for start: ConnectionEvent) -> ConnectionEvent? { finishes[start.attempt] }
    public func repeatedFailures(since: Date) -> Set<ConnectionOperation> {
        var failures: [ConnectionOperation: Int] = [:]
        for event in events.filter({ !$0.isStart && $0.date >= since }).sorted(by: { $0.date < $1.date }) {
            failures[event.operation] = event.failed ? (failures[event.operation] ?? 0) + 1 : 0
        }
        return Set(failures.filter { $0.value >= 3 }.map(\.key))
    }
}
public enum ConnectionJournal {
    static func validateAncestors(_ url: URL) throws {
        var path = url
        while path.path != "/" {
            if FileManager.default.fileExists(atPath: path.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
                if attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw CocoaError(.fileReadNoPermission) }
            }
            path.deleteLastPathComponent()
        }
    }
    static func validateFile(_ url: URL, directory: Bool = false) throws {
        try validateAncestors(url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              directory || ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 5 * 1024 * 1024 else { throw CocoaError(.fileReadNoPermission) }
    }
    static func segments(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "jsonl" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }
    static func readManifest(_ directory: URL) throws -> ConnectionManifest {
        let file = directory.appendingPathComponent("manifest.json"); try validateFile(file)
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4096 else { throw CocoaError(.fileReadTooLarge) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let result = try decoder.decode(ConnectionManifest.self, from: Data(contentsOf: file))
        guard result.schema == 1, result.version.count <= 64, (0...1_000_000_000).contains(result.dropped) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
    public static func read(app: ConnectionApp, directory: URL? = nil) -> ConnectionHistory {
        ConnectionReader().read(app: app, directory: directory)
    }
}

/// Reuses decoded, unchanged segments; only changed segments are read again.
public final class ConnectionReader: @unchecked Sendable {
    private struct Cached {
        var size: Int
        var modified: Date
        var inode: Int
        var events: [ConnectionEvent]
        var incomplete: Bool
    }
    private let lock = NSLock()
    private var cache: [String: Cached] = [:]
    public init() {}
    public func read(app: ConnectionApp, directory: URL? = nil) -> ConnectionHistory {
        lock.lock(); defer { lock.unlock() }
        let directory = directory ?? ConnectionRecorder.directory(for: app)
        var history = ConnectionHistory(app: app, manifest: nil, events: [], incomplete: false)
        guard FileManager.default.fileExists(atPath: directory.path) else { return history }
        do {
            try ConnectionJournal.validateFile(directory, directory: true)
            let metadata = try ConnectionJournal.readManifest(directory)
            guard metadata.app == app else { throw CocoaError(.fileReadCorruptFile) }
            history.manifest = metadata; history.incomplete = metadata.incomplete
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            var seen = Set<String>(), total = 0
            let files = try ConnectionJournal.segments(directory)
            let paths = Set(files.map(\.path))
            cache = cache.filter { !$0.key.hasPrefix(directory.path + "/") || paths.contains($0.key) }
            for file in files {
                try ConnectionJournal.validateFile(file)
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                let size = (attrs[.size] as? NSNumber)?.intValue ?? Int.max
                let modified = attrs[.modificationDate] as? Date ?? .distantPast
                let inode = (attrs[.systemFileNumber] as? NSNumber)?.intValue ?? 0
                guard size <= 5 * 1024 * 1024 - total else { throw CocoaError(.fileReadTooLarge) }
                total += size
                let decoded: Cached
                if let cached = cache[file.path], cached.size == size, cached.modified == modified, cached.inode == inode {
                    decoded = cached
                } else {
                    let bytes = try Data(contentsOf: file)
                    var events: [ConnectionEvent] = [], incomplete = false
                    let lines = bytes.split(separator: 10, omittingEmptySubsequences: true)
                    for (index, line) in lines.enumerated() {
                        if index == lines.count - 1 && bytes.last != 10 { incomplete = true; continue }
                        guard line.count < 4096,
                              let event = try? decoder.decode(ConnectionEvent.self, from: Data(line)), event.schema == 1, event.app == app,
                              event.sequence > 0, event.leaseRemaining.isFinite, (0...60).contains(event.leaseRemaining),
                              event.duration == nil || (event.duration!.isFinite && (0...7 * 86400).contains(event.duration!)),
                              event.status == nil || (100...599).contains(event.status!) else { incomplete = true; continue }
                        events.append(event)
                    }
                    decoded = Cached(size: size, modified: modified, inode: inode, events: events, incomplete: incomplete)
                    cache[file.path] = decoded
                }
                history.incomplete = history.incomplete || decoded.incomplete
                for event in decoded.events where event.date >= Date().addingTimeInterval(-7 * 86400) {
                    if seen.insert(event.id).inserted {
                        history.events.append(event)
                        if !event.isStart { history.finishes[event.attempt] = event }
                    }
                }
            }
            history.events.sort { $0.date == $1.date && $0.session == $1.session ? $0.sequence < $1.sequence : $0.date < $1.date }
        } catch { history.incomplete = true }
        return history
    }
}

/// Live local IPC only. Absence of a response never implies healthy recording.
public final class ConnectionHealth: @unchecked Sendable {
    static let query = Notification.Name("com.kylbutlr.connections.health-query")
    static let status = Notification.Name("com.kylbutlr.connections.health-status")
    private let lock = NSLock()
    private var responses: [ConnectionApp: (Date, Bool)] = [:]
    private var observer: NSObjectProtocol?
    public init() {
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.status, object: nil, queue: nil) { [weak self] notification in
            guard let self, let name = notification.object as? String, let app = ConnectionApp(rawValue: name),
                  let failed = notification.userInfo?["failed"] as? Bool else { return }
            self.lock.lock(); self.responses[app] = (Date(), failed); self.lock.unlock()
        }
    }
    deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) } }
    public func refresh() {
        DistributedNotificationCenter.default().postNotificationName(Self.query, object: nil, userInfo: nil, deliverImmediately: true)
    }
    public func failed(for app: ConnectionApp) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard let (time, failed) = responses[app], Date().timeIntervalSince(time) < 15 else { return nil }
        return failed
    }
}
