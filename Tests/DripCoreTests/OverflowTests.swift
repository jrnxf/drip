import DripCore
import Testing

/// The overflow drop under a full stack, which counts the cards waiting for room.
struct OverflowTests {
    private let metrics = IslandMetrics(notchWidth: 185, notchHeight: 32, textWidth: 180, textHeight: 34)

    private func card(_ title: String, seconds: Double = 3, id: String? = nil) -> Card {
        var card = Card(preset: .info, title: title)
        card.seconds = seconds
        card.id = id
        return card
    }

    /// Runs a stack as the Mac app and the web page run one, 60 steps a second: with the stack at
    /// rest, another drip's card swaps into its card on screen, and with no overflow drop a card drops
    /// in; whenever it can, the next card grows out of the overflow drop. `others` are other drips'
    /// cards waiting for the stack.
    private final class Driver {
        let stack: CardStack
        let metrics: IslandMetrics
        var others: [Card] = []
        var time = 0.0
        /// Each card grown out of the drop, with when it starts to spread, where it settles, and the
        /// cards on screen right after.
        var releases: [(time: Double, release: CardStack.Release, start: Double, top: Double, live: [String])] = []
        var swaps: [(time: Double, title: String)] = []

        init(_ stack: CardStack, metrics: IslandMetrics) {
            self.stack = stack
            self.metrics = metrics
        }

        func run(for seconds: Double, metrics cardMetrics: ((Card) -> IslandMetrics)? = nil, step: (Double, CardStack.Changes) -> Void = { _, _ in }) {
            let layout = cardMetrics ?? { _ in self.metrics }
            let until = time + seconds
            while time < until {
                if stack.isReady(at: time) {
                    if let index = others.firstIndex(where: stack.swapsInPlace),
                       let shown = stack.live.first(where: { $0.card.id == others[index].id })
                    {
                        let card = others.remove(at: index)
                        stack.swap(shown, for: card, metrics: layout(card), at: time, reduced: false)
                        swaps.append((time, card.title))
                    } else if stack.overflow == nil, stack.hasRoom {
                        if let card = stack.nextOwn() {
                            stack.enter(card, metrics: layout(card), own: true, decided: time, at: time)
                        } else if let index = others.firstIndex(where: { !stack.swapsInPlace($0) }) {
                            let card = others.remove(at: index)
                            stack.enter(card, metrics: layout(card), own: false, decided: time, at: time)
                        }
                    }
                }
                if stack.canRelease(at: time) {
                    var next = stack.nextOwn()
                    var own = true
                    if next == nil, let index = others.firstIndex(where: { !stack.swapsInPlace($0) }) {
                        next = others.remove(at: index)
                        own = false
                    }
                    if let next, let release = stack.release(next, metrics: layout(next), own: own, at: time) {
                        var start = time
                        if case let .entering(begin, _) = release.entry.phase { start = begin }
                        releases.append((time, release, start, release.entry.animator.targetTop, stack.live.map(\.card.title)))
                    }
                }
                let changes = stack.advance(to: time, elapsed: 1.0 / 60, lead: 0, queued: others)
                step(time, changes)
                time += 1.0 / 60
            }
        }
    }

    private func stack(_ titles: [String], max: Int = 3, seconds: Double = 4, mode: StackSettings.Mode = .chain) -> Driver {
        Driver(
            CardStack(settings: StackSettings(mode: mode, max: max), cards: titles.map { card($0, seconds: seconds) }),
            metrics: metrics)
    }

    private func slot(_ index: Int) -> Double {
        metrics.pillTop + Double(index) * (metrics.pillHeight + CardStack.gap)
    }

    @Test func aFullStackDripsADropThatCountsTheCardsWaiting() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 6)
        var formedAt: Double?
        var lastSettled = 0.0
        driver.run(for: 4) { time, _ in
            if formedAt == nil, driver.stack.overflow != nil { formedAt = time }
            if formedAt == nil { lastSettled = driver.stack.live.last?.animator.end ?? 0 }
        }
        let overflow = try #require(driver.stack.overflow)
        #expect(overflow.count == 2)
        #expect(driver.stack.live.map(\.card.title) == ["a", "b", "c"])
        // Out of the last card once it is at rest, into the place a fourth card would take.
        #expect(try #require(formedAt) >= lastSettled)
        #expect(overflow.anchor === driver.stack.live.last)
        #expect(abs(overflow.animator.targetTop - slot(3)) < 0.01)
        #expect(overflow.animator.metrics.pillWidth == metrics.dropSize)
        #expect(overflow.phase == .shown)
        #expect(overflow.titles == ["e", "d"])
        #expect(overflow.peekText == "e · d")
    }

    @Test func noDropWithoutTheCardsWaitingOrWithRoom() {
        // A stack that is not given the cards waiting never shows one.
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 1), cards: ["a", "b"].map { card($0) })
        var time = 0.0
        while time < 3 {
            if stack.isReady(at: time), let next = stack.nextOwn() {
                stack.enter(next, metrics: metrics, own: true, decided: time, at: time)
            }
            _ = stack.advance(to: time, elapsed: 1.0 / 60, lead: 0)
            time += 1.0 / 60
        }
        #expect(stack.overflow == nil)

        // Nor does a stack with room.
        let roomy = self.stack(["a", "b"])
        roomy.run(for: 3)
        #expect(roomy.stack.overflow == nil)
    }

    /// Once it appears at the place a card more would take, the drop never moves up or down until it
    /// goes, through cards dripping in, the count ticking and cards growing out of it.
    @Test func theDropNeverMoves() {
        let driver = stack(["a", "b", "c", "d", "e", "f"], seconds: 3)
        var tops: Set<Double> = []
        var showed = false
        driver.run(for: 3) { _, _ in }
        driver.others = [card("late")]
        driver.run(for: 12) { _, _ in
            guard let overflow = driver.stack.overflow, !overflow.isLeaving else { return }
            showed = true
            tops.insert((overflow.animator.targetTop * 100).rounded() / 100)
        }
        #expect(showed)
        #expect(tops == [(slot(3) * 100).rounded() / 100])
        #expect(driver.releases.count >= 3)
    }

    /// The count ticks down the moment a card starts to leave, and the next card grows out of the
    /// drop as the leaving card's drop starts to rise and the cards below close up: one motion.
    @Test func theNextCardGrowsOutAsTheLeavingCardGoes() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 3)
        var leftAt: Double?
        var leaving: CardStack.Entry?
        driver.run(for: 10) { time, changes in
            if leftAt == nil, let left = changes.left.first {
                leftAt = time
                leaving = left.entry
            }
        }
        let first = try #require(driver.releases.first)
        #expect(first.release.count == 2)
        #expect(!first.release.last)
        #expect(first.release.entry.card.title == "d")
        // Released in the step the card started to leave, not once the stack had come to rest.
        #expect(abs(first.time - (try #require(leftAt))) < 0.02)
        #expect(abs(first.start - (try #require(leaving?.animator.riseTime))) < 0.001)
        // Into the place the leaving card frees, at the bottom of the cards that stay.
        #expect(abs(first.top - slot(2)) < 0.01)
        // It grows out of the drop, where the drop is.
        #expect(abs(first.release.entry.animator.shape(at: first.time).pillTop - slot(3)) < 1)
    }

    @Test func theLastCardWaitingIsTheDropItself() throws {
        let driver = stack(["a", "b", "c", "d"], seconds: 3)
        driver.run(for: 3)
        let drop = try #require(driver.stack.overflow)
        #expect(drop.count == 1)
        driver.run(for: 4)
        let release = try #require(driver.releases.first?.release)
        #expect(release.last)
        #expect(release.count == 1)
        #expect(driver.stack.overflow == nil)
        // The drop's own springs carry on into the card.
        #expect(release.entry.animator.shape(at: driver.releases[0].time).pillWidth < metrics.dropSize + 4)
        #expect(abs(driver.releases[0].top - slot(2)) < 0.01)
        #expect(driver.releases[0].live == ["b", "c", "d"])
    }

    /// A card that comes while the drop shows drips into it from the last card: the count goes up as
    /// it merges, not when it is queued.
    @Test func aCardThatComesDripsIntoTheDrop() throws {
        let driver = stack(["a", "b", "c", "d"], seconds: 8)
        driver.run(for: 3)
        #expect(driver.stack.overflow?.count == 1)
        driver.others = [card("late")]
        var counts: [Int] = []
        var seeded: Double?
        var traced = false
        driver.run(for: 1.5) { time, _ in
            guard let overflow = driver.stack.overflow else { return }
            if seeded == nil, !overflow.seeds.isEmpty { seeded = time }
            if counts.last != overflow.count { counts.append(overflow.count) }
            // The seed is melted into the card it leaves, then into the drop.
            if driver.stack.outline.overflowPieces(at: time).dropFirst().contains(where: {
                if case .traced = $0 { return true }
                return false
            }) { traced = true }
        }
        #expect(seeded != nil)
        #expect(counts == [1, 2])
        #expect(traced)
        #expect(driver.stack.overflow?.seeds.isEmpty == true)
        #expect(driver.stack.overflow?.titles == ["late", "d"])
    }

    /// An --id update queued for a card on screen counts until it swaps in place; a drop never forms
    /// for updates alone, and with nothing left waiting it goes back into the last card.
    @Test func anUpdateForACardOnScreenCountsUntilItSwaps() throws {
        let stack = CardStack(
            settings: StackSettings(mode: .chain, max: 2),
            cards: [card("deploying", seconds: 30, id: "deploy"), card("b", seconds: 30), card("c", seconds: 30)])
        let driver = Driver(stack, metrics: metrics)
        driver.run(for: 3)
        let drop = try #require(stack.overflow)
        #expect(drop.count == 1)

        // Only an update waits: no drop of its own.
        let updates = CardStack(
            settings: StackSettings(mode: .chain, max: 1), cards: [card("deploying", seconds: 30, id: "deploy")])
        let only = Driver(updates, metrics: metrics)
        only.run(for: 2)
        only.others = [card("deployed", id: "deploy")]
        var formed = false
        only.run(for: 2) { _, _ in formed = formed || updates.overflow != nil }
        #expect(!formed)
        #expect(only.swaps.map(\.title) == ["deployed"])

        // The update counts, then swaps in place and the count goes back down. The pointer holds the
        // swap until the update has dripped in.
        stack.hover(true)
        driver.others = [card("deployed", seconds: 30, id: "deploy")]
        var counts: [Int] = []
        var gone = false
        driver.run(for: 1.5) { _, _ in
            if let count = stack.overflow?.count, counts.last != count { counts.append(count) }
        }
        #expect(driver.swaps.isEmpty)
        stack.hover(false)
        driver.run(for: 3) { _, _ in
            if let count = stack.overflow?.count, counts.last != count { counts.append(count) }
            if stack.overflow == nil { gone = true }
        }
        #expect(driver.swaps.map(\.title) == ["deployed"])
        #expect(counts.first == 1)
        #expect(counts.max() == 2)
        #expect(counts.last == 1)
        #expect(!gone)
    }

    @Test func anEmptiedDropGoesBackIntoTheLastCard() throws {
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 1), cards: [card("a", seconds: 30)])
        let driver = Driver(stack, metrics: metrics)
        driver.run(for: 2)
        driver.others = [card("b")]
        driver.run(for: 2)
        let drop = try #require(stack.overflow)
        #expect(drop.count == 1)
        // Its drip went: nothing waits any more.
        driver.others = []
        var left: Double?
        var gone: Double?
        var fillingKept = true
        driver.run(for: 2) { time, _ in
            if left == nil, drop.isLeaving { left = time }
            if gone == nil, stack.overflow == nil { gone = time }
            if left != nil, gone == nil, stack.live.isEmpty { fillingKept = false }
        }
        #expect(drop.count == 0)
        #expect(drop.anchor === stack.live.last)
        #expect(try #require(gone) > (try #require(left)))
        #expect(fillingKept)
    }

    /// While the pointer is on the stack, cards keep dripping in so the count stays true, but none
    /// grows out.
    @Test func hoveringHoldsTheReleaseButNotTheCount() throws {
        let driver = stack(["a", "b", "c", "d"], seconds: 3)
        driver.run(for: 3)
        driver.stack.hover(true)
        driver.others = [card("late")]
        driver.run(for: 6)
        #expect(driver.releases.isEmpty)
        #expect(driver.stack.overflow?.count == 2)
        #expect(driver.stack.live.count == 3)
        driver.stack.hover(false)
        driver.run(for: 4)
        #expect(driver.releases.count >= 1)
    }

    /// With the pointer on it, the drop springs wide to list the waiting titles, newest first, and
    /// back to its count after; nothing grows out of it meanwhile.
    @Test func theDropPeeksAtTheTitlesWaiting() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 6)
        driver.run(for: 4)
        let drop = try #require(driver.stack.overflow)
        #expect(drop.phase == .shown)
        let time = driver.time
        #expect(driver.stack.isOnOverflow(IslandPoint(0, slot(3) + metrics.dropSize / 2), time: time))
        #expect(!driver.stack.isOnOverflow(IslandPoint(60, slot(3) + metrics.dropSize / 2), time: time))
        #expect(driver.stack.peek(width: 40, at: time))
        #expect(!driver.stack.peek(width: 40, at: time))
        #expect(drop.peeking)
        #expect(drop.animator.metrics.pillWidth == 66)
        // Never wider than 340 points.
        driver.stack.peek(width: 1000, at: time)
        #expect(drop.animator.metrics.pillWidth == 340)
        driver.stack.hover(true)
        driver.run(for: 3)
        #expect(driver.releases.isEmpty)
        #expect(abs(drop.animator.shape(at: driver.time).pillWidth - 340) < 0.5)
        driver.stack.hover(false)
        #expect(driver.stack.peek(width: nil, at: driver.time))
        #expect(!drop.peeking)
        #expect(drop.animator.metrics.pillWidth == metrics.dropSize)
        driver.run(for: 4)
        #expect(!driver.releases.isEmpty)
    }

    /// A count too wide for the round drop widens it.
    @Test func aWideCountWidensTheDrop() throws {
        let titles = (0..<14).map { "card \($0)" }
        let driver = stack(titles, max: 2, seconds: 30)
        driver.stack.measureCount = { Double($0.count) * 8 }
        driver.run(for: 3)
        let drop = try #require(driver.stack.overflow)
        #expect(drop.count == 12)
        #expect(drop.metrics.pillWidth == 30)
    }

    @Test func aStackOfOneDripsTheDropUnderItsCard() throws {
        let driver = stack(["a", "b", "c"], max: 1, seconds: 3)
        driver.run(for: 2.5)
        let drop = try #require(driver.stack.overflow)
        #expect(drop.count == 2)
        #expect(abs(drop.animator.targetTop - slot(1)) < 0.01)
        driver.run(for: 12)
        #expect(driver.releases.map(\.release.entry.card.title) == ["b", "c"])
        #expect(driver.releases.map(\.release.last) == [false, true])
        // Each grows up into the only place, under the notch.
        #expect(driver.releases.allSatisfy { abs($0.top - slot(0)) < 0.01 })
    }

    /// In push mode the drop hangs under the last card too, and the next card drops from the notch.
    @Test func pushModeDripsTheDropUnderTheLastCard() throws {
        let driver = stack(["a", "b", "c", "d"], seconds: 3, mode: .push)
        driver.run(for: 3)
        let drop = try #require(driver.stack.overflow)
        #expect(abs(drop.animator.targetTop - slot(3)) < 0.01)
        driver.run(for: 6)
        let release = try #require(driver.releases.first)
        #expect(!release.release.last)
        #expect(release.release.entry.anchor == nil)
        #expect(release.live.first == "d")
    }

    /// The card summing up what came while the screen was locked counts as one.
    @Test func theMissedSummaryCountsAsOne() throws {
        let held = ["x", "y", "z"].map { card($0) }
        let summary = try #require(MissedSummary.cards(for: held).first)
        let stack = CardStack(settings: StackSettings(mode: .chain, max: 1), cards: [card("a", seconds: 30), summary])
        let driver = Driver(stack, metrics: metrics)
        driver.run(for: 3)
        #expect(stack.overflow?.count == 1)
        #expect(stack.overflow?.titles == ["3 cards while you were away"])
    }

    /// A taller card under the drop's place pushes it down, never up, and only as far as it needs.
    @Test func aTallerCardPushesTheDropDownOnly() throws {
        let tall = IslandMetrics(notchWidth: 185, notchHeight: 32, textWidth: 180, textHeight: 80, titleLines: 2, detailLines: 2)
        let driver = stack(["a", "b", "c", "tall", "e"], seconds: 3)
        driver.run(for: 3)
        let drop = try #require(driver.stack.overflow)
        let top = drop.animator.targetTop
        var tops: [Double] = []
        driver.run(for: 6, metrics: { $0.title == "tall" ? tall : self.metrics }) { _, _ in
            guard driver.stack.overflow === drop, !drop.isLeaving else { return }
            if tops.last != drop.animator.targetTop { tops.append(drop.animator.targetTop) }
        }
        // Once, as the tall card grew out of it into the third place, and no further.
        #expect(tops.count == 2)
        #expect(tops.first == top)
        #expect(tops.last.map { abs($0 - (slot(2) + tall.pillHeight + CardStack.gap)) < 0.01 } == true)
    }

    // MARK: Motion

    @Test func aCardSpreadsOutOfTheDropWhereTheDropIs() {
        let drop = IslandShape(pillTop: 200, pillWidth: 26, pillHeight: 26, progress: 1)
        var animator = IslandAnimator(metrics: metrics, from: drop)
        #expect(animator.shape(at: 0).pillTop == 200)
        #expect(animator.shape(at: 0).pillWidth == 26)
        let cues = animator.spread(into: metrics, top: 100, at: 1)
        #expect(cues.sides > 0 && cues.sides < 0.5)
        #expect(cues.title.first == cues.sides)
        let open = animator.shape(at: 4)
        #expect(abs(open.pillTop - 100) < 0.01)
        #expect(abs(open.pillWidth - metrics.pillWidth) < 0.01)
        #expect(abs(open.progress - 1) < 0.001)
    }

    @Test func theDropSwellsAndSettlesBack() {
        let round = IslandMetrics(
            notchWidth: 185, notchHeight: 32, textWidth: 0, textHeight: 0, titleLines: 0, detailLines: 0,
            hasIcon: false, fixedPill: IslandMetrics.PillSize(width: 26, height: 26))
        #expect(round.pillWidth == 26 && round.pillHeight == 26)
        #expect(round.pillCornerRadius == .infinity)
        var animator = IslandAnimator(metrics: round)
        animator.open(top: 200)
        animator.swell(by: 3, at: 0)
        let widest = stride(from: 0.0, through: 1, by: 0.01).map { animator.shape(at: $0).pillWidth }.max() ?? 0
        #expect(widest > 27)
        #expect(abs(animator.shape(at: 3).pillWidth - 26) < 0.01)
        #expect(abs(animator.shape(at: 3).pillTop + 13 - (200 + 13)) < 0.01)
    }
}
