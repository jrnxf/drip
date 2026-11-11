#if !os(WASI) // Only the macOS and Linux drip run `drip doctor`.
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What `drip doctor` reports: what stops cards now, the config file and its problems, the settings
/// drip uses and where it keeps its state. The GUI session and the screen lock come from the caller,
/// which reads them the way the cards do.
public struct DoctorReport: Equatable {
    /// Something that keeps a card off the screen now.
    public enum Blocker: String, CaseIterable, Sendable {
        /// A `DRIP_*` variable drip cannot read: every card command exits 2.
        case badVariable = "bad_variable"
        /// No logged-in macOS desktop, as over ssh: a card exits 3.
        case noGUISession = "no_gui_session"
        /// `drip pause` holds cards until it ends.
        case paused
        /// Cards wait for the unlock.
        case screenLocked = "screen_locked"

        /// The line the report ends with for it.
        public var explanation: String {
            switch self {
            case .badVariable:
                return "a DRIP_* variable drip cannot read: every card command exits 2 until you fix or unset it"
            case .noGUISession: return "no GUI session: cards need a logged-in macOS desktop (for example, not over ssh)"
            case .paused:
                return "drip is paused: cards are held until the pause ends, but a question already on screen "
                    + "stays (drip resume ends the pause now)"
            case .screenLocked: return "the screen is locked: cards wait for the unlock"
            }
        }
    }

    /// The settings a card starts from, after `DRIP_*` variables and the config file, read by the code
    /// the cards use.
    public struct Settings: Equatable {
        public var seconds: Double
        public var size: CardSize
        /// The sound of every card; nil when each preset plays its own.
        public var sound: Sound?
        /// The presets that keep the sound the config gives them over `sound`, by name.
        public var presetsWithOwnSound: [String]
        public var motion: Motion
        public var stack: StackSettings.Choice
        public var stackMax: Int
        public var whenFocused: WhenFocused
        public var awayAfter: Double
        public var history: Int
        public var debug: Bool

        /// The settings of `resolver`, for a card whose preset sets none of its own, and the debug log's
        /// switch, which reads `environment` and `file` itself.
        public init(resolver: CardResolver, environment: [String: String], file: ConfigFile) {
            seconds = resolver.seconds(for: nil)
            size = resolver.size
            sound = resolver.sound
            presetsWithOwnSound = resolver.sound == nil ? []
                : resolver.presets.values.filter(resolver.keepsOwnSound).map(\.name).sorted()
            motion = resolver.motion
            stack = StackSettings.choice(resolver.environment, config: resolver.config)
            stackMax = StackSettings.maxCards(resolver.environment, config: resolver.config)
            whenFocused = resolver.whenFocused
            awayAfter = resolver.awayAfter
            history = resolver.historyLimit
            debug = DebugLog.isEnabled(environment: environment) { file }
        }
    }

    public var version: String
    /// When the report was made: the one clock for the pause and its time left.
    public var now: Date
    /// Whether this drip shows cards at all: false on Linux, where an agent's hooks run
    /// `drip-remote-hook` and `drip follow` on the Mac shows the cards.
    public var showsCards: Bool
    public var hasGUISession: Bool
    /// When the pause ends; nil when drip is not paused.
    public var pauseEnd: Date?
    public var screenLocked: Bool
    public var configPath: String
    /// Whether the config file is there; without it every setting is the default.
    public var configExists: Bool
    /// Every problem in the config file, in file order: each key keeps its default.
    public var configProblems: [String]
    /// Whether drip ignores the whole file, as for a TOML syntax error, a file over 1 MB or one that is
    /// not UTF-8: every key keeps its default.
    public var configIgnored: Bool
    /// The config file's other warnings, such as unknown keys, which do not make it invalid.
    public var configWarnings: [String]
    /// Each `DRIP_*` variable drip cannot read, by name: a card command exits 2 for the first.
    public var environmentProblems: [String]
    public var settings: Settings
    public var stateDirectory: String
    /// Whether drip can write the state directory, or create it. Without it drip keeps no history,
    /// pause or debug log, but cards still show.
    public var stateDirectoryWritable: Bool

    /// Reads the config file, the environment, the pause and the state directory. `hasGUISession`
    /// and `screenLocked` are what the cards go by, and `showsCards` is false where drip shows no cards.
    public init(
        environment: [String: String], hasGUISession: Bool, screenLocked: Bool, showsCards: Bool = true,
        now: Date = Date()
    ) {
        version = dripVersion
        self.now = now
        self.showsCards = showsCards
        self.hasGUISession = hasGUISession
        self.screenLocked = screenLocked
        pauseEnd = DripPause(environment: environment).end(now: now)
        configPath = ConfigLoader.path(environment: environment)
        // One read, as a card command reads the file: the lenient parse lists every problem, and a
        // strict parse would throw the first of them, so the file is valid when there is none.
        let read = ConfigLoader.loadLeniently(path: configPath)
        let file = read ?? ConfigFile(config: Config(), warnings: [])
        configExists = read != nil
        configProblems = file.problems.map(\.description)
        configIgnored = file.problems.contains { $0.key == nil }
        let problemWarnings = Set(file.problems.map(ConfigLoader.warning))
        configWarnings = file.warnings.filter { !problemWarnings.contains($0) }
        let (variables, problems) = EnvironmentSettings.leniently(environment)
        environmentProblems = problems
        settings = Settings(
            resolver: CardResolver(config: file.config, environment: variables), environment: environment,
            file: file)
        stateDirectory = StateDirectory.path(environment: environment)
        stateDirectoryWritable = Self.canWrite(directory: stateDirectory)
    }

    /// Whether `directory`, or the nearest folder above it that is there, takes new files.
    private static func canWrite(directory: String) -> Bool {
        var path = directory
        var isDirectory: ObjCBool = false
        while !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return false }
            path = parent
        }
        return isDirectory.boolValue && access(path, W_OK | X_OK) == 0
    }

    /// What keeps cards off the screen now, most serious first. Where drip shows no cards, only a bad
    /// variable counts.
    public var blockers: [Blocker] {
        let found = [
            (!environmentProblems.isEmpty, Blocker.badVariable), (!hasGUISession, .noGUISession),
            (pauseEnd != nil, .paused), (screenLocked, .screenLocked),
        ].filter(\.0).map(\.1)
        return showsCards ? found : found.filter { $0 == .badVariable }
    }

    /// 2 for a `DRIP_*` variable drip cannot read, else 4 for an invalid config file, else 1 when
    /// something stops cards, else 0.
    public var status: Int32 {
        if !environmentProblems.isEmpty { return ExitStatus.usage }
        if !configProblems.isEmpty { return ExitStatus.invalidConfig }
        if !blockers.isEmpty { return ExitStatus.failed }
        return ExitStatus.shown
    }

    /// What goes to stderr: one `drip:` line for each cause. The bad variables come first, then where
    /// the help is, as for any usage error, then the invalid config file and the rest. Nil when all is
    /// well.
    public var standardError: String? {
        var lines: [String] = []
        if !environmentProblems.isEmpty {
            lines.append(CommandLineParser.usageMessage(
                environmentProblems.joined(separator: "\ndrip: "), subcommand: DoctorCommand.configuration.commandName))
        }
        if !configProblems.isEmpty {
            let count = configProblems.count
            lines.append("drip: invalid config: \(count) problem\(count == 1 ? "" : "s") in \(configPath)")
        }
        lines += blockers.filter { $0 != .badVariable }.map { "drip: " + $0.explanation }
        guard !lines.isEmpty else { return nil }
        return CardText.printable(lines.joined(separator: "\n"))
    }

    /// The report for a terminal: a line for each item, then what stops cards, if anything. Text from
    /// the config file and the environment is made printable, a line break too.
    public func text(timeZone: TimeZone = .current) -> String {
        func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
        func shown(_ text: String) -> String {
            CardText.printable(text).split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\\n")
        }
        var lines = [
            "drip \(version)",
            "GUI session: \(yesNo(hasGUISession))",
            "paused: " + (pauseEnd.map { "yes, " + DripPause.timeLeft(end: $0, now: now, timeZone: timeZone) } ?? "no"),
            "screen locked: \(yesNo(screenLocked))",
        ]
        let state = !configExists ? "not found, so drip uses the defaults"
            : configProblems.isEmpty ? "valid"
            : configIgnored ? "invalid, so drip ignores the whole file and uses the defaults"
            : "invalid, each bad key keeps its default"
        lines.append("config: \(shown(configPath)) (\(state))")
        lines += configProblems.map { "  error: \(shown($0))" }
        lines += configWarnings.map { "  warning: \(shown($0))" }
        lines += environmentProblems.map { "environment: \(shown($0))" }
        lines.append("settings:")
        lines += settingFields.map { "  \($0.key) = \(shown($0.text))" }
        let writable = stateDirectoryWritable ? "writable"
            : "not writable, so drip keeps no history, pause or debug log, but cards still show"
        lines.append("state directory: \(shown(stateDirectory)) (\(writable))")
        let blockers = blockers
        if !blockers.isEmpty {
            lines += blockers.map { "stops cards: \($0.explanation)" }
        } else if showsCards {
            lines.append("cards show now")
        } else {
            lines.append(
                "cards show only on macOS: here an agent's hooks run drip-remote-hook, and drip follow on the "
                    + "Mac shows the cards")
        }
        return lines.joined(separator: "\n")
    }

    /// `glass`, with the presets that keep a sound of their own after it, or `each preset's own`.
    private var soundText: String {
        guard let sound = settings.sound else { return "each preset's own" }
        let own = settings.presetsWithOwnSound
        guard !own.isEmpty else { return sound.argument }
        return "\(sound.argument) (\(own.joined(separator: ", ")) keep\(own.count == 1 ? "s" : "") \(own.count == 1 ? "its" : "their") own)"
    }

    /// The settings by the config file's key, as the report and its JSON give them.
    private var settingFields: [(key: String, text: String, json: JSONValue)] {
        [
            ("seconds", Defaults.number(settings.seconds), .number(Defaults.number(settings.seconds))),
            ("size", settings.size.rawValue, .string(settings.size.rawValue)),
            ("sound", soundText, settings.sound.map { .string($0.argument) } ?? .null),
            ("motion", settings.motion.rawValue, .string(settings.motion.rawValue)),
            ("stack", settings.stack.rawValue, .string(settings.stack.rawValue)),
            ("stack_max", "\(settings.stackMax)", .number("\(settings.stackMax)")),
            ("when_focused", settings.whenFocused.rawValue, .string(settings.whenFocused.rawValue)),
            ("away_after", Defaults.number(settings.awayAfter), .number(Defaults.number(settings.awayAfter))),
            ("history", "\(settings.history)", .number("\(settings.history)")),
            ("debug", settings.debug ? "true" : "false", .bool(settings.debug)),
        ]
    }

    /// The report as one JSON object, indented. Every key is always there, null when it has no value, and
    /// new keys can come in any release.
    public var json: String {
        let end = pauseEnd.map { date -> JSONValue in
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(identifier: "UTC")
            return .string(formatter.string(from: date))
        } ?? .null
        let value = JSONValue.object([
            JSONMember("version", .string(version)),
            JSONMember("status", .number("\(status)")),
            JSONMember("stops_cards", .array(blockers.map { .string($0.rawValue) })),
            JSONMember("shows_cards", .bool(showsCards)),
            JSONMember("gui_session", .bool(hasGUISession)),
            JSONMember("paused", .bool(pauseEnd != nil)),
            JSONMember("pause_ends", end),
            JSONMember("screen_locked", .bool(screenLocked)),
            JSONMember("config", .object([
                JSONMember("path", .string(configPath)),
                JSONMember("exists", .bool(configExists)),
                JSONMember("valid", .bool(configProblems.isEmpty)),
                JSONMember("ignored", .bool(configIgnored)),
                JSONMember("errors", .array(configProblems.map(JSONValue.string))),
                JSONMember("warnings", .array(configWarnings.map(JSONValue.string))),
            ])),
            JSONMember("environment_errors", .array(environmentProblems.map(JSONValue.string))),
            JSONMember("settings", .object(settingFields.map { JSONMember($0.key, $0.json) })),
            JSONMember("state_directory", .object([
                JSONMember("path", .string(stateDirectory)),
                JSONMember("writable", .bool(stateDirectoryWritable)),
            ])),
        ])
        return value.formatted()
    }
}
#endif
