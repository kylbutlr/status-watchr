import Foundation

enum HookReadiness: String {
    case unknown = "Hook trust not checked"
    case missing = "Hook installation incomplete"
    case untrusted = "Review and trust hooks in Codex"
    case ready = "Hooks trusted; execution not yet verified"

    static func inspect(_ result: [String: Any]) -> HookReadiness {
        // hooks/list is grouped by event, not necessarily flat across Codex versions.
        var handlers: [[String: Any]] = []
        func visit(_ value: Any) {
            if let object = value as? [String: Any] {
                if let command = object["command"] as? String, command == CodexHookInstaller.command {
                    handlers.append(object)
                }
                for child in object.values { visit(child) }
            } else if let array = value as? [Any] { array.forEach(visit) }
        }
        visit(result)
        let expected = Set(CodexHookInstaller.eventNames.map { $0.prefix(1).lowercased() + $0.dropFirst() })
        let discovered = Set(handlers.compactMap { $0["eventName"] as? String })
        guard expected.isSubset(of: discovered) else { return .missing }
        guard handlers.allSatisfy({ $0["enabled"] as? Bool == true && $0["trustStatus"] as? String == "trusted" }) else { return .untrusted }
        return .ready
    }
}
