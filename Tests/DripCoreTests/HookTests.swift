import DripCore
#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif
import Testing

struct HookTests {
    @Test func claudePermissionPromptNeedsYou() throws {
        let event = try AgentHook.event(agent: .claude, payload: """
            {"session_id":"abc123","cwd":"/Users/me/code/drip","hook_event_name":"Notification",
             "message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}
            """)
        #expect(event == AgentHook.Event(
            kind: "info", title: "drip needs you", detail: "Claude needs your permission to use Bash",
            id: "claude:abc123", stays: true))
    }

    @Test func claudeStaysWhenTheNotificationNeedsADecision() throws {
        func event(_ type: String) throws -> AgentHook.Event {
            try AgentHook.event(agent: .claude, payload: """
                {"hook_event_name":"Notification","message":"m","notification_type":"\(type)"}
                """)
        }
        for type in ["permission_prompt", "elicitation_dialog", "idle_prompt", "auth_success"] {
            #expect(try event(type).kind == "info")
        }
        #expect(try event("permission_prompt").stays)
        #expect(try event("elicitation_dialog").stays)
        #expect(try !event("idle_prompt").stays)
        #expect(try !event("auth_success").stays)
    }

    @Test func claudeStopIsDoneWithTheLastMessage() throws {
        let event = try AgentHook.event(agent: .claude, payload: """
            {"session_id":"s1","cwd":"/work/api","hook_event_name":"Stop","stop_hook_active":false,
             "last_assistant_message":"Fixed the flaky test.\\n\\nAll 42 tests pass."}
            """)
        #expect(event == AgentHook.Event(
            kind: "ok", title: "api is done", detail: "Fixed the flaky test.\n\nAll 42 tests pass.", id: "claude:s1"))
    }

    @Test func theLastMessageLosesItsMarkdown() throws {
        func detail(_ message: String) throws -> String? {
            let payload = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "Stop", "last_assistant_message": message,
            ])
            return try AgentHook.event(agent: .claude, payload: String(decoding: payload, as: UTF8.self)).detail
        }
        #expect(try detail("""
            ## Summary

            I refactored the **billing** module and *renamed* `retryCount`.

            ```swift
            let retries = 3
            ```

            - Updated [the docs](https://example.com/docs "Docs")
            * [x] ~~Removed~~ the flag
            > All 236 tests pass.

            ---
            1. Next: ship it
            """) == """
            Summary

            I refactored the billing module and renamed retryCount.

            let retries = 3

            Updated the docs
            Removed the flag
            All 236 tests pass.

            1. Next: ship it
            """)
        // Code keeps its text; snake_case, lone asterisks and globs keep theirs.
        #expect(try detail("Ran `__init__` and `**kwargs` in snake_case_name") == "Ran __init__ and **kwargs in snake_case_name")
        #expect(try detail("2 * 3 = 6, and *.swift or *.md files") == "2 * 3 = 6, and *.swift or *.md files")
        #expect(try detail("__dunder__ and __bold text__") == "dunder and bold text")
    }

    @Test func aHugeMessageIsReadQuickly() throws {
        let line = "**bold** *it* `code` [link](https://example.com) __u__ ~~s~~ * 2 ** 3 "
        let message = String(repeating: line, count: AgentHook.payloadLimit / line.utf8.count / 2)
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop", "last_assistant_message": message,
        ])
        let start = Date()
        let event = try AgentHook.event(agent: .claude, payload: String(decoding: payload, as: UTF8.self))
        #expect(event.detail?.hasPrefix("bold it code link u s * 2 ** 3") == true)
        // Linear time takes well under a second; the bound only catches backtracking that runs for minutes.
        #expect(Date().timeIntervalSince(start) < 30)
    }

    @Test func claudeStopFailureFailsWithTheError() throws {
        let event = try AgentHook.event(agent: .claude, payload: """
            {"session_id":"s1","cwd":"/work/my-app","hook_event_name":"StopFailure","error":"rate_limit",
             "error_details":"429 Too Many Requests","last_assistant_message":"API Error: Rate limit reached"}
            """)
        #expect(event == AgentHook.Event(
            kind: "fail", title: "my-app stopped", detail: "API Error: Rate limit reached", id: "claude:s1"))
        // Without the message, the details, else the error's name in words.
        #expect(try AgentHook.event(agent: .claude, payload: """
            {"hook_event_name":"StopFailure","error":"server_error","error_details":"500 Internal Server Error"}
            """).detail == "500 Internal Server Error")
        #expect(try AgentHook.event(agent: .claude, payload: """
            {"hook_event_name":"StopFailure","error":"billing_error"}
            """).detail == "billing error")
        #expect(try AgentHook.event(agent: .claude, payload: #"{"hook_event_name":"StopFailure"}"#)
            == AgentHook.Event(kind: "fail", title: "Claude stopped"))
    }

    @Test func codexPermissionRequestNeedsYou() throws {
        let event = try AgentHook.event(agent: .codex, payload: """
            {"session_id":"019a","turn_id":"t1","transcript_path":null,"cwd":"/src/web",
             "hook_event_name":"PermissionRequest","model":"gpt-5.5","permission_mode":"default",
             "tool_name":"Bash","tool_input":{"command":"npm install","description":null}}
            """)
        #expect(event == AgentHook.Event(
            kind: "info", title: "web needs you", detail: "Codex wants to run npm install", id: "codex:019a",
            stays: true))
        func detail(_ input: String) throws -> String? {
            try AgentHook.event(agent: .codex, payload: """
                {"hook_event_name":"PermissionRequest","tool_name":"apply_patch","tool_input":\(input)}
                """).detail
        }
        #expect(try detail(#"{"command":"rm -rf build","description":"Clean the build to retry"}"#)
            == "Clean the build to retry")
        #expect(try detail(#"{"command":["git","push","--force"]}"#) == "Codex wants to run git push --force")
        #expect(try detail(#"{"patch":"*** Begin Patch"}"#) == "Codex wants to use apply_patch")
        #expect(try detail(#"{"command":"  "}"#) == "Codex wants to use apply_patch")
    }

    @Test func codexStopHookIsDone() throws {
        let event = try AgentHook.event(agent: .codex, payload: """
            {"session_id":"019a","turn_id":"t1","cwd":"/src/web","hook_event_name":"Stop",
             "stop_hook_active":false,"last_assistant_message":"Renamed the **route**."}
            """)
        #expect(event == AgentHook.Event(kind: "ok", title: "web is done", detail: "Renamed the route.", id: "codex:019a"))
        // last_assistant_message is null when Codex has nothing to show.
        #expect(try AgentHook.event(agent: .codex, payload: """
            {"hook_event_name":"Stop","last_assistant_message":null}
            """) == AgentHook.Event(kind: "ok", title: "Codex is done"))
    }

    @Test func geminiToolPermissionNeedsYou() throws {
        let event = try AgentHook.event(agent: .gemini, payload: """
            {"session_id":"g1","transcript_path":"/tmp/t.json","cwd":"/home/user/site",
             "hook_event_name":"Notification","timestamp":"2026-10-21T12:00:00Z",
             "notification_type":"ToolPermission","message":"Allow run_shell_command: npm test?",
             "details":{"tool_name":"run_shell_command"}}
            """)
        #expect(event == AgentHook.Event(
            kind: "info", title: "site needs you", detail: "Allow run_shell_command: npm test?", id: "gemini:g1",
            stays: true))
        #expect(try AgentHook.event(agent: .gemini, payload: """
            {"hook_event_name":"Notification","notification_type":"Other","message":"m"}
            """).kind == "info")
    }

    @Test func geminiAfterAgentIsDone() throws {
        let event = try AgentHook.event(agent: .gemini, payload: """
            {"session_id":"g1","cwd":"/home/user/site","hook_event_name":"AfterAgent","prompt":"fix it",
             "prompt_response":"Fixed the `nav` *overflow*.","stop_hook_active":false}
            """)
        #expect(event == AgentHook.Event(kind: "ok", title: "site is done", detail: "Fixed the nav overflow.", id: "gemini:g1"))
    }

    @Test func codexNotifyIsDone() throws {
        let event = try AgentHook.event(agent: .codex, payload: """
            {"type":"agent-turn-complete","thread-id":"t-9","turn-id":"1","cwd":"/src/web",
             "input-messages":["fix it"],"last-assistant-message":"Done: renamed the route."}
            """)
        #expect(event == AgentHook.Event(kind: "ok", title: "web is done", detail: "Done: renamed the route.", id: "codex:t-9"))
    }

    @Test func theTitleFallsBackToTheAgent() throws {
        for payload in [#"{"type":"agent-turn-complete"}"#, #"{"type":"agent-turn-complete","cwd":"/"}"#,
                        #"{"type":"agent-turn-complete","cwd":"  "}"#] {
            #expect(try AgentHook.event(agent: .codex, payload: payload).title == "Codex is done", "\(payload)")
        }
        let trailing = try AgentHook.event(agent: .claude, payload: #"{"hook_event_name":"Stop","cwd":"/a/repo/"}"#)
        #expect(trailing.title == "repo is done")
    }

    @Test func noSessionMeansNoID() throws {
        #expect(try AgentHook.event(agent: .claude, payload: #"{"hook_event_name":"Stop"}"#).id == nil)
        #expect(try AgentHook.event(agent: .claude, payload: #"{"hook_event_name":"Stop","session_id":""}"#).id == nil)
    }

    @Test func emptyMessagesAreIgnored() throws {
        let event = try AgentHook.event(agent: .claude, payload: """
            {"hook_event_name":"Notification","message":"  "}
            """)
        #expect(event.detail == nil)
    }

    @Test func eachAgentIsReadOnlyInItsOwnShape() throws {
        let claude = try AgentHook.event(agent: .claude, payload: """
            {"hook_event_name":"Stop","thread-id":"t","last-assistant-message":"bye"}
            """)
        #expect(claude == AgentHook.Event(kind: "ok", title: "Claude is done"))
        let codex = try AgentHook.event(agent: .codex, payload: """
            {"type":"agent-turn-complete","session_id":"s","last_assistant_message":"bye"}
            """)
        #expect(codex == AgentHook.Event(kind: "ok", title: "Codex is done"))
        let gemini = try AgentHook.event(agent: .gemini, payload: """
            {"hook_event_name":"AfterAgent","last_assistant_message":"bye"}
            """)
        #expect(gemini == AgentHook.Event(kind: "ok", title: "Gemini is done"))
    }

    @Test func anUnknownEventIsAnError() {
        let claude = [
            #"{}"#, #"{"last_assistant_message":"bye"}"#, #"{"message":"hello"}"#,
            #"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#,
            #"{"hook_event_name":"SubagentStop"}"#, #"{"type":"agent-turn-complete"}"#,
        ]
        for payload in claude {
            #expect(throws: UsageError.self, "\(payload)") { try AgentHook.event(agent: .claude, payload: payload) }
        }
        let codex = [
            #"{}"#, #"{"type":"approval-requested"}"#, #"{"hook_event_name":"SessionStart"}"#,
            #"{"hook_event_name":"Notification","notification_type":"permission_prompt"}"#,
        ]
        for payload in codex {
            #expect(throws: UsageError.self, "\(payload)") { try AgentHook.event(agent: .codex, payload: payload) }
        }
        let gemini = [
            #"{}"#, #"{"hook_event_name":"Stop"}"#, #"{"hook_event_name":"BeforeTool","tool_name":"x"}"#,
            #"{"type":"agent-turn-complete"}"#,
        ]
        for payload in gemini {
            #expect(throws: UsageError.self, "\(payload)") { try AgentHook.event(agent: .gemini, payload: payload) }
        }
    }

    @Test func aPayloadThatIsNotAnObjectIsAnError() {
        for payload in ["", "not json", "[1,2]", "\"Stop\"", "{\"cwd\":"] {
            #expect(throws: UsageError.self, "\(payload)") { try AgentHook.event(agent: .claude, payload: payload) }
        }
    }

    @Test func theResolvedCardCarriesTheSessionID() throws {
        let event = try AgentHook.event(agent: .claude, payload: """
            {"session_id":"abc","cwd":"/x/drip","hook_event_name":"Notification","message":"hi",
             "notification_type":"permission_prompt"}
            """)
        let card = try CardResolver().resolve(kind: event.kind, title: event.title, flags: event.filling(CardFlags()))
        #expect(card.kind == "info")
        #expect(card.waits && !card.asksQuestion)
        #expect(Delivery.choose(for: [card], wait: false) == .background)
        #expect(card.title == "drip needs you")
        #expect(card.detail == "hi")
        #expect(card.id == "claude:abc")
    }

    /// The command line's own --id and --detail win over the event's, and --stay keeps any card.
    @Test func theCommandLineBeatsTheEvent() {
        let event = AgentHook.Event(kind: "ok", title: "t", detail: "theirs", id: "claude:s1")
        let mine = event.filling(CardFlags(detail: "mine", stay: true, id: "deploy"))
        #expect(mine.detail == "mine" && mine.id == "deploy" && mine.stay)
        let theirs = event.filling(CardFlags())
        #expect(theirs.detail == "theirs" && theirs.id == "claude:s1" && !theirs.stay)
        #expect(AgentHook.Event(kind: "info", title: "t", stays: true).filling(CardFlags()).stay)
    }

    @Test func anAgentShowsItsInstalledAppsIcon() {
        #expect(AgentHook.Agent.claude.icon { _ in true } == .app("com.anthropic.claudefordesktop"))
        #expect(AgentHook.Agent.codex.icon { _ in true } == .app("com.openai.codex"))
        #expect(AgentHook.Agent.codex.icon { $0 == "com.openai.chat" } == .app("com.openai.chat"))
        // With none installed, the maker's bundled mark, and the ring still carries the state.
        #expect(AgentHook.Agent.claude.icon { _ in false } == .mark("claude"))
        #expect(AgentHook.Agent.codex.icon { _ in false } == .mark("codex"))
        #expect(AgentHook.Agent.gemini.icon { _ in true } == .mark("gemini"))
        for agent in AgentHook.Agent.allCases {
            var card = Card(preset: .ok, title: "drip is done")
            card.icon = agent.icon { _ in false }
            #expect(card.ringGlyph == "checkmark")
        }
        var card = Card.staying(title: "drip needs you")
        card.icon = AgentHook.fallbackIcon
        #expect(card.ringGlyph == "info")
    }

    @Test func needsYouTurnsIntoDoneInTheRing() throws {
        func card(_ payload: String) throws -> Card {
            let event = try AgentHook.event(agent: .claude, payload: payload)
            return try CardResolver().resolve(
                kind: event.kind, title: event.title,
                flags: event.filling(CardFlags(icon: .app("com.anthropic.claudefordesktop"))))
        }
        let asking = try card("""
            {"session_id":"s1","cwd":"/work/api","hook_event_name":"Notification","message":"m",
             "notification_type":"permission_prompt"}
            """)
        let done = try card("""
            {"session_id":"s1","cwd":"/work/api","hook_event_name":"Stop","last_assistant_message":"Done."}
            """)
        #expect(asking.id == done.id)
        #expect(CardReplacement.canSwap(asking, for: done))
        #expect(IslandUpdate.changesState(from: asking, to: done))
        // The agent's icon stays; the state lands in the ring.
        #expect(IslandUpdate.landsInRing(from: asking, to: done))
        #expect(asking.waits)
        #expect(asking.ringGlyph == "info")
        #expect(done.ringGlyph == "checkmark")
        #expect(!done.waits)
    }
}

#if os(WASI)
/// The payloads these tests build, without Foundation's JSONSerialization.
private enum JSONSerialization {
    static func data(withJSONObject object: [String: String]) throws -> Data {
        try JSONEncoder().encode(object)
    }
}
#endif
