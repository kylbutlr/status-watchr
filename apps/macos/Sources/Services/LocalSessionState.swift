import Foundation

enum LocalSessionState: Equatable {
    case working(marker: String, occurredAt: String?)
    case finished(marker: String, occurredAt: String?)
    case failed(marker: String, occurredAt: String?)
    case stale(marker: String, occurredAt: String?)
    case unknown

    var occurredAt: String? {
        switch self {
        case let .working(_, occurredAt), let .finished(_, occurredAt), let .failed(_, occurredAt), let .stale(_, occurredAt): occurredAt
        case .unknown: nil
        }
    }

    var marker: String? {
        switch self {
        case let .working(marker, _), let .finished(marker, _), let .failed(marker, _), let .stale(marker, _): marker
        case .unknown: nil
        }
    }

    static func from(fileAt path: String, maxBytes: UInt64 = 1_048_576) -> LocalSessionState {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return .unknown }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let start = fileSize > maxBytes ? fileSize - maxBytes : 0
        try? handle.seek(toOffset: start)
        return from(jsonl: handle.readDataToEndOfFile())
    }

    static func from(jsonl data: Data) -> LocalSessionState {
        var latest = LocalSessionState.unknown

        for line in data.split(separator: 10) {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  message["type"] as? String == "event_msg",
                  let payload = message["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else { continue }

            let explicitMarker = (payload["turn_id"] as? String) ?? (payload["turnId"] as? String)
            let marker = explicitMarker ?? "unknown"
            let timestampKey = eventType == "task_started" ? "started_at" : "completed_at"
            let occurredAt = (payload[timestampKey] as? String) ?? (message["timestamp"] as? String)
            switch eventType {
            case "task_started": latest = .working(marker: marker, occurredAt: occurredAt)
            case "task_complete": latest = .finished(marker: marker, occurredAt: occurredAt)
            case "turn_aborted": latest = .stale(marker: marker, occurredAt: occurredAt)
            default:
                guard let explicitMarker else { continue }
                switch latest {
                case let .working(currentMarker, _):
                    if shouldAdvanceTurn(from: currentMarker, to: explicitMarker) {
                        latest = .working(marker: explicitMarker, occurredAt: occurredAt)
                    }
                case let .finished(currentMarker, _), let .failed(currentMarker, _), let .stale(currentMarker, _):
                    if shouldAdvanceTurn(from: currentMarker, to: explicitMarker) {
                        latest = .working(marker: explicitMarker, occurredAt: occurredAt)
                    }
                case .unknown:
                    latest = .working(marker: explicitMarker, occurredAt: occurredAt)
                }
            }
        }

        return latest
    }
}

func mostRecentLocalSessionState(_ first: LocalSessionState, _ second: LocalSessionState) -> LocalSessionState {
    if first == .unknown { return second }
    if second == .unknown { return first }
    if let firstMarker = first.marker,
       let secondMarker = second.marker,
       firstMarker != secondMarker,
       let markerOrder = compareCodexTurnMarkers(firstMarker, secondMarker) {
        return markerOrder == .orderedDescending ? first : second
    }
    let firstTime = first.occurredAt.flatMap(parseLocalSessionTimestamp)
    let secondTime = second.occurredAt.flatMap(parseLocalSessionTimestamp)
    switch (firstTime, secondTime) {
    case let (firstTime?, secondTime?): return firstTime >= secondTime ? first : second
    case (.some, .none): return first
    case (.none, .some): return second
    case (.none, .none): return first
    }
}

private func shouldAdvanceTurn(from currentMarker: String, to candidateMarker: String) -> Bool {
    guard currentMarker != candidateMarker else { return false }
    return compareCodexTurnMarkers(candidateMarker, currentMarker) != .orderedAscending
}

private func compareCodexTurnMarkers(_ first: String, _ second: String) -> ComparisonResult? {
    guard isCodexVersionSevenUUID(first), isCodexVersionSevenUUID(second) else { return nil }
    return first.lowercased().compare(second.lowercased())
}

private func isCodexVersionSevenUUID(_ value: String) -> Bool {
    let components = value.split(separator: "-", omittingEmptySubsequences: false)
    return components.count == 5 && components[2].first == "7" && UUID(uuidString: value) != nil
}

private func parseLocalSessionTimestamp(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
}
