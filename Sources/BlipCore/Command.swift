import ArgumentParser

/// Process exit codes. `blip run` exits with the wrapped command's code instead.
public enum ExitStatus {
    public static let shown: Int32 = 0
    public static let usage: Int32 = 2
    public static let noGUISession: Int32 = 3
    public static let invalidConfig: Int32 = 4
}

extension Position: ExpressibleByArgument {}
extension CardSize: ExpressibleByArgument {}
extension CardStyle: ExpressibleByArgument {}
extension NotchMotion: ExpressibleByArgument {}
extension Motion: ExpressibleByArgument {}

extension CardColor: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(parsing: argument)
    }
}

extension Icon: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(parsing: argument)
    }
}

extension Sound: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(parsing: argument)
    }
}

/// Options shared by every command that shows a card.
public struct CardOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: ArgumentHelp("The second, gray line.", valueName: "text"))
    var detail: String?

    @Option(name: .shortAndLong, help: ArgumentHelp(
        "Seconds fully visible, excluding fades: 0.5 to 60. (default: 4.5)", valueName: "n"))
    var seconds: Double?

    @Option(help: ArgumentHelp(
        "A sound from /System/Library/Sounds, a path to an .aiff or .wav file, or none. (default: the preset's)",
        valueName: "name|none"))
    var sound: Sound?

    @Option(help: ArgumentHelp(
        "An SF Symbol name, or none. Unknown names fall back to the preset's icon. (default: the preset's)",
        valueName: "symbol|none"))
    var icon: Icon?

    @Option(help: ArgumentHelp(
        "#rrggbb, or green, orange, red, blue, purple, pink, yellow or gray. (default: the preset's)",
        valueName: "hex|name"))
    var color: CardColor?

    @Option(help: ArgumentHelp(
        "bottom, center, top or notch. notch falls back to top without a notch. (default: bottom)",
        valueName: "position"))
    var position: Position?

    @Option(help: ArgumentHelp("compact, regular or large. (default: regular)", valueName: "size"))
    var size: CardSize?

    @Option(help: ArgumentHelp(
        "hud, glass, wash or terminal. (default: glass on macOS 26, hud before)", valueName: "style"))
    var style: CardStyle?

    @Option(help: ArgumentHelp(
        "How a notch card appears: droplet, snap or ears. (default: droplet)", valueName: "motion"))
    var notch: NotchMotion?

    @Option(help: ArgumentHelp(
        "full, subtle (fades only) or none. Reduce Motion caps it at subtle. (default: full)",
        valueName: "amount"))
    var motion: Motion?

    @Flag(help: "Block until the card has faded out.")
    var wait = false

    @Flag(help: "Never print warnings.")
    var quiet = false

    public init() {}

    public func validate() throws {
        if let seconds, !Defaults.secondsRange.contains(seconds) {
            throw ValidationError("--seconds must be between 0.5 and 60.")
        }
    }

    /// The parsed values, as a plain value.
    public var flags: CardFlags {
        CardFlags(
            detail: detail, seconds: seconds, sound: sound, icon: icon, color: color, position: position,
            size: size, style: style, notch: notch, motion: motion, wait: wait, quiet: quiet)
    }
}

/// The card options from the command line; nil where a flag was not given.
public struct CardFlags: Equatable {
    public var detail: String?
    public var seconds: Double?
    public var sound: Sound?
    public var icon: Icon?
    public var color: CardColor?
    public var position: Position?
    public var size: CardSize?
    public var style: CardStyle?
    public var notch: NotchMotion?
    public var motion: Motion?
    public var wait: Bool
    public var quiet: Bool

    public init(
        detail: String? = nil, seconds: Double? = nil, sound: Sound? = nil, icon: Icon? = nil,
        color: CardColor? = nil, position: Position? = nil, size: CardSize? = nil, style: CardStyle? = nil,
        notch: NotchMotion? = nil, motion: Motion? = nil, wait: Bool = false, quiet: Bool = false
    ) {
        self.detail = detail
        self.seconds = seconds
        self.sound = sound
        self.icon = icon
        self.color = color
        self.position = position
        self.size = size
        self.style = style
        self.notch = notch
        self.motion = motion
        self.wait = wait
        self.quiet = quiet
    }
}

/// `blip [KIND] [TITLE] [options]`
public struct BlipCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "blip",
        abstract: "Show a brief HUD card on macOS.",
        usage: """
            blip [KIND] [TITLE] [options]
            blip run [options] -- <command> [args...]
            blip demo [options]
            blip --version | --help
            """,
        discussion: """
            Presets: ok, warn, fail and info, plus any defined in $XDG_CONFIG_HOME/blip/config.toml.

            When no TITLE is given and stdin is not a terminal, blip reads stdin: the first \
            non-empty line is the title and the remaining lines are the detail, unless --detail \
            is given.

            blip run runs the command, then shows ok when it exits 0 and fail otherwise, with how \
            long it took. It exits with the command's exit code.

            blip demo plays every style, then every notch motion, so you can pick by feel.

            Exit codes: 0 shown, 2 usage error, 3 no GUI session, 4 invalid config file.
            """,
        version: blipVersion
    )

    @Argument(help: ArgumentHelp(
        "ok, warn, fail, info or a custom preset. Taken as the title when it is not a preset. (default: info)",
        valueName: "kind"))
    public var kind: String?

    @Argument(help: ArgumentHelp("The bold line. Required unless stdin provides it.", valueName: "title"))
    public var title: String?

    @OptionGroup public var options: CardOptions

    public init() {}
}

/// `blip run [options] -- <command> [args...]`
public struct RunCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "blip run",
        abstract: "Run a command, then show ok or fail with how long it took.",
        usage: "blip run [options] -- <command> [args...]",
        discussion: "Exits with the command's exit code."
    )

    @OptionGroup public var options: CardOptions

    @Argument(parsing: .postTerminator, help: ArgumentHelp("The command to run, after --.", valueName: "command"))
    public var command: [String] = []

    public init() {}

    public func validate() throws {
        if command.isEmpty {
            throw ValidationError("Missing the command to run after --.")
        }
    }
}

/// `blip demo [options]`: shows every style, then every notch motion, one after another.
public struct DemoCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "blip demo",
        abstract: "Play every style, then every notch motion, so you can pick by feel.",
        usage: "blip demo [options]",
        discussion: """
            Styles play at your configured position, or --position. Notch motions play only on a \
            screen with a notch. Cards are silent unless --sound or BLIP_SOUND is given. --style and \
            --notch narrow the demo to one style or one notch motion.
            """
    )

    @OptionGroup public var options: CardOptions

    public init() {}
}

/// `blip __render --out card.png [KIND] [TITLE] [options]`: draws a card offscreen into a PNG.
/// Hidden from help; used by the snapshot tests.
public struct RenderCommand: ParsableCommand {
    public enum Appearance: String, ExpressibleByArgument, CaseIterable {
        case light, dark
    }

    public static let configuration = CommandConfiguration(
        commandName: "blip __render",
        abstract: "Draw a card offscreen into a PNG at 2x.",
        usage: "blip __render --out <file.png> [KIND] [TITLE] [options]"
    )

    @Argument public var kind: String?
    @Argument public var title: String?
    @OptionGroup public var options: CardOptions

    @Option(help: "Where to write the PNG.")
    public var out: String

    @Option(help: "light or dark.")
    public var appearance: Appearance = .light

    @Option(help: "For a notch card: draw its entrance this many seconds in, instead of fully open.")
    public var at: Double?

    @Flag(help: "With --at, draw the notch card's exit instead of its entrance.")
    public var leaving = false

    public init() {}
}

/// What the command line asks blip to do.
public enum Invocation {
    case show(BlipCommand)
    case run(RunCommand)
    case demo(DemoCommand)
    case render(RenderCommand)
}

/// The outcome of parsing a command line.
public enum ParseResult {
    case invocation(Invocation)
    /// Help, version or a usage error: print `message` and exit with `status`.
    case exit(status: Int32, message: String)
}

public enum CommandLineParser {
    /// Parses arguments, not including the program name.
    ///
    /// The subcommands are dispatched here rather than by ArgumentParser, which would read a
    /// subcommand name as the root command's KIND positional.
    public static func parse(_ arguments: [String]) -> ParseResult {
        switch arguments.first {
        case "run":
            return parse(RunCommand.self, Array(arguments.dropFirst())).map(Invocation.run)
        case "demo":
            return parse(DemoCommand.self, Array(arguments.dropFirst())).map(Invocation.demo)
        case "__render":
            return parse(RenderCommand.self, Array(arguments.dropFirst())).map(Invocation.render)
        default:
            return parse(BlipCommand.self, arguments).map(Invocation.show)
        }
    }

    private static func parse<Command: ParsableCommand>(
        _ type: Command.Type, _ arguments: [String]
    ) -> Result<Command, ParseFailure> {
        do {
            return .success(try type.parse(arguments))
        } catch {
            let status = type.exitCode(for: error) == .success ? 0 : ExitStatus.usage
            return .failure(ParseFailure(status: status, message: type.fullMessage(for: error)))
        }
    }
}

private struct ParseFailure: Error {
    var status: Int32
    var message: String
}

private extension Result where Failure == ParseFailure {
    func map(_ invocation: (Success) -> Invocation) -> ParseResult {
        switch self {
        case let .success(command):
            return .invocation(invocation(command))
        case let .failure(failure):
            return .exit(status: failure.status, message: failure.message)
        }
    }
}
