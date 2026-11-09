import DripCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// The recipes in the repo's `recipes/` folder, which the tests hold up against what drip installs.
enum Recipes {
    static let names = ["permission-cards", "attention", "everything", "long-turns", "approve-from-card"]

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("recipes")

    static func text(_ name: String, _ agent: AgentHook.Agent) throws -> String {
        try String(contentsOf: folder.appendingPathComponent("\(name)/\(agent.rawValue).json"), encoding: .utf8)
    }

    static func snippet(_ name: String, _ agent: AgentHook.Agent) throws -> AgentSetup.Snippet {
        try AgentSetup.Snippet(parsing: try text(name, agent), agent: agent)
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
