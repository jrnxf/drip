import ArgumentParser
import Foundation

/// Turns a coding agent's hook payload into what its card says.
///
/// Claude Code hooks write JSON to stdin with snake_case keys (`hook_event_name`, `session_id`,
/// `cwd`, `message`, `notification_type`, `last_assistant_message`). Codex's `notify` appends JSON
/// with kebab-case keys (`type`, `thread-id`, `cwd`, `last-assistant-message`). Each agent is read
/// only in its own shape.
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

    /// Reads a payload. Throws a `UsageError` when it is not a JSON object or not an event this agent
    /// sends: a Claude `Notification` or `Stop`, or a Codex `agent-turn-complete`.
    public static func event(agent: Agent, payload: String) throws -> Event {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any]
        else {
            throw UsageError("the \(agent.rawValue) hook payload is not a JSON object")
        }
        func string(_ key: String) -> String? {
            guard let value = fields[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return value
        }
        func project() -> String {
            string("cwd").flatMap(projectName) ?? agent.displayName
        }

        switch agent {
        case .claude:
            let id = string("session_id").map { "claude:\($0)" }
            switch string("hook_event_name") {
            case "Notification":
                let kind: String
                switch string("notification_type") {
                case "permission_prompt", "elicitation_dialog": kind = Preset.warn.name
                default: kind = Preset.info.name
                }
                return Event(kind: kind, title: "\(project()) needs you", detail: string("message"), id: id)
            case "Stop":
                return Event(
                    kind: Preset.ok.name, title: "\(project()) is done",
                    detail: string("last_assistant_message"), id: id)
            case let name:
                let found = name.map { "'\($0)'" } ?? "with no hook_event_name"
                throw UsageError("unknown claude hook event \(found): expected Notification or Stop")
            }
        case .codex:
            let id = string("thread-id").map { "codex:\($0)" }
            switch string("type") {
            case "agent-turn-complete":
                return Event(
                    kind: Preset.ok.name, title: "\(project()) is done",
                    detail: string("last-assistant-message"), id: id)
            case let type:
                let found = type.map { "'\($0)'" } ?? "with no type"
                throw UsageError("unknown codex notify payload \(found): expected type agent-turn-complete")
            }
        }
    }

    /// The last component of a working directory, or nil for the root.
    static func projectName(_ path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init)
        return name?.isEmpty == false ? name : nil
    }
}
