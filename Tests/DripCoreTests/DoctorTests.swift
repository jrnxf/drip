#if !os(WASI) // DoctorReport is only in the macOS and Linux drip.
@testable import DripCore
import Foundation
import Testing

/// `drip doctor`: what it says stops cards, how it judges the config file, and the exit code.
struct DoctorTests {
    /// A home of its own with a config file of `config`, if given, and the environment for it.
    private static func environment(config: String? = nil, extra: [String: String] = [:]) throws -> [String: String] {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("drip-doctor-\(UUID().uuidString)")
        let configDirectory = home.appendingPathComponent("config")
        try FileManager.default.createDirectory(
            at: configDirectory.appendingPathComponent("drip"), withIntermediateDirectories: true)
        if let config {
            try config.write(
                to: configDirectory.appendingPathComponent("drip/config.toml"), atomically: false, encoding: .utf8)
        }
        return [
            "HOME": home.path, "XDG_CONFIG_HOME": configDirectory.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
        ].merging(extra) { $1 }
    }

    private static func report(
        config: String? = nil, extra: [String: String] = [:], gui: Bool = true, locked: Bool = false,
        showsCards: Bool = true
    ) throws -> DoctorReport {
        DoctorReport(
            environment: try environment(config: config, extra: extra), hasGUISession: gui, screenLocked: locked,
            showsCards: showsCards)
    }

    @Test func parses() {
        guard case let .invocation(.doctor(plain)) = CommandLineParser.parse(["doctor"]) else {
            Issue.record("drip doctor did not parse"); return
        }
        #expect(!plain.json)
        guard case let .invocation(.doctor(json)) = CommandLineParser.parse(["doctor", "--json"]) else {
            Issue.record("drip doctor --json did not parse"); return
        }
        #expect(json.json)
        for arguments in [["doctor", "extra"], ["doctor", "--yes", "Go"]] {
            guard case let .exit(status, message) = CommandLineParser.parse(arguments) else {
                Issue.record("\(arguments) parsed"); continue
            }
            #expect(status == ExitStatus.usage, "\(arguments)")
            #expect(message.hasSuffix("See 'drip doctor --help'."), "\(message)")
        }
        // A real subcommand, so it is no custom preset's name.
        #expect(ConfigLoader.reservedNames.contains("doctor"))
    }

    @Test func allIsWell() throws {
        let report = try Self.report()
        #expect(report.status == ExitStatus.shown)
        #expect(report.blockers.isEmpty)
        #expect(report.standardError == nil)
        #expect(!report.configExists)
        #expect(report.stateDirectoryWritable)
        #expect(report.version == dripVersion)
        let text = report.text()
        #expect(text.hasPrefix("drip \(dripVersion)\nGUI session: yes\npaused: no\nscreen locked: no\n"), "\(text)")
        #expect(text.contains("(not found, so drip uses the defaults)"), "\(text)")
        #expect(text.contains("state directory: \(report.stateDirectory) (writable)"), "\(text)")
        #expect(text.hasSuffix("\ncards show now"), "\(text)")
    }

    @Test func eachThingThatStopsCardsExitsOne() throws {
        let away = try Self.report(gui: false)
        #expect(away.blockers == [.noGUISession])
        #expect(away.status == ExitStatus.failed)
        #expect(away.text().hasSuffix("\nstops cards: \(DoctorReport.Blocker.noGUISession.explanation)"))
        #expect(away.standardError == "drip: " + DoctorReport.Blocker.noGUISession.explanation)

        let locked = try Self.report(locked: true)
        #expect(locked.blockers == [.screenLocked])
        #expect(locked.status == ExitStatus.failed)
        #expect(locked.text().contains("screen locked: yes"))

        let environment = try Self.environment()
        try DripPause(environment: environment).pause(until: Date().addingTimeInterval(1800))
        let paused = DoctorReport(environment: environment, hasGUISession: true, screenLocked: true)
        #expect(paused.blockers == [.paused, .screenLocked])
        #expect(paused.status == ExitStatus.failed)
        // One stderr line for each cause.
        #expect(paused.standardError == ([.paused, .screenLocked] as [DoctorReport.Blocker])
            .map { "drip: " + $0.explanation }.joined(separator: "\n"))
        let now = Date()
        let utc = try #require(TimeZone(identifier: "UTC"))
        let text = paused.text(now: now, timeZone: utc)
        let end = try #require(paused.pauseEnd)
        // The same words as drip pause, from the same code.
        let left = DripPause.timeLeft(end: end, now: now, timeZone: utc)
        #expect(left.hasPrefix("until "), "\(left)")
        #expect(DripPause.status(end: end, now: now, timeZone: utc) == "drip is paused " + left)
        #expect(text.contains("\npaused: yes, \(left)\n"), "\(text)")
        // A question already on screen stays through a pause, so the report says so.
        #expect(DoctorReport.Blocker.paused.explanation.contains("a question already on screen stays"))
        #expect(text.contains("stops cards: \(DoctorReport.Blocker.paused.explanation)"), "\(text)")
        #expect(text.contains("stops cards: \(DoctorReport.Blocker.screenLocked.explanation)"), "\(text)")
    }

    /// Every problem is listed, not only the first; an unknown key is only a warning.
    @Test func anInvalidConfigExitsFour() throws {
        let report = try Self.report(config: "size = \"huge\"\nseconds = 99\nbogus = 1\n", gui: false)
        #expect(report.status == ExitStatus.invalidConfig)
        #expect(report.configExists)
        #expect(report.configProblems.count == 2)
        #expect(report.configProblems[0].contains(":1: size: "), "\(report.configProblems)")
        #expect(report.configProblems[1].contains(":2: seconds: "), "\(report.configProblems)")
        #expect(report.configWarnings.count == 1)
        #expect(report.configWarnings[0].contains("unknown key 'bogus'"), "\(report.configWarnings)")
        #expect(report.standardError == "drip: invalid config: 2 problems in \(report.configPath)\n"
            + "drip: \(DoctorReport.Blocker.noGUISession.explanation)")
        #expect(!report.configIgnored)
        #expect(report.text().contains("(invalid, each bad key keeps its default)"))
        // The bad keys keep their defaults, as a card command would use them.
        #expect(report.settings.size == Defaults.size)
        #expect(report.settings.seconds == Defaults.seconds)

        let warned = try Self.report(config: "bogus = 1\n")
        #expect(warned.status == ExitStatus.shown)
        #expect(warned.configProblems.isEmpty)
        #expect(warned.text().contains("(valid)"))
    }

    /// A file drip cannot use at all, not one bad key: drip ignores all of it.
    @Test func aWholeFileDripCannotUseIsIgnored() throws {
        let environment = try Self.environment()
        let path = ConfigLoader.path(environment: environment)
        for (what, bytes) in [
            ("not TOML", Data("seconds = 3\nbroken = [".utf8)),
            ("not UTF-8", Data([0x73, 0x3D, 0xFF, 0xFE])),
            ("over 1 MB", Data(repeating: 0x20, count: ConfigLoader.sizeLimit + 1)),
        ] {
            try bytes.write(to: URL(fileURLWithPath: path))
            let report = DoctorReport(environment: environment, hasGUISession: true, screenLocked: false)
            #expect(report.status == ExitStatus.invalidConfig, "\(what)")
            #expect(report.configIgnored, "\(what)")
            #expect(report.configProblems.count == 1, "\(what)")
            #expect(report.settings.seconds == Defaults.seconds, "\(what)")
            let text = report.text()
            #expect(text.contains("(invalid, so drip ignores the whole file and uses the defaults)"), "\(what): \(text)")
            #expect(!text.contains("each bad key keeps its default"), "\(what): \(text)")
            #expect(try JSONValue(parsing: report.json)["config"]?["ignored"] == .bool(true), "\(what)")
        }
    }

    /// Text from the config file and the environment reaches the terminal escaped, so it cannot drive it.
    @Test func terminalTextIsEscaped() throws {
        let report = try Self.report(
            config: "size = \"\\u001B[31mhuge\"\n", extra: ["DRIP_SIZE": "\u{1B}[2J"])
        #expect(report.configProblems.first?.unicodeScalars.contains("\u{1B}") == true, "\(report.configProblems)")
        let text = report.text()
        #expect(!text.unicodeScalars.contains("\u{1B}"), "\(text)")
        #expect(text.contains("\\u{1B}[31mhuge"), "\(text)")
        #expect(text.contains("\\u{1B}[2J"), "\(text)")
        let standardError = try #require(report.standardError)
        #expect(!standardError.unicodeScalars.contains("\u{1B}"), "\(standardError)")
        #expect(standardError.contains("\\u{1B}[2J"), "\(standardError)")
        #expect(!report.json.unicodeScalars.contains("\u{1B}"))
    }

    /// A bad variable stops every card command with 2, so it is a cause, and the others still count.
    @Test func aBadVariableIsAUsageError() throws {
        let report = try Self.report(
            config: "size = \"huge\"\ndebug = true\n",
            extra: ["DRIP_SECONDS": "soon", "DRIP_SIZE": "large", "DRIP_DEBUG": "maybe", "DRIP_MOTION": "subtle"])
        #expect(report.status == ExitStatus.usage)
        #expect(report.environmentProblems.count == 2, "\(report.environmentProblems)")
        #expect(report.environmentProblems.first?.hasPrefix("DRIP_DEBUG must be") == true, "\(report.environmentProblems)")
        #expect(report.environmentProblems.last?.hasPrefix("DRIP_SECONDS must be") == true, "\(report.environmentProblems)")
        #expect(report.blockers == [.badVariable])
        // The variables drip can read still apply, and the debug log reads DRIP_DEBUG as it always does:
        // one it cannot read counts as unset, so the config's debug holds.
        #expect(report.settings.size == .large)
        #expect(report.settings.motion == .subtle)
        #expect(report.settings.seconds == Defaults.seconds)
        #expect(report.settings.debug)
        let text = report.text()
        #expect(text.contains("\nenvironment: DRIP_SECONDS must be"), "\(text)")
        #expect(text.hasSuffix("\nstops cards: \(DoctorReport.Blocker.badVariable.explanation)"), "\(text)")
        #expect(!text.contains("cards show now"), "\(text)")
        // stderr in the form of any usage error.
        let standardError = try #require(report.standardError)
        #expect(standardError.hasPrefix("drip: DRIP_DEBUG must be"), "\(standardError)")
        #expect(standardError.contains("\ndrip: DRIP_SECONDS must be"), "\(standardError)")
        #expect(standardError.contains("\ndrip: invalid config: 1 problem in "), "\(standardError)")
        #expect(standardError.hasSuffix("\nSee 'drip doctor --help'."), "\(standardError)")
        let json = try JSONValue(parsing: report.json)
        #expect(json["stops_cards"] == .array([.string("bad_variable")]))
        #expect(json["environment_errors"]?.elements?.count == 2)
    }

    /// The Linux drip shows no cards, so no GUI session, a pause or a lock stops nothing there.
    @Test func linuxShowsNoCards() throws {
        let environment = try Self.environment()
        try DripPause(environment: environment).pause(until: Date().addingTimeInterval(600))
        let report = DoctorReport(environment: environment, hasGUISession: false, screenLocked: false, showsCards: false)
        #expect(report.blockers.isEmpty)
        #expect(report.status == ExitStatus.shown)
        #expect(report.standardError == nil)
        #expect(report.text().hasSuffix("\ncards show only on macOS: here an agent's hooks run drip-remote-hook, and drip "
            + "follow on the Mac shows the cards"))
        #expect(try JSONValue(parsing: report.json)["shows_cards"] == .bool(false))
        let bad = try Self.report(extra: ["DRIP_SIZE": "huge"], gui: false, showsCards: false)
        #expect(bad.blockers == [.badVariable])
        #expect(bad.status == ExitStatus.usage)
    }

    /// A state directory drip cannot write keeps no history or pause, but cards show, so it is no cause.
    @Test func aStateDirectoryDripCannotWriteIsReported() throws {
        var environment = try Self.environment()
        let file = try #require(environment["HOME"]) + "/a-file"
        try Data().write(to: URL(fileURLWithPath: file))
        environment["XDG_STATE_HOME"] = file
        let report = DoctorReport(environment: environment, hasGUISession: true, screenLocked: false)
        #expect(!report.stateDirectoryWritable)
        #expect(report.status == ExitStatus.shown)
        #expect(report.text().contains(
            "(not writable, so drip keeps no history, pause or debug log, but cards still show)\ncards show now"))
        #expect(try JSONValue(parsing: report.json)["state_directory"]?["writable"] == .bool(false))
    }

    /// The settings are those the code the cards use gives.
    @Test func settingsAreWhatTheCardsUse() throws {
        let environment = try Self.environment(
            config: "seconds = 3\nsize = \"large\"\nstack = \"off\"\nstack_max = 2\nsound = \"Glass\"\n",
            extra: ["DRIP_MOTION": "subtle"])
        let report = DoctorReport(environment: environment, hasGUISession: true, screenLocked: false)
        let file = ConfigLoader.loadLeniently(environment: environment)
        let resolver = CardResolver(config: file.config, environment: try EnvironmentSettings(environment: environment))
        let card = try resolver.resolve(kind: "info", title: "t", flags: CardFlags())
        #expect(report.settings.seconds == card.seconds)
        #expect(report.settings.size == card.size)
        #expect(report.settings.motion == card.motion)
        #expect(report.settings.sound == card.sound)
        #expect(StackSettings.current(environment: environment) == nil)
        #expect(report.settings.stack == .off)
        #expect(report.settings.stackMax == 2)
    }

    @Test func settingsComeFromTheVariablesThenTheConfig() throws {
        let report = try Self.report(
            config: "seconds = 3\nsize = \"large\"\nstack = \"push\"\nhistory = 50\naway_after = 30\n",
            extra: ["DRIP_SECONDS": "6", "DRIP_SOUND": "none", "DRIP_DEBUG": "1"])
        let settings = report.settings
        #expect(settings.seconds == 6)
        #expect(settings.size == .large)
        #expect(settings.sound == Sound.none)
        #expect(settings.motion == Defaults.motion)
        #expect(settings.stack == .push)
        #expect(settings.stackMax == Defaults.stackMax)
        #expect(settings.whenFocused == .default)
        #expect(settings.awayAfter == 30)
        #expect(settings.history == 50)
        #expect(settings.debug)
        let text = report.text()
        for line in ["  seconds = 6", "  size = large", "  sound = none", "  stack = push", "  history = 50", "  debug = true"] {
            #expect(text.contains(line + "\n"), "\(line): \(text)")
        }
    }

    /// The keys the contract lists are there every time, with null for a value that is not.
    static let keys = [
        "version", "status", "stops_cards", "shows_cards", "gui_session", "paused", "pause_ends", "screen_locked",
        "config", "environment_errors", "settings", "state_directory",
    ]

    @Test func jsonHasEveryKeyEveryTime() throws {
        let well = try JSONValue(parsing: try Self.report().json)
        #expect(well.members?.map(\.key) == Self.keys)
        #expect(well["status"] == .number("0"))
        #expect(well["stops_cards"] == .array([]))
        #expect(well["pause_ends"] == .null)
        #expect(well["environment_errors"] == .array([]))
        #expect(well["config"]?.members?.map(\.key) == ["path", "exists", "valid", "ignored", "errors", "warnings"])
        #expect(well["state_directory"]?.members?.map(\.key) == ["path", "writable"])
        #expect(well["settings"]?.members?.map(\.key) == [
            "seconds", "size", "sound", "motion", "stack", "stack_max", "when_focused", "away_after", "history", "debug",
        ])
        #expect(well["settings"]?["sound"] == .null)
        #expect(well["settings"]?["seconds"] == .number("4.5"))

        let environment = try Self.environment(config: "size = \"huge\"")
        try DripPause(environment: environment).pause(until: Date().addingTimeInterval(600))
        let bad = try JSONValue(parsing: DoctorReport(environment: environment, hasGUISession: false, screenLocked: false).json)
        #expect(bad.members?.map(\.key) == Self.keys)
        #expect(bad["status"] == .number("4"))
        #expect(bad["stops_cards"] == .array([.string("no_gui_session"), .string("paused")]))
        #expect(bad["pause_ends"]?.string?.hasSuffix("Z") == true)
        #expect(bad["config"]?["valid"] == .bool(false))
        #expect(bad["config"]?["errors"]?.elements?.count == 1)
    }

    /// The docs, with each run of whitespace as one space, so a line wrap moves nothing.
    private static func doc(_ path: String) throws -> String {
        let text = try String(contentsOf: DripProcess.repo.appendingPathComponent(path), encoding: .utf8)
        return text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    }

    @Test func theDocsDescribeIt() throws {
        let contract = try Self.doc("docs/contract.md")
        #expect(contract.contains("**`drip doctor --json`.**"))
        for key in Self.keys + DoctorReport.Blocker.allCases.map(\.rawValue)
            + ["exists", "valid", "ignored", "errors", "warnings", "path", "writable"] {
            #expect(contract.contains("`\(key)`"), "docs/contract.md does not name \(key)")
        }
        let usage = try Self.doc("docs/usage.md")
        #expect(usage.contains("## Checking drip"))
        #expect(usage.contains("drip doctor [--json]"))
        #expect(usage.contains("It exits 2 for a `DRIP_*` variable drip cannot read, as a card command does, whatever else it finds. Else it exits 4 when the config file is invalid"))
        #expect(usage.contains("Else it exits 1 when something stops cards now, and 0 when all is well."))
        #expect(usage.contains("stderr gets one line for each of these, and one for an invalid config file. With `--json`, stdout is the JSON alone."))
        #expect(usage.contains("a pause (cards are held until it ends, but a question already on screen stays)"))
        #expect(usage.contains("On Linux, where drip shows no cards, it checks the config file and the variables only"))
        let troubleshooting = try Self.doc("docs/troubleshooting.md")
        #expect(troubleshooting.contains("## Run drip doctor first"))
        #expect(troubleshooting.contains("It exits 2 for a bad `DRIP_*` variable, else 4 when the config file is invalid, else 1 when something stops cards, else 0."))
        guard case let .exit(_, help) = CommandLineParser.parse(["--help"]) else { Issue.record(); return }
        #expect(help.contains("drip doctor [--json]"), "\(help)")
    }
}
#endif
