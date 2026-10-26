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
    /// drip asked with `--yes` and no button was clicked: the card timed out, a newer card with the
    /// same id replaced it, or it was clicked off its buttons.
    public static let notClicked: Int32 = 5
    /// drip asked with `--yes` and `--no`, and no was clicked. 0 and 1 read as yes and no, as for
    /// `test`, so `drip warn … --yes Merge --no Later && merge` runs the merge on yes only.
    public static let declined: Int32 = 1
    /// `drip hook` could not make a card, for any reason. Never 2 or more: Claude Code and Codex read
    /// exit 2 from a hook as "block", and Gemini CLI reads any code but 0 and 1 as "deny", which after
    /// a turn makes it try the turn again.
    public static let hookFailed: Int32 = 1
    /// `drip setup` left the agent's settings alone: a symlink, read-only or not plain JSON.
    public static let setupFailed: Int32 = 1
    /// `drip pause` or `drip resume` could not write the pause to the state directory.
    public static let pauseFailed: Int32 = 1
    /// `drip dismiss` could not write its request to the state directory.
    public static let dismissFailed: Int32 = 1
    /// `drip follow` could not start: another one follows the machine already, or the state
    /// directory cannot be written.
    public static let followFailed: Int32 = 1

    /// What a drip that waited for its cards exits with: 5 when a card with a button went without a
    /// click on one, else 1 when a question was answered no, else 0.
    public static func answered(missed: Bool, declined: Bool) -> Int32 {
        missed ? notClicked : declined ? Self.declined : shown
    }
}

extension CardSize: ExpressibleByArgument {}
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

/// Options shared by every command that shows a card. ArgumentParser lists the values of an option
/// that has a fixed set, so its help does not.
public struct CardOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: ArgumentHelp(
        "The gray text under the title, up to 3 lines.", valueName: "text"))
    var detail: String?

    @Option(name: .shortAndLong, help: ArgumentHelp(
        "Seconds fully visible, excluding fades: 0.5 to 60. A card that stays or a question given a time counts it down instead of waiting. (default: 4.5)",
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
        "Add a button that opens this URL or path. Hovering holds the card.", valueName: "url|path"))
    var open: String?

    @Option(help: ArgumentHelp("The --open button's label. (default: Open)", valueName: "label"))
    var button: String?

    @Option(help: ArgumentHelp(
        "Ask a question with a yes button of this label: drip waits up to 10 minutes, then exits 0 if it was clicked and 5 if no button was.",
        valueName: "label"))
    var yes: String?

    @Option(help: ArgumentHelp(
        "With --yes, a no button of this label to its left: drip exits 1 if it was clicked, and 5 if neither was.",
        valueName: "label"))
    var no: String?

    @Option(help: ArgumentHelp(
        "Names what the card is about: a newer card with the same id replaces it while it waits, or takes its place on screen.",
        valueName: "id"))
    var id: String?

    @Option(help: ArgumentHelp(
        "The app a click on the card brings forward, or none. (default: the app drip was run from)",
        valueName: "bundle-id|none"))
    var activate: String?

    @Flag(help: "Keep the card on screen until it is clicked, a newer card with the same --id replaces it, or 10 minutes pass. drip still returns at once.")
    var stay = false

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
        if let button {
            if open == nil {
                throw ValidationError("--button names the --open button, so it needs --open; to ask a question, use --yes")
            }
            if CardText.line(button, limit: Defaults.buttonLimit) == nil {
                throw ValidationError("--button needs a label")
            }
        }
        if let yes {
            if open != nil {
                throw ValidationError("--yes asks a question, so it opens nothing: give --open or --yes, not both")
            }
            if CardText.line(yes, limit: Defaults.buttonLimit) == nil {
                throw ValidationError("--yes needs a label")
            }
        }
        if let no {
            if yes == nil {
                throw ValidationError("--no needs --yes, the button that answers yes")
            }
            if CardText.line(no, limit: Defaults.buttonLimit) == nil {
                throw ValidationError("--no needs a label")
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

    /// Throws when the options ask a question, which `drip run` and `drip hook` cannot: nothing reads
    /// the answer, as `drip run` exits with its command's code and `drip hook` with 0 or 1.
    func rejectQuestion(in command: String) throws {
        for (flag, label) in [("--yes", yes), ("--no", no)] where label != nil {
            throw ValidationError(
                "drip \(command) takes no \(flag): nothing reads the answer to its question. Ask with drip itself, as in: drip warn \"Deploy?\" --yes Deploy")
        }
    }

    /// The parsed values, as a plain value. A `--yes` question is a button with nothing to open, and
    /// `--no` its second button.
    public var flags: CardFlags {
        let directory = FileManager.default.currentDirectoryPath
        // `--open "$CI_URL"` with the variable empty opens nothing, so the card has no button, and
        // `drip run` still runs its command.
        let target = open.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Self.target($0, from: directory) }
        // --button names the --open button, and an empty --open has none.
        let label = open == nil ? yes : target == nil ? nil : button
        return CardFlags(
            detail: detail, seconds: seconds, sound: sound,
            icon: icon.map { $0.resolved(from: directory) }, color: color, stay: stay, wait: wait, quiet: quiet,
            open: target, button: label, decline: open == nil ? no : nil, id: id, activate: activate)
    }

    /// What drip warns about before it shows the card: options that do nothing.
    public var warnings: [String] {
        var warnings: [String] = []
        if open?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            warnings.append("--open is empty, so the card has no button")
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
    /// Set only by `drip __render`: everywhere else the size comes from the config or `DRIP_SIZE`.
    public var size: CardSize?
    /// Set only by `drip __render`: everywhere else the motion comes from the config or `DRIP_MOTION`.
    public var motion: Motion?
    /// Keeps the card on screen, as `--stay` does, unless a time is set for it.
    public var stay: Bool
    public var wait: Bool
    public var quiet: Bool
    public var open: String?
    /// The button's label: it opens `open`, or, without it, asks a question.
    public var button: String?
    /// The label of a question's second button, which answers no.
    public var decline: String?
    public var id: String?
    /// A bundle identifier, or `none`.
    public var activate: String?

    public init(
        detail: String? = nil, seconds: Double? = nil, sound: Sound? = nil, icon: Icon? = nil,
        color: CardColor? = nil, size: CardSize? = nil, motion: Motion? = nil, stay: Bool = false,
        wait: Bool = false, quiet: Bool = false,
        open: String? = nil, button: String? = nil, decline: String? = nil, id: String? = nil, activate: String? = nil
    ) {
        self.open = open
        self.button = button
        self.decline = decline
        self.id = id
        self.activate = activate
        self.detail = detail
        self.seconds = seconds
        self.sound = sound
        self.icon = icon
        self.color = color
        self.size = size
        self.motion = motion
        self.stay = stay
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
            drip hook claude|codex|gemini [options] [payload]
            drip setup claude|codex|gemini [--print | --remote]
            drip setup remote
            drip follow <ssh-target> [options]
            drip history [--missed] [--json | --replay]
            drip dismiss [--id ID]
            drip pause [DURATION]
            drip resume
            """,
        version: dripVersion,
        subcommands: [
            ShowCommand.self, RunCommand.self, HookCommand.self, SetupCommand.self, FollowCommand.self,
            HistoryCommand.self, DismissCommand.self, PauseCommand.self, ResumeCommand.self, RenderCommand.self,
            BackgroundCommand.self,
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
          drip warn "Deploy to prod?" --yes Deploy --no Cancel && ./deploy.sh
          drip fail "deploy failed" --stay
          drip info "my-app needs you" --stay --icon app:com.openai.chat
          drip setup claude
          drip follow devbox
          drip dismiss
          drip pause 30m
        """

    /// What `drip --help` ends with.
    static let exitCodes = """
        EXIT CODES:
          0  The card was shown, or handed off to be shown; a question was answered yes.
          1  A question was answered no, drip hook could not make a card, or drip setup left the
             settings alone.
          2  Usage error.
          3  No GUI session, such as over ssh (drip hook exits 0 instead).
          4  The config file is invalid.
          5  drip asked with --yes and no button was clicked.
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
        "ok, warn, fail, info or a preset from ~/.config/drip/config.toml: the card's icon, color and sound. Taken as the title when no title follows it. (default: info)",
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
        try options.rejectQuestion(in: "run")
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

/// `drip hook claude|codex|gemini [options] [payload]`: shows a card from a coding agent's hook.
public struct HookCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Show a card from a Claude Code, Codex or Gemini CLI hook.",
        usage: "drip hook claude|codex|gemini [options] [payload]",
        discussion: """
            The payload is the hook's JSON, on stdin as hooks pass it, or an argument as Codex's older \
            notify does. The card names the project and whether the agent needs you, is done or \
            stopped on an error, and each session's card replaces its last. A card that says the \
            agent needs you goes once you answer in the terminal: the hooks that report a tool ran or \
            a prompt was sent take it away and show nothing. drip setup adds these hooks for you. \
            Without a GUI session, as over ssh, drip shows nothing and exits 0, and so it does for a \
            session nobody attends, such as claude -p, and wherever DRIP_HOOK=off; DRIP_HOOK=on \
            shows cards even then, and DRIP_HOOK=attention shows only the cards that need you or \
            report an error, not the done cards, for an orchestrator's own session. Any failure exits 1, \
            since an agent reads some other codes as "block".
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
        try options.rejectQuestion(in: "hook")
        if agentName == nil {
            throw ValidationError("missing the agent: drip hook claude, drip hook codex or drip hook gemini")
        }
    }
}

/// `drip setup claude|codex|gemini [--print | --remote]`: adds drip's hooks to a coding agent's
/// settings. `drip setup remote`: prints the hook for agents on another machine.
public struct SetupCommand: ParsableCommand {
    /// What `drip setup` sets up: an agent, or `remote`, the hook for agents on another machine.
    public enum Target: String, CaseIterable, ExpressibleByArgument {
        case claude, codex, gemini, remote
    }

    public static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Add drip's hooks to Claude Code's, Codex's or Gemini CLI's settings.",
        usage: """
            drip setup claude|codex|gemini [--print | --remote]
            drip setup remote
            """,
        discussion: """
            Adds drip hook to ~/.claude/settings.json, ~/.codex/hooks.json or ~/.gemini/settings.json, \
            keeping everything else, and backs the old file up next to it. Running it again changes \
            nothing. A settings file that is a symlink or read-only, as home-manager makes, or that \
            is not plain JSON is left alone: drip prints the hooks to add yourself and exits 1. For \
            Codex it also takes drip out of notify in ~/.codex/config.toml, which the Stop hook replaces. \
            For an agent on another machine, which drip follow shows the cards of: drip setup remote \
            prints drip-remote-hook, a shell script to save there, and --remote prints the hooks that \
            run it, for the agent's settings there.
            """
    )

    /// Optional here so that `drip setup` alone is a one-line error, not the whole help.
    @Argument(help: ArgumentHelp(
        "The agent whose settings get drip's hooks, or remote for the hook script of another machine.",
        valueName: "agent"))
    var target: Target?

    /// The agent whose settings get drip's hooks; nil for `drip setup remote`.
    public var agent: AgentHook.Agent? {
        target.flatMap { AgentHook.Agent(rawValue: $0.rawValue) }
    }

    @Flag(name: .customLong("print"), help: "Print drip's hooks for the agent's settings instead of adding them.")
    public var printOnly = false

    @Flag(help: "Print the hooks for the agent's settings on another machine, which run drip-remote-hook.")
    public var remote = false

    public init() {}

    public func validate() throws {
        guard let target else {
            throw ValidationError("missing the agent: drip setup claude, drip setup codex or drip setup gemini")
        }
        if target != .remote, printOnly, remote {
            throw ValidationError("--remote prints the hooks already: give --print or --remote, not both")
        }
    }
}

/// `drip follow <ssh-target> [options]`: shows the cards of agents on another machine.
public struct FollowCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "follow",
        abstract: "Show the cards of coding agents on another machine, over ssh.",
        usage: "drip follow <ssh-target> [--max-age <duration>] [--activate <bundle-id>] [--herdr-machine <label>] [--queue <path>] [--launchd]",
        discussion: """
            Reads the events that drip-remote-hook queues on the machine, over ssh with no prompts, and \
            shows each one's card as drip hook would on this Mac, by the same config and DRIP_HOOK. \
            It runs until stopped, reconnecting when the connection drops, and takes up after the last \
            event it handled. Events older than --max-age when they arrive, as after the Mac slept, \
            show no card, but still take away the cards they would. drip setup remote prints the hook; --launchd prints a launchd agent that keeps \
            drip follow running.
            """
    )

    /// How old an event may be when it arrives, by default: one queued while the Mac slept shows no card.
    public static let defaultMaxAge = 5 * 60.0

    @Argument(help: ArgumentHelp("The machine, as ssh takes it: a host, user@host, or a Host from ~/.ssh/config.", valueName: "ssh-target"))
    public var target: String?

    @Option(name: .customLong("max-age"), help: ArgumentHelp(
        "Show no card for events older than this when they arrive: minutes or hours, such as 5m or 1h. (default: 5m)",
        valueName: "duration"))
    var maxAgeText: String?

    @Option(help: ArgumentHelp(
        "The app a click on a card brings forward, or none. (default: the app drip follow was run from)",
        valueName: "bundle-id|none"))
    public var activate: String?

    @Option(name: .customLong("herdr-machine"), help: ArgumentHelp(
        "The machine as herdr on this Mac saved it, which a click focuses the agent's tab on. (default: the ssh target's host)",
        valueName: "label"))
    var herdrMachineName: String?

    @Option(help: ArgumentHelp(
        "The queue on the machine. (default: $DRIP_QUEUE there, else drip/remote.jsonl in $XDG_STATE_HOME or ~/.local/state)",
        valueName: "path"))
    public var queue: String?

    @Flag(help: "Print a launchd agent that runs this drip follow at login and keeps it running, instead of running it.")
    public var launchd = false

    /// Seconds an event may be old when it arrives.
    public var maxAge: Double {
        maxAgeText.flatMap(DripPause.duration) ?? Self.defaultMaxAge
    }

    /// The saved herdr machine a click focuses the agent's tab on: `--herdr-machine`, else the
    /// target's host, without its user or port. Nil when it is no machine label.
    public var herdrMachine: String? {
        var host = herdrMachineName ?? target ?? ""
        if host.hasPrefix("ssh://") { host = String(host.dropFirst(6)) }
        if herdrMachineName == nil {
            host = String(host.split(separator: "@").last ?? "")
            host = String(host.split(separator: ":").first ?? "")
        }
        return TerminalPane.isMachineLabel(host) ? host : nil
    }

    public init() {}

    public func validate() throws {
        guard let target else {
            throw ValidationError("missing the machine, as ssh takes it: drip follow devbox")
        }
        if target.isEmpty || target.hasPrefix("-") || target.count > 255
            || target.contains(where: { $0.isWhitespace || ($0.asciiValue ?? 32) < 32 })
        {
            throw ValidationError("'\(target)' is not an ssh target such as devbox or user@devbox")
        }
        if let maxAgeText, DripPause.duration(maxAgeText) == nil {
            throw ValidationError("--max-age: '\(maxAgeText)' is not a duration: give minutes or hours, as in 5m or 1h")
        }
        if let activate, activate != CardActivation.none, !CardActivation.isBundleIdentifier(activate) {
            throw ValidationError("--activate: '\(activate)' is not a bundle identifier such as com.apple.Terminal")
        }
        if let herdrMachineName, !TerminalPane.isMachineLabel(herdrMachineName) {
            throw ValidationError("--herdr-machine: '\(herdrMachineName)' is not a herdr machine label")
        }
        if let queue, queue.isEmpty || queue.contains("\n") {
            throw ValidationError("--queue needs a path")
        }
    }
}

/// `drip history [--missed] [--json | --replay]`: lists or shows again the cards in the history.
public struct HistoryCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "List the cards in the history, or show them again.",
        usage: "drip history [--missed] [--json | --replay]",
        discussion: """
            Lists every card in the history, oldest first, marking those that came up while the screen was \
            locked or drip was paused as missed. The history is $XDG_STATE_HOME/drip/history.jsonl, or \
            ~/.local/state/drip/history.jsonl, and keeps the last \(CardHistory.limit) cards.
            """
    )

    @Flag(help: "Only cards that came up while the screen was locked or drip was paused.")
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

/// `drip dismiss [--id ID]`: takes cards away without bringing anything forward.
public struct DismissCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "dismiss",
        abstract: "Take the cards on screen away, without bringing anything forward.",
        usage: "drip dismiss [--id ID]",
        discussion: """
            Takes away every card on screen, and every card still waiting its turn, as a right-click on \
            each would: nothing comes forward, and a question goes unanswered. With --id, only the \
            cards with that id. A card that comes after is shown as usual. Bind it to a key in \
            Shortcuts, Raycast or skhd to clear the notch from the keyboard.
            """,
        aliases: ["clear"]
    )

    @Option(name: .customLong("id"), help: ArgumentHelp("Only the cards with this --id.", valueName: "id"))
    public var id: String?

    public init() {}

    public func validate() throws {
        if let id, id.isEmpty || id.count > Defaults.idLimit {
            throw ValidationError("--id takes 1 to \(Defaults.idLimit) characters")
        }
    }
}

/// `drip pause [DURATION]`: holds cards for a while, as while the screen is locked.
public struct PauseCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pause",
        abstract: "Hold cards for a while, then show what came up.",
        usage: "drip pause [DURATION]",
        discussion: """
            Until the pause ends, cards are held as they are while the screen is locked: then one or \
            two show as they are, and three or more as one card, and drip history --missed lists them. \
            A drip that waits for its card, with --wait or a --yes question, waits for the end. drip \
            pause alone pauses for 1h, or says how long is left when drip is paused already. To \
            extend or shorten a running pause, pass a duration, such as drip pause 1h: it sets a new \
            end from now. The pause holds for every drip, ends on its own, and lasts at \
            most 24h. drip resume ends it now.
            """
    )

    /// How long to pause for, in seconds, from now, replacing any pause; nil to say how long is left
    /// of the pause, or to pause for `DripPause.defaultDuration` when there is none.
    public var seconds: Double? {
        argument.flatMap(DripPause.duration)
    }

    @Argument(help: ArgumentHelp(
        "How long to pause: minutes or hours, such as 30m, 2h or 1h30m. (default: 1h, or the time left when paused)",
        valueName: "duration"))
    var argument: String?

    public init() {}

    public func validate() throws {
        guard let argument else { return }
        guard let seconds = DripPause.duration(argument) else {
            throw ValidationError("'\(argument)' is not a duration: give minutes or hours, as in 30m, 2h or 1h30m")
        }
        if seconds > DripPause.longest {
            throw ValidationError("a pause lasts at most 24h")
        }
    }
}

/// `drip resume`: ends a pause now.
public struct ResumeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "End a pause now, and show the cards it held.",
        usage: "drip resume"
    )

    public init() {}
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

    @Option(help: "Draw the card's entrance this many seconds in, instead of fully open.")
    public var at: Double?

    @Flag(help: "With --at, draw the card's exit instead of its entrance.")
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
    case hook(HookCommand)
    case setup(SetupCommand)
    case follow(FollowCommand)
    case history(HistoryCommand)
    case dismiss(DismissCommand)
    case pause(PauseCommand)
    /// `drip resume`: ends a pause now.
    case resume
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
            case let command as SetupCommand: return .invocation(.setup(command))
            case let command as FollowCommand: return .invocation(.follow(command))
            case let command as HistoryCommand: return .invocation(.history(command))
            case let command as DismissCommand: return .invocation(.dismiss(command))
            case let command as PauseCommand: return .invocation(.pause(command))
            case is ResumeCommand: return .invocation(.resume)
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
        "-d": "--detail", "--detail": "--detail", "--button": "--button", "--yes": "--yes", "--no": "--no",
        "--id": "--id",
    ]

    /// Every card option that takes a value, so that `drip run` can tell an option's value from the
    /// command: in `drip run -s 3 make`, 3 is the value and make the command.
    static let valueOptions: Set<String> = [
        "-d", "--detail", "-s", "--seconds", "--sound", "--icon", "--color", "--open", "--button",
        "--yes", "--no", "--id", "--activate",
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
