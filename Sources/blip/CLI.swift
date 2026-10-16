import BlipCore
import Foundation

/// Shows and renders cards. The macOS implementation is in HUDWindow.swift and Render.swift.
protocol CardDisplay {
    /// Shows the card and returns once it has faded out, with the exit status to report.
    func show(_ card: Card, console: Console) -> Int32

    /// Draws the card offscreen into a PNG file.
    func render(
        _ card: Card, appearance: RenderCommand.Appearance, scale: Double, to path: String, console: Console
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
            let console = Console()
            guard let card = resolve(kind: command.kind, title: command.title, options: command.options, console)
            else { return ExitStatus.usage }
            return display.show(card, console: console)
        case let .invocation(.render(command)):
            let console = Console()
            guard let card = resolve(kind: command.kind, title: command.title, options: command.options, console)
            else { return ExitStatus.usage }
            return display.render(
                card, appearance: command.appearance, scale: command.scale, to: command.out, console: console)
        }
    }

    private func resolve(kind: String?, title: String?, options: CardOptions, _ console: Console) -> Card? {
        do {
            return try CardResolver().resolve(kind: kind, title: title, flags: options.flags)
        } catch {
            console.error("\(error)")
            return nil
        }
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
        _ card: Card, appearance: RenderCommand.Appearance, scale: Double, to path: String, console: Console
    ) -> Int32 {
        console.error("no GUI session: blip renders cards only on macOS")
        return ExitStatus.noGUISession
    }
}
#endif
