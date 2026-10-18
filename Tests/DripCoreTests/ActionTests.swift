import DripCore
import Foundation
import Testing

struct ActionTests {
    private func flags(_ arguments: [String]) -> CardFlags? {
        guard case let .invocation(.show(command)) = CommandLineParser.parse(["ok", "t"] + arguments) else {
            return nil
        }
        return command.options.flags
    }

    private func usageMessage(_ arguments: [String]) -> String? {
        guard case let .exit(status, message) = CommandLineParser.parse(["ok", "t"] + arguments),
              status == ExitStatus.usage
        else { return nil }
        return message
    }

    @Test func openAndButtonParse() throws {
        let parsed = try #require(flags(["--open", "https://example.com/run/1", "--button", "View run", "--wait"]))
        #expect(parsed.open == "https://example.com/run/1")
        // A path is made absolute where drip runs, since another drip may show the card, or the
        // history replay it.
        let here = FileManager.default.currentDirectoryPath
        #expect(try #require(flags(["--open", "coverage/index.html"])).open == here + "/coverage/index.html")
        #expect(try #require(flags(["--open", "./a/../build.log"])).open == here + "/build.log")
        #expect(try #require(flags(["--open", "~/build.log"])).open == NSHomeDirectory() + "/build.log")
        #expect(try #require(flags(["--open", "/tmp/test.log"])).open == "/tmp/test.log")
        #expect(parsed.button == "View run")
        #expect(parsed.wait)
    }

    @Test func emptyOpenBadURLsAndEmptyLabelsAreUsageErrors() {
        #expect(usageMessage(["--open", " "])?.contains("--open needs a URL or a path") == true)
        #expect(usageMessage(["--open", "://nope"])?.contains("is not a valid URL") == true)
        #expect(usageMessage(["--button", "  "])?.contains("--button needs a label") == true)
    }

    @Test func theResolverAddsTheButton() throws {
        let resolver = CardResolver()
        #expect(try resolver.resolve(kind: "ok", title: "t", flags: CardFlags()).action == nil)
        let open = try resolver.resolve(kind: "ok", title: "t", flags: CardFlags(open: "~/build.log"))
        #expect(open.action == CardAction(label: "Open", open: "~/build.log"))
        let labelled = try resolver.resolve(
            kind: "ok", title: "t", flags: CardFlags(button: "  Promote\tto prod  "))
        #expect(labelled.action == CardAction(label: "Promote to prod", open: nil))
        let long = try resolver.resolve(kind: "ok", title: "t", flags: CardFlags(button: String(repeating: "a", count: 40)))
        #expect(long.action?.label.count == Defaults.buttonLimit)
    }

    @Test func dripRunTakesTheButtonToo() throws {
        guard case let .invocation(.run(command)) = CommandLineParser.parse(
            ["run", "--open", "https://ci.example.com", "--", "make"])
        else { Issue.record("did not parse"); return }
        let card = try CardResolver().resolveRun(
            command: command.command, status: 0, seconds: 1, flags: command.options.flags)
        #expect(card.action?.open == "https://ci.example.com")
    }
}

struct DeliveryTests {
    private let plain = Card(preset: .ok, title: "t")

    @Test func cardsGoToTheBackgroundUnlessSomethingWaits() {
        var linked = plain
        linked.action = CardAction(label: "Open", open: "https://example.com")
        var question = plain
        question.action = CardAction(label: "Promote", open: nil)
        #expect(Delivery.choose(for: [plain], wait: false) == .background)
        #expect(Delivery.choose(for: [linked], wait: false) == .background)
        #expect(Delivery.choose(for: [plain], wait: true) == .wait)
        // Only drip's exit status reports the click on a button that opens nothing.
        #expect(Delivery.choose(for: [question], wait: false) == .wait)
        #expect(Delivery.choose(for: [plain, question], wait: false) == .wait)
    }

    @Test func aRequestSurvivesTheTripToTheBackgroundDrip() throws {
        var card = Card(
            kind: "deploy", title: "Deploy finished", detail: "api · 2m 14s", icon: .symbol("shippingbox.fill"),
            fallbackIcon: .symbol("checkmark.circle.fill"), color: .rgb(red: 1, green: 128, blue: 255),
            sound: .file("~/sounds/done.aiff"), seconds: 7.5, position: .notch, size: .large, style: .wash,
            motion: .subtle)
        card.action = CardAction(label: "View run", open: "https://example.com/run/1")
        let others = [Card(preset: .fail, title: "x"), Card(preset: .info, title: "y")]
        let request = BackgroundRequest(cards: [card] + others)
        #expect(try BackgroundRequest.decode(request.encoded()) == request)
    }

    @Test func garbageIsNotARequest() {
        #expect(throws: (any Error).self) { try BackgroundRequest.decode(Data("not json".utf8)) }
    }
}

struct IslandButtonTests {
    @Test func theButtonTakesTheRingsPlaceAndWidensThePill() {
        let plain = IslandMetrics(notchWidth: 185, notchHeight: 32, textWidth: 180, textHeight: 34)
        var withButton = plain
        withButton.actionWidth = 76
        #expect(withButton.pillWidth == plain.pillWidth - 20 + 76)
        var animator = IslandAnimator(metrics: withButton)
        animator.open()
        let shape = animator.shape(at: 0)
        let layout = animator.content(for: shape)
        #expect(layout.ringCenter.x + 76 / 2 < shape.pillWidth / 2)
        #expect(layout.textX + withButton.textWidth < layout.ringCenter.x - 76 / 2)
    }

    /// The text column is 500 points, unless a button is too wide for both to fit in the widest
    /// capsule: then the column narrows, so the longest line still stops short of the button.
    @Test func aWideButtonNarrowsTheTextColumn() {
        let plain = IslandMetrics(notchWidth: 185, notchHeight: 32, textWidth: 0, textHeight: 34)
        #expect(plain.textColumn == 500)
        var wide = plain
        wide.actionWidth = 180
        #expect(wide.textColumn == 640 - 48 - 10 - 180 - 14)
        wide.textWidth = wide.textColumn
        #expect(wide.pillWidth == 640)
        var animator = IslandAnimator(metrics: wide)
        animator.open()
        let layout = animator.content(for: animator.shape(at: 0))
        #expect(layout.textX + wide.textWidth <= layout.ringCenter.x - 180 / 2 - 10 + 1e-9)
    }
}
