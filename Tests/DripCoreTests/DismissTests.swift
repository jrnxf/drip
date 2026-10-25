import DripCore
import Testing

/// `drip dismiss`, and its alias `drip clear`.
struct DismissTests {
    private func dismissal(_ arguments: [String]) -> DismissCommand? {
        guard case let .invocation(.dismiss(command)) = CommandLineParser.parse(arguments) else { return nil }
        return command
    }

    @Test func dismissTakesEveryCardOrThoseWithAnID() {
        #expect(dismissal(["dismiss"])?.id == nil)
        #expect(dismissal(["dismiss"]) != nil)
        #expect(dismissal(["dismiss", "--id", "claude:abc"])?.id == "claude:abc")
        // An id that starts with a dash is still the id.
        #expect(dismissal(["dismiss", "--id", "--wait"])?.id == "--wait")
        #expect(dismissal(["clear", "--id", "deploy"])?.id == "deploy")
    }

    @Test func aBadIDIsAUsageError() {
        for arguments in [["dismiss", "--id", ""], ["dismiss", "--id", String(repeating: "x", count: Defaults.idLimit + 1)], ["dismiss", "extra"]] {
            guard case let .exit(status, _) = CommandLineParser.parse(arguments) else {
                Issue.record("\(arguments) parsed")
                continue
            }
            #expect(status == ExitStatus.usage, "\(arguments)")
        }
    }

    @Test func noPresetMayTakeTheName() {
        for name in ["dismiss", "clear"] {
            #expect(throws: ConfigError.self, "\(name)") {
                try ConfigLoader.parse("[preset.\(name)]\nicon = \"star\"", path: "config.toml")
            }
        }
    }

    @Test func theHelpNamesIt() {
        guard case let .exit(_, help) = CommandLineParser.parse(["--help"]) else {
            Issue.record("no help")
            return
        }
        #expect(help.contains("drip dismiss [--id ID]"))
    }
}
