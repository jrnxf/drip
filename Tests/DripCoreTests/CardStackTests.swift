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
        let stack = CardStack(settings: StackSettings(max: 3), cards: ["a", "b", "c"].map { card($0, seconds: 10) })
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

    @Test func aFourthCardWaitsForRoom() {
        let stack = CardStack(
            settings: StackSettings(max: 3),
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
        let stack = CardStack(settings: StackSettings(max: 3), cards: [asking("a")])
        let time = run(stack, until: 30)
        #expect(titles(stack.live) == ["a"])
        #expect(stack.live[0].isWaiting)
        stack.live[0].dismissed = false
        var left: [String] = []
        run(stack, from: time, until: time + 2) { _, changes in left += titles(changes.left.map(\.entry)) }
        #expect(left == ["a"])
    }

    @Test func aCardThatWaitsStaysNoLongerThanItsLimit() {
        let stack = CardStack(settings: StackSettings(max: 3), cards: [asking("a")])
        var leftAt: Double?
        run(stack, until: Defaults.waitLimit + 5) { time, changes in
            if leftAt == nil, !changes.left.isEmpty { leftAt = time }
        }
        #expect(leftAt.map { $0 > Defaults.waitLimit && $0 < Defaults.waitLimit + 2 } == true)
    }

    @Test func theOldestCardThatWaitsGivesWayWhenACardNeedsRoom() {
        let stack = CardStack(
            settings: StackSettings(max: 2),
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
            settings: StackSettings(max: 2),
            cards: [asking("a"), card("b", seconds: 4), card("c", seconds: 10)])
        var stopped: [String] = []
        run(stack, until: 10) { _, changes in stopped += titles(changes.stoppedWaiting) }
        #expect(stopped.isEmpty)
        #expect(titles(stack.live) == ["a", "c"])
        #expect(stack.live[0].isWaiting)
    }

    @Test func cardsThatWaitGiveWayToOtherDrips() {
        // Another drip's card waits for room in a full stack: the oldest gives way.
        let full = CardStack(settings: StackSettings(max: 1), cards: [asking("a")])
        var stopped: [String] = []
        run(full, until: 3, needsRoom: true) { _, changes in stopped += titles(changes.stoppedWaiting) }
        #expect(stopped == ["a"])

        // With room for it, nothing gives way.
        let roomy = CardStack(settings: StackSettings(max: 3), cards: [asking("a")])
        run(roomy, until: 3, needsRoom: true)
        #expect(roomy.live[0].isWaiting)

        // A drip that waits for the stack to finish: every card that waits gives way.
        let stack = CardStack(settings: StackSettings(max: 3), cards: [asking("a"), asking("b")])
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
        let stack = CardStack(settings: StackSettings(max: 3), cards: [question, asking("b")])
        var time = run(stack, until: 3)
        let changes = stack.advance(to: time, elapsed: 0, lead: 0, othersWaiting: true)
        #expect(titles(changes.stoppedWaiting) == ["b"])
        time = run(stack, from: time, until: time + 30, othersWaiting: true)
        #expect(titles(stack.live) == ["merge?"])
        #expect(stack.live[0].isWaiting)

        // A full stack of questions and a card that needs room: nothing gives way, so it waits.
        let full = CardStack(settings: StackSettings(max: 1), cards: [question])
        var stopped: [String] = []
        run(full, until: 30, needsRoom: true) { _, changes in stopped += titles(changes.stoppedWaiting) }
        #expect(stopped.isEmpty)
        #expect(full.live[0].isWaiting)

        // Beside a card that stays, that card gives way for room instead.
        let mixed = CardStack(
            settings: StackSettings(max: 2), cards: [question, asking("b", seconds: 2), card("c", seconds: 10)])
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
        let stack = CardStack(settings: StackSettings(max: 3), cards: [card("a", seconds: 1)])
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
        let stack = CardStack(settings: StackSettings(max: 3), cards: [question])
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
        let stack = CardStack(settings: StackSettings(max: 3), cards: [card("a", seconds: 1)])
        #expect(stack.handOff(at: 0) == nil)
        let time = run(stack, until: 4)
        #expect(stack.entries.isEmpty)
        #expect(stack.handOff(at: time) == [])
    }

    /// The cards handed on show in the new stack where they were, in the same order, with the time
    /// they had left, and a card that was leaving goes on leaving from as far as it had got.
    @Test func handedOnCardsShowAsTheyWere() throws {
        let settings = StackSettings(max: 3)
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
        let settings = StackSettings(max: 3)
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
        let stack = CardStack(settings: StackSettings(max: 3), cards: [asking("a")])
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
            settings: StackSettings(max: 3),
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

    /// A stack of `titles` whose cards' times run out at `ends`, top to bottom, on the stack's clock,
    /// and when each card left: the titles that left in one step, and the time.
    private func leaves(_ titles: [String], ends: [Double], step: Double = 1.0 / 60, phase: Double = 0)
        -> (stack: CardStack, left: [(titles: [String], time: Double)])
    {
        // When each card starts counting down, learned from cards that stay.
        let probe = CardStack(settings: StackSettings(max: 6), cards: titles.map { card($0, seconds: 60) })
        var time = phase
        func drive(_ stack: CardStack, until: Double, each: (Double, CardStack.Changes) -> Void = { _, _ in }) {
            time = phase
            var last = phase
            while time < until {
                if stack.isReady(at: time), let next = stack.nextOwn() {
                    stack.enter(next, metrics: metrics, own: true, decided: time, at: time)
                }
                each(time, stack.advance(to: time, elapsed: time - last, lead: 0))
                last = time
                time += step
            }
        }
        drive(probe, until: 8)
        let from = probe.live.map(\.countdownFrom)
        let stack = CardStack(
            settings: StackSettings(max: 6), cards: titles.indices.map { card(titles[$0], seconds: ends[$0] - from[$0]) })
        var left: [(titles: [String], time: Double)] = []
        drive(stack, until: 20) { time, changes in
            if !changes.left.isEmpty { left.append((changes.left.map(\.entry.card.title), time)) }
        }
        return (stack, left)
    }

    /// Cards whose time runs out together leave together, in one motion, whatever frame each
    /// countdown started on and however long a frame is.
    @Test func cardsWhoseTimeRunsOutTogetherLeaveTogether() {
        let titles = ["a", "b", "c", "d", "e", "f"]
        // A few milliseconds apart, as countdowns that start on different frames end.
        let ends = [12.004, 12.0, 12.011, 12.002, 12.016, 12.007]
        for step in [1.0 / 60, 1.0 / 120, 1.0 / 47] {
            for phase in stride(from: 0, to: step, by: step / 8) {
                let (stack, left) = leaves(titles, ends: ends, step: step, phase: phase)
                #expect(left.map(\.titles) == [titles], "step \(step) phase \(phase)")
                #expect(stack.entries.isEmpty)
            }
        }
    }

    /// A card whose time is up within the round's window goes with the first, once its own time is
    /// up, so neither goes before its ring is empty. One whose time is up later goes on its own, once
    /// the stack is at rest again.
    @Test func aCardWhoseTimeIsUpSoonAfterGoesWithTheFirst() throws {
        let inside = leaves(["a", "b"], ends: [10, 10.15]).left
        #expect(inside.map(\.titles) == [["a", "b"]])
        #expect(try #require(inside.first).time >= 10.15)
        #expect(try #require(inside.first).time < 10.3)

        let outside = leaves(["a", "b"], ends: [10, 10.5]).left
        #expect(outside.map(\.titles) == [["a"], ["b"]])
        #expect(try #require(outside.first).time < 10.12)
        // The second waits for the first one's drop to go and the stack to close up.
        #expect(try #require(outside.last).time > 10.5)
    }

    /// The round does not grow as it waits: each card here ends within the window of the one before,
    /// but only those within it of the first go with the first.
    @Test func aRoundTakesOnlyTheCardsWithinItsWindow() {
        let left = leaves(["a", "b", "c", "d"], ends: [10, 10.15, 10.35, 10.5]).left
        #expect(left.map(\.titles) == [["a", "b"], ["c", "d"]])
    }

    /// The cards that leave together are neighbours, so no card that stays is between two drops:
    /// the one a drop is aimed at would otherwise move away under it. Two cards whose time is up
    /// together with a card that stays between them leave one after the other, the upper first,
    /// whichever frame each countdown ended on.
    @Test func cardsThatLeaveTogetherAreNeighbours() {
        for (first, third) in [(10.0, 10.0), (10.0, 10.012), (10.012, 10.0)] {
            let (_, left) = leaves(["a", "b", "c"], ends: [first, 13, third])
            #expect(left.map(\.titles) == [["a"], ["c"], ["b"]], "\(first) \(third)")
        }
        // A block in the middle goes into the card above it, and one at the bottom into the one above.
        #expect(leaves(["a", "b", "c", "d", "e"], ends: [13, 10, 10, 10, 13]).left.map(\.titles) == [["b", "c", "d"], ["a", "e"]])
        #expect(leaves(["a", "b", "c", "d"], ends: [13, 13, 10, 10]).left.map(\.titles) == [["c", "d"], ["a", "b"]])
    }

    /// Cards whose times run out within one exit of each other, the bottom card's first: it leaves
    /// alone, on time, as the others are not due within its round. Those two then leave together,
    /// from a stack at rest, each from its place in a closed-up stack.
    @Test func cardsWhoseTimeRunsOutCloseTogetherLeaveInRounds() {
        let (stack, left) = leaves(["third", "first", "second"], ends: [6.25, 6.3, 6.0])
        #expect(left.map(\.titles) == [["second"], ["third", "first"]])
        #expect(left[0].time < 6.12)
        #expect(stack.entries.isEmpty)
    }

    /// No card that leaves ever runs into a card that stays, whichever cards go together.
    @Test func cardsLeavingTogetherNeverRunIntoACardThatStays() {
        let titles = ["a", "b", "c", "d", "e"]
        for ends in [[10.0, 10, 10, 10, 10], [13, 10, 10, 10, 13], [10, 10, 13, 13, 13], [13, 13, 13, 10, 10], [10, 13, 10, 13, 10]] {
            let probe = CardStack(settings: StackSettings(max: 6), cards: titles.map { card($0, seconds: 60) })
            run(probe, until: 8)
            let from = probe.live.map(\.countdownFrom)
            let stack = CardStack(
                settings: StackSettings(max: 6), cards: titles.indices.map { card(titles[$0], seconds: ends[$0] - from[$0]) })
            var closest = Double.infinity
            run(stack, until: 16) { time, _ in
                for (index, leaving) in stack.entries.enumerated() where leaving.isLeaving {
                    let above = leaving.animator.shape(at: time)
                    for below in stack.entries[(index + 1)...] where !below.isLeaving {
                        closest = min(closest, below.animator.shape(at: time).pillTop - (above.pillTop + above.pillHeight))
                    }
                }
            }
            #expect(closest > 0, "\(ends)")
            #expect(stack.entries.isEmpty)
        }
    }

    /// A card does not drop in when a card on screen would run out of time before it had settled:
    /// that card would stay, its ring empty, until the new one was in. It leaves on time, and the
    /// new card drops in after it.
    @Test func aCardWaitsToDropInForACardAboutToLeave() throws {
        let probe = CardStack(settings: StackSettings(max: 3), cards: ["a", "b"].map { card($0, seconds: 60) })
        var bEnters = 0.0
        run(probe, until: 4) { time, _ in
            if bEnters == 0, probe.live.count == 2 { bEnters = time }
        }
        let from = probe.live[0].countdownFrom
        // a's time runs out half a second after b could drop in.
        let ends = bEnters + 0.5
        let stack = CardStack(settings: StackSettings(max: 3), cards: [card("a", seconds: ends - from), card("b", seconds: 60)])
        var aLeaves: Double?
        var bComes: Double?
        run(stack, until: 6) { time, changes in
            if changes.left.contains(where: { $0.entry.card.title == "a" }) { aLeaves = aLeaves ?? time }
            if bComes == nil, stack.entries.contains(where: { $0.card.title == "b" }) { bComes = time }
        }
        let left = try #require(aLeaves)
        // On time, within the steps a countdown starts and ends on, not after b has come in and settled.
        #expect(left - ends < 0.12)
        #expect(try #require(bComes) > left)

        // With more time than a card takes to settle, b drops in at once and a still leaves on time.
        let later = bEnters + CardStack.entranceSettling + 0.3
        let roomy = CardStack(settings: StackSettings(max: 3), cards: [card("a", seconds: later - from), card("b", seconds: 60)])
        var leaves: Double?
        var comes: Double?
        run(roomy, until: 6) { time, changes in
            if changes.left.contains(where: { $0.entry.card.title == "a" }) { leaves = leaves ?? time }
            if comes == nil, roomy.entries.contains(where: { $0.card.title == "b" }) { comes = time }
        }
        #expect(abs(try #require(comes) - bEnters) < 0.02)
        #expect(try #require(leaves) - later < 0.12)
    }

    /// A card whose time runs out while the next card is still dropping in leaves as soon as the
    /// stack is at rest, before the card after that drops in, so a burst of arrivals never holds a
    /// card past its time.
    @Test func aCardWhoseTimeIsUpLeavesBeforeTheNextDropsIn() throws {
        let titles = ["a", "b", "c"]
        // When b starts to drop in and when a starts counting down, learned from cards that stay.
        let probe = CardStack(settings: StackSettings(max: 3), cards: titles.map { card($0, seconds: 60) })
        var bEnters = 0.0
        run(probe, until: 4) { time, _ in
            if bEnters == 0, probe.live.count == 2 { bEnters = time }
        }
        let from = probe.live[0].countdownFrom
        // a's time runs out while b is still settling.
        let stack = CardStack(
            settings: StackSettings(max: 3),
            cards: [card("a", seconds: bEnters + 0.1 - from), card("b", seconds: 60), card("c", seconds: 60)])
        var aLeaves: Double?
        var cEnters: Double?
        run(stack, until: 6) { time, changes in
            if changes.left.contains(where: { $0.entry.card.title == "a" }) { aLeaves = aLeaves ?? time }
            if cEnters == nil, stack.entries.contains(where: { $0.card.title == "c" }) { cEnters = time }
        }
        let left = try #require(aLeaves)
        let entered = try #require(cEnters)
        #expect(left < entered)
    }

    @Test func aClickedButtonIsReported() {
        var withButton = card("a", seconds: 10)
        withButton.action = CardAction(label: "Open", open: nil)
        let stack = CardStack(settings: StackSettings(max: 3), cards: [withButton])
        let time = run(stack, until: 2)
        stack.live[0].dismissed = true
        let changes = stack.advance(to: time, elapsed: 0, lead: 0.06)
        #expect(changes.left.count == 1 && changes.left[0].clicked && changes.left[0].time == time + 0.06)
    }

    @Test func nothingMovesWhileThePointerIsOnTheStack() {
        let stack = CardStack(settings: StackSettings(max: 3), cards: [card("a", seconds: 1), card("b")])
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

    /// A pointer left resting on the stack, as one moved there to read what is under a card, holds
    /// it for `holdLimit` at most; moving again holds it again.
    @Test func aRestingPointerLetsTheStackGo() {
        let stack = CardStack(settings: StackSettings(max: 3), cards: [card("a", seconds: 1), card("b")])
        let time = run(stack, until: 0.1)
        #expect(stack.hover(true, moved: true, at: time))
        #expect(!stack.hover(true, moved: false, at: time + CardStack.holdLimit - 0.1))
        run(stack, from: time, until: time + CardStack.holdLimit - 0.1)
        #expect(titles(stack.entries) == ["a"])
        // Rested long enough: the stack lets go, with a moment to read the card.
        #expect(stack.hover(true, moved: false, at: time + CardStack.holdLimit))
        #expect(!stack.hovering)
        #expect(stack.live[0].remaining == 1.5)
        // It moves again: held again.
        #expect(stack.hover(true, moved: true, at: time + CardStack.holdLimit + 1))
        #expect(stack.hovering)
        // Rested again: let go.
        #expect(stack.hover(true, moved: false, at: time + 2 * CardStack.holdLimit + 1))
        #expect(!stack.hovering)
        // The card under the still pointer leaves and the next slides under it: no new hold.
        #expect(!stack.hover(false, moved: false, at: time + 20))
        #expect(!stack.hover(true, moved: false, at: time + 21))
        #expect(!stack.hovering)
        // The pointer leaves and comes back on, which moves it: held again.
        #expect(!stack.hover(false, moved: true, at: time + 22))
        #expect(stack.hover(true, moved: true, at: time + 23))
    }

    /// In a background drip's stack, a card that waits for you and gives way goes back into the
    /// overflow drop with what is left of its wait, and comes back once there is room.
    @Test func aCardThatGivesWayComesBack() {
        let stack = CardStack(
            settings: StackSettings(max: 2),
            cards: [asking("a", seconds: 2), asking("b", seconds: 2), card("c", seconds: 2)])
        stack.tucks = true
        var tucked: [String] = []
        var stopped: [String] = []
        var back = false
        var time = 0.0
        while time < 20 {
            if stack.isReady(at: time) {
                if let next = stack.nextOwn() {
                    stack.enter(next, metrics: metrics, own: true, decided: time, at: time)
                } else if let next = stack.nextTucked() {
                    stack.enter(next.card, metrics: metrics, own: next.own, decided: time, at: time)
                    back = true
                }
            }
            let changes = stack.advance(to: time, elapsed: 1.0 / 60, lead: 0)
            tucked += titles(changes.tucked)
            stopped += titles(changes.stoppedWaiting)
            time += 1.0 / 60
        }
        // a made room for c instead of counting down, then came back once c had gone.
        #expect(tucked == ["a"])
        #expect(stopped.isEmpty)
        #expect(back)
        #expect(Set(titles(stack.live)) == ["a", "b"])
        #expect(stack.live.allSatisfy { $0.isWaiting })
        // Its wait went on from where it was, not from the start.
        let a = stack.live.first { $0.card.title == "a" }
        #expect((a?.card.waitLimit ?? .infinity) < Defaults.waitLimit)
    }

    // MARK: What comes in next

    private func identified(_ title: String, id: String? = nil) -> Card {
        var card = card(title, seconds: 10)
        card.id = id
        return card
    }

    /// A stack of one place whose only card gave way to a newer one and went back into the overflow
    /// drop, with that card gone and the stack at rest: the tucked card waits, and so do `then`, this
    /// drip's own cards not yet in.
    private func stackWithATuckedCard(then own: [Card] = []) -> CardStack {
        let stack = CardStack(
            settings: StackSettings(max: 2),
            cards: [asking("a", seconds: 2), asking("b", seconds: 2), card("c", seconds: 2)] + own)
        stack.tucks = true
        var time = 0.0
        while time < 20 {
            if !stack.tucked.isEmpty, stack.waiting.count == own.count, stack.hasRoom, stack.isReady(at: time) { break }
            if stack.isReady(at: time), let next = stack.nextOwn() {
                stack.enter(next, metrics: metrics, own: true, decided: time, at: time)
            }
            _ = stack.advance(to: time, elapsed: 1.0 / 60, lead: 0)
            time += 1.0 / 60
        }
        return stack
    }

    @Test func aNewerCardWithTheSameIdSwapsIntoThePlaceOnScreenEvenInAFullStack() {
        let stack = CardStack(
            settings: StackSettings(max: 2), cards: [identified("a", id: "build"), identified("b")])
        run(stack, until: 4)
        #expect(!stack.hasRoom)
        guard case let .swap(shown, 0)? = stack.nextAdmission(adoptable: [identified("a2", id: "build")]) else {
            Issue.record("a card with the id of one on screen should swap into it")
            return
        }
        #expect(shown.card.title == "a")
        // A card with no match has no place to go.
        #expect(stack.nextAdmission(adoptable: [identified("other")]) == nil)
    }

    /// A drip that waits for its cards takes no others in, but a newer card with the id of one of its
    /// own on screen still takes that card's place: only its own shown cards with an id qualify.
    @Test func aStackOffersItsOwnShownCardsWithAnIDForANewerCardToReplace() {
        let stack = CardStack(
            settings: StackSettings(max: 3),
            cards: [identified("a", id: "build"), identified("b"), identified("c", id: "test")])
        var time = run(stack, until: 0.05)
        // Still dropping in, so not on screen yet.
        #expect(stack.replaceable.isEmpty)
        time = run(stack, from: time, until: 4)
        #expect(titles(stack.replaceable) == ["a", "c"])
        // Another drip's card it took in is not its own to give up.
        stack.enter(identified("d", id: "lint"), metrics: metrics, own: false, decided: time, at: time)
        time = run(stack, from: time, until: time + 1)
        #expect(titles(stack.replaceable) == ["a", "c"])
        // Swapped, it stays this drip's own, with the newer card's id.
        let entry = stack.replaceable[0]
        stack.swap(entry, for: identified("a2", id: "build"), metrics: metrics, at: time, reduced: false)
        #expect(titles(stack.replaceable) == ["a2", "c"])
        // One that leaves is gone already.
        stack.leave(entry, at: time)
        #expect(titles(stack.replaceable) == ["c"])
    }

    /// A card taken away, as by `drip dismiss`, stays on screen until the stack moves on, then goes.
    /// A newer card with its id never swaps into it only to go with it: it takes a place of its own.
    @Test func aNewerCardWithTheSameIdNeverSwapsIntoACardTakenAway() {
        let stack = CardStack(
            settings: StackSettings(max: 3), cards: [identified("a", id: "build"), identified("b")])
        run(stack, until: 4)
        let newer = identified("a2", id: "build")
        #expect(titles(stack.replaceable) == ["a"])
        #expect(stack.swapsInPlace(newer))
        let entry = stack.replaceable[0]
        entry.dismissed = false
        #expect(entry.isShown)
        #expect(stack.replaceable.isEmpty)
        #expect(stack.swapTarget(for: newer) == nil)
        #expect(!stack.swapsInPlace(newer))
        guard case .enter(0)? = stack.nextAdmission(adoptable: [newer]) else {
            Issue.record("a newer card whose match was taken away should come in as a card of its own")
            return
        }
    }

    @Test func aCardThatAsksAQuestionNeverSwapsIntoPlace() {
        var question = card("a", seconds: 10)
        question.id = "build"
        question.action = CardAction(label: "Merge", open: nil)
        let stack = CardStack(settings: StackSettings(max: 3), cards: [question])
        run(stack, until: 4)
        guard case .enter(0)? = stack.nextAdmission(adoptable: [identified("a2", id: "build")]) else {
            Issue.record("a question reports its click to the drip that showed it, so the newer card waits for its own place")
            return
        }
    }

    @Test func aNewerDripsCardTakesAFreePlaceOnlyWhenNoOwnCardWaits() {
        let free = CardStack(settings: StackSettings(max: 3))
        guard case .enter(0)? = free.nextAdmission(adoptable: [card("other")]) else {
            Issue.record("the adopted card drops in")
            return
        }
        let waiting = CardStack(settings: StackSettings(max: 3), cards: [card("own")])
        guard case .own? = waiting.nextAdmission(adoptable: [card("other")]) else {
            Issue.record("this drip's own card goes first, so a newer drip's never jumps the queue")
            return
        }
    }

    @Test func noNewerCardJumpsAnOwnCardThatWaitsPastAFullStack() {
        let stack = CardStack(settings: StackSettings(max: 1), cards: [card("a", seconds: 10), card("b")])
        run(stack, until: 4)
        #expect(stack.waiting.count == 1)
        #expect(stack.nextAdmission(adoptable: [card("other")]) == nil)
    }

    @Test func anOwnCardComesBeforeACardThatGaveWay() {
        let stack = stackWithATuckedCard(then: [card("own")])
        guard case .own? = stack.nextRelease(adoptable: []) else {
            Issue.record("an own card grows out of the drop first")
            return
        }
    }

    @Test func aCardThatGaveWayComesBackOnlyAfterEveryNewerCardOffered() {
        let stack = stackWithATuckedCard()
        guard case .enter(0)? = stack.nextRelease(adoptable: [card("other")]) else {
            Issue.record("a newer card goes before one that gave way")
            return
        }
        guard case .tucked? = stack.nextRelease(adoptable: []) else {
            Issue.record("the card that gave way comes back into free room")
            return
        }
    }

    @Test func aReplacedOwnCardIsDroppedBeforeACardThatGaveWayComesBack() {
        let stack = stackWithATuckedCard(then: [card("old")])
        // The card that gave way must not slip in ahead of the drop's count going down.
        guard case .skipOwn? = stack.nextRelease(adoptable: [], isReplaced: { $0.title == "old" }) else {
            Issue.record("a replaced own card is skipped, not shown")
            return
        }
        stack.dropWaiting(at: 0)
        guard case .tucked? = stack.nextRelease(adoptable: [], isReplaced: { $0.title == "old" }) else {
            Issue.record("the card that gave way comes back once the replaced one is gone")
            return
        }
    }

    @Test func releaseTakesOwnFirstThenACardNotSwappingInPlace() {
        let own = CardStack(settings: StackSettings(max: 3), cards: [card("own")])
        guard case .own? = own.nextRelease(adoptable: [card("other")]) else {
            Issue.record("own first")
            return
        }

        let stack = CardStack(settings: StackSettings(max: 3), cards: [identified("a", id: "build")])
        run(stack, until: 4)
        // "a2" shows in place of "a" and so does not grow out of the drop; "b" does.
        guard case .enter(1)? = stack.nextRelease(adoptable: [identified("a2", id: "build"), identified("b")]) else {
            Issue.record("a card that swaps in place does not grow out of the drop")
            return
        }
        #expect(stack.nextRelease(adoptable: [identified("a2", id: "build")]) == nil)
    }

    @Test func releaseSkipsAReplacedOwnCardInsteadOfShowingIt() {
        let stack = CardStack(settings: StackSettings(max: 3), cards: [card("old")])
        guard case .skipOwn? = stack.nextRelease(adoptable: [card("other")], isReplaced: { $0.title == "old" }) else {
            Issue.record("the replaced card is dropped, not shown or passed over for a newer drip's")
            return
        }
    }

    @Test func aCardThatGaveWayCanBeForgotten() {
        let stack = CardStack(settings: StackSettings(max: 1), cards: [asking("a"), card("c", seconds: 2)])
        stack.tucks = true
        var time = 0.0
        var gaveWay: [Int] = []
        while time < 3, stack.tucked.isEmpty {
            if stack.isReady(at: time), let next = stack.nextOwn() {
                stack.enter(next, metrics: metrics, own: true, decided: time, at: time)
            }
            gaveWay += stack.advance(to: time, elapsed: 1.0 / 60, lead: 0).tucked.map(\.id)
            time += 1.0 / 60
        }
        #expect(stack.tucked.map(\.card.title) == ["a"])
        #expect(stack.tucked.map(\.entry) == gaveWay)
        #expect(!stack.dropTucked { $0.title == "x" })
        #expect(stack.dropTucked { $0.title == "a" })
        #expect(stack.tucked.isEmpty)
    }

    @Test func theCloseMarkIsTheCardsLeftEnd() throws {
        let stack = CardStack(settings: StackSettings(max: 3), cards: [card("a", seconds: 10)])
        let time = run(stack, until: 3)
        let entry = try #require(stack.live.first)
        let shape = entry.animator.shape(at: time)
        let layout = entry.animator.content(for: shape)
        let middle = shape.pillTop + shape.pillHeight / 2
        #expect(stack.isOnClose(of: entry, at: IslandPoint(-shape.pillWidth / 2 + 2, middle), time: time))
        #expect(stack.isOnClose(of: entry, at: IslandPoint(layout.iconCenter.x, middle), time: time))
        #expect(!stack.isOnClose(of: entry, at: IslandPoint(layout.iconCenter.x + layout.iconSize, middle), time: time))
        #expect(!stack.isOnClose(of: entry, at: IslandPoint(layout.iconCenter.x, shape.pillTop + shape.pillHeight + 10), time: time))
        // Without an icon there is no ×.
        let bare = CardStack(settings: StackSettings(max: 3))
        let noIcon = IslandMetrics(notchWidth: 185, notchHeight: 32, textWidth: 180, textHeight: 34, hasIcon: false)
        let other = bare.enter(card("b"), metrics: noIcon, own: true, decided: 0, at: 0)
        let end = run(bare, until: 3)
        let otherShape = other.animator.shape(at: end)
        #expect(!bare.isOnClose(of: other, at: IslandPoint(-otherShape.pillWidth / 2 + 2, otherShape.pillTop + 5), time: end))
    }

    @Test func theOutlineMeltsEachDropIntoWhatItGrowsOutOf() {
        let stack = CardStack(settings: StackSettings(max: 3), cards: [card("a", seconds: 10)])
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

    /// `--activate none` promises a card you can click through. The stack held every card while the
    /// pointer was on any of them, and a click took the card away, so the default stack ate the click.
    @Test func aCardWithNothingToClickIsNotUnderThePointer() {
        var clickable = card("a", seconds: 10)
        clickable.activate = "com.apple.finder"
        var plain = card("b", seconds: 10)
        plain.activate = nil
        #expect(clickable.isClickable && !plain.isClickable)
        let stack = CardStack(settings: StackSettings(max: 3), cards: [clickable, plain])
        let time = run(stack, until: 4)
        let (a, b) = (stack.live[0], stack.live[1])
        let middle = { (entry: CardStack.Entry) in
            let shape = entry.animator.shape(at: time)
            return IslandPoint(0, shape.pillTop + shape.pillHeight / 2)
        }
        #expect(stack.entry(at: middle(b), time: time) === b)
        #expect(stack.clickableEntry(at: middle(a), time: time) === a)
        #expect(stack.clickableEntry(at: middle(b), time: time) == nil)
    }

    /// The window over the notch is wider and taller than its cards. It took every click in it while
    /// any card took clicks, so the windows of other apps beside a card, at its height, or under it,
    /// could not be clicked while it showed. Only the capsules take the pointer now.
    @Test func onlyTheCapsulesTakeThePointer() {
        let cards = ["a", "b"].map { title in
            var clickable = card(title, seconds: 10)
            clickable.activate = "com.apple.finder"
            return clickable
        }
        let stack = CardStack(settings: StackSettings(max: 3), cards: cards)
        let time = run(stack, until: 4)
        let (a, b) = (stack.live[0], stack.live[1])
        #expect(a.card.isClickable && b.card.isClickable)
        let shapeA = a.animator.shape(at: time), shapeB = b.animator.shape(at: time)
        let middleA = shapeA.pillTop + shapeA.pillHeight / 2
        #expect(stack.clickableEntry(at: IslandPoint(0, middleA), time: time) === a)
        #expect(stack.clickableEntry(at: IslandPoint(shapeA.pillWidth / 2 - 1, middleA), time: time) === a)
        // Beside the card, at its height: on either side, just past it and far from it.
        for x in [shapeA.pillWidth / 2 + 3, shapeA.pillWidth / 2 + 30, -shapeA.pillWidth / 2 - 30] {
            #expect(stack.clickableEntry(at: IslandPoint(x, middleA), time: time) == nil)
        }
        // Under the last card, and between two.
        #expect(stack.clickableEntry(at: IslandPoint(0, shapeB.pillTop + shapeB.pillHeight + 10), time: time) == nil)
        let gap = (shapeA.pillTop + shapeA.pillHeight + shapeB.pillTop) / 2
        if shapeB.pillTop - (shapeA.pillTop + shapeA.pillHeight) > 6 {
            #expect(stack.clickableEntry(at: IslandPoint(0, gap), time: time) == nil)
        }
        // Just outside a round end's corner, inside the capsule's bounding box.
        let radius = shapeA.pillRadius(a.metrics)
        let corner = IslandPoint(shapeA.pillWidth / 2 - radius * 0.1, shapeA.pillTop + radius * 0.1)
        #expect(stack.clickableEntry(at: corner, time: time) == nil)
    }

    @Test func thePointerFindsTheCardAndItsButton() {
        var withButton = card("a", seconds: 10)
        withButton.action = CardAction(label: "Open", open: nil)
        let stack = CardStack(settings: StackSettings(max: 3), cards: [withButton, card("b", seconds: 10)])
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
        #expect(stack.button(of: a, at: ring, time: time) != nil)
        #expect(stack.button(of: a, at: middle(a), time: time) == nil)
        #expect(stack.button(of: b, at: b.animator.content(for: b.animator.shape(at: time)).ringCenter, time: time) == nil)
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
        let stack = CardStack(settings: StackSettings(max: 3))
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
