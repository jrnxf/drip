/// The eight named system colors `--color` accepts.
public enum SystemColor: String, CaseIterable, Sendable, Codable {
    case green, orange, red, blue, purple, pink, yellow, gray
}

/// A card's accent color: a system color that adapts to light and dark, or a fixed sRGB value.
public enum CardColor: Equatable, Sendable, Codable {
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
public enum Icon: Equatable, Sendable, Codable {
    case none
    case symbol(String)

    /// `none` means no icon; anything else is taken as an SF Symbol name.
    public init(parsing text: String) {
        self = text == "none" ? .none : .symbol(text)
    }
}

/// A system sound from /System/Library/Sounds, a sound file, or silence.
public enum Sound: Equatable, Sendable, Codable {
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

/// Where the card sits on the screen. `notch` grows the card out of the camera notch, and falls back
/// to `top` on a screen without one.
public enum Position: String, CaseIterable, Sendable, Codable {
    case bottom, center, top, notch
}

/// How the card is drawn.
public enum CardStyle: String, CaseIterable, Sendable, Codable {
    /// The dark HUD material with an accent hairline.
    case hud
    /// The system glass on macOS 26; `hud` on earlier versions.
    case glass
    /// The whole card in the accent color, darkened until white text is readable on it.
    case wash
    /// A solid dark card with an accent stripe and monospaced text.
    case terminal
}

/// How a card at `position = notch` leaves the notch.
public enum NotchMotion: String, CaseIterable, Sendable, Codable {
    /// A drop forms under the notch, breaks free on a neck and floats below the menu bar.
    case droplet
    /// One quick move from the notch into the card, without bounce.
    case snap
    /// Ears grow either side of the notch, inside the menu bar; the card never drops.
    case ears
}

/// How much a card moves. Reduce Motion in System Settings caps this at `subtle`.
public enum Motion: String, CaseIterable, Sendable, Codable {
    /// Each style's own entrance and exit.
    case full
    /// Fades only.
    case subtle
    /// Appears and disappears at once.
    case none

    /// This setting, capped at `subtle` when the system asks for reduced motion.
    public func capped(reduceMotion: Bool) -> Motion {
        reduceMotion && self == .full ? .subtle : self
    }
}

/// Scales fonts, icon and padding.
public enum CardSize: String, CaseIterable, Sendable, Codable {
    case compact, regular, large

    public var scale: Double {
        switch self {
        case .compact: return 0.85
        case .regular: return 1.0
        case .large: return 1.25
        }
    }
}

/// A named bundle of icon, color, sound and optionally a visible time and a style.
public struct Preset: Equatable, Sendable {
    public var name: String
    public var icon: Icon
    public var color: CardColor
    public var sound: Sound
    public var seconds: Double?
    public var style: CardStyle?

    public init(
        name: String, icon: Icon, color: CardColor, sound: Sound, seconds: Double? = nil, style: CardStyle? = nil
    ) {
        self.name = name
        self.icon = icon
        self.color = color
        self.sound = sound
        self.seconds = seconds
        self.style = style
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
    public static let position = Position.notch
    public static let size = CardSize.regular
    /// The style when nothing sets one and the display has no better default.
    public static let style = CardStyle.hud
    public static let notch = NotchMotion.droplet
    public static let motion = Motion.full
    public static let titleLimit = 80
    public static let detailLimit = 120
    /// The longest button label, in characters.
    public static let buttonLimit = 24
    /// The longest `--id`, in characters.
    public static let idLimit = 200
}

/// A button on the card. A click opens `open` when it is set and dismisses the card; a blip that
/// waits for the card exits 0 when the button was clicked and 5 when it was not.
public struct CardAction: Equatable, Sendable, Codable {
    public var label: String
    public var open: String?

    public init(label: String, open: String?) {
        self.label = label
        self.open = open
    }
}

/// A fully resolved card, ready to render.
public struct Card: Equatable, Sendable, Codable {
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
    public var style: CardStyle
    public var notch: NotchMotion
    public var motion: Motion
    /// A button on the card; nil for none.
    public var action: CardAction?
    /// Names what the card is about, such as an agent session: a newer card with the same id
    /// replaces this one while it waits, or takes its place on screen. Nil for none.
    public var id: String?
    /// The bundle identifier of the app a click on the card brings forward; nil for none.
    public var activate: String?

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
        size: CardSize = Defaults.size,
        style: CardStyle = Defaults.style,
        notch: NotchMotion = Defaults.notch,
        motion: Motion = Defaults.motion
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
        self.style = style
        self.notch = notch
        self.motion = motion
    }

    /// Whether the card asks a question: it has a button with nothing to open, and only blip's exit
    /// status reports the click.
    public var asksQuestion: Bool {
        action != nil && action?.open == nil
    }

    /// Whether the card takes clicks: on its button, or anywhere to bring the sending app forward.
    public var isClickable: Bool {
        action != nil || activate != nil
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
            seconds: preset.seconds ?? Defaults.seconds,
            style: preset.style ?? Defaults.style
        )
    }
}
