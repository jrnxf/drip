@testable import DripCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import Testing

/// One test per row of the CLI table, plus help, version and the hidden render command.
struct CommandTests {
    @Test func kindAndTitlePositionals() throws {
        let command = try show(["ok", "hi"])
        #expect(command.kind == "ok")
        #expect(command.title == "hi")
        let titleOnly = try show(["build finished"])
        #expect(titleOnly.kind == "build finished")
        #expect(titleOnly.title == nil)
        let none = try show([])
        #expect(none.kind == nil)
        #expect(none.title == nil)
    }

    @Test func detail() throws {
        #expect(try flags(["ok", "hi", "-d", "there"]).detail == "there")
        #expect(try flags(["ok", "hi", "--detail", "there"]).detail == "there")
        #expect(try flags(["ok", "hi"]).detail == nil)
    }

    @Test func helpAndVersionAsWords() {
        for (word, flag) in [("help", "--help"), ("version", "--version")] {
            guard case let .exit(status, message) = CommandLineParser.parse([word]),
                  case let .exit(_, expected) = CommandLineParser.parse([flag])
            else {
                Issue.record("drip \(word) parsed as a card")
                continue
            }
            #expect(status == 0)
            #expect(message == expected)
        }
        // With anything after it, version is read as usual: here, a card titled version. help is
        // ArgumentParser's own subcommand.
        #expect((try? show(["version", "-d", "x"]))?.kind == "version")
    }

    /// `drip help run` shows run's help, as `drip run --help` does.
    @Test func helpForASubcommand() {
        for name in ["run", "hook", "setup", "demo", "history", "show"] {
            guard case let .exit(status, help) = CommandLineParser.parse(["help", name]),
                  case let .exit(_, flag) = CommandLineParser.parse([name, "--help"]),
                  case let .exit(_, short) = CommandLineParser.parse([name, "-h"])
            else { Issue.record("drip help \(name) parsed"); continue }
            #expect(status == 0)
            #expect(help == flag, "\(name)")
            #expect(help == short, "\(name)")
            #expect(!help.contains("SUBCOMMANDS"), "\(name)")
        }
        guard case let .exit(_, run) = CommandLineParser.parse(["help", "run"]) else { Issue.record(); return }
        #expect(run.hasPrefix("OVERVIEW: Run a command, then show ok or fail with how long it took.\n\nUSAGE: drip run"), "\(run)")
        // The options after the command are the command's.
        guard case let .invocation(.run(command)) = CommandLineParser.parse(["run", "make", "--help"]) else {
            Issue.record(); return
        }
        #expect(command.command == ["make", "--help"])
    }

    @Test func aTitleThatStartsWithADashIsExplained() throws {
        guard case let .exit(status, message) = CommandLineParser.parse(["fail", "--- FAIL: TestFoo"]) else {
            Issue.record("a title starting with dashes parsed")
            return
        }
        #expect(status == 2)
        #expect(message.hasPrefix("drip: '--- FAIL: TestFoo' starts with a dash, so it reads as an option."))
        #expect(message.hasSuffix("drip fail -- '--- FAIL: TestFoo'\nSee 'drip --help'."))
        // After --, it is the title.
        #expect(try show(["fail", "--", "--- FAIL: TestFoo"]).title == "--- FAIL: TestFoo")
        // A real unknown option, or a detail that starts with dashes next to another mistake, keeps
        // its own message.
        guard case let .exit(_, unknown) = CommandLineParser.parse(["fail", "x", "--bogus"]),
              case let .exit(_, seconds) = CommandLineParser.parse(["fail", "x", "-d", "--- F", "-s", "0.1"])
        else {
            Issue.record("a mistake parsed")
            return
        }
        #expect(unknown == "drip: unknown option '--bogus'\nSee 'drip --help'.")
        #expect(seconds.hasPrefix("drip: --seconds must be between"))
    }

    @Test func textOptionsTakeValuesThatStartWithADash() throws {
        // Command output often does: `drip fail "tests failed" -d "$err"`.
        #expect(try flags(["fail", "hi", "-d", "--- FAIL: TestFoo"]).detail == "--- FAIL: TestFoo")
        #expect(try flags(["fail", "hi", "--detail", "-1 files changed", "-s", "3"]).detail == "-1 files changed")
        #expect(try flags(["fail", "hi", "-d", "--open=/Applications/Calculator.app"]).open == nil)
        let card = try flags(["hi", "--open", "https://example.com", "--button", "-> View", "--id", "-deploy"])
        #expect(card.button == "-> View")
        #expect(card.id == "-deploy")
        // An empty value, as from `-d "$err"` when there was no error, is no detail.
        #expect(try flags(["fail", "hi", "-d", ""]).detail == "")
        #expect(try flags(["fail", "hi", "--detail", "", "-s", "3"]).seconds == 3)
        #expect(try run(["-d", "", "--", "echo", "ran"]).command == ["echo", "ran"])
    }

    @Test func seconds() throws {
        #expect(try flags(["hi", "-s", "8"]).seconds == 8)
        #expect(try flags(["hi", "--seconds", "0.5"]).seconds == 0.5)
        #expect(try flags(["hi", "--seconds", "60"]).seconds == 60)
        #expect(try flags(["hi"]).seconds == nil)
        for bad in ["0.4", "60.5", "0", "-1", "nan", "abc"] {
            assertUsageError(["hi", "--seconds", bad])
        }
    }

    @Test func sound() throws {
        #expect(try flags(["hi", "--sound", "Hero"]).sound == .named("Hero"))
        #expect(try flags(["hi", "--sound", "none"]).sound == Sound.none)
        #expect(try flags(["hi", "--sound", "/tmp/ding.aiff"]).sound == .file("/tmp/ding.aiff"))
        #expect(try flags(["hi"]).sound == nil)
    }

    @Test func icon() throws {
        #expect(try flags(["hi", "--icon", "paperplane.fill"]).icon == .symbol("paperplane.fill"))
        #expect(try flags(["hi", "--icon", "none"]).icon == Icon.none)
        #expect(try flags(["hi", "--icon", "app:com.openai.chat"]).icon == .app("com.openai.chat"))
        #expect(try flags(["hi", "--icon", "/home/user/claude.png"]).icon == .image("/home/user/claude.png"))
        // A relative path is made absolute, since another drip may draw the card.
        let relative = try flags(["hi", "--icon", "claude.png"]).icon
        guard case let .image(path) = relative else {
            Issue.record("expected an image, got \(String(describing: relative))")
            return
        }
        #expect(path.hasPrefix("/") && path.hasSuffix("/claude.png"))
        #expect(try flags(["hi"]).icon == nil)
        for bad in ["app:", "app:com apple", "app:com..apple"] {
            assertUsageError(["hi", "--icon", bad])
        }
    }

    @Test func color() throws {
        #expect(try flags(["hi", "--color", "#a78bfa"]).color == .rgb(red: 0xA7, green: 0x8B, blue: 0xFA))
        #expect(try flags(["hi", "--color", "purple"]).color == .system(.purple))
        #expect(try flags(["hi"]).color == nil)
        assertUsageError(["hi", "--color", "teal"])
        assertUsageError(["hi", "--color", "#abc"])
    }

    /// The size is a viewing preference, set in the config or DRIP_SIZE; only the snapshot tests'
    /// `__render` takes it per card.
    @Test func sizeIsASettingNotAFlag() throws {
        assertUsageError(["hi", "--size", "large"])
        guard case let .exit(_, message) = CommandLineParser.parse(["run", "--size", "large", "make"]) else {
            Issue.record(); return
        }
        #expect(message == "drip: unknown option '--size'\nSee 'drip run --help'.")
        for size in CardSize.allCases {
            guard case let .invocation(.render(command)) = CommandLineParser.parse(
                ["__render", "--out", "x.png", "hi", "--size", size.rawValue])
            else { Issue.record(); continue }
            #expect(command.flags.size == size)
        }
    }

    @Test func waitAndQuiet() throws {
        #expect(!(try flags(["hi"]).wait))
        #expect(!(try flags(["hi"]).quiet))
        #expect(try flags(["hi", "--wait"]).wait)
        #expect(try flags(["hi", "--quiet"]).quiet)
    }

    @Test func optionsMayComeFirst() throws {
        let command = try show(["--seconds", "2", "-d", "there", "warn", "hi"])
        #expect(command.kind == "warn")
        #expect(command.title == "hi")
        #expect(command.options.flags == CardFlags(detail: "there", seconds: 2))
    }

    @Test func unknownOptionsAreUsageErrors() {
        assertUsageError(["ok", "hi", "--bogus"])
    }

    /// Words after the title parse, so that the resolver can say how to quote them into the title.
    @Test func wordsAfterTheTitleAreKept() throws {
        let command = try show(["ok", "build", "is", "done", "-d", "x"])
        #expect(command.title == "build")
        #expect(command.rest == ["is", "done"])
    }

    /// Every mistake prints one way: `drip: <message>`, then one line saying where the help is.
    @Test func errorsAreOneLineAndWhereTheHelpIs() {
        let mistakes: [([String], String)] = [
            (["ok", "hi", "--bogus"], "drip --help"), (["ok", "hi", "--seconds", "abc"], "drip --help"),
            (["ok", "hi", "-s", "0.2"], "drip --help"), (["ok", "hi", "--position"], "drip --help"),
            (["run"], "drip run --help"), (["run", "--nope", "make"], "drip run --help"),
            (["run", "--version"], "drip run --help"),
            (["hook"], "drip hook --help"), (["hook", "cursor"], "drip hook --help"),
            (["setup"], "drip setup --help"), (["setup", "cursor"], "drip setup --help"),
            (["setup", "claude", "--seconds", "3"], "drip setup --help"),
            (["demo", "sideways"], "drip demo --help"), (["history", "--json", "--replay"], "drip history --help"),
        ]
        for (arguments, help) in mistakes {
            guard case let .exit(status, message) = CommandLineParser.parse(arguments) else {
                Issue.record("\(arguments) parsed"); continue
            }
            #expect(status != 0, "\(arguments)")
            let lines = message.split(separator: "\n").map(String.init)
            #expect(lines.count == 2, "\(arguments): \(message)")
            #expect(lines.first?.hasPrefix("drip: ") == true, "\(arguments): \(message)")
            #expect(lines.first?.hasSuffix(".") == false, "\(arguments): \(message)")
            #expect(lines.last == "See '\(help)'.", "\(arguments): \(message)")
        }
    }

    /// drip's own usage mistakes print as the parser's do, keeping the message as written.
    @Test func usageMessagesSayWhereTheHelpIs() {
        #expect(CommandLineParser.usageMessage("DRIP_STACK must be chain, push or off, not 'x'")
            == "drip: DRIP_STACK must be chain, push or off, not 'x'\nSee 'drip --help'.")
        #expect(CommandLineParser.usageMessage("no hook payload: pass it as an argument or on stdin", subcommand: "hook")
            == "drip: no hook payload: pass it as an argument or on stdin\nSee 'drip hook --help'.")
    }

    /// The command starts at the first argument that is not one of drip's options, as for `time`
    /// or `nice`.
    @Test func runTakesTheCommandWithoutTheTerminator() throws {
        #expect(try run(["make", "test"]).command == ["make", "test"])
        let withOptions = try run(["-s", "3", "--detail", "x", "--quiet", "--sound", "Ping", "ls", "--color", "-la"])
        #expect(withOptions.command == ["ls", "--color", "-la"])
        #expect(withOptions.options.flags == CardFlags(detail: "x", seconds: 3, sound: .named("Ping"), quiet: true))
        // An option's value is never the command, and the command's own options are never drip's,
        // nor joined to a value.
        let wrapped = try run(["-d", "--- x", "--id", "build", "grep", "-d", "skip", "--id", "y", "--", "z"])
        #expect(wrapped.command == ["grep", "-d", "skip", "--id", "y", "--", "z"])
        #expect(wrapped.options.flags.detail == "--- x")
        #expect(wrapped.options.flags.id == "build")
        #expect(try run(["--open", "https://example.com", "./deploy.sh"]).command == ["./deploy.sh"])
        #expect(try run(["--wait", "true"]).options.flags.wait)
    }

    /// The option names `drip run` knows take a value are exactly those that do.
    @Test func runKnowsWhichOptionsTakeAValue() throws {
        struct Help: Decodable {
            struct Command: Decodable { var arguments: [Argument]? }
            struct Argument: Decodable {
                struct Name: Decodable { var kind: String; var name: String }
                var kind: String
                var names: [Name]?
            }
            var command: Command
        }
        let help = try JSONDecoder().decode(Help.self, from: Data(RunCommand._dumpHelp().utf8))
        let valued = (help.command.arguments ?? []).filter { $0.kind == "option" }.flatMap { argument in
            (argument.names ?? []).map { ($0.kind == "short" ? "-" : "--") + $0.name }
        }
        #expect(Set(valued) == CommandLineParser.valueOptions)
    }

    @Test func runTakesTheCommandAfterTheTerminator() throws {
        let command = try run(["--", "make", "test"])
        #expect(command.command == ["make", "test"])
        #expect(command.options.flags == CardFlags())

        let withOptions = try run(["-s", "3", "--detail", "x", "--quiet", "--", "ls", "--color", "-la"])
        #expect(withOptions.command == ["ls", "--color", "-la"])
        #expect(withOptions.options.flags == CardFlags(detail: "x", seconds: 3, quiet: true))

        // The command's own arguments are never joined to a value.
        let wrapped = try run(["-d", "--- x", "--", "grep", "-d", "skip", "--id", "y"])
        #expect(wrapped.command == ["grep", "-d", "skip", "--id", "y"])
        #expect(wrapped.options.flags.detail == "--- x")
    }

    @Test func runWithoutACommandIsAUsageError() {
        assertUsageError(["run"])
        assertUsageError(["run", "--"])
        assertUsageError(["run", "-s", "3"])
        assertUsageError(["run", "--seconds", "99", "--", "true"])
        // An option drip does not know is not the command.
        assertUsageError(["run", "--bogus", "make"])
    }

    @Test func id() throws {
        #expect(try flags(["hi", "--id", "claude:abc"]).id == "claude:abc")
        #expect(try flags(["hi"]).id == nil)
        assertUsageError(["hi", "--id", ""])
        assertUsageError(["hi", "--id", "  "])
        assertUsageError(["hi", "--id", String(repeating: "x", count: Defaults.idLimit + 1)])
    }

    @Test func activate() throws {
        #expect(try flags(["hi", "--activate", "com.apple.Terminal"]).activate == "com.apple.Terminal")
        #expect(try flags(["hi", "--activate", "none"]).activate == "none")
        #expect(try flags(["hi"]).activate == nil)
        for bad in ["", "com..apple", ".com.apple", "com.apple.", "com apple", "com/apple"] {
            assertUsageError(["hi", "--activate", bad])
        }
    }

    @Test func hookTakesTheAgentAndAnOptionalPayload() throws {
        guard case let .invocation(.hook(claude)) = CommandLineParser.parse(["hook", "claude", "--seconds", "3"])
        else { Issue.record(); return }
        #expect(claude.agent == .claude)
        #expect(claude.payload == nil)
        #expect(claude.options.flags == CardFlags(seconds: 3))
        guard case let .invocation(.hook(codex)) = CommandLineParser.parse(["hook", "codex", #"{"type":"x"}"#])
        else { Issue.record(); return }
        #expect(codex.agent == .codex)
        #expect(codex.payload == #"{"type":"x"}"#)
        guard case let .invocation(.hook(gemini)) = CommandLineParser.parse(["hook", "gemini"])
        else { Issue.record(); return }
        #expect(gemini.agent == .gemini)
    }

    @Test func setupTakesTheAgentAndPrint() throws {
        for agent in AgentHook.Agent.allCases {
            guard case let .invocation(.setup(setup)) = CommandLineParser.parse(["setup", agent.rawValue])
            else { Issue.record("\(agent)"); continue }
            #expect(setup.agent == agent)
            #expect(!setup.printOnly)
        }
        guard case let .invocation(.setup(printing)) = CommandLineParser.parse(["setup", "codex", "--print"])
        else { Issue.record(); return }
        #expect(printing.agent == .codex)
        #expect(printing.printOnly)
        // Without an agent, one line says what is missing, not the whole help; a mistake is a usage error.
        guard case let .exit(status, missing) = CommandLineParser.parse(["setup"]) else { Issue.record(); return }
        #expect(status == ExitStatus.usage)
        #expect(missing == "drip: missing the agent: drip setup claude, drip setup codex or drip setup gemini\n"
            + "See 'drip setup --help'.")
    }

    @Test func hookMistakesExitOneNotTwo() {
        // Claude Code reads a hook's exit 2 as "block", so drip hook never uses it.
        for arguments in [["hook"], ["hook", "cursor"], ["hook", "claude", "--seconds", "99"], ["hook", "--position", "top"]] {
            guard case let .exit(status, message) = CommandLineParser.parse(arguments) else {
                Issue.record("\(arguments) parsed"); continue
            }
            #expect(status == ExitStatus.hookFailed, "\(arguments)")
            #expect(!message.isEmpty, "\(arguments)")
        }
        // Without an agent, one line says what is missing, not the whole help.
        guard case let .exit(_, missing) = CommandLineParser.parse(["hook"]) else { Issue.record(); return }
        #expect(missing == "drip: missing the agent: drip hook claude, drip hook codex or drip hook gemini\n"
            + "See 'drip hook --help'.")
        guard case let .exit(status, _) = CommandLineParser.parse(["hook", "--help"]) else { Issue.record(); return }
        #expect(status == 0)
    }

    @Test func historyCommand() throws {
        let plain = try history([])
        #expect(!plain.missed && !plain.json && !plain.replay)
        let all = try history(["--missed", "--replay"])
        #expect(all.missed && all.replay)
        #expect(try history(["--json"]).json)
        assertUsageError(["history", "--json", "--replay"])
        assertUsageError(["history", "-n", "3"])
        assertUsageError(["history", "extra"])
    }

    @Test func helpAndVersionExitZero() {
        for arguments in [["--help"], ["-h"], ["help"], ["--version"], ["run", "--help"], ["run", "-s", "3", "--help"],
                          ["history", "--help"], ["help", "hook"], ["ok", "--help"]] {
            guard case let .exit(status, message) = CommandLineParser.parse(arguments) else {
                Issue.record("\(arguments) did not exit"); return
            }
            #expect(status == 0, "\(arguments)")
            #expect(!message.isEmpty, "\(arguments)")
        }
        guard case let .exit(_, version) = CommandLineParser.parse(["--version"]) else { Issue.record(); return }
        #expect(version == dripVersion)
    }

    /// drip run rejects --version, so its help does not offer it; drip's own help does.
    @Test func runHelpDoesNotOfferVersion() {
        for arguments in [["run", "--help"], ["help", "run"]] {
            guard case let .exit(status, help) = CommandLineParser.parse(arguments) else {
                Issue.record("\(arguments) did not exit"); continue
            }
            #expect(status == 0, "\(arguments)")
            #expect(help.contains("-h, --help"), "\(arguments): \(help)")
            #expect(!help.contains("--version"), "\(arguments): \(help)")
        }
        guard case let .exit(_, root) = CommandLineParser.parse(["--help"]) else { Issue.record(); return }
        #expect(root.contains("--version"))
    }

    /// The usage first, then examples, the card options, the subcommands and the exit codes.
    @Test func helpListsTheSubcommandsAndHidesRender() throws {
        guard case let .exit(_, help) = CommandLineParser.parse(["--help"]) else { Issue.record(); return }
        #expect(help.hasPrefix("OVERVIEW: Show a brief card at the notch on macOS.\n\nUSAGE: drip [KIND] [TITLE] [options]"), "\(help)")
        #expect(help.contains("drip run [options] [--] <command> [args...]"), "\(help)")
        #expect(help.contains("drip hook claude|codex|gemini [options]"), "\(help)")
        #expect(help.contains("drip setup claude|codex|gemini [--print]"), "\(help)")
        #expect(help.contains("drip history [--missed] [--json | --replay]"), "\(help)")
        let order = ["USAGE:", "EXAMPLES:", "ARGUMENTS:", "OPTIONS:", "SUBCOMMANDS:", "EXIT CODES:"].map {
            help.firstRange(of: "\n\($0)")?.lowerBound
        }
        #expect(order.allSatisfy { $0 != nil }, "\(help)")
        #expect(order.compactMap { $0 } == order.compactMap { $0 }.sorted(), "\(help)")
        for subcommand in ["run", "hook", "setup", "demo", "history"] {
            #expect(help.contains("\n  \(subcommand) "), "\(subcommand)")
        }
        #expect(help.contains("--seconds"), "\(help)")
        #expect(help.contains("--confirm"), "\(help)")
        #expect(!help.contains("__render"), "\(help)")
        #expect(!help.contains("__background"), "\(help)")
        // Preferences are settings, not flags.
        #expect(!help.contains("--size"), "\(help)")
        #expect(!help.contains("--motion"), "\(help)")
        // Retired: drip still takes them from old scripts, but no longer offers them.
        #expect(!help.contains("--position"), "\(help)")
        #expect(!help.contains("--style"), "\(help)")
    }

    /// The completion scripts know the subcommands, and only those shown.
    @Test func completionScripts() {
        for shell in ["zsh", "bash", "fish"] {
            guard case let .exit(status, script) = CommandLineParser.parse(["--generate-completion-script", shell]) else {
                Issue.record("\(shell) did not exit"); continue
            }
            #expect(status == 0, "\(shell)")
            for subcommand in ["run", "hook", "demo", "history"] {
                #expect(script.contains(subcommand), "\(shell): \(subcommand)")
            }
            #expect(!script.contains("__render"), "\(shell)")
            #expect(!script.contains("__background"), "\(shell)")
            #expect(!script.contains("drip run_complete"), "\(shell)")
            #expect(!script.contains("--position"), "\(shell)")
            #expect(!script.contains("--style"), "\(shell)")
        }
        guard case let .exit(_, zsh) = CommandLineParser.parse(["--generate-completion-script", "zsh"]) else {
            Issue.record(); return
        }
        #expect(zsh.hasPrefix("#compdef drip\n"))
        #expect(zsh.contains("_drip_run()"))
    }

    @Test func renderCommand() throws {
        guard case let .invocation(.render(command)) = CommandLineParser.parse(
            ["__render", "--out", "card.png", "--appearance", "dark", "fail", "nope", "-d", "exit 1", "--size", "large"])
        else { Issue.record(); return }
        #expect(command.out == "card.png")
        #expect(command.appearance == .dark)
        #expect(command.kind == "fail")
        #expect(command.title == "nope")
        #expect(command.flags == CardFlags(detail: "exit 1", size: .large))
    }

    @Test func renderRequiresOut() {
        assertUsageError(["__render", "ok", "hi"])
    }

    private func show(_ arguments: [String]) throws -> ShowCommand {
        guard case let .invocation(.show(command)) = CommandLineParser.parse(arguments) else {
            throw UsageError("\(arguments) did not parse as a card")
        }
        return command
    }

    private func flags(_ arguments: [String]) throws -> CardFlags {
        try show(arguments).options.flags
    }

    private func run(_ arguments: [String]) throws -> RunCommand {
        guard case let .invocation(.run(command)) = CommandLineParser.parse(["run"] + arguments) else {
            throw UsageError("\(arguments) did not parse as drip run")
        }
        return command
    }

    private func history(_ arguments: [String]) throws -> HistoryCommand {
        guard case let .invocation(.history(command)) = CommandLineParser.parse(["history"] + arguments) else {
            throw UsageError("\(arguments) did not parse as drip history")
        }
        return command
    }

    private func assertUsageError(_ arguments: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        guard case let .exit(status, message) = CommandLineParser.parse(arguments) else {
            Issue.record("\(arguments) parsed", sourceLocation: sourceLocation); return
        }
        #expect(status == ExitStatus.usage, "\(arguments)", sourceLocation: sourceLocation)
        #expect(!message.isEmpty, sourceLocation: sourceLocation)
    }
}
