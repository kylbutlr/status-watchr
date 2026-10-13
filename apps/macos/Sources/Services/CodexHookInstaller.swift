import Foundation

enum CodexHookInstaller {
    static let command = "/usr/bin/curl --silent --max-time 1 --output /dev/null --header 'Content-Type: application/json' --data-binary @- http://127.0.0.1:48731/codex-hook"
    static let legacyCommand = "/usr/bin/curl --silent --show-error --max-time 1 --output /dev/null --data-binary @- http://127.0.0.1:48731/codex-hook"
    static let eventNames = ["UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SubagentStart", "SubagentStop"]

    private static var hooksURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/hooks.json")
    }

    static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: hooksURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return eventNames.allSatisfy { eventName in
            guard let groups = hooks[eventName] as? [[String: Any]] else { return false }
            return groups.contains { group in containsCommand(group) }
        }
    }

    static func install() throws {
        var root = try readRoot()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for eventName in eventNames {
            var groups = hooks[eventName] as? [[String: Any]] ?? []
            groups = groups.compactMap { group in
                var copy = group
                let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter { $0["command"] as? String != legacyCommand }
                guard !handlers.isEmpty else { return nil }
                copy["hooks"] = handlers
                return copy
            }
            if !groups.contains(where: { containsCommand($0) }) {
                groups.append([
                    "hooks": [[
                        "type": "command",
                        "command": command,
                        "async": true,
                        "timeout": 1,
                        "statusMessage": "Sending Status Watchr update"
                    ]]
                ])
            }
            hooks[eventName] = groups
        }
        root["hooks"] = hooks
        try writeRoot(root)
    }

    static func remove() throws {
        var root = try readRoot()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for eventName in eventNames {
            guard let groups = hooks[eventName] as? [[String: Any]] else { continue }
            let remaining = groups.compactMap { group -> [String: Any]? in
                var copy = group
                let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter { ![command, legacyCommand].contains($0["command"] as? String ?? "") }
                guard !handlers.isEmpty else { return nil }
                copy["hooks"] = handlers
                return copy
            }
            if remaining.isEmpty { hooks.removeValue(forKey: eventName) }
            else { hooks[eventName] = remaining }
        }
        root["hooks"] = hooks
        try writeRoot(root)
    }

    private static func containsCommand(_ group: [String: Any]) -> Bool {
        guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
        return handlers.contains { $0["type"] as? String == "command" && $0["command"] as? String == command }
    }

    private static func readRoot() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return [:] }
        let data = try Data(contentsOf: hooksURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallerError.invalidHooksFile
        }
        return root
    }

    private static func writeRoot(_ root: [String: Any]) throws {
        let directory = hooksURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: hooksURL, options: .atomic)
    }

    enum HookInstallerError: LocalizedError {
        case invalidHooksFile

        var errorDescription: String? {
            switch self {
            case .invalidHooksFile: "The existing Codex hooks file is not valid JSON."
            }
        }
    }
}
