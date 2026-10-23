/// A problem that stops drip from showing a card.
public struct UsageError: Error, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Turns parsed arguments into a finished card.
///
/// Each setting comes from the first of: flags, DRIP_* environment variables, the config file,
/// built-in defaults. Within the config file, a preset's own value beats the global one:
/// `[preset.deploy] seconds = 6` beats a top-level `seconds = 3`.
public struct CardResolver {
    public var presets: [String: Preset]
    public var config: Config
    public var environment: EnvironmentSettings

    public init(config: Config = Config(), environment: EnvironmentSettings = EnvironmentSettings()) {
        presets = Dictionary(config.allPresets.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        self.config = config
        self.environment = environment
    }

    /// Resolves `drip [KIND] [TITLE] [options]` into a card.
    ///
    /// The first positional is the kind when it names a preset; otherwise it is the title and the
    /// kind is `info`. When there is no title, `standardInput` is read for the title and, unless
    /// --detail was given, the detail. It is not called at all when a title was given. Words after
    /// the title, `rest`, are an error that says how to quote them into the title.
    public func resolve(
        kind: String?, title: String?, rest: [String] = [], flags: CardFlags, standardInput: () -> String? = { nil }
    ) throws -> Card {
        let (preset, positionalTitle) = try presetAndTitle(kind: kind, title: title, rest: rest)
        var title = positionalTitle
        var detail = flags.detail
        if title == nil, let input = standardInput() {
            let lines = CardText.splitStandardInput(input)
            title = lines.title
            if detail == nil { detail = lines.detail }
        }
        guard let title = CardText.line(title) else {
            throw UsageError("missing TITLE: pass it as an argument or on stdin")
        }
        return card(preset: preset, title: title, detail: detail, flags: flags)
    }

    /// Resolves the card `drip run` shows: ok when the command exited 0, fail otherwise, with the
    /// wall time as the detail unless --detail was given.
    public func resolveRun(command: [String], status: Int32, seconds: Double, flags: CardFlags) throws -> Card {
        let preset = try preset(named: status == 0 ? Preset.ok.name : Preset.fail.name)
        let title = RunSummary.title(command: command, status: status)
        return card(
            preset: preset, title: title, detail: flags.detail ?? RunSummary.duration(seconds: seconds),
            flags: flags)
    }

    private func card(preset: Preset, title: String, detail: String?, flags: CardFlags) -> Card {
        // The config's top-level sound mutes every preset, or replaces the sound of those that set
        // none of their own.
        var presetSound = preset.sound
        if config.sound == Sound.none || config.presets[preset.name]?.sound == nil {
            presetSound = config.sound ?? preset.sound
        }
        var card = Card(
            kind: preset.name,
            title: title,
            detail: CardText.line(detail),
            icon: flags.icon ?? preset.icon,
            fallbackIcon: preset.icon,
            color: flags.color ?? preset.color,
            sound: flags.sound ?? environment.sound ?? presetSound,
            seconds: flags.seconds ?? environment.seconds ?? preset.seconds ?? config.seconds ?? Defaults.seconds,
            size: flags.size ?? environment.size ?? config.size ?? Defaults.size,
            motion: flags.motion ?? environment.motion ?? config.motion ?? Defaults.motion
        )
        if flags.open != nil || flags.button != nil {
            card.action = CardAction(
                label: CardText.line(flags.button, limit: Defaults.buttonLimit) ?? "Open", open: flags.open,
                decline: flags.open == nil ? CardText.line(flags.decline, limit: Defaults.buttonLimit) : nil)
        }
        card.id = flags.id
        card.activate = CardActivation.target(flag: flags.activate, sender: environment.sender)
        // A card that stays and a question of any kind wait for you. A time from the command line,
        // the environment or the preset makes them count down instead.
        if flags.stay || card.asksQuestion, flags.seconds == nil, environment.seconds == nil,
           preset.seconds == nil {
            card.waitLimit = Defaults.waitLimit
        }
        return card
    }

    private func presetAndTitle(kind: String?, title: String?, rest: [String]) throws -> (Preset, String?) {
        guard let kind else {
            return (try preset(named: Preset.defaultName), title)
        }
        let known = presets[kind]
        if let title, known == nil || !rest.isEmpty {
            // Most likely a title of several words, unquoted: `drip build finished`.
            let words = ([title] + rest).joined(separator: " ")
            let problem: String, shown: String, command: String
            if known == nil {
                problem = "unknown preset '\(kind)' (known: \(presets.keys.sorted().joined(separator: ", ")))"
                shown = kind + " " + words
                command = "drip \(ShellWord.quoted(shown))"
            } else {
                problem = "unexpected argument '\(rest[0])'"
                shown = words
                command = "drip \(kind) \(ShellWord.quoted(shown))"
            }
            throw UsageError("\(problem)\nTo show \"\(shown)\" as the title, quote it: \(command)")
        }
        if let known {
            return (known, title)
        }
        return (try preset(named: Preset.defaultName), kind)
    }

    private func preset(named name: String) throws -> Preset {
        guard let preset = presets[name] else {
            throw UsageError("unknown preset '\(name)'")
        }
        return preset
    }
}

/// One word for a shell to read back as it is.
enum ShellWord {
    /// `text` in double quotes, or in single quotes when it holds a character a shell expands
    /// inside double quotes.
    static func quoted(_ text: String) -> String {
        guard text.contains(where: { "\"$`\\!".contains($0) }) else { return "\"\(text)\"" }
        return "'" + text.map { $0 == "'" ? "'\\''" : String($0) }.joined() + "'"
    }
}
