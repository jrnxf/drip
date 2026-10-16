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

    /// Resolves the positional arguments and flags into a card.
    ///
    /// The first positional is the kind when it names a preset; otherwise it is the title and the
    /// kind is `info`.
    public func resolve(kind: String?, title: String?, flags: CardFlags) throws -> Card {
        let (preset, title) = try presetAndTitle(kind: kind, title: title)
        guard let title, !title.isEmpty else {
            throw UsageError("missing TITLE")
        }
        let detail = flags.detail.flatMap { $0.isEmpty ? nil : $0 }
        return Card(preset: preset, title: title, detail: detail)
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
