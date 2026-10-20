import ArgumentParser
#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif

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
        #if os(WASI)
        let object = try? JSONDecoder().decode([String: LooseString].self, from: Data(payload.utf8))
        let fields: [String: Any]? = object?.compactMapValues(\.value)
        #else
        let object = payload.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let fields = object as? [String: Any]
        #endif
        guard let fields else {
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
                    detail: string("last_assistant_message").map(plainText), id: id)
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
                    detail: string("last-assistant-message").map(plainText), id: id)
            case let type:
                let found = type.map { "'\($0)'" } ?? "with no type"
                throw UsageError("unknown codex notify payload \(found): expected type agent-turn-complete")
            }
        }
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

#if os(WASI)
/// A JSON value kept only when it is a string, as the hook reads its payload.
private struct LooseString: Decodable {
    var value: String?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(String.self)
    }
}
#endif
