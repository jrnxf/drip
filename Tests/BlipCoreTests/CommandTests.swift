import BlipCore
import XCTest

/// One test per row of the CLI table, plus help, version and the hidden render command.
final class CommandTests: XCTestCase {
    func testKindAndTitlePositionals() throws {
        let command = try show(["ok", "hi"])
        XCTAssertEqual(command.kind, "ok")
        XCTAssertEqual(command.title, "hi")
        let titleOnly = try show(["build finished"])
        XCTAssertEqual(titleOnly.kind, "build finished")
        XCTAssertNil(titleOnly.title)
        let none = try show([])
        XCTAssertNil(none.kind)
        XCTAssertNil(none.title)
    }

    func testDetail() throws {
        XCTAssertEqual(try flags(["ok", "hi", "-d", "there"]).detail, "there")
        XCTAssertEqual(try flags(["ok", "hi", "--detail", "there"]).detail, "there")
        XCTAssertNil(try flags(["ok", "hi"]).detail)
    }

    func testSeconds() throws {
        XCTAssertEqual(try flags(["hi", "-s", "8"]).seconds, 8)
        XCTAssertEqual(try flags(["hi", "--seconds", "0.5"]).seconds, 0.5)
        XCTAssertEqual(try flags(["hi", "--seconds", "60"]).seconds, 60)
        XCTAssertNil(try flags(["hi"]).seconds)
        for bad in ["0.4", "60.5", "0", "-1", "nan", "abc"] {
            assertUsageError(["hi", "--seconds", bad])
        }
    }

    func testSound() throws {
        XCTAssertEqual(try flags(["hi", "--sound", "Hero"]).sound, .named("Hero"))
        XCTAssertEqual(try flags(["hi", "--sound", "none"]).sound, Sound.none)
        XCTAssertEqual(try flags(["hi", "--sound", "/tmp/ding.aiff"]).sound, .file("/tmp/ding.aiff"))
        XCTAssertNil(try flags(["hi"]).sound)
    }

    func testIcon() throws {
        XCTAssertEqual(try flags(["hi", "--icon", "paperplane.fill"]).icon, .symbol("paperplane.fill"))
        XCTAssertEqual(try flags(["hi", "--icon", "none"]).icon, Icon.none)
        XCTAssertNil(try flags(["hi"]).icon)
    }

    func testColor() throws {
        XCTAssertEqual(try flags(["hi", "--color", "#a78bfa"]).color, .rgb(red: 0xA7, green: 0x8B, blue: 0xFA))
        XCTAssertEqual(try flags(["hi", "--color", "purple"]).color, .system(.purple))
        XCTAssertNil(try flags(["hi"]).color)
        assertUsageError(["hi", "--color", "teal"])
        assertUsageError(["hi", "--color", "#abc"])
    }

    func testPosition() throws {
        for position in Position.allCases {
            XCTAssertEqual(try flags(["hi", "--position", position.rawValue]).position, position)
        }
        XCTAssertNil(try flags(["hi"]).position)
        assertUsageError(["hi", "--position", "left"])
    }

    func testSize() throws {
        for size in CardSize.allCases {
            XCTAssertEqual(try flags(["hi", "--size", size.rawValue]).size, size)
        }
        XCTAssertNil(try flags(["hi"]).size)
        assertUsageError(["hi", "--size", "huge"])
    }

    func testWaitAndQuiet() throws {
        XCTAssertFalse(try flags(["hi"]).wait)
        XCTAssertFalse(try flags(["hi"]).quiet)
        XCTAssertTrue(try flags(["hi", "--wait"]).wait)
        XCTAssertTrue(try flags(["hi", "--quiet"]).quiet)
    }

    func testOptionsMayComeFirst() throws {
        let command = try show(["--seconds", "2", "-d", "there", "warn", "hi"])
        XCTAssertEqual(command.kind, "warn")
        XCTAssertEqual(command.title, "hi")
        XCTAssertEqual(command.options.flags, CardFlags(detail: "there", seconds: 2))
    }

    func testUnknownOptionAndExtraArgumentsAreUsageErrors() {
        assertUsageError(["ok", "hi", "--bogus"])
        assertUsageError(["ok", "hi", "there"])
    }

    func testRunTakesTheCommandAfterTheTerminator() throws {
        let command = try run(["--", "make", "test"])
        XCTAssertEqual(command.command, ["make", "test"])
        XCTAssertEqual(command.options.flags, CardFlags())

        let withOptions = try run(["-s", "3", "--detail", "x", "--quiet", "--", "ls", "--color", "-la"])
        XCTAssertEqual(withOptions.command, ["ls", "--color", "-la"])
        XCTAssertEqual(withOptions.options.flags, CardFlags(detail: "x", seconds: 3, quiet: true))
    }

    func testRunWithoutACommandIsAUsageError() {
        assertUsageError(["run"])
        assertUsageError(["run", "--"])
        assertUsageError(["run", "make", "test"])
        assertUsageError(["run", "--seconds", "99", "--", "true"])
    }

    func testHelpAndVersionExitZero() {
        for arguments in [["--help"], ["-h"], ["--version"], ["run", "--help"]] {
            guard case let .exit(status, message) = CommandLineParser.parse(arguments) else {
                return XCTFail("\(arguments) did not exit")
            }
            XCTAssertEqual(status, 0, "\(arguments)")
            XCTAssertFalse(message.isEmpty, "\(arguments)")
        }
        guard case let .exit(_, version) = CommandLineParser.parse(["--version"]) else { return XCTFail() }
        XCTAssertEqual(version, blipVersion)
    }

    func testHelpListsRunAndHidesRender() {
        guard case let .exit(_, help) = CommandLineParser.parse(["--help"]) else { return XCTFail() }
        XCTAssertTrue(help.contains("blip run [options] -- <command> [args...]"), help)
        XCTAssertTrue(help.contains("--seconds"), help)
        XCTAssertFalse(help.contains("__render"), help)
    }

    func testRenderCommand() throws {
        guard case let .invocation(.render(command)) = CommandLineParser.parse(
            ["__render", "--out", "card.png", "--appearance", "dark", "fail", "nope", "-d", "exit 1", "--size", "large"])
        else { return XCTFail() }
        XCTAssertEqual(command.out, "card.png")
        XCTAssertEqual(command.appearance, .dark)
        XCTAssertEqual(command.scale, 2)
        XCTAssertEqual(command.kind, "fail")
        XCTAssertEqual(command.title, "nope")
        XCTAssertEqual(command.options.flags, CardFlags(detail: "exit 1", size: .large))
    }

    func testRenderRequiresOut() {
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

    private func assertUsageError(_ arguments: [String], line: UInt = #line) {
        guard case let .exit(status, message) = CommandLineParser.parse(arguments) else {
            return XCTFail("\(arguments) parsed", line: line)
        }
        XCTAssertEqual(status, ExitStatus.usage, "\(arguments)", line: line)
        XCTAssertFalse(message.isEmpty, line: line)
    }
}
