import DripCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// The hook snippets in the repo's `recipes/<name>/README.md` files, which the tests hold up against
/// what drip's hooks do. A recipe README has one fenced JSON block per agent.
enum Recipes {
    static let names = ["permission-cards", "attention", "everything", "long-turns", "approve-from-card"]

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("recipes")

    /// The fenced blocks of a recipe's README, `json` ones unless another language is asked for.
    static func blocks(_ name: String, language: String = "json") throws -> [String] {
        let readme = try String(contentsOf: folder.appendingPathComponent("\(name)/README.md"), encoding: .utf8)
        var blocks: [String] = []
        var current: [Substring]?
        for line in readme.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "```\(language)" {
                current = []
            } else if line == "```", let lines = current {
                blocks.append(lines.joined(separator: "\n"))
                current = nil
            } else if current != nil {
                current?.append(line)
            }
        }
        return blocks
    }

    /// The `hooks` of the snippet for an agent: its events in order, and each event's groups.
    static func events(_ name: String, _ agent: AgentHook.Agent) throws -> [JSONMember] {
        for block in try blocks(name) {
            let hooks = try JSONValue(parsing: block)["hooks"]?.members ?? []
            let found = hooks.flatMap { commands(in: $0.value) }
            if !found.isEmpty, found.allSatisfy({ $0.hasPrefix("drip hook \(agent.rawValue)") }) { return hooks }
        }
        throw RecipeError.missing("\(name) has no snippet for \(agent.rawValue)")
    }

    /// The command of each handler in an event's groups.
    static func commands(in groups: JSONValue) -> [String] {
        (groups.elements ?? []).flatMap { group in
            (group["hooks"]?.elements ?? []).compactMap { $0["command"]?.string }
        }
    }

    /// One command for each event of a recipe's snippet for an agent.
    static func commands(_ name: String, _ agent: AgentHook.Agent) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try events(name, agent).compactMap { event in
            commands(in: event.value).first.map { (event.key, $0) }
        })
    }

    /// The events whose hook takes a waiting card away once the agent moves on.
    static func clearEvents(for agent: AgentHook.Agent) -> [String] {
        switch agent {
        case .claude: return ["PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "ElicitationResult"]
        case .codex: return ["PostToolUse", "UserPromptSubmit"]
        case .gemini: return ["AfterTool", "BeforeAgent"]
        }
    }
}

enum RecipeError: Error {
    case missing(String)
}
