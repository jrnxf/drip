import ArgumentParser
import Foundation

/// Process exit codes. `drip run` exits with the wrapped command's code instead.
public enum ExitStatus {
    public static let shown: Int32 = 0
    public static let usage: Int32 = 2
    public static let noGUISession: Int32 = 3
    public static let invalidConfig: Int32 = 4
    /// The card had a button and it was not clicked.
    public static let notClicked: Int32 = 5
    /// `drip hook` could not make a card. Never 2: Claude Code reads exit 2 from a hook as "block",
    /// which would stop Claude from finishing its turn.
    public static let hookFailed: Int32 = 1
}

extension Position: ExpressibleByArgument {}
extension CardSize: ExpressibleByArgument {}
extension CardStyle: ExpressibleByArgument {}
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
    @Option(name: .shortAndLong, help: ArgumentHelp(
        "The gray text under the title, up to 3 lines.", valueName: "text"))
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
        "bottom, center, top or notch. notch falls back to top without a notch. (default: notch)",
        valueName: "position"))
    var position: Position?

    @Option(help: ArgumentHelp("compact, regular or large. (default: regular)", valueName: "size"))
    var size: CardSize?

    @Option(help: ArgumentHelp(
        "hud, glass, wash or terminal. (default: glass on macOS 26, hud before)", valueName: "style"))
    var style: CardStyle?

    @Option(help: ArgumentHelp(
        "full, subtle (fades only) or none. Reduce Motion caps it at subtle. (default: full)",
        valueName: "amount"))
    var motion: Motion?

    @Option(help: ArgumentHelp(
        "Add a button that opens this URL or path. Hovering holds the card.", valueName: "url|path"))
    var open: String?

    @Option(help: ArgumentHelp(
        "The button's label. Without --open, drip waits and exits 0 if it was clicked, 5 if not. (default: Open)",
        valueName: "label"))
    var button: String?

    @Option(help: ArgumentHelp(
        "Names what the card is about: a newer card with the same id replaces it while it waits, or takes its place on screen.",
        valueName: "id"))
    var id: String?

    @Option(help: ArgumentHelp(
        "The app a click on the card brings forward, or none. (default: the app drip was run from)",
        valueName: "bundle-id|none"))
    var activate: String?

    @Flag(help: "Wait until the card has gone before exiting. Without it, drip returns at once.")
    var wait = false

    @Flag(help: "Never print warnings.")
    var quiet = false

    public init() {}

    public func validate() throws {
        if let seconds, !Defaults.secondsRange.contains(seconds) {
            throw ValidationError("--seconds must be between 0.5 and 60.")
        }
        if let open, open.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("--open needs a URL or a path.")
        }
        if let open, let separator = open.range(of: "://") {
            // A URL needs a scheme such as https before its "://"; a path never contains one.
            let scheme = open[..<separator.lowerBound]
            let valid = scheme.first?.isLetter == true
                && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
                && URL(string: open) != nil
            if !valid { throw ValidationError("--open: '\(open)' is not a valid URL.") }
        }
        if let button, CardText.line(button, limit: Defaults.buttonLimit) == nil {
            throw ValidationError("--button needs a label.")
        }
        if let id, id.trimmingCharacters(in: .whitespaces).isEmpty || id.count > Defaults.idLimit {
            throw ValidationError("--id needs 1 to \(Defaults.idLimit) characters.")
        }
        if let activate, activate != CardActivation.none, !CardActivation.isBundleIdentifier(activate) {
            throw ValidationError("--activate: '\(activate)' is not a bundle identifier such as com.apple.Terminal.")
        }
    }

    /// The parsed values, as a plain value.
    public var flags: CardFlags {
        CardFlags(
            detail: detail, seconds: seconds, sound: sound, icon: icon, color: color, position: position,
            size: size, style: style, motion: motion, wait: wait, quiet: quiet,
            open: open.map { Self.target($0, from: FileManager.default.currentDirectoryPath) },
            button: button, id: id, activate: activate)
    }

    /// What `--open` names, as the button opens it: a URL as given, and a path with `~` expanded
    /// and made absolute from `directory`. The button may be clicked in another drip, started
    /// somewhere else, or replayed from the history later.
    static func target(_ open: String, from directory: String) -> String {
        guard !open.contains("://") else { return open }
        let path = (open as NSString).expandingTildeInPath
        guard !path.hasPrefix("/") else { return path }
        return ((directory as NSString).appendingPathComponent(path) as NSString).standardizingPath
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
    public var motion: Motion?
    public var wait: Bool
    public var quiet: Bool
    public var open: String?
    public var button: String?
    public var id: String?
    /// A bundle identifier, or `none`.
    public var activate: String?

    public init(
        detail: String? = nil, seconds: Double? = nil, sound: Sound? = nil, icon: Icon? = nil,
        color: CardColor? = nil, position: Position? = nil, size: CardSize? = nil, style: CardStyle? = nil,
        motion: Motion? = nil, wait: Bool = false, quiet: Bool = false,
        open: String? = nil, button: String? = nil, id: String? = nil, activate: String? = nil
    ) {
        self.open = open
        self.button = button
        self.id = id
        self.activate = activate
        self.detail = detail
        self.seconds = seconds
        self.sound = sound
        self.icon = icon
        self.color = color
        self.position = position
        self.size = size
        self.style = style
        self.motion = motion
        self.wait = wait
        self.quiet = quiet
    }
}

/// `drip [KIND] [TITLE] [options]`
public struct DripCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "drip",
        abstract: "Show a brief HUD card on macOS.",
        usage: """
            drip [KIND] [TITLE] [options]
            drip run [options] -- <command> [args...]
            drip hook claude|codex [options] [payload]
            drip demo [options]
            drip history [--missed] [--json | --replay]
            drip --version | --help
            """,
        discussion: """
            Presets: ok, warn, fail and info, plus any defined in $XDG_CONFIG_HOME/drip/config.toml.

            When no TITLE is given and stdin is not a terminal, drip reads stdin: the first \
            non-empty line is the title and the remaining lines are the detail, unless --detail \
            is given.

            drip run runs the command, then shows ok when it exits 0 and fail otherwise, with how \
            long it took. It exits with the command's exit code.

            drip hook shows a card from a Claude Code or Codex hook: which project needs you or is \
            done, and what the agent said.

            A click on the card brings forward the app drip was run from, such as the terminal, \
            unless --activate says otherwise.

            drip demo plays every style, then the notch card, so you can pick by feel.

            Cards that come up while the screen is locked wait for the unlock; three or more \
            become one card. drip history lists every card, the missed ones marked.

            Exit codes: 0 shown, 1 drip hook could not make a card, 2 usage error, 3 no GUI \
            session, 4 invalid config file, 5 a --button question went unanswered.
            """,
        version: dripVersion
    )

    @Argument(help: ArgumentHelp(
        "ok, warn, fail, info or a custom preset. Taken as the title when it is not a preset. (default: info)",
        valueName: "kind"))
    public var kind: String?

    @Argument(help: ArgumentHelp("The bold text, up to 2 lines. Required unless stdin provides it.", valueName: "title"))
    public var title: String?

    @OptionGroup public var options: CardOptions

    public init() {}
}

/// `drip run [options] -- <command> [args...]`
public struct RunCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "drip run",
        abstract: "Run a command, then show ok or fail with how long it took.",
        usage: "drip run [options] -- <command> [args...]",
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

/// `drip hook claude|codex [options] [payload]`: shows a card from a coding agent's hook.
public struct HookCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "drip hook",
        abstract: "Show a card from a Claude Code or Codex hook.",
        usage: "drip hook claude|codex [options] [payload]",
        discussion: """
            Reads the hook's JSON from the payload argument, which Codex's notify appends, or from \
            stdin, which Claude Code hooks use. Claude's Notification and Stop events and Codex's \
            agent-turn-complete make a card; any other payload is an error. The title is the \
            project (the payload's working directory) and whether the agent needs you or is done; \
            the detail is the agent's message. Each session's card replaces its previous one, \
            unless --id says otherwise. Exits 1 instead of 2 on an error, because a hook exiting 2 \
            blocks the agent.
            """
    )

    @Argument(help: ArgumentHelp("The agent whose hook runs drip: claude or codex.", valueName: "agent"))
    public var agent: AgentHook.Agent

    @Argument(help: ArgumentHelp("The hook's JSON. Read from stdin when absent.", valueName: "payload"))
    public var payload: String?

    @OptionGroup public var options: CardOptions

    public init() {}
}

/// `drip demo [options]`: shows every style, then the notch card, one after another.
public struct DemoCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "drip demo",
        abstract: "Play every style, then the notch card, so you can pick by feel.",
        usage: "drip demo [options]",
        discussion: """
            Styles play at your configured position, or --position. The notch card plays only on a \
            screen with a notch. Cards are silent unless --sound or DRIP_SOUND is given. --style \
            narrows the demo to one style.
            """
    )

    @OptionGroup public var options: CardOptions

    public init() {}
}

/// `drip history [--missed] [--json | --replay]`: lists or shows again the cards in the history.
public struct HistoryCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "drip history",
        abstract: "List the cards in the history, or show them again.",
        usage: "drip history [--missed] [--json | --replay]",
        discussion: """
            Lists every card in the history, oldest first, marking those that came up while the screen was \
            locked as missed. The history is $XDG_STATE_HOME/drip/history.jsonl, or \
            ~/.local/state/drip/history.jsonl, and keeps the last \(CardHistory.limit) cards.
            """
    )

    @Flag(help: "Only cards that came up while the screen was locked.")
    public var missed = false

    @Flag(help: "Print each card as a line of JSON, as it is stored.")
    public var json = false

    @Flag(help: "Show the cards again instead of listing them.")
    public var replay = false

    public init() {}

    public func validate() throws {
        if json, replay { throw ValidationError("--json and --replay cannot be used together.") }
    }
}

/// `drip __render --out card.png [KIND] [TITLE] [options]`: draws a card offscreen into a PNG.
/// Hidden from help; used by the snapshot tests.
public struct RenderCommand: ParsableCommand {
    public enum Appearance: String, ExpressibleByArgument, CaseIterable {
        case light, dark
    }

    public static let configuration = CommandConfiguration(
        commandName: "drip __render",
        abstract: "Draw a card offscreen into a PNG at 2x.",
        usage: "drip __render --out <file.png> [KIND] [TITLE] [options]"
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

/// What the command line asks drip to do.
public enum Invocation {
    case show(DripCommand)
    case run(RunCommand)
    case demo(DemoCommand)
    case hook(HookCommand)
    case history(HistoryCommand)
    case render(RenderCommand)
    /// The background drip: shows the cards it reads from standard input.
    case background
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
        case "hook":
            return parse(HookCommand.self, Array(arguments.dropFirst()), failure: ExitStatus.hookFailed)
                .map(Invocation.hook)
        case "history":
            return parse(HistoryCommand.self, Array(arguments.dropFirst())).map(Invocation.history)
        case "__render":
            return parse(RenderCommand.self, Array(arguments.dropFirst())).map(Invocation.render)
        case "__background":
            return .invocation(.background)
        default:
            return parse(DripCommand.self, arguments).map(Invocation.show)
        }
    }

    private static func parse<Command: ParsableCommand>(
        _ type: Command.Type, _ arguments: [String], failure: Int32 = ExitStatus.usage
    ) -> Result<Command, ParseFailure> {
        let attached = attachingTextValues(arguments)
        do {
            return .success(try type.parse(attached))
        } catch {
            let status = type.exitCode(for: error) == .success ? 0 : failure
            var message = type.fullMessage(for: error)
            if status != 0, message.hasPrefix("Error: Invalid option") || message.hasPrefix("Error: Unknown option"),
               let text = dashLeadingText(in: attached) {
                // Text such as "--- FAIL: TestFoo" read as an option: say where it goes instead.
                let usage = message.split(separator: "\n", maxSplits: 1).dropFirst().first.map { "\n" + $0 } ?? ""
                message = "Error: '\(text)' starts with a dash, so it reads as an option. Put text that starts "
                    + "with a dash after --, as in: drip fail -- '\(text)'" + usage
            }
            return .failure(ParseFailure(status: status, message: message))
        }
    }
}

extension CommandLineParser {
    /// The options whose values are free text, often a script's own output.
    private static let textOptions = ["-d": "--detail", "--detail": "--detail", "--button": "--button", "--id": "--id"]

    /// The first argument before `--` that starts with a dash but is text, not an option: it holds
    /// a space, or starts with three dashes. Options never do.
    static func dashLeadingText(in arguments: [String]) -> String? {
        arguments.prefix { $0 != "--" }.first { argument in
            argument.hasPrefix("-") && (argument.hasPrefix("---") || argument.contains(" "))
                && !textOptions.values.contains { argument.hasPrefix($0 + "=") }
        }
    }

    /// Joins each text option to the argument after it, as `--detail=<text>`, so text that starts
    /// with a dash, such as `-d "$err"` when the error reads "--- FAIL: TestFoo", is the option's
    /// value instead of an unknown option. Arguments after `--` are left alone.
    static func attachingTextValues(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--" {
                result += arguments[index...]
                break
            }
            // An empty value stays apart: `--detail=` would read as a missing value.
            if let name = textOptions[argument], index + 1 < arguments.endIndex, !arguments[index + 1].isEmpty {
                result.append("\(name)=\(arguments[index + 1])")
                index += 2
            } else {
                result.append(argument)
                index += 1
            }
        }
        return result
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
