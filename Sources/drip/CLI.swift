import DripCore
import Foundation

/// Shows and renders cards. The macOS implementation is in HUDWindow.swift and Render.swift.
protocol CardDisplay {
    /// The style for cards that set none: `glass` where the system has it.
    var automaticStyle: CardStyle { get }

    /// Whether the screen a card would appear on has a camera notch.
    var hasNotch: Bool { get }

    /// Shows the cards one after another, after any other drip's, and returns once the last has
    /// gone, with the exit status to report. `locked` says what happens while the screen is locked.
    func show(_ cards: [Card], locked: LockedScreen, console: Console) -> Int32

    /// Hands the cards to a background drip and returns at once, or shows them here when it cannot.
    func showInBackground(_ request: BackgroundRequest, console: Console) -> Int32

    /// Checks the cards' sounds and icons, warning about and replacing any that cannot load.
    func prepare(_ cards: [Card], console: Console) -> [Card]

    /// Draws the card offscreen into a PNG file; a notch card `at` seconds into its entrance, or
    /// its exit when `leaving`.
    func render(
        _ card: Card, appearance: RenderCommand.Appearance, at time: Double?, leaving: Bool, to path: String,
        console: Console
    ) -> Int32
}

/// Writes messages to stderr.
struct Console {
    var quiet = false

    /// Prints a warning unless --quiet was given.
    func warn(_ message: String) {
        if !quiet { error("warning: \(message)") }
    }

    /// Warns about card options that were given but say nothing.
    func warnAbout(_ options: CardOptions) {
        if options.opensNothing { warn("--open is empty, so the card has no button") }
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
        case let .invocation(.demo(command)):
            return demo(command)
        case let .invocation(.hook(command)):
            return hook(command)
        case let .invocation(.history(command)):
            return history(command)
        case let .invocation(.render(command)):
            return render(command)
        case .invocation(.background):
            return background()
        }
    }

    private func show(_ command: DripCommand) -> Int32 {
        let flags = command.options.flags
        let console = Console(quiet: flags.quiet)
        console.warnAbout(command.options)
        do {
            let card = try makeResolver(console).resolve(
                kind: command.kind, title: command.title, flags: flags, standardInput: StandardInput.read)
            return deliver([card], wait: flags.wait, console: console)
        } catch {
            return report(error, console)
        }
    }

    /// The card for an agent's hook. Never exits 2, which an agent reads as "block": a mistake exits
    /// 1 instead.
    private func hook(_ command: HookCommand) -> Int32 {
        var flags = command.options.flags
        let console = Console(quiet: flags.quiet)
        console.warnAbout(command.options)
        let status: Int32
        do {
            // One byte past the limit tells a payload that was cut from one that fits.
            guard let payload = command.payload ?? StandardInput.read(limit: AgentHook.payloadLimit + 1) else {
                throw UsageError("no hook payload: pass it as an argument or on stdin")
            }
            if payload.utf8.count > AgentHook.payloadLimit {
                throw UsageError("the hook payload is larger than 4 MB")
            }
            let event = try AgentHook.event(agent: command.agent, payload: payload)
            flags.id = flags.id ?? event.id
            flags.detail = flags.detail ?? event.detail
            let card = try makeResolver(console).resolve(kind: event.kind, title: event.title, flags: flags)
            status = deliver([card], wait: flags.wait, console: console)
        } catch {
            status = report(error, console)
        }
        return status == ExitStatus.usage ? ExitStatus.hookFailed : status
    }

    /// Everything that can fail is checked here, before the cards are handed off. `record` is false
    /// for cards shown again from the history.
    private func deliver(_ cards: [Card], wait: Bool, record: Bool = true, console: Console) -> Int32 {
        let cards = display.prepare(cards, console: console)
        switch Delivery.choose(for: cards, wait: wait) {
        case .background: return display.showInBackground(BackgroundRequest(cards: cards, record: record), console: console)
        case .wait: return display.show(cards, locked: .wait(record: record), console: console)
        }
    }

    /// The background drip a foreground one started: shows the cards from standard input, with
    /// nowhere to print to.
    private func background() -> Int32 {
        #if canImport(AppKit)
        guard let request = BackgroundDrip.readRequest() else { return ExitStatus.usage }
        return display.show(request.cards, locked: request.locked, console: Console(quiet: true))
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
        let outcome = CommandRunner.run(command.command)
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
        CommandRunner.endLikeTheCommand(outcome)
        return outcome.status
    }

    /// A few notch cards, one after another, the way queued cards show. Silent unless --sound or
    /// DRIP_SOUND is given.
    private func demo(_ command: DemoCommand) -> Int32 {
        var flags = command.options.flags
        let console = Console(quiet: flags.quiet)
        console.warnAbout(command.options)
        if flags.position != nil { console.warn("drip demo shows only notch cards, so --position does nothing") }
        if flags.style != nil, display.hasNotch {
            console.warn("drip demo shows only notch cards, so --style does nothing")
        }
        do {
            let resolver = try makeResolver(console)
            // Short and silent, unless a flag, the environment or the config says otherwise.
            if flags.seconds == nil, resolver.environment.seconds == nil, resolver.config.seconds == nil {
                flags.seconds = 2
            }
            if flags.sound == nil, resolver.environment.sound == nil { flags.sound = Sound.none }
            if !display.hasNotch {
                console.warn("this screen has no notch, so the cards show at the top")
            }
            let cards = try DemoCommand.cards(resolver, flags: flags)
            return display.show(display.prepare(cards, console: console), locked: .ignore, console: console)
        } catch {
            return report(error, console)
        }
    }

    /// Lists the cards in the history, or shows them again, oldest first.
    private func history(_ command: HistoryCommand) -> Int32 {
        let console = Console()
        let entries = HistoryListing.select(
            CardHistory(environment: ProcessInfo.processInfo.environment).entries(), missed: command.missed)
        if command.replay {
            guard !entries.isEmpty else { return ExitStatus.shown }
            return deliver(entries.map(HistoryListing.replay), wait: false, record: false, console: console)
        }
        do {
            for entry in entries {
                print(command.json ? try HistoryListing.publicJSON(entry) : HistoryListing.line(entry))
            }
        } catch {
            return report(error, console)
        }
        return ExitStatus.shown
    }

    private func render(_ command: RenderCommand) -> Int32 {
        let flags = command.options.flags
        let console = Console(quiet: flags.quiet)
        console.warnAbout(command.options)
        do {
            // Renderings must not depend on the machine, so the automatic style is always hud here.
            let card = try makeResolver(console, automaticStyle: .hud)
                .resolve(kind: command.kind, title: command.title, flags: flags)
            return display.render(card, appearance: command.appearance, at: command.at, leaving: command.leaving, to: command.out, console: console)
        } catch {
            return report(error, console)
        }
    }

    /// Reads the config file and environment, printing the config's warnings.
    private func makeResolver(_ console: Console, automaticStyle: CardStyle? = nil) throws -> CardResolver {
        let environment = ProcessInfo.processInfo.environment
        let file = try ConfigLoader.load(environment: environment)
        file.warnings.forEach(console.warn)
        return CardResolver(
            config: file.config, environment: try EnvironmentSettings(environment: environment),
            automaticStyle: automaticStyle ?? display.automaticStyle)
    }

    /// Prints an error and returns its exit status.
    private func report(_ error: Error, _ console: Console) -> Int32 {
        if let error = error as? ConfigError {
            console.error("invalid config: \(error)")
            return ExitStatus.invalidConfig
        }
        console.error("\(error)")
        return ExitStatus.usage
    }
}

#if !canImport(AppKit)
/// Used where AppKit is missing: every card fails as if there were no GUI session.
struct UnavailableDisplay: CardDisplay {
    var automaticStyle: CardStyle { Defaults.style }
    var hasNotch: Bool { false }

    func show(_ cards: [Card], locked: LockedScreen, console: Console) -> Int32 {
        console.error("no GUI session: drip shows cards only on macOS")
        return ExitStatus.noGUISession
    }

    func showInBackground(_ request: BackgroundRequest, console: Console) -> Int32 {
        show(request.cards, locked: .wait(record: request.record), console: console)
    }

    func prepare(_ cards: [Card], console: Console) -> [Card] {
        cards
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
