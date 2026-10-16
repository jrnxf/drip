import BlipCore
import Foundation

/// Shows and renders cards. The macOS implementation is in HUDWindow.swift and Render.swift.
protocol CardDisplay {
    /// Shows the card and returns once it has faded out, with the exit status to report.
    func show(_ card: Card, console: Console) -> Int32

    /// Draws the card offscreen into a PNG file.
    func render(
        _ card: Card, appearance: RenderCommand.Appearance, to path: String, console: Console
    ) -> Int32
}

/// Writes messages to stderr.
struct Console {
    var quiet = false

    /// Prints a warning unless --quiet was given.
    func warn(_ message: String) {
        if !quiet { error("warning: \(message)") }
    }

    func error(_ message: String) {
        FileHandle.standardError.write(Data("blip: \(message)\n".utf8))
    }
}

/// The command-line entry point, independent of how cards are drawn.
struct BlipCLI {
    var display: CardDisplay

    func run(_ arguments: [String]) -> Int32 {
        switch CommandLineParser.parse(arguments) {
        case let .exit(status, message):
            if status == 0 {
                print(message)
            } else {
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            return status
        case let .invocation(.show(command)):
            return show(command)
        case let .invocation(.run(command)):
            return run(command)
        case let .invocation(.render(command)):
            return render(command)
        }
    }

    /// `--wait` needs no handling yet: the card is shown in-process, so blip always returns once
    /// it has faded out.
    private func show(_ command: BlipCommand) -> Int32 {
        let flags = command.options.flags
        let console = Console(quiet: flags.quiet)
        do {
            let card = try makeResolver(console).resolve(
                kind: command.kind, title: command.title, flags: flags, standardInput: StandardInput.read)
            return display.show(card, console: console)
        } catch {
            return report(error, console)
        }
    }

    /// Runs the command first, whatever happens to the card after, and exits with its code. A bad
    /// config or environment still gets reported, and the card falls back to the defaults.
    private func run(_ command: RunCommand) -> Int32 {
        let flags = command.options.flags
        let console = Console(quiet: flags.quiet)
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
            _ = display.show(card, console: console)
        } catch {
            _ = report(error, console)
        }
        return outcome.status
    }

    private func render(_ command: RenderCommand) -> Int32 {
        let flags = command.options.flags
        let console = Console(quiet: flags.quiet)
        do {
            let card = try makeResolver(console).resolve(kind: command.kind, title: command.title, flags: flags)
            return display.render(card, appearance: command.appearance, to: command.out, console: console)
        } catch {
            return report(error, console)
        }
    }

    /// Reads the config file and environment, printing the config's warnings.
    private func makeResolver(_ console: Console) throws -> CardResolver {
        let environment = ProcessInfo.processInfo.environment
        let file = try ConfigLoader.load(environment: environment)
        file.warnings.forEach(console.warn)
        return CardResolver(config: file.config, environment: try EnvironmentSettings(environment: environment))
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
    func show(_ card: Card, console: Console) -> Int32 {
        console.error("no GUI session: blip shows cards only on macOS")
        return ExitStatus.noGUISession
    }

    func render(
        _ card: Card, appearance: RenderCommand.Appearance, to path: String, console: Console
    ) -> Int32 {
        console.error("no GUI session: blip renders cards only on macOS")
        return ExitStatus.noGUISession
    }
}
#endif
