@testable import DripCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import Testing

/// `drip --result`: one word on stdout for how the card ended, and nothing else changes.
struct ResultTests {
    /// The words are the contract: scripts match on them.
    @Test func theWords() {
        #expect(CardResult.allCases.map(\.rawValue) == ["activate", "dismiss", "timeout", "replaced"])
        #expect(CardResult.allCases.map(\.line) == ["activate\n", "dismiss\n", "timeout\n", "replaced\n"])
    }

    /// Only a press that opens something is a click on the card.
    @Test func aPressEndsTheCard() {
        #expect(CardResult(pressing: .yes) == .activate)
        #expect(CardResult(pressing: .no) == .dismiss)
    }

    /// The word comes only once the card has gone, so --result waits as --wait does.
    @Test func resultWaits() throws {
        let command = try show(["ok", "Built", "--result"])
        #expect(command.result)
        #expect(command.flags.wait)
        #expect(try show(["ok", "Built", "--result", "--wait"]).flags.wait)
        let plain = try show(["ok", "Built"])
        #expect(!plain.result)
        #expect(!plain.flags.wait)
    }

    /// A --yes question already answers through drip's exit status.
    @Test func resultIsNoAnswerToAQuestion() {
        guard case let .exit(status, message) = CommandLineParser.parse(["warn", "Deploy?", "--yes", "Go", "--result"])
        else {
            Issue.record("--result with --yes parsed")
            return
        }
        #expect(status == ExitStatus.usage)
        #expect(message.contains("give --yes or --result, not both"), "\(message)")
    }

    /// drip run and drip hook print nothing of their cards: a hook's stdout belongs to its agent.
    @Test(arguments: [
        (["run", "--result", "true"], ExitStatus.usage),
        (["run", "--result=yes", "true"], ExitStatus.usage),
        (["hook", "claude", "--result", "{}"], ExitStatus.hookFailed),
    ] as [([String], Int32)])
    func runAndHookTakeNoResult(_ arguments: [String], _ code: Int32) {
        guard case let .exit(status, message) = CommandLineParser.parse(arguments) else {
            Issue.record("\(arguments) parsed")
            return
        }
        #expect(status == code, "\(arguments)")
        #expect(message.contains("takes no --result") && message.contains("drip ok \"Built\" --result"), "\(message)")
    }

    /// The help and every shell's completions offer --result for drip itself, not for run or hook.
    @Test func helpAndCompletionsOfferResultOnlyToShow() throws {
        guard case let .exit(_, help) = CommandLineParser.parse(["show", "--help"]) else {
            Issue.record("no help")
            return
        }
        #expect(help.contains("--result"))
        for name in ["run", "hook"] {
            guard case let .exit(_, text) = CommandLineParser.parse([name, "--help"]) else {
                Issue.record("no help for \(name)")
                continue
            }
            #expect(!text.contains("--result"), "drip \(name) --help")
        }
        for shell in ["zsh", "bash", "fish"] {
            guard case let .exit(_, script) = CommandLineParser.parse(["--generate-completion-script", shell]) else {
                Issue.record("no \(shell) completion script")
                continue
            }
            let token = shell == "fish" ? "-l 'result'" : "--result"
            #expect(HelpTests.section(of: script, for: "show", shell: shell).contains(token), "\(shell) show")
            for name in ["run", "hook"] {
                #expect(!HelpTests.section(of: script, for: name, shell: shell).contains(token), "\(shell) \(name)")
            }
        }
    }

    private func show(_ arguments: [String]) throws -> ShowCommand {
        guard case let .invocation(.show(command)) = CommandLineParser.parse(arguments) else {
            throw UsageError("\(arguments) did not parse as a card")
        }
        return command
    }
}

#if !os(WASI) // Runs the built drip, which WebAssembly cannot.
/// The built drip, as a script runs it: the word on stdout, and nothing there when it fails.
struct ResultProcessTests {
    /// One run of drip, the code it exits with and what it prints on stdout.
    struct Case: CustomTestStringConvertible, Sendable {
        var code: Int32
        var what: String
        var arguments: [String]
        var input = ""
        var output = ""

        var testDescription: String { "\(code): \(what)" }
    }

    static let anywhere: [Case] = [
        Case(code: 2, what: "--result with --yes", arguments: ["warn", "t", "--yes", "Go", "--result"]),
        Case(code: 2, what: "drip run --result", arguments: ["run", "--result", "true"]),
        Case(code: 1, what: "drip hook --result", arguments: ["hook", "claude", "--result"],
             input: #"{"hook_event_name":"Stop","session_id":"s1","cwd":"/home/user/api"}"#),
    ]

    static let withoutGUI: [Case] = [
        Case(code: 3, what: "--result without a GUI session", arguments: ["ok", "t", "--result"]),
    ]

    static let onScreen: [Case] = [
        Case(code: 0, what: "a --result card nobody clicks",
             arguments: ["info", "result check", "--result", "--seconds", "0.5", "--sound", "none"],
             output: "timeout\n"),
    ]

    static func expect(_ run: Case) throws {
        let outcome = try DripProcess.run(run.arguments, input: Data(run.input.utf8))
        #expect(outcome.status == run.code, "\(run.what): exits \(outcome.status), \(outcome.error)")
        #expect(outcome.output == run.output, "\(run.what): prints \(outcome.output.debugDescription)")
        if run.code != 0 { #expect(!outcome.error.isEmpty, "\(run.what): it says nothing on stderr") }
    }

    @Test(arguments: anywhere)
    func eachRow(_ run: Case) throws {
        try Self.expect(run)
    }

    @Test(.enabled(if: !ExitCodeTests.hasGUISession), arguments: withoutGUI)
    func withoutAGUISession(_ run: Case) throws {
        try Self.expect(run)
    }

    @Test(.enabled(if: ExitCodeTests.mayShowCards), arguments: onScreen)
    func onScreenRows(_ run: Case) throws {
        try Self.expect(run)
    }
}
#endif
