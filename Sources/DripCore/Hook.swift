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
        /// A preset name: `ok` when the agent is done, `fail` when its turn died on an error, `info`
        /// when it waits on a decision or is only idle.
        public var kind: String
        public var title: String
        public var detail: String?
        /// `<agent>:<session>`, so a session's newer card replaces its older one.
        public var id: String?
        /// Whether the card stays, as with `--stay`: the agent waits on a decision from you.
        public var stays: Bool
        /// The tool call a card that stays waits on, so the hook that reports the call ran takes
        /// that card away and no other; nil when the payload names none.
        public var waitsOn: String?
        /// Whether this is Claude's `permission_prompt` notification, which a `PermissionRequest`
        /// hook already showed a card for when both run: it then shows nothing.
        public var isPermissionNotice: Bool
        /// The session's working directory, which the title names; nil when the payload has none.
        public var directory: String?

        public init(
            kind: String, title: String, detail: String? = nil, id: String? = nil, stays: Bool = false,
            waitsOn: String? = nil, isPermissionNotice: Bool = false, directory: String? = nil
        ) {
            self.kind = kind
            self.title = title
            self.detail = detail
            self.id = id
            self.stays = stays
            self.waitsOn = waitsOn
            self.isPermissionNotice = isPermissionNotice
            self.directory = directory
        }

        /// `flags` with what the event says where the command line says nothing: the session's id
        /// and the detail, and the card stays while the agent waits on you.
        public func filling(_ flags: CardFlags) -> CardFlags {
            var flags = flags
            flags.id = flags.id ?? id
            flags.detail = flags.detail ?? detail
            flags.stay = flags.stay || stays
            return flags
        }
    }

    /// Takes away the card a session waits on, once the agent shows it no longer waits: you answered
    /// in the terminal, so the card that said it needs you would only be wrong.
    public struct Clear: Equatable, Sendable {
        /// `<agent>:<session>`.
        public var id: String
        /// The tool call that ran: only a card waiting on that call goes. Nil for any card that waits,
        /// as when you sent the agent a prompt.
        public var tool: String?

        public init(id: String, tool: String? = nil) {
            self.id = id
            self.tool = tool
        }
    }

    /// What a hook payload asks drip to do.
    public enum Outcome: Equatable, Sendable {
        /// Show a card.
        case card(Event)
        /// Take the session's waiting card away, when one waits; show nothing.
        case clear(Clear)
        /// Nothing: an event drip has nothing to say about, such as a clear without a session.
        case nothing
    }

    /// The events drip's hooks run on that take a waiting card away, by agent.
    public static func clearEvents(for agent: Agent) -> [String] {
        switch agent {
        case .claude: return ["PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "ElicitationResult"]
        case .codex: return ["PostToolUse", "UserPromptSubmit"]
        case .gemini: return ["AfterTool", "BeforeAgent"]
        }
    }

    /// Reads a payload that shows a card. Throws a `UsageError` as `outcome` does, and for an event
    /// that shows none.
    public static func event(agent: Agent, payload: String) throws -> Event {
        guard case let .card(event) = try outcome(agent: agent, payload: payload) else {
            throw UsageError("the \(agent.rawValue) hook payload shows no card")
        }
        return event
    }

    /// Reads a payload. Throws a `UsageError` when it is not a JSON object or not an event this agent
    /// sends: a Claude `Notification`, `PermissionRequest`, `Stop` or `StopFailure`; a Codex
    /// `PermissionRequest` or `Stop`, or notify's `agent-turn-complete`; a Gemini `Notification` or
    /// `AfterAgent`; or one of `clearEvents(for:)`.
    public static func outcome(agent: Agent, payload: String) throws -> Outcome {
        guard let object = try? JSONValue(parsing: payload), object.members != nil else {
            throw UsageError("the \(agent.rawValue) hook payload is not a JSON object")
        }
        func string(_ key: String) -> String? {
            object[key].flatMap(nonBlank)
        }
        let directory = string("cwd")
        func project() -> String {
            directory.flatMap(projectName) ?? agent.displayName
        }
        func unknown(_ name: String?, expected: String) -> UsageError {
            let found = name.map { "'\($0)'" } ?? "with no hook_event_name"
            return UsageError("unknown \(agent.rawValue) hook event \(found): expected \(expected)")
        }
        let id = string("session_id").map { "\(agent.rawValue):\($0)" }
        func card(
            _ kind: Preset, _ title: String, _ detail: String?, stays: Bool = false, waitsOn: String? = nil,
            isPermissionNotice: Bool = false
        ) -> Outcome {
            .card(Event(
                kind: kind.name, title: "\(project()) \(title)", detail: detail, id: id, stays: stays,
                waitsOn: stays ? waitsOn : nil, isPermissionNotice: isPermissionNotice, directory: directory))
        }
        func clear(tool: String? = nil, keyed: Bool = false) -> Outcome {
            // A clear for one tool call that names none could take the wrong card: nothing then.
            guard let id, !keyed || tool != nil else { return .nothing }
            return .clear(Clear(id: id, tool: tool))
        }

        switch agent {
        case .claude:
            switch string("hook_event_name") {
            case "Notification":
                let type = string("notification_type")
                let decides = ["permission_prompt", "elicitation_dialog"].contains(type)
                return card(
                    .info, "needs you", string("message"), stays: decides,
                    isPermissionNotice: type == "permission_prompt")
            case "PermissionRequest":
                return card(
                    .info, "needs you", request(object, agent: agent, directory: directory), stays: true,
                    waitsOn: string("tool_use_id"))
            case "Stop":
                return card(.ok, "is done", string("last_assistant_message").map(plainText))
            case "StopFailure":
                // The error as the conversation shows it, such as "API Error: Rate limit reached".
                let reason = string("last_assistant_message") ?? string("error_details")
                    ?? string("error").map { $0.replacing("_", with: " ") }
                return card(.fail, "stopped", reason)
            case "PostToolUse", "PostToolUseFailure":
                return clear(tool: string("tool_use_id"), keyed: true)
            case "UserPromptSubmit", "ElicitationResult":
                return clear()
            case let name:
                throw unknown(
                    name, expected: "Notification, PermissionRequest, Stop, StopFailure, PostToolUse, "
                        + "PostToolUseFailure, UserPromptSubmit or ElicitationResult")
            }
        case .codex:
            guard let name = string("hook_event_name") else {
                // The payload Codex's notify passes.
                switch string("type") {
                case "agent-turn-complete":
                    return .card(Event(
                        kind: Preset.ok.name, title: "\(project()) is done",
                        detail: string("last-assistant-message").map(plainText),
                        id: string("thread-id").map { "codex:\($0)" }, directory: directory))
                case let type:
                    let found = type.map { "'\($0)'" } ?? "with no hook_event_name or type"
                    throw UsageError(
                        "unknown codex payload \(found): expected a PermissionRequest or Stop hook, "
                            + "or notify's agent-turn-complete")
                }
            }
            switch name {
            case "PermissionRequest":
                return card(
                    .info, "needs you", request(object, agent: agent, directory: directory), stays: true,
                    waitsOn: codexCall(object))
            case "Stop":
                return card(.ok, "is done", string("last_assistant_message").map(plainText))
            case "PostToolUse":
                return clear(tool: codexCall(object), keyed: true)
            case "UserPromptSubmit":
                return clear()
            default:
                throw unknown(name, expected: "PermissionRequest, Stop, PostToolUse or UserPromptSubmit")
            }
        case .gemini:
            switch string("hook_event_name") {
            case "Notification":
                return card(.info, "needs you", string("message"), stays: string("notification_type") == "ToolPermission")
            case "AfterAgent":
                return card(.ok, "is done", string("prompt_response").map(plainText))
            case "AfterTool", "BeforeAgent":
                // Gemini CLI names no tool call, so any card the session waits on goes.
                return clear()
            case let name:
                throw unknown(name, expected: "Notification, AfterAgent, AfterTool or BeforeAgent")
            }
        }
    }

    /// The tool call a Codex hook is about. Codex's `PermissionRequest` carries no `tool_use_id`, so
    /// the call is its turn, its tool and the tool's input, which `PostToolUse` repeats. Nil without a
    /// turn or a tool.
    static func codexCall(_ object: JSONValue) -> String? {
        guard let turn = object["turn_id"].flatMap(nonBlank), let tool = object["tool_name"].flatMap(nonBlank)
        else { return nil }
        let input = object["tool_input"].map(canonical) ?? "null"
        return "\(turn) \(tool) \(fingerprint(input))"
    }

    /// A JSON value as text with its object keys sorted, so the same value reads the same however
    /// its keys were ordered.
    static func canonical(_ value: JSONValue) -> String {
        func quoted(_ text: String) -> String {
            var result = "\""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\"": result += "\\\""
                case "\\": result += "\\\\"
                case "\n": result += "\\n"
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
        }
        switch value {
        case let .object(members):
            let sorted = members.sorted { $0.key < $1.key }
            return "{" + sorted.map { quoted($0.key) + ":" + canonical($0.value) }.joined(separator: ",") + "}"
        case let .array(elements):
            return "[" + elements.map(canonical).joined(separator: ",") + "]"
        case let .string(text):
            return quoted(text)
        default:
            return value.formatted()
        }
    }

    /// A short, stable fingerprint of `text`: FNV-1a, 64 bits, in hex.
    public static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    /// What a permission request asks: its own description, else the command it would run, else
    /// the file or the address the tool would work on, else the tool it would use.
    static func request(_ object: JSONValue, agent: Agent, directory: String?) -> String? {
        let name = agent.displayName
        let input = object["tool_input"]
        if let description = input?["description"].flatMap(nonBlank) {
            return description
        }
        // A command is one string, or its words.
        let command = input?["command"].flatMap { $0.string ?? $0.elements?.compactMap(\.string).joined(separator: " ") }
        if let command = command.flatMap({ nonBlank(.string($0)) }) {
            return "\(name) wants to run \(command)"
        }
        guard let tool = object["tool_name"].flatMap(nonBlank) else { return nil }
        let target = (input?["file_path"] ?? input?["notebook_path"] ?? input?["path"]).flatMap(nonBlank)
            .map { relative($0, to: directory) } ?? input?["url"].flatMap(nonBlank)
        return target.map { "\(name) wants to use \(tool) on \($0)" } ?? "\(name) wants to use \(tool)"
    }

    /// `path` from inside `directory` without it, as the session sees it; other paths as they are.
    static func relative(_ path: String, to directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return path }
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(base) && path.count > base.count ? String(path.dropFirst(base.count)) : path
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
    public static func projectName(_ path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init)
        return name?.isEmpty == false ? name : nil
    }
}
