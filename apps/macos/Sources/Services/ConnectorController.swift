import CryptoKit
import AppKit
import Foundation
import Combine
import ServiceManagement
import UniformTypeIdentifiers

struct ConnectorEventDeduper {
    private var eventMetadata: [String: String] = [:]

    func contains(_ eventKey: String) -> Bool { eventMetadata[eventKey] != nil }

    mutating func insert(_ eventKey: String, metadata: String = "") -> Bool {
        guard eventMetadata[eventKey] != metadata else { return false }
        eventMetadata[eventKey] = metadata
        return true
    }

    mutating func remove(_ eventKey: String) {
        eventMetadata.removeValue(forKey: eventKey)
    }
}

struct ConnectorHeartbeatThrottle {
    private var sentAt: [String: Date] = [:]

    mutating func shouldSend(_ key: String, now: Date, minimumInterval: TimeInterval) -> Bool {
        if let previous = sentAt[key], now.timeIntervalSince(previous) < minimumInterval { return false }
        sentAt[key] = now
        return true
    }

    mutating func remove(_ key: String) {
        sentAt.removeValue(forKey: key)
    }

    mutating func reset() {
        sentAt.removeAll()
    }
}

struct LocalSourceFreshness: Equatable {
    private(set) var lastSuccessfulScanAt: Date?
    private(set) var degradedSince: Date?

    mutating func observe(available: Bool, at now: Date) {
        if available {
            lastSuccessfulScanAt = now
            degradedSince = nil
        } else if degradedSince == nil {
            degradedSince = now
        }
    }

    mutating func stop() { degradedSince = nil }

    func degradedDuration(at now: Date) -> TimeInterval? {
        degradedSince.map { max(0, now.timeIntervalSince($0)) }
    }
}

func connectorEventKey(threadID: String, method: String, status: String, marker: String) -> String {
    "\(threadID):\(method):\(status):\(marker)"
}

func turnSessionID(threadID: String, turnID: String) -> String {
    turnID == "unknown" ? threadID : "\(threadID):turn:\(turnID)"
}

func turnStatusForCompletion(_ turnStatus: String?) -> String {
    turnStatus == "failed" ? "failed" : turnStatus == "interrupted" ? "stale" : "finished"
}

func connectorStatus(threadType: String?, localState: LocalSessionState) -> String? {
    switch localState {
    case .working: return "working"
    case .finished: return "finished"
    case .failed: return "failed"
    case .stale: return "stale"
    case .unknown: break
    }

    if threadType == "active" { return "working" }
    return nil
}

func statusForHookEvent(_ eventName: String) -> String? {
    switch eventName {
    case "UserPromptSubmit", "SubagentStart": return "working"
    // PermissionRequest can be routed to Codex Auto-review, so it is not proof
    // that the owner has an actionable prompt.
    case "PermissionRequest": return nil
    case "Stop", "SubagentStop": return "finished"
    case "Interrupt": return "stale"
    default: return nil
    }
}

func discardUnconfirmedAttention(_ store: AttentionStateStore) throws {
    // Older builds promoted hook-only candidates. A saved candidate alone does
    // not prove that a human approval is still outstanding.
    if !(try store.load()).isEmpty { try store.save([:]) }
}

let connectorRecoveryIntervalOptions: [Double] = [15, 30, 60]
let connectorDefaultRecoveryInterval: Double = 60
let connectorMinimumHeartbeatInterval: Double = 60
let attentionConfirmationDelay: TimeInterval = 5
let completionConfirmationDelay: TimeInterval = 5

private struct PendingCompletion {
    var event: [String: Any]
    let heartbeatKey: String
    let observedAt: Date
}

func connectorRetryDelay(failures: Int) -> TimeInterval {
    min(300, 5 * pow(2, Double(min(8, max(0, failures)))))
}

func occurredDuringStandby(_ timestamp: String, interval: DateInterval?) -> Bool {
    guard let interval else { return false }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let occurred = parser.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else { return false }
    return interval.contains(occurred)
}

func threadListParameters(cursor: String? = nil) -> [String: Any] {
    var parameters: [String: Any] = [
        "archived": false,
        "limit": 100,
        "sortKey": "updated_at",
        "sortDirection": "desc"
    ]
    if let cursor, !cursor.isEmpty { parameters["cursor"] = cursor }
    return parameters
}

func uniqueThreadsByID(_ threads: [[String: Any]]) -> [[String: Any]] {
    var seen = Set<String>()
    return threads.filter { thread in
        guard let id = thread["id"] as? String else { return false }
        return seen.insert(id).inserted
    }
}

enum ConnectorEnvironment {
    static func path(home: String, existingPath: String) -> String {
        [
            "\(home)/.local/bin",
            "/Applications/ChatGPT.app/Contents/Resources",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            existingPath
        ]
            .filter { !$0.isEmpty }
            .joined(separator: ":")
    }
}

@MainActor
final class ConnectorController: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case paused
        case connected
        case needsYou
        case failed(String)

        var label: String {
            switch self {
            case .stopped: "Stopped"
            case .starting: "Starting…"
            case .paused: "Paused by App Switchr"
            case .connected: "Observing local runs"
            case .needsYou: "Needs you"
            case .failed: "Error"
            }
        }

        var colorName: String {
            switch self {
            case .stopped: "secondary"
            case .starting: "orange"
            case .paused: "secondary"
            case .connected: "green"
            case .needsYou: "yellow"
            case .failed: "red"
            }
        }
    }

    @Published var state: State = .stopped
    @Published var siteURL: String = UserDefaults.standard.string(forKey: "siteURL") ?? "https://statuswatchr.netlify.app" {
        didSet { UserDefaults.standard.set(siteURL, forKey: "siteURL") }
    }
    @Published var intervalSeconds: Double = min(60, UserDefaults.standard.object(forKey: "intervalSeconds") as? Double ?? connectorDefaultRecoveryInterval) {
        didSet {
            UserDefaults.standard.set(intervalSeconds, forKey: "intervalSeconds")
            if process?.isRunning == true { restartTimer() }
        }
    }
    @Published var token: String
    @Published private(set) var sourceFreshness = LocalSourceFreshness()
    @Published private(set) var scannedThreadCount = 0
    @Published private(set) var matchedThreadCount = 0
    @Published private(set) var sentEventCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var hooksEnabled = CodexHookInstaller.isInstalled()
    @Published private(set) var hookReadiness: HookReadiness = .unknown
    @Published private(set) var lastHookAt: Date?
    @Published private(set) var pendingEventCount = 0

    let intervalOptions = connectorRecoveryIntervalOptions
    private var process: Process?
    private var inputPipe: Pipe?
    @Published private(set) var workSwitchStatus: String? = "Switchr: Pending"
    private var workLease = WorkSwitchLease()
    private var workTimer: Timer?
    private var checkingWork = false
    private var workCheckAgain = false
    private var workGeneration = 0
    private var monitoringStarted = false
    private var localObservationPaused = false
    private var standbyStartedAt: Date?
    private var lastStandbyInterval: DateInterval?
    private var scanTimer: Timer?
    private var localTimer: Timer?
    private var cachedThreads: [[String: Any]] = []
    private var internalReviewThreads = Set<String>()
    private var queuedReviewExclusions = Set<String>()
    private let threadStore: CodexThreadStore
    private let finalReplyStore = CodexFinalReplyStore()
    private var inventoryFailure: CodexMetadataReadFailure?
    private var hookRequestID: Int?
    @Published private var pendingAttention: [String: PendingAttention] = [:] {
        didSet {
            if oldValue != pendingAttention {
                diagnostics.record(.attention, category: pendingAttention.isEmpty ? .attentionCleared : .attentionChanged)
            }
            guard !previewOnly else { return }
            do { try attentionStateStore.save(pendingAttention) }
            catch { lastError = "Could not preserve attention identity locally. Attention alerts may repeat after restart." }
        }
    }
    private let outbox = EventOutbox()
    private let diagnostics: DiagnosticHistory
    private let previewOnly: Bool
    @Published private(set) var diagnosticMessage: String?

    var attentionConversations: [(id: String, title: String)] {
        pendingAttention.keys.sorted().map { id in
            (id: id, title: contexts[id]?.title ?? "Conversation unavailable")
        }
    }

    func exportDiagnostics() {
        diagnostics.flush()
        guard !diagnostics.storageFailed else {
            diagnosticMessage = "Diagnostic history could not be saved. Check available disk space and folder permissions."
            return
        }
        diagnosticMessage = nil
        let panel = NSSavePanel()
        panel.title = "Export diagnostics"
        panel.nameFieldStringValue = "status-watchr-diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try diagnostics.export(to: destination) }
        catch { diagnosticMessage = "Could not export diagnostics. Check the destination folder permissions and available space." }
    }
    private var drainingOutbox = false
    private var deliveryFailures = 0
    private let deliveryAttempts = DeliveryAttempts()
    private var deliveryRetryAfter = Date.distantPast
    private var healthSentAt: Date = .distantPast
    private var outputBuffer = Data()
    private var nextRequestID = 1
    private var contexts: [String: ThreadContext] = [:]
    private let turnStateStore: CodexTurnStateStore
    private let questionAnswerStore: QuestionAnswerStore
    private let questionAlertsEnabled: Bool
    private var questions: [String: PendingQuestion] = [:]
    private var questionTimer: Timer?
    private var reportedQuestionAnswers: [String: Date] = [:]
    private let attentionStateStore: AttentionStateStore
    private let confirmationDelay: TimeInterval
    private let eventSink: (([String: Any]) -> Void)?
    private var pendingCompletions: [String: PendingCompletion] = [:]
    private var latestStartedTurns: [String: LocalSessionState] = [:]
    private var supersededCompletionSessions = Set<String>()
    private var completionTimer: Timer?
    private var attentionRequestBuffer = AttentionRequestBuffer()
    private var attentionConfirmationTimers: [String: Timer] = [:]
    private var automaticReviewThreads = Set<String>()
    private var reportedEventKeys = ConnectorEventDeduper()
    private var queuedTitleRepairs = Set<String>()
    private var queuedRelationships = Set<String>()
    private var heartbeatThrottle = ConnectorHeartbeatThrottle()
    private lazy var hookServer = CodexHookServer { [weak self] data in
        DispatchQueue.main.async { [weak self] in self?.handleHook(data) }
    }

    init(diagnostics: DiagnosticHistory = DiagnosticHistory(), previewOnly: Bool = false,
         codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
         attentionStateStore: AttentionStateStore = AttentionStateStore(),
         confirmationDelay: TimeInterval = attentionConfirmationDelay,
         questionAlertsEnabled: Bool = UserDefaults.standard.bool(forKey: "questionAlertsEnabled"),
         eventSink: (([String: Any]) -> Void)? = nil) {
        self.diagnostics = diagnostics
        self.previewOnly = previewOnly
        self.threadStore = CodexThreadStore(codexHome: codexHome)
        self.turnStateStore = CodexTurnStateStore(codexHome: codexHome)
        self.questionAnswerStore = QuestionAnswerStore(codexHome: codexHome)
        self.questionAlertsEnabled = questionAlertsEnabled
        self.attentionStateStore = attentionStateStore
        self.confirmationDelay = confirmationDelay
        self.eventSink = eventSink
        self.token = previewOnly ? "" : KeychainStore.readToken()
        if previewOnly {
            _siteURL = Published(initialValue: "https://statuswatchr.netlify.app")
            workSwitchStatus = "Switchr: On"
            sourceFreshness.observe(available: true, at: Date())
            return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(workSwitchChanged), name: Notification.Name("com.kylbutlr.app-switchr.state-changed"), object: nil)
        do { try discardUnconfirmedAttention(attentionStateStore) }
        catch { lastError = "Saved attention state unavailable. Attention continuity cannot be verified." }
        if hooksEnabled { hookServer.start() }
    }

    var isRunning: Bool { monitoringStarted }

    var lastScanLabel: String {
        guard let lastScan = sourceFreshness.lastSuccessfulScanAt else { return "Never" }
        return lastScan.formatted(date: .omitted, time: .shortened)
    }

    var sourceDegradedLabel: String? {
        guard let duration = sourceFreshness.degradedDuration(at: Date()) else { return nil }
        let seconds = Int(duration)
        let elapsed: String
        if seconds < 60 { elapsed = "<1m" }
        else if seconds < 3_600 { elapsed = "\(seconds / 60)m" }
        else { elapsed = "\(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
        return "Local source unavailable for \(elapsed)"
    }

    func start() {
        guard !isRunning else { return }
        if previewOnly {
            monitoringStarted = true
            state = .starting
            requestScan()
            restartTimer()
            return
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("Add the ingest token first.")
            return
        }
        do { try KeychainStore.saveToken(token) } catch {
            state = .failed("Could not save the token to Keychain.")
            return
        }

        monitoringStarted = true
        state = .starting
        lastError = nil
        matchedThreadCount = 0
        sentEventCount = 0
        contexts.removeAll()
        reportedEventKeys = ConnectorEventDeduper()
        heartbeatThrottle.reset()
        requestScan()
        restartTimer()
        workTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkWorkPermission() }
        }
        Task { await checkWorkPermission() }
        startAppServer()
    }

    private func startAppServer() {
        guard isRunning, !previewOnly, !localObservationPaused, process == nil else { return }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "app-server", "--listen", "stdio://"]
        process.environment = connectorEnvironment()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        self.process = process
        self.inputPipe = inputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self, weak process] in
                guard let self, let process, self.process === process else { return }
                self.receive(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] exited in
            Task { @MainActor [weak self] in
                guard let self, self.process === exited else { return }
                self.process = nil
                self.inputPipe = nil
                self.hookReadiness = .unknown
                self.lastError = "Hook trust check unavailable. Local history monitoring continues."
            }
        }

        do {
            try process.run()
            send(method: "initialize", params: [
                "clientInfo": ["name": "status-watchr-mac", "title": "Status Watchr", "version": "0.1.0"]
            ], id: 1)
        } catch {
            self.process = nil
            self.inputPipe = nil
            hookReadiness = .unknown
            lastError = "Hook trust check unavailable. Local history monitoring continues."
        }
    }

    private func stopAppServer() {
        let current = process
        process = nil
        inputPipe = nil
        outputBuffer.removeAll()
        hookRequestID = nil
        hookReadiness = .unknown
        (current?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (current?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if current?.isRunning == true { current?.terminate() }
    }

    func stop() {
        questionTimer?.invalidate(); questionTimer = nil
        questions.removeAll()
        reportedQuestionAnswers.removeAll()
        monitoringStarted = false
        if let standbyStartedAt {
            lastStandbyInterval = DateInterval(start: standbyStartedAt, end: max(standbyStartedAt, Date()))
            self.standbyStartedAt = nil
        }
        workGeneration += 1
        workTimer?.invalidate(); workTimer = nil
        workLease.invalidate()
        if !previewOnly { ConnectionTelemetry.recorder.setPermission(.unavailable) }
        workSwitchStatus = "Switchr: Pending"
        scanTimer?.invalidate()
        localTimer?.invalidate()
        attentionConfirmationTimers.values.forEach { $0.invalidate() }
        attentionConfirmationTimers.removeAll()
        attentionRequestBuffer.removeAll()
        clearPendingCompletions()
        automaticReviewThreads.removeAll()
        localTimer = nil
        scanTimer = nil
        stopAppServer()
        localObservationPaused = false
        sourceFreshness.stop()
        state = .stopped
    }

    func refresh() {
        heartbeatThrottle.reset()
        requestScan()
    }

    @objc private func workSwitchChanged() {
        workGeneration += 1
        workLease.invalidate(); ConnectionTelemetry.recorder.setPermission(.unavailable)
        workSwitchStatus = "Switchr: Pending"
        Task { await checkWorkPermission() }
    }

    private func checkWorkPermission() async {
        guard isRunning else { return }
        if checkingWork { workCheckAgain = true; return }
        checkingWork = true
        defer { checkingWork = false }
        repeat {
            workCheckAgain = false
            let generation = workGeneration
            let wasAllowed = workLease.allowsWork()
            let started = ProcessInfo.processInfo.systemUptime
            let requestedSite = siteURL
            let requestedToken = token
            do {
                guard let url = URL(string: "\(requestedSite.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/work-state"),
                      url.scheme == "https", url.user == nil, url.password == nil else { throw URLError(.badURL) }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
                request.setValue("Bearer \(requestedToken)", forHTTPHeaderField: "authorization")
                let (data, response) = try await ConnectionTelemetry.recorder.data(for: request, session: ingestSession, operation: .workState, trigger: .control)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let permission = try JSONDecoder().decode(WorkSwitchPermission.self, from: data)
                guard permission.valid else { throw URLError(.cannotParseResponse) }
                guard isRunning else { return }
                if generation != workGeneration || requestedSite != siteURL || requestedToken != token {
                    workCheckAgain = true; continue
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let resumed = acceptWorkPermission(permission, elapsed: elapsed)
                ConnectionTelemetry.recorder.setPermission(!permission.configured ? .unconfigured : permission.state == "active" ? .active : permission.state == "standby" ? .off : .unavailable, revision: permission.revision, remaining: max(0, permission.leaseSeconds - elapsed))
                if !wasAllowed && workLease.allowsWork() {
                    deliveryRetryAfter = .distantPast
                    heartbeatThrottle.reset()
                    healthSentAt = .distantPast
                    if !resumed { requestScan() }
                    drainOutbox()
                }
            } catch {
                workLease.invalidate(); ConnectionTelemetry.recorder.setPermission(.unavailable)
                workSwitchStatus = "Switchr: Pending"
                resumeLocalObservation()
            }
        } while workCheckAgain && isRunning
    }

    @discardableResult
    func acceptWorkPermission(_ permission: WorkSwitchPermission, elapsed: Double = 0) -> Bool {
        workLease.accept(permission, elapsed: elapsed)
        workSwitchStatus = workLease.label
        if workLease.isConfirmedStandby() {
            pauseLocalObservation()
            return false
        }
        return resumeLocalObservation()
    }

    private func pauseLocalObservation() {
        guard isRunning, !localObservationPaused else { return }
        localObservationPaused = true
        standbyStartedAt = Date()
        scanTimer?.invalidate(); scanTimer = nil
        localTimer?.invalidate(); localTimer = nil
        attentionConfirmationTimers.values.forEach { $0.invalidate() }
        attentionConfirmationTimers.removeAll()
        attentionRequestBuffer.removeAll()
        clearPendingCompletions()
        stopAppServer()
        sourceFreshness.stop()
        if lastError == "Hook trust check unavailable. Local history monitoring continues." { lastError = nil }
        state = .paused
    }

    @discardableResult
    private func resumeLocalObservation() -> Bool {
        guard isRunning, localObservationPaused else { return false }
        localObservationPaused = false
        if let standbyStartedAt {
            lastStandbyInterval = DateInterval(start: standbyStartedAt, end: max(standbyStartedAt, Date()))
            self.standbyStartedAt = nil
        }
        restartTimer()
        startAppServer()
        requestScan()
        return true
    }

    func saveToken() {
        do {
            try KeychainStore.saveToken(token)
            lastError = nil
        } catch {
            lastError = "Could not save the token to Keychain."
        }
    }

    func setHooksEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try CodexHookInstaller.install()
                hookServer.start()
            } else {
                try CodexHookInstaller.remove()
                hookServer.stop()
            }
            hooksEnabled = enabled
            hookReadiness = .unknown
            if process?.isRunning == true { hookRequestID = send(method: "hooks/list", params: [:]) }
            lastError = nil
        } catch {
            lastError = "Could not update Codex hooks. Check the existing hooks file and its permissions."
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            lastError = "Could not update Launch at Login."
        }
    }

    private func connectorEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? ""
        let home = environment["HOME"] ?? ""
        environment["PATH"] = ConnectorEnvironment.path(home: home, existingPath: existingPath)
        return environment
    }

    private func restartTimer() {
        scanTimer?.invalidate()
        localTimer?.invalidate()
        guard !localObservationPaused else { scanTimer = nil; localTimer = nil; return }
        scanTimer = Timer.scheduledTimer(withTimeInterval: max(intervalSeconds, 5), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduledInventoryScan() }
        }
        localTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduledLocalScan() }
        }
    }

    func scheduledInventoryScan() {
        guard !localObservationPaused, !workLease.isConfirmedStandby() else { return }
        requestScan()
    }

    func scheduledLocalScan() {
        guard !localObservationPaused, !workLease.isConfirmedStandby() else { return }
        scanLocalHistory()
        drainOutbox()
    }

    private func requestScan() {
        if !previewOnly, !token.isEmpty, let rows = threadStore.conversationRelationships() {
            for report in conversationRelationshipEvents(rows) where !queuedRelationships.contains(report.id) {
                do {
                    try outbox.enqueue(id: report.id, body: report.body)
                    queuedRelationships.insert(report.id)
                } catch { lastError = "Could not queue conversation relationships; will retry." }
            }
        }
        if !previewOnly, !token.isEmpty, let titles = threadStore.subagentTitleRepairs() {
            for report in conversationTitleRepairEvents(titles) where !queuedTitleRepairs.contains(report.id) {
                do {
                    try outbox.enqueue(id: report.id, body: report.body)
                    queuedTitleRepairs.insert(report.id)
                } catch { lastError = "Could not queue conversation title repairs; will retry." }
            }
        }
        if let reviews = threadStore.internalReviewIDs() {
            internalReviewThreads.formUnion(reviews)
            pendingAttention = pendingAttention.filter { !reviews.contains($0.key) }
            for event in internalReviewExclusionEvents(ids: previewOnly || token.isEmpty ? [] : reviews.subtracting(queuedReviewExclusions)) {
                do {
                    try outbox.enqueue(id: event.id, body: event.body)
                    if let body = try JSONSerialization.jsonObject(with: event.body) as? [String: Any],
                       let ids = body["excludedThreadIds"] as? [String] { queuedReviewExclusions.formUnion(ids) }
                } catch { lastError = "Could not queue internal review exclusions; will retry." }
            }
        }
        switch threadStore.read() {
        case .available(let threads):
            cachedThreads = threads
            inventoryFailure = nil
            scannedThreadCount = threads.count
        case .unavailable(let failure):
            inventoryFailure = failure
            cachedThreads = []
            scannedThreadCount = 0
        }
        scanLocalHistory()
        if process?.isRunning == true { hookRequestID = send(method: "hooks/list", params: [:]) }
    }

    private func scanLocalHistory() {
        confirmQuestions()
        let historyRead = turnStateStore.readHistories(forThreads: cachedThreads)
        let histories: [String: [LocalSessionState]]
        let historyFailure: CodexMetadataReadFailure?
        switch historyRead {
        case .available(let values):
            histories = values
            historyFailure = nil
        case .unavailable(let failure):
            histories = [:]
            historyFailure = failure
        }
        let projected = histories.compactMapValues { $0.first }
        matchedThreadCount = 0
        for thread in cachedThreads {
            guard let id = thread["id"] as? String else { continue }
            handleThread(thread, projectedState: projected[id] ?? .unknown)
            // Recover short runs that finished between polls. Ignore older history for alerts.
            for previous in (histories[id] ?? []).dropFirst() {
                guard let timestamp = previous.occurredAt else { continue }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                guard let occurred = formatter.date(from: timestamp), Date().timeIntervalSince(occurred) < 600 else { continue }
                switch previous {
                case .finished, .failed, .stale: handleThread(thread, projectedState: previous)
                default: break
                }
            }
        }
        let sourceFailure: DiagnosticCategory?
        if let inventoryFailure {
            sourceFailure = inventoryDiagnosticCategory(inventoryFailure)
        } else if cachedThreads.isEmpty {
            sourceFailure = nil
        } else if let historyFailure {
            sourceFailure = turnHistoryDiagnosticCategory(historyFailure)
        } else if projected.isEmpty {
            sourceFailure = .turnHistoryEmpty
        } else {
            sourceFailure = nil
        }
        let sourceAvailable = sourceFailure == nil
        sourceFreshness.observe(available: sourceAvailable, at: Date())
        if let sourceFailure {
            diagnostics.record(.localSource, category: sourceFailure,
                               sqliteDetails: inventoryFailure?.sqliteDetails ?? historyFailure?.sqliteDetails,
                               queued: pendingEventCount)
        }
        else { diagnostics.success(.localSource, queued: pendingEventCount) }
        if sourceAvailable { state = pendingAttention.isEmpty ? .connected : .needsYou }
        else { state = .failed("Local run metadata is unavailable.") }
        sendHealth(sourceAvailable: sourceAvailable)
    }

    private func inventoryDiagnosticCategory(_ failure: CodexMetadataReadFailure) -> DiagnosticCategory {
        switch failure {
        case .databaseMissing: return .inventoryDatabaseMissing
        case .openFailed: return .inventoryDatabaseUnavailable
        case .queryFailed: return .inventoryQueryFailed
        case .readFailed: return .inventoryReadFailed
        }
    }

    private func turnHistoryDiagnosticCategory(_ failure: CodexMetadataReadFailure) -> DiagnosticCategory {
        switch failure {
        case .databaseMissing: return .turnHistoryDatabaseMissing
        case .openFailed: return .turnHistoryDatabaseUnavailable
        case .queryFailed: return .turnHistoryQueryFailed
        case .readFailed: return .turnHistoryReadFailed
        }
    }

    @discardableResult
    private func send(method: String, params: [String: Any], id: Int? = nil) -> Int {
        let requestID = id ?? nextRequestID
        nextRequestID = max(nextRequestID, requestID + 1)
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: ["method": method, "id": requestID, "params": params]),
              let input = inputPipe?.fileHandleForWriting else { return requestID }
        input.write(data)
        input.write(Data([10]))
        return requestID
    }

    private func receive(_ data: Data) {
        guard !localObservationPaused, !workLease.isConfirmedStandby() else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty, let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = message["id"] as? Int, id == 1, message["result"] != nil {
            inputPipe?.fileHandleForWriting.write(Data("{\"method\":\"initialized\",\"params\":{}}\n".utf8))
            requestScan()
            restartTimer()
            return
        }

        if let id = message["id"] as? Int, id == hookRequestID {
            hookReadiness = (message["result"] as? [String: Any]).map(HookReadiness.inspect) ?? .unknown
            return
        }

        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        let threadID = (params["threadId"] as? String) ?? ((params["turn"] as? [String: Any])?["threadId"] as? String)
        guard let threadID else { return }
        let context = contexts[threadID] ?? ThreadContext(id: threadID, title: "Codex task", repo: nil, branch: nil)
        if method == "item/autoApprovalReview/started" {
            diagnostics.record(.attention, category: .appServerAutoReviewStarted)
            automaticReviewThreads.insert(threadID)
            attentionConfirmationTimers[threadID]?.invalidate()
            attentionConfirmationTimers.removeValue(forKey: threadID)
            attentionRequestBuffer.cancel(sessionID: threadID)
            if let turnID = params["turnId"] as? String,
               let pending = pendingAttention[threadID], pending.turn == turnID {
                pendingAttention.removeValue(forKey: threadID)
                postEvent(threadID: threadID, sessionID: turnSessionID(threadID: threadID, turnID: turnID), context: context,
                          status: "working", method: "local/attention/resolved", params: ["turnId": turnID, "marker": pending.marker])
            }
            return
        }
        if method == "item/autoApprovalReview/completed" {
            diagnostics.record(.attention, category: .appServerAutoReviewCompleted)
            automaticReviewThreads.remove(threadID)
            return
        }
        let status: String
        switch method {
        case "turn/started": status = "working"
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            status = turnStatusForCompletion(turn?["status"] as? String)
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            status = "working"
        case "tool/requestUserInput":
            status = "needs_you"
        case "thread/status/changed":
            let statusInfo = params["status"] as? [String: Any]
            guard statusInfo?["type"] as? String == "active" else { return }
            status = "working"
        default: return
        }
        if status == "needs_you" {
            diagnostics.record(.attention, category: .appServerAttention)
            state = .needsYou
        }
        var eventParams = params
        let turnID = (params["turn"] as? [String: Any])?["id"] as? String ?? params["turnId"] as? String
        if let turnID { eventParams["turnId"] = turnID }
        postEvent(threadID: threadID, sessionID: turnID.map { turnSessionID(threadID: threadID, turnID: $0) }, context: context, status: status, method: method, params: eventParams)
    }

    private func handleThread(_ thread: [String: Any], projectedState: LocalSessionState) {
        guard let id = thread["id"] as? String else { return }
        let statusInfo = thread["status"] as? [String: Any]
        let context = ThreadContext(
            id: id,
            title: activityTitle(thread["name"] as? String, thread["title"] as? String),
            repo: ((thread["gitInfo"] as? [String: Any])?["originUrl"] as? String) ?? (thread["cwd"] as? String),
            branch: (thread["gitInfo"] as? [String: Any])?["branch"] as? String,
            parentThreadId: thread["parentThreadId"] as? String
        )
        contexts[id] = context

        // Private Desktop monitoring never opens rollout content; unknown stays unknown.
        let localState = projectedState
        guard let status = connectorStatus(threadType: statusInfo?["type"] as? String, localState: localState) else { return }

        matchedThreadCount += 1
        switch localState {
        case let .working(marker, occurredAt):
            // The inProgress row alone cannot clear attention; same-turn Bash progress can.
            if let pending = pendingAttention[id], pending.turn == marker {
                guard status == "working", hasBashProgress(thread: thread, pending: pending) else { return }
                pendingAttention.removeValue(forKey: id)
                postEvent(threadID: id, sessionID: turnSessionID(threadID: id, turnID: marker), context: context,
                          status: "working", method: "local/attention/resolved", params: ["turnId": marker, "marker": pending.marker])
                return
            }
            if pendingAttention[id] != nil { pendingAttention.removeValue(forKey: id) }
            postEvent(threadID: id, sessionID: turnSessionID(threadID: id, turnID: marker), context: context, status: status, method: "local/task/started", params: ["marker": marker, "turnId": marker, "occurredAt": occurredAt ?? NSNull(), "observedAt": ISO8601DateFormatter().string(from: Date())], deduplicate: false, heartbeatInterval: max(connectorMinimumHeartbeatInterval, intervalSeconds))
        case let .finished(marker, occurredAt):
            if pendingAttention[id]?.turn == marker { pendingAttention.removeValue(forKey: id) }
            postEvent(threadID: id, sessionID: turnSessionID(threadID: id, turnID: marker), context: context, status: status, method: "local/task/completed", params: ["marker": marker, "turnId": marker, "occurredAt": occurredAt ?? NSNull(), "observedAt": ISO8601DateFormatter().string(from: Date())])
        case let .failed(marker, occurredAt):
            if pendingAttention[id]?.turn == marker { pendingAttention.removeValue(forKey: id) }
            postEvent(threadID: id, sessionID: turnSessionID(threadID: id, turnID: marker), context: context, status: status, method: "turn/completed", params: ["marker": marker, "turnId": marker, "occurredAt": occurredAt ?? NSNull(), "observedAt": ISO8601DateFormatter().string(from: Date()), "turn": ["status": "failed"]])
        case let .stale(marker, occurredAt):
            if pendingAttention[id]?.turn == marker { pendingAttention.removeValue(forKey: id) }
            postEvent(threadID: id, sessionID: turnSessionID(threadID: id, turnID: marker), context: context, status: status, method: "local/task/aborted", params: ["marker": marker, "turnId": marker, "occurredAt": occurredAt ?? NSNull(), "observedAt": ISO8601DateFormatter().string(from: Date())])
        case .unknown:
            if status == "needs_you" { state = .needsYou }
            postEvent(threadID: id, context: context, status: status, method: "thread/status/changed", params: ["status": statusInfo ?? [:], "observedAt": ISO8601DateFormatter().string(from: Date())], deduplicate: false, heartbeatInterval: max(connectorMinimumHeartbeatInterval, intervalSeconds))
        }
    }

    func handleHook(_ data: Data) {
        guard isRunning, !localObservationPaused, !workLease.isConfirmedStandby() else { return }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventName = payload["hook_event_name"] as? String,
              let sessionID = payload["session_id"] as? String else { return }
        lastHookAt = Date()
        if questionAlertsEnabled, payload["questionCount"] != nil {
            stageQuestions(payload)
            return
        }
        let eventThreadID = (payload["agent_id"] as? String) ?? sessionID
        if internalReviewThreads.contains(eventThreadID) {
            pendingAttention.removeValue(forKey: eventThreadID)
            return
        }
        // A hook can precede inventory discovery. Unknown metadata waits for history
        // recovery instead of creating an unclassified conversation or phone alert.
        guard threadStore.permitsHook(threadID: eventThreadID) else { return }

        // PostToolUse lets repeated approvals in the same run become distinct requests.
        // Unrelated tool results must not clear an outstanding approval.
        if eventName == "PostToolUse" {
            let tool = payload["tool_name"] as? String ?? "unknown"
            if attentionRequestBuffer.cancel(sessionID: sessionID, turnID: payload["turn_id"] as? String ?? "", tool: tool) != nil {
                attentionConfirmationTimers[sessionID]?.invalidate()
                attentionConfirmationTimers.removeValue(forKey: sessionID)
                heartbeatThrottle.reset()
                scanLocalHistory()
                return
            }
            guard let pending = pendingAttention[sessionID],
                  pending.turn == payload["turn_id"] as? String,
                  pending.tool == payload["tool_name"] as? String else { return }
            pendingAttention.removeValue(forKey: sessionID)
            let context = contexts[sessionID] ?? ThreadContext(id: sessionID, title: "Codex task", repo: nil, branch: nil)
            postEvent(threadID: sessionID, sessionID: turnSessionID(threadID: sessionID, turnID: pending.turn), context: context,
                      status: "working", method: "local/attention/resolved", params: ["turnId": pending.turn, "marker": pending.marker])
            heartbeatThrottle.reset()
            scanLocalHistory()
            return
        }
        if eventName == "PermissionRequest" {
            diagnostics.record(.attention, category: .approvalHook)
            return
        }
        guard let status = statusForHookEvent(eventName) else { return }
        guard let turnID = payload["turn_id"] as? String, !turnID.isEmpty else {
            lastError = "Hook omitted run identity; waiting for local history."
            return
        }

        let agentID = payload["agent_id"] as? String
        let eventSessionID = agentID ?? sessionID
        if status == "needs_you" {
            diagnostics.record(.attention, category: .approvalHook)
            guard !automaticReviewThreads.contains(eventSessionID) else { return }
            let tool = payload["tool_name"] as? String ?? "unknown"
            let existing = attentionRequestBuffer.candidates[eventSessionID]
            let candidate = existing?.turn == turnID && existing?.tool == tool
                ? existing!
                : PendingAttention(turn: turnID, marker: UUID().uuidString, tool: tool)
            attentionRequestBuffer.stage(sessionID: eventSessionID, attention: candidate)
            attentionConfirmationTimers[eventSessionID]?.invalidate()
            attentionConfirmationTimers[eventSessionID] = Timer.scheduledTimer(withTimeInterval: confirmationDelay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.confirmAttentionRequest(sessionID: eventSessionID, turnID: turnID) }
            }
            return
        }
        attentionConfirmationTimers[eventSessionID]?.invalidate()
        attentionConfirmationTimers.removeValue(forKey: eventSessionID)
        attentionRequestBuffer.cancel(sessionID: eventSessionID)
        pendingAttention.removeValue(forKey: eventSessionID)
        let context = contexts[eventSessionID] ?? ThreadContext(
            id: eventSessionID,
            title: agentID == nil ? "Codex task \(shortID(sessionID))" : "Codex subagent \(shortID(agentID ?? sessionID))",
            repo: payload["cwd"] as? String,
            branch: nil
        )
        let params: [String: Any] = [
            "marker": turnID,
            "turnId": turnID,
            "attentionId": NSNull(),
            "detail": "Codex hook: \(eventName)"
        ]
        postEvent(threadID: eventSessionID, sessionID: turnSessionID(threadID: eventSessionID, turnID: turnID), context: context, status: status, method: "codex/hook/\(eventName)", params: params)
    }

    private func confirmAttentionRequest(sessionID: String, turnID: String) {
        attentionConfirmationTimers.removeValue(forKey: sessionID)
        guard isRunning, !localObservationPaused, !workLease.isConfirmedStandby(), !automaticReviewThreads.contains(sessionID),
              let candidate = attentionRequestBuffer.promote(sessionID: sessionID, turnID: turnID) else { return }
        if let thread = cachedThreads.first(where: { $0["id"] as? String == sessionID }),
           hasBashProgress(thread: thread, pending: candidate) {
            return
        }
        pendingAttention[sessionID] = candidate
        state = .needsYou
        let context = contexts[sessionID] ?? ThreadContext(id: sessionID, title: "Codex task", repo: nil, branch: nil)
        postEvent(threadID: sessionID, sessionID: turnSessionID(threadID: sessionID, turnID: turnID), context: context,
                  status: "needs_you", method: "codex/hook/PermissionRequest",
                  params: ["marker": candidate.marker, "turnId": turnID, "attentionId": candidate.marker])
    }

    private func hasBashProgress(thread: [String: Any], pending: PendingAttention) -> Bool {
        guard pending.tool == "Bash", let historyID = thread["historyId"] as? String else { return false }
        return turnStateStore.hasBashProgress(threadID: historyID, turnID: pending.turn, after: pending.createdAt)
    }

    private func shortID(_ value: String) -> String {
        String(value.prefix(8))
    }

    private func postEvent(threadID: String, sessionID: String? = nil, context: ThreadContext, status: String, method: String, params: [String: Any], deduplicate: Bool = true, heartbeatInterval: TimeInterval? = nil) {
        guard (!token.isEmpty || eventSink != nil), !internalReviewThreads.contains(threadID) else { return }
        let occurredAt = (params["occurredAt"] as? String) ?? ISO8601DateFormatter().string(from: Date())
        let candidateStart = (params["turnId"] as? String).map { LocalSessionState.working(marker: $0, occurredAt: occurredAt) }
        if status == "working", let turnID = params["turnId"] as? String,
           let candidateStart,
           latestStartedTurns[threadID].map({ mostRecentLocalSessionState($0, candidateStart).marker == turnID }) ?? true,
           !supersededCompletionSessions.contains(turnSessionID(threadID: threadID, turnID: turnID)) {
            // Remember the transition even if the old Stop/poll has not arrived yet.
            // A lagging poll for an already superseded turn cannot reverse it.
            if let previous = latestStartedTurns[threadID]?.marker, previous != turnID {
                supersededCompletionSessions.insert(turnSessionID(threadID: threadID, turnID: previous))
            }
            latestStartedTurns[threadID] = candidateStart
            for key in Array(pendingCompletions.keys) {
                if pendingCompletions[key]?.event["threadId"] as? String == threadID,
                   let previous = pendingCompletions[key]?.event["turnId"] as? String,
                   previous != turnID {
                    supersededCompletionSessions.insert(turnSessionID(threadID: threadID, turnID: previous))
                    pendingCompletions[key]?.event["notificationEligible"] = false
                }
            }
        }
        let marker = (params["marker"] as? String) ?? (params["turnId"] as? String) ?? ""
        let eventKey = connectorEventKey(threadID: threadID, method: method, status: status, marker: marker)
        let heartbeatKey = "\(eventKey):\(sessionID ?? threadID):\(context.title):\(context.repo ?? ""):\(context.branch ?? "")"
        let metadataUpdate = deduplicate && reportedEventKeys.contains(eventKey) && pendingCompletions[eventKey] == nil
        if deduplicate { guard reportedEventKeys.insert(eventKey, metadata: heartbeatKey) else { return } }
        if let heartbeatInterval {
            guard heartbeatThrottle.shouldSend(heartbeatKey, now: Date(), minimumInterval: heartbeatInterval) else { return }
        }
        let eventID = SHA256.hash(data: Data(eventKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let observedAt = (params["observedAt"] as? String)
        let resolvedSessionID = sessionID ?? threadID
        var event: [String: Any] = [
            "sessionId": resolvedSessionID,
            "threadId": threadID,
            "turnId": params["turnId"] ?? NSNull(),
            "attentionId": params["attentionId"] ?? NSNull(),
            "eventId": "codex-\(eventID.prefix(32))",
            "eventType": method,
            "title": activityTitle(context.title),
            "repo": context.repo.map { String($0.split(separator: "?").first?.split(separator: "#").first?.split(separator: "/").last ?? "").replacingOccurrences(of: ".git", with: "") } ?? NSNull(),
            "branch": NSNull(),
            "status": status,
            "statusDetail": status == "needs_you" ? "Waiting for your input" : status == "failed" ? "Run failed" : status == "finished" ? "Run finished, assignment outcome not evaluated" : status == "stale" ? "Run interrupted" : "Run in progress; may be waiting for input",
            "label": method.replacingOccurrences(of: "/", with: " "),
            "detail": "",
            "tone": status == "needs_you" ? "attention" : status == "working" ? "working" : status == "finished" ? "success" : status == "failed" || status == "stale" ? "danger" : "quiet",
            "occurredAt": occurredAt,
            "observedAt": observedAt ?? NSNull(),
            "startedAt": status == "working" ? occurredAt : NSNull(),
            "finishedAt": ["finished", "failed", "stale"].contains(status) ? occurredAt : NSNull()
        ]
        // Carry the link on future activity too, including hooks outside the discovery window.
        let hookParent = contexts[threadID] == nil ? threadStore.thread(id: threadID)?["parentThreadId"] as? String : nil
        if let parent = context.parentThreadId ?? hookParent,
           UUID(uuidString: parent) != nil, UUID(uuidString: threadID) != nil,
           parent.lowercased() != threadID.lowercased() { event["parentThreadId"] = parent.lowercased() }
        // Reuse the lifecycle identity to repair metadata without another completion alert.
        if metadataUpdate { event["notificationEligible"] = false }
        if status == "finished", supersededCompletionSessions.contains(resolvedSessionID) {
            event["notificationEligible"] = false
        }
        if status == "finished", pendingCompletions[eventKey]?.event["notificationEligible"] as? Bool == false {
            event["notificationEligible"] = false
        }
        let currentStandbyInterval = standbyStartedAt.map { DateInterval(start: $0, end: max($0, Date())) }
        if occurredDuringStandby(occurredAt, interval: lastStandbyInterval)
            || occurredDuringStandby(occurredAt, interval: currentStandbyInterval) {
            event["notificationEligible"] = false
        }
        if event["notificationEligible"] as? Bool != false,
           status == "finished", let turnID = params["turnId"] as? String {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let finishedAt = parser.date(from: occurredAt) ?? ISO8601DateFormatter().date(from: occurredAt)
            if let finishedAt, (-60..<600).contains(Date().timeIntervalSince(finishedAt)),
               let preview = finalReplyStore.preview(threadID: threadID, turnID: turnID) {
                event["replyPreview"] = preview
            }
        }
        // Metadata repairs preserve both the suppression decision and the original deadline.
        if status == "finished", let pending = pendingCompletions[eventKey] {
            if event["notificationEligible"] as? Bool != false, event["replyPreview"] == nil {
                event["replyPreview"] = pending.event["replyPreview"]
            }
            pendingCompletions[eventKey] = PendingCompletion(event: event, heartbeatKey: heartbeatKey, observedAt: pending.observedAt)
            return
        }
        if status == "finished", event["notificationEligible"] as? Bool != false {
            pendingCompletions[eventKey] = PendingCompletion(event: event, heartbeatKey: heartbeatKey, observedAt: Date())
            scheduleCompletionConfirmation()
            return
        }
        _ = enqueueEvent(event, eventKey: eventKey, heartbeatKey: heartbeatKey)
    }

    private func scheduleCompletionConfirmation() {
        guard completionTimer == nil, !pendingCompletions.isEmpty else { return }
        let now = Date()
        let delay = pendingCompletions.values.map { pending in
            let remaining = completionConfirmationDelay - now.timeIntervalSince(pending.observedAt)
            return remaining > 0 ? remaining : completionConfirmationDelay
        }.min() ?? completionConfirmationDelay
        completionTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, delay), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.completionTimer = nil
                self?.confirmPendingCompletions()
            }
        }
    }

    // Re-read the inventory as well as turn history: resumed tasks can rotate their history identity.
    func confirmPendingCompletions(now: Date = Date()) {
        guard isRunning, !localObservationPaused, !workLease.isConfirmedStandby(), !pendingCompletions.isEmpty else { return }
        let threads = threadStore.threads() ?? []
        let histories = turnStateStore.histories(forThreads: threads)
        let latest = histories.compactMapValues { $0.first }
        for (key, pending) in pendingCompletions {
            guard now.timeIntervalSince(pending.observedAt) >= completionConfirmationDelay else { continue }
            var event = pending.event
            guard let threadID = event["threadId"] as? String, let turnID = event["turnId"] as? String else { continue }
            // A live Start absent from the projection is stronger evidence than its old completion.
            // Once history catches up, a later genuine completion can still become eligible.
            if let startedTurn = latestStartedTurns[threadID]?.marker, startedTurn != turnID,
               !(histories[threadID] ?? []).contains(where: { $0.marker == startedTurn }) {
                event["notificationEligible"] = false
            }
            let stillFinished: Bool
            if case let .finished(marker, _) = latest[threadID] { stillFinished = marker == turnID }
            else { stillFinished = false }
            if latest[threadID] == nil || latest[threadID] == .unknown {
                // Unavailable metadata cannot establish that the owner is needed.
                guard now.timeIntervalSince(pending.observedAt) >= 600 else { continue }
                event["notificationEligible"] = false
            } else if !stillFinished {
                event["notificationEligible"] = false
            }
            if !completionAncestorsIdle(threadID: threadID, threads: threads, histories: histories) {
                event["notificationEligible"] = false
            }
            if internalReviewThreads.contains(threadID) || !threadStore.permitsHook(threadID: threadID) {
                event["notificationEligible"] = false
            }
            if enqueueEvent(event, eventKey: key, heartbeatKey: pending.heartbeatKey) {
                pendingCompletions.removeValue(forKey: key)
            }
        }
        completionTimer?.invalidate()
        completionTimer = nil
        scheduleCompletionConfirmation()
    }

    private func completionAncestorsIdle(threadID: String, threads: [[String: Any]], histories: [String: [LocalSessionState]]) -> Bool {
        guard var thread = threads.first(where: { $0["id"] as? String == threadID }) ?? threadStore.thread(id: threadID) else { return false }
        var visited: Set<String> = [threadID]
        while thread["isSubagent"] as? Bool == true {
            guard let parentID = thread["parentThreadId"] as? String, !parentID.isEmpty,
                  visited.count < 32, visited.insert(parentID).inserted,
                  let parent = threads.first(where: { $0["id"] as? String == parentID }) ?? threadStore.thread(id: parentID) else { return false }
            // Unknown or still-running ancestors cannot establish that a child needs the owner.
            let history = histories[parentID] ?? turnStateStore.histories(forThreads: [parent])[parentID] ?? []
            guard case let .finished(marker, _) = history.first else { return false }
            // A parent Start can arrive before its SQLite projection catches up.
            if let observedStart = latestStartedTurns[parentID]?.marker, observedStart != marker { return false }
            thread = parent
        }
        return true
    }

    private func stageQuestions(_ payload: [String: Any]) {
        guard let hookID = payload["agent_id"] as? String ?? payload["session_id"] as? String,
              let turn = payload["turn_id"] as? String,
              let call = payload["tool_use_id"] as? String,
              call.range(of: "^call_[A-Za-z0-9_-]{1,180}$", options: .regularExpression) != nil,
              let count = payload["questionCount"] as? Int, (1...64).contains(count) else { return }
        // Desktop hook identities may refer to the resumed projection rather than the stable chat.
        let thread = cachedThreads.first { $0["id"] as? String == hookID || $0["historyId"] as? String == hookID }
            ?? threadStore.thread(id: hookID)
        guard let thread, let id = thread["id"] as? String,
              !internalReviewThreads.contains(id), threadStore.permitsHook(threadID: id) else { return }
        for index in 0..<count {
            let attention = "\(call):\(index)"
            let key = "\(id):\(attention)"
            if questions[key] == nil && reportedQuestionAnswers[key] == nil {
                questions[key] = PendingQuestion(threadID: id, turnID: turn, attentionID: attention, requestedAt: Date())
            }
        }
        questionTimer?.invalidate()
        questionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.questionTimer = nil; self?.confirmQuestions() }
        }
    }

    func confirmQuestions(now: Date = Date()) {
        guard questionAlertsEnabled, isRunning, !localObservationPaused, !workLease.isConfirmedStandby() else { return }
        questions = questions.filter { now.timeIntervalSince($0.value.requestedAt) < 3_600 }
        reportedQuestionAnswers = reportedQuestionAnswers.filter { now.timeIntervalSince($0.value) < 3_600 }
        var questionThreads = cachedThreads
        let cachedQuestionIDs = Set(cachedThreads.compactMap { $0["id"] as? String })
        for id in Set(questions.values.map(\.threadID)).subtracting(cachedQuestionIDs) {
            if let thread = threadStore.thread(id: id) { questionThreads.append(thread) }
        }
        for thread in questionThreads {
            guard let id = thread["id"] as? String, !internalReviewThreads.contains(id) else { continue }
            let history = thread["historyId"] as? String ?? id
            // Unknown source state withholds new alerts. Ordinary work, Stop and new turns never clear questions.
            guard let answers = questionAnswerStore.read(historyID: history, since: now.addingTimeInterval(-3_600)) else { continue }
            for answer in answers {
                let key = "\(id):\(answer.attentionID)"
                questions.removeValue(forKey: key)
                if reportedQuestionAnswers[key] == nil,
                   emitQuestion(thread: thread, turn: answer.turnID, attention: answer.attentionID,
                     method: "local/question/answered", occurredAt: answer.answeredAt) {
                    reportedQuestionAnswers[key] = answer.answeredAt
                }
            }
            for key in Array(questions.keys) {
                guard let question = questions[key], question.threadID == id, !question.announced,
                      now.timeIntervalSince(question.requestedAt) >= 5 else { continue }
                if emitQuestion(thread: thread, turn: question.turnID, attention: question.attentionID,
                    method: "local/question/opened", occurredAt: question.requestedAt) {
                    questions[key]?.announced = true
                }
            }
        }
    }

    @discardableResult private func emitQuestion(thread: [String: Any], turn: String, attention: String,
                                               method: String, occurredAt: Date) -> Bool {
        guard let id = thread["id"] as? String else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let key = "\(id):\(attention):\(method)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let event: [String: Any] = [
            "eventId": "question-\(hash.prefix(32))", "eventType": method,
            "sessionId": turnSessionID(threadID: id, turnID: turn), "threadId": id, "turnId": turn,
            "attentionId": attention, "title": activityTitle(thread["title"] as? String),
            "status": "working", "occurredAt": formatter.string(from: occurredAt)
        ]
        return enqueueEvent(event, eventKey: key, heartbeatKey: key)
    }

    private func clearPendingCompletions() {
        completionTimer?.invalidate()
        completionTimer = nil
        for key in pendingCompletions.keys { reportedEventKeys.remove(key) }
        pendingCompletions.removeAll()
        latestStartedTurns.removeAll()
        supersededCompletionSessions.removeAll()
    }

    private func enqueueEvent(_ event: [String: Any], eventKey: String, heartbeatKey: String) -> Bool {
        guard JSONSerialization.isValidJSONObject(event), let body = try? JSONSerialization.data(withJSONObject: event),
              let eventID = event["eventId"] as? String else { return false }
        if let eventSink { eventSink(event); return true }
        do {
            try outbox.enqueue(id: eventID, body: body)
            diagnostics.success(.localQueue, queued: pendingEventCount)
            drainOutbox()
            return true
        } catch {
            reportedEventKeys.remove(eventKey)
            heartbeatThrottle.remove(heartbeatKey)
            lastError = "Could not queue event locally; check available disk space."
            diagnostics.record(.localQueue, category: .localStorage, queued: pendingEventCount)
            return false
        }
    }

    private func drainOutbox() {
        guard isRunning, workLease.allowsWork(), !drainingOutbox, Date() >= deliveryRetryAfter, !token.isEmpty,
              let url = URL(string: "\(siteURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/events"),
              url.scheme == "https", url.user == nil, url.password == nil else { return }
        drainingOutbox = true
        Task {
            defer { drainingOutbox = false }
            let result = await deliverBatch(outbox: outbox, shouldContinue: { self.isRunning && self.workLease.allowsWork() }, diagnostics: diagnostics, attempts: deliveryAttempts) { body in
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.httpMethod = "POST"
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
                let (_, response) = try await ConnectionTelemetry.recorder.data(for: request, session: ingestSession, operation: .upload, trigger: .automatic)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return http.statusCode
            }
            sentEventCount += result.sent
            pendingEventCount = result.pending
            lastError = result.error
            if result.error != nil {
                scheduleDeliveryRetry()
            } else {
                deliveryFailures = 0
                deliveryRetryAfter = .distantPast
            }
        }
    }

    private func scheduleDeliveryRetry() {
        deliveryFailures = min(8, deliveryFailures + 1)
        deliveryRetryAfter = Date().addingTimeInterval(connectorRetryDelay(failures: deliveryFailures))
    }

    private func sendHealth(sourceAvailable: Bool) {
        guard workLease.allowsWork(), Date().timeIntervalSince(healthSentAt) >= 60, !token.isEmpty,
              let url = URL(string: "\(siteURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/collector"), url.scheme == "https" else { return }
        healthSentAt = Date()
        let body: [String: Any] = [
            "sourceAvailable": sourceAvailable,
            "hookTrust": hookReadiness == .ready ? "trusted" : hookReadiness == .untrusted ? "untrusted" : "unknown",
            "lastHookAt": lastHookAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "queued": pendingEventCount
        ]
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        Task {
            do {
                let (_, response) = try await ConnectionTelemetry.recorder.data(for: request, session: ingestSession, operation: .health, trigger: .automatic)
                if let http = response as? HTTPURLResponse {
                    if (200..<300).contains(http.statusCode) { diagnostics.success(.collectorHealth, queued: pendingEventCount) }
                    else { diagnostics.record(.collectorHealth, category: .http, httpStatus: http.statusCode, queued: pendingEventCount) }
                } else { diagnostics.record(.collectorHealth, category: .connection, queued: pendingEventCount) }
            } catch { diagnostics.record(.collectorHealth, category: DiagnosticHistory.category(for: error), queued: pendingEventCount) }
        }
    }

    private struct ThreadContext {
        let id: String
        let title: String
        let repo: String?
        let branch: String?
        var parentThreadId: String? = nil
    }
}
