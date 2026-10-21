import ArgumentParser
#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif

/// Process exit codes. `drip run` exits with the wrapped command's code instead.
public enum ExitStatus {
    public static let shown: Int32 = 0
    public static let usage: Int32 = 2
    public static let noGUISession: Int32 = 3
    public static let invalidConfig: Int32 = 4
    /// drip asked with `--confirm` and the button was not clicked.
    public static let notClicked: Int32 = 5
    /// `drip hook` could not make a card. Never 2: Claude Code reads exit 2 from a hook as "block",
    /// which would stop Claude from finishing its turn.
    public static let hookFailed: Int32 = 1
}

extension Position: ExpressibleByArgument {}
extension CardSize: ExpressibleByArgument {}
extension CardStyle: ExpressibleByArgument {}
extension Motion: ExpressibleByArgument {}
extension StackSettings.Mode: ExpressibleByArgument {}

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

/// Options shared by every command that shows a card. ArgumentParser lists the values of an option
/// that has a fixed set, so its help does not.
public struct CardOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: ArgumentHelp(
        "The gray text under the title, up to 3 lines.", valueName: "text"))
    var detail: String?

    @Option(name: .shortAndLong, help: ArgumentHelp(
        "Seconds fully visible, excluding fades: 0.5 to 60. An ask card given a time counts it down instead of waiting. (default: 4.5)",
        valueName: "n"))
    var seconds: Double?

    @Option(help: ArgumentHelp(
        "A sound from /System/Library/Sounds, a path to an .aiff or .wav file, or none. (default: the preset's)",
        valueName: "name|none"))
    var sound: Sound?

    @Option(help: ArgumentHelp(
        "An SF Symbol name, a path to an image, app: and an app's bundle identifier for its icon, mark:claude, mark:codex or mark:gemini for an agent's mark drip bundles, or none. Icons that cannot load fall back to the preset's. (default: the preset's)",
        valueName: "symbol|path|app:id|mark:name|none"))
    var icon: Icon?

    @Option(help: ArgumentHelp(
        "#rrggbb, or green, orange, red, blue, purple, pink, yellow or gray. (default: the preset's)",
        valueName: "hex|name"))
    var color: CardColor?

    @Option(help: ArgumentHelp(
        "Where the card shows. Without a notch, notch grows from the top edge. (default: notch)",
        valueName: "position"))
    var position: Position?

    @Option(help: ArgumentHelp(
        "How the card is drawn; a notch card is always black. (default: glass on macOS 26, hud before)",
        valueName: "style"))
    var style: CardStyle?

    @Option(help: ArgumentHelp(
        "Add a button that opens this URL or path. Hovering holds the card.", valueName: "url|path"))
    var open: String?

    @Option(help: ArgumentHelp("The --open button's label. (default: Open)", valueName: "label"))
    var button: String?

    @Option(help: ArgumentHelp(
        "Ask with a button of this label: drip waits, then exits 0 if it was clicked and 5 if not.",
        valueName: "label"))
    var confirm: String?

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
            throw ValidationError("--seconds must be between 0.5 and 60")
        }
        if let open, let separator = open.range(of: "://") {
            // A URL needs a scheme such as https before its "://"; a path never contains one.
            let scheme = open[..<separator.lowerBound]
            let valid = scheme.first?.isLetter == true
                && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
                && URL(string: open) != nil
            if !valid { throw ValidationError("--open: '\(open)' is not a valid URL") }
        }
        if let button, CardText.line(button, limit: Defaults.buttonLimit) == nil {
            throw ValidationError("--button needs a label")
        }
        if let confirm {
            if open != nil {
                throw ValidationError("--confirm asks a question, so it opens nothing: name an --open button with --button")
            }
            if button != nil { throw ValidationError("--confirm and --button both name the button: give one") }
            if CardText.line(confirm, limit: Defaults.buttonLimit) == nil {
                throw ValidationError("--confirm needs a label")
            }
        }
        if let id, id.trimmingCharacters(in: .whitespaces).isEmpty || id.count > Defaults.idLimit {
            throw ValidationError("--id needs 1 to \(Defaults.idLimit) characters")
        }
        if let problem = icon?.problem {
            throw ValidationError("--icon: \(problem)")
        }
        if let activate, activate != CardActivation.none, !CardActivation.isBundleIdentifier(activate) {
            throw ValidationError("--activate: '\(activate)' is not a bundle identifier such as com.apple.Terminal")
        }
    }

    /// The parsed values, as a plain value. A `--confirm` question is a button with nothing to open.
    public var flags: CardFlags {
        let directory = FileManager.default.currentDirectoryPath
        // `--open "$CI_URL"` with the variable empty opens nothing, so the card has no button, and
        // `drip run` still runs its command.
        let target = open.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Self.target($0, from: directory) }
        let label: String?
        if open == nil {
            // Without --open, --button is the old spelling of --confirm.
            label = confirm ?? button
        } else {
            // --button names the --open button, and an empty --open has none.
            label = target == nil ? nil : button
        }
        return CardFlags(
            detail: detail, seconds: seconds, sound: sound,
            icon: icon.map { $0.resolved(from: directory) }, color: color, position: position,
            style: style, wait: wait, quiet: quiet, open: target, button: label, id: id, activate: activate)
    }

    /// What drip warns about before it shows the card: options that do nothing, and the old
    /// spelling of --confirm.
    public var warnings: [String] {
        var warnings: [String] = []
        if open?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            warnings.append("--open is empty, so the card has no button")
        }
        if button != nil, open == nil {
            warnings.append("--button without --open is deprecated; use --confirm")
        }
        return warnings
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
    /// Set only by `drip __render`: everywhere else the size comes from the config or `DRIP_SIZE`.
    public var size: CardSize?
    public var style: CardStyle?
    /// Set only by `drip __render`: everywhere else the motion comes from the config or `DRIP_MOTION`.
    public var motion: Motion?
    public var wait: Bool
    public var quiet: Bool
    public var open: String?
    /// The button's label: it opens `open`, or, without it, asks a question.
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

/// `drip`: shows a card, or runs the subcommand named first.
public struct DripCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "drip",
        abstract: "Show a brief card at the notch on macOS.",
        usage: """
            drip [KIND] [TITLE] [options]
            drip run [options] [--] <command> [args...]
            drip hook claude|codex [options] [payload]
            drip demo [chain|push] [options]
            drip history [--missed] [--json | --replay]
            """,
        version: dripVersion,
        subcommands: [
            ShowCommand.self, RunCommand.self, HookCommand.self, DemoCommand.self, HistoryCommand.self,
            RenderCommand.self, BackgroundCommand.self,
        ],
        defaultSubcommand: ShowCommand.self
    )

    /// What `drip --help` shows after the usage.
    static let examples = """
        EXAMPLES:
          drip "build finished"
          drip ok "dotfiles up to date" -d "pulled 1 commit"
          drip fail "deploy failed" -d "$err" --seconds 8
          git log -1 --format='%s%n%an' | drip ok
          drip run make test
          drip run --open "$CI_URL" --button "View run" ./deploy.sh
          drip warn "staging is ready" --confirm Promote && ./promote.sh
          drip ask "my-app needs you" --icon app:com.openai.chat
        """

    /// What `drip --help` ends with.
    static let exitCodes = """
        EXIT CODES:
          0  The card was shown, or handed off to be shown.
          1  drip hook could not make a card.
          2  Usage error.
          3  No GUI session, such as over ssh.
          4  The config file is invalid.
          5  drip asked with --confirm and the button was not clicked.
          drip run exits with its command's exit code instead.
        """

    public init() {}
}

/// `drip [KIND] [TITLE] [options]`, which `drip show` names: what drip does when the first word
/// names no subcommand.
public struct ShowCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show a card.",
        usage: "drip [KIND] [TITLE] [options]"
    )

    @Argument(help: ArgumentHelp(
        "ok, warn, fail, info, ask or a preset from ~/.config/drip/config.toml. An ask card waits until it is clicked. Taken as the title when no title follows it. (default: info)",
        valueName: "kind"))
    public var kind: String?

    @Argument(help: ArgumentHelp(
        "The bold text, up to 2 lines. Without it, drip reads stdin: the first line is the title and the rest the detail.",
        valueName: "title"))
    public var title: String?

    /// Words after the title, as from `drip build finished` with the title left unquoted: the
    /// error says how to quote it.
    @Argument(help: .hidden)
    public var rest: [String] = []

    @OptionGroup public var options: CardOptions

    public init() {}
}

/// `drip run [options] [--] <command> [args...]`
public struct RunCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command, then show ok or fail with how long it took.",
        usage: "drip run [options] [--] <command> [args...]",
        discussion: """
            drip's options come first; the command starts at the first argument that is not one, or \
            after --. Exits with the command's exit code.
            """
    )

    @OptionGroup public var options: CardOptions

    /// Everything from the first argument that is not one of drip's options, `--` included.
    @Argument(parsing: .captureForPassthrough, help: ArgumentHelp(
        "The command to run, and its arguments.", valueName: "command"))
    var words: [String] = []

    /// The command to run and its arguments.
    public var command: [String] {
        words.first == "--" ? Array(words.dropFirst()) : words
    }

    public init() {}

    public func validate() throws {
        // drip's options end where the command starts, so these are the only ones it can see.
        switch words.first {
        case "-h", "--help": throw CleanExit.helpRequest(Self.self)
        case let first? where first != "--" && first.hasPrefix("-"):
            throw ValidationError("unknown option '\(first)'")
        default: break
        }
        if command.isEmpty {
            throw ValidationError("missing the command to run, as in: drip run make test")
        }
    }
}

/// `drip hook claude|codex [options] [payload]`: shows a card from a coding agent's hook.
public struct HookCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Show a card from a Claude Code or Codex hook.",
        usage: "drip hook claude|codex [options] [payload]",
        discussion: """
            The payload is the hook's JSON: an argument, as Codex's notify passes it, or stdin, as \
            Claude Code's hooks do. The card names the project and whether the agent needs you or is \
            done, and each session's card replaces its last. Exits 1 instead of 2 on a mistake, since \
            a hook that exits 2 blocks the agent.
            """
    )

    /// Optional here so that `drip hook` alone is a one-line error, not the whole help.
    @Argument(help: ArgumentHelp("The agent whose hook runs drip.", valueName: "agent"))
    var agentName: AgentHook.Agent?

    /// The agent whose hook runs drip; `validate()` makes sure there is one.
    public var agent: AgentHook.Agent {
        agentName ?? .claude
    }

    @Argument(help: ArgumentHelp("The hook's JSON. Read from stdin when absent.", valueName: "payload"))
    public var payload: String?

    @OptionGroup public var options: CardOptions

    public init() {}

    public func validate() throws {
        if agentName == nil {
            throw ValidationError("missing the agent: drip hook claude or drip hook codex")
        }
    }
}

/// `drip demo [chain|push] [options]`: drops a few cards from the notch, stacking them each way.
public struct DemoCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "demo",
        abstract: "Drop a few cards from the notch, stacking as queued cards do.",
        usage: "drip demo [chain|push] [options]",
        discussion: """
            Plays the cards chained, each new card dropping out of the one above, then pushed, each \
            new card dropping out of the notch as the others move down; chain or push plays only that \
            one. Every card is a notch card and plays its preset's sound; --id is ignored.
            """
    )

    /// The cards the demo drops, in order: one of each kind a build or an agent sends, the last
    /// with a button. `pause` is how long a card waits, at the least, after the one before it.
    public static let samples: [(kind: String, title: String, detail: String, open: String?, pause: Double)] = [
        ("ok", "Build finished", "make test: 246 passed in 3.2s", nil, 0),
        ("ask", "Claude needs you", "Claude needs your permission to use Bash", nil, 0),
        ("fail", "Deploy failed", "staging: health check timed out after 30s", nil, 0),
        ("info", "Report uploaded", "q3-review.pdf is on the file server", "https://github.com/jrnxf/drip", 3),
    ]

    /// How the demo stacks its cards `mode`'s way, whatever `stack` or `DRIP_STACK` says, the report
    /// held back.
    public static func stack(_ mode: StackSettings.Mode, environment: [String: String], config: Config) -> StackSettings {
        var settings = StackSettings.current(environment: environment, config: config, mode: mode)
            ?? StackSettings(mode: mode, max: Defaults.stackMax)
        settings.pauses = samples.map(\.pause)
        return settings
    }

    /// The warnings to print before the demo: which flags do nothing.
    public static func warnings(flags: CardFlags) -> [String] {
        var warnings: [String] = []
        if flags.position != nil { warnings.append("drip demo shows only notch cards, so --position does nothing") }
        if flags.style != nil { warnings.append("drip demo shows only notch cards, so --style does nothing") }
        return warnings
    }

    /// The demo's cards, all at the notch. --detail replaces every sample's detail.
    public static func cards(_ resolver: CardResolver, flags: CardFlags) throws -> [Card] {
        var flags = flags
        flags.position = .notch
        // Every demo card would share one id and replace the one before.
        flags.id = nil
        return try samples.map { sample in
            var cardFlags = flags
            cardFlags.detail = flags.detail ?? sample.detail
            if let open = sample.open, flags.open == nil, flags.button == nil {
                cardFlags.open = open
                cardFlags.button = "Open"
            }
            return try resolver.resolve(kind: sample.kind, title: sample.title, flags: cardFlags)
        }
    }

    @Argument(help: ArgumentHelp("How the cards stack. (default: both, in turn)", valueName: "stack"))
    public var stack: StackSettings.Mode?

    /// The ways the demo stacks its cards, in turn.
    public var stacks: [StackSettings.Mode] {
        stack.map { [$0] } ?? StackSettings.Mode.allCases
    }

    @OptionGroup public var options: CardOptions

    public init() {}
}

/// `drip history [--missed] [--json | --replay]`: lists or shows again the cards in the history.
public struct HistoryCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "history",
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

    @Flag(help: "Print each card as one flat line of JSON, for scripts.")
    public var json = false

    @Flag(help: "Show the cards again instead of listing them.")
    public var replay = false

    public init() {}

    public func validate() throws {
        if json, replay { throw ValidationError("--json and --replay cannot be used together") }
    }
}

/// `drip __render --out card.png [KIND] [TITLE] [options]`: draws a card offscreen into a PNG.
/// Hidden from help; used by the snapshot tests, which also set the size and motion, settings the
/// other commands take only from the config and the environment.
public struct RenderCommand: ParsableCommand {
    public enum Appearance: String, ExpressibleByArgument, CaseIterable {
        case light, dark
    }

    public static let configuration = CommandConfiguration(
        commandName: "__render",
        abstract: "Draw a card offscreen into a PNG at 2x.",
        usage: "drip __render --out <file.png> [KIND] [TITLE] [options]",
        shouldDisplay: false
    )

    @Argument public var kind: String?
    @Argument public var title: String?
    @OptionGroup public var options: CardOptions

    @Option(help: "How large the card is drawn. (default: regular)")
    public var size: CardSize?

    @Option(help: "How much the card moves. (default: full)")
    public var motion: Motion?

    @Option(help: "Where to write the PNG.")
    public var out: String

    @Option(help: "How the card's surroundings look.")
    public var appearance: Appearance = .light

    @Option(help: "For a notch card: draw its entrance this many seconds in, instead of fully open.")
    public var at: Double?

    @Flag(help: "With --at, draw the notch card's exit instead of its entrance.")
    public var leaving = false

    /// The card options, with the size and motion.
    public var flags: CardFlags {
        var flags = options.flags
        flags.size = size
        flags.motion = motion
        return flags
    }

    public init() {}
}

/// `drip __background`: the drip a foreground one starts, which shows the cards it reads from stdin.
public struct BackgroundCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "__background",
        abstract: "Show the cards a foreground drip hands over on stdin.",
        shouldDisplay: false
    )

    public init() {}
}

/// What the command line asks drip to do.
public enum Invocation {
    case show(ShowCommand)
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
    public static func parse(_ arguments: [String]) -> ParseResult {
        // What people type for the version; a card titled "version" is never what they meant.
        if arguments == ["version"] {
            return parse(["--version"])
        }
        let attached = arguments.first == RunCommand.configuration.commandName
            ? Array(arguments.prefix(1)) + attachingTextValues(Array(arguments.dropFirst()), untilCommand: true)
            : attachingTextValues(arguments)
        do {
            var command = try DripCommand.parseAsRoot(attached)
            switch command {
            case let command as ShowCommand: return .invocation(.show(command))
            case let command as RunCommand: return .invocation(.run(command))
            case let command as HookCommand: return .invocation(.hook(command))
            case let command as DemoCommand: return .invocation(.demo(command))
            case let command as HistoryCommand: return .invocation(.history(command))
            case let command as RenderCommand: return .invocation(.render(command))
            case is BackgroundCommand: return .invocation(.background)
            default:
                // `drip help [subcommand]`, whose run() asks for that help.
                try command.run()
                return .exit(status: ExitStatus.shown, message: "")
            }
        } catch {
            return failure(error, arguments: attached)
        }
    }

    /// Help, the version or a completion script, printed as they are, or a usage error, printed as
    /// drip's own errors are: `drip: <message>`, then where the help is.
    private static func failure(_ error: Error, arguments: [String]) -> ParseResult {
        let message = DripCommand.message(for: error)
        if DripCommand.exitCode(for: error) == .success {
            var text = message == DripCommand.helpMessage() ? rootHelp : message
            if message == DripCommand.helpMessage(for: RunCommand.self) {
                // drip run takes --version as the start of its command and rejects it, so its help
                // does not offer the flag ArgumentParser lists for every subcommand.
                text = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.hasPrefix("  --version ") }.joined(separator: "\n")
            }
            return .exit(status: ExitStatus.shown, message: HelpSections(text).usageFirst ?? text)
        }
        let subcommand = DripCommand.configuration.subcommands
            .first { $0.configuration.shouldDisplay && $0.configuration.commandName == arguments.first }
            .flatMap { $0.configuration.commandName }
        let status = subcommand == HookCommand.configuration.commandName ? ExitStatus.hookFailed : ExitStatus.usage
        var problem = message
        if problem.hasPrefix("Invalid option") || problem.hasPrefix("Unknown option"),
           let text = dashLeadingText(in: arguments) {
            // Text such as "--- FAIL: TestFoo" read as an option: say where it goes instead.
            problem = "'\(text)' starts with a dash, so it reads as an option. Put text that starts with a "
                + "dash after --, as in: drip fail -- '\(text)'"
        }
        if problem.hasSuffix(".") { problem.removeLast() }
        problem = problem.prefix(1).lowercased() + problem.dropFirst()
        return .exit(status: status, message: usageMessage(problem, subcommand: subcommand))
    }

    /// A usage mistake as drip prints it: `drip: <message>`, then where the help is, for the
    /// subcommand if one is named.
    public static func usageMessage(_ problem: String, subcommand: String? = nil) -> String {
        let help = subcommand.map { "drip \($0) --help" } ?? "drip --help"
        return "drip: \(problem)\nSee '\(help)'."
    }

    /// `drip --help`: the usage, examples, the card options and the subcommands, then the exit
    /// codes. ArgumentParser's own help for drip would list only the subcommands.
    static var rootHelp: String {
        let root = HelpSections(DripCommand.helpMessage())
        let show = HelpSections(DripCommand.helpMessage(for: ShowCommand.self))
        return [
            root["OVERVIEW"], root["USAGE"], DripCommand.examples, show["ARGUMENTS"], show["OPTIONS"],
            root["SUBCOMMANDS"], DripCommand.exitCodes,
        ].compactMap { $0 }.joined(separator: "\n\n") + "\n"
    }
}

/// ArgumentParser's help, by section: each starts with a line such as `OPTIONS:`.
struct HelpSections {
    private var sections: [(title: String, text: String)] = []

    /// The help with the usage right after the one-line overview, and the rest of the overview, the
    /// command's discussion, after it. Nil for text that is not help, such as the version.
    var usageFirst: String? {
        guard let overview = self["OVERVIEW"], let usage = self["USAGE"] else { return nil }
        let paragraphs = overview.components(separatedBy: "\n\n")
        var parts = [paragraphs[0], usage]
        parts += paragraphs.dropFirst()
        for section in sections where section.title != "OVERVIEW" && section.title != "USAGE" {
            parts += [self[section.title]].compactMap { $0 }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    init(_ help: String) {
        for line in help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let title = line.prefix { $0 != ":" }
            if !title.isEmpty, title.count < line.count, title.allSatisfy({ $0.isUppercase || $0 == " " }) {
                sections.append((String(title), line))
            } else if !sections.isEmpty {
                sections[sections.count - 1].text += "\n" + line
            }
        }
    }

    /// The section's text, its title line included, without the blank lines after it.
    subscript(title: String) -> String? {
        sections.first { $0.title == title }.map { section in
            var text = section.text
            while text.hasSuffix("\n") { text.removeLast() }
            return text
        }
    }
}

extension CommandLineParser {
    /// The options whose values are free text, often a script's own output.
    private static let textOptions = [
        "-d": "--detail", "--detail": "--detail", "--button": "--button", "--confirm": "--confirm", "--id": "--id",
    ]

    /// Every card option that takes a value, so that `drip run` can tell an option's value from the
    /// command: in `drip run -s 3 make`, 3 is the value and make the command.
    static let valueOptions: Set<String> = [
        "-d", "--detail", "-s", "--seconds", "--sound", "--icon", "--color", "--position", "--style", "--open",
        "--button", "--confirm", "--id", "--activate",
    ]

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
    /// value instead of an unknown option. Arguments after `--` are left alone, and so, when
    /// `untilCommand`, are `drip run`'s command and its arguments.
    static func attachingTextValues(_ arguments: [String], untilCommand: Bool = false) -> [String] {
        var result: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--" || (untilCommand && !argument.hasPrefix("-")) {
                result += arguments[index...]
                break
            }
            // An empty value stays apart: `--detail=` would read as a missing value.
            if let name = textOptions[argument], index + 1 < arguments.endIndex, !arguments[index + 1].isEmpty {
                result.append("\(name)=\(arguments[index + 1])")
                index += 2
            } else if untilCommand, valueOptions.contains(argument), index + 1 < arguments.endIndex {
                // The option's value, which never starts the command.
                result += arguments[index...(index + 1)]
                index += 2
            } else {
                result.append(argument)
                index += 1
            }
        }
        return result
    }
}
