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

    /// How many cards the history keeps: `DRIP_HISTORY`, then the config's `history`, then the default.
    public var historyLimit: Int { environment.history ?? config.history ?? Defaults.history }

    /// How long a card of `preset` stays without `--seconds`: `DRIP_SECONDS`, then the preset's own
    /// time, then the config's `seconds`, then the default. A nil `preset` sets no time of its own.
    public func seconds(for preset: Preset?) -> Double {
        environment.seconds ?? preset?.seconds ?? config.seconds ?? Defaults.seconds
    }

    /// The sound of every card without `--sound`: `DRIP_SOUND`, then the config's top-level `sound`.
    /// Nil when each preset plays its own. A preset the config gives a sound of its own keeps it,
    /// unless `DRIP_SOUND` is set or the config's `sound` is `none`.
    public var sound: Sound? { environment.sound ?? config.sound }

    /// Whether a card of `preset` keeps the sound the config gives that preset, over `sound`: when
    /// `DRIP_SOUND` is unset and the config's top-level `sound` is not `none`.
    public func keepsOwnSound(_ preset: Preset) -> Bool {
        environment.sound == nil && config.sound != Sound.none && config.presets[preset.name]?.sound != nil
    }

    /// How the cards stack at the notch: `DRIP_STACK`, `DRIP_STACK_MAX` and `DRIP_STACK_DELAY`, then
    /// the config's `stack`, `stack_max` and `stack_delay`, then the defaults. Nil when stacking is off.
    public var stack: StackSettings? { StackSettings.resolved(environment, config: config) }

    /// The settings from the config file `loadConfig` reads and the environment, for a drip that
    /// shows its card whatever the environment says: each `DRIP_*` variable drip cannot read is left
    /// out, and the others still apply. `warnings` are the file's. `error` is what a card command's
    /// strict read of the environment throws, nil when it reads, for a caller that reports it.
    public static func leniently(
        environment: [String: String],
        loadConfig: ([String: String]) -> ConfigFile = { ConfigLoader.loadLeniently(environment: $0) }
    ) -> (resolver: CardResolver, warnings: [String], error: Error?) {
        let file = loadConfig(environment)
        do {
            let settings = try EnvironmentSettings(environment: environment)
            return (CardResolver(config: file.config, environment: settings), file.warnings, nil)
        } catch {
            let settings = EnvironmentSettings.leniently(environment).settings
            return (CardResolver(config: file.config, environment: settings), file.warnings, error)
        }
    }

    /// `DRIP_SIZE`, then the config's `size`, then the default.
    public var size: CardSize { environment.size ?? config.size ?? Defaults.size }

    /// `DRIP_MOTION`, then the config's `motion`, then the default.
    public var motion: Motion { environment.motion ?? config.motion ?? Defaults.motion }

    /// `DRIP_CONTRAST`, then the config's `contrast`, then off: whether every card has its outline,
    /// whatever Increase Contrast says.
    public var contrast: Bool { environment.contrast ?? config.contrast ?? false }

    /// Resolves `drip [<kind>] [<title>] [options]` into a card.
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
            throw UsageError("missing the title: pass it as an argument or on stdin")
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
        var card = Card(
            kind: preset.name,
            title: title,
            detail: CardText.line(detail),
            icon: flags.icon ?? preset.icon,
            fallbackIcon: preset.icon,
            color: flags.color ?? preset.color,
            sound: flags.sound ?? (keepsOwnSound(preset) ? preset.sound : sound ?? preset.sound),
            seconds: flags.seconds ?? seconds(for: preset),
            size: flags.size ?? size,
            motion: flags.motion ?? motion
        )
        if flags.open != nil || flags.button != nil {
            card.action = CardAction(
                label: CardText.line(flags.button, limit: Defaults.buttonLimit) ?? "Open", open: flags.open,
                decline: flags.open == nil ? CardText.line(flags.decline, limit: Defaults.buttonLimit) : nil)
        }
        // Left out when off, so a card's JSON reads as it did before the outline.
        card.contrast = (flags.contrast ?? contrast) ? true : nil
        card.id = flags.id
        card.activate = CardActivation.target(flag: flags.activate, sender: environment.sender)
        card.pane = flags.activate == nil && card.activate != nil ? environment.pane : nil
        card.onClick = flags.onClick.map { OnClick(command: $0, environment: environment.forwarded) }
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
