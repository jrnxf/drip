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
        {"drip":1,"time":1800000000,"agent":"claude","machine":"devbox","env":{"DRIP_HOOK":"attention","CLAUDE_CODE_SESSION_ATTENDED":"","CLAUDE_CODE_ENTRYPOINT":"cli","HERDR_PANE_ID":"w1:p2","OTHER":"x"},"forward":{"HERDR_PANE_ID":"w1:p2","WEZTERM_PANE":"7"},"payload":{"session_id":"s1","cwd":"/home/user/api", "hook_event_name":"Stop","last_assistant_message":"Done."} }
        """#

    @Test func aQueueLineIsAnEvent() throws {
        let event = try RemoteEvent(line: Self.line)
        #expect(event.time == 1_800_000_000)
        #expect(event.agent == .claude)
        #expect(event.machine == "devbox")
        // Empty values and variables the hook does not pass are left out.
        #expect(event.environment == ["DRIP_HOOK": "attention", "CLAUDE_CODE_ENTRYPOINT": "cli"])
        // What DRIP_FORWARD_ENV named there is kept apart, for a click command only.
        #expect(event.forwarded == ["HERDR_PANE_ID": "w1:p2", "WEZTERM_PANE": "7"])
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

    @Test func aClickRunsOnlyFollowsCommandWithTheMachineAndWhatItForwarded() throws {
        let event = try RemoteEvent(line: Self.line)
        let origin = event.origin(activate: "com.mitchellh.ghostty", onClick: "my-focus")
        #expect(origin.machine == "devbox")
        #expect(origin.activate == "com.mitchellh.ghostty")
        #expect(origin.click == OnClick(
            command: "my-focus", machine: "devbox", environment: ["HERDR_PANE_ID": "w1:p2", "WEZTERM_PANE": "7"]))
        #expect(origin.qualified("claude:s1") == "claude:s1@devbox")
        // Without drip follow --on-click, a click runs nothing.
        #expect(event.origin(activate: nil, onClick: nil).click == nil)
    }

    @Test func aQueuedEventCannotSetWhatAClickRuns() throws {
        // A queue line can hold anything: a command, a path to open, a pane, an app to bring forward.
        let line = #"""
            {"drip":1,"time":1800000000,"agent":"claude","machine":"devbox","on_click":"rm -rf ~","onClick":{"command":"rm -rf ~"},"command":"touch /tmp/owned","open":"/Applications/Calculator.app","activate":"com.apple.Terminal","pane":"%1","env":{"DRIP_HOOK":"attention","TMUX":"/tmp/t,1,0","TMUX_PANE":"%1","__CFBundleIdentifier":"com.apple.Terminal","DRIP_FORWARD_ENV":"HOME","DRIP_ACTIVATE":"com.apple.Terminal"},"forward":{"bad name":"x","OK":"line\nbreak","LONG":"\#(String(repeating: "x", count: 300))","FINE":"w1:p2"},"payload":{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"Stop","last_assistant_message":"Done."}}
            """#
        let event = try RemoteEvent(line: line)
        // None of the Mac's own variables come from the queue: no pane, no app, no forwarding.
        #expect(event.environment == ["DRIP_HOOK": "attention"])
        // Forwarded values are data: bad names, control characters and long values are left out.
        #expect(event.forwarded == ["FINE": "w1:p2"])
        #expect(event.origin(activate: nil, onClick: nil).click == nil)
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
        #expect(lines.map(\.0) == [.hello(time: nil), .file(FollowPosition(inode: "42", offset: 100))])
        // Half a line waits for the rest.
        lines = stream.read(Array(line.utf8.dropFirst(10)) + Array("#\n=not json\n#missing /home/user/q.jsonl\n".utf8))
        #expect(lines.count == 4)
        guard case .event(.success)? = lines.first?.0 else { Issue.record("\(lines)"); return }
        // The place moves by the queue's own line, not the `=` before it.
        #expect(lines[0].1 == FollowPosition(inode: "42", offset: 100 + line.utf8.count))
        #expect(lines[1].0 == .heartbeat(time: nil))
        // A line that is no event still moves the place past it.
        #expect(lines[2].0 == .event(.failure(UsageError("not a JSON object"))))
        #expect(lines[3].0 == .missing("/home/user/q.jsonl"))
        #expect(stream.position == FollowPosition(inode: "42", offset: 100 + line.utf8.count + 9))
    }

    @Test func theReaderSaysItsClockWithHelloAndHeartbeat() {
        var stream = FollowReader.Stream(position: nil)
        let lines = stream.read(Array("#drip-follow 2 1800000000\n#\n# 1800000015\n# soon\n#drip-follow 2 soon\n".utf8))
        // A line without a time, or with something else for one, says nothing of the clock.
        #expect(lines.map(\.0) == [
            .hello(time: 1_800_000_000), .heartbeat(time: nil), .heartbeat(time: 1_800_000_015), .heartbeat(time: nil),
            .noise("#drip-follow 2 soon"),
        ])
        var older = FollowReader.Stream(position: nil)
        #expect(older.read(Array("#drip-follow 2 soon\n".utf8)).map(\.0) == [.hello(time: nil)])
    }

    @Test func thePlaceKeepsTheFilesFirstLineWithItsInode() throws {
        var stream = FollowReader.Stream(position: nil)
        let lines = stream.read(Array("#drip-follow 2\n#file 42 100 3245-210\n#file 43 0\n#file 44 0 x1\n#file 45 0 1-2 3\n".utf8))
        #expect(lines.map(\.0) == [
            .hello(time: nil), .file(FollowPosition(inode: "42", offset: 100, id: "3245-210")),
            .file(FollowPosition(inode: "43", offset: 0)), .noise("#file 44 0 x1"), .noise("#file 45 0 1-2 3"),
        ])
        #expect(stream.position == FollowPosition(inode: "43", offset: 0))
        // A position kept by a drip that did not know the id still reads, and has none.
        let old = try JSONDecoder().decode(FollowPosition.self, from: Data(#"{"inode":"42","offset":7}"#.utf8))
        #expect(old == FollowPosition(inode: "42", offset: 7, id: nil))
    }

    @Test func whatTheRemoteShellPrintsNeverMovesThePlace() throws {
        var stream = FollowReader.Stream(position: FollowPosition(inode: "42", offset: 0))
        // A banner from the shell's startup files, before the reader starts, even one that looks
        // like the reader's own lines; then stray output while it runs.
        let lines = stream.read(Array("Welcome to devbox\n#file 7 900\n=\(Self.line)\n#drip-follow 2\nstray output\n#later\n".utf8))
        #expect(lines.map(\.0) == [
            .noise("Welcome to devbox"), .noise("#file 7 900"), .noise("=\(Self.line)"), .hello(time: nil), .noise("stray output"),
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

    @Test func remoteHookPrintsTheRemoteHook() throws {
        guard case .invocation(.remoteHook) = CommandLineParser.parse(["remote-hook"]) else {
            Issue.record(); return
        }
        // The hook script takes the flags a recipe writes after the agent.
        #expect(RemoteHook.script.contains("--min-turn"))
        #expect(!RemoteHook.script.contains("drip setup"))
        // No options: the hooks come from a recipe, written by hand.
        for arguments in [["remote-hook", "s.json"], ["remote-hook", "--remote"]] {
            guard case let .exit(status, _) = CommandLineParser.parse(arguments) else { Issue.record("\(arguments)"); continue }
            #expect(status == ExitStatus.usage, "\(arguments)")
        }
    }

    @Test func followTakesTheMachineAndItsOptions() throws {
        guard case let .invocation(.follow(plain)) = CommandLineParser.parse(["follow", "me@devbox"]) else {
            Issue.record(); return
        }
        #expect(plain.target == "me@devbox")
        #expect(plain.maxAge == FollowCommand.defaultMaxAge)
        #expect(plain.onClick == nil)
        #expect(plain.queue == nil)
        guard case let .invocation(.follow(full)) = CommandLineParser.parse([
            "follow", "devbox", "--max-age", "1h", "--on-click", "my-focus --pane", "--activate", "com.apple.Terminal",
            "--queue", "/srv/queue.jsonl",
        ]) else { Issue.record(); return }
        #expect(full.maxAge == 3600)
        #expect(full.onClick == "my-focus --pane")
        #expect(full.activate == "com.apple.Terminal")
        #expect(full.queue == "/srv/queue.jsonl")
        for arguments in [
            ["follow"], ["follow", "-oProxyCommand=x"], ["follow", "dev box"], ["follow", "devbox", "--max-age", "soon"],
            ["follow", "devbox", "--on-click", ""], ["follow", "devbox", "--activate", "not an app"],
            // Gone: a click command does what it did.
            ["follow", "devbox", "--herdr-machine", "devbox"],
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
        // The remote machine's clock: what `date +%s` prints there is whatever `remote-now` holds.
        try FileManager.default.createDirectory(atPath: "\(root)/clock", withIntermediateDirectories: true)
        try write(script: "clock/date", """
            #!/bin/sh
            # The reader asks once, as it starts: that it is up is noted.
            if [ "$1" = "+%s" ]; then : >"\(root)/reader-up"; fi
            if [ "$1" = "+%s" ] && [ -s "\(root)/remote-now" ]; then cat "\(root)/remote-now"; else exec /bin/date "$@"; fi
            """)
        // ssh's options, then `--`, the target, and the command, which runs here, on that clock.
        try write(script: "ssh", """
            #!/bin/sh
            while [ "$1" != "--" ]; do shift; done
            shift 2
            PATH="\(root)/clock:$PATH"
            export PATH
            exec "$@"
            """)
        // The tools the hook runs and no flock, as on macOS and with busybox.
        try FileManager.default.createDirectory(atPath: "\(root)/noflock", withIntermediateDirectories: true)
        for tool in ["dirname", "mkdir", "mktemp", "wc", "tr", "sed", "cut", "uname", "date", "ls", "cat", "mv", "rm", "sleep", "kill"] {
            guard let path = ["/usr/bin", "/bin"].map({ "\($0)/\(tool)" }).first(where: FileManager.default.isExecutableFile) else {
                continue
            }
            try FileManager.default.createSymbolicLink(atPath: "\(root)/noflock/\(tool)", withDestinationPath: path)
        }
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

    /// The PATH of a machine with no flock.
    var noFlock: [String: String] { ["PATH": "\(root)/noflock"] }

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
        count: Int, ssh: String = "ssh", now: Date = Date(), remoteNow: String? = nil,
        handle: ((RemoteEvent, Bool) -> Void)? = nil, log: ((String) -> Void)? = nil,
        whileFollowing: (() throws -> Void)? = nil
    ) throws -> (sessions: [String], stale: [String], delays: [Double]) {
        // The machine's clock is this Mac's, unless the test says otherwise.
        try (remoteNow ?? String(Int(now.timeIntervalSince1970))).write(toFile: "\(root)/remote-now", atomically: false, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: "\(root)/reader-up")
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
            // Once the reader is up and has looked at the queue, however long a busy machine takes.
            DispatchQueue.global().async {
                let deadline = Date().addingTimeInterval(15)
                while !FileManager.default.fileExists(atPath: "\(root)/reader-up"), Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                Thread.sleep(forTimeInterval: 1.5)
                try? whileFollowing()
            }
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
            "DRIP_HOOK": "attention", "HERDR_PANE_ID": "w1:p2", "HERDR_TAB_ID": "w1:t3;rm -rf", "EMPTY": "",
            "DRIP_FORWARD_ENV": "HERDR_PANE_ID HERDR_TAB_ID EMPTY UNSET 1BAD $(id) HERDR_PANE_ID",
        ]) == 0)
        // Codex's notify passes its JSON as an argument.
        #expect(try hook(["codex", #"{"type":"agent-turn-complete","thread-id":"t1"}"#], environment: ["DRIP_MACHINE": "build box!"]) == 0)
        let lines = queueLines()
        #expect(lines.count == 2)
        let event = try RemoteEvent(line: lines[0])
        #expect(event.agent == .claude)
        #expect(event.machine == "devbox")
        #expect(abs(event.time - Date().timeIntervalSince1970) < 60)
        #expect(event.environment == ["DRIP_HOOK": "attention"])
        // Only what DRIP_FORWARD_ENV names is forwarded, with names checked and values cleaned.
        #expect(event.forwarded == ["HERDR_PANE_ID": "w1:p2", "HERDR_TAB_ID": "w1:t3rm-rf"])
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

    /// `--min-turn` and `--only` ride the queue line for `drip follow` to apply. `--approve` does not,
    /// and a word the hook does not know is not taken for the payload.
    @Test func theHookQueuesItsFlagsAsAFilter() throws {
        let stop = #"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"Stop"}"#
        try hook(["claude", "--min-turn", "30", "--only", "needs-you", "--approve"], stdin: stop)
        try hook(["claude", "--approve", "--min-turn", "7.5"], stdin: stop)
        // The flags may follow the payload argument too, as Codex's notify passes it first.
        try hook(["codex", "--only", "needs-you", #"{"type":"agent-turn-complete","thread-id":"t1"}"#])
        // Values that are not numbers or not known are left out, not queued as they are.
        try hook(["claude", "--min-turn", "$(id)", "--only", "everything"], stdin: stop)
        try hook(["claude"], stdin: stop)
        let events = try queueLines().map { try RemoteEvent(line: $0) }
        #expect(events.map(\.policy) == [
            AgentHook.Policy(minTurn: 30, only: .needsYou), AgentHook.Policy(minTurn: 7.5),
            AgentHook.Policy(only: .needsYou), AgentHook.Policy(), AgentHook.Policy(),
        ])
        #expect(try events.map { try AgentHook.event(agent: $0.agent, payload: $0.payload).id }
            == ["claude:s1", "claude:s1", "codex:t1", "claude:s1", "claude:s1"])
        #expect(!queueLines().joined().contains("approve"))
    }

    @Test func theMachinesNameStartsWithALetterOrDigit() throws {
        // A name loses what comes before its first letter or digit.
        try hook(["gemini", #"{"hook_event_name":"AfterTool"}"#], environment: ["DRIP_MACHINE": "_-.dev"])
        try hook(["gemini", #"{"hook_event_name":"AfterTool"}"#], environment: ["DRIP_MACHINE": "..."])
        #expect(try queueLines().map { try RemoteEvent(line: $0).machine } == ["dev", "remote"])
    }

    @Test func theHookNeverFailsTheAgentsTurn() throws {
        // More than a pipe holds: the agent's write ends only once the hook has read all of it, and
        // fails with a broken pipe if the hook ends first.
        let big = #"{"hook_event_name":"Stop","filler":""# + String(repeating: "x", count: 1024 * 1024) + #""}"#
        #expect(try hook(["cursor"], stdin: "{}") == 0)
        #expect(try hook(["cursor"], stdin: big) == 0)
        #expect(try hook(["claude"], stdin: "") == 0)
        #expect(try hook([]) == 0)
        #expect(try hook([], stdin: big) == 0)
        // A queue it cannot write: still 0, and nothing printed.
        try write(script: "blocked", "")
        #expect(try hook(["claude"], stdin: "{}", environment: ["DRIP_QUEUE": "\(root)/blocked/queue.jsonl"]) == 0)
        #expect(try hook(["claude"], stdin: big, environment: ["DRIP_QUEUE": "\(root)/blocked/queue.jsonl"]) == 0)
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
                in: event.surroundings(mac, activate: nil, onClick: nil, stale: stale)))
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
        // The place is kept with the first line's fingerprint, which the reader learned on the way.
        let place = try #require(FollowPosition.load(from: positionPath))
        #expect(place.inode == (try inode(queue)) && place.offset == line.utf8.count + 1 && place.id != nil)
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

    @Test func aConnectionThatGoesSilentIsDroppedAndReconnected() throws {
        // A half-open ssh: the reader said hello and then nothing. It closes the pipe only well past
        // the limit, so a follower without the silence check ends each connection at that close,
        // never saying it was silent; it does not rely on being killed, which may take until SIGKILL.
        try write(script: "silent-ssh", """
            #!/bin/sh
            echo "#drip-follow 2"
            exec sleep 3
            """)
        let settings = RemoteFollower.Settings(
            target: "devbox", queue: queue, ssh: ["\(root)/silent-ssh"], positionPath: positionPath, silenceLimit: 0.5)
        var logs: [String] = []
        var delays: [Double] = []
        let follower = RemoteFollower(settings: settings, handle: { _, _ in }, log: { logs.append($0) })
        follower.sleep = { delays.append($0) }
        try follower.run(connections: 2)
        #expect(logs.filter { $0.hasPrefix("devbox said nothing for") }.count == 2)
        #expect(delays == [RemoteFollower.delays[0]])
    }

    @Test func aConnectionThatLastedPastSteadyAfterStartsTheBackoffOver() throws {
        try write(script: "hello-ssh", """
            #!/bin/sh
            echo "#drip-follow 2"
            """)
        let settings = RemoteFollower.Settings(
            target: "devbox", queue: queue, ssh: ["\(root)/hello-ssh"], positionPath: positionPath)
        var jumped = 0.0
        var delays: [Double] = []
        let follower = RemoteFollower(settings: settings, handle: { _, _ in }, log: { line in
            // The third connection comes up, and then a steady half minute passes on this Mac's clock.
            if line == "following devbox again", delays.count == 2 { jumped = RemoteFollower.steadyAfter + 1 }
        })
        follower.now = { Date().addingTimeInterval(jumped) }
        follower.sleep = { delays.append($0) }
        try follower.run(connections: 4)
        // Two short connections lengthen the pause; the long one is forgiven.
        #expect(delays == [1, 2, 1])
    }

    @Test func aPaneQueryThatHangsHoldsTheNextEventUpNoLongerThanItsDeadline() throws {
        let now = Date()
        try append([Self.line(session: "s1", time: now.timeIntervalSince1970), Self.line(session: "s2", time: now.timeIntervalSince1970)])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        // As a slow command run for the first event would: it ignores
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
        // The deadline and the grace, and time to connect while the other suites run, well
        // short of the 30 seconds the command would hold it up.
        #expect(handled.last.map { $0.timeIntervalSince(started) < 0.5 + TimedCommand.grace + 3 } == true)
    }

    @Test func aClockBehindThisMacsAgesEventsByItsOwnTime() throws {
        // The machine's clock is 2 hours behind this Mac's: its events are still the age it says.
        let remote = 1_800_000_000.0
        let now = Date(timeIntervalSince1970: remote + 7200)
        try append([
            Self.line(session: "old", time: remote - FollowCommand.defaultMaxAge - 1),
            Self.line(session: "recent", time: remote - FollowCommand.defaultMaxAge + 1),
            Self.line(session: "ahead", time: remote + 100),
        ])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        var logs: [String] = []
        var times: [String: Double] = [:]
        let result = try follow(count: 3, now: now, remoteNow: String(Int(remote)), handle: { event, _ in
            times[(try? JSONValue(parsing: event.payload))?["session_id"]?.string ?? "?"] = event.time
        }, log: { logs.append($0) })
        #expect(result.sessions == ["recent", "ahead"])
        #expect(result.stale == ["old"])
        // Handed on at the time it happened on this Mac's clock.
        #expect(times["recent"] == remote - FollowCommand.defaultMaxAge + 1 + 7200)
        #expect(logs.first == "devbox's clock is 2h behind this Mac's: its events are aged by its own clock")
    }

    @Test func aClockAheadOfThisMacsDoesNotHideStaleEvents() throws {
        // 1 hour ahead: an event 6 minutes old reads as 54 minutes in the future by the Mac's clock.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let remote = now.timeIntervalSince1970 + 3600
        try append([
            Self.line(session: "old", time: remote - 360),
            Self.line(session: "recent", time: remote - 240),
        ])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        var logs: [String] = []
        let result = try follow(count: 2, now: now, remoteNow: String(Int(remote)), log: { logs.append($0) })
        #expect(result.sessions == ["recent"])
        #expect(result.stale == ["old"])
        #expect(logs.first == "devbox's clock is 1h ahead of this Mac's: its events are aged by its own clock")
    }

    @Test func aReaderWithoutAClockCorrectsNothing() throws {
        // `date +%s` prints no number there: the events are aged by this Mac's clock, as before.
        let remote = 1_800_000_000.0
        let now = Date(timeIntervalSince1970: remote + 7200)
        try append([Self.line(session: "behind", time: remote), Self.line(session: "now", time: remote + 7200)])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        let result = try follow(count: 2, now: now, remoteNow: "unknown")
        #expect(result.sessions == ["now"])
        #expect(result.stale == ["behind"])
    }

    @Test func aQueueThatTookTheInodeOfAnotherIsReadFromItsStart() throws {
        let now = Date()
        try append([Self.line(session: "old1", time: now.timeIntervalSince1970)])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        #expect(try follow(count: 1, now: now).sessions == ["old1"])
        let place = try #require(FollowPosition.load(from: positionPath))
        #expect(place.id != nil)
        // Rotated away twice while the Mac was off, and the third queue took the first one's inode:
        // here, the same file written over, with lines as long as the one read, so the offset is
        // a line's end in it too.
        let handle = try #require(FileHandle(forWritingAtPath: queue))
        try handle.truncate(atOffset: 0)
        try handle.close()
        try append((1...3).map { Self.line(session: "new\($0)", time: now.timeIntervalSince1970) })
        #expect(try inode(queue) == place.inode)
        #expect(place.offset < (try FileManager.default.attributesOfItem(atPath: queue)[.size] as? Int ?? 0))
        #expect(try follow(count: 3, now: now).sessions == ["new1", "new2", "new3"])
        // The same file read again resumes where it was, with its id.
        try append([Self.line(session: "new4", time: now.timeIntervalSince1970)])
        #expect(try follow(count: 1, now: now).sessions == ["new4"])
    }

    @Test func aQueueCutShortWhileFollowedResumesAfterReconnecting() throws {
        let now = Date()
        try append([Self.line(session: "old1", time: now.timeIntervalSince1970), Self.line(session: "old2", time: now.timeIntervalSince1970)])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        #expect(try follow(count: 2, now: now).sessions == ["old1", "old2"])
        // Emptied in place while followed, as with `: > remote.jsonl`, and written again.
        let result = try follow(count: 1, now: now, whileFollowing: {
            let handle = try #require(FileHandle(forWritingAtPath: queue))
            try handle.truncate(atOffset: 0)
            try handle.close()
            try append([Self.line(session: "new1", time: now.timeIntervalSince1970)])
        })
        #expect(result.sessions == ["new1"])
        // The connection drops: the next one resumes after what was shown, and shows it no more.
        try append([Self.line(session: "new2", time: now.timeIntervalSince1970)])
        #expect(try follow(count: 1, now: now).sessions == ["new2"])
    }

    @Test func aPlaceKeptBeforeFilesHadIDsStillResumes() throws {
        let now = Date()
        let first = Self.line(session: "s1", time: now.timeIntervalSince1970)
        try append([first, Self.line(session: "s2", time: now.timeIntervalSince1970)])
        // No id: the inode alone says it is the same file, and the id is learned for next time.
        try FollowPosition(inode: inode(queue), offset: first.utf8.count + 1).save(to: positionPath)
        #expect(try follow(count: 1, now: now).sessions == ["s2"])
        #expect(FollowPosition.load(from: positionPath)?.id != nil)
    }

    @Test func aFirstLineStillBeingWrittenGetsItsIDWhenItIsDone() throws {
        let now = Date()
        let line = Self.line(session: "s1", time: now.timeIntervalSince1970)
        // A queue whose first line has no end yet has no id, and none is saved with its place.
        try FileManager.default.createDirectory(atPath: (queue as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try String(line.prefix(20)).write(toFile: queue, atomically: false, encoding: .utf8)
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        let result = try follow(count: 1, now: now, whileFollowing: {
            let handle = try #require(FileHandle(forWritingAtPath: queue))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line.dropFirst(20) + "\n").utf8))
            try handle.close()
        })
        #expect(result.sessions == ["s1"])
        #expect(FollowPosition.load(from: positionPath)?.id != nil)
    }

    @Test func withoutFlockTheHookLocksWithMkdir() throws {
        #expect(!FileManager.default.fileExists(atPath: "\(root)/noflock/flock"))
        #expect(try hook(["codex"], stdin: #"{"hook_event_name":"Stop","session_id":"s1"}"#, environment: noFlock) == 0)
        #expect(queueLines().count == 1)
        // Nothing left behind but the queue.
        let left = try FileManager.default.contentsOfDirectory(atPath: (queue as NSString).deletingLastPathComponent)
        #expect(left == ["remote.jsonl"])
    }

    @Test func withoutFlockBigEventsFromSessionsAtOnceStayWhole() throws {
        // GNU cat writes 128 KiB at a time: a line this big is several writes.
        let filler = String(repeating: "x", count: 600_000)
        DispatchQueue.concurrentPerform(iterations: 4) { index in
            _ = try? hook(["codex"], stdin: #"{"hook_event_name":"UserPromptSubmit","session_id":"s\#(index)","prompt":"\#(filler)"}"#, environment: noFlock)
        }
        let events = try queueLines().map { try RemoteEvent(line: $0) }
        #expect(events.count == 4)
        #expect(Set(events.compactMap { (try? JSONValue(parsing: $0.payload))?["session_id"]?.string }) == ["s0", "s1", "s2", "s3"])
    }

    @Test func withoutFlockTwoHooksNeverRotateTheQueueTwice() throws {
        try append([String(repeating: "x", count: RemoteHook.rotateSize)])
        DispatchQueue.concurrentPerform(iterations: 6) { index in
            _ = try? hook(["codex"], stdin: #"{"hook_event_name":"Stop","session_id":"s\#(index)"}"#, environment: noFlock)
        }
        // The queue moved aside once: the second hook found a small queue, and left the unread one alone.
        let aside = queueLines(queue + ".1")
        #expect(aside.count == 1 && aside[0].utf8.count == RemoteHook.rotateSize)
        let events = try queueLines().map { try RemoteEvent(line: $0) }
        #expect(events.count == 6)
    }

    @Test func withoutFlockALockLeftByADeadHookIsTakenOver() throws {
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        try FileManager.default.createDirectory(atPath: queue + ".lockdir", withIntermediateDirectories: true)
        try "\(gone.processIdentifier)\n".write(toFile: queue + ".lockdir/pid", atomically: false, encoding: .utf8)
        #expect(try hook(["codex"], stdin: #"{"hook_event_name":"Stop","session_id":"s1"}"#, environment: noFlock) == 0)
        #expect(queueLines().count == 1)
        #expect(!FileManager.default.fileExists(atPath: queue + ".lockdir"))
        // A lock whose hook never wrote its pid is no one's either.
        try FileManager.default.createDirectory(atPath: queue + ".lockdir", withIntermediateDirectories: true)
        #expect(try hook(["codex"], stdin: #"{"hook_event_name":"Stop","session_id":"s2"}"#, environment: noFlock) == 0)
        #expect(queueLines().count == 2)
    }

    @Test func withoutFlockALockAHookLiveHoldsIsLeftAlone() throws {
        try FileManager.default.createDirectory(atPath: queue + ".lockdir", withIntermediateDirectories: true)
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(toFile: queue + ".lockdir/pid", atomically: false, encoding: .utf8)
        // After the 2 seconds it waits, it gives up without the event, and without failing the turn.
        #expect(try hook(["codex"], stdin: #"{"hook_event_name":"Stop","session_id":"s1"}"#, environment: noFlock) == 0)
        #expect(queueLines().isEmpty)
        #expect(FileManager.default.fileExists(atPath: queue + ".lockdir/pid"))
    }

    @Test func aSecondFollowerWaitsForTheFirstAndTakesOver() throws {
        let now = Date()
        try append([Self.line(session: "s1", time: now.timeIntervalSince1970)])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        try String(Int(now.timeIntervalSince1970)).write(toFile: "\(root)/remote-now", atomically: false, encoding: .utf8)
        let settings = RemoteFollower.Settings(target: "devbox", queue: queue, ssh: ["\(root)/ssh"], positionPath: positionPath)
        // The first holds the lock once it hands on an event: it takes the lock before it connects.
        let following = DispatchSemaphore(value: 0)
        let first = RemoteFollower(settings: settings, handle: { _, _ in following.signal() }, log: { _ in })
        first.now = { now }
        let waiting = DispatchSemaphore(value: 0)
        let took = DispatchSemaphore(value: 0)
        var logs: [String] = []
        var sessions: [String] = []
        let second = RemoteFollower(settings: settings, handle: { event, _ in
            sessions.append((try? JSONValue(parsing: event.payload))?["session_id"]?.string ?? "?")
            took.signal()
        }, log: { line in
            logs.append(line)
            if line.contains("waiting") { waiting.signal() }
        })
        second.now = { now }
        // Never longer than this, whatever happens.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            first.stop()
            second.stop()
        }
        DispatchQueue.global().async { try? first.run() }
        #expect(following.wait(timeout: .now() + 20) == .success)
        // It does not end, as it would to be started again by launchd, but says it waits, once.
        var ended = false
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? second.run()
            ended = true
            finished.signal()
        }
        #expect(waiting.wait(timeout: .now() + 20) == .success)
        Thread.sleep(forTimeInterval: 2 * RemoteFollower.lockPoll)
        #expect(!ended)
        #expect(logs == ["another drip follow follows devbox already; waiting for it to end"])
        // The first ends: the second follows on from where it was.
        first.stop()
        try append([Self.line(session: "s2", time: now.timeIntervalSince1970)])
        #expect(took.wait(timeout: .now() + 20) == .success)
        #expect(sessions == ["s2"])
        second.stop()
        #expect(finished.wait(timeout: .now() + 20) == .success)
    }

    @Test func aFollowerStoppedWhileWaitingEndsWithoutFollowing() throws {
        let now = Date()
        try append([Self.line(session: "s1", time: now.timeIntervalSince1970)])
        try FollowPosition(inode: inode(queue), offset: 0).save(to: positionPath)
        try String(Int(now.timeIntervalSince1970)).write(toFile: "\(root)/remote-now", atomically: false, encoding: .utf8)
        let settings = RemoteFollower.Settings(target: "devbox", queue: queue, ssh: ["\(root)/ssh"], positionPath: positionPath)
        let following = DispatchSemaphore(value: 0)
        let first = RemoteFollower(settings: settings, handle: { _, _ in following.signal() }, log: { _ in })
        first.now = { now }
        let waiting = DispatchSemaphore(value: 0)
        var connected = false
        let second = RemoteFollower(settings: settings, handle: { _, _ in connected = true }, log: { line in
            if line.contains("waiting") { waiting.signal() }
        })
        // Never longer than this, whatever happens.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            first.stop()
            second.stop()
        }
        DispatchQueue.global().async { try? first.run() }
        #expect(following.wait(timeout: .now() + 20) == .success)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            #expect(throws: Never.self) { try second.run() }
            finished.signal()
        }
        #expect(waiting.wait(timeout: .now() + 20) == .success)
        second.stop()
        #expect(finished.wait(timeout: .now() + 20) == .success)
        #expect(!connected)
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
        resurface: @escaping (Card, Double) -> Void = { _, _ in }
    ) -> AgentHook.Surroundings {
        AgentHook.Surroundings(
            environment: [
                "XDG_STATE_HOME": state, "XDG_CONFIG_HOME": "\(state)/config", "HOME": state,
                "__CFBundleIdentifier": "com.apple.Terminal",
            ]
                .merging(environment) { $1 },
            hasGUISession: true, isInstalled: { _ in false },
            front: front, paneShowing: paneShowing, resurface: resurface,
            resolver: { _, environment in CardResolver(config: Config(), environment: try EnvironmentSettings(environment: environment)) },
            now: { now })
    }

    func remote(
        _ payload: String, environment: [String: String] = [:], time: Double? = nil,
        policy: AgentHook.Policy = AgentHook.Policy()
    ) -> RemoteEvent {
        RemoteEvent(
            time: time ?? now.timeIntervalSince1970, agent: .claude, machine: "devbox", environment: environment,
            policy: policy, payload: payload)
    }

    func card(
        _ event: RemoteEvent, _ local: AgentHook.Surroundings, onClick: String? = nil, stale: Bool = false
    ) throws -> Card? {
        try AgentHook.card(
            agent: event.agent, payload: event.payload, policy: event.policy,
            in: event.surroundings(local, activate: "com.mitchellh.ghostty", onClick: onClick, stale: stale))
    }

    static let stop = #"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"Stop","last_assistant_message":"Done."}"#
    static let permission = #"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#

    @Test func aRemoteCardIsTheLocalCardFromItsMachine() throws {
        let here = try #require(try AgentHook.card(agent: .claude, payload: Self.stop, in: local()))
        let there = try #require(try card(remote(Self.stop), local(["TMUX": "/tmp/t,1,0", "TMUX_PANE": "%1"])))
        #expect(here.id == "claude:s1")
        #expect(there.id == "claude:s1@devbox")
        #expect(here.title == "api is done")
        #expect(there.title == "api on devbox is done")
        #expect(there.activate == "com.mitchellh.ghostty")
        // The Mac's own tmux pane is not the agent's: a remote card has none.
        #expect(there.pane == nil)
        #expect(there.onClick == nil)
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

    /// Which cards show under `--only needs-you` does not depend on the event naming a session.
    @Test(arguments: [
        (#"{"cwd":"/home/user/api","hook_event_name":"Stop"}"#, false),
        (#"{"session_id":"","cwd":"/home/user/api","hook_event_name":"Stop"}"#, false),
        (#"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"Stop"}"#, false),
        (#"{"cwd":"/home/user/api","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#, true),
        (#"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#, true),
        (#"{"cwd":"/home/user/api","hook_event_name":"StopFailure","error":"rate_limit"}"#, true),
        (#"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"StopFailure","error":"rate_limit"}"#, true),
    ] as [(String, Bool)])
    func onlyNeedsYouFiltersDoneCardsWhetherOrNotTheEventNamesASession(_ case: (payload: String, shows: Bool)) throws {
        let policy = AgentHook.Policy(only: .needsYou)
        let direct = try AgentHook.card(agent: .claude, payload: `case`.payload, policy: policy, in: local())
        let viaRemote = try card(remote(`case`.payload, policy: policy), local())
        #expect((direct != nil) == `case`.shows, "\(`case`.payload)")
        #expect((viaRemote != nil) == `case`.shows, "remote \(`case`.payload)")
        // Without the flag every card shows, with or without a session.
        #expect(try AgentHook.card(agent: .claude, payload: `case`.payload, in: local()) != nil)
    }

    /// Without a session id there is no turn start to count `--min-turn` from: the done card shows.
    @Test func aSessionlessDoneCardIsNotHeldBackByMinTurn() throws {
        #expect(try AgentHook.card(
            agent: .claude, payload: #"{"cwd":"/home/user/api","hook_event_name":"Stop"}"#,
            policy: AgentHook.Policy(minTurn: 30), in: local()) != nil)
    }

    @Test func theFilterTheMachinesHookGaveDecides() throws {
        let only = AgentHook.Policy(only: .needsYou)
        #expect(try card(remote(Self.stop, policy: only), local()) == nil)
        #expect(try card(remote(Self.permission, policy: only), local()) != nil)
        // --min-turn counts from the prompt the machine reported.
        let prompt = #"{"session_id":"s1","hook_event_name":"UserPromptSubmit"}"#
        #expect(try card(remote(prompt), local()) == nil)
        #expect(try card(remote(Self.stop, policy: AgentHook.Policy(minTurn: 30)), local()) == nil)
        // The flag is the machine's: this Mac's own settings do not add one.
        #expect(try card(remote(Self.stop), local()) != nil)
    }

    @Test func aQueueLineCarriesTheFilterAndNeverApprove() throws {
        let line = #"{"drip":1,"time":1800000000,"agent":"claude","machine":"devbox","env":{},"forward":{},"filter":{"min_turn":"30","only":"needs-you"},"payload":{"hook_event_name":"Stop"}}"#
        let event = try RemoteEvent(line: line)
        #expect(event.policy == AgentHook.Policy(approve: false, minTurn: 30, only: .needsYou))
        // A filter that is not one drip knows is ignored, as is a line without one.
        let odd = line.replacingOccurrences(of: #"{"min_turn":"30","only":"needs-you"}"#, with: #"{"min_turn":"-1","only":"all","approve":true}"#)
        #expect(try RemoteEvent(line: odd).policy == AgentHook.Policy())
        let none = line.replacingOccurrences(of: #""filter":{"min_turn":"30","only":"needs-you"},"#, with: "")
        #expect(try RemoteEvent(line: none).policy == AgentHook.Policy())
    }

    @Test func aRemoteCardTakesYouNotToBeWatchingIt() throws {
        let asked = Asked()
        /// The terminal in front, or not, and you at it `idle` seconds ago.
        func there(_ environment: [String: String], app: Bool = true, idle: Double = 0) throws -> Card? {
            try card(remote(Self.stop), local(environment) { _ in
                WhenFocused.Front(app: app, idle: idle)
            } paneShowing: { card in
                asked.panes.append(card.pane)
                return true
            })
        }
        let skip = ["DRIP_WHEN_FOCUSED": "skip"]
        // drip cannot tell which pane shows on the machine: the card shows, with its sound.
        #expect(try there(skip)?.sound != Sound.none)
        #expect(try there([:])?.sound != Sound.none)
        #expect(try there(skip, app: false)?.sound != Sound.none)
        #expect(try there(skip, idle: 120)?.sound != Sound.none)
        // And it never asks this Mac's terminal about a pane that is not the agent's.
        #expect(asked.panes.isEmpty)
    }

    @Test func aRemoteCardRunsOnlyTheCommandFollowGives() throws {
        var event = remote(Self.stop)
        event.forwarded = ["HERDR_PANE_ID": "w1:p2"]
        #expect(try card(event, local())?.onClick == nil)
        let clicked = try #require(try card(event, local(), onClick: "my-focus"))
        #expect(clicked.onClick == OnClick(command: "my-focus", machine: "devbox", environment: ["HERDR_PANE_ID": "w1:p2"]))
        #expect(clicked.isClickable)
        // A click command of this Mac's own shell does not reach a remote card.
        #expect(try card(event, local(["DRIP_FORWARD_ENV": "HOME"]))?.onClick == nil)
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

struct ConfigWarnedOnceTests {
    @Test func theConfigIsReadWithEachEventAndEachWarningSaidOnce() throws {
        var reads = 0
        var warnings: [String] = []
        let config = ConfigWarnedOnce(
            read: { _ in
                reads += 1
                let said = ["config.toml:2: unknown key 'colour'"] + (reads < 3 ? [] : ["config.toml:3: unknown key 'tone'"])
                return ConfigFile(config: Config(), warnings: said)
            },
            warn: { warnings.append($0) })
        var files: [ConfigFile] = []
        for _ in 1...5 { files.append(config.load(environment: [:])) }
        #expect(reads == 5)
        // An edit applies to the next event.
        #expect(files.map(\.warnings.count) == [1, 1, 2, 2, 2])
        #expect(warnings == ["config.toml:2: unknown key 'colour'", "config.toml:3: unknown key 'tone'"])
    }

    @Test func aFileThatCannotBeUsedIsReadAgainWithTheNextEvent() {
        var reads = 0
        var warnings: [String] = []
        let config = ConfigWarnedOnce(
            read: { _ in
                reads += 1
                if reads == 1 { return ConfigFile(config: Config(), warnings: ["invalid config: config.toml:1: not TOML (drip ignores the file)"]) }
                return ConfigFile(config: Config(size: .large), warnings: ["config.toml:2: unknown key 'colour'"])
            },
            warn: { warnings.append($0) })
        #expect(config.load(environment: [:]).config == Config())
        #expect(warnings.count == 1)
        // A fixed file applies to the next event.
        #expect(config.load(environment: [:]).config == Config(size: .large))
        _ = config.load(environment: [:])
        #expect(reads == 3)
        #expect(warnings.count == 2)
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
