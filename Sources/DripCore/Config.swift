#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif

/// Changes a config file makes to one preset; nil where it keeps the preset's value.
public struct PresetOverride: Equatable {
    public var icon: Icon?
    public var color: CardColor?
    public var sound: Sound?
    public var seconds: Double?

    public init(icon: Icon? = nil, color: CardColor? = nil, sound: Sound? = nil, seconds: Double? = nil) {
        self.icon = icon
        self.color = color
        self.sound = sound
        self.seconds = seconds
    }
}

/// The settings from config.toml; nil where the file does not set a key.
public struct Config: Equatable {
    public var seconds: Double?
    public var size: CardSize?
    /// The sound of every preset that sets none of its own; `none` mutes every preset.
    public var sound: Sound?
    public var motion: Motion?
    /// How cards stack, or off.
    public var stack: StackSettings.Choice?
    /// The most cards on screen at once.
    public var stackMax: Int?
    /// What an agent's card does while its terminal is in front.
    public var whenFocused: WhenFocused?
    /// Seconds without the keyboard or mouse after which drip takes you to be away from the screen.
    public var awayAfter: Double?
    /// Which of an agent's cards show.
    public var agentCards: AgentHook.Cards?
    /// The shortest turn, in seconds, whose done card shows.
    public var doneAfter: Double?
    /// Whether drip keeps its debug log, `DebugLog`.
    public var debug: Bool?
    /// Overrides of built-in presets, and custom presets, by name.
    public var presets: [String: PresetOverride]

    public init(
        seconds: Double? = nil, size: CardSize? = nil, sound: Sound? = nil, motion: Motion? = nil,
        stack: StackSettings.Choice? = nil, stackMax: Int? = nil, whenFocused: WhenFocused? = nil,
        awayAfter: Double? = nil, agentCards: AgentHook.Cards? = nil, doneAfter: Double? = nil,
        debug: Bool? = nil, presets: [String: PresetOverride] = [:]
    ) {
        self.debug = debug
        self.awayAfter = awayAfter
        self.agentCards = agentCards
        self.doneAfter = doneAfter
        self.seconds = seconds
        self.size = size
        self.sound = sound
        self.motion = motion
        self.stack = stack
        self.stackMax = stackMax
        self.whenFocused = whenFocused
        self.presets = presets
    }

    /// The built-in presets with their overrides applied, plus the custom presets. A custom preset
    /// starts from `info` and replaces what it sets.
    public var allPresets: [Preset] {
        let builtInNames = Set(Preset.builtIn.map(\.name))
        let custom = presets.keys.filter { !builtInNames.contains($0) }.sorted().map { name in
            Preset(name: name, icon: Preset.info.icon, color: Preset.info.color, sound: Preset.info.sound)
        }
        return (Preset.builtIn + custom).map { preset in
            guard let change = presets[preset.name] else { return preset }
            var preset = preset
            preset.icon = change.icon ?? preset.icon
            preset.color = change.color ?? preset.color
            preset.sound = change.sound ?? preset.sound
            preset.seconds = change.seconds ?? preset.seconds
            return preset
        }
    }
}

/// An invalid config file. drip exits 4 with this message.
public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public var path: String
    public var line: Int?
    public var key: String?
    public var message: String

    public init(path: String, line: Int?, key: String?, message: String) {
        self.path = path
        self.line = line
        self.key = key
        self.message = message
    }

    public var description: String {
        let location = line.map { "\(path):\($0)" } ?? path
        return "\(location): \(key.map { "\($0): " } ?? "")\(message)"
    }
}

/// A loaded config and the warnings it produced, such as unknown keys.
public struct ConfigFile: Equatable {
    public var config: Config
    public var warnings: [String]

    public init(config: Config, warnings: [String]) {
        self.config = config
        self.warnings = warnings
    }
}

public enum ConfigLoader {
    /// `$XDG_CONFIG_HOME/drip/config.toml`, falling back to `~/.config/drip/config.toml`.
    public static func path(environment: [String: String]) -> String {
        let base: String
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            base = xdg
        } else {
            let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            base = (home as NSString).appendingPathComponent(".config")
        }
        return ((base as NSString).appendingPathComponent("drip") as NSString).appendingPathComponent("config.toml")
    }

    /// The largest config file drip reads. A real one is a few hundred bytes.
    public static let sizeLimit = 1024 * 1024

    /// Loads the config file; a missing file is an empty config.
    public static func load(environment: [String: String]) throws -> ConfigFile {
        let path = path(environment: environment)
        guard FileManager.default.fileExists(atPath: path) else {
            return ConfigFile(config: Config(), warnings: [])
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > sizeLimit {
            throw ConfigError(path: path, line: nil, key: nil, message: "the file is larger than 1 MB")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ConfigError(path: path, line: nil, key: nil, message: "cannot read the file")
        }
        // WebAssembly's file system cannot tell a file's size before it is read.
        if data.count > sizeLimit {
            throw ConfigError(path: path, line: nil, key: nil, message: "the file is larger than 1 MB")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigError(path: path, line: nil, key: nil, message: "the file is not UTF-8")
        }
        return try parse(text, path: path)
    }

    /// Parses config.toml. Unknown keys are warnings; wrong types and invalid values are
    /// errors.
    public static func parse(_ text: String, path: String) throws -> ConfigFile {
        var reader = ConfigReader(path: path)
        let table: TOMLTable
        do {
            table = try TOML.parse(text)
        } catch let error as TOMLError {
            throw ConfigError(path: path, line: error.line, key: nil, message: error.message)
        }
        let config = try reader.read(table)
        return ConfigFile(config: config, warnings: reader.warnings)
    }
}

private struct ConfigReader {
    let path: String
    var warnings: [String] = []

    init(path: String) {
        self.path = path
    }

    mutating func read(_ table: TOMLTable) throws -> Config {
        var config = Config()
        for key in table.keys {
            guard let item = table[key] else { continue }
            switch key {
            case "seconds": config.seconds = try seconds(item, key: key)
            case "size": config.size = try choice(item, key: key, CardSize.self)
            case "sound": config.sound = try sound(item, key: key)
            case "motion": config.motion = try choice(item, key: key, Motion.self)
            case "stack": config.stack = try choice(item, key: key, StackSettings.Choice.self)
            case "stack_max":
                guard case let .integer(value) = item.value else { throw wrongType(item, key: key, expected: "a whole number") }
                guard Defaults.stackMaxRange.contains(Int(clamping: value)) else {
                    throw ConfigError(path: path, line: item.line, key: key, message: "must be between 1 and 6")
                }
                config.stackMax = Int(value)
            case "when_focused": config.whenFocused = try choice(item, key: key, WhenFocused.self)
            case "away_after": config.awayAfter = try seconds(item, key: key, in: Defaults.awayAfterRange)
            case "agent_cards": config.agentCards = try choice(item, key: key, AgentHook.Cards.self)
            case "done_after": config.doneAfter = try seconds(item, key: key, in: Defaults.doneAfterRange)
            case "debug": config.debug = try boolean(item, key: key)
            case "preset": config.presets = try presets(item)
            default: warnUnknown(key, line: item.line)
            }
        }
        return config
    }

    private mutating func presets(_ item: TOMLItem) throws -> [String: PresetOverride] {
        guard case let .table(table) = item.value else {
            throw wrongType(item, key: "preset", expected: "a table")
        }
        let builtInNames = Set(Preset.builtIn.map(\.name))
        var presets: [String: PresetOverride] = [:]
        for name in table.keys {
            guard let presetItem = table[name] else { continue }
            let key = "preset.\(name)"
            guard case let .table(fields) = presetItem.value else {
                throw wrongType(presetItem, key: key, expected: "a table")
            }
            if !builtInNames.contains(name) {
                if Self.reservedNames.contains(name) {
                    throw ConfigError(
                        path: path, line: presetItem.line, key: key,
                        message: "'\(name)' is kept for drip's own commands; give the preset another name")
                }
                if !Self.isValidPresetName(name) {
                    throw ConfigError(
                        path: path, line: presetItem.line, key: key,
                        message: "a custom preset name must match [a-z][a-z0-9-]*")
                }
            }
            presets[name] = try preset(fields, key: key)
        }
        return presets
    }

    private mutating func preset(_ table: TOMLTable, key presetKey: String) throws -> PresetOverride {
        var preset = PresetOverride()
        for field in table.keys {
            guard let item = table[field] else { continue }
            let key = "\(presetKey).\(field)"
            switch field {
            case "icon":
                let icon = Icon(parsing: try string(item, key: key))
                if let problem = icon.problem {
                    throw ConfigError(path: path, line: item.line, key: key, message: problem)
                }
                // A relative image path is taken from the config file's own directory.
                preset.icon = icon.resolved(from: (path as NSString).deletingLastPathComponent)
            case "color":
                let text = try string(item, key: key)
                guard let color = CardColor(parsing: text) else {
                    throw ConfigError(
                        path: path, line: item.line, key: key,
                        message: "expected #rrggbb or one of \(Self.list(SystemColor.allCases.map(\.rawValue))), got '\(text)'")
                }
                preset.color = color
            case "sound":
                preset.sound = try sound(item, key: key)
            case "seconds":
                preset.seconds = try seconds(item, key: key)
            default:
                warnUnknown(key, line: item.line)
            }
        }
        return preset
    }

    /// The names a custom preset cannot take: drip's subcommands, and those it may have one day,
    /// since `drip <name>` would run the subcommand instead.
    static let reservedNames: Set<String> = [
        "run", "hook", "history", "show", "help", "version", "setup", "config", "init", "install",
        "uninstall", "completion", "completions", "doctor", "mute", "pause", "resume", "listen",
        "test", "dismiss", "clear", "debug",
    ]

    static func isValidPresetName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// A sound name or path, `"none"`, or false, which is none; true keeps the preset's sound.
    private func sound(_ item: TOMLItem, key: String) throws -> Sound? {
        switch item.value {
        case let .string(text): return Sound(parsing: text)
        case .boolean(false): return Sound.none
        case .boolean(true): return nil
        default: throw wrongType(item, key: key, expected: "a sound name, a path, \"none\" or false")
        }
    }

    private func seconds(
        _ item: TOMLItem, key: String, in range: ClosedRange<Double> = Defaults.secondsRange
    ) throws -> Double {
        let value: Double
        switch item.value {
        case let .integer(integer): value = Double(integer)
        case let .float(float): value = float
        default: throw wrongType(item, key: key, expected: "a number")
        }
        guard range.contains(value) else {
            throw ConfigError(
                path: path, line: item.line, key: key,
                message: "must be between \(Defaults.number(range.lowerBound)) and \(Defaults.number(range.upperBound))")
        }
        return value
    }

    private func choice<Choice: RawRepresentable & CaseIterable>(
        _ item: TOMLItem, key: String, _: Choice.Type
    ) throws -> Choice where Choice.RawValue == String {
        let text = try string(item, key: key)
        guard let choice = Choice(rawValue: text) else {
            throw ConfigError(
                path: path, line: item.line, key: key,
                message: "expected \(Self.list(Choice.allCases.map(\.rawValue))), got '\(text)'")
        }
        return choice
    }

    private func string(_ item: TOMLItem, key: String) throws -> String {
        guard case let .string(text) = item.value else { throw wrongType(item, key: key, expected: "a string") }
        return text
    }

    private func boolean(_ item: TOMLItem, key: String) throws -> Bool {
        guard case let .boolean(value) = item.value else { throw wrongType(item, key: key, expected: "true or false") }
        return value
    }

    private func wrongType(_ item: TOMLItem, key: String, expected: String) -> ConfigError {
        ConfigError(path: path, line: item.line, key: key, message: "expected \(expected), got \(item.value.typeName)")
    }

    private mutating func warnUnknown(_ key: String, line: Int) {
        warnings.append("\(path):\(line): unknown key '\(key)'")
    }

    private static func list(_ items: [String]) -> String {
        ChoiceList.or(items)
    }
}

/// Lists choices in messages and help.
public enum ChoiceList {
    /// `a, b or c`.
    public static func or(_ items: [String]) -> String {
        guard items.count > 1 else { return items.joined() }
        return items.dropLast().joined(separator: ", ") + " or " + items[items.count - 1]
    }
}

/// The DRIP_* environment variables, which override the config file.
public struct EnvironmentSettings: Equatable {
    public var seconds: Double?
    public var size: CardSize?
    public var sound: Sound?
    public var motion: Motion?
    /// How cards stack, or off.
    public var stack: StackSettings.Choice?
    /// The most cards on screen at once.
    public var stackMax: Int?
    /// What an agent's card does while its terminal is in front.
    public var whenFocused: WhenFocused?
    /// Seconds without the keyboard or mouse after which drip takes you to be away from the screen.
    public var awayAfter: Double?
    /// Which of an agent's cards show.
    public var agentCards: AgentHook.Cards?
    /// The shortest turn, in seconds, whose done card shows.
    public var doneAfter: Double?
    /// The bundle identifier of the app drip was run from, from `__CFBundleIdentifier`.
    public var sender: String?
    /// The terminal pane drip was run in, from `TMUX` and `TMUX_PANE`, herdr's `HERDR_PANE_ID`, or
    /// `WEZTERM_PANE`.
    public var pane: TerminalPane?
    /// Whether the debug log is on, from `DRIP_DEBUG`.
    public var debug: Bool?

    public init(
        seconds: Double? = nil, size: CardSize? = nil, sound: Sound? = nil, motion: Motion? = nil,
        stack: StackSettings.Choice? = nil, stackMax: Int? = nil, whenFocused: WhenFocused? = nil,
        awayAfter: Double? = nil, agentCards: AgentHook.Cards? = nil, doneAfter: Double? = nil,
        sender: String? = nil, debug: Bool? = nil
    ) {
        self.debug = debug
        self.awayAfter = awayAfter
        self.agentCards = agentCards
        self.doneAfter = doneAfter
        self.sender = sender
        self.whenFocused = whenFocused
        self.stack = stack
        self.stackMax = stackMax
        self.seconds = seconds
        self.size = size
        self.sound = sound
        self.motion = motion
    }

    /// Reads DRIP_SECONDS, DRIP_SIZE, DRIP_SOUND, DRIP_MOTION, DRIP_STACK, DRIP_STACK_MAX,
    /// DRIP_WHEN_FOCUSED, DRIP_AWAY_AFTER, DRIP_AGENT_CARDS, DRIP_DONE_AFTER and DRIP_DEBUG. Empty
    /// values are ignored; invalid ones are usage errors. Also notes the app drip was run from, from
    /// `__CFBundleIdentifier`, ignoring a value that is not a bundle identifier.
    public init(environment: [String: String]) throws {
        func value(_ name: String) -> String? {
            environment[name].flatMap { $0.isEmpty ? nil : $0 }
        }
        if let text = value("DRIP_SECONDS") {
            guard let seconds = Double(text), Defaults.secondsRange.contains(seconds) else {
                throw UsageError("DRIP_SECONDS must be a number between 0.5 and 60, not '\(text)'")
            }
            self.seconds = seconds
        }
        func choice<Choice: RawRepresentable & CaseIterable>(_ name: String, _: Choice.Type) throws -> Choice?
        where Choice.RawValue == String {
            guard let text = value(name) else { return nil }
            guard let choice = Choice(rawValue: text) else {
                throw UsageError("\(name) must be \(ChoiceList.or(Choice.allCases.map(\.rawValue))), not '\(text)'")
            }
            return choice
        }
        size = try choice("DRIP_SIZE", CardSize.self)
        motion = try choice("DRIP_MOTION", Motion.self)
        stack = try choice("DRIP_STACK", StackSettings.Choice.self)
        whenFocused = try choice("DRIP_WHEN_FOCUSED", WhenFocused.self)
        agentCards = try choice("DRIP_AGENT_CARDS", AgentHook.Cards.self)
        func seconds(_ name: String, in range: ClosedRange<Double>) throws -> Double? {
            guard let text = value(name) else { return nil }
            guard let seconds = Double(text), range.contains(seconds) else {
                throw UsageError(
                    "\(name) must be a number of seconds from \(Defaults.number(range.lowerBound)) to "
                        + "\(Defaults.number(range.upperBound)), not '\(text)'")
            }
            return seconds
        }
        awayAfter = try seconds("DRIP_AWAY_AFTER", in: Defaults.awayAfterRange)
        doneAfter = try seconds("DRIP_DONE_AFTER", in: Defaults.doneAfterRange)
        if let text = value("DRIP_STACK_MAX") {
            guard let max = Int(text), Defaults.stackMaxRange.contains(max) else {
                throw UsageError("DRIP_STACK_MAX must be a whole number from 1 to 6, not '\(text)'")
            }
            stackMax = max
        }
        sound = value("DRIP_SOUND").map(Sound.init(parsing:))
        debug = try Self.debug(environment: environment)
        sender = CardActivation.sender(in: environment)
        pane = TerminalPane(environment: environment)
    }
}

extension EnvironmentSettings {
    /// `DRIP_DEBUG`: `1`, `true`, `on` or `yes`, or `0`, `false`, `off` or `no`; nil when unset or
    /// empty. Throws a `UsageError` for anything else.
    public static func debug(environment: [String: String]) throws -> Bool? {
        guard let text = environment["DRIP_DEBUG"].flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        switch text.lowercased() {
        case "1", "true", "on", "yes": return true
        case "0", "false", "off", "no": return false
        default: throw UsageError("DRIP_DEBUG must be 1 or 0, not '\(text)'")
        }
    }
}
