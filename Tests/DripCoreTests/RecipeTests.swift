import DripCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import Testing

#if !os(WASI) // Reads the recipes folder, which the browser's sandbox has not.
/// The snippets in the recipe READMEs are the policy drip ships no code for, so they are held up here.
struct RecipeTests {
    @Test(arguments: Recipes.names, AgentHook.Agent.allCases)
    func everyRecipeHasASnippetThatRunsOnlyDripHook(name: String, agent: AgentHook.Agent) throws {
        let events = try Recipes.events(name, agent)
        #expect(!events.isEmpty)
        for event in events {
            let commands = Recipes.commands(in: event.value)
            #expect(!commands.isEmpty, "\(name) \(agent) \(event.key)")
            for command in commands { #expect(command.hasPrefix("drip hook \(agent.rawValue)"), "\(command)") }
        }
    }

    @Test func theRecipesNameTheEventsEachAgentHas() throws {
        let everything = try Recipes.events("everything", .claude)
        #expect(everything.map(\.key) == [
            "PermissionRequest", "Notification", "Stop", "StopFailure",
            "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "ElicitationResult",
        ])
        // PermissionRequest shows permission prompts, with what Claude wants to do. Not idle_prompt,
        // whose card would replace the done card a minute after every turn.
        #expect(everything[1].value.elements?.first?["matcher"] == .string("elicitation_dialog"))
        #expect(try Recipes.events("everything", .codex).map(\.key)
            == ["PermissionRequest", "Stop", "PostToolUse", "UserPromptSubmit"])
        let gemini = try Recipes.events("everything", .gemini)
        #expect(gemini.map(\.key) == ["Notification", "AfterAgent", "AfterTool", "BeforeAgent"])
        // Gemini CLI enables and disables a hook by its name.
        #expect(gemini[1].value.elements?.first?["hooks"]?.elements?.first?["name"] == .string("drip"))

        // permission-cards has no Stop: the done card is not its policy.
        for agent in AgentHook.Agent.allCases {
            let keys = try Recipes.events("permission-cards", agent).map(\.key)
            #expect(!keys.contains("Stop") && !keys.contains("AfterAgent") && !keys.contains("StopFailure"), "\(agent)")
        }
        #expect(try Recipes.events("attention", .claude).map(\.key).contains("StopFailure"))
    }

    @Test func everyRecipeHooksTheEventsThatTakeAWaitingCardAway() throws {
        for name in Recipes.names {
            for agent in AgentHook.Agent.allCases {
                let keys = try Recipes.events(name, agent).map(\.key)
                for event in Recipes.clearEvents(for: agent) { #expect(keys.contains(event), "\(name) \(agent) \(event)") }
            }
        }
    }

    @Test func theRecipeFlagsAreOnTheCommandsTheyChange() throws {
        let approve = try Recipes.commands("approve-from-card", .claude)
        #expect(approve["PermissionRequest"] == "drip hook claude --approve")
        #expect(approve["Notification"] == "drip hook claude")
        #expect(try Recipes.commands("approve-from-card", .codex)["PermissionRequest"] == "drip hook codex --approve")
        let long = try Recipes.commands("long-turns", .claude)
        #expect(long["Stop"] == "drip hook claude --min-turn 30")
        #expect(long["PermissionRequest"] == "drip hook claude")
        #expect(try Recipes.commands("long-turns", .gemini)["AfterAgent"] == "drip hook gemini --min-turn 30")
    }

    /// Every recipe's flags are ones drip's `hook` command takes.
    @Test func everyRecipeCommandParses() throws {
        for name in Recipes.names {
            for agent in AgentHook.Agent.allCases {
                for command in try Recipes.commands(name, agent).values {
                    let arguments = command.split(separator: " ").dropFirst().map(String.init)
                    guard case .invocation = CommandLineParser.parse(Array(arguments)) else {
                        Issue.record("\(name) \(agent): \(command)"); continue
                    }
                }
            }
        }
    }

    @Test func noRecipeTellsYouToCloneTheRepoOrNamesALocalPath() throws {
        let folders = try FileManager.default.contentsOfDirectory(atPath: Recipes.folder.path)
        for folder in folders where !folder.hasPrefix(".") && !folder.hasSuffix(".md") {
            let text = try String(contentsOf: Recipes.folder.appendingPathComponent("\(folder)/README.md"), encoding: .utf8)
            for word in ["git clone", "recipes/", "/Users/", "drip setup claude", "drip setup codex", "drip setup gemini"] {
                #expect(!text.contains(word), "\(folder) mentions \(word)")
            }
        }
    }
}
#endif
