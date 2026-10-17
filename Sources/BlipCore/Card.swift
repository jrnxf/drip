/// The eight named system colors `--color` accepts.
public enum SystemColor: String, CaseIterable, Sendable {
    case green, orange, red, blue, purple, pink, yellow, gray
}

/// A card's accent color: a system color that adapts to light and dark, or a fixed sRGB value.
public enum CardColor: Equatable, Sendable {
    case system(SystemColor)
    case rgb(red: UInt8, green: UInt8, blue: UInt8)

    /// Parses `#rrggbb` or one of the system color names. Case-insensitive.
    public init?(parsing text: String) {
        let lowered = text.lowercased()
        if let name = SystemColor(rawValue: lowered) {
            self = .system(name)
            return
        }
        guard lowered.hasPrefix("#"), lowered.count == 7,
              lowered.dropFirst().allSatisfy(\.isHexDigit),
              let value = UInt32(lowered.dropFirst(), radix: 16)
        else { return nil }
        self = .rgb(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF)
        )
    }
}

/// An SF Symbol, or no icon at all.
public enum Icon: Equatable, Sendable {
    case none
    case symbol(String)

    /// `none` means no icon; anything else is taken as an SF Symbol name.
    public init(parsing text: String) {
        self = text == "none" ? .none : .symbol(text)
    }
}

/// A system sound from /System/Library/Sounds, a sound file, or silence.
public enum Sound: Equatable, Sendable {
    case none
    case named(String)
    case file(String)

    /// `none` mutes; a value containing a slash or ending in a sound file extension is a path;
    /// anything else is a system sound name such as `Glass`.
    public init(parsing text: String) {
        let lowered = text.lowercased()
        if text == "none" {
            self = .none
        } else if text.contains("/") || [".aiff", ".aif", ".wav"].contains(where: lowered.hasSuffix) {
            self = .file(text)
        } else {
            self = .named(text)
        }
    }
}

/// Where the card sits on the screen.
public enum Position: String, CaseIterable, Sendable {
    case bottom, center, top
}

/// Scales fonts, icon and padding.
public enum CardSize: String, CaseIterable, Sendable {
    case compact, regular, large

    public var scale: Double {
        switch self {
        case .compact: return 0.85
        case .regular: return 1.0
        case .large: return 1.25
        }
    }
}

/// A named bundle of icon, color, sound and optionally a visible time.
public struct Preset: Equatable, Sendable {
    public var name: String
    public var icon: Icon
    public var color: CardColor
    public var sound: Sound
    public var seconds: Double?

    public init(name: String, icon: Icon, color: CardColor, sound: Sound, seconds: Double? = nil) {
        self.name = name
        self.icon = icon
        self.color = color
        self.sound = sound
        self.seconds = seconds
    }

    public static let ok = Preset(
        name: "ok", icon: .symbol("checkmark.circle.fill"), color: .system(.green), sound: .named("Glass"))
    public static let warn = Preset(
        name: "warn", icon: .symbol("exclamationmark.circle.fill"), color: .system(.orange), sound: .named("Purr"))
    public static let fail = Preset(
        name: "fail", icon: .symbol("xmark.circle.fill"), color: .system(.red), sound: .named("Basso"))
    public static let info = Preset(
        name: "info", icon: .symbol("info.circle.fill"), color: .system(.blue), sound: .named("Tink"))

    /// The built-in presets, in the order help text lists them.
    public static let builtIn: [Preset] = [.ok, .warn, .fail, .info]

    /// The preset used when no kind is given.
    public static let defaultName = "info"
}

/// Fixed numbers from the CLI spec.
public enum Defaults {
    public static let seconds = 4.5
    public static let secondsRange: ClosedRange<Double> = 0.5...60
    public static let position = Position.bottom
    public static let size = CardSize.regular
    public static let titleLimit = 80
    public static let detailLimit = 120
}

/// A fully resolved card, ready to render.
public struct Card: Equatable, Sendable {
    /// The preset name the card was built from.
    public var kind: String
    public var title: String
    public var detail: String?
    public var icon: Icon
    /// The preset's own icon, used when `icon` names a symbol that does not exist.
    public var fallbackIcon: Icon
    public var color: CardColor
    public var sound: Sound
    public var seconds: Double
    public var position: Position
    public var size: CardSize

    public init(
        kind: String,
        title: String,
        detail: String? = nil,
        icon: Icon,
        fallbackIcon: Icon? = nil,
        color: CardColor,
        sound: Sound,
        seconds: Double = Defaults.seconds,
        position: Position = Defaults.position,
        size: CardSize = Defaults.size
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.icon = icon
        self.fallbackIcon = fallbackIcon ?? icon
        self.color = color
        self.sound = sound
        self.seconds = seconds
        self.position = position
        self.size = size
    }

    /// A card that uses every value of `preset`.
    public init(preset: Preset, title: String, detail: String? = nil) {
        self.init(
            kind: preset.name,
            title: title,
            detail: detail,
            icon: preset.icon,
            color: preset.color,
            sound: preset.sound,
            seconds: preset.seconds ?? Defaults.seconds
        )
    }
}
