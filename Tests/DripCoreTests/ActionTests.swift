import DripCore
#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif
import Testing
#if os(WASI)
@testable import DripCore // Foundation's path helpers, which DripCore fills in on WebAssembly
#endif

struct ActionTests {
    private func flags(_ arguments: [String]) -> CardFlags? {
        guard case let .invocation(.show(command)) = CommandLineParser.parse(["ok", "t"] + arguments) else {
            return nil
        }
        return command.options.flags
    }

    private func options(_ arguments: [String]) -> CardOptions? {
        guard case let .invocation(.show(command)) = CommandLineParser.parse(["ok", "t"] + arguments) else {
            return nil
        }
        return command.options
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
        #expect(try #require(flags(["--open", "coverage/index.html"])).open == (here as NSString).appendingPathComponent("coverage/index.html"))
        #expect(try #require(flags(["--open", "./a/../build.log"])).open == (here as NSString).appendingPathComponent("build.log"))
        #expect(try #require(flags(["--open", "~/build.log"])).open == NSHomeDirectory() + "/build.log")
        #expect(try #require(flags(["--open", "/tmp/test.log"])).open == "/tmp/test.log")
        #expect(parsed.button == "View run")
        #expect(parsed.wait)
    }

    @Test func emptyOpenBadURLsAndEmptyLabelsAreUsageErrors() {
        // `--open "$CI_URL"` with the variable empty: no button, not a question nobody meant to ask.
        let empty = flags(["--open", " ", "--button", "View run"])
        #expect(empty != nil)
        #expect(empty?.open == nil)
        #expect(empty?.button == nil)
        #expect(options(["--open", " ", "--button", "View run"])?.warnings == ["--open is empty, so the card has no button"])
        #expect(options(["--open", "https://example.com", "--button", "View run"])?.warnings == [])
        #expect(usageMessage(["--open", "://nope"])?.contains("is not a valid URL") == true)
        #expect(usageMessage(["--button", "  "])?.contains("--button needs a label") == true)
    }

    /// `--confirm` asks: drip waits for the card, and its exit status says whether the button was
    /// clicked.
    @Test func confirmAsks() throws {
        let asked = try #require(flags(["--confirm", "Promote"]))
        #expect(asked.button == "Promote")
        #expect(asked.open == nil)
        #expect(options(["--confirm", "Promote"])?.warnings == [])
        let card = try CardResolver().resolve(kind: "warn", title: "staging is ready", flags: asked)
        #expect(card.asksQuestion)
        #expect(Delivery.choose(for: [card], wait: false) == .wait)
        #expect(try #require(flags(["--confirm", "-> Ship"])).button == "-> Ship")
        #expect(usageMessage(["--confirm", " "])?.contains("--confirm needs a label") == true)
        #expect(usageMessage(["--confirm", "Promote", "--open", "https://example.com"])?.contains("--confirm asks a question") == true)
        #expect(usageMessage(["--confirm", "Promote", "--open", ""]) != nil)
        #expect(usageMessage(["--confirm", "Promote", "--button", "Ship"])?.contains("both name the button") == true)
    }

    /// `--yes` asks as `--confirm` does, and `--no` adds the button that answers no.
    @Test func yesAndNoAsk() throws {
        let asked = try #require(flags(["--yes", "Merge", "--no", "Later"]))
        #expect(asked.button == "Merge")
        #expect(asked.decline == "Later")
        #expect(options(["--yes", "Merge", "--no", "Later"])?.warnings == [])
        let card = try CardResolver().resolve(kind: "ask", title: "Merge drip #23?", flags: asked)
        #expect(card.action == CardAction(label: "Merge", open: nil, decline: "Later"))
        #expect(card.asksQuestion && card.waitsForAnswer)
        #expect(Delivery.choose(for: [card], wait: false) == .wait)
        // --yes alone is --confirm.
        #expect(flags(["--yes", "Promote"]) == flags(["--confirm", "Promote"]))
        #expect(try #require(flags(["--confirm", "Merge", "--no", "Later"])).decline == "Later")
        // Text that starts with a dash is the label, not an option.
        #expect(try #require(flags(["--no", "-> later", "--yes", "-> now"])).decline == "-> later")
        let long = try CardResolver().resolve(
            kind: "ask", title: "t", flags: CardFlags(button: "y", decline: String(repeating: "n", count: 40)))
        #expect(long.action?.decline?.count == Defaults.buttonLimit)
        #expect(usageMessage(["--no", "Later"])?.contains("--no needs --yes") == true)
        #expect(usageMessage(["--yes", "Merge", "--no", " "])?.contains("--no needs a label") == true)
        #expect(usageMessage(["--yes", " "])?.contains("--yes needs a label") == true)
        #expect(usageMessage(["--yes", "Merge", "--confirm", "Merge"])?.contains("both name the button") == true)
        #expect(usageMessage(["--yes", "Merge", "--button", "Ship"])?.contains("both name the button") == true)
        #expect(usageMessage(["--yes", "Merge", "--no", "Later", "--open", "https://example.com"])?
            .contains("--yes asks a question") == true)
    }

    /// 0 for yes, 1 for no, 5 for no answer at all, as with --confirm.
    @Test func theExitStatusIsTheAnswer() {
        #expect(ExitStatus.answered(missed: false, declined: false) == 0)
        #expect(ExitStatus.answered(missed: false, declined: true) == 1)
        #expect(ExitStatus.answered(missed: true, declined: false) == 5)
        #expect(ExitStatus.answered(missed: true, declined: true) == 5)
    }

    /// `--button` without `--open` is the old spelling of `--confirm`, kept through 0.1 with a
    /// warning, so a script that asks with it, as a deploy approval does, still reads exit 0 or 5.
    @Test func buttonWithoutOpenStillAsks() throws {
        let arguments = ["--button", "Approve", "--seconds", "30", "--id", "mac-deploy:1", "--activate", "none", "--quiet"]
        let asked = try #require(flags(arguments))
        #expect(asked == (try #require(flags(["--confirm", "Approve", "--seconds", "30", "--id", "mac-deploy:1",
                                               "--activate", "none", "--quiet"]))))
        let card = try CardResolver().resolve(kind: "warn", title: "deploy?", flags: asked)
        #expect(card.asksQuestion)
        #expect(Delivery.choose(for: [card], wait: false) == .wait)
        #expect(options(arguments)?.warnings == ["--button without --open is deprecated; use --confirm"])
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

    /// A screen narrower than the widest capsule narrows the capsule and its text column with it, so
    /// long text wraps instead of running off the screen.
    @Test func aNarrowerWidestPillNarrowsTheCapsuleAndTheColumn() {
        let narrow = IslandMetrics(notchWidth: 185, notchHeight: 32, textWidth: 0, textHeight: 34, widestPill: 360)
        #expect(narrow.textColumn == 360 - 140)
        var full = narrow
        full.textWidth = 1000
        #expect(full.pillWidth == 360)
        #expect(full.maxWidth == 360)
    }
}
