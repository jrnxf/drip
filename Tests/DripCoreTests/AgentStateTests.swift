#if !os(WASI)
import DripCore
import Foundation
import Testing

/// What drip keeps between an agent's hooks, and the dismissals the drips showing cards act on.
struct AgentStateTests {
    let directory: String
    let state: AgentState
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("drip-agents-\(UUID().uuidString)").path
        state = AgentState(directory: directory)
    }

    @Test func aToolThatRanTakesOnlyTheCardWaitingOnIt() throws {
        try state.noteWaiting(id: "claude:s1", tool: "toolu_01", now: now)
        // Another call ran, as a tool run alongside the one that asked: the card stays.
        #expect(!state.takeWaiting(AgentHook.Clear(id: "claude:s1", tool: "toolu_02"), now: now))
        #expect(!state.takeWaiting(AgentHook.Clear(id: "claude:s2", tool: "toolu_01"), now: now))
        #expect(state.waiting(id: "claude:s1", now: now)?.tool == "toolu_01")
        #expect(state.takeWaiting(AgentHook.Clear(id: "claude:s1", tool: "toolu_01"), now: now))
        // Once: the card is gone.
        #expect(!state.takeWaiting(AgentHook.Clear(id: "claude:s1", tool: "toolu_01"), now: now))
        #expect(state.waiting(id: "claude:s1", now: now) == nil)
    }

    @Test func aTurnStartsWithAPromptAndIsForgottenWithTheWaitLimit() throws {
        #expect(state.turnStarted(id: "claude:s1", now: now) == nil)
        try state.noteTurn(id: "claude:s1", now: now)
        #expect(state.turnStarted(id: "claude:s1", now: now) == now.timeIntervalSince1970)
        #expect(state.turnStarted(id: "claude:s2", now: now) == nil)
        #expect(state.turnStarted(id: "claude:s1", now: now.addingTimeInterval(Defaults.waitLimit)) == nil)
    }

    @Test func aNewPromptDeletesTurnsGoneQuiet() throws {
        let later = now.addingTimeInterval(Defaults.waitLimit)
        try state.noteTurn(id: "claude:old", now: now)
        try state.noteTurn(id: "claude:recent", now: later.addingTimeInterval(-1))
        try state.noteTurn(id: "claude:new", now: later)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory).count == 2)
        #expect(state.turnStarted(id: "claude:recent", now: later) != nil)
        #expect(state.turnStarted(id: "claude:new", now: later) != nil)
    }

    /// Claude Code sends Stop again when another Stop hook keeps it going: the turn still counts
    /// from the prompt.
    @Test func aTurnOutlivesItsDoneCard() throws {
        try state.noteTurn(id: "claude:s1", now: now)
        #expect(state.turnStarted(id: "claude:s1", now: now.addingTimeInterval(5)) == now.timeIntervalSince1970)
        #expect(state.turnStarted(id: "claude:s1", now: now.addingTimeInterval(10)) == now.timeIntervalSince1970)
    }

    @Test func aTurnGoneQuietIsDeletedWithTheSessions() throws {
        try state.noteTurn(id: "claude:old", now: now)
        try state.noteTurn(id: "claude:new", now: now.addingTimeInterval(Defaults.waitLimit))
        _ = state.otherDirectories(than: "claude:a", now: now.addingTimeInterval(Defaults.waitLimit))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        #expect(names.count == 1)
        #expect(state.turnStarted(id: "claude:new", now: now.addingTimeInterval(Defaults.waitLimit)) != nil)
    }

    @Test func aToolCallKnownByTwoNamesTakesTheCardWaitingOnEither() throws {
        try state.noteWaiting(id: "claude:s1", tool: "toolu_01", now: now)
        #expect(!state.takeWaiting(AgentHook.Clear(id: "claude:s1", tool: "p1 Bash 1f", alsoTool: "toolu_02"), now: now))
        #expect(state.takeWaiting(AgentHook.Clear(id: "claude:s1", tool: "p1 Bash 1f", alsoTool: "toolu_01"), now: now))
    }

    /// You approve a Claude Code permission prompt in the terminal, so its tool runs: the card that
    /// said Claude needs you goes then, not at the end of the turn. The pair Claude Code 2.1.310
    /// sent, whose `PermissionRequest` names no `tool_use_id`.
    @Test func approvingAClaudePromptTakesItsCardAwayWhenTheToolRuns() throws {
        let ask = """
            {"session_id":"0a93","cwd":"/work/api","prompt_id":"2421","permission_mode":"default",
             "hook_event_name":"PermissionRequest","tool_name":"Bash",
             "tool_input":{"command":"touch approved.txt","description":"Create empty approved.txt file"}}
            """
        func ran(_ command: String, _ toolUseId: String) -> String {
            """
            {"session_id":"0a93","cwd":"/work/api","prompt_id":"2421","permission_mode":"default",
             "hook_event_name":"PostToolUse","tool_name":"Bash",
             "tool_input":{"command":"\(command)","description":"Create empty approved.txt file"},
             "tool_response":"","tool_use_id":"\(toolUseId)","duration_ms":55}
            """
        }
        guard case let .card(asked) = try AgentHook.outcome(agent: .claude, payload: ask), let id = asked.id else {
            Issue.record("no card for the request")
            return
        }
        try state.noteWaiting(id: id, tool: asked.waitsOn, now: now)
        // Another command that ran alongside leaves the card.
        guard case let .clear(other) = try AgentHook.outcome(agent: .claude, payload: ran("ls", "toolu_02")) else {
            Issue.record("no clear for another command")
            return
        }
        #expect(!state.takeWaiting(other, now: now))
        #expect(state.waiting(id: id, now: now) != nil)
        guard case let .clear(approved) = try AgentHook.outcome(
            agent: .claude, payload: ran("touch approved.txt", "toolu_01JVNJbCN3PGDewBqRhsM384"))
        else {
            Issue.record("no clear for the approved command")
            return
        }
        #expect(state.takeWaiting(approved, now: now))
        #expect(state.waiting(id: id, now: now) == nil)
    }

    @Test func aPromptTakesWhateverTheSessionWaitsOn() throws {
        try state.noteWaiting(id: "gemini:g1", tool: nil, now: now)
        // A clear for one tool call never takes a card that names none.
        #expect(!state.takeWaiting(AgentHook.Clear(id: "gemini:g1", tool: "x"), now: now))
        #expect(state.takeWaiting(AgentHook.Clear(id: "gemini:g1"), now: now))
        try state.noteWaiting(id: "claude:s1", tool: "toolu_01", now: now)
        #expect(state.takeWaiting(AgentHook.Clear(id: "claude:s1"), now: now))
    }

    @Test func aCardThatCountsDownEndsTheWait() throws {
        try state.noteWaiting(id: "claude:s1", tool: "toolu_01", now: now)
        state.noteDone(id: "claude:s1")
        #expect(state.waiting(id: "claude:s1", now: now) == nil)
        // Nothing waits: nothing to take, and no error.
        #expect(!state.takeWaiting(AgentHook.Clear(id: "claude:s1"), now: now))
    }

    @Test func aWaitOutlivesItsCardByNoMore() throws {
        try state.noteWaiting(id: "claude:s1", tool: nil, now: now)
        #expect(state.waiting(id: "claude:s1", now: now.addingTimeInterval(Defaults.waitLimit - 1)) != nil)
        #expect(state.waiting(id: "claude:s1", now: now.addingTimeInterval(Defaults.waitLimit)) == nil)
    }

    @Test func sessionsInFoldersOfTheSameNameReadApart() throws {
        try state.noteSession(id: "claude:a", directory: "/home/user/pool/1/drip", now: now)
        try state.noteSession(id: "claude:b", directory: "/home/user/pool/2/drip", now: now)
        try state.noteSession(id: "claude:c", directory: "/home/user/web", now: now)
        let others = state.otherDirectories(than: "claude:a", now: now)
        #expect(Set(others) == ["/home/user/pool/2/drip", "/home/user/web"])
        #expect(AgentState.project("/home/user/pool/1/drip", among: others) == "1/drip")
        #expect(AgentState.project("/home/user/web", among: others) == "web")
        // The same folder twice reads the same: there is nothing to tell apart.
        #expect(AgentState.project("/home/user/web", among: ["/home/user/web"]) == "web")
        #expect(AgentState.project("/a/x/repo", among: ["/b/x/repo"]) == "a/x/repo")
        #expect(AgentState.project("/repo", among: ["/x/repo"]) == "repo")
        // A session gone quiet is forgotten.
        #expect(state.otherDirectories(than: "claude:a", now: now.addingTimeInterval(Defaults.waitLimit)).isEmpty)
    }

    @Test func aDismissalTakesOnlyCardsThatCameBeforeIt() throws {
        let requests = DismissRequests(directory: directory + "/dismiss")
        #expect(requests.load(now: now).isEmpty)
        try requests.request(id: "claude:s1", now: now)
        let loaded = requests.load(now: now)
        let before = now.timeIntervalSince1970 - 1, after = now.timeIntervalSince1970 + 1
        #expect(loaded.dismisses(id: "claude:s1", since: before))
        #expect(!loaded.dismisses(id: "claude:s1", since: after))
        #expect(!loaded.dismisses(id: "claude:s2", since: before))
        #expect(!loaded.dismisses(id: nil, since: before))

        // Every card, with no id.
        try requests.request(id: nil, now: now)
        #expect(requests.load(now: now).dismisses(id: nil, since: before))
        #expect(requests.load(now: now).dismisses(id: "codex:x", since: before))
        #expect(!requests.load(now: now).dismisses(id: "codex:x", since: after))

        // Old requests are forgotten, and their files go.
        #expect(requests.load(now: now.addingTimeInterval(Defaults.waitLimit)).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory + "/dismiss").filter { $0.hasSuffix(".json") }.isEmpty)
    }

    /// You deny a permission in the terminal, so no tool runs to take its card away, and the turn
    /// ends. Under `DRIP_HOOK=attention` no done card shows, but the waiting card still goes.
    @Test func aSkippedDoneCardStillEndsTheWait() throws {
        let attention = ["DRIP_HOOK": "attention"]
        let turns: [(AgentHook.Agent, ask: String, done: String)] = [
            (.claude,
             #"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash"}"#,
             #"{"hook_event_name":"Stop","session_id":"s"}"#),
            (.codex,
             #"{"hook_event_name":"PermissionRequest","session_id":"s","turn_id":"t","tool_name":"Bash"}"#,
             #"{"hook_event_name":"Stop","session_id":"s"}"#),
            (.gemini,
             #"{"hook_event_name":"Notification","session_id":"s","message":"m","notification_type":"ToolPermission"}"#,
             #"{"hook_event_name":"AfterAgent","session_id":"s","prompt_response":"ok"}"#),
        ]
        for (agent, ask, done) in turns {
            guard case let .card(asked) = try AgentHook.outcome(agent: agent, payload: ask, environment: attention),
                  let id = asked.id, asked.stays
            else {
                Issue.record("\(agent) ask: \(ask)")
                continue
            }
            try state.noteWaiting(id: id, tool: asked.waitsOn, now: now)
            guard case let .clear(clear) = try AgentHook.outcome(agent: agent, payload: done, environment: attention) else {
                Issue.record("\(agent) done: \(done)")
                continue
            }
            #expect(clear.id == id)
            #expect(state.takeWaiting(clear, now: now), "\(agent)")
            #expect(state.waiting(id: id, now: now) == nil, "\(agent)")
            // Under `on` the done card itself replaces the waiting card.
            guard case .card = try AgentHook.outcome(agent: agent, payload: done, environment: ["DRIP_HOOK": "on"]) else {
                Issue.record("\(agent) on: \(done)")
                continue
            }
        }
        // A done card with no session has no waiting card to take.
        #expect(try AgentHook.outcome(agent: .codex, payload: #"{"type":"agent-turn-complete","last-assistant-message":"ok"}"#,
                                      environment: attention) == .nothing)
    }
}
#endif
