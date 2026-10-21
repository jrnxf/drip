import ArgumentParser
#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif

/// Turns a coding agent's hook payload into what its card says.
///
/// Claude Code, Codex and Gemini CLI hooks write JSON to stdin with snake_case keys
/// (`hook_event_name`, `session_id`, `cwd`, and each event's own). Codex's older `notify` passes JSON
/// as an argument with kebab-case keys (`type`, `thread-id`, `cwd`, `last-assistant-message`), and
/// drip still reads it. Each agent is read only in its own shapes.
public enum AgentHook {
    public enum Agent: String, CaseIterable, Sendable, ExpressibleByArgument {
        case claude, codex, gemini

        /// The name a title falls back to when the payload has no working directory.
        public var displayName: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .gemini: return "Gemini"
            }
        }

        /// The bundle identifiers of the agent's own apps, in the order their icon is preferred: the
        /// command-line agent shows the icon of its maker's app when one is installed.
        public var apps: [String] {
            switch self {
            case .claude: return ["com.anthropic.claudefordesktop"]
            case .codex: return ["com.openai.codex", "com.openai.chat"]
            case .gemini: return []
            }
        }

        /// The maker's mark drip bundles, for when none of its apps is installed.
        public var mark: AgentMark? {
            switch self {
            case .claude: return .claude
            case .codex: return .codex
            case .gemini: return .gemini
            }
        }

        /// The agent's card icon: the icon of the first of its apps that is installed, else its
        /// bundled mark, else drip's neutral `fallbackIcon`.
        public func icon(installed: (String) -> Bool) -> Icon {
            apps.first(where: installed).map(Icon.app) ?? mark.map { .mark($0.name) } ?? AgentHook.fallbackIcon
        }
    }

    /// The icon of an agent with no app installed and no bundled mark: a plain terminal, so the ring
    /// at the notch still carries the state.
    public static let fallbackIcon = Icon.symbol("terminal.fill")

    /// The most a payload read from stdin may be. A Stop payload carries the agent's whole last
    /// message, which can be long.
    public static let payloadLimit = 4 * 1024 * 1024

    /// What the card says.
    public struct Event: Equatable, Sendable {
        /// A preset name: `ok` when the agent is done, `ask` when it waits on a decision, `fail` when
        /// its turn died on an error, `info` when it is only idle.
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
    /// sends: a Claude `Notification`, `Stop` or `StopFailure`; a Codex `PermissionRequest` or `Stop`,
    /// or notify's `agent-turn-complete`; a Gemini `Notification` or `AfterAgent`.
    public static func event(agent: Agent, payload: String) throws -> Event {
        guard let object = try? JSONValue(parsing: payload), object.members != nil else {
            throw UsageError("the \(agent.rawValue) hook payload is not a JSON object")
        }
        func string(_ key: String) -> String? {
            object[key].flatMap(nonBlank)
        }
        func project() -> String {
            string("cwd").flatMap(projectName) ?? agent.displayName
        }
        func unknown(_ name: String?, expected: String) -> UsageError {
            let found = name.map { "'\($0)'" } ?? "with no hook_event_name"
            return UsageError("unknown \(agent.rawValue) hook event \(found): expected \(expected)")
        }
        let id = string("session_id").map { "\(agent.rawValue):\($0)" }

        switch agent {
        case .claude:
            switch string("hook_event_name") {
            case "Notification":
                let kind: String
                switch string("notification_type") {
                case "permission_prompt", "elicitation_dialog": kind = Preset.ask.name
                default: kind = Preset.info.name
                }
                return Event(kind: kind, title: "\(project()) needs you", detail: string("message"), id: id)
            case "Stop":
                return Event(
                    kind: Preset.ok.name, title: "\(project()) is done",
                    detail: string("last_assistant_message").map(plainText), id: id)
            case "StopFailure":
                // The error as the conversation shows it, such as "API Error: Rate limit reached".
                let reason = string("last_assistant_message") ?? string("error_details")
                    ?? string("error").map { $0.replacing("_", with: " ") }
                return Event(kind: Preset.fail.name, title: "\(project()) stopped", detail: reason, id: id)
            case let name:
                throw unknown(name, expected: "Notification, Stop or StopFailure")
            }
        case .codex:
            guard let name = string("hook_event_name") else {
                // The payload Codex's notify passes.
                switch string("type") {
                case "agent-turn-complete":
                    return Event(
                        kind: Preset.ok.name, title: "\(project()) is done",
                        detail: string("last-assistant-message").map(plainText),
                        id: string("thread-id").map { "codex:\($0)" })
                case let type:
                    let found = type.map { "'\($0)'" } ?? "with no hook_event_name or type"
                    throw UsageError(
                        "unknown codex payload \(found): expected a PermissionRequest or Stop hook, "
                            + "or notify's agent-turn-complete")
                }
            }
            switch name {
            case "PermissionRequest":
                return Event(
                    kind: Preset.ask.name, title: "\(project()) needs you", detail: codexRequest(object), id: id)
            case "Stop":
                return Event(
                    kind: Preset.ok.name, title: "\(project()) is done",
                    detail: string("last_assistant_message").map(plainText), id: id)
            default:
                throw unknown(name, expected: "PermissionRequest or Stop")
            }
        case .gemini:
            switch string("hook_event_name") {
            case "Notification":
                let kind = string("notification_type") == "ToolPermission" ? Preset.ask.name : Preset.info.name
                return Event(kind: kind, title: "\(project()) needs you", detail: string("message"), id: id)
            case "AfterAgent":
                return Event(
                    kind: Preset.ok.name, title: "\(project()) is done",
                    detail: string("prompt_response").map(plainText), id: id)
            case let name:
                throw unknown(name, expected: "Notification or AfterAgent")
            }
        }
    }

    /// What a Codex permission request asks: its own description, else the command it would run,
    /// else the tool it would use.
    private static func codexRequest(_ object: JSONValue) -> String? {
        let input = object["tool_input"]
        if let description = input?["description"].flatMap(nonBlank) {
            return description
        }
        // A command is one string, or its words.
        let command = input?["command"].flatMap { $0.string ?? $0.elements?.compactMap(\.string).joined(separator: " ") }
        if let command = command.flatMap({ nonBlank(.string($0)) }) {
            return "Codex wants to run \(command)"
        }
        return object["tool_name"].flatMap(nonBlank).map { "Codex wants to use \($0)" }
    }

    /// A string value with more than whitespace in it.
    private static func nonBlank(_ value: JSONValue) -> String? {
        guard let string = value.string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return string
    }

    /// An agent's last message is Markdown; a card shows the words. Drops code fences, rules, and
    /// heading, quote and list markers, and keeps the text of emphasis, links and inline code. Code
    /// spans keep their text as written, so `__init__` stays whole.
#if os(WASI)
    static func plainText(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return nil }
            let rule = trimmed.filter { $0 != " " }
            if rule.count >= 3, Set(rule).count == 1, let mark = rule.first, "-*_".contains(mark) { return nil }
            return String(line).replacing(lineMarker, with: "")
        }
        let text = lines.joined(separator: "\n")
        var plain = ""
        var location = text.startIndex
        for span in text.matches(of: codeSpan) {
            plain += withoutEmphasis(String(text[location..<span.range.lowerBound]))
            plain += String(span.output[1].substring ?? "")
            location = span.range.upperBound
        }
        return plain + withoutEmphasis(String(text[location...]))
    }

    /// A heading, quote or bullet marker at the start of a line.
    nonisolated(unsafe) private static let lineMarker = regex(#"^\s*(#{1,6}\s+|(>\s?)+|[-*+]\s+(\[[ xX]\]\s+)?)"#)
    nonisolated(unsafe) private static let codeSpan = regex(#"`+([^`]+)`+"#)
    /// Swift's Regex has no lookbehind, so a pattern that must not follow a word character captures
    /// the character before it, which comes back with the text: `prefixed` patterns keep group 1 and 2.
    nonisolated(unsafe) private static let emphasis: [(Regex<AnyRegexOutput>, prefixed: Bool)] = [
        // An image or a link: its text.
        (regex(#"!?\[([^\]]*)\]\([^)\s]*(\s+"[^"]*")?\)"#), false),
        (regex(#"\*\*(\S(?:.*?\S)?)\*\*"#), false),
        (regex(#"(^|[^\w_])__([^\s_](?:.*?[^\s_])?)__(?![\w_])"#), true),
        (regex(#"(^|[^\w*])\*([^\s*](?:.*?[^\s*])?)\*(?![\w*])"#), true),
        (regex(#"~~(\S(?:.*?\S)?)~~"#), false),
    ]

    private static func withoutEmphasis(_ text: String) -> String {
        emphasis.reduce(text) { text, pattern in
            text.replacing(pattern.0) { match in
                let groups = pattern.prefixed ? [1, 2] : [1]
                return groups.map { String(match.output[$0].substring ?? "") }.joined()
            }
        }
    }

    private static func regex(_ pattern: String) -> Regex<AnyRegexOutput> {
        // The patterns are constants, and the tests run every one.
        try! Regex(pattern).anchorsMatchLineEndings()
    }

#else
    static func plainText(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return nil }
            let rule = trimmed.filter { $0 != " " }
            if rule.count >= 3, Set(rule).count == 1, let mark = rule.first, "-*_".contains(mark) { return nil }
            return replacing(lineMarker, in: String(line), with: "")
        }
        let text = lines.joined(separator: "\n") as NSString
        var plain = ""
        var location = 0
        for span in codeSpan.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            plain += withoutEmphasis(text.substring(with: NSRange(location: location, length: span.range.location - location)))
            plain += text.substring(with: span.range(at: 1))
            location = NSMaxRange(span.range)
        }
        return plain + withoutEmphasis(text.substring(from: location))
    }

    /// A heading, quote or bullet marker at the start of a line.
    private static let lineMarker = regex(#"^\s*(#{1,6}\s+|(>\s?)+|[-*+]\s+(\[[ xX]\]\s+)?)"#)
    private static let codeSpan = regex(#"`+([^`]+)`+"#)
    private static let emphasis: [(NSRegularExpression, String)] = [
        // An image or a link: its text.
        (regex(#"!?\[([^\]]*)\]\([^)\s]*(\s+"[^"]*")?\)"#), "$1"),
        (regex(#"\*\*(\S(?:.*?\S)?)\*\*"#), "$1"),
        (regex(#"(?<![\w_])__([^\s_](?:.*?[^\s_])?)__(?![\w_])"#), "$1"),
        (regex(#"(?<![\w*])\*([^\s*](?:.*?[^\s*])?)\*(?![\w*])"#), "$1"),
        (regex(#"~~(\S(?:.*?\S)?)~~"#), "$1"),
    ]

    private static func withoutEmphasis(_ text: String) -> String {
        emphasis.reduce(text) { replacing($1.0, in: $0, with: $1.1) }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants, and the tests run every one.
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

#endif

    /// The last component of a working directory, or nil for the root.
    static func projectName(_ path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init)
        return name?.isEmpty == false ? name : nil
    }
}
