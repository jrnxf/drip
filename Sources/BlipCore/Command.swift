import ArgumentParser

/// Process exit codes.
public enum ExitStatus {
    public static let shown: Int32 = 0
    public static let usage: Int32 = 2
    public static let noGUISession: Int32 = 3
    public static let invalidConfig: Int32 = 4
}

/// Options shared by every command that shows a card.
public struct CardOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: ArgumentHelp("The second, gray line.", valueName: "text"))
    public var detail: String?

    public init() {}

    /// The parsed values, as a plain value.
    public var flags: CardFlags {
        CardFlags(detail: detail)
    }
}

/// The card options from the command line; nil where a flag was not given.
public struct CardFlags: Equatable {
    public var detail: String?

    public init(detail: String? = nil) {
        self.detail = detail
    }
}

/// `blip [KIND] [TITLE] [options]`
public struct BlipCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "blip",
        abstract: "Show a brief HUD card on macOS.",
        usage: """
            blip [KIND] [TITLE] [options]
              blip --version | --help
            """,
        version: blipVersion
    )

    @Argument(help: ArgumentHelp(
        "ok, warn, fail or info. Taken as the title when it is not a preset.",
        valueName: "kind"))
    public var kind: String?

    @Argument(help: ArgumentHelp("The bold line.", valueName: "title"))
    public var title: String?

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
        abstract: "Draw a card offscreen into a PNG.",
        usage: "blip __render --out <file.png> [KIND] [TITLE] [options]"
    )

    @Argument public var kind: String?
    @Argument public var title: String?
    @OptionGroup public var options: CardOptions

    @Option(help: "Where to write the PNG.")
    public var out: String

    @Option(help: "light or dark.")
    public var appearance: Appearance = .light

    @Option(help: "Pixels per point.")
    public var scale: Double = 2

    public init() {}

    public func validate() throws {
        guard scale >= 1, scale <= 4 else {
            throw ValidationError("--scale must be between 1 and 4.")
        }
    }
}

/// What the command line asks blip to do.
public enum Invocation {
    case show(BlipCommand)
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
