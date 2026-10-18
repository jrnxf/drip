import BlipCore
import Testing

struct HookTests {
    @Test func claudePermissionPromptNeedsYou() throws {
        let event = try AgentHook.event(agent: .claude, payload: """
            {"session_id":"abc123","cwd":"/Users/me/code/blip","hook_event_name":"Notification",
             "message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}
            """)
        #expect(event == AgentHook.Event(
            kind: "warn", title: "blip needs you", detail: "Claude needs your permission to use Bash",
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

    @Test func claudePermissionRequestNamesTheTool() throws {
        let event = try AgentHook.event(agent: .claude, payload: """
            {"hook_event_name":"PermissionRequest","cwd":"/w/app","tool_name":"Bash","session_id":"s"}
            """)
        #expect(event == AgentHook.Event(kind: "warn", title: "app needs you", detail: "wants to use Bash", id: "claude:s"))
    }

    @Test func codexNotifyIsDone() throws {
        let event = try AgentHook.event(agent: .codex, payload: """
            {"type":"agent-turn-complete","thread-id":"t-9","turn-id":"1","cwd":"/src/web",
             "input-messages":["fix it"],"last-assistant-message":"Done: renamed the route."}
            """)
        #expect(event == AgentHook.Event(kind: "ok", title: "web is done", detail: "Done: renamed the route.", id: "codex:t-9"))
    }

    @Test func codexHooksInClaudesShapeWork() throws {
        let event = try AgentHook.event(agent: .codex, payload: """
            {"hook_event_name":"Stop","session_id":"x","cwd":"/a/b","last_assistant_message":"ok"}
            """)
        #expect(event == AgentHook.Event(kind: "ok", title: "b is done", detail: "ok", id: "codex:x"))
    }

    @Test func withoutAnEventNameTheMessagesDecide() throws {
        let done = try AgentHook.event(agent: .claude, payload: #"{"last_assistant_message":"bye"}"#)
        #expect(done.kind == "ok")
        #expect(done.title == "Claude is done")
        let waiting = try AgentHook.event(agent: .claude, payload: #"{"message":"hello"}"#)
        #expect(waiting.kind == "info")
        #expect(waiting.title == "Claude needs you")
    }

    @Test func theTitleFallsBackToTheAgent() throws {
        for payload in [#"{"hook_event_name":"Stop"}"#, #"{"hook_event_name":"Stop","cwd":"/"}"#,
                        #"{"hook_event_name":"Stop","cwd":"  "}"#] {
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
            {"hook_event_name":"Notification","message":"  ","tool_name":"Edit"}
            """)
        #expect(event.detail == "wants to use Edit")
    }

    @Test func aPayloadThatIsNotAnObjectIsAnError() {
        for payload in ["", "not json", "[1,2]", "\"Stop\"", "{\"cwd\":"] {
            #expect(throws: UsageError.self, "\(payload)") { try AgentHook.event(agent: .claude, payload: payload) }
        }
    }

    @Test func theResolvedCardCarriesTheSessionID() throws {
        let event = try AgentHook.event(agent: .claude, payload: """
            {"session_id":"abc","cwd":"/x/blip","hook_event_name":"Notification","message":"hi",
             "notification_type":"permission_prompt"}
            """)
        let card = try CardResolver().resolve(
            kind: event.kind, title: event.title, flags: CardFlags(detail: event.detail, id: event.id))
        #expect(card.kind == "warn")
        #expect(card.title == "blip needs you")
        #expect(card.detail == "hi")
        #expect(card.id == "claude:abc")
    }
}
