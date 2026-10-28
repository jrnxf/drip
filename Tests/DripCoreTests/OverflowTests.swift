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

    /// Runs a stack as the Mac app runs one, 60 steps a second: with the stack at rest, another
    /// drip's card swaps into its card on screen, and with no overflow drop a card drops in; whenever
    /// it can, the next card grows out of the overflow drop, and in the same step a card leaves when
    /// that makes room for it. `others` are other drips'
    /// cards waiting for the stack, and `replaced` this drip's own a newer card with the same id
    /// replaced, which never show.
    private final class Driver {
        let stack: CardStack
        let metrics: IslandMetrics
        var others: [Card] = []
        var replaced: [Card] = []
        var time = 0.0
        /// Each card grown out of the drop, with when it starts to spread, where it settles, and the
        /// cards on screen right after.
        var releases: [(time: Double, release: CardStack.Release, start: Double, top: Double, live: [String])] = []
        var swaps: [(time: Double, title: String)] = []

        init(_ stack: CardStack, metrics: IslandMetrics) {
            self.stack = stack
            self.metrics = metrics
        }

        /// Grows the next card waiting out of the overflow drop, when it can: this drip's own first.
        private func release(_ layout: (Card) -> IslandMetrics) {
            guard stack.canRelease(at: time) else { return }
            var next = stack.nextOwn()
            var own = true
            if let card = next, replaced.contains(card) { next = nil }
            if next == nil, let index = others.firstIndex(where: { !stack.swapsInPlace($0) }) {
                next = others.remove(at: index)
                own = false
            }
            guard let next, let release = stack.release(next, metrics: layout(next), own: own, at: time) else { return }
            var start = time
            if case let .entering(begin, _) = release.entry.phase { start = begin }
            releases.append((time, release, start, release.entry.animator.targetTop, stack.live.map(\.card.title)))
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
                release(layout)
                let changes = stack.advance(to: time, elapsed: 1.0 / 60, lead: 0, queued: others, replaced: replaced)
                if !changes.left.isEmpty { release(layout) }
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
        driver.run(for: 4, step: { time, _ in
            if formedAt == nil, driver.stack.overflow != nil { formedAt = time }
            if formedAt == nil { lastSettled = driver.stack.live.last?.animator.end ?? 0 }
        })
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

    /// One of this drip's own cards still to come, replaced by a newer drip's card with the same id,
    /// stops counting as the newer card starts: the count stays as it was.
    @Test func aReplacedOwnCardIsNotCounted() throws {
        let replacedCard = card("e", id: "x")
        let driver = Driver(
            CardStack(
                settings: StackSettings(mode: .chain, max: 3),
                cards: [card("a", seconds: 6), card("b", seconds: 6), card("c", seconds: 6), card("d"), replacedCard]),
            metrics: metrics)
        driver.run(for: 3)
        #expect(try #require(driver.stack.overflow).count == 2)
        driver.others = [card("e2", id: "x")]
        driver.replaced = [replacedCard]
        var counts: Set<Int> = []
        driver.run(for: 1, step: { _, _ in
            if let overflow = driver.stack.overflow { counts.insert(overflow.count) }
        })
        #expect(counts == [2])
        #expect(try #require(driver.stack.overflow).titles == ["e2", "d"])
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
        driver.run(for: 3, step: { _, _ in })
        driver.others = [card("late")]
        driver.run(for: 12, step: { _, _ in
            guard let overflow = driver.stack.overflow, !overflow.isLeaving else { return }
            showed = true
            tops.insert((overflow.animator.targetTop * 100).rounded() / 100)
        })
        #expect(showed)
        #expect(tops == [(slot(3) * 100).rounded() / 100])
        #expect(driver.releases.count >= 3)
    }

    /// The moment a card starts to leave, the count rolls down, the next card starts to grow out of
    /// the drop and the cards below start to close up, all on `CardStack.handOver`: one motion. The
    /// leaving card rises at once, so the cards below never run into it.
    @Test func theNextCardGrowsOutAsTheLeavingCardGoes() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 3)
        var leftAt: Double?
        var leaving: CardStack.Entry?
        var below: CardStack.Entry?
        var count: (Int, Double, Bool)?
        var overflow: CardStack.Overflow?
        var closest = Double.infinity
        driver.run(for: 10, step: { time, changes in
            if leftAt == nil, let left = changes.left.first {
                leftAt = time
                leaving = left.entry
                below = driver.stack.live.first
                overflow = driver.stack.overflow
                count = overflow.map { ($0.count, $0.changedAt, $0.handedOver) }
            }
            guard let leaving, let below, leaving.isLeaving, driver.stack.entries.contains(where: { $0 === leaving })
            else { return }
            let above = leaving.animator.shape(at: time)
            closest = min(closest, below.animator.shape(at: time).pillTop - (above.pillTop + above.pillHeight))
        })
        let first = try #require(driver.releases.first)
        let left = try #require(leftAt)
        #expect(first.release.count == 2)
        #expect(!first.release.last)
        #expect(first.release.entry.card.title == "d")
        // In the very step the card started to leave, and growing from that moment.
        #expect(first.time == left)
        #expect(first.start == left)
        #expect(try #require(leaving?.exit?.time) == left)
        // It rises as it gathers, rather than once it is round, and the cards below follow it up at
        // once without ever touching it.
        #expect(try #require(leaving?.animator.riseTime) - left < 0.05)
        #expect(try #require(below?.animator.shape(at: left + 0.1)).pillTop < slot(1) - 1)
        #expect(closest > 0)
        // The count rolls with it, from the same moment, with no swell of the drop.
        let drop = try #require(overflow)
        let (shown, changedAt, handedOver) = try #require(count)
        #expect(shown == 1)
        #expect(changedAt == left)
        #expect(handedOver)
        #expect(stride(from: left, through: left + 0.6, by: 0.01).allSatisfy {
            abs(drop.animator.shape(at: $0).pillWidth - metrics.dropSize) < 0.5
        })
        // Into the place the leaving card frees, at the bottom of the cards that stay.
        #expect(abs(first.top - slot(2)) < 0.01)
        // It grows out of the drop, where the drop is.
        #expect(abs(first.release.entry.animator.shape(at: first.time).pillTop - slot(3)) < 1)
    }

    /// A card clicked away under the pointer gathers in place, as it does without a drop: let go a
    /// moment later, the next card waits to grow out until that card's drop starts to rise, and the
    /// cards below never run into it.
    @Test func aCardStillGatheringHoldsItsPlaceAsTheNextGrowsOut() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 6)
        driver.run(for: 4)
        #expect(driver.stack.overflow?.phase == .shown)
        let leaving = driver.stack.live[0]
        let below = driver.stack.live[1]
        driver.stack.hover(true, at: driver.time)
        leaving.dismissed = true
        var leftAt: Double?
        var closest = Double.infinity
        driver.run(for: 3, step: { time, changes in
            if leftAt == nil, changes.left.contains(where: { $0.entry === leaving }) {
                leftAt = time
                driver.stack.hover(false, at: time)
            }
            guard leftAt != nil, driver.stack.entries.contains(where: { $0 === leaving }) else { return }
            let above = leaving.animator.shape(at: time)
            closest = min(closest, below.animator.shape(at: time).pillTop - (above.pillTop + above.pillHeight))
        })
        let left = try #require(leftAt)
        let rise = try #require(leaving.animator.riseTime)
        let first = try #require(driver.releases.first)
        #expect(rise - left > 0.1)
        #expect(first.time > left)
        #expect(first.start >= rise - 0.001)
        #expect(abs(below.animator.shape(at: rise - 0.02).pillTop - slot(1)) < 0.01)
        #expect(closest > 0)
        #expect(abs(first.top - slot(2)) < 0.01)
    }

    /// The smallest gap, over `seconds` of `driver`, between each card leaving and every card below
    /// it in the stack that stays, while both are there; `step` runs first at each step.
    private func closestGap(_ driver: Driver, for seconds: Double, step: @escaping (Double, CardStack.Changes) -> Void = { _, _ in }) -> Double {
        var closest = Double.infinity
        driver.run(for: seconds, step: { time, changes in
            step(time, changes)
            let entries = driver.stack.entries
            for (index, leaving) in entries.enumerated() where leaving.isLeaving {
                let above = leaving.animator.shape(at: time)
                for below in entries[(index + 1)...] where !below.isLeaving {
                    closest = min(closest, below.animator.shape(at: time).pillTop - (above.pillTop + above.pillHeight))
                }
            }
        })
        return closest
    }

    /// Cards leaving in the same step, with cards waiting in the drop, gather in place before they
    /// rise, as they do without a drop: none rises into the place another just gave up, and the
    /// cards below and the card growing out of the drop never run into them.
    @Test(arguments: [2, 3]) func cardsLeavingTogetherGatherFirst(count: Int) throws {
        let driver = stack(["a", "b", "c", "d", "e", "f"], seconds: 8)
        driver.run(for: 4)
        #expect(driver.stack.overflow?.phase == .shown)
        let leaving = Array(driver.stack.live.prefix(count))
        for entry in leaving { entry.dismissed = true }
        var leftTogether = false
        let closest = closestGap(driver, for: 3, step: { _, changes in
            if changes.left.count == count { leftTogether = true }
        })
        #expect(leftTogether)
        for entry in leaving {
            let exit = try #require(entry.exit)
            #expect(try #require(entry.animator.riseTime) - exit.time > 0.1)
        }
        #expect(closest > 0)
        #expect(driver.releases.first?.release.entry.card.title == "d")
    }

    /// The pointer leaving gives every card with less than 1.5 seconds left 1.5 seconds, so they all
    /// run out in the same step: they gather first and nothing runs into them.
    @Test func cardsRunningOutTogetherAfterThePointerLeavesGatherFirst() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 3)
        while driver.stack.overflow?.phase != .shown, driver.time < 5 { driver.run(for: 1.0 / 60) }
        driver.stack.hover(true, at: driver.time)
        driver.run(for: 1)
        #expect(driver.stack.live.filter { $0.remaining < 1.5 }.count >= 2)
        driver.stack.hover(false, at: driver.time)
        var most = 0
        let closest = closestGap(driver, for: 4, step: { _, changes in most = max(most, changes.left.count) })
        #expect(most >= 2)
        #expect(closest > 0)
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
        driver.run(for: 1.5, step: { time, _ in
            guard let overflow = driver.stack.overflow else { return }
            if seeded == nil, !overflow.seeds.isEmpty { seeded = time }
            if counts.last != overflow.count { counts.append(overflow.count) }
            // The seed is melted into the card it leaves, then into the drop.
            if driver.stack.outline.overflowPieces(at: time).dropFirst().contains(where: {
                if case .traced = $0 { return true }
                return false
            }) { traced = true }
        })
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
        only.run(for: 2, step: { _, _ in formed = formed || updates.overflow != nil })
        #expect(!formed)
        #expect(only.swaps.map(\.title) == ["deployed"])

        // The update counts, then swaps in place and the count goes back down. The pointer holds the
        // swap until the update has dripped in.
        stack.hover(true)
        driver.others = [card("deployed", seconds: 30, id: "deploy")]
        var counts: [Int] = []
        var gone = false
        driver.run(for: 1.5, step: { _, _ in
            if let count = stack.overflow?.count, counts.last != count { counts.append(count) }
        })
        #expect(driver.swaps.isEmpty)
        stack.hover(false)
        driver.run(for: 3, step: { _, _ in
            if let count = stack.overflow?.count, counts.last != count { counts.append(count) }
            if stack.overflow == nil { gone = true }
        })
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
        driver.run(for: 2, step: { time, _ in
            if left == nil, drop.isLeaving { left = time }
            if gone == nil, stack.overflow == nil { gone = time }
            if left != nil, gone == nil, stack.live.isEmpty { fillingKept = false }
        })
        #expect(drop.count == 0)
        #expect(drop.anchor === stack.live.last)
        #expect(try #require(gone) > (try #require(left)))
        #expect(fillingKept)
    }

    /// A card that comes while a card grows out of the drop counts at once, so the count stays true
    /// through releases back to back and never runs out while a card still waits.
    @Test func aCardThatComesWhileOneGrowsOutCounts() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 3)
        var sent = false
        var releasing = false
        var trailed = false
        var blank = false
        driver.run(for: 14, step: { time, _ in
            if !sent, driver.releases.count == 1 {
                sent = true
                driver.others = [self.card("late", seconds: 3)]
            }
            guard let overflow = driver.stack.overflow, !overflow.isLeaving else { return }
            let inFlight = overflow.seeds.filter { time < $0.merge }.count
            if case .releasing = overflow.phase, sent {
                releasing = true
                if overflow.count + inFlight != driver.stack.queued.count { trailed = true }
            }
            if overflow.count == 0, !driver.stack.queued.isEmpty { blank = true }
        })
        #expect(releasing)
        #expect(!trailed)
        #expect(!blank)
        #expect(driver.releases.map(\.release.entry.card.title) == ["d", "e", "late"])
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
        driver.run(for: 6, metrics: { $0.title == "tall" ? tall : self.metrics }, step: { _, _ in
            guard driver.stack.overflow === drop, !drop.isLeaving else { return }
            if tops.last != drop.animator.targetTop { tops.append(drop.animator.targetTop) }
        })
        // Once, as the tall card grew out of it into the third place, and no further.
        #expect(tops.count == 2)
        #expect(tops.first == top)
        #expect(tops.last.map { abs($0 - (slot(2) + tall.pillHeight + CardStack.gap)) < 0.01 } == true)
    }

    /// A taller card in the bottom place pushes the drop down; once it leaves and a shorter card
    /// takes its place, the drop goes back up to where it first was.
    @Test func theDropFollowsTheBottomPlace() throws {
        let tall = IslandMetrics(notchWidth: 185, notchHeight: 32, textWidth: 180, textHeight: 80, titleLines: 2, detailLines: 2)
        let cards = [card("a", seconds: 12), card("b", seconds: 12), card("c", seconds: 2), card("tall", seconds: 2)]
            + ["e", "f", "g"].map { card($0, seconds: 12) }
        let driver = Driver(CardStack(settings: StackSettings(mode: .chain, max: 3), cards: cards), metrics: metrics)
        while driver.stack.overflow == nil, driver.time < 4 { driver.run(for: 1.0 / 60) }
        let drop = try #require(driver.stack.overflow)
        #expect(driver.releases.isEmpty)
        let top = drop.animator.targetTop
        var tops: [Double] = [top]
        driver.run(for: 8, metrics: { $0.title == "tall" ? tall : self.metrics }, step: { _, _ in
            guard driver.stack.overflow === drop, !drop.isLeaving else { return }
            if tops.last != drop.animator.targetTop { tops.append(drop.animator.targetTop) }
        })
        #expect(driver.releases.map(\.release.entry.card.title).prefix(2) == ["tall", "e"])
        #expect(tops.count == 3)
        #expect(tops.dropFirst().first.map { abs($0 - (slot(2) + tall.pillHeight + CardStack.gap)) < 0.01 } == true)
        #expect(tops.last.map { abs($0 - top) < 0.01 } == true)
    }

    /// The bottom card dismissed while the pointer holds the stack leaves its place with no card to
    /// take it: the drop stays exactly where it is, and the next card grows up into that place once
    /// the pointer leaves.
    @Test func theDropStaysWhenTheBottomPlaceEmpties() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 12)
        driver.run(for: 3)
        let drop = try #require(driver.stack.overflow)
        let top = drop.animator.targetTop
        var tops: Set<Double> = [top]
        driver.stack.hover(true)
        driver.stack.live[2].dismissed = true
        driver.run(for: 2, step: { _, _ in tops.insert(drop.animator.targetTop) })
        #expect(driver.stack.live.map(\.card.title) == ["a", "b"])
        #expect(driver.releases.isEmpty)
        driver.stack.hover(false)
        driver.run(for: 2, step: { _, _ in tops.insert(drop.animator.targetTop) })
        #expect(driver.releases.first?.release.entry.card.title == "d")
        #expect(driver.releases.first.map { abs($0.top - slot(2)) < 0.01 } == true)
        #expect(tops == [top])
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

    /// The shared spring is the new card's spread and the cards' move: both settle together.
    @Test func theHandOverIsOneSpring() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 3)
        var below: CardStack.Entry?
        driver.run(for: 10, step: { _, changes in
            if below == nil, !changes.left.isEmpty { below = driver.stack.live.first }
        })
        let first = try #require(driver.releases.first)
        let moving = try #require(below)
        // Each is as far along its way as the other at every moment, on the same curve.
        let entry = first.release.entry
        let middle = { (shape: IslandShape) in shape.pillTop + shape.pillHeight / 2 }
        let from = middle(entry.animator.shape(at: first.start))
        let to = slot(2) + metrics.pillHeight / 2
        for t in [0.1, 0.2, 0.3, 0.6] {
            let time = first.start + t
            let progress = CardStack.handOver.progress(at: t)
            #expect(abs(moving.animator.shape(at: time).pillTop - (slot(1) + (slot(0) - slot(1)) * progress)) < 0.5)
            #expect(abs(middle(entry.animator.shape(at: time)) - (from + (to - from) * progress)) < 0.5)
        }
    }

    /// With no card waiting, a card leaving still keeps its place until its drop rises, and the
    /// count ticking for any other reason still swells the drop.
    @Test func withoutAHandOverNothingChanges() throws {
        let driver = stack(["a", "b"], seconds: 2)
        var leaving: CardStack.Entry?
        var leftAt = 0.0
        driver.run(for: 6, step: { time, changes in
            if leaving == nil, let left = changes.left.first { leaving = left.entry; leftAt = time }
        })
        let left = try #require(leaving)
        #expect(try #require(left.animator.riseTime) - leftAt > 0.15)

        let late = stack(["a", "b", "c", "d"], seconds: 6)
        late.run(for: 3)
        let drop = try #require(late.stack.overflow)
        late.others = [card("late")]
        var widest = 0.0
        late.run(for: 1.5, step: { time, _ in widest = max(widest, drop.animator.shape(at: time).pillWidth) })
        #expect(drop.count == 2)
        #expect(!drop.handedOver)
        #expect(widest > metrics.dropSize + 1)
    }
}
