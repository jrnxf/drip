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
            kind: "ask", title: "drip needs you", detail: "Claude needs your permission to use Bash",
            id: "claude:abc123"))
    }

    @Test func claudeKindFollowsTheNotificationType() throws {
        func kind(_ type: String) throws -> String {
            try AgentHook.event(agent: .claude, payload: """
                {"hook_event_name":"Notification","message":"m","notification_type":"\(type)"}
                """).kind
        }
        #expect(try kind("permission_prompt") == "ask")
        #expect(try kind("elicitation_dialog") == "ask")
        #expect(try kind("idle_prompt") == "info")
        #expect(try kind("auth_success") == "info")
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
        let codex = [#"{}"#, #"{"type":"approval-requested"}"#, #"{"hook_event_name":"Stop"}"#]
        for payload in codex {
            #expect(throws: UsageError.self, "\(payload)") { try AgentHook.event(agent: .codex, payload: payload) }
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
        let card = try CardResolver().resolve(
            kind: event.kind, title: event.title, flags: CardFlags(detail: event.detail, id: event.id))
        #expect(card.kind == "ask")
        #expect(card.waits)
        #expect(card.title == "drip needs you")
        #expect(card.detail == "hi")
        #expect(card.id == "claude:abc")
    }

    @Test func anAgentShowsItsInstalledAppsIcon() {
        #expect(AgentHook.Agent.claude.icon { _ in true } == .app("com.anthropic.claudefordesktop"))
        #expect(AgentHook.Agent.codex.icon { _ in true } == .app("com.openai.codex"))
        #expect(AgentHook.Agent.codex.icon { $0 == "com.openai.chat" } == .app("com.openai.chat"))
        // With none installed, the maker's bundled mark, and the ring still carries the state.
        #expect(AgentHook.Agent.claude.icon { _ in false } == .mark("claude"))
        #expect(AgentHook.Agent.codex.icon { _ in false } == .mark("openai"))
        for agent in AgentHook.Agent.allCases {
            var card = Card(preset: .ok, title: "drip is done")
            card.icon = agent.icon { _ in false }
            #expect(card.ringGlyph == "checkmark")
        }
        var card = Card(preset: .ask, title: "drip needs you")
        card.icon = AgentHook.fallbackIcon
        #expect(card.ringGlyph == "questionmark")
    }

    @Test func needsYouTurnsIntoDoneInTheRing() throws {
        func card(_ payload: String) throws -> Card {
            let event = try AgentHook.event(agent: .claude, payload: payload)
            return try CardResolver().resolve(
                kind: event.kind, title: event.title,
                flags: CardFlags(detail: event.detail, icon: .app("com.anthropic.claudefordesktop"), id: event.id))
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
        #expect(asking.ringGlyph == "questionmark")
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
