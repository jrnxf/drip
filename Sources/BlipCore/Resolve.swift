/// A problem that stops blip from showing a card.
public struct UsageError: Error, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Turns parsed arguments into a finished card.
public struct CardResolver {
    public var presets: [String: Preset]

    public init(presets: [Preset] = Preset.builtIn) {
        self.presets = Dictionary(presets.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Resolves `blip [KIND] [TITLE] [options]` into a card.
    ///
    /// The first positional is the kind when it names a preset; otherwise it is the title and the
    /// kind is `info`. When there is no title, `standardInput` is read for the title and, unless
    /// --detail was given, the detail. It is not called at all when a title was given.
    public func resolve(
        kind: String?, title: String?, flags: CardFlags, standardInput: () -> String? = { nil }
    ) throws -> Card {
        let (preset, positionalTitle) = try presetAndTitle(kind: kind, title: title)
        var title = positionalTitle
        var detail = flags.detail
        if title == nil, let input = standardInput() {
            let lines = CardText.splitStandardInput(input)
            title = lines.title
            if detail == nil { detail = lines.detail }
        }
        guard let title = CardText.line(title, limit: Defaults.titleLimit) else {
            throw UsageError("missing TITLE: pass it as an argument or on stdin")
        }
        return card(preset: preset, title: title, detail: detail, flags: flags)
    }

    /// Resolves the card `blip run` shows: ok when the command exited 0, fail otherwise, with the
    /// wall time as the detail unless --detail was given.
    public func resolveRun(command: [String], status: Int32, seconds: Double, flags: CardFlags) throws -> Card {
        let preset = try preset(named: status == 0 ? Preset.ok.name : Preset.fail.name)
        let title = RunSummary.title(command: command, status: status)
        return card(
            preset: preset, title: title, detail: flags.detail ?? RunSummary.duration(seconds: seconds),
            flags: flags)
    }

    private func card(preset: Preset, title: String, detail: String?, flags: CardFlags) -> Card {
        Card(
            kind: preset.name,
            title: title,
            detail: CardText.line(detail, limit: Defaults.detailLimit),
            icon: flags.icon ?? preset.icon,
            fallbackIcon: preset.icon,
            color: flags.color ?? preset.color,
            sound: flags.sound ?? preset.sound,
            seconds: flags.seconds ?? preset.seconds ?? Defaults.seconds,
            position: flags.position ?? Defaults.position,
            size: flags.size ?? Defaults.size
        )
    }

    private func presetAndTitle(kind: String?, title: String?) throws -> (Preset, String?) {
        guard let kind else {
            return (try preset(named: Preset.defaultName), title)
        }
        if let preset = presets[kind] {
            return (preset, title)
        }
        if title != nil {
            let names = presets.keys.sorted().joined(separator: ", ")
            throw UsageError("unknown preset '\(kind)' (known: \(names))")
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
