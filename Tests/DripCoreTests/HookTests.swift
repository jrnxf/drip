import DripCore
import Testing

struct HookTests {
    @Test func claudePermissionPromptNeedsYou() throws {
        let event = try AgentHook.event(agent: .claude, payload: """
            {"session_id":"abc123","cwd":"/Users/me/code/drip","hook_event_name":"Notification",
             "message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}
            """)
        #expect(event == AgentHook.Event(
            kind: "warn", title: "drip needs you", detail: "Claude needs your permission to use Bash",
            id: "claude:abc123"))
    }

    @Test func claudeKindFollowsTheNotificationType() throws {
        func kind(_ type: String) throws -> String {
            try AgentHook.event(agent: .claude, payload: """
                {"hook_event_name":"Notification","message":"m","notification_type":"\(type)"}
                """).kind
        }
        #expect(try kind("permission_prompt") == "warn")
        #expect(try kind("elicitation_dialog") == "warn")
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
        #expect(card.kind == "warn")
        #expect(card.title == "drip needs you")
        #expect(card.detail == "hi")
        #expect(card.id == "claude:abc")
    }
}
