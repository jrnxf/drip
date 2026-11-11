#if !os(WASI) // Only the macOS and Linux drip run `drip doctor`.
import Foundation

/// What `drip doctor` reports: what stops cards now, the config file and its problems, the settings
/// drip uses and where it keeps its state. The GUI session and the screen lock come from the caller,
/// which reads them the way the cards do.
public struct DoctorReport: Equatable {
    /// Something that keeps a card off the screen now.
    public enum Blocker: String, CaseIterable, Sendable {
        /// No logged-in macOS desktop, as over ssh: a card exits 3.
        case noGUISession = "no_gui_session"
        /// `drip pause` holds cards until it ends.
        case paused
        /// Cards wait for the unlock.
        case screenLocked = "screen_locked"

        /// The line the report ends with for it.
        public var explanation: String {
            switch self {
            case .noGUISession: return "no GUI session: cards need a logged-in macOS desktop (for example, not over ssh)"
            case .paused: return "drip is paused: cards are held until the pause ends (drip resume ends it now)"
            case .screenLocked: return "the screen is locked: cards wait for the unlock"
            }
        }
    }

    /// The settings a card starts from, after `DRIP_*` variables and the config file.
    public struct Settings: Equatable {
        public var seconds: Double
        public var size: CardSize
        /// The sound of every card; nil when each preset plays its own.
        public var sound: Sound?
        public var motion: Motion
        public var stack: StackSettings.Choice
        public var stackMax: Int
        public var whenFocused: WhenFocused
        public var awayAfter: Double
        public var history: Int
        public var debug: Bool

        public init(config: Config, environment: EnvironmentSettings) {
            let resolver = CardResolver(config: config, environment: environment)
            seconds = environment.seconds ?? config.seconds ?? Defaults.seconds
            size = environment.size ?? config.size ?? Defaults.size
            sound = environment.sound ?? config.sound
            motion = environment.motion ?? config.motion ?? Defaults.motion
            stack = environment.stack ?? config.stack ?? .chain
            stackMax = environment.stackMax ?? config.stackMax ?? Defaults.stackMax
            whenFocused = resolver.whenFocused
            awayAfter = resolver.awayAfter
            history = resolver.historyLimit
            debug = environment.debug ?? config.debug ?? false
        }
    }

    public var version: String
    public var hasGUISession: Bool
    /// When the pause ends; nil when drip is not paused.
    public var pauseEnd: Date?
    public var screenLocked: Bool
    public var configPath: String
    /// Whether the config file is there; without it every setting is the default.
    public var configExists: Bool
    /// Every problem in the config file, in file order: each key keeps its default.
    public var configProblems: [String]
    /// The config file's other warnings, such as unknown keys, which do not make it invalid.
    public var configWarnings: [String]
    /// The `DRIP_*` variable drip cannot read, if any: a card command exits 2 for it.
    public var environmentProblem: String?
    public var settings: Settings
    public var stateDirectory: String

    /// Reads the config file, the environment and the pause. `hasGUISession` and `screenLocked` are
    /// what the cards go by.
    public init(environment: [String: String], hasGUISession: Bool, screenLocked: Bool, now: Date = Date()) {
        version = dripVersion
        self.hasGUISession = hasGUISession
        self.screenLocked = screenLocked
        pauseEnd = DripPause(environment: environment).end(now: now)
        configPath = ConfigLoader.path(environment: environment)
        configExists = FileManager.default.fileExists(atPath: configPath)
        // The strict load says whether the file is valid; the lenient one lists every problem and
        // gives the settings a card command would use.
        let file = ConfigLoader.loadLeniently(environment: environment)
        var problems = file.problems.map(\.description)
        do {
            _ = try ConfigLoader.load(environment: environment)
        } catch {
            if problems.isEmpty { problems = ["\(error)"] }
        }
        configProblems = problems
        let problemWarnings = Set(file.problems.map(ConfigLoader.warning))
        configWarnings = file.warnings.filter { !problemWarnings.contains($0) }
        let variables: EnvironmentSettings
        do {
            variables = try EnvironmentSettings(environment: environment)
        } catch {
            environmentProblem = "\(error)"
            variables = EnvironmentSettings()
        }
        settings = Settings(config: file.config, environment: variables)
        stateDirectory = StateDirectory.path(environment: environment)
    }

    /// What keeps cards off the screen now, most serious first.
    public var blockers: [Blocker] {
        [(!hasGUISession, Blocker.noGUISession), (pauseEnd != nil, .paused), (screenLocked, .screenLocked)]
            .filter(\.0).map(\.1)
    }

    /// 2 for a `DRIP_*` variable drip cannot read, else 4 for an invalid config file, else 1 when
    /// something stops cards, else 0.
    public var status: Int32 {
        if environmentProblem != nil { return ExitStatus.usage }
        if !configProblems.isEmpty { return ExitStatus.invalidConfig }
        if !blockers.isEmpty { return ExitStatus.failed }
        return ExitStatus.shown
    }

    /// What is wrong, one line each, for stderr; empty when all is well.
    public var failures: [String] {
        var lines: [String] = []
        if let environmentProblem { lines.append(environmentProblem) }
        if !configProblems.isEmpty {
            let count = configProblems.count
            lines.append("invalid config: \(count) problem\(count == 1 ? "" : "s") in \(configPath)")
        }
        return lines + blockers.map(\.explanation)
    }

    /// The report for a terminal: a line for each item, then what stops cards, if anything.
    public func text(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
        var lines = [
            "drip \(version)",
            "GUI session: \(yesNo(hasGUISession))",
            "paused: \(paused(now: now, timeZone: timeZone))",
            "screen locked: \(yesNo(screenLocked))",
        ]
        let state = !configExists ? "not found, so drip uses the defaults"
            : configProblems.isEmpty ? "valid" : "invalid, each bad key keeps its default"
        lines.append("config: \(configPath) (\(state))")
        lines += configProblems.map { "  error: \($0)" }
        lines += configWarnings.map { "  warning: \($0)" }
        if let environmentProblem { lines.append("environment: \(environmentProblem)") }
        lines.append("settings:")
        lines += settingFields.map { "  \($0.key) = \($0.text)" }
        lines.append("state directory: \(stateDirectory)")
        let blockers = blockers
        lines += blockers.isEmpty ? ["cards show now"] : blockers.map { "stops cards: \($0.explanation)" }
        return lines.joined(separator: "\n")
    }

    /// `no`, or `yes, until 15:42 (1h left)`.
    private func paused(now: Date, timeZone: TimeZone) -> String {
        guard let pauseEnd else { return "no" }
        let status = DripPause.status(end: pauseEnd, now: now, timeZone: timeZone)
        return "yes, " + String(status.dropFirst("drip is paused ".count))
    }

    /// The settings by the config file's key, as the report and its JSON give them.
    private var settingFields: [(key: String, text: String, json: JSONValue)] {
        [
            ("seconds", Defaults.number(settings.seconds), .number(Defaults.number(settings.seconds))),
            ("size", settings.size.rawValue, .string(settings.size.rawValue)),
            ("sound", settings.sound?.argument ?? "each preset's own", settings.sound.map { .string($0.argument) } ?? .null),
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
            JSONMember("gui_session", .bool(hasGUISession)),
            JSONMember("paused", .bool(pauseEnd != nil)),
            JSONMember("pause_ends", end),
            JSONMember("screen_locked", .bool(screenLocked)),
            JSONMember("config", .object([
                JSONMember("path", .string(configPath)),
                JSONMember("exists", .bool(configExists)),
                JSONMember("valid", .bool(configProblems.isEmpty)),
                JSONMember("errors", .array(configProblems.map(JSONValue.string))),
                JSONMember("warnings", .array(configWarnings.map(JSONValue.string))),
            ])),
            JSONMember("environment_error", environmentProblem.map(JSONValue.string) ?? .null),
            JSONMember("settings", .object(settingFields.map { JSONMember($0.key, $0.json) })),
            JSONMember("state_directory", .string(stateDirectory)),
        ])
        return value.formatted()
    }
}
#endif
