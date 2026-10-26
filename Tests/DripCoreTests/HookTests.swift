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
            id: "claude:abc123", stays: true, isPermissionNotice: true, directory: "/Users/me/code/drip"))
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
            kind: "ok", title: "api is done", detail: "Fixed the flaky test.\n\nAll 42 tests pass.", id: "claude:s1",
            directory: "/work/api"))
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
            kind: "fail", title: "my-app stopped", detail: "API Error: Rate limit reached", id: "claude:s1",
            directory: "/work/my-app"))
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
        #expect(event.waitsOn != nil)
        #expect(event == AgentHook.Event(
            kind: "info", title: "web needs you", detail: "Codex wants to run npm install", id: "codex:019a",
            stays: true, waitsOn: event.waitsOn, directory: "/src/web"))
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
        #expect(event == AgentHook.Event(
            kind: "ok", title: "web is done", detail: "Renamed the route.", id: "codex:019a", directory: "/src/web"))
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
            stays: true, directory: "/home/user/site"))
        #expect(try AgentHook.event(agent: .gemini, payload: """
            {"hook_event_name":"Notification","notification_type":"Other","message":"m"}
            """).kind == "info")
    }

    @Test func geminiAfterAgentIsDone() throws {
        let event = try AgentHook.event(agent: .gemini, payload: """
            {"session_id":"g1","cwd":"/home/user/site","hook_event_name":"AfterAgent","prompt":"fix it",
             "prompt_response":"Fixed the `nav` *overflow*.","stop_hook_active":false}
            """)
        #expect(event == AgentHook.Event(
            kind: "ok", title: "site is done", detail: "Fixed the nav overflow.", id: "gemini:g1", directory: "/home/user/site"))
    }

    @Test func codexNotifyIsDone() throws {
        let event = try AgentHook.event(agent: .codex, payload: """
            {"type":"agent-turn-complete","thread-id":"t-9","turn-id":"1","cwd":"/src/web",
             "input-messages":["fix it"],"last-assistant-message":"Done: renamed the route."}
            """)
        #expect(event == AgentHook.Event(
            kind: "ok", title: "web is done", detail: "Done: renamed the route.", id: "codex:t-9", directory: "/src/web"))
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
            #"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#,
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

    @Test func claudePermissionRequestSaysWhatClaudeWants() throws {
        let event = try AgentHook.event(agent: .claude, payload: """
            {"session_id":"s1","cwd":"/work/api","hook_event_name":"PermissionRequest","permission_mode":"default",
             "prompt_id":"p1","tool_name":"Bash","tool_input":{"command":"npm install"}}
            """)
        #expect(event == AgentHook.Event(
            kind: "info", title: "api needs you", detail: "Claude wants to run npm install", id: "claude:s1",
            stays: true, waitsOn: event.waitsOn, directory: "/work/api"))
        #expect(event.waitsOn?.hasPrefix("p1 Bash ") == true)
        func detail(_ tool: String, _ input: String) throws -> String? {
            try AgentHook.event(agent: .claude, payload: """
                {"cwd":"/work/api","hook_event_name":"PermissionRequest","tool_name":"\(tool)","tool_input":\(input)}
                """).detail
        }
        // A file inside the session's folder reads from there; others as they are.
        #expect(try detail("Edit", #"{"file_path":"/work/api/src/main.swift","old_string":"a"}"#)
            == "Claude wants to use Edit on src/main.swift")
        #expect(try detail("Write", #"{"file_path":"/etc/hosts"}"#) == "Claude wants to use Write on /etc/hosts")
        #expect(try detail("WebFetch", #"{"url":"https://example.com/a"}"#)
            == "Claude wants to use WebFetch on https://example.com/a")
        #expect(try detail("mcp__github__create_issue", #"{"title":"x"}"#) == "Claude wants to use mcp__github__create_issue")
        // Claude's own description of a command wins, as Codex's does.
        #expect(try detail("Bash", #"{"command":"rm -rf build","description":"Clean the build"}"#) == "Clean the build")
    }

    /// The pair Claude Code 2.1.310 sent for an approved command: the request has no `tool_use_id`
    /// and its `tool_input` matches the PostToolUse's, which does carry one.
    @Test func claudeClearsAnApprovedRequestThatNamesNoToolUseId() throws {
        let asked = try AgentHook.event(agent: .claude, payload: """
            {"session_id":"0a93","prompt_id":"2421","permission_mode":"default","hook_event_name":"PermissionRequest",
             "tool_name":"Bash","tool_input":{"command":"touch approved.txt","description":"Create empty approved.txt file"},
             "permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}
            """)
        #expect(asked.waitsOn != nil)
        let ran = try AgentHook.outcome(agent: .claude, payload: """
            {"session_id":"0a93","prompt_id":"2421","permission_mode":"default","hook_event_name":"PostToolUse",
             "tool_name":"Bash","tool_input":{"command":"touch approved.txt","description":"Create empty approved.txt file"},
             "tool_response":"","tool_use_id":"toolu_01JVNJbCN3PGDewBqRhsM384","duration_ms":55}
            """)
        #expect(ran == .clear(AgentHook.Clear(id: "claude:0a93", tool: asked.waitsOn, alsoTool: "toolu_01JVNJbCN3PGDewBqRhsM384")))
        // Another command is another call.
        let elsewhere = try AgentHook.outcome(agent: .claude, payload: """
            {"session_id":"0a93","prompt_id":"2421","hook_event_name":"PostToolUse","tool_name":"Bash",
             "tool_input":{"command":"rm approved.txt"},"tool_use_id":"toolu_02"}
            """)
        guard case let .clear(clear) = elsewhere else { Issue.record("no clear"); return }
        #expect(clear.tool != asked.waitsOn)
    }

    @Test func aToolThatRanClearsOnlyTheCardWaitingOnIt() throws {
        #expect(try AgentHook.outcome(agent: .claude, payload: """
            {"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"toolu_01"}
            """) == .clear(AgentHook.Clear(id: "claude:s1", tool: "toolu_01")))
        #expect(try AgentHook.outcome(agent: .claude, payload: """
            {"session_id":"s1","hook_event_name":"PostToolUseFailure","tool_use_id":"toolu_02","error":"denied"}
            """) == .clear(AgentHook.Clear(id: "claude:s1", tool: "toolu_02")))
        // Without the call it ran, or a session, a tool clears nothing: it could take the wrong card.
        #expect(try AgentHook.outcome(agent: .claude, payload: """
            {"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Read"}
            """) == .nothing)
        #expect(try AgentHook.outcome(agent: .claude, payload: """
            {"hook_event_name":"PostToolUse","tool_use_id":"toolu_01"}
            """) == .nothing)
        // A prompt you sent, or an answer to a question, clears whatever the session waits on; only
        // the prompt starts a turn.
        #expect(try AgentHook.outcome(agent: .claude, payload: """
            {"session_id":"s1","hook_event_name":"UserPromptSubmit"}
            """) == .clear(AgentHook.Clear(id: "claude:s1", startsTurn: true)))
        #expect(try AgentHook.outcome(agent: .claude, payload: """
            {"session_id":"s1","hook_event_name":"ElicitationResult"}
            """) == .clear(AgentHook.Clear(id: "claude:s1")))
        #expect(throws: UsageError.self) {
            try AgentHook.event(agent: .claude, payload: #"{"session_id":"s1","hook_event_name":"UserPromptSubmit"}"#)
        }
    }

    @Test func codexMatchesTheCallItRanToThePermissionItAsked() throws {
        let asked = try AgentHook.event(agent: .codex, payload: """
            {"session_id":"019a","turn_id":"t1","hook_event_name":"PermissionRequest","tool_name":"Bash",
             "tool_input":{"command":"npm install","description":null}}
            """)
        // PostToolUse repeats the input, its keys in whatever order, with the call's id and result.
        let ran = try AgentHook.outcome(agent: .codex, payload: """
            {"session_id":"019a","turn_id":"t1","hook_event_name":"PostToolUse","tool_name":"Bash",
             "tool_use_id":"call_9","tool_input":{"description":null,"command":"npm install"},"tool_response":"ok"}
            """)
        #expect(ran == .clear(AgentHook.Clear(id: "codex:019a", tool: asked.waitsOn)))
        let other = try AgentHook.outcome(agent: .codex, payload: """
            {"session_id":"019a","turn_id":"t1","hook_event_name":"PostToolUse","tool_name":"Bash",
             "tool_input":{"command":"ls"}}
            """)
        #expect(other != ran)
        #expect(try AgentHook.outcome(agent: .codex, payload: """
            {"session_id":"019a","turn_id":"t2","hook_event_name":"UserPromptSubmit","prompt":"go on"}
            """) == .clear(AgentHook.Clear(id: "codex:019a", startsTurn: true)))
        // Without a turn, no call to match: nothing.
        #expect(try AgentHook.outcome(agent: .codex, payload: """
            {"session_id":"019a","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{}}
            """) == .nothing)
    }

    /// The pair Codex 0.164.0 sent for an approved command: the request's `tool_input` carries a
    /// `description` (the question it asks) that the PostToolUse repeat leaves out.
    @Test func codexClearsAnApprovedRequestWhoseInputCarriesADescription() throws {
        let asked = try AgentHook.event(agent: .codex, payload: """
            {"session_id":"01a1","turn_id":"01a2","cwd":"/home/user/drip-contract","hook_event_name":"PermissionRequest",
             "model":"gpt-6.1-sol","permission_mode":"default","tool_name":"Bash",
             "tool_input":{"command":"touch approved.txt","description":"Do you approve running touch approved.txt outside the read-only sandbox in this directory?"}}
            """)
        #expect(asked.detail == "Do you approve running touch approved.txt outside the read-only sandbox in this directory?")
        #expect(asked.waitsOn != nil)
        let ran = try AgentHook.outcome(agent: .codex, payload: """
            {"session_id":"01a1","turn_id":"01a2","cwd":"/home/user/drip-contract","hook_event_name":"PostToolUse",
             "model":"gpt-6.1-sol","permission_mode":"default","tool_name":"Bash",
             "tool_input":{"command":"touch approved.txt"},"tool_response":"","tool_use_id":"exec-3e2b"}
            """)
        #expect(ran == .clear(AgentHook.Clear(id: "codex:01a1", tool: asked.waitsOn)))
    }

    /// Dropping `description` must not make unlike calls alike: a different command, tool or turn
    /// still names a different call, so one call's PostToolUse never takes another's card.
    @Test func codexCallsThatDifferStillDoNotClearEachOther() throws {
        func request(turn: String = "t1", tool: String = "Bash", input: String) throws -> String? {
            try AgentHook.event(agent: .codex, payload: """
                {"session_id":"s","turn_id":"\(turn)","hook_event_name":"PermissionRequest","tool_name":"\(tool)",
                 "tool_input":\(input)}
                """).waitsOn
        }
        func ran(turn: String = "t1", tool: String = "Bash", input: String) throws -> AgentHook.Outcome {
            try AgentHook.outcome(agent: .codex, payload: """
                {"session_id":"s","turn_id":"\(turn)","hook_event_name":"PostToolUse","tool_name":"\(tool)",
                 "tool_input":\(input),"tool_use_id":"call_1"}
                """)
        }
        let rm = try request(input: #"{"command":"rm a","description":"Allow rm a?"}"#)
        let touch = try request(input: #"{"command":"touch a","description":"Allow touch a?"}"#)
        #expect(rm != touch)
        // Both wait at once; each call's PostToolUse takes away only its own card.
        #expect(try ran(input: #"{"command":"rm a"}"#) == .clear(AgentHook.Clear(id: "codex:s", tool: rm)))
        #expect(try ran(input: #"{"command":"touch a"}"#) == .clear(AgentHook.Clear(id: "codex:s", tool: touch)))
        #expect(try ran(input: #"{"command":"rm b"}"#) != .clear(AgentHook.Clear(id: "codex:s", tool: rm)))
        #expect(try ran(tool: "Edit", input: #"{"command":"rm a"}"#) != .clear(AgentHook.Clear(id: "codex:s", tool: rm)))
        #expect(try ran(turn: "t2", input: #"{"command":"rm a"}"#) != .clear(AgentHook.Clear(id: "codex:s", tool: rm)))
        // Only the top-level description is set aside: a nested one is part of the input.
        #expect(try request(input: #"{"a":{"description":"x"}}"#) != request(input: #"{"a":{"description":"y"}}"#))
    }

    @Test func geminiClearsOnAnyToolOrPrompt() throws {
        for (event, startsTurn) in [("AfterTool", false), ("BeforeAgent", true)] {
            #expect(try AgentHook.outcome(agent: .gemini, payload: """
                {"session_id":"g1","hook_event_name":"\(event)","tool_name":"run_shell_command"}
                """) == .clear(AgentHook.Clear(id: "gemini:g1", startsTurn: startsTurn)))
        }
    }

    @Test func aDoneCardIsLeftOutUnderAttentionOrForAQuickTurn() {
        let done = AgentHook.Event(kind: "ok", title: "api is done", id: "claude:s1")
        let failed = AgentHook.Event(kind: "fail", title: "api stopped", id: "claude:s1")
        let waits = AgentHook.Event(kind: "info", title: "api needs you", id: "claude:s1", stays: true)
        func skips(_ event: AgentHook.Event, _ cards: AgentHook.Cards = .all, after: Double = 0, started: Double? = 100) -> Bool {
            AgentHook.skipsDone(event, cards: cards, doneAfter: after, turnStarted: started, now: 120)
        }
        #expect(!skips(done))
        #expect(skips(done, .attention))
        // A 20 second turn, under done_after = 30 but not 10.
        #expect(skips(done, after: 30))
        #expect(!skips(done, after: 10))
        // No turn seen, as when drip's hooks came mid-turn: the card shows.
        #expect(!skips(done, after: 30, started: nil))
        for event in [failed, waits] {
            #expect(!skips(event, .attention, after: 30))
        }
    }

    @Test func eachAgentsHooksShowOrClear() throws {
        for agent in AgentHook.Agent.allCases {
            for event in AgentHook.clearEvents(for: agent) {
                let outcome = try AgentHook.outcome(agent: agent, payload: """
                    {"session_id":"s","turn_id":"t","hook_event_name":"\(event)","tool_name":"x","tool_use_id":"u"}
                    """)
                guard case .clear = outcome else {
                    Issue.record("\(agent) \(event): \(outcome)")
                    continue
                }
            }
        }
    }

    /// `claude -p` and the pipelines that run it raise no card: nobody is at that terminal.
    @Test func aSessionNobodyAttendsStaysSilent() throws {
        let interactive = ["CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_SESSION_ATTENDED": "1"]
        #expect(try AgentHook.speaks(for: .claude, environment: interactive))
        #expect(try AgentHook.speaks(for: .claude, environment: [:]))
        // An interactive session started from inside `claude -p` inherits its entrypoint, but
        // Claude Code marks it attended.
        let started = ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli", "CLAUDE_CODE_SESSION_ATTENDED": "1"]
        #expect(try AgentHook.speaks(for: .claude, environment: started))
        for headless in [
            ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli", "CLAUDE_CODE_SESSION_ATTENDED": "0"],
            ["CLAUDE_CODE_SESSION_ATTENDED": "0"], ["CLAUDE_CODE_ENTRYPOINT": "sdk-ts"], ["CLAUDE_CODE_ENTRYPOINT": "sdk-py"],
        ] {
            #expect(try !AgentHook.speaks(for: .claude, environment: headless), "\(headless)")
        }
        // Claude's variables say nothing about another agent's session.
        #expect(try AgentHook.speaks(for: .codex, environment: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]))
    }

    @Test func dripHookTurnsTheHooksOffOrOn() throws {
        for agent in AgentHook.Agent.allCases {
            #expect(try !AgentHook.speaks(for: agent, environment: ["DRIP_HOOK": "off"]))
            #expect(try AgentHook.speaks(for: agent, environment: ["DRIP_HOOK": "on", "CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]))
            #expect(try AgentHook.speaks(for: agent, environment: ["DRIP_HOOK": ""]))
        }
        #expect(throws: UsageError.self) { try AgentHook.speaks(for: .claude, environment: ["DRIP_HOOK": "quiet"]) }
    }

    /// `DRIP_HOOK=attention` is for an orchestrator's own session: the cards that need you stay, the
    /// done card of every turn goes, and the clear events still take a waiting card away.
    @Test func attentionSkipsOnlyTheDoneCards() throws {
        let attention = ["DRIP_HOOK": "attention"]
        let payloads: [(AgentHook.Agent, done: [String], waiting: [String], failure: [String], clear: [String])] = [
            (.claude,
             [#"{"hook_event_name":"Stop","session_id":"s"}"#],
             [#"{"hook_event_name":"Notification","session_id":"s","message":"m","notification_type":"permission_prompt"}"#,
              #"{"hook_event_name":"Notification","session_id":"s","message":"m","notification_type":"idle_prompt"}"#,
              #"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash"}"#],
             [#"{"hook_event_name":"StopFailure","session_id":"s","error":"rate_limit"}"#],
             AgentHook.clearEvents(for: .claude).map { #"{"hook_event_name":"\#($0)","session_id":"s","tool_use_id":"u"}"# }),
            (.codex,
             [#"{"hook_event_name":"Stop","session_id":"s"}"#,
              #"{"type":"agent-turn-complete","thread-id":"s","last-assistant-message":"ok"}"#],
             [#"{"hook_event_name":"PermissionRequest","session_id":"s","turn_id":"t","tool_name":"Bash"}"#],
             [],
             AgentHook.clearEvents(for: .codex).map { #"{"hook_event_name":"\#($0)","session_id":"s","turn_id":"t","tool_name":"x"}"# }),
            (.gemini,
             [#"{"hook_event_name":"AfterAgent","session_id":"s","prompt_response":"ok"}"#],
             [#"{"hook_event_name":"Notification","session_id":"s","message":"m","notification_type":"ToolPermission"}"#],
             [],
             AgentHook.clearEvents(for: .gemini).map { #"{"hook_event_name":"\#($0)","session_id":"s"}"# }),
        ]
        for (agent, done, waiting, failure, clear) in payloads {
            #expect(try AgentHook.speaks(for: agent, environment: attention))
            for payload in done {
                guard case let .card(event) = try AgentHook.outcome(agent: agent, payload: payload) else {
                    Issue.record("\(agent) done: \(payload)")
                    continue
                }
                #expect(try !AgentHook.shows(event, environment: attention), "\(agent) \(payload)")
                #expect(try AgentHook.shows(event, environment: ["DRIP_HOOK": "on"]), "\(agent) \(payload)")
                #expect(try AgentHook.shows(event, environment: [:]), "\(agent) \(payload)")
            }
            for payload in waiting + failure {
                guard case let .card(event) = try AgentHook.outcome(agent: agent, payload: payload) else {
                    Issue.record("\(agent) card: \(payload)")
                    continue
                }
                #expect(try AgentHook.shows(event, environment: attention), "\(agent) \(payload)")
            }
            for payload in clear {
                guard case .clear = try AgentHook.outcome(agent: agent, payload: payload, environment: attention) else {
                    Issue.record("\(agent) clear: \(payload)")
                    continue
                }
            }
        }
        // Unlike an unset DRIP_HOOK, it speaks from a session nobody attends, as `on` does.
        #expect(try AgentHook.speaks(for: .claude, environment: ["DRIP_HOOK": "attention", "CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]))
    }

    @Test func dripHookErrorListsEveryValue() throws {
        do {
            _ = try AgentHook.speaks(for: .claude, environment: ["DRIP_HOOK": "quiet"])
            Issue.record("expected a UsageError")
        } catch let error as UsageError {
            #expect(error.message.contains("DRIP_HOOK must be on, off or attention, not 'quiet'"), "\(error.message)")
        }
    }

    /// Codex's cards take their sound from their look, as Claude's do: the same preset, the same sound.
    @Test func everyAgentsCardsSoundTheSame() throws {
        let payloads: [AgentHook.Agent: (needs: String, done: String)] = [
            .claude: (#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#, #"{"hook_event_name":"Stop"}"#),
            .codex: (#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#, #"{"hook_event_name":"Stop"}"#),
            .gemini: (#"{"hook_event_name":"Notification","notification_type":"ToolPermission"}"#, #"{"hook_event_name":"AfterAgent"}"#),
        ]
        var sounds: [AgentHook.Agent: [Sound]] = [:]
        for (agent, payload) in payloads {
            sounds[agent] = try [payload.needs, payload.done].map { json in
                let event = try AgentHook.event(agent: agent, payload: json)
                return try CardResolver().resolve(kind: event.kind, title: event.title, flags: event.filling(CardFlags())).sound
            }
        }
        #expect(sounds[.codex] == sounds[.claude])
        #expect(sounds[.gemini] == sounds[.claude])
        #expect(sounds[.claude]?.allSatisfy { $0 != .none } == true)
    }

    @Test func fingerprintsAreStableAndShort() {
        #expect(AgentHook.fingerprint("") == "cbf29ce484222325")
        #expect(AgentHook.fingerprint("claude:abc").count == 16)
        #expect(AgentHook.fingerprint("a") != AgentHook.fingerprint("b"))
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
