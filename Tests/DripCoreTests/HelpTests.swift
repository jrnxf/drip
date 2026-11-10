@testable import DripCore
import Testing

/// What each subcommand's `--help` lists is what its parser accepts, and nothing it rejects.
struct HelpTests {
    /// The arguments that run `name` with `option` and a value, enough for the parser to get to it.
    private func arguments(_ name: String, _ option: String) -> [String] {
        switch name {
        case "hook": ["hook", "claude", option, "1"]
        case "run": ["run", option, "1", "true"]
        default: [name, option, "1"]
        }
    }

    /// The error the parser gives for the arguments, if it is one that names the option as unknown
    /// or as one the command takes no part in.
    private func rejection(_ arguments: [String]) -> String? {
        guard case let .exit(_, message) = CommandLineParser.parse(arguments) else { return nil }
        let lowered = message.lowercased()
        return lowered.contains("unknown option") || lowered.contains("invalid option") || lowered.contains(" takes no ")
            ? message : nil
    }

    /// The long options a help text lists: lines that start with two spaces and the option.
    private func listed(_ help: String) -> [String] {
        help.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("  -"), !line.hasPrefix("   ") else { return nil }
            return line.split(separator: " ").first { $0.hasPrefix("--") }
                .map { String($0.split(separator: ",")[0]) }
        }
    }

    private var names: [String] {
        DripCommand.configuration.subcommands.filter { $0.configuration.shouldDisplay }
            .compactMap { $0.configuration.commandName }
    }

    @Test func everyListedOptionParses() {
        for name in names {
            guard case let .exit(_, help) = CommandLineParser.parse([name, "--help"]) else {
                Issue.record("drip \(name) --help is not help")
                continue
            }
            let options = listed(help).filter { $0 != "--help" }
            for option in options {
                #expect(rejection(arguments(name, option)) == nil, "drip \(name) --help lists \(option), which its parser rejects")
            }
        }
    }

    @Test func noRejectedOptionIsListed() {
        for name in names {
            guard case let .exit(_, help) = CommandLineParser.parse([name, "--help"]) else { continue }
            let options = listed(help)
            for option in CommandLineParser.valueOptions.filter({ $0.hasPrefix("--") }).union(["--stay", "--wait", "--quiet"]) {
                if rejection(arguments(name, option)) != nil {
                    #expect(!options.contains(option), "drip \(name) --help lists \(option), which its parser rejects")
                }
            }
        }
    }

    @Test func questionOptionsBelongToShow() {
        for name in ["run", "hook"] {
            guard case let .exit(_, help) = CommandLineParser.parse([name, "--help"]) else {
                Issue.record("drip \(name) --help is not help")
                continue
            }
            #expect(!listed(help).contains("--yes"))
            #expect(!listed(help).contains("--no"))
        }
        guard case let .exit(_, help) = CommandLineParser.parse(["show", "--help"]) else {
            Issue.record("drip show --help is not help")
            return
        }
        #expect(listed(help).contains("--yes"))
        #expect(listed(help).contains("--no"))
    }
}
