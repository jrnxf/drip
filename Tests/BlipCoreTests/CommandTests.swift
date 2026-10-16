import BlipCore
import XCTest

final class CommandTests: XCTestCase {
    func testPresetTitleAndDetail() throws {
        let command = try show(["ok", "hi", "-d", "there"])
        XCTAssertEqual(command.kind, "ok")
        XCTAssertEqual(command.title, "hi")
        XCTAssertEqual(command.options.detail, "there")
        XCTAssertEqual(try show(["ok", "hi", "--detail", "there"]).options.detail, "there")
    }

    func testHelpAndVersionExitZero() {
        for arguments in [["--help"], ["-h"], ["--version"]] {
            guard case let .exit(status, message) = CommandLineParser.parse(arguments) else {
                return XCTFail("\(arguments) did not exit")
            }
            XCTAssertEqual(status, 0, "\(arguments)")
            XCTAssertFalse(message.isEmpty, "\(arguments)")
        }
        guard case let .exit(_, version) = CommandLineParser.parse(["--version"]) else { return XCTFail() }
        XCTAssertEqual(version, blipVersion)
    }

    func testHelpHidesTheRenderCommand() {
        guard case let .exit(_, help) = CommandLineParser.parse(["--help"]) else { return XCTFail() }
        XCTAssertFalse(help.contains("__render"))
    }

    func testUnknownOptionIsAUsageError() {
        guard case let .exit(status, message) = CommandLineParser.parse(["ok", "hi", "--bogus"]) else {
            return XCTFail()
        }
        XCTAssertEqual(status, ExitStatus.usage)
        XCTAssertTrue(message.contains("--bogus"), message)
    }

    func testRenderCommand() throws {
        guard case let .invocation(.render(command)) = CommandLineParser.parse(
            ["__render", "--out", "card.png", "--appearance", "dark", "fail", "nope", "-d", "exit 1"])
        else { return XCTFail() }
        XCTAssertEqual(command.out, "card.png")
        XCTAssertEqual(command.appearance, .dark)
        XCTAssertEqual(command.scale, 2)
        XCTAssertEqual(command.kind, "fail")
        XCTAssertEqual(command.title, "nope")
        XCTAssertEqual(command.options.detail, "exit 1")
    }

    func testRenderRequiresOut() {
        guard case let .exit(status, _) = CommandLineParser.parse(["__render", "ok", "hi"]) else {
            return XCTFail()
        }
        XCTAssertEqual(status, ExitStatus.usage)
    }

    private func show(_ arguments: [String]) throws -> BlipCommand {
        switch CommandLineParser.parse(arguments) {
        case let .invocation(.show(command)):
            return command
        case let result:
            throw UsageError("\(arguments) parsed as \(result)")
        }
    }
}

final class ResolveTests: XCTestCase {
    private let resolver = CardResolver()

    func testKnownPresetIsTheKind() throws {
        let card = try resolver.resolve(kind: "ok", title: "hi", flags: CardFlags(detail: "there"))
        XCTAssertEqual(card, Card(preset: .ok, title: "hi", detail: "there"))
    }

    func testFirstPositionalThatIsNotAPresetIsTheTitle() throws {
        let card = try resolver.resolve(kind: "build finished", title: nil, flags: CardFlags())
        XCTAssertEqual(card, Card(preset: .info, title: "build finished"))
    }

    func testUnknownPresetWithATitleIsAUsageError() {
        XCTAssertThrowsError(try resolver.resolve(kind: "okay", title: "hi", flags: CardFlags())) { error in
            XCTAssertEqual((error as? UsageError)?.message.hasPrefix("unknown preset 'okay'"), true)
        }
    }

    func testMissingTitleIsAUsageError() {
        XCTAssertThrowsError(try resolver.resolve(kind: nil, title: nil, flags: CardFlags()))
        XCTAssertThrowsError(try resolver.resolve(kind: "ok", title: nil, flags: CardFlags()))
        XCTAssertThrowsError(try resolver.resolve(kind: "ok", title: "", flags: CardFlags()))
    }
}
