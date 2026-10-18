import ArgumentParser
import Foundation

/// Turns a coding agent's hook payload into what its card says.
///
/// Claude Code hooks write JSON to stdin with snake_case keys (`hook_event_name`, `session_id`,
/// `cwd`, `message`, `notification_type`, `last_assistant_message`). Codex's `notify` appends JSON
/// with kebab-case keys (`type`, `thread-id`, `cwd`, `last-assistant-message`). Both spellings are
/// read for either agent, so Codex hooks that use Claude's shape work too.
public enum AgentHook {
    public enum Agent: String, CaseIterable, Sendable, ExpressibleByArgument {
        case claude, codex

        /// The name a title falls back to when the payload has no working directory.
        public var displayName: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            }
        }
    }

    /// The most a payload read from stdin may be. A Stop payload carries the agent's whole last
    /// message, which can be long.
    public static let payloadLimit = 4 * 1024 * 1024

    /// What the card says.
    public struct Event: Equatable, Sendable {
        /// A preset name: `ok` when the agent is done, `warn` when it waits on a decision, `info`
        /// when it is only idle.
        public var kind: String
        public var title: String
        public var detail: String?
        /// `<agent>:<session>`, so a session's newer card replaces its older one.
        public var id: String?

        public init(kind: String, title: String, detail: String? = nil, id: String? = nil) {
            self.kind = kind
            self.title = title
            self.detail = detail
            self.id = id
        }
    }

    /// Reads a payload. Throws a `UsageError` when it is not a JSON object.
    public static func event(agent: Agent, payload: String) throws -> Event {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any]
        else {
            throw UsageError("the \(agent.rawValue) hook payload is not a JSON object")
        }
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = fields[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
            return nil
        }

        let event = string("hook_event_name", "type")
        let message = string("message")
        let lastMessage = string("last_assistant_message", "last-assistant-message")
        let project = string("cwd").flatMap(projectName) ?? agent.displayName
        let session = string("session_id", "thread-id", "thread_id")
        let id = session.map { "\(agent.rawValue):\($0)" }

        let done: Bool
        switch event {
        case "Stop", "SubagentStop", "agent-turn-complete":
            done = true
        case nil:
            done = message == nil && lastMessage != nil
        default:
            done = false
        }
        if done {
            return Event(kind: Preset.ok.name, title: "\(project) is done", detail: lastMessage ?? message, id: id)
        }

        let kind: String
        switch (event, string("notification_type")) {
        case ("PermissionRequest", _), (_, "permission_prompt"), (_, "elicitation_dialog"):
            kind = Preset.warn.name
        default:
            kind = Preset.info.name
        }
        let tool = string("tool_name").map { "wants to use \($0)" }
        return Event(kind: kind, title: "\(project) needs you", detail: message ?? tool, id: id)
    }

    /// The last component of a working directory, or nil for the root.
    static func projectName(_ path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init)
        return name?.isEmpty == false ? name : nil
    }
}
