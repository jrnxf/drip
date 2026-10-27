#if !os(WASI)
import DripCore
import Foundation
import Testing

/// The debug log: off unless turned on, one greppable line for each decision about a card, and
/// nothing an agent said.
struct DebugLogTests {
    let state: String
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("drip-debug-\(UUID().uuidString)").path
    }

    var environment: [String: String] {
        ["XDG_STATE_HOME": state, "XDG_CONFIG_HOME": "\(state)/config", "HOME": state]
    }

    var logPath: String { "\(state)/drip/debug.log" }

    func log() -> String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }

    func lines() -> [String] { log().split(separator: "\n").map(String.init) }

    func writeConfig(_ text: String) throws {
        try FileManager.default.createDirectory(atPath: "\(state)/config/drip", withIntermediateDirectories: true)
        try text.write(toFile: "\(state)/config/drip/config.toml", atomically: true, encoding: .utf8)
    }

    func surroundings(
        _ extra: [String: String] = [:], front: WhenFocused.Front = WhenFocused.Front(app: true, pane: nil, idle: 3, frontmost: "com.apple.Terminal"),
        paneShowing: Bool? = true, process: DebugLog.Process = .hook
    ) -> AgentHook.Surroundings {
        AgentHook.Surroundings(
            environment: environment.merging(extra) { $1 }, hasGUISession: true, isInstalled: { _ in false },
            front: { _ in front }, paneShowing: { _ in paneShowing },
            resolver: { _, environment in CardResolver(config: Config(), environment: try EnvironmentSettings(environment: environment)) },
            now: { now }, process: process)
    }

    /// Surroundings that count how often the config file is read, and hand the resolver what was read.
    func counting(_ extra: [String: String] = [:], loads: Loads) -> AgentHook.Surroundings {
        var counted = surroundings(extra)
        counted.loadConfig = { environment in
            loads.count += 1
            return try ConfigLoader.load(environment: environment)
        }
        counted.resolver = { file, environment in
            CardResolver(config: file.config, environment: try EnvironmentSettings(environment: environment))
        }
        return counted
    }

    final class Loads {
        var count = 0
    }

    static let clear = #"{"session_id":"0123456789abcdef-long-session","cwd":"/home/user/project","hook_event_name":"UserPromptSubmit"}"#

    static let secret = "SECRET-TITLE-TEXT"
    static let stop = #"{"session_id":"0123456789abcdef-long-session","cwd":"/home/user/private-project","hook_event_name":"Stop","last_assistant_message":"SECRET-TITLE-TEXT"}"#
    static let permission = #"{"session_id":"0123456789abcdef-long-session","cwd":"/home/user/private-project","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf /secret/command-path"},"prompt":"SECRET-PROMPT"}"#

    @Test func aResolvedEventReadsTheConfigOnceWhateverLogsIt() throws {
        try writeConfig("debug = true\nwhen_focused = \"show\"\n")
        let loads = Loads()
        let card = try AgentHook.card(agent: .claude, payload: Self.stop, in: counting(loads: loads))
        #expect(card != nil)
        #expect(loads.count == 1)
        #expect(lines().count == 1)

        // DRIP_DEBUG decides the log alone, so the resolver's read is the only one.
        loads.count = 0
        _ = try AgentHook.card(agent: .claude, payload: Self.stop, in: counting(["DRIP_DEBUG": "0"], loads: loads))
        #expect(loads.count == 1)
    }

    @Test func aDecisionThatResolvesNoCardReadsTheConfigOnlyForTheLog() throws {
        try writeConfig("debug = true\n")
        let loads = Loads()
        _ = try AgentHook.card(agent: .claude, payload: Self.clear, in: counting(loads: loads))
        #expect(loads.count == 1)
        #expect(lines().count == 1)

        loads.count = 0
        _ = try AgentHook.card(agent: .claude, payload: Self.clear, in: counting(["DRIP_DEBUG": "1"], loads: loads))
        _ = try AgentHook.card(agent: .claude, payload: Self.stop, in: counting(["DRIP_DEBUG": "1", "DRIP_HOOK": "off"], loads: loads))
        #expect(loads.count == 0)
    }

    @Test func aMalformedConfigFailsOnlyTheEventsThatResolveACard() throws {
        try writeConfig("debug = \"yes\"\n")
        let loads = Loads()
        for (payload, extra) in [(Self.clear, [:]), (Self.stop, ["DRIP_HOOK": "off"]), (Self.stop, ["DRIP_HOOK": "attention"])] as [(String, [String: String])] {
            #expect(try AgentHook.card(agent: .claude, payload: payload, in: counting(extra, loads: loads)) == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: logPath))
        #expect(throws: ConfigError.self) {
            try AgentHook.card(agent: .claude, payload: Self.stop, in: counting(loads: loads))
        }
        // A card that resolves fails the same with the log forced on, and the log still says nothing of the config.
        #expect(throws: ConfigError.self) {
            try AgentHook.card(agent: .claude, payload: Self.stop, in: counting(["DRIP_DEBUG": "1"], loads: loads))
        }
    }

    @Test func anInvalidSettingFailsOnlyTheEventsThatResolveACard() throws {
        let loads = Loads()
        let invalid = ["DRIP_SECONDS": "soon", "DRIP_DEBUG": "maybe"]
        #expect(try AgentHook.card(agent: .claude, payload: Self.clear, in: counting(invalid, loads: loads)) == nil)
        #expect(try AgentHook.card(agent: .claude, payload: Self.stop, in: counting(invalid.merging(["DRIP_HOOK": "off"]) { $1 }, loads: loads)) == nil)
        #expect(throws: UsageError.self) {
            try AgentHook.card(agent: .claude, payload: Self.stop, in: counting(invalid, loads: loads))
        }
    }

    @Test func eachEventReadsTheConfigAsItIsThen() throws {
        let loads = Loads()
        try writeConfig("debug = false\n")
        _ = try AgentHook.card(agent: .claude, payload: Self.clear, in: counting(loads: loads))
        #expect(lines().isEmpty)
        try writeConfig("debug = true\n")
        _ = try AgentHook.card(agent: .claude, payload: Self.clear, in: counting(loads: loads))
        #expect(lines().count == 1)
        #expect(loads.count == 2)
    }

    @Test func offByDefaultWritesNothing() throws {
        _ = try AgentHook.card(agent: .claude, payload: Self.stop, in: surroundings())
        #expect(!FileManager.default.fileExists(atPath: logPath))
    }

    @Test func onWritesOneLineWithTheInputsOfTheDecision() throws {
        let card = try AgentHook.card(
            agent: .claude, payload: Self.stop, in: surroundings(["DRIP_DEBUG": "1", "DRIP_WHEN_FOCUSED": "skip", "DRIP_AWAY_AFTER": "30"]))
        #expect(card == nil)
        let written = lines()
        #expect(written.count == 1)
        let line = try #require(written.first)
        let fields = line.split(separator: " ").map(String.init)
        // <time> <process> <event> <decision> key=value ...
        #expect(fields[1...3] == ["hook", "card", "skip"])
        #expect(fields[0].hasPrefix("2027-") || fields[0].hasPrefix("2026-") || fields[0].hasPrefix("2025-") || fields[0].contains("T"))
        for field in [
            "agent=claude", "reason=focused_skip", "when_focused=skip", "away_after=30.0", "idle_seconds=3.0",
            "frontmost=com.apple.Terminal", "app_in_front=true", "pane_showing=true", "id=claude:01234567",
            "query_ms=", "answer=showing",
        ] {
            #expect(fields.contains { $0.hasPrefix(field) }, "missing \(field) in \(line)")
        }
    }

    @Test func aRemoteDecisionRecordsTheHerdrQueryItsAnswerAndHowLongItTook() throws {
        let event = RemoteEvent(
            time: now.timeIntervalSince1970, agent: .claude, machine: "devbox",
            environment: ["HERDR_PANE_ID": "w1:p2", "HERDR_TAB_ID": "w1:t2", "HERDR_WORKSPACE_ID": "w1"], payload: Self.stop)
        let local = surroundings(["DRIP_DEBUG": "1"], paneShowing: nil)
        _ = try AgentHook.card(
            agent: .claude, payload: event.payload,
            in: event.surroundings(local, activate: "com.mitchellh.ghostty", herdrMachine: "devbox"))
        let line = try #require(lines().first)
        let fields = line.split(separator: " ").map(String.init)
        #expect(fields[1] == "follow")
        for field in [
            "machine=devbox", "herdr_machine=devbox", "pane=herdr:w1:p2", "query=\"herdr pane get w1:p2\"", "answer=unknown",
            "remote_pane_unknown=true", "when_focused=quiet", "away_after=60.0", "activate=com.mitchellh.ghostty",
        ] {
            #expect(line.contains(field), "missing \(field) in \(line)")
        }
        #expect(line.contains("query_ms="))
        // The unanswered pane query does not hide what drip noticed.
        #expect(line.contains("frontmost=com.apple.Terminal") && line.contains("idle_seconds=3.0"))
    }

    @Test func aFrontmostAppMacOSDoesNotReportIsNone() throws {
        let front = WhenFocused.Front(app: false, pane: nil, idle: 5, frontmost: "none")
        _ = try AgentHook.card(
            agent: .claude, payload: Self.stop, in: surroundings(["DRIP_DEBUG": "1", "DRIP_WHEN_FOCUSED": "skip"], front: front))
        let line = try #require(lines().first)
        #expect(line.contains("frontmost=none") && line.contains("idle_seconds=5.0") && line.contains("app_in_front=false"))
    }

    @Test func everyKindOfDecisionIsLogged() throws {
        let on = ["DRIP_DEBUG": "1"]
        _ = try AgentHook.card(agent: .claude, payload: Self.stop, in: surroundings(on.merging(["DRIP_HOOK": "off"]) { $1 }))
        _ = try AgentHook.card(agent: .claude, payload: Self.stop, in: surroundings(on.merging(["DRIP_AGENT_CARDS": "attention"]) { $1 }))
        _ = try AgentHook.card(agent: .claude, payload: Self.permission, in: surroundings(on.merging(["DRIP_WHEN_FOCUSED": "show"]) { $1 }))
        var stale = surroundings(on)
        stale.showsCards = false
        _ = try AgentHook.card(agent: .claude, payload: Self.stop, in: stale)
        var noGUI = surroundings(on)
        noGUI.hasGUISession = false
        _ = try AgentHook.card(agent: .claude, payload: Self.stop, in: noGUI)
        _ = try AgentHook.card(
            agent: .claude, payload: #"{"session_id":"s1","hook_event_name":"UserPromptSubmit"}"#, in: surroundings(on))
        let text = log()
        for expected in [
            "reason=drip_hook_off", "reason=done_card_filtered", "reason=when_focused_show",
            "reason=stale_event", "reason=no_gui_session", " clear clear ",
        ] {
            #expect(text.contains(expected), "missing \(expected) in \(text)")
        }
        // Every card line says which app was in front and how long you were idle, or that drip did not ask.
        for line in lines() where line.contains(" card ") {
            #expect(line.contains(" frontmost=unknown") && line.contains(" idle_seconds=unknown"), "\(line)")
        }
    }

    @Test func noPayloadTextReachesTheLog() throws {
        let on = ["DRIP_DEBUG": "1"]
        for payload in [Self.stop, Self.permission] {
            for focus in ["show", "skip", "quiet"] {
                _ = try AgentHook.card(
                    agent: .claude, payload: payload, in: surroundings(on.merging(["DRIP_WHEN_FOCUSED": focus]) { $1 }))
            }
        }
        let text = log()
        #expect(!text.isEmpty)
        for leak in [Self.secret, "SECRET-PROMPT", "rm -rf", "command-path", "private-project", "/home/user", "long-session", "Bash"] {
            #expect(!text.contains(leak), "\(leak) leaked into the log")
        }
        // The session id is cut short.
        #expect(text.contains("claude:01234567 ") || text.contains("claude:01234567\n"))
        #expect(!text.contains("0123456789"))
    }

    @Test func aValueNeverBreaksALineOrRunsLong() {
        let path = "\(state)/drip/debug.log"
        let log = DebugLog(path: path, process: .cli, enabled: true, now: { now })
        log.record("test", "note", [("a", "two words\nnext line"), ("b", String(repeating: "x", count: 500)), ("c", nil)])
        let written = lines()
        #expect(written.count == 1)
        #expect(written[0].contains("a=\"two wordsnext line\""))
        #expect(!written[0].contains("c="))
        #expect(written[0].count < 300)
    }

    @Test func theFileIsReadableOnlyByTheUser() throws {
        _ = try AgentHook.card(agent: .claude, payload: Self.stop, in: surroundings(["DRIP_DEBUG": "1"]))
        let attributes = try FileManager.default.attributesOfItem(atPath: logPath)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func theLogKeepsAboutTheLastMegabyte() throws {
        let log = DebugLog(path: logPath, process: .cli, enabled: true, now: { now })
        let filler = String(repeating: "y", count: 70)
        let total = DebugLog.limit / 100
        for index in 0..<total { log.record("fill", "note", [("n", "\(index)"), ("pad", filler)]) }
        let size = (try FileManager.default.attributesOfItem(atPath: logPath))[.size] as? Int ?? 0
        #expect(size <= DebugLog.limit)
        #expect(size > DebugLog.limit / 2)
        let written = lines()
        #expect(written.last?.contains("n=\(total - 1) ") == true)
        #expect(written.first?.contains("n=0 ") == false)
        // The oldest lines went whole: every line left is one.
        #expect(written.allSatisfy { $0.split(separator: " ").count == 6 })
    }

    @Test func manyDripsWriteAtOnce() throws {
        let log = DebugLog(path: logPath, process: .hook, enabled: true, now: { now })
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<50 { log.record("race", "note", [("w", "\(worker)"), ("i", "\(index)")]) }
        }
        let written = lines()
        #expect(written.count == 400)
        #expect(written.allSatisfy { $0.split(separator: " ").count == 6 })
    }

    @Test func theConfigAndTheEnvironmentDecideAsForOtherSettings() throws {
        #expect(!DebugLog.isEnabled(environment: environment))
        try writeConfig("debug = true\n")
        #expect(DebugLog.isEnabled(environment: environment))
        // The environment beats the config file, either way.
        #expect(!DebugLog.isEnabled(environment: environment.merging(["DRIP_DEBUG": "0"]) { $1 }))
        try writeConfig("debug = false\n")
        #expect(!DebugLog.isEnabled(environment: environment))
        #expect(DebugLog.isEnabled(environment: environment.merging(["DRIP_DEBUG": "1"]) { $1 }))
        // Empty counts as unset.
        #expect(!DebugLog.isEnabled(environment: environment.merging(["DRIP_DEBUG": ""]) { $1 }))
        #expect(try EnvironmentSettings.debug(environment: ["DRIP_DEBUG": "true"]) == true)
        #expect(throws: UsageError.self) { try EnvironmentSettings.debug(environment: ["DRIP_DEBUG": "maybe"]) }
    }

    @Test func theConfigKeyTakesABoolean() throws {
        #expect(try ConfigLoader.parse("debug = true\n", path: "config.toml").config.debug == true)
        #expect(throws: ConfigError.self) { try ConfigLoader.parse("debug = \"yes\"\n", path: "config.toml") }
        #expect(try ConfigLoader.parse("", path: "config.toml").config.debug == nil)
    }

    @Test func theConfigFileTurnsTheLogOnForAHook() throws {
        try writeConfig("debug = true\n")
        _ = try AgentHook.card(agent: .claude, payload: Self.stop, in: surroundings())
        #expect(lines().count == 1)
    }

    @Test func debugShowsTheLogAndClearEmptiesIt() throws {
        #expect(DebugLog.contents(environment: environment).isEmpty)
        try DebugLog.clear(environment: environment)
        _ = try AgentHook.card(agent: .claude, payload: Self.stop, in: surroundings(["DRIP_DEBUG": "1"]))
        #expect(DebugLog.contents(environment: environment) == log())
        #expect(!DebugLog.contents(environment: environment).isEmpty)
        try DebugLog.clear(environment: environment)
        #expect(DebugLog.contents(environment: environment).isEmpty)
        // Still the user's alone, and still the log: the next line goes in it.
        _ = try AgentHook.card(agent: .claude, payload: Self.stop, in: surroundings(["DRIP_DEBUG": "1"]))
        #expect(lines().count == 1)
    }

    @Test func debugIsASubcommand() {
        guard case let .invocation(.debug(command)) = CommandLineParser.parse(["debug", "--clear"]) else {
            Issue.record("drip debug --clear is not the debug command")
            return
        }
        #expect(command.clear)
        guard case let .invocation(.debug(plain)) = CommandLineParser.parse(["debug"]) else {
            Issue.record("drip debug is not the debug command")
            return
        }
        #expect(!plain.clear)
    }
}
#endif
