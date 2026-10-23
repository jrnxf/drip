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

    /// A card that waits for you, as `--stay` makes it.
    private func asking(_ title: String, seconds: Double = 3) -> Card {
        var card = Card.staying(title: title)
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
            if stack.isReady(at: time), let next = stack.nextOwn() {
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

    /// A question never gives way: other cards stack around it, and one with no room waits for it.
    @Test func aQuestionNeverStopsWaiting() {
        var question = asking("merge?")
        question.action = CardAction(label: "Merge", open: nil, decline: "Later")
        #expect(question.waitsForAnswer)

        // Another drip waits for the stack to finish: the card that stays gives way, the question does not.
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: [question, asking("b")])
        var time = run(stack, until: 3)
        let changes = stack.advance(to: time, elapsed: 0, lead: 0, othersWaiting: true)
        #expect(titles(changes.stoppedWaiting) == ["b"])
        time = run(stack, from: time, until: time + 30, othersWaiting: true)
        #expect(titles(stack.live) == ["merge?"])
        #expect(stack.live[0].isWaiting)

        // A full stack of questions and a card that needs room: nothing gives way, so it waits.
        let full = CardStack(settings: StackSettings(mode: .chain, max: 1), cards: [question])
        var stopped: [String] = []
        run(full, until: 30, needsRoom: true) { _, changes in stopped += titles(changes.stoppedWaiting) }
        #expect(stopped.isEmpty)
        #expect(full.live[0].isWaiting)

        // Beside a card that stays, that card gives way for room instead.
        let mixed = CardStack(
            settings: StackSettings(mode: .chain, max: 2), cards: [question, asking("b", seconds: 2), card("c", seconds: 10)])
        stopped = []
        run(mixed, until: 12) { _, changes in stopped += titles(changes.stoppedWaiting) }
        #expect(stopped == ["b"])
        #expect(titles(mixed.live) == ["merge?", "c"])

        // A question that counts down a time it was given still goes when its time is up.
        var timed = question
        timed.waitLimit = nil
        #expect(!timed.waitsForAnswer)
    }

    @Test func aStackHoldsItsOwnCardsUntilTheyHaveGone() {
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: [card("a", seconds: 1)])
        #expect(stack.holdsOwn)
        var time = run(stack, until: 1)
        stack.enter(card("adopted", seconds: 10), metrics: metrics, own: false, decided: time, at: time)
        #expect(stack.holdsOwn)
        time = run(stack, from: time, until: time + 4)
        #expect(titles(stack.live) == ["adopted"])
        #expect(!stack.holdsOwn)
    }

    /// Answered while a card it took in has long left, a question's stack hands every card on, its
    /// own on its way out, in the same step of the clock as the answer.
    @Test func anAnsweredQuestionHandsOnTheCardsItTookIn() throws {
        var question = asking("merge?")
        question.action = CardAction(label: "Merge", open: nil, decline: "Later")
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: [question])
        var time = run(stack, until: 2)
        let done = stack.enter(card("done", seconds: 30), metrics: metrics, own: false, decided: time, at: time)
        let needsYou = stack.enter(asking("needs you"), metrics: metrics, own: false, decided: time, at: time)
        time = run(stack, from: time, until: time + 3)
        #expect(stack.handOff(at: time) == nil)

        // Clicked: the next step of the clock sends the card off and the stack can go at once.
        let answered = time
        stack.live[0].answer = .yes
        stack.live[0].dismissed = true
        var handed: (time: Double, cards: [HandedCard], left: [Double], tops: [Double])?
        run(stack, from: time, until: time + 5) { now, _ in
            guard handed == nil, let cards = stack.handOff(at: now) else { return }
            handed = (
                now, cards, [done.remaining, needsYou.remaining],
                [done, needsYou].map { $0.animator.shape(at: now).pillTop })
        }
        let handOff = try #require(handed)
        #expect(handOff.time - answered < 0.05)
        #expect(handOff.cards.map(\.card) == [question, card("done", seconds: 30), asking("needs you")])
        let leaving = try #require(handOff.cards[0].leaving)
        #expect(leaving < 0.05)
        let adopted = Array(handOff.cards.dropFirst())
        #expect(adopted.map(\.remaining) == handOff.left)
        for (card, top) in zip(adopted, handOff.tops) { #expect(abs(card.drawnTop - top) < 0.1) }
        #expect(adopted[0].remaining > 25)
        #expect(adopted.map(\.isWaiting) == [false, true])
        #expect(adopted.allSatisfy { $0.leaving == nil })
        #expect(!stack.holdsOwn)
    }

    /// A single answered card at the notch, handed on, leaves the way it would have alone.
    @Test func aLeavingIslandHandedOnLeavesAsItWould() throws {
        let handOff = StackHandOff.leaving(asking("merge?"), top: metrics.pillTop, at: 1_000)
        let aged = handOff.cards(at: 1_000.1)
        #expect(abs((aged.first?.leaving ?? 0) - 0.1) < 0.001)
        let stack = CardStack(settings: handOff.settings)
        let (entry, cues) = stack.resume(try #require(aged.first), metrics: metrics, at: 50)
        #expect(cues != nil)
        #expect(entry.isLeaving)

        var alone = IslandAnimator(metrics: metrics)
        alone.open()
        _ = alone.exit(at: 0)
        let leaving = try #require(aged.first?.leaving)
        for offset in [0.0, 0.1, 0.3] {
            let was = alone.shape(at: leaving + offset), now = entry.animator.shape(at: 50 + offset)
            #expect(abs(was.pillTop - now.pillTop) < 0.01)
            #expect(abs(was.pillWidth - now.pillWidth) < 0.01)
        }
    }

    @Test func aStackWithNoAdoptedCardsHandsOnNothing() {
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3), cards: [card("a", seconds: 1)])
        #expect(stack.handOff(at: 0) == nil)
        let time = run(stack, until: 4)
        #expect(stack.entries.isEmpty)
        #expect(stack.handOff(at: time) == [])
    }

    /// The cards handed on show in the new stack where they were, in the same order, with the time
    /// they had left, and a card that was leaving goes on leaving from as far as it had got.
    @Test func handedOnCardsShowAsTheyWere() throws {
        let settings = StackSettings(mode: .chain, max: 3)
        let before = CardStack(settings: settings)
        var time = 0.0
        for title in ["a", "b", "c"] {
            before.enter(card(title, seconds: 30), metrics: metrics, own: false, decided: time, at: time)
            time = run(before, from: time, until: time + 1)
        }
        time = run(before, from: time, until: time + 2)
        let leaving = before.live[2]
        leaving.dismissed = true
        time = run(before, from: time, until: time + 0.1)
        let handed = try #require(before.handOff(at: time))
        #expect(handed.map(\.card.title) == ["a", "b", "c"])
        let fade = try #require(handed[2].leaving)
        #expect(fade > 0 && fade < 0.2)

        let after = CardStack(settings: settings)
        let resumed = handed.map { after.resume($0, metrics: metrics, at: 50) }
        #expect(titles(after.entries) == ["a", "b", "c"])
        #expect(titles(after.live) == ["a", "b"])
        #expect(after.entries.map(\.remaining) == handed.map(\.remaining))
        #expect(resumed.map { $0.exit == nil } == [true, true, false])
        for (old, new) in zip(before.entries, after.entries) {
            let was = old.animator.shape(at: time), now = new.animator.shape(at: 50)
            #expect(abs(was.pillTop - now.pillTop) < 0.01)
            #expect(abs(was.pillWidth - now.pillWidth) < 0.01)
            #expect(abs(was.pillHeight - now.pillHeight) < 0.01)
        }
        // Both go on as one: the leaving card is gone at the same moment, the others count down.
        var gone: (before: Double?, after: Double?) = (nil, nil)
        run(before, from: time, until: time + 2) { now, changes in
            if gone.before == nil, !changes.gone.isEmpty { gone.before = now - time }
        }
        run(after, from: 50, until: 52) { now, changes in
            if gone.after == nil, !changes.gone.isEmpty { gone.after = now - 50 }
        }
        let goneBefore = try #require(gone.before), goneAfter = try #require(gone.after)
        #expect(abs(goneBefore - goneAfter) < 0.05)
        #expect(after.live.allSatisfy { $0.remaining < 30 && $0.remaining > 20 })
    }

    /// Shown a moment after they were handed on, the cards are as they are by then: a leaving card
    /// further into its exit, every countdown further on, a gliding card further on its way.
    @Test func handedOnCardsAgeUntilTheyShow() throws {
        let settings = StackSettings(mode: .chain, max: 3)
        let before = CardStack(settings: settings)
        var time = 0.0
        for title in ["a", "b", "c"] {
            before.enter(card(title, seconds: 30), metrics: metrics, own: false, decided: time, at: time)
            time = run(before, from: time, until: time + 1)
        }
        time = run(before, from: time, until: time + 2)
        before.live[0].dismissed = true
        before.live[2].dismissed = true
        time = run(before, from: time, until: time + 0.1)
        let handOff = StackHandOff(settings: settings, cards: try #require(before.handOff(at: time)), time: 1_000)
        #expect(handOff.cards(at: 1_000) == handOff.cards)
        #expect(handOff.cards(at: 999) == handOff.cards)

        // b, alone, glides up into a's place once a has risen.
        time = run(before, from: time, until: time + 0.35)
        let b = before.live[0]
        #expect(b.card.title == "b")
        let moving = try #require(before.handOff(at: time))
        let gliding = try #require(moving.first { $0.card.title == "b" })
        #expect(!gliding.glide.isEmpty)
        #expect(gliding.top == b.animator.targetTop)
        #expect(abs(gliding.drawnTop - b.animator.shape(at: time).pillTop) < 0.1)

        let age = 0.25
        let aged = StackHandOff(settings: settings, cards: moving, time: 1_000).cards(at: 1_000 + age)
        for (was, now) in zip(moving, aged) {
            #expect(now.remaining == max(was.remaining - age, 0))
            #expect(now.leaving == was.leaving.map { $0 + age })
        }

        // Shown on in another stack, it goes on gliding from where it is drawn by then, as fast.
        let glided = try #require(aged.first { $0.card.title == "b" })
        let after = CardStack(settings: settings)
        let resumed = after.resume(glided, metrics: metrics, at: 50).entry
        func top(_ entry: CardStack.Entry, _ time: Double) -> Double { entry.animator.shape(at: time).pillTop }
        let step = 1.0 / 240
        for offset in [0, 0.05, 0.2] {
            let was = time + age + offset, now = 50 + offset
            #expect(abs(top(resumed, now) - top(b, was)) < 0.1)
            #expect(abs((top(resumed, now + step) - top(resumed, now)) - (top(b, was + step) - top(b, was))) < 0.01)
        }
        #expect(gliding.aged(by: 5).glide.isEmpty)
        #expect(gliding.aged(by: 5).drawnTop == gliding.top)
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
        #expect(stack.button(of: a, at: ring, time: time) == .yes)
    }

    @Test func aQuestionsNoButtonIsLeftOfItsYesButton() {
        var question = asking("merge?")
        question.action = CardAction(label: "Merge", open: nil, decline: "Later")
        let (no, yes) = (50.0, 60.0)
        var buttons = metrics
        buttons.actionWidth = IslandMetrics.buttonsWidth(yes: yes, no: no, scale: 1)
        buttons.declineWidth = no
        #expect(buttons.actionWidth == 116)
        #expect(IslandMetrics.buttonsWidth(yes: yes, no: nil, scale: 1.25) == yes)
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 3))
        let entry = stack.enter(question, metrics: buttons, own: true, decided: 0, at: 0)
        run(stack, until: 3)
        let layout = entry.animator.content(for: entry.animator.shape(at: 3))
        let left = layout.ringCenter.x - layout.ringSize / 2, y = layout.ringCenter.y
        #expect(stack.button(of: entry, at: IslandPoint(left + no / 2, y), time: 3) == .no)
        #expect(stack.button(of: entry, at: IslandPoint(left + no + 2, y), time: 3) == .no)
        #expect(stack.button(of: entry, at: IslandPoint(left + no + 4, y), time: 3) == .yes)
        #expect(stack.button(of: entry, at: IslandPoint(left + no + 6 + yes / 2, y), time: 3) == .yes)
        #expect(stack.button(of: entry, at: IslandPoint(left - 20, y), time: 3) == nil)
    }
}
