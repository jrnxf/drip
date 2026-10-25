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
}
#endif
