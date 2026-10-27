import DripCore
import Foundation

/// Shows and renders cards. The macOS implementation is in HUDWindow.swift and Render.swift.
protocol CardDisplay {
    /// Shows the cards one after another, after any other drip's, and returns once the last has
    /// gone, or as soon as a question is answered, with the exit status to report. `locked` says what happens while the screen is locked;
    /// a `stack` given stacks cards that way instead of as `stack` or `DRIP_STACK` says.
    func show(_ cards: [Card], locked: LockedScreen, stack: StackSettings?, console: Console) -> Int32

    /// Hands the cards to a background drip and returns at once, or shows them here when it cannot.
    func showInBackground(_ request: BackgroundRequest, console: Console) -> Int32

    /// Checks the cards' sounds and icons, warning about and replacing any that cannot load.
    func prepare(_ cards: [Card], console: Console) -> [Card]

    /// Whether an app with the bundle identifier is installed.
    func isInstalled(_ bundleIdentifier: String) -> Bool

    /// Whether there is a GUI session to show cards in: not over ssh, for example.
    var hasGUISession: Bool { get }

    /// Where the terminal a click on `card` brings forward is: whether it is the frontmost app, and
    /// how long since you last used the keyboard or mouse.
    func front(of card: Card) -> WhenFocused.Front

    /// Whether the card's pane is the one its terminal shows; nil when drip cannot tell.
    func paneShowing(_ card: Card) -> Bool?

    /// Draws the card offscreen into a PNG file; `at` seconds into its entrance, or its exit when
    /// `leaving`.
    func render(
        _ card: Card, appearance: RenderCommand.Appearance, at time: Double?, leaving: Bool, to path: String,
        console: Console
    ) -> Int32
}

extension CardDisplay {
    /// Shows the cards, stacking them as `stack` or `DRIP_STACK` says.
    func show(_ cards: [Card], locked: LockedScreen, console: Console) -> Int32 {
        show(cards, locked: locked, stack: nil, console: console)
    }
}

/// Writes messages to stderr.
struct Console {
    var quiet = false
    /// Set in the background drip that answers clicks, whose standard error is a log, if any.
    var background = false

    /// Prints a warning unless --quiet was given.
    func warn(_ message: String) {
        if !quiet { error("warning: \(message)") }
    }

    /// Warns about card options that were given but say nothing, or are on their way out.
    func warnAbout(_ options: CardOptions) {
        options.warnings.forEach(warn)
    }

    /// Says how a click on a card went: in the background drip, always; elsewhere only when it
    /// went wrong, as a warning.
    func click(_ message: String, failed: Bool = true) {
        if background {
            error(message)
        } else if failed {
            warn(message)
        }
    }

    func error(_ message: String) {
        FileHandle.standardError.write(Data("drip: \(CardText.printable(message))\n".utf8))
    }
}

/// The command-line entry point, independent of how cards are drawn.
struct DripCLI {
    var display: CardDisplay

    func run(_ arguments: [String]) -> Int32 {
        switch CommandLineParser.parse(arguments) {
        case let .exit(status, message):
            if status == 0 {
                print(message)
            } else {
                FileHandle.standardError.write(Data((CardText.printable(message) + "\n").utf8))
            }
            return status
        case let .invocation(.show(command)):
            return show(command)
        case let .invocation(.run(command)):
            return run(command)
        case let .invocation(.hook(command)):
            return hook(command)
        case let .invocation(.setup(command)):
            return setup(command)
        case let .invocation(.follow(command)):
            return follow(command)
        case let .invocation(.history(command)):
            return history(command)
        case let .invocation(.dismiss(command)):
            return dismiss(command)
        case let .invocation(.pause(command)):
            return pause(command.seconds)
        case .invocation(.resume):
            return resume()
        case let .invocation(.render(command)):
            return render(command)
        case .invocation(.background):
            return background()
        }
    }

    private func show(_ command: ShowCommand) -> Int32 {
        let flags = command.options.flags
        let console = Console(quiet: flags.quiet)
        console.warnAbout(command.options)
        do {
            let card = try makeResolver(console).resolve(
                kind: command.kind, title: command.title, rest: command.rest, flags: flags,
                standardInput: StandardInput.read)
            return deliver([card], wait: flags.wait, console: console)
        } catch {
            return report(error, console)
        }
    }

    /// The card for an agent's hook, or the waiting card it takes away. Any failure exits 1: an
    /// agent reads 2, and Gemini CLI any other code, as "block". Without a GUI session there is
    /// nothing to show, which is no failure: drip exits 0 and prints nothing, so an agent used over
    /// ssh shows no hook error after every turn.
    private func hook(_ command: HookCommand) -> Int32 {
        let flags = command.options.flags
        let console = Console(quiet: flags.quiet)
        console.warnAbout(command.options)
        let status: Int32
        do {
            // One byte past the limit tells a payload that was cut from one that fits.
            guard let payload = command.payload ?? StandardInput.read(limit: AgentHook.payloadLimit + 1) else {
                throw UsageError("no hook payload: pass it as an argument or on stdin")
            }
            #if os(WASI)
            // A session nobody attends, such as `claude -p` in a pipeline, or one an orchestrator
            // silenced with DRIP_HOOK=off: nothing to show, nothing to take away, nothing to fail.
            guard try AgentHook.speaks(for: command.agent, environment: ProcessInfo.processInfo.environment) else {
                return ExitStatus.shown
            }
            if payload.utf8.count > AgentHook.payloadLimit {
                throw UsageError("the hook payload is larger than 4 MB")
            }
            guard case let .card(event) = try AgentHook.outcome(
                agent: command.agent, payload: payload, environment: ProcessInfo.processInfo.environment)
            else {
                return ExitStatus.shown
            }
            guard display.hasGUISession else { return ExitStatus.shown }
            var cardFlags = event.filling(flags)
            cardFlags.icon = cardFlags.icon ?? command.agent.icon(installed: display.isInstalled)
            let card = try makeResolver(console).resolve(kind: event.kind, title: event.title, flags: cardFlags)
            #else
            guard let card = try AgentHook.card(
                agent: command.agent, payload: payload, flags: flags, in: surroundings(console))
            else {
                return ExitStatus.shown
            }
            #endif
            // An agent's hook keeps its output clean, terminal or not.
            status = deliver([card], wait: flags.wait, remind: false, console: console)
        } catch {
            status = report(error, console, subcommand: HookCommand.configuration.commandName)
        }
        return status == ExitStatus.shown || status == ExitStatus.noGUISession ? ExitStatus.shown : ExitStatus.hookFailed
    }

    /// Shows the cards of agents on another machine until stopped, or prints the launchd agent that
    /// runs it.
    private func follow(_ command: FollowCommand) -> Int32 {
        let console = Console()
        #if os(WASI)
        console.error("drip follow reads another machine over ssh, which WebAssembly cannot")
        return ExitStatus.usage
        #else
        let environment = ProcessInfo.processInfo.environment
        let target = command.target ?? ""
        let activate = CardActivation.target(flag: command.activate, sender: CardActivation.sender(in: environment))
        if activate == nil, command.activate == nil {
            console.warn("drip cannot tell which terminal you use: a click on a card brings nothing forward until you pass --activate")
        }
        if command.launchd {
            print(FollowAgent.plist(
                command: [Self.executable(environment: environment)] + Array(CommandLine.arguments.dropFirst())
                    .filter { $0 != "--launchd" } + (command.activate == nil ? activate.map { ["--activate", $0] } ?? [] : []),
                target: target, environment: environment), terminator: "")
            return ExitStatus.shown
        }
        let settings = RemoteFollower.Settings(
            target: target, queue: command.queue, maxAge: command.maxAge,
            ssh: [environment["DRIP_SSH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin/ssh"],
            positionPath: FollowPosition.path(target: target, environment: environment))
        // herdr names a machine by the label it was saved under, which need not be the ssh target.
        let herdrMachine = command.herdrMachine(savedMachines: {
            Terminal.output(["herdr", "machine", "list", "--json"], timeout: 5)
        })
        let follower = RemoteFollower(settings: settings, handle: { event, stale in
            let surroundings = event.surroundings(
                self.surroundings(console), activate: activate, herdrMachine: herdrMachine, stale: stale)
            do {
                guard let card = try AgentHook.card(agent: event.agent, payload: event.payload, in: surroundings) else {
                    return
                }
                _ = self.deliver([card], wait: false, remind: false, console: console)
            } catch {
                console.error("\(target): a \(event.agent.rawValue) event from \(event.machine): \(error)")
            }
        }, log: { console.error($0) })
        console.error("following \(target)" + (herdrMachine.map { ", which herdr calls \($0)" } ?? ""))
        do {
            try follower.run()
        } catch {
            console.error("\(error)")
            return ExitStatus.followFailed
        }
        return ExitStatus.shown
        #endif
    }

    /// The drip a launchd agent runs: this one, by the name `PATH` finds it under when it does, as
    /// Homebrew's link, which stays put when Homebrew upgrades drip.
    private static func executable(environment: [String: String]) -> String {
        let this = (Bundle.main.executablePath ?? CommandLine.arguments[0]) as NSString
        let resolved = this.resolvingSymlinksInPath
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return directories.map { ($0 as NSString).appendingPathComponent("drip") }
            .first { $0.hasPrefix("/") && ($0 as NSString).resolvingSymlinksInPath == resolved } ?? resolved
    }

    /// Asks every drip showing cards to take them away, those with `--id` only when it is given.
    private func dismiss(_ command: DismissCommand) -> Int32 {
        #if os(WASI)
        Console().error("drip dismiss takes away cards on your Mac, which WebAssembly cannot")
        return ExitStatus.dismissFailed
        #else
        do {
            try DismissRequests(environment: ProcessInfo.processInfo.environment).request(id: command.id)
            return ExitStatus.shown
        } catch {
            Console().error("cannot dismiss: \(error)")
            return ExitStatus.dismissFailed
        }
        #endif
    }

    /// Adds drip's hooks to the agent's settings, or prints them.
    private func setup(_ command: SetupCommand) -> Int32 {
        guard let agent = command.agent else {
            print(RemoteHook.script, terminator: "")
            return ExitStatus.shown
        }
        if command.printOnly || command.remote {
            print(AgentSetup.snippet(for: agent, remote: command.remote), terminator: "")
            return ExitStatus.shown
        }
        let console = Console()
        #if os(WASI)
        console.error("drip setup changes files, which WebAssembly cannot")
        return ExitStatus.setupFailed
        #else
        switch SetupInstaller(environment: ProcessInfo.processInfo.environment).install(agent) {
        case let .done(lines, warnings):
            warnings.forEach(console.warn)
            lines.forEach { print($0) }
            remindIfPaused(console)
            return ExitStatus.shown
        case let .refused(reason, snippet):
            console.error(reason)
            print(snippet, terminator: "")
            return ExitStatus.setupFailed
        case let .failed(message):
            console.error(message)
            return ExitStatus.setupFailed
        }
        #endif
    }

    /// Everything that can fail is checked here, before the cards are handed off. `record` is false
    /// for cards shown again from the history. `remind` says whether to print that drip is paused:
    /// a drip that waits for its card says so as it starts to wait instead.
    private func deliver(
        _ cards: [Card], wait: Bool, record: Bool = true, remind: Bool = true, console: Console
    ) -> Int32 {
        let cards = display.prepare(cards, console: console)
        switch Delivery.choose(for: cards, wait: wait) {
        case .background:
            if remind { remindIfPaused(console) }
            return display.showInBackground(BackgroundRequest(cards: cards, record: record), console: console)
        case .wait: return display.show(cards, locked: .wait(record: record), console: console)
        }
    }

    /// The background drip a foreground one started: shows the cards from standard input, saying how
    /// each click went only on a standard error that is a log, as `drip follow`'s.
    private func background() -> Int32 {
        #if canImport(AppKit)
        guard let request = BackgroundDrip.readRequest() else { return ExitStatus.usage }
        let console = Console(quiet: true, background: true)
        if let handOff = request.handOff { return HUDDisplay().resume(handOff, console: console) }
        return display.show(request.cards, locked: request.locked, console: console)
        #else
        return ExitStatus.noGUISession
        #endif
    }

    /// Runs the command first, whatever happens to the card after, and exits with its code. A bad
    /// config or environment still gets reported, and the card falls back to the defaults.
    private func run(_ command: RunCommand) -> Int32 {
        let flags = command.options.flags
        let console = Console(quiet: flags.quiet)
        console.warnAbout(command.options)
        let resolver: CardResolver
        do {
            resolver = try makeResolver(console)
        } catch {
            _ = report(error, console)
            resolver = CardResolver()
        }

        let clock = ContinuousClock()
        let start = clock.now
        #if os(WASI)
        let outcome = CommandRunner.Outcome(status: 126, error: "\(command.command[0]): cannot run commands in WebAssembly")
        #else
        let outcome = CommandRunner.run(command.command)
        #endif
        let elapsed = (clock.now - start).components
        if let error = outcome.error {
            console.error(error)
        }
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        do {
            let card = try resolver.resolveRun(
                command: command.command, status: outcome.status, seconds: seconds, flags: flags)
            _ = deliver([card], wait: flags.wait, console: console)
        } catch {
            _ = report(error, console)
        }
        // The card is on its way; Ctrl-C now stops the script that ran drip, as it would the command.
        #if !os(WASI)
        CommandRunner.endLikeTheCommand(outcome)
        #endif
        return outcome.status
    }

    /// Lists the cards in the history, newest first, or prints them as JSON or shows them again,
    /// oldest first.
    private func history(_ command: HistoryCommand) -> Int32 {
        let console = Console()
        let environment = ProcessInfo.processInfo.environment
        // The listing is the last cards; JSON and replay are all of them, unless -n limits them.
        let count = command.all ? nil : command.number ?? (command.json || command.replay ? nil : HistoryListing.defaultCount)
        let entries = HistoryListing.newest(
            HistoryListing.select(CardHistory(environment: environment).entries(), missed: command.missed), count: count)
        if command.replay {
            guard !entries.isEmpty else { return ExitStatus.shown }
            return deliver(entries.map(HistoryListing.replay), wait: false, record: false, console: console)
        }
        do {
            if command.json {
                for entry in entries { print(try HistoryListing.publicJSON(entry)) }
            } else if !entries.isEmpty {
                let color = isatty(STDOUT_FILENO) != 0 && (environment["NO_COLOR"] ?? "").isEmpty
                print(HistoryListing.render(entries, color: color))
            }
        } catch {
            return report(error, console)
        }
        remindIfPaused(console)
        return ExitStatus.shown
    }

    /// Pauses drip for `seconds`, or, without them, says how long is left of the pause, pausing for
    /// an hour when there is none.
    private func pause(_ seconds: Double?) -> Int32 {
        let pause = DripPause(environment: ProcessInfo.processInfo.environment)
        let now = Date()
        do {
            let end: Date
            if seconds == nil, let current = pause.end(now: now) {
                end = current
            } else {
                end = now.addingTimeInterval(seconds ?? DripPause.defaultDuration)
                try pause.pause(until: end)
            }
            print(DripPause.status(end: end, now: now) + ". drip resume ends it now.")
            return ExitStatus.shown
        } catch {
            Console().error("\(error)")
            return ExitStatus.pauseFailed
        }
    }

    /// Ends the pause now; the cards it held show once the holder notices, within a second.
    private func resume() -> Int32 {
        do {
            let paused = try DripPause(environment: ProcessInfo.processInfo.environment).resume()
            print(paused ? "drip is no longer paused." : "drip is not paused.")
            return ExitStatus.shown
        } catch {
            Console().error("\(error)")
            return ExitStatus.pauseFailed
        }
    }

    /// While drip is paused, says so on stderr with the time left, so a pause is never forgotten.
    /// Only in a terminal: a pipe, a script's log and an agent's hook stay clean.
    private func remindIfPaused(_ console: Console) {
        guard !console.quiet, isatty(STDERR_FILENO) != 0,
              let end = DripPause(environment: ProcessInfo.processInfo.environment).end()
        else { return }
        FileHandle.standardError.write(Data((DripPause.reminder(end: end) + "\n").utf8))
    }

    private func render(_ command: RenderCommand) -> Int32 {
        let flags = command.flags
        let console = Console(quiet: flags.quiet)
        console.warnAbout(command.options)
        do {
            let card = try makeResolver(console).resolve(kind: command.kind, title: command.title, flags: flags)
            return display.render(card, appearance: command.appearance, at: command.at, leaving: command.leaving, to: command.out, console: console)
        } catch {
            return report(error, console)
        }
    }

    #if !os(WASI)
    /// What an agent's hook reads around its event on this Mac.
    private func surroundings(_ console: Console) -> AgentHook.Surroundings {
        AgentHook.Surroundings(
            environment: ProcessInfo.processInfo.environment, hasGUISession: display.hasGUISession,
            isInstalled: display.isInstalled, front: display.front(of:), paneShowing: display.paneShowing,
            resolver: { try makeResolver(console, environment: $0) })
    }
    #endif

    /// Reads the config file and environment, printing the config file's warnings.
    private func makeResolver(
        _ console: Console, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CardResolver {
        let file = try ConfigLoader.load(environment: environment)
        file.warnings.forEach(console.warn)
        let settings = try EnvironmentSettings(environment: environment)
        return CardResolver(config: file.config, environment: settings)
    }

    /// Prints an error and returns its exit status. A usage mistake also says where the help is.
    private func report(_ error: Error, _ console: Console, subcommand: String? = nil) -> Int32 {
        if let error = error as? ConfigError {
            console.error("invalid config: \(error)")
            return ExitStatus.invalidConfig
        }
        if let error = error as? UsageError {
            FileHandle.standardError.write(Data((CardText.printable(
                CommandLineParser.usageMessage(error.message, subcommand: subcommand)) + "\n").utf8))
            return ExitStatus.usage
        }
        console.error("\(error)")
        return ExitStatus.usage
    }
}

#if !canImport(AppKit)
/// Used where AppKit is missing: every card fails as if there were no GUI session.
struct UnavailableDisplay: CardDisplay {
    func show(_ cards: [Card], locked: LockedScreen, stack: StackSettings?, console: Console) -> Int32 {
        console.error("no GUI session: drip shows cards only on macOS")
        return ExitStatus.noGUISession
    }

    func showInBackground(_ request: BackgroundRequest, console: Console) -> Int32 {
        show(request.cards, locked: .wait(record: request.record), console: console)
    }

    func prepare(_ cards: [Card], console: Console) -> [Card] {
        cards
    }

    func isInstalled(_ bundleIdentifier: String) -> Bool {
        false
    }

    var hasGUISession: Bool { false }

    func front(of card: Card) -> WhenFocused.Front {
        WhenFocused.Front(app: false)
    }

    func paneShowing(_ card: Card) -> Bool? {
        nil
    }

    func render(
        _ card: Card, appearance: RenderCommand.Appearance, at time: Double?, leaving: Bool, to path: String,
        console: Console
    ) -> Int32 {
        console.error("no GUI session: drip renders cards only on macOS")
        return ExitStatus.noGUISession
    }
}
#endif
