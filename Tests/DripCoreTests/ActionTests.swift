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
        #expect(usageMessage(["--open", "https://example.com", "--button", "  "])?.contains("--button needs a label") == true)
    }

    /// `--yes` asks a question: drip waits for the card, and its exit status says whether the button
    /// was clicked. `--no` adds the button that answers no.
    @Test func yesAndNoAsk() throws {
        let asked = try #require(flags(["--yes", "Merge", "--no", "Later"]))
        #expect(asked.button == "Merge")
        #expect(asked.decline == "Later")
        #expect(options(["--yes", "Merge", "--no", "Later"])?.warnings == [])
        // On any look.
        for kind in ["ok", "warn", "fail", "info"] {
            let card = try CardResolver().resolve(kind: kind, title: "Merge drip #23?", flags: asked)
            #expect(card.action == CardAction(label: "Merge", open: nil, decline: "Later"))
            #expect(card.asksQuestion && card.waitsForAnswer)
            #expect(Delivery.choose(for: [card], wait: false) == .wait)
        }
        let alone = try #require(flags(["--yes", "Promote"]))
        #expect(alone.button == "Promote" && alone.decline == nil)
        // Text that starts with a dash is the label, not an option.
        #expect(try #require(flags(["--yes", "-> Ship"])).button == "-> Ship")
        #expect(try #require(flags(["--no", "-> later", "--yes", "-> now"])).decline == "-> later")
        let long = try CardResolver().resolve(
            kind: "warn", title: "t", flags: CardFlags(button: "y", decline: String(repeating: "n", count: 40)))
        #expect(long.action?.decline?.count == Defaults.buttonLimit)
        #expect(usageMessage(["--no", "Later"])?.contains("--no needs --yes") == true)
        #expect(usageMessage(["--yes", "Merge", "--no", " "])?.contains("--no needs a label") == true)
        #expect(usageMessage(["--yes", " "])?.contains("--yes needs a label") == true)
        #expect(usageMessage(["--yes", "Merge", "--no", "Later", "--open", "https://example.com"])?
            .contains("--yes asks a question") == true)
        #expect(usageMessage(["--yes", "Promote", "--open", ""]) != nil)
    }

    /// 0 for yes, 1 for no, 5 for no answer at all.
    @Test func theExitStatusIsTheAnswer() {
        #expect(ExitStatus.answered(missed: false, declined: false) == 0)
        #expect(ExitStatus.answered(missed: false, declined: true) == 1)
        #expect(ExitStatus.answered(missed: true, declined: false) == 5)
        #expect(ExitStatus.answered(missed: true, declined: true) == 5)
    }

    /// `--confirm` is gone, and `--button` names only the `--open` button: `--yes` asks.
    @Test func confirmAndAButtonWithoutOpenAreUsageErrors() {
        #expect(usageMessage(["--confirm", "Promote"]) != nil)
        #expect(usageMessage(["--button", "Approve"])?.contains("--button names the --open button, so it needs --open") == true)
        #expect(usageMessage(["--yes", "Merge", "--button", "Ship"])?.contains("needs --open") == true)
    }

    /// `--stay` keeps a card of any look on screen without holding the script.
    @Test func stayKeepsTheCardWithoutWaiting() throws {
        let staying = try #require(flags(["--stay"]))
        #expect(staying.stay)
        #expect(try #require(flags([])).stay == false)
        for kind in ["ok", "warn", "fail", "info"] {
            let card = try CardResolver().resolve(kind: kind, title: "Deploy failed", flags: staying)
            #expect(card.kind == kind)
            #expect(card.waitLimit == Defaults.waitLimit)
            #expect(card.showsWaitingMark && card.isClickable && card.showsIconAtNotch)
            // It gives way to other cards, unlike a question, and the script moves on.
            #expect(!card.waitsForAnswer)
            #expect(Delivery.choose(for: [card], wait: false) == .background)
        }
        // A time counts it down instead.
        let timed = try CardResolver().resolve(kind: "fail", title: "t", flags: CardFlags(seconds: 8, stay: true))
        #expect(!timed.waits && timed.seconds == 8)
        // With a link button, it stays and still opens the link.
        let linked = try CardResolver().resolve(
            kind: "ok", title: "t", flags: CardFlags(stay: true, open: "https://example.com", button: "View"))
        #expect(linked.waits && !linked.asksQuestion)
        #expect(Delivery.choose(for: [linked], wait: false) == .background)
    }

    /// `drip run` and `drip hook` cannot ask: `drip run` exits with its command's code and `drip
    /// hook` with 0 or 1, so nothing would read the answer.
    @Test func runAndHookTakeNoQuestion() {
        for prefix in [["run"], ["hook", "claude"]] {
            for question in [["--yes", "Retry"], ["--yes", "Retry", "--no", "Stop"], ["--no", "Stop"]] {
                let arguments = prefix + question + (prefix == ["run"] ? ["make"] : ["{}"])
                guard case let .exit(status, message) = CommandLineParser.parse(arguments) else {
                    Issue.record("\(arguments) parsed")
                    continue
                }
                // Any failure of drip hook exits 1, as an agent reads 2 as "block".
                #expect(status == (prefix == ["run"] ? ExitStatus.usage : ExitStatus.hookFailed), "\(arguments)")
                #expect(message.contains("--no needs --yes") || message.contains("takes no --yes"), "\(message)")
            }
            guard case .invocation = CommandLineParser.parse(prefix + ["--stay"] + (prefix == ["run"] ? ["make"] : ["{}"]))
            else { Issue.record("\(prefix) --stay did not parse"); continue }
        }
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
            sound: .file("~/sounds/done.aiff"), seconds: 7.5, size: .large, motion: .subtle)
        card.action = CardAction(label: "View run", open: "https://example.com/run/1")
        let others = [Card(preset: .fail, title: "x"), Card(preset: .info, title: "y")]
        let request = BackgroundRequest(cards: [card] + others)
        #expect(try BackgroundRequest.decode(request.encoded()) == request)
    }

    @Test func aHandOffSurvivesTheTripToTheBackgroundDrip() throws {
        let handOff = StackHandOff(settings: StackSettings(mode: .push, max: 2), cards: [
            HandedCard(card: Card(preset: .ok, title: "done"), top: 42, remaining: 12.5, isWaiting: false),
            HandedCard(card: .staying(title: "needs you"), top: 98, remaining: 590, isWaiting: true, leaving: 0.04),
        ])
        let request = BackgroundRequest(handOff: handOff)
        #expect(request.cards.map(\.title) == ["done", "needs you"])
        #expect(!request.record)
        #expect(try BackgroundRequest.decode(request.encoded()) == request)
    }

    @Test func aRequestFromBeforeHandOffsHandsNothingOn() throws {
        let old = try BackgroundRequest.decode(Data(#"{"cards":[],"record":false}"#.utf8))
        #expect(old == BackgroundRequest(cards: [], record: false))
        #expect(old.handOff == nil)
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
