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
        config: String? = nil, extra: [String: String] = [:], gui: Bool = true, locked: Bool = false
    ) throws -> DoctorReport {
        DoctorReport(environment: try environment(config: config, extra: extra), hasGUISession: gui, screenLocked: locked)
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
        #expect(report.failures.isEmpty)
        #expect(!report.configExists)
        #expect(report.version == dripVersion)
        let text = report.text()
        #expect(text.hasPrefix("drip \(dripVersion)\nGUI session: yes\npaused: no\nscreen locked: no\n"), "\(text)")
        #expect(text.contains("(not found, so drip uses the defaults)"), "\(text)")
        #expect(text.contains("state directory: \(report.stateDirectory)"), "\(text)")
        #expect(text.hasSuffix("\ncards show now"), "\(text)")
    }

    @Test func eachThingThatStopsCardsExitsOne() throws {
        let away = try Self.report(gui: false)
        #expect(away.blockers == [.noGUISession])
        #expect(away.status == ExitStatus.failed)
        #expect(away.text().hasSuffix("\nstops cards: \(DoctorReport.Blocker.noGUISession.explanation)"))
        #expect(away.failures == [DoctorReport.Blocker.noGUISession.explanation])

        let locked = try Self.report(locked: true)
        #expect(locked.blockers == [.screenLocked])
        #expect(locked.status == ExitStatus.failed)
        #expect(locked.text().contains("screen locked: yes"))

        let environment = try Self.environment()
        try DripPause(environment: environment).pause(until: Date().addingTimeInterval(1800))
        let paused = DoctorReport(environment: environment, hasGUISession: true, screenLocked: true)
        #expect(paused.blockers == [.paused, .screenLocked])
        #expect(paused.status == ExitStatus.failed)
        let text = paused.text()
        #expect(text.contains("paused: yes, until "), "\(text)")
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
        #expect(report.failures.first == "invalid config: 2 problems in \(report.configPath)")
        // The bad keys keep their defaults, as a card command would use them.
        #expect(report.settings.size == Defaults.size)
        #expect(report.settings.seconds == Defaults.seconds)

        let unusable = try Self.report(config: "broken = [")
        #expect(unusable.status == ExitStatus.invalidConfig)
        #expect(unusable.configProblems.count == 1)

        let warned = try Self.report(config: "bogus = 1\n")
        #expect(warned.status == ExitStatus.shown)
        #expect(warned.configProblems.isEmpty)
        #expect(warned.text().contains("(valid)"))
    }

    @Test func aBadVariableIsAUsageError() throws {
        let report = try Self.report(config: "size = \"huge\"", extra: ["DRIP_SECONDS": "soon"])
        #expect(report.status == ExitStatus.usage)
        #expect(report.environmentProblem?.contains("DRIP_SECONDS") == true)
        #expect(report.failures.first == report.environmentProblem)
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
        "version", "status", "stops_cards", "gui_session", "paused", "pause_ends", "screen_locked", "config",
        "environment_error", "settings", "state_directory",
    ]

    @Test func jsonHasEveryKeyEveryTime() throws {
        let well = try JSONValue(parsing: try Self.report().json)
        #expect(well.members?.map(\.key) == Self.keys)
        #expect(well["status"] == .number("0"))
        #expect(well["stops_cards"] == .array([]))
        #expect(well["pause_ends"] == .null)
        #expect(well["environment_error"] == .null)
        #expect(well["config"]?.members?.map(\.key) == ["path", "exists", "valid", "errors", "warnings"])
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
        for key in Self.keys + ["no_gui_session", "screen_locked", "exists", "valid", "errors", "warnings"] {
            #expect(contract.contains("`\(key)`"), "docs/contract.md does not name \(key)")
        }
        let usage = try Self.doc("docs/usage.md")
        #expect(usage.contains("## Checking drip"))
        #expect(usage.contains("drip doctor [--json]"))
        #expect(usage.contains("It exits 0 when all is well and 1 when something stops cards now. It exits 4 when the config file is invalid"))
        let troubleshooting = try Self.doc("docs/troubleshooting.md")
        #expect(troubleshooting.contains("## Run drip doctor first"))
        #expect(troubleshooting.contains("It exits 0 when all is well, 1 when something stops cards, and 4 when the config file is invalid."))
        guard case let .exit(_, help) = CommandLineParser.parse(["--help"]) else { Issue.record(); return }
        #expect(help.contains("drip doctor [--json]"), "\(help)")
    }
}
#endif
