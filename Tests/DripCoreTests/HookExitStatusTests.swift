#if !os(WASI) // Runs the built drip, which WebAssembly cannot.
import Foundation
import Testing

/// What `drip hook` exits with when the hook goes wrong, run as the agent runs it. Claude Code reads
/// a hook's exit 2 as "block": on a `PermissionRequest` that turns drip's card into a denied
/// permission. `report` returns 2 for a usage error, so only the mapping at the end of `hook(_:)`
/// in the drip target keeps a bad payload from blocking the agent's tool call, and the parser's
/// tests in CommandTests never reach it.
struct HookExitStatusTests {
    static let permission = """
        {"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash",\
        "tool_input":{"command":"ls"},"cwd":"/home/user/api"}
        """

    /// Gemini asks for a permission with a `Notification`: it has no `PermissionRequest`.
    static let geminiPermission = """
        {"hook_event_name":"Notification","session_id":"g1","notification_type":"ToolPermission",\
        "message":"Allow run_shell_command: ls?","details":{"tool_name":"run_shell_command"},"cwd":"/home/user/api"}
        """

    /// Runs `drip hook <agent>` with `payload` on its standard input, in a home of its own.
    private func hook(
        _ agent: String, payload: Data, environment: [String: String] = [:], config: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> DripProcess.Outcome {
        try DripProcess.run(
            ["hook", agent], input: payload, config: config, environment: environment, sourceLocation: sourceLocation)
    }

    private func expectNeverBlocks(
        _ outcome: DripProcess.Outcome, _ what: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(outcome.status == 0 || outcome.status == 1, "\(what): exit \(outcome.status), \(outcome.error)",
                sourceLocation: sourceLocation)
    }

    @Test(arguments: ["claude", "codex", "gemini"])
    func aBadPayloadFailsTheHookWithOneNotTwo(agent: String) throws {
        let bad: [(String, Data)] = [
            ("an empty payload", Data()),
            ("a payload that is not JSON", Data("not json".utf8)),
            ("a payload that is not an object", Data("[1,2]".utf8)),
            ("an event drip does not know", Data(#"{"hook_event_name":"Nope","session_id":"s"}"#.utf8)),
            // One byte past the 4 MB drip reads.
            ("a payload past 4 MB", Data(repeating: UInt8(ascii: " "), count: 4 * 1024 * 1024 + 1)),
        ]
        for (what, payload) in bad {
            let outcome = try hook(agent, payload: payload)
            // The mistake is the hook's to report: it exits 1 and says why, and never 0 (shown).
            #expect(outcome.status == 1, "\(agent), \(what): exit \(outcome.status), \(outcome.error)")
            #expect(!outcome.error.isEmpty, "\(agent), \(what): it says nothing")
        }
    }

    /// A broken config is only a warning, so with a GUI session the permission card shows and waits
    /// for a click: the check runs where there is none to show it.
    @Test(.enabled(if: !ExitCodeTests.hasGUISession, "a broken config shows the permission card, which waits for a click"),
          arguments: ["claude", "codex", "gemini"])
    func aBrokenConfigNeverBlocksAPermission(agent: String) throws {
        let permission = agent == "gemini" ? Self.geminiPermission : Self.permission
        let outcome = try hook(agent, payload: Data(permission.utf8), config: "broken = [")
        expectNeverBlocks(outcome, "\(agent), a broken config.toml")
    }

    @Test(arguments: ["claude", "codex", "gemini"])
    func aSilencedHookNeverBlocks(agent: String) throws {
        for payload in [Self.permission, "", "not json"] {
            let outcome = try hook(agent, payload: Data(payload.utf8), environment: ["DRIP_HOOK": "off"])
            expectNeverBlocks(outcome, "\(agent), DRIP_HOOK=off, payload \(payload.prefix(12))")
        }
        // A DRIP_HOOK drip does not know is a mistake too, and no more a reason to block.
        let unknown = try hook(agent, payload: Data(Self.permission.utf8), environment: ["DRIP_HOOK": "sometimes"])
        expectNeverBlocks(unknown, "\(agent), DRIP_HOOK=sometimes")
    }
}
#endif
