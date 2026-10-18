import BlipCore
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
        #expect(try flags(["hi"]).icon == nil)
    }

    @Test func color() throws {
        #expect(try flags(["hi", "--color", "#a78bfa"]).color == .rgb(red: 0xA7, green: 0x8B, blue: 0xFA))
        #expect(try flags(["hi", "--color", "purple"]).color == .system(.purple))
        #expect(try flags(["hi"]).color == nil)
        assertUsageError(["hi", "--color", "teal"])
        assertUsageError(["hi", "--color", "#abc"])
    }

    @Test func position() throws {
        for position in Position.allCases {
            #expect(try flags(["hi", "--position", position.rawValue]).position == position)
        }
        #expect(try flags(["hi"]).position == nil)
        assertUsageError(["hi", "--position", "left"])
    }

    @Test func size() throws {
        for size in CardSize.allCases {
            #expect(try flags(["hi", "--size", size.rawValue]).size == size)
        }
        #expect(try flags(["hi"]).size == nil)
        assertUsageError(["hi", "--size", "huge"])
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

    @Test func unknownOptionAndExtraArgumentsAreUsageErrors() {
        assertUsageError(["ok", "hi", "--bogus"])
        assertUsageError(["ok", "hi", "there"])
    }

    @Test func runTakesTheCommandAfterTheTerminator() throws {
        let command = try run(["--", "make", "test"])
        #expect(command.command == ["make", "test"])
        #expect(command.options.flags == CardFlags())

        let withOptions = try run(["-s", "3", "--detail", "x", "--quiet", "--", "ls", "--color", "-la"])
        #expect(withOptions.command == ["ls", "--color", "-la"])
        #expect(withOptions.options.flags == CardFlags(detail: "x", seconds: 3, quiet: true))
    }

    @Test func runWithoutACommandIsAUsageError() {
        assertUsageError(["run"])
        assertUsageError(["run", "--"])
        assertUsageError(["run", "make", "test"])
        assertUsageError(["run", "--seconds", "99", "--", "true"])
    }

    @Test func historyCommand() throws {
        let plain = try history([])
        #expect(!plain.missed && !plain.json && !plain.replay)
        #expect(plain.limit == 20)
        let all = try history(["--missed", "--replay", "-n", "3"])
        #expect(all.missed && all.replay && all.limit == 3)
        #expect(try history(["--json", "--limit", "50"]).json)
        assertUsageError(["history", "--json", "--replay"])
        assertUsageError(["history", "-n", "0"])
        assertUsageError(["history", "extra"])
    }

    @Test func helpAndVersionExitZero() {
        for arguments in [["--help"], ["-h"], ["--version"], ["run", "--help"], ["history", "--help"]] {
            guard case let .exit(status, message) = CommandLineParser.parse(arguments) else {
                Issue.record("\(arguments) did not exit"); return
            }
            #expect(status == 0, "\(arguments)")
            #expect(!message.isEmpty, "\(arguments)")
        }
        guard case let .exit(_, version) = CommandLineParser.parse(["--version"]) else { Issue.record(); return }
        #expect(version == blipVersion)
    }

    @Test func helpListsRunAndHidesRender() {
        guard case let .exit(_, help) = CommandLineParser.parse(["--help"]) else { Issue.record(); return }
        #expect(help.contains("blip run [options] -- <command> [args...]"), "\(help)")
        #expect(help.contains("blip history [--missed] [--json | --replay] [-n <n>]"), "\(help)")
        #expect(help.contains("--seconds"), "\(help)")
        #expect(!help.contains("__render"), "\(help)")
    }

    @Test func renderCommand() throws {
        guard case let .invocation(.render(command)) = CommandLineParser.parse(
            ["__render", "--out", "card.png", "--appearance", "dark", "fail", "nope", "-d", "exit 1", "--size", "large"])
        else { Issue.record(); return }
        #expect(command.out == "card.png")
        #expect(command.appearance == .dark)
        #expect(command.kind == "fail")
        #expect(command.title == "nope")
        #expect(command.options.flags == CardFlags(detail: "exit 1", size: .large))
    }

    @Test func renderRequiresOut() {
        assertUsageError(["__render", "ok", "hi"])
    }

    private func show(_ arguments: [String]) throws -> BlipCommand {
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
            throw UsageError("\(arguments) did not parse as blip run")
        }
        return command
    }

    private func history(_ arguments: [String]) throws -> HistoryCommand {
        guard case let .invocation(.history(command)) = CommandLineParser.parse(["history"] + arguments) else {
            throw UsageError("\(arguments) did not parse as blip history")
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
