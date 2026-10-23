import Foundation
import Network

final class CodexHookServer: @unchecked Sendable {
    static let port: UInt16 = 48732

    private let queue = DispatchQueue(label: "com.kylbutlr.statuswatchr.codex-hooks")
    private let onEvent: (Data) -> Void
    private var listener: NWListener?

    init(onEvent: @escaping (Data) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { state in
                if case .failed = state { listener.cancel() }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.receive(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            listener = nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, _ in
            var buffered = buffered
            if let data { buffered.append(data) }

            if let request = Self.parseRequest(buffered) {
                self?.onEvent(request)
                Self.respond(to: connection, status: "204 No Content")
                return
            }

            if buffered.count > 65_536 || isComplete {
                Self.respond(to: connection, status: "400 Bad Request")
                return
            }

            self?.receive(connection, buffered: buffered)
        }
    }

    static func parseRequest(_ data: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator),
              let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8),
              header.hasPrefix("POST /codex-hook HTTP/1.1\r\n"),
              header.lowercased().contains("\r\ncontent-type: application/json"),
              !header.lowercased().contains("\r\norigin:") else { return nil }
        let contentLength = header.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        let bodyStart = headerEnd.upperBound
        guard contentLength > 0, contentLength <= 65_536, data.count >= bodyStart + contentLength,
              let payload = try? JSONSerialization.jsonObject(with: Data(data[bodyStart..<(bodyStart + contentLength)])) as? [String: Any] else { return nil }
        // Raw hook stdin can contain prompts and tool output. Drop it here, before callbacks or persistence.
        let fields = Set(["hook_event_name", "session_id", "turn_id", "agent_id", "tool_name"])
        var metadata = payload.filter { fields.contains($0.key) && (($0.value as? String)?.count ?? Int.max) <= 250 }
        metadata.merge(QuestionHookMetadata.extract(payload)) { _, new in new }
        return try? JSONSerialization.data(withJSONObject: metadata)
    }

    private static func respond(to connection: NWConnection, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
