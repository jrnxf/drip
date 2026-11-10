@testable import DripCore
import Testing

/// What each subcommand's `--help` lists is what its parser accepts, and its shell completions
/// offer the same.
struct HelpTests {
    /// A valid value for each option that takes one, and the options it needs beside it.
    private static let values: [String: [String]] = [
        "--detail": ["x"], "-d": ["x"], "--seconds": ["3"], "-s": ["3"], "--sound": ["none"], "--icon": ["none"],
        "--color": ["red"], "--open": ["https://example.com"], "--button": ["Go", "--open", "https://example.com"],
        "--yes": ["Go"], "--no": ["Stop", "--yes", "Go"], "--id": ["a"], "--activate": ["com.apple.Terminal"],
        "--on-click": ["true"], "--min-turn": ["5"], "--only": ["needs-you"], "--pane": ["%1"],
        "--app": ["com.apple.Terminal"], "--max-age": ["1h"], "--queue": ["/home/user/queue"], "-n": ["5"],
    ]

    /// The subcommands `drip --help` lists, with the words that make one complete.
    private static let names = DripCommand.configuration.subcommands
        .filter { $0.configuration.shouldDisplay }.compactMap { $0.configuration.commandName }

    private func help(_ arguments: [String]) -> String? {
        guard case let .exit(status, message) = CommandLineParser.parse(arguments), status == 0 else { return nil }
        return message
    }

    /// The options a help text lists: lines that start with two spaces and the option, long name first.
    private func listed(_ help: String) -> [String] {
        help.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("  -") else { return nil }
            let words = line.split(separator: " ").map { String($0.split(separator: ",")[0]) }
            return words.first { $0.hasPrefix("--") } ?? words.first
        }
    }

    /// The arguments that run `name` with `option` and a valid value.
    private func arguments(_ name: String, _ option: String, takesValue: Bool) -> [String]? {
        let value = takesValue ? Self.values[option] : []
        guard let value else { return nil }
        switch name {
        case "hook": return ["hook", "claude", option] + value
        case "run": return ["run", option] + value + ["true"]
        case "follow": return ["follow", "host", option] + value
        default: return [name, option] + value
        }
    }

    @Test func everyListedOptionParses() throws {
        for name in Self.names {
            let text = try #require(help([name, "--help"]), "drip \(name) --help is not help")
            for line in text.split(separator: "\n") where line.hasPrefix("  -") {
                let option = try #require(listed(String(line)).first)
                guard let command = arguments(name, option, takesValue: line.contains("<")) else {
                    Issue.record("drip \(name) lists \(option), which HelpTests has no value for")
                    continue
                }
                if case let .exit(status, message) = CommandLineParser.parse(command), status != 0 {
                    Issue.record("drip \(name) --help lists \(option), which its parser rejects: \(message)")
                }
            }
        }
    }

    @Test func questionOptionsBelongToShow() throws {
        for name in ["run", "hook"] {
            let options = listed(try #require(help([name, "--help"])))
            #expect(!options.contains("--yes") && !options.contains("--no"), "drip \(name)")
        }
        let options = listed(try #require(help(["show", "--help"])))
        #expect(options.contains("--yes") && options.contains("--no"))
        // They say what to do instead, and exit as other usage errors do.
        for (arguments, status) in [
            (["run", "--yes", "Go", "true"], ExitStatus.usage), (["run", "--no", "true"], ExitStatus.usage),
            (["hook", "claude", "--yes", "Go", "{}"], ExitStatus.hookFailed),
            (["hook", "claude", "--no=Stop", "{}"], ExitStatus.hookFailed),
        ] {
            guard case let .exit(code, message) = CommandLineParser.parse(arguments) else {
                Issue.record("\(arguments) parsed")
                continue
            }
            #expect(code == status, "\(arguments)")
            #expect(message.contains("takes no --") && message.contains("drip warn \"Deploy?\" --yes Deploy"), "\(message)")
        }
    }

    /// Help does not win over a mistake: --help after the command is the command's own.
    @Test func runIsNotHelpedByAnUnknownOption() {
        guard case let .exit(status, message) = CommandLineParser.parse(["run", "--bogus", "make", "--help"]) else {
            Issue.record("drip run --bogus parsed")
            return
        }
        #expect(status == ExitStatus.usage)
        #expect(message.contains("unknown option '--bogus'"), "\(message)")
    }

    /// The renderer asks the same questions show does.
    @Test func renderChecksTheQuestion() {
        for question in [["--no", "Stop"], ["--yes", "A", "--open", "https://example.com"]] {
            guard case let .exit(status, _) = CommandLineParser.parse(["__render", "--out", "card.png"] + question) else {
                Issue.record("\(question) parsed")
                continue
            }
            #expect(status == ExitStatus.usage, "\(question)")
        }
    }

    /// Only show says to ask a question for a --button without --open.
    @Test func buttonHintNamesYesOnlyForShow() {
        for (arguments, hint) in [(["ok", "t", "--button", "x"], true), (["run", "--button", "x", "true"], false),
                                  (["hook", "claude", "--button", "x", "{}"], false)] {
            guard case let .exit(_, message) = CommandLineParser.parse(arguments) else {
                Issue.record("\(arguments) parsed")
                continue
            }
            #expect(message.contains("use --yes") == hint, "\(arguments): \(message)")
        }
    }

    @Test func completionsOfRunAndHookOfferNoQuestion() throws {
        for shell in ["zsh", "bash", "fish"] {
            guard case let .exit(_, script) = CommandLineParser.parse(["--generate-completion-script", shell]) else {
                Issue.record("no \(shell) completion script")
                continue
            }
            let tokens = shell == "fish" ? ["-l 'yes'", "-l 'no'"] : ["--yes", "--no"]
            for name in ["run", "hook"] {
                let text = Self.section(of: script, for: name, shell: shell)
                #expect(!text.isEmpty, "\(shell) \(name)")
                for token in tokens { #expect(!text.contains(token), "\(shell) \(name) offers \(token)") }
            }
            let show = Self.section(of: script, for: "show", shell: shell)
            for token in tokens { #expect(show.contains(token), "\(shell) show lacks \(token)") }
        }
    }

    /// The part of a completion script for one subcommand.
    private static func section(of script: String, for name: String, shell: String) -> String {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if shell == "fish" {
            return lines.filter { $0.contains("\"drip \(name)\"") }.joined(separator: "\n")
        }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("_drip_\(name)") }) else { return "" }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("_drip_") } ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }
}
