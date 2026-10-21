import DripCore
import Testing

/// The stack the Mac app draws at the notch and the web page draws on a canvas.
struct CardStackTests {
    private let metrics = IslandMetrics(notchWidth: 185, notchHeight: 32, textWidth: 180, textHeight: 34)

    private func card(_ title: String, seconds: Double = 3) -> Card {
        var card = Card(preset: .info, title: title)
        card.seconds = seconds
        return card
    }

    /// A card that waits for you, as `ask` does.
    private func asking(_ title: String, seconds: Double = 3) -> Card {
        var card = Card(preset: .ask, title: title)
        card.seconds = seconds
        return card
    }

    /// Runs the stack's clock as a drawing would, 60 steps a second from `from` until `until`, letting
    /// this drip's own cards in whenever the stack is ready for one. `step` sees the stack after each.
    @discardableResult
    private func run(
        _ stack: CardStack, from: Double = 0, until: Double, needsRoom: Bool = false, othersWaiting: Bool = false,
        step: (Double, CardStack.Changes) -> Void = { _, _ in }
    ) -> Double {
        var time = from
        while time < until {
            if stack.isReady(at: time), let next = stack.nextOwn(at: time) {
                stack.enter(next, metrics: metrics, own: true, decided: time, at: time)
            }
            let changes = stack.advance(
                to: time, elapsed: 1.0 / 60, lead: 0, needsRoom: needsRoom, othersWaiting: othersWaiting)
            step(time, changes)
            time += 1.0 / 60
        }
        return time
    }

    private func titles(_ entries: [CardStack.Entry]) -> [String] {
        entries.map(\.card.title)
    }

    @Test func chainDropsEachCardFromTheOneAbove() {
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: ["a", "b", "c"].map { card($0, seconds: 10) })
        run(stack, until: 4)
        #expect(titles(stack.live) == ["a", "b", "c"])
        #expect(stack.live.map { $0.anchor?.card.title } == [nil, "a", "b"])
        // At rest, one under another with the gap between them.
        let tops = stack.live.map(\.animator.targetTop)
        #expect(tops[0] == metrics.pillTop)
        #expect(tops[1] == tops[0] + metrics.pillHeight + CardStack.gap)
        #expect(tops[2] == tops[1] + metrics.pillHeight + CardStack.gap)
        #expect(stack.live.allSatisfy { $0.isShown })
    }

    @Test func pushDropsEachCardFromTheNotchAndPushesTheOthersDown() {
        let stack = CardStack(settings: StackSettings(mode: .push, max: 3), cards: ["a", "b", "c"].map { card($0, seconds: 10) })
        var overlapped = false
        run(stack, until: 4) { time, _ in
            // The new drop never touches the card it pushes down.
            let shapes = stack.live.map { $0.animator.shape(at: time) }
            for (upper, lower) in zip(shapes, shapes.dropFirst()) where upper.pillTop + upper.pillHeight > lower.pillTop {
                overlapped = true
            }
        }
        #expect(!overlapped)
        #expect(titles(stack.live) == ["c", "b", "a"])
        #expect(stack.live.allSatisfy { $0.anchor == nil })
        let tops = stack.live.map(\.animator.targetTop)
        #expect(tops == [0, 1, 2].map { metrics.pillTop + Double($0) * (metrics.pillHeight + CardStack.gap) })
    }

    @Test func aFourthCardWaitsForRoom() {
        let stack = CardStack(
            settings: StackSettings(mode: .chain, max: 3),
            cards: [card("a", seconds: 2), card("b", seconds: 6), card("c", seconds: 6), card("d", seconds: 6)])
        var most = 0
        var leftBeforeD: [String] = []
        var dEntered = false
        run(stack, until: 12) { _, changes in
            most = max(most, stack.live.count)
            if !dEntered { leftBeforeD += titles(changes.left.map(\.entry)) }
            dEntered = dEntered || stack.entries.contains { $0.card.title == "d" }
        }
        #expect(most == 3)
        #expect(dEntered)
        #expect(leftBeforeD == ["a"])
        #expect(stack.waiting.isEmpty)
    }

    @Test func aCardThatWaitsStaysUntilItIsClicked() {
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: [asking("a")])
        let time = run(stack, until: 30)
        #expect(titles(stack.live) == ["a"])
        #expect(stack.live[0].isWaiting)
        stack.live[0].dismissed = false
        var left: [String] = []
        run(stack, from: time, until: time + 2) { _, changes in left += titles(changes.left.map(\.entry)) }
        #expect(left == ["a"])
    }

    @Test func aCardThatWaitsStaysNoLongerThanItsLimit() {
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: [asking("a")])
        var leftAt: Double?
        run(stack, until: Defaults.waitLimit + 5) { time, changes in
            if leftAt == nil, !changes.left.isEmpty { leftAt = time }
        }
        #expect(leftAt.map { $0 > Defaults.waitLimit && $0 < Defaults.waitLimit + 2 } == true)
    }

    @Test func theOldestCardThatWaitsGivesWayWhenACardNeedsRoom() {
        let stack = CardStack(
            settings: StackSettings(mode: .chain, max: 2),
            cards: [asking("a", seconds: 2), asking("b", seconds: 2), card("c", seconds: 10)])
        var stopped: [String] = []
        var left: [String] = []
        run(stack, until: 12) { _, changes in
            stopped += titles(changes.stoppedWaiting)
            left += titles(changes.left.map(\.entry))
        }
        // a counted down its own time and went; b goes on waiting below c.
        #expect(stopped == ["a"])
        #expect(left == ["a"])
        #expect(titles(stack.live) == ["b", "c"])
        #expect(stack.live[0].isWaiting && !stack.live[1].isWaiting)
    }

    @Test func noCardGivesWayWhileAnotherWillLeaveOnItsOwn() {
        let stack = CardStack(
            settings: StackSettings(mode: .chain, max: 2),
            cards: [asking("a"), card("b", seconds: 4), card("c", seconds: 10)])
        var stopped: [String] = []
        run(stack, until: 10) { _, changes in stopped += titles(changes.stoppedWaiting) }
        #expect(stopped.isEmpty)
        #expect(titles(stack.live) == ["a", "c"])
        #expect(stack.live[0].isWaiting)
    }

    @Test func cardsThatWaitGiveWayToOtherDrips() {
        // Another drip's card waits for room in a full stack: the oldest gives way.
        let full = CardStack(settings: StackSettings(mode: .chain, max: 1), cards: [asking("a")])
        var stopped: [String] = []
        run(full, until: 3, needsRoom: true) { _, changes in stopped += titles(changes.stoppedWaiting) }
        #expect(stopped == ["a"])

        // With room for it, nothing gives way.
        let roomy = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: [asking("a")])
        run(roomy, until: 3, needsRoom: true)
        #expect(roomy.live[0].isWaiting)

        // A drip that waits for the stack to finish: every card that waits gives way.
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: [asking("a"), asking("b")])
        var time = run(stack, until: 3)
        #expect(stack.live.allSatisfy { $0.isWaiting })
        let changes = stack.advance(to: time, elapsed: 0, lead: 0.06, othersWaiting: true)
        #expect(titles(changes.stoppedWaiting) == ["a", "b"])
        #expect(stack.live.allSatisfy { !$0.isWaiting && $0.remaining == 3 && $0.countdownFrom >= time + 0.06 })
        time = run(stack, from: time, until: time + 6)
        #expect(stack.entries.isEmpty)
    }

    @Test func aCardThatWaitsWaitsAgainWhenReplacedByOneThatWaits() {
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: [asking("a")])
        let time = run(stack, until: 3)
        let entry = stack.live[0]
        _ = stack.advance(to: time, elapsed: 0, lead: 0, othersWaiting: true)
        #expect(!entry.isWaiting)
        stack.swap(entry, for: asking("a again"), metrics: metrics, at: time, reduced: false)
        #expect(entry.isWaiting && entry.remaining == Defaults.waitLimit)
        stack.swap(entry, for: card("done", seconds: 4), metrics: metrics, at: time, reduced: false)
        #expect(!entry.isWaiting && entry.remaining == 4)
    }

    @Test func theCardsBelowCloseTheGapAndHangFromTheCardAbove() {
        let stack = CardStack(
            settings: StackSettings(mode: .chain, max: 3),
            cards: [card("a", seconds: 10), card("b", seconds: 10), card("c", seconds: 10)])
        let time = run(stack, until: 4)
        // A click on the card, away from any button.
        stack.live[1].dismissed = false
        var left: [(String, Bool)] = []
        let end = run(stack, from: time, until: time + 3) { _, changes in
            left += changes.left.map { ($0.entry.card.title, $0.clicked) }
        }
        #expect(left.map(\.0) == ["b"] && left.map(\.1) == [false])
        #expect(titles(stack.entries) == ["a", "c"])
        #expect(stack.live[1].anchor === stack.live[0])
        #expect(stack.live[1].animator.targetTop == metrics.pillTop + metrics.pillHeight + CardStack.gap)
        #expect(stack.live[1].animator.end <= end)
    }

    @Test func aClickedButtonIsReported() {
        var withButton = card("a", seconds: 10)
        withButton.action = CardAction(label: "Open", open: nil)
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: [withButton])
        let time = run(stack, until: 2)
        stack.live[0].dismissed = true
        let changes = stack.advance(to: time, elapsed: 0, lead: 0.06)
        #expect(changes.left.count == 1 && changes.left[0].clicked && changes.left[0].time == time + 0.06)
    }

    @Test func nothingMovesWhileThePointerIsOnTheStack() {
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: [card("a", seconds: 1), card("b")])
        let time = run(stack, until: 0.1)
        #expect(stack.hover(true))
        #expect(!stack.hover(true))
        // Long past its time, the card stays, and the next one waits.
        run(stack, from: time, until: time + 5)
        #expect(titles(stack.entries) == ["a"])
        #expect(!stack.isReady(at: time + 5))
        // A moment to read it once the pointer leaves.
        #expect(stack.hover(false))
        #expect(stack.live[0].remaining == 1.5)
    }

    @Test func pausesHoldTheNextCardBack() throws {
        let stack = CardStack(
            settings: StackSettings(mode: .chain, max: 3, pauses: [0, 2.5]), cards: [card("a", seconds: 10), card("b", seconds: 10)])
        var entered: Double?
        run(stack, until: 4) { time, _ in
            if entered == nil, stack.entries.count == 2 { entered = time }
        }
        #expect(try #require(entered) >= 2.5)
    }

    @Test func theOutlineMeltsEachDropIntoWhatItGrowsOutOf() {
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: [card("a", seconds: 10)])
        let time = run(stack, until: 2)
        stack.enter(card("b"), metrics: metrics, own: true, decided: time, at: time)
        let outline = stack.outline
        #expect(outline.cards.map(\.anchor) == [nil, 0])
        #expect(outline.notch == metrics)
        // The first card floats free; the second is still a drop hanging from it.
        let pieces = outline.pieces(at: time + 0.15)
        guard case .capsule = pieces[0], case let .traced(field) = pieces[1] else {
            Issue.record("expected a capsule and a traced drop, got \(pieces)")
            return
        }
        let first = stack.entries[0]
        #expect(field.anchor == DropletAnchor.capsule(first.animator.shape(at: time + 0.15), metrics: first.metrics))
    }

    @Test func thePointerFindsTheCardAndItsButton() {
        var withButton = card("a", seconds: 10)
        withButton.action = CardAction(label: "Open", open: nil)
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: [withButton, card("b", seconds: 10)])
        let time = run(stack, until: 4)
        let (a, b) = (stack.live[0], stack.live[1])
        let middle = { (entry: CardStack.Entry) in
            let shape = entry.animator.shape(at: time)
            return IslandPoint(0, shape.pillTop + shape.pillHeight / 2)
        }
        #expect(stack.entry(at: middle(a), time: time) === a)
        #expect(stack.entry(at: middle(b), time: time) === b)
        #expect(stack.entry(at: IslandPoint(0, 2), time: time) == nil)
        let ring = a.animator.content(for: a.animator.shape(at: time)).ringCenter
        #expect(stack.isOnButton(of: a, at: ring, time: time))
        #expect(!stack.isOnButton(of: a, at: middle(a), time: time))
        #expect(!stack.isOnButton(of: b, at: b.animator.content(for: b.animator.shape(at: time)).ringCenter, time: time))
    }
}
