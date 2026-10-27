import DripCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import Testing

/// Agents on another machine: the line `drip-remote-hook` queues, and how `drip follow` reads it.
struct RemoteEventTests {
    static let line = #"""
        {"drip":1,"time":1800000000,"agent":"claude","machine":"devbox","env":{"DRIP_HOOK":"attention","CLAUDE_CODE_SESSION_ATTENDED":"","CLAUDE_CODE_ENTRYPOINT":"cli","HERDR_PANE_ID":"w1:p2","HERDR_TAB_ID":"w1:t3","HERDR_WORKSPACE_ID":"w1","OTHER":"x"},"payload":{"session_id":"s1","cwd":"/home/user/api", "hook_event_name":"Stop","last_assistant_message":"Done."} }
        """#

    @Test func aQueueLineIsAnEvent() throws {
        let event = try RemoteEvent(line: Self.line)
        #expect(event.time == 1_800_000_000)
        #expect(event.agent == .claude)
        #expect(event.machine == "devbox")
        // Empty values and variables the hook does not pass are left out.
        #expect(event.environment == [
            "DRIP_HOOK": "attention", "CLAUDE_CODE_ENTRYPOINT": "cli", "HERDR_PANE_ID": "w1:p2",
            "HERDR_TAB_ID": "w1:t3", "HERDR_WORKSPACE_ID": "w1",
        ])
        #expect(try AgentHook.event(agent: .claude, payload: event.payload).title == "api is done")
    }

    @Test func aLineThatIsNoEventSaysWhy() {
        func problem(_ line: String) -> String? {
            do {
                _ = try RemoteEvent(line: line)
                return nil
            } catch {
                return "\(error)"
            }
        }
        #expect(problem("not json") == "not a JSON object")
        #expect(problem(#"{"drip":2}"#) == "not a drip-remote-hook event of format 1")
        #expect(problem(#"{"drip":1,"time":1,"agent":"cursor"}"#) == "no agent drip knows")
        #expect(problem(#"{"drip":1,"time":1,"agent":"codex","machine":"-x"}"#) == "no machine name")
        #expect(problem(#"{"drip":1,"time":1,"agent":"codex","machine":"devbox","payload":"{}"}"#) == "no payload")
    }

    @Test func theSessionsVariablesReplaceTheMacsOwn() throws {
        let event = try RemoteEvent(line: Self.line)
        let merged = event.environment(over: [
            "HOME": "/Users/me", "DRIP_HOOK": "off", "DRIP_AGENT_CARDS": "attention", "TMUX": "/tmp/t,1,0",
            "TMUX_PANE": "%1", "__CFBundleIdentifier": "com.apple.Terminal", "CLAUDE_CODE_SESSION_ATTENDED": "0",
        ])
        #expect(merged == [
            "HOME": "/Users/me", "DRIP_AGENT_CARDS": "attention", "DRIP_HOOK": "attention",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
        ])
    }

    @Test func aClickFocusesTheAgentsWorkspaceAndTabOnItsMachine() throws {
        let origin = try RemoteEvent(line: Self.line).origin(activate: "com.mitchellh.ghostty", herdrMachine: "devbox")
        #expect(origin.machine == "devbox")
        #expect(origin.activate == "com.mitchellh.ghostty")
        let pane = try #require(origin.pane)
        #expect(pane.selectCommands == [
            ["herdr", "--machine", "devbox", "workspace", "focus", "w1"],
            ["herdr", "--machine", "devbox", "tab", "focus", "w1:t3"],
        ])
        // That machine's herdr says whether the agent's pane is in front there.
        #expect(pane.herdrShowingCommand == ["herdr", "--machine", "devbox", "pane", "get", "w1:p2"])
        #expect(pane.hostName == "devbox")
        #expect(origin.qualified("claude:s1") == "claude:s1@devbox")
        // Outside herdr, or without a machine to name: nothing to focus.
        #expect(RemoteEvent(time: 0, agent: .codex, machine: "devbox", environment: [:], payload: "{}")
            .origin(activate: nil, herdrMachine: "devbox").pane == nil)
        #expect(try RemoteEvent(line: Self.line).origin(activate: nil, herdrMachine: nil).pane == nil)
    }

    @Test func anEventFromAheadOfThisClockIsNew() throws {
        let event = try RemoteEvent(line: Self.line)
        #expect(event.age(now: 1_800_000_090) == 90)
        #expect(event.age(now: 1_799_999_990) == 0)
    }

    @Test func theStreamKeepsThePlaceInTheQueue() throws {
        var stream = FollowReader.Stream(position: nil)
        let line = Self.line + "\n"
        var lines = stream.read(Array("#drip-follow 2\n#file 42 100\n=".utf8) + Array(line.utf8.prefix(10)))
        #expect(lines.map(\.0) == [.hello, .file(FollowPosition(inode: "42", offset: 100))])
        // Half a line waits for the rest.
        lines = stream.read(Array(line.utf8.dropFirst(10)) + Array("#\n=not json\n#missing /home/user/q.jsonl\n".utf8))
        #expect(lines.count == 4)
        guard case .event(.success)? = lines.first?.0 else { Issue.record("\(lines)"); return }
        // The place moves by the queue's own line, not the `=` before it.
        #expect(lines[0].1 == FollowPosition(inode: "42", offset: 100 + line.utf8.count))
        #expect(lines[1].0 == .heartbeat)
        // A line that is no event still moves the place past it.
        #expect(lines[2].0 == .event(.failure(UsageError("not a JSON object"))))
        #expect(lines[3].0 == .missing("/home/user/q.jsonl"))
        #expect(stream.position == FollowPosition(inode: "42", offset: 100 + line.utf8.count + 9))
    }

    @Test func whatTheRemoteShellPrintsNeverMovesThePlace() throws {
        var stream = FollowReader.Stream(position: FollowPosition(inode: "42", offset: 0))
        // A banner from the shell's startup files, before the reader starts, even one that looks
        // like the reader's own lines; then stray output while it runs.
        let lines = stream.read(Array("Welcome to devbox\n#file 7 900\n=\(Self.line)\n#drip-follow 2\nstray output\n#later\n".utf8))
        #expect(lines.map(\.0) == [
            .noise("Welcome to devbox"), .noise("#file 7 900"), .noise("=\(Self.line)"), .hello, .noise("stray output"),
            .noise("#later"),
        ])
        #expect(stream.position == FollowPosition(inode: "42", offset: 0))
    }

    @Test func aLineTooLongIsSkippedToItsEnd() {
        var stream = FollowReader.Stream(position: FollowPosition(inode: "1", offset: 0))
        let long = [UInt8](repeating: UInt8(ascii: "x"), count: FollowReader.Stream.lineLimit + 5)
        var lines = stream.read(Array("#drip-follow 2\n=".utf8) + long + Array("\n".utf8))
        #expect(lines.count == 2)
        guard case .event(.failure)? = lines.last?.0 else { Issue.record("\(lines)"); return }
        #expect(stream.position?.offset == long.count + 1)
        // Output as long that is not the queue's moves nothing.
        lines = stream.read(long + Array("\n".utf8))
        guard case .noise? = lines.last?.0 else { Issue.record("\(lines)"); return }
        #expect(stream.position?.offset == long.count + 1)
    }

    @Test func setupPrintsTheRemoteHookAndItsHooks() throws {
        guard case let .invocation(.setup(remote)) = CommandLineParser.parse(["setup", "remote"]) else {
            Issue.record(); return
        }
        #expect(remote.agent == nil)
        guard case let .invocation(.setup(claude)) = CommandLineParser.parse(["setup", "claude", "--remote"]) else {
            Issue.record(); return
        }
        #expect(claude.agent == .claude)
        #expect(claude.remote)
        #expect(AgentSetup.snippet(for: .claude, remote: true).contains(#""command": "drip-remote-hook claude""#))
        #expect(!AgentSetup.snippet(for: .claude, remote: true).contains("drip hook"))
        guard case let .exit(status, _) = CommandLineParser.parse(["setup", "codex", "--print", "--remote"]) else {
            Issue.record(); return
        }
        #expect(status == ExitStatus.usage)
    }

    @Test func followTakesTheMachineAndItsOptions() throws {
        guard case let .invocation(.follow(plain)) = CommandLineParser.parse(["follow", "me@devbox"]) else {
            Issue.record(); return
        }
        #expect(plain.target == "me@devbox")
        #expect(plain.maxAge == FollowCommand.defaultMaxAge)
        #expect(plain.herdrMachine == "devbox")
        #expect(plain.queue == nil)
        guard case let .invocation(.follow(full)) = CommandLineParser.parse([
            "follow", "devbox", "--max-age", "1h", "--herdr-machine", "build-box", "--activate", "com.apple.Terminal",
            "--queue", "/srv/queue.jsonl",
        ]) else { Issue.record(); return }
        #expect(full.maxAge == 3600)
        #expect(full.herdrMachine == "build-box")
        // herdr's saved machines: the one saved for the target, by its label, unless one is named.
        let saved = #"[{"id":"7fa0","label":"devbox.example.com","target":"devbox","enabled":true}]"#
        #expect(full.herdrMachine(savedMachines: { saved }) == "build-box")
        guard case let .invocation(.follow(target)) = CommandLineParser.parse(["follow", "devbox"]) else {
            Issue.record(); return
        }
        #expect(target.herdrMachine(savedMachines: { saved }) == "devbox.example.com")
        #expect(target.herdrMachine(savedMachines: { "[]" }) == "devbox")
        #expect(target.herdrMachine(savedMachines: { nil }) == "devbox")
        #expect(full.activate == "com.apple.Terminal")
        #expect(full.queue == "/srv/queue.jsonl")
        for arguments in [
            ["follow"], ["follow", "-oProxyCommand=x"], ["follow", "dev box"], ["follow", "devbox", "--max-age", "soon"],
            ["follow", "devbox", "--herdr-machine", "-x"], ["follow", "devbox", "--activate", "not an app"],
        ] {
            guard case let .exit(status, _) = CommandLineParser.parse(arguments) else {
                Issue.record("\(arguments)"); continue
            }
            #expect(status == ExitStatus.usage, "\(arguments)")
        }
    }
}

#if !os(WASI)
/// `drip-remote-hook` run by sh, and `drip follow` reading what it queued through a fake ssh that
/// runs the reader here: no real connection is ever made.
@Suite(.serialized)
struct RemoteFollowTests {
    let root: String
    let queue: String
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("drip-remote-\(UUID().uuidString)").path
        queue = "\(root)/remote/drip/remote.jsonl"
        environment = ["HOME": root, "XDG_STATE_HOME": "\(root)/mac", "XDG_CONFIG_HOME": "\(root)/mac-config"]
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try RemoteHook.script.write(toFile: "\(root)/drip-remote-hook", atomically: false, encoding: .utf8)
        // ssh's options, then `--`, the target, and the command, which runs here.
        try write(script: "ssh", """
            #!/bin/sh
            while [ "$1" != "--" ]; do shift; done
            shift 2
            exec "$@"
            """)
        // Prints a banner, as a shell's startup files can, before the command runs.
        try write(script: "banner-ssh", """
            #!/bin/sh
            echo "Welcome to devbox"
            exec "\(root)/ssh" "$@"
            """)
        // Fails to connect once, then connects.
        try write(script: "flaky-ssh", """
            #!/bin/sh
            if [ ! -e "\(root)/tried" ]; then : >"\(root)/tried"; exit 255; fi
            exec "\(root)/ssh" "$@"
            """)
    }

    func write(script name: String, _ text: String) throws {
        try (text + "\n").write(toFile: "\(root)/\(name)", atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(root)/\(name)")
    }

    /// Runs `drip-remote-hook` with sh, as an agent's hook would on the remote machine.
    @discardableResult
    func hook(_ arguments: [String], stdin: String = "", environment extra: [String: String] = [:]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["\(root)/drip-remote-hook"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "\(root)/remote", "DRIP_QUEUE": queue, "DRIP_MACHINE": "devbox"]
            .merging(extra) { $1 }
        let input = Pipe()
        process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        // The hook never holds up a turn: give it 20 seconds at most.
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(!process.isRunning, "drip-remote-hook \(arguments) did not end")
        RemoteFollower.end(process, patience: 0)
        return process.terminationStatus
    }

    func queueLines(_ path: String? = nil) -> [String] {
        ((try? String(contentsOfFile: path ?? queue, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func append(_ lines: [String]) throws {
        try FileManager.default.createDirectory(
            atPath: (queue as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let handle = FileHandle(forWritingAtPath: queue) ?? {
            FileManager.default.createFile(atPath: queue, contents: nil)
            return FileHandle(forWritingAtPath: queue)!
        }()
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        try handle.close()
    }

    /// A queue line for a Codex prompt in session `session`, queued at `time`.
    static func line(session: String, time: Double) -> String {
        #"{"drip":1,"time":\#(Int(time)),"agent":"codex","machine":"devbox","env":{},"payload":{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)"}}"#
    }

    var positionPath: String { FollowPosition.path(target: "devbox", environment: environment) }

    /// Follows the fake machine until `count` events arrive, then returns the sessions of those young
    /// enough to show, of the stale ones, and the pauses before each reconnection. `handle` sees
    /// every event too.
    func follow(
        count: Int, ssh: String = "ssh", now: Date = Date(), handle: ((RemoteEvent, Bool) -> Void)? = nil,
        log: ((String) -> Void)? = nil, whileFollowing: (() throws -> Void)? = nil
    ) throws -> (sessions: [String], stale: [String], delays: [Double]) {
        var sessions: [String] = []
        var stale: [String] = []
        var delays: [Double] = []
        let settings = RemoteFollower.Settings(
            target: "devbox", queue: queue, ssh: ["\(root)/\(ssh)"], positionPath: positionPath)
        let follower = RemoteFollower(settings: settings, handle: { _, _ in }, log: { log?($0) })
        follower.now = { now }
        follower.sleep = { delays.append($0) }
        follower.handle = { event, tooOld in
            let payload = try? JSONValue(parsing: event.payload)
            let session = payload?["session_id"]?.string ?? "?"
            if tooOld { stale.append(session) } else { sessions.append(session) }
            handle?(event, tooOld)
            if sessions.count + stale.count >= count { follower.stop() }
        }
        // Never longer than this, whatever happens.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { follower.stop() }
        if let whileFollowing {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { try? whileFollowing() }
        }
        try follower.run()
        return (sessions, stale, delays)
    }

    @Test func theHookQueuesOneLinePerEvent() throws {
        let payload = """
            {"session_id":"s1","cwd":"/home/user/api",
             "hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make\\ntest"}}

            """
        #expect(try hook(["claude"], stdin: payload, environment: [
            "DRIP_HOOK": "attention", "HERDR_PANE_ID": "w1:p2", "HERDR_TAB_ID": "w1:t3;rm -rf", "HERDR_WORKSPACE_ID": "w1",
        ]) == 0)
        // Codex's notify passes its JSON as an argument.
        #expect(try hook(["codex", #"{"type":"agent-turn-complete","thread-id":"t1"}"#], environment: ["DRIP_MACHINE": "build box!"]) == 0)
        let lines = queueLines()
        #expect(lines.count == 2)
        let event = try RemoteEvent(line: lines[0])
        #expect(event.agent == .claude)
        #expect(event.machine == "devbox")
        #expect(abs(event.time - Date().timeIntervalSince1970) < 60)
        #expect(event.environment == [
            "DRIP_HOOK": "attention", "HERDR_PANE_ID": "w1:p2", "HERDR_TAB_ID": "w1:t3rm-rf", "HERDR_WORKSPACE_ID": "w1",
        ])
        let card = try AgentHook.event(agent: .claude, payload: event.payload)
        #expect(card.detail == "Claude wants to run make\ntest")
        let notify = try RemoteEvent(line: lines[1])
        #expect(notify.agent == .codex)
        #expect(notify.machine == "buildbox")
        #expect(try AgentHook.event(agent: .codex, payload: notify.payload).id == "codex:t1")
        // Nothing left behind but the queue and its lock.
        let left = try FileManager.default.contentsOfDirectory(atPath: (queue as NSString).deletingLastPathComponent)
        #expect(Set(left).isSubset(of: ["remote.jsonl", "remote.jsonl.lock"]))
    }

    @Test func theMachinesNameStartsWithALetterOrDigit() throws {
        // A name herdr would not take loses what comes before its first letter or digit.
        try hook(["gemini", #"{"hook_event_name":"AfterTool"}"#], environment: ["DRIP_MACHINE": "_-.dev"])
        try hook(["gemini", #"{"hook_event_name":"AfterTool"}"#], environment: ["DRIP_MACHINE": "..."])
        #expect(try queueLines().map { try RemoteEvent(line: $0).machine } == ["dev", "remote"])
    }

    @Test func theHookNeverFailsTheAgentsTurn() throws {
        #expect(try hook(["cursor"], stdin: "{}") == 0)
        #expect(try hook(["claude"], stdin: "") == 0)
        #expect(try hook([]) == 0)
        // A queue it cannot write: still 0, and nothing printed.
        try write(script: "blocked", "")
        #expect(try hook(["claude"], stdin: "{}", environment: ["DRIP_QUEUE": "\(root)/blocked/queue.jsonl"]) == 0)
        #expect(queueLines().isEmpty)
    }

    @Test func theHookMovesABigQueueAside() throws {
        try append([String(repeating: "x", count: RemoteHook.rotateSize)])
        try hook(["codex"], stdin: #"{"hook_event_name":"Stop","session_id":"s1"}"#)
        #expect(queueLines(queue + ".1").count == 1)
        #expect(queueLines().count == 1)
        #expect(try RemoteEvent(line: queueLines()[0]).agent == .codex)
    }

    @Test func aFirstFollowShowsOnlyWhatComesNext() throws {
        let now = Date()
        try append([Self.line(session: "before", time: now.timeIntervalSince1970)])
        let result = try follow(count: 1, now: now, whileFollowing: {
            try hook(["codex"], stdin: #"{"hook_event_name":"UserPromptSubmit","session_id":"after"}"#)
        })
        #expect(result.sessions == ["after"])
    }

    @Test func eventsTooOldWhenTheyArriveAreStale() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try append([
            Self.line(session: "old", time: 1_800_000_000 - FollowCommand.defaultMaxAge - 1),
            Self.line(session: "recent", time: 1_800_000_000 - FollowCommand.defaultMaxAge + 1),
            Self.line(session: "ahead", time: 1_800_000_100),
        ])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        let result = try follow(count: 3, now: now)
        #expect(result.sessions == ["recent", "ahead"])
        #expect(result.stale == ["old"])
    }

    @Test func aStaleAnswerStillTakesAwayTheCardItAnswers() throws {
        let now = Date()
        let mac = AgentHook.Surroundings(
            environment: environment, hasGUISession: true, isInstalled: { _ in false },
            front: { _ in WhenFocused.Front(app: false, pane: false) },
            resolver: { _, environment in CardResolver(config: Config(), environment: try EnvironmentSettings(environment: environment)) })
        var cards: [Card?] = []
        let show: (RemoteEvent, Bool) -> Void = { event, stale in
            cards.append(try? AgentHook.card(
                agent: event.agent, payload: event.payload,
                in: event.surroundings(mac, activate: nil, herdrMachine: nil, stale: stale)))
        }
        let ask = #"{"drip":1,"time":\#(Int(now.timeIntervalSince1970)),"agent":"claude","machine":"devbox","env":{},"payload":{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}}"#
        try append([ask])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        _ = try follow(count: 1, now: now, handle: show)
        #expect(cards.count == 1 && cards[0]?.waits == true)
        let agents = AgentState(environment: environment)
        #expect(agents.waiting(id: "claude:s1@devbox", now: now) != nil)

        // You answered on the machine while the Mac slept, longer than --max-age.
        let answered = now.timeIntervalSince1970 + 60
        let later = Date(timeIntervalSince1970: answered + FollowCommand.defaultMaxAge + 60)
        try append([#"{"drip":1,"time":\#(Int(answered)),"agent":"claude","machine":"devbox","env":{},"payload":{"session_id":"s1","hook_event_name":"UserPromptSubmit"}}"#])
        let result = try follow(count: 1, now: later, handle: show)
        #expect(result.stale == ["s1"])
        #expect(cards.count == 2 && cards[1] == nil)
        #expect(agents.waiting(id: "claude:s1@devbox", now: Date(timeIntervalSince1970: answered)) == nil)
        #expect(DismissRequests(environment: environment).load().dismisses(id: "claude:s1@devbox", since: now.timeIntervalSince1970 - 1))
    }

    @Test func aNewConnectionTakesUpAfterTheLastEventHandled() throws {
        let now = Date()
        try append([Self.line(session: "s1", time: now.timeIntervalSince1970)])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        try append([Self.line(session: "s2", time: now.timeIntervalSince1970)])
        #expect(try follow(count: 2, now: now).sessions == ["s1", "s2"])
        try append([Self.line(session: "s3", time: now.timeIntervalSince1970)])
        #expect(try follow(count: 1, now: now).sessions == ["s3"])
        // The queue moved aside while drip was away: the rest of it first, then the new one.
        try append([Self.line(session: "s4", time: now.timeIntervalSince1970)])
        try FileManager.default.moveItem(atPath: queue, toPath: queue + ".1")
        try append([Self.line(session: "s5", time: now.timeIntervalSince1970)])
        #expect(try follow(count: 2, now: now).sessions == ["s4", "s5"])
    }

    @Test func aBannerFromTheRemoteShellNeverMovesThePlace() throws {
        let now = Date()
        let line = Self.line(session: "s1", time: now.timeIntervalSince1970)
        try append([line])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        var logs: [String] = []
        #expect(try follow(count: 1, ssh: "banner-ssh", now: now, log: { logs.append($0) }).sessions == ["s1"])
        #expect(FollowPosition.load(from: positionPath) == FollowPosition(inode: try inode(queue), offset: line.utf8.count + 1))
        #expect(logs == ["ignored what devbox's shell printed: Welcome to devbox"])
        // The next connection takes up after the event, banner and all.
        try append([Self.line(session: "s2", time: now.timeIntervalSince1970)])
        #expect(try follow(count: 1, ssh: "banner-ssh", now: now).sessions == ["s2"])
    }

    @Test func aMissingQueueIsSaidOnceAndSoIsItsArrival() throws {
        var logs: [String] = []
        let result = try follow(count: 1, log: { logs.append($0) }) {
            try hook(["codex"], stdin: #"{"hook_event_name":"UserPromptSubmit","session_id":"first"}"#)
        }
        // A queue that comes after the first follow started is read from its start.
        #expect(result.sessions == ["first"])
        #expect(logs.count == 2)
        #expect(logs.first?.hasPrefix("devbox has no queue at \(queue) yet") == true)
        #expect(logs.last == "devbox has its queue now")
    }

    @Test func aDroppedConnectionReconnectsAfterAPause() throws {
        let now = Date()
        try append([Self.line(session: "s1", time: now.timeIntervalSince1970)])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        let result = try follow(count: 1, ssh: "flaky-ssh", now: now)
        #expect(result.sessions == ["s1"])
        #expect(result.delays == [RemoteFollower.delays[0]])
    }

    @Test func aPaneQueryThatHangsHoldsTheNextEventUpNoLongerThanItsDeadline() throws {
        let now = Date()
        try append([Self.line(session: "s1", time: now.timeIntervalSince1970), Self.line(session: "s2", time: now.timeIntervalSince1970)])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        // As herdr on the machine would, asked whether the first event's pane shows: it ignores
        // SIGTERM, and leaves a process holding its output open.
        var handled: [Date] = []
        let started = Date()
        let result = try follow(count: 2, now: now, handle: { _, _ in
            handled.append(Date())
            if handled.count == 1 {
                _ = TimedCommand.run(["sh", "-c", "trap '' TERM; sleep 30 & sleep 30"], timeout: 0.5)
            }
        })
        #expect(result.sessions == ["s1", "s2"])
        #expect(handled.count == 2)
        // The deadline and the grace, and a second to connect.
        #expect(handled.last.map { $0.timeIntervalSince(started) < 0.5 + TimedCommand.grace + 1 } == true)
    }

    @Test func oneFollowerPerMachine() throws {
        let now = Date()
        try append([Self.line(session: "s1", time: now.timeIntervalSince1970)])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        let settings = RemoteFollower.Settings(target: "devbox", queue: queue, ssh: ["\(root)/ssh"], positionPath: positionPath)
        // The first holds the lock once it hands on an event: it takes the lock before it connects.
        let following = DispatchSemaphore(value: 0)
        let first = RemoteFollower(settings: settings, handle: { _, _ in following.signal() }, log: { _ in })
        let second = RemoteFollower(settings: settings, handle: { _, _ in }, log: { _ in })
        // Never longer than this, whatever happens.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            first.stop()
            second.stop()
        }
        DispatchQueue.global().async { try? first.run() }
        #expect(following.wait(timeout: .now() + 20) == .success)
        #expect(throws: StateError.self) { try second.run(connections: 1) }
        first.stop()
    }

    func inode(_ path: String) throws -> String {
        var info = stat()
        guard stat(path, &info) == 0 else { throw StateError("cannot stat \(path)") }
        return "\(info.st_ino)"
    }
}

/// An event from another machine goes through the same rules as `drip hook` on this Mac.
struct RemoteDecisionTests {
    let state: String
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("drip-decide-\(UUID().uuidString)").path
    }

    /// What `drip hook` reads around an event on this Mac, with the terminal in front and you at it.
    func local(_ environment: [String: String] = [:], inFront: Bool = false) -> AgentHook.Surroundings {
        local(environment) { _ in WhenFocused.Front(app: inFront, pane: inFront, idle: 0) }
    }

    /// What `drip hook` reads around an event on this Mac, with the terminal where `front` says.
    func local(
        _ environment: [String: String] = [:], front: @escaping (Card) -> WhenFocused.Front,
        paneShowing: @escaping (Card) -> Bool? = { _ in nil },
        machineView: @escaping (Card) -> MachineView = { _ in .selected },
        resurface: @escaping (Card, Double) -> Void = { _, _ in }
    ) -> AgentHook.Surroundings {
        AgentHook.Surroundings(
            environment: [
                "XDG_STATE_HOME": state, "XDG_CONFIG_HOME": "\(state)/config", "HOME": state,
                "__CFBundleIdentifier": "com.apple.Terminal",
            ]
                .merging(environment) { $1 },
            hasGUISession: true, isInstalled: { _ in false },
            front: front, paneShowing: paneShowing, machineView: machineView, resurface: resurface,
            resolver: { _, environment in CardResolver(config: Config(), environment: try EnvironmentSettings(environment: environment)) },
            now: { now })
    }

    func remote(_ payload: String, environment: [String: String] = [:], time: Double? = nil) -> RemoteEvent {
        RemoteEvent(
            time: time ?? now.timeIntervalSince1970, agent: .claude, machine: "devbox", environment: environment,
            payload: payload)
    }

    func card(_ event: RemoteEvent, _ local: AgentHook.Surroundings, stale: Bool = false) throws -> Card? {
        try AgentHook.card(
            agent: event.agent, payload: event.payload,
            in: event.surroundings(local, activate: "com.mitchellh.ghostty", herdrMachine: "devbox", stale: stale))
    }

    static let stop = #"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"Stop","last_assistant_message":"Done."}"#
    static let permission = #"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#

    @Test func aRemoteCardIsTheLocalCardFromItsMachine() throws {
        let here = try #require(try AgentHook.card(agent: .claude, payload: Self.stop, in: local()))
        let there = try #require(try card(remote(Self.stop, environment: ["HERDR_TAB_ID": "w1:t2"]), local()))
        #expect(here.id == "claude:s1")
        #expect(there.id == "claude:s1@devbox")
        #expect(here.title == "api is done")
        #expect(there.title == "api on devbox is done")
        #expect(there.activate == "com.mitchellh.ghostty")
        #expect(there.pane == TerminalPane(herdrTab: "w1:t2", herdrMachine: "devbox", hostName: "devbox"))
        var same = there
        same.id = here.id
        same.title = here.title
        same.activate = here.activate
        same.pane = here.pane
        #expect(same == here)
    }

    @Test func theSessionsDripHookDecides() throws {
        #expect(try card(remote(Self.stop, environment: ["DRIP_HOOK": "off"]), local()) == nil)
        #expect(try card(remote(Self.stop, environment: ["DRIP_HOOK": "attention"]), local()) == nil)
        #expect(try card(remote(Self.permission, environment: ["DRIP_HOOK": "attention"]), local()) != nil)
        // claude -p on the machine: nobody attends it.
        #expect(try card(remote(Self.stop, environment: ["CLAUDE_CODE_SESSION_ATTENDED": "0"]), local()) == nil)
        // This Mac's own DRIP_HOOK is about the session follow runs in, not the machine's.
        #expect(try card(remote(Self.stop), local(["DRIP_HOOK": "off"])) != nil)
        #expect(throws: UsageError.self) { try card(remote(Self.stop, environment: ["DRIP_HOOK": "maybe"]), local()) }
    }

    /// Which cards show under `agent_cards = "attention"` does not depend on the event naming a session.
    @Test(arguments: [
        (#"{"cwd":"/home/user/api","hook_event_name":"Stop"}"#, false),
        (#"{"session_id":"","cwd":"/home/user/api","hook_event_name":"Stop"}"#, false),
        (#"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"Stop"}"#, false),
        (#"{"cwd":"/home/user/api","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#, true),
        (#"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#, true),
        (#"{"cwd":"/home/user/api","hook_event_name":"StopFailure","error":"rate_limit"}"#, true),
        (#"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"StopFailure","error":"rate_limit"}"#, true),
    ] as [(String, Bool)], [true, false])
    func attentionFiltersDoneCardsWhetherOrNotTheEventNamesASession(
        _ case: (payload: String, shows: Bool), viaConfig: Bool
    ) throws {
        var surroundings = local(viaConfig ? [:] : ["DRIP_AGENT_CARDS": "attention"])
        if viaConfig {
            surroundings.resolver = { _, environment in CardResolver(config: Config(agentCards: .attention), environment: try EnvironmentSettings(environment: environment)) }
        }
        let direct = try AgentHook.card(agent: .claude, payload: `case`.payload, in: surroundings)
        let viaRemote = try card(remote(`case`.payload), surroundings)
        #expect((direct != nil) == `case`.shows, "\(`case`.payload)")
        #expect((viaRemote != nil) == `case`.shows, "remote \(`case`.payload)")
        // The default shows every card, with or without a session.
        #expect(try AgentHook.card(agent: .claude, payload: `case`.payload, in: local()) != nil)
    }

    /// Without a session id there is no turn start to count `done_after` from: the done card shows.
    @Test func aSessionlessDoneCardIsNotHeldBackByDoneAfter() throws {
        var surroundings = local()
        surroundings.resolver = { _, environment in CardResolver(config: Config(doneAfter: 30), environment: try EnvironmentSettings(environment: environment)) }
        #expect(try AgentHook.card(agent: .claude, payload: #"{"cwd":"/home/user/api","hook_event_name":"Stop"}"#, in: surroundings) != nil)
    }

    @Test func theConfigOnThisMacDecides() throws {
        #expect(try card(remote(Self.stop), local(["DRIP_AGENT_CARDS": "attention"])) == nil)
        #expect(try card(remote(Self.permission), local(["DRIP_AGENT_CARDS": "attention"])) != nil)
        // done_after counts from the prompt the machine reported.
        let prompt = #"{"session_id":"s1","hook_event_name":"UserPromptSubmit"}"#
        #expect(try card(remote(prompt), local()) == nil)
        #expect(try card(remote(Self.stop), local(["DRIP_DONE_AFTER": "30"])) == nil)
    }

    @Test func aRemoteCardFollowsWhenFocusedOnItsMachinesWord() throws {
        let herdr = ["HERDR_PANE_ID": "w1:p2", "HERDR_TAB_ID": "w1:t2", "HERDR_WORKSPACE_ID": "w1"]
        let asked = Asked()
        /// The terminal in front, or not, and you at it `idle` seconds ago, with the agent's pane in
        /// front on the machine as its herdr says, which is nil when it does not answer in time.
        func there(_ environment: [String: String], pane: Bool?, app: Bool = true, idle: Double = 0) throws -> Card? {
            try card(remote(Self.stop, environment: herdr), local(environment) { _ in
                WhenFocused.Front(app: app, idle: idle)
            } paneShowing: { card in
                asked.panes.append(card.pane)
                return pane
            })
        }
        let skip = ["DRIP_WHEN_FOCUSED": "skip"]
        // The agent's pane in front on the machine: no card, as for a pane here.
        #expect(try there(skip, pane: true) == nil)
        #expect(asked.panes.last == TerminalPane(
            herdrPane: "w1:p2", herdrTab: "w1:t2", herdrWorkspace: "w1", herdrMachine: "devbox", hostName: "devbox"))
        #expect(try there([:], pane: true)?.sound == Sound.none)
        // You were away longer than away_after: it shows, with its sound.
        #expect(try there(skip, pane: true, idle: 120)?.sound != Sound.none)
        #expect(try there(skip.merging(["DRIP_AWAY_AFTER": "300"]) { $1 }, pane: true, idle: 120) == nil)
        // Another pane in front there, or no answer in time: it shows, with its sound.
        #expect(try there(skip, pane: false)?.sound != Sound.none)
        #expect(try there(skip, pane: nil)?.sound != Sound.none)
        #expect(try there([:], pane: nil)?.sound != Sound.none)
        // With show, with the terminal not in front here, or with you away, drip never asks the machine.
        let count = asked.panes.count
        #expect(try there(["DRIP_WHEN_FOCUSED": "show"], pane: true)?.sound != Sound.none)
        #expect(try there(skip, pane: true, app: false)?.sound != Sound.none)
        #expect(try there(skip, pane: true, idle: 120)?.sound != Sound.none)
        #expect(asked.panes.count == count)
    }

    @Test func aRemoteCardIsOnlySkippedWhileThisMacsHerdrShowsItsMachine() throws {
        let herdr = ["HERDR_PANE_ID": "w1:p2", "HERDR_TAB_ID": "w1:t2", "HERDR_WORKSPACE_ID": "w1"]
        let skip = ["DRIP_WHEN_FOCUSED": "skip", "DRIP_DEBUG": "1"]
        func there(_ view: MachineView) throws -> Card? {
            try card(remote(Self.stop, environment: herdr), local(skip) { _ in
                WhenFocused.Front(app: true, idle: 0)
            } paneShowing: { _ in true } machineView: { _ in view })
        }
        // The pane shows on the machine and so does this Mac's herdr window: no card.
        #expect(try there(.selected) == nil)
        // The window shows Local, though the machine's pane is the one in front there: the card shows.
        #expect(try there(.notSelected)?.sound != Sound.none)
        // herdr cannot say: the card shows, and the log says why.
        #expect(try there(.unknown("no answer within 3s"))?.sound != Sound.none)
        let log = (try? String(contentsOfFile: "\(state)/drip/debug.log", encoding: .utf8)) ?? ""
        #expect(log.contains("machine_selected=false"))
        #expect(log.contains("machine_selected=\"unknown: no answer within 3s\"") || log.contains("machine_selected=unknown:"))
    }

    @Test func aMachineListNamesWhichSavedMachineTheWindowShows() {
        func view(_ selected: String) -> MachineView {
            MachineView(
                machineList: #"[{"id":"a","label":"devbox","target":"dev","session":"default","enabled":true,\#(selected)}]"#,
                machine: "devbox")
        }
        #expect(view(#""selected":true"#) == .selected)
        #expect(view(#""selected":false"#) == .notSelected)
        #expect(view(#""other":1"#) == .unknown("no selected field"))
        #expect(MachineView(machineList: "[]", machine: "devbox") == .unknown("machine not in list"))
        #expect(MachineView(machineList: "not json", machine: "devbox") == .unknown("unreadable machine list"))
    }

    @Test func aWaitingCardSkippedWhileWatchingComesBackIfTheAgentStillWaits() throws {
        let skip = ["DRIP_WHEN_FOCUSED": "skip"]
        var asked: [(Card, Double)] = []
        let watching = local(skip, front: { _ in WhenFocused.Front(app: true, pane: true, idle: 0) }, resurface: { asked.append(($0, $1)) })
        #expect(try AgentHook.card(agent: .claude, payload: Self.permission, in: watching) == nil)
        let (card, noted) = try #require(asked.first)
        #expect(asked.count == 1 && card.waits && card.id == "claude:s1")
        func again(_ front: WhenFocused.Front) throws -> Card? {
            try AgentHook.resurfaced(card, agent: .claude, noted: noted, in: local(skip, front: { _ in front }))
        }
        // Still watching: nothing, and no third look.
        let stillWatching = local(skip, front: { _ in WhenFocused.Front(app: true, pane: true, idle: 0) }, resurface: { asked.append(($0, $1)) })
        #expect(try AgentHook.resurfaced(card, agent: .claude, noted: noted, in: stillWatching) == nil)
        #expect(asked.count == 1)
        // Looked away, or the terminal left: it shows, with its sound.
        #expect(try again(WhenFocused.Front(app: false, idle: 0)) == card)
        #expect(try again(WhenFocused.Front(app: true, pane: false, idle: 0)) == card)
        #expect(try again(WhenFocused.Front(app: true, pane: true, idle: 600)) == card)
        // A later event for the session took the waiting card away: it never returns.
        let ran = #"{"session_id":"s1","hook_event_name":"UserPromptSubmit"}"#
        #expect(try AgentHook.card(agent: .claude, payload: ran, in: watching) == nil)
        #expect(try again(WhenFocused.Front(app: false, idle: 0)) == nil)
    }

    @Test func aNewerWaitingCardIsNotReplacedByTheOlderOne() throws {
        let skip = ["DRIP_WHEN_FOCUSED": "skip"]
        var asked: [(Card, Double)] = []
        let watching = local(skip, front: { _ in WhenFocused.Front(app: true, pane: true, idle: 0) }, resurface: { asked.append(($0, $1)) })
        #expect(try AgentHook.card(agent: .claude, payload: Self.permission, in: watching) == nil)
        let older = try #require(asked.first)
        var later = watching
        later.now = { self.now.addingTimeInterval(5) }
        #expect(try AgentHook.card(agent: .claude, payload: Self.permission, in: later) == nil)
        // The agent asked again since: the first look finds a different waiting record.
        let away = local(skip) { _ in WhenFocused.Front(app: false, idle: 0) }
        #expect(try AgentHook.resurfaced(older.0, agent: .claude, noted: older.1, in: away) == nil)
        #expect(try AgentHook.resurfaced(asked[1].0, agent: .claude, noted: asked[1].1, in: away) == asked[1].0)
    }

    /// The panes drip asked about, in order.
    final class Asked {
        var panes: [TerminalPane?] = []
    }

    @Test func answeringOnTheMachineTakesAwayOnlyItsCard() throws {
        let surroundings = local()
        #expect(try card(remote(Self.permission), surroundings)?.waits == true)
        #expect(try AgentHook.card(agent: .claude, payload: Self.permission, in: surroundings)?.waits == true)
        let ran = #"{"session_id":"s1","hook_event_name":"UserPromptSubmit"}"#
        #expect(try card(remote(ran), surroundings) == nil)
        let agents = AgentState(environment: surroundings.environment)
        #expect(agents.waiting(id: "claude:s1@devbox", now: now) == nil)
        #expect(agents.waiting(id: "claude:s1", now: now) != nil)
    }

    @Test func aStaleEventShowsNoCardButTakesAwayTheOneItReplaces() throws {
        let surroundings = local()
        #expect(try card(remote(Self.permission), surroundings)?.waits == true)
        #expect(try card(remote(Self.stop), surroundings, stale: true) == nil)
        let agents = AgentState(environment: surroundings.environment)
        #expect(agents.waiting(id: "claude:s1@devbox", now: now) == nil)
        #expect(DismissRequests(environment: surroundings.environment).load()
            .dismisses(id: "claude:s1@devbox", since: Date().timeIntervalSince1970 - 60))
        // A stale clear does what a fresh one does.
        #expect(try card(remote(Self.permission), surroundings)?.waits == true)
        let answered = #"{"session_id":"s1","hook_event_name":"UserPromptSubmit"}"#
        #expect(try card(remote(answered), surroundings, stale: true) == nil)
        #expect(agents.waiting(id: "claude:s1@devbox", now: now) == nil)
    }

    @Test func aTurnIsTimedByWhenItsEventsHappened() throws {
        // A turn of 3 minutes, heard in one burst after a reconnection.
        let prompt = #"{"session_id":"s1","hook_event_name":"UserPromptSubmit"}"#
        let surroundings = local(["DRIP_DONE_AFTER": "60"])
        #expect(try card(remote(prompt, time: now.timeIntervalSince1970 - 200), surroundings) == nil)
        let agents = AgentState(environment: surroundings.environment)
        #expect(agents.turnStarted(id: "claude:s1@devbox", now: now) == now.timeIntervalSince1970 - 200)
        #expect(try card(remote(Self.stop, time: now.timeIntervalSince1970 - 20), surroundings)?.title == "api on devbox is done")
        // A machine whose clock is ahead: never later than now here.
        #expect(try card(remote(prompt, time: now.timeIntervalSince1970 + 600), surroundings) == nil)
        #expect(agents.turnStarted(id: "claude:s1@devbox", now: now) == now.timeIntervalSince1970)
    }

    @Test func foldersOfOneNameReadApartPerMachine() throws {
        let other = #"{"session_id":"s2","cwd":"/srv/api","hook_event_name":"Stop"}"#
        _ = try card(remote(Self.stop), local())
        #expect(try card(remote(other), local())?.title == "srv/api on devbox is done")
        // A folder of the same name on this Mac is not one of them.
        let here = #"{"session_id":"s3","cwd":"/Users/me/api","hook_event_name":"Stop"}"#
        #expect(try AgentHook.card(agent: .claude, payload: here, in: local())?.title == "api is done")
    }
}

struct FollowAgentTests {
    @Test func theLaunchdAgentRunsFollowAndKeepsItRunning() throws {
        let plist = FollowAgent.plist(
            command: ["/opt/homebrew/bin/drip", "follow", "me@devbox", "--activate", "com.apple.Terminal"],
            target: "me@devbox", environment: [
                "HOME": "/Users/me", "PATH": "/opt/homebrew/bin:/usr/bin:/opt/homebrew/bin", "DRIP_SOUND": "none",
                "DRIP_AGENT_CARDS": "attention", "DRIP_HOOK": "off", "XDG_CONFIG_HOME": "/Users/me/.dotfiles/config",
                "XDG_STATE_HOME": "/Users/me/.state", "SHELL": "/bin/zsh", "DRIP_SECONDS": "",
            ])
        let agent = try #require(
            try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any])
        #expect(FollowAgent.label(target: "me@devbox") == "co.jrnxf.drip.follow.me-devbox")
        #expect(agent["Label"] as? String == "co.jrnxf.drip.follow.me-devbox")
        #expect(agent["ProgramArguments"] as? [String] == [
            "/opt/homebrew/bin/drip", "follow", "me@devbox", "--activate", "com.apple.Terminal",
        ])
        // drip's settings and where its config and state are, but not one session's DRIP_HOOK.
        #expect(agent["EnvironmentVariables"] as? [String: String] == [
            "PATH": "/opt/homebrew/bin:/usr/bin", "DRIP_SOUND": "none", "DRIP_AGENT_CARDS": "attention",
            "XDG_CONFIG_HOME": "/Users/me/.dotfiles/config", "XDG_STATE_HOME": "/Users/me/.state",
        ])
        #expect(agent["StandardErrorPath"] as? String == "/Users/me/Library/Logs/co.jrnxf.drip.follow.me-devbox.log")
        #expect(agent["KeepAlive"] as? Bool == true)
        #expect(agent["RunAtLoad"] as? Bool == true)
    }
}
#endif
