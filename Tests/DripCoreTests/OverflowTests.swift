@testable import DripCore // to give two cards the same time left
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
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

    /// Runs a stack as the Mac app runs one, 60 steps a second: when a card may come in, another
    /// drip's card swaps into its card on screen, and with no overflow drop a card drops in; whenever
    /// a place is free, the next card grows out of the overflow drop, on the step that reaches the
    /// moment the drop of the card leaving starts to rise. `others` are other drips'
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
        /// Whether no card grows out of the overflow drop, as when the next card waiting was replaced.
        var holdsReleases = false

        init(_ stack: CardStack, metrics: IslandMetrics) {
            self.stack = stack
            self.metrics = metrics
        }

        /// Grows the next card waiting out of the overflow drop, when it can: this drip's own first.
        /// Returns whether one came out.
        private func release(_ layout: (Card) -> IslandMetrics) -> Bool {
            guard !holdsReleases, stack.canRelease(at: time) else { return false }
            var next = stack.nextOwn()
            var own = true
            if let card = next, replaced.contains(card) { next = nil }
            if next == nil, let index = others.firstIndex(where: { !stack.swapsInPlace($0) }) {
                next = others.remove(at: index)
                own = false
            }
            guard let next, let release = stack.release(next, metrics: layout(next), own: own, decided: time, at: time)
            else { return false }
            var start = time
            if case let .entering(begin, _) = release.entry.phase { start = begin }
            releases.append((time, release, start, release.entry.animator.targetTop, stack.live.map(\.card.title)))
            return true
        }

        func run(
            for seconds: Double, metrics cardMetrics: ((Card) -> IslandMetrics)? = nil, before: (Double) -> Void = { _ in },
            step: (Double, CardStack.Changes) -> Void = { _, _ in }
        ) {
            let layout = cardMetrics ?? { _ in self.metrics }
            let until = time + seconds
            while time < until {
                before(time)
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
                while release(layout) {}
                let changes = stack.advance(to: time, lead: 0, queued: others, replaced: replaced)
                step(time, changes)
                time += 1.0 / 60
            }
        }
    }

    private func stack(_ titles: [String], max: Int = 3, seconds: Double = 4) -> Driver {
        Driver(
            CardStack(settings: StackSettings(max: max), cards: titles.map { card($0, seconds: seconds) }),
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

    /// The card past the stack's size waits in a drop under the full stack at every `stack_max`,
    /// whether it is this drip's own card or another drip's.
    @Test(arguments: Defaults.stackMaxRange) func theCardPastTheStackWaitsInTheDropAtEveryMax(max: Int) throws {
        let titles = (1...(max + 1)).map { "card \($0)" }
        let own = stack(titles, max: max, seconds: 30)
        own.run(for: 8)
        #expect(own.stack.live.count == max)
        #expect(own.stack.overflow?.count == 1)
        #expect(own.stack.overflow?.phase == .shown)

        let driver = Driver(CardStack(settings: StackSettings(max: max)), metrics: metrics)
        driver.others = titles.map { card($0, seconds: 30) }
        driver.run(for: 8)
        #expect(driver.stack.live.count == max)
        #expect(driver.stack.overflow?.count == 1)
        #expect(driver.stack.overflow?.phase == .shown)
    }

    /// Cards that run out as fast as they come in, as a stack of six does at the default time,
    /// never fill the stack long enough for a drop. The card past the stack still comes in as soon
    /// as the first card has left, not after every card on screen has gone.
    @Test(arguments: Defaults.stackMaxRange) func theCardPastTheStackComesInOnceTheFirstHasLeft(max: Int) throws {
        let driver = Driver(CardStack(settings: StackSettings(max: max)), metrics: metrics)
        let titles = (1...(max + 1)).map { "card \($0)" }
        driver.others = titles.map { card($0, seconds: Defaults.seconds) }
        var liveWhenLastCameIn: [String]?
        driver.run(for: 20, step: { _, _ in
            if liveWhenLastCameIn == nil, driver.stack.live.contains(where: { $0.card.title == titles.last }) {
                liveWhenLastCameIn = driver.stack.live.map(\.card.title)
            }
        })
        let onScreen = try #require(liveWhenLastCameIn)
        // Into the room the first cards left, with most of the stack still on screen: it did not
        // wait for all of them to go.
        #expect(onScreen.count * 2 > max)
        #expect(driver.stack.live.isEmpty)
        #expect(driver.stack.overflow == nil)
    }

    /// Whenever a card may drop in, a newer card with the id of one on screen may swap in place too,
    /// rather than wait for that card to go and come in on its own: through cards coming in, a
    /// card leaving on time and the stack closing up behind it.
    @Test func aCardMaySwapWheneverACardMayDropIn() throws {
        let driver = Driver(CardStack(settings: StackSettings(max: 4)), metrics: metrics)
        driver.others = [card("x", seconds: 4), card("a", seconds: 5), card("b", seconds: 60, id: "build")]
        var xLeft = false
        var checked = false
        var readySteps = 0
        driver.run(for: 12, before: { time in
            let stack = driver.stack
            guard stack.isReady(at: time) else { return }
            readySteps += 1
            // The first moment a card may drop in after x has left, with its drop long gone.
            guard xLeft, !checked, stack.live.contains(where: { $0.card.title == "b" }) else { return }
            checked = true
            let newer = card("b2", seconds: 4, id: "build")
            guard case .swap(let shown, 0)? = stack.nextAdmission(adoptable: [newer]) else {
                Issue.record("a newer card with the id of one on screen should swap in place")
                return
            }
            #expect(shown.card.title == "b")
        }, step: { _, changes in
            if changes.left.contains(where: { $0.entry.card.title == "x" }) { xLeft = true }
        })
        #expect(checked)
        #expect(readySteps > 0)
    }

    /// With `stack_delay`, the next card drops in that long after the last is fully in, before the
    /// stack has settled, but never while the last is still coming in; without it, only once the
    /// stack has.
    @Test func theStackDelaySetsTheTimeBetweenTwoCardsDroppingIn() throws {
        func enters(delay: Double?, overlaps: inout Bool) -> [Double] {
            let driver = Driver(
                CardStack(settings: StackSettings(max: 6, delay: delay)), metrics: metrics)
            driver.others = (1...4).map { card("card \($0)", seconds: 30) }
            var times: [Double] = []
            var count = 0
            var overlapped = false
            driver.run(for: 8, step: { time, _ in
                guard driver.stack.live.count != count else { return }
                count = driver.stack.live.count
                times.append(time)
                // Another card still coming in as this one starts.
                let coming = driver.stack.live.filter { if case .entering = $0.phase { true } else { false } }
                overlapped = overlapped || coming.count > 1
            })
            overlaps = overlapped
            return times
        }
        var overlaps = false
        func gaps(_ times: [Double]) -> [Double] { zip(times.dropFirst(), times).map { $0 - $1 } }
        // Settled first: about a second between two cards.
        let settled = gaps(enters(delay: nil, overlaps: &overlaps))
        #expect(settled.allSatisfy { $0 > 0.8 })
        // No pause is quicker than that, but each card is in before the next starts.
        let quick = gaps(enters(delay: 0, overlaps: &overlaps))
        #expect(quick.count == 3)
        #expect(quick.allSatisfy { $0 < settled.min()! })
        #expect(!overlaps)
        // With no pause, each drop starts as the last card's text finishes fading in, to the step.
        let driver = Driver(CardStack(settings: StackSettings(max: 6, delay: 0)), metrics: metrics)
        driver.others = (1...3).map { card("card \($0)", seconds: 30) }
        var entrances: [ObjectIdentifier: (begin: Double, ends: Double)] = [:]
        driver.run(for: 4, step: { _, _ in
            for entry in driver.stack.entries {
                if case let .entering(begin, cues) = entry.phase, entrances[ObjectIdentifier(entry)] == nil {
                    entrances[ObjectIdentifier(entry)] = (begin, begin + CardStack.entrance(cues))
                }
            }
        })
        let ordered = entrances.values.sorted { $0.begin < $1.begin }
        #expect(ordered.count == 3)
        #expect(zip(ordered.dropFirst(), ordered).allSatisfy { next, last in
            next.begin >= last.ends && next.begin - last.ends < 0.02
        })
        // A pause is added to that, card after card.
        let slow = gaps(enters(delay: 2, overlaps: &overlaps))
        #expect(zip(slow, quick).allSatisfy { abs(($0 - $1) - 2) < 0.1 })
    }

    /// One of this drip's own cards still to come, replaced by a newer drip's card with the same id,
    /// stops counting as the newer card starts: the count stays as it was.
    @Test func aReplacedOwnCardIsNotCounted() throws {
        let replacedCard = card("e", id: "x")
        let driver = Driver(
            CardStack(
                settings: StackSettings(max: 3),
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
        let stack = CardStack(settings: StackSettings(max: 1), cards: ["a", "b"].map { card($0) })
        var time = 0.0
        while time < 3 {
            if stack.isReady(at: time), let next = stack.nextOwn() {
                stack.enter(next, metrics: metrics, own: true, decided: time, at: time)
            }
            _ = stack.advance(to: time, lead: 0)
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

    /// The leaving card gathers into a round drop in place first. The moment that drop starts to rise,
    /// the count rolls down, the next card starts to grow out of the overflow drop and the cards below
    /// start to close up, all on `CardStack.handOver`: one motion, and none runs into the drop.
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
            }
            if count == nil, !driver.releases.isEmpty {
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
        // Decided on the step that reaches the moment its drop starts to rise, once it is round,
        // and growing from that moment exactly.
        let rise = try #require(leaving?.animator.riseTime)
        #expect(first.time < rise && rise <= first.time + 1.0 / 60 + 1e-9)
        // At the moment its time was up, which the step reaches ahead to.
        let exit = try #require(leaving?.exit?.time)
        #expect(exit >= left && exit <= left + 1.0 / 60 + 1e-9)
        #expect(rise - exit > 0.15)
        #expect(first.start == rise)
        // The cards below hold their place while it gathers, then follow it up without touching it.
        #expect(abs(try #require(below?.animator.shape(at: rise - 0.01)).pillTop - slot(1)) < 0.01)
        #expect(try #require(below?.animator.shape(at: rise + 0.1)).pillTop < slot(1) - 1)
        #expect(closest > 0)
        // The count rolls with it, from the same moment, with no swell of the drop.
        let drop = try #require(overflow)
        let (shown, changedAt, handedOver) = try #require(count)
        #expect(shown == 1)
        #expect(changedAt == rise)
        #expect(handedOver)
        #expect(stride(from: rise, through: rise + 0.6, by: 0.01).allSatisfy {
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
    /// run out in the same step: they leave together, each gathering first, and nothing runs
    /// into them.
    @Test func cardsRunningOutTogetherAfterThePointerLeavesGatherFirst() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 3)
        while driver.stack.overflow?.phase != .shown, driver.time < 5 { driver.run(for: 1.0 / 60) }
        driver.stack.hover(true, at: driver.time)
        driver.run(for: 1)
        #expect(driver.stack.live.filter { $0.remaining < 1.5 }.count >= 2)
        driver.stack.hover(false, at: driver.time)
        var most = 0
        var left = 0
        let closest = closestGap(driver, for: 4, step: { _, changes in
            most = max(most, changes.left.count)
            left += changes.left.count
        })
        #expect(most >= 2)
        #expect(left >= 2)
        #expect(closest > 0)
    }

    /// A card that runs out just after others started to gather in place, with the drop still
    /// shown because no card could grow out of it yet, gathers too, rather than rising at once
    /// through them.
    @Test func aCardLeavingWhileOthersGatherGathersToo() throws {
        let driver = stack(["a", "b", "c", "d", "e", "f"], seconds: 8)
        driver.run(for: 4)
        #expect(driver.stack.overflow?.phase == .shown)
        driver.holdsReleases = true
        let together = Array(driver.stack.live.prefix(2))
        let later = driver.stack.live[2]
        for entry in together { entry.dismissed = true }
        var leftAt: Double?
        var phase: CardStack.Overflow.Phase?
        let closest = closestGap(driver, for: 3, step: { time, changes in
            if leftAt == nil, changes.left.count == 2 { leftAt = time }
            if let left = leftAt, later.dismissed == nil, time >= left + 0.1 {
                later.dismissed = true
                phase = driver.stack.overflow?.phase
            }
        })
        let left = try #require(leftAt)
        #expect(phase == .shown)
        let exit = try #require(later.exit)
        #expect(exit.time - left < 0.2)
        for entry in together + [later] {
            let exit = try #require(entry.exit)
            #expect(try #require(entry.animator.riseTime) - exit.time > 0.1)
        }
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
            settings: StackSettings(max: 2),
            cards: [card("deploying", seconds: 30, id: "deploy"), card("b", seconds: 30), card("c", seconds: 30)])
        let driver = Driver(stack, metrics: metrics)
        driver.run(for: 3)
        let drop = try #require(stack.overflow)
        #expect(drop.count == 1)

        // Only an update waits: no drop of its own.
        let updates = CardStack(
            settings: StackSettings(max: 1), cards: [card("deploying", seconds: 30, id: "deploy")])
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
        let stack = CardStack(settings: StackSettings(max: 1), cards: [card("a", seconds: 30)])
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

    /// The count rolls up with the card growing up out of the drop. A card dripping in rolls it up too.
    @Test func theCountRollsWithTheCardGrowingOutOfIt() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 3)
        var handOver: (rollsUp: Bool, handedOver: Bool)?
        driver.run(for: 10, step: { _, _ in
            if handOver == nil, driver.releases.count == 1, let overflow = driver.stack.overflow {
                handOver = (overflow.rollsUp, overflow.handedOver)
            }
        })
        let rolled = try #require(handOver)
        #expect(rolled.handedOver)
        #expect(rolled.rollsUp)
        let late = stack(["a", "b", "c", "d"], seconds: 8)
        late.run(for: 3.5)
        let drop = try #require(late.stack.overflow)
        late.others = [card("late")]
        late.run(for: 1)
        #expect(drop.count == 2)
        #expect(drop.rollsUp)
        #expect(!drop.handedOver)
    }

    /// The card summing up what came while the screen was locked counts as one.
    @Test func theMissedSummaryCountsAsOne() throws {
        let held = ["x", "y", "z"].map { card($0) }
        let summary = try #require(MissedSummary.cards(for: held).first)
        let stack = CardStack(settings: StackSettings(max: 1), cards: [card("a", seconds: 30), summary])
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
        let driver = Driver(CardStack(settings: StackSettings(max: 3), cards: cards), metrics: metrics)
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

    /// The overflow drop at rest, round, with its top at `top`.
    private func drop(top: Double) -> IslandAnimator {
        var drop = IslandAnimator(metrics: IslandMetrics(
            notchWidth: 185, notchHeight: 32, textWidth: 0, textHeight: 0, titleLines: 0, detailLines: 0,
            hasIcon: false, fixedPill: IslandMetrics.PillSize(width: 26, height: 26)))
        drop.open(top: top)
        return drop
    }

    @Test func aCardSpreadsOutOfTheDropWhereTheDropIs() {
        var animator = IslandAnimator(metrics: metrics, from: drop(top: 200))
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

    /// A card that grows out of the drop starts as the drop, whatever the drop is doing: where it
    /// is, as large, as fast and as melted. The neck the drop has goes with the card, and the
    /// drop's neck to that card starts from nothing.
    @Test func aCardStartsAsTheDropItGrowsOutOf() {
        var drop = drop(top: 200)
        // The drop glides, and still melts into the card that grew out of it a moment ago.
        drop.move(to: 230, at: 0)
        drop.join(at: 0)
        var card = IslandAnimator(metrics: metrics, from: drop)
        _ = card.spread(into: metrics, top: 100, at: 0.05)
        #expect(card.letsGo == drop.letsGo)
        for time in [0, 0.02, 0.05] {
            let (a, b) = (card.shape(at: time), drop.shape(at: time))
            #expect(a.pillTop + a.pillHeight / 2 == b.pillTop + b.pillHeight / 2)
            #expect(abs(a.pillWidth * a.pillHeight - b.pillWidth * b.pillHeight) < 1e-9)
            #expect(a.blend == b.blend)
        }
        #expect(drop.shape(at: 0.05).blend > 5)
        // As fast as the drop at the moment it starts.
        let step = 1e-4
        let speed = { (animator: IslandAnimator) in
            let (a, b) = (animator.shape(at: 0.05 - step), animator.shape(at: 0.05))
            return (b.pillTop + b.pillHeight / 2 - a.pillTop - a.pillHeight / 2) / step
        }
        #expect(abs(speed(card) - speed(drop)) < 1e-6 && speed(drop) > 10)
        // The card keeps that neck, and the drop's neck to the card starts from nothing.
        let neck = card.shape(at: 0.05).blend
        drop.join(at: 0.05)
        #expect(drop.shape(at: 0.05).blend == 0 && card.shape(at: 0.05).blend == neck)
        #expect(drop.letsGo == 0.05 + 0.12)
        #expect(drop.shape(at: 0.12).blend > 5 && drop.shape(at: 2).blend < 0.01)
        let open = card.shape(at: 4)
        #expect(abs(open.pillTop - 100) < 0.01 && abs(open.pillWidth - metrics.pillWidth) < 0.01 && open.blend < 0.01)
    }

    /// Every place free at one moment is taken at that moment: two cards grow out of the drop on
    /// the same step, each joined to the one above it, and the last is the drop itself.
    @Test func twoCardsGrowOutOfTheDropAtOnce() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 60)
        driver.run(for: 5)
        let drop = try #require(driver.stack.overflow)
        #expect(drop.phase == .shown && drop.count == 2)
        for entry in driver.stack.live.prefix(2) { entry.dismissed = false }
        driver.run(for: 3)
        #expect(driver.releases.map(\.release.entry.card.title) == ["d", "e"])
        let (d, e) = (driver.releases[0], driver.releases[1])
        #expect(d.time == e.time && d.start == e.start)
        #expect(!d.release.last && e.release.last)
        // The drop shows 2 until that moment, so that is the number that rolls out over the last.
        #expect(d.release.count == 2 && e.release.count == 2)
        #expect(e.release.entry.anchor === d.release.entry)
        #expect(driver.stack.overflow == nil)
        #expect(driver.stack.live.map(\.card.title) == ["c", "d", "e"])
        for (index, card) in driver.stack.live.enumerated() {
            #expect(card.isShown && abs(card.animator.shape(at: driver.time).pillTop - slot(index)) < 0.01)
        }
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

    /// With no card waiting, a lone card leaving gathers into a round drop in place first and only
    /// then rises, as in the old exit, and the card below holds its place until the drop rises and
    /// then closes the gap without touching it. The
    /// count ticking up as a card drips in still swells the drop.
    @Test func aLoneCardLeavingGathersBeforeItRisesWithoutADrop() throws {
        let driver = stack(["a", "b"], seconds: 2)
        var leaving: CardStack.Entry?
        var leftAt = 0.0
        var sampled: (width: Double, tall: Double)?
        var below: CardStack.Entry?
        var early = Double.infinity
        let closest = closestGap(driver, for: 6, step: { time, changes in
            if leaving == nil, let left = changes.left.first {
                leaving = left.entry
                leftAt = time
                below = driver.stack.live.first { $0 !== left.entry }
            }
            guard let leaving, let rise = leaving.animator.riseTime else { return }
            if sampled == nil, time >= rise {
                let shape = leaving.animator.shape(at: time)
                sampled = (shape.pillWidth, shape.pillHeight)
            }
            // The card below stays put until the drop above it starts to rise.
            if time < rise, let below { early = min(early, below.animator.shape(at: time).pillTop - slot(1)) }
        })
        let left = try #require(leaving)
        #expect(left.card.title == "a")
        let rise = try #require(left.animator.riseTime)
        // Round to the eye once it rises, after the gather rather than with it.
        #expect(rise - leftAt > 0.15)
        let round = try #require(sampled)
        // Within a step of round: the first step at or past the rise.
        #expect(abs(round.width - metrics.dropSize) <= 3 * metrics.scale)
        #expect(abs(round.tall - metrics.dropSize) <= 3 * metrics.scale)
        #expect(early > -0.01)
        #expect(closest > 0)

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

    /// A card whose time is up while the drop is still forming leaves at that moment: it does not
    /// wait for the drop. The cards below close up behind it, and the next card grows out of the
    /// drop as soon as the drop is ready, into the place at the bottom, with the count rolling.
    @Test func aCardDueWhileTheDropFormsLeavesAtOnce() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 2.5)
        var formingAt: Double?
        var leftAt: Double?
        var leaving: CardStack.Entry?
        var due = 0.0
        var formingAsItLeft = false
        driver.run(for: 6, step: { time, changes in
            if formingAt == nil, case .forming = driver.stack.overflow?.phase { formingAt = time }
            if leftAt == nil, let left = changes.left.first {
                leftAt = left.time
                leaving = left.entry
                due = left.entry.countdownFrom + left.entry.card.duration
                if case .forming = driver.stack.overflow?.phase { formingAsItLeft = true }
            }
        })
        let forming = try #require(formingAt)
        let left = try #require(leftAt)
        let entry = try #require(leaving)
        // a's 2.5 seconds ran out while the drop was still forming, and it left on time.
        #expect(entry.card.title == "a")
        #expect(left > forming)
        #expect(formingAsItLeft)
        #expect(abs(left - due) < 1e-9)
        // The next card grows out once the drop is ready, and the count rolls with it.
        let first = try #require(driver.releases.first)
        #expect(first.release.entry.card.title == "d")
        #expect(first.time > left)
        #expect(first.time - left < 1)
        #expect(first.release.count == 2)
        #expect(abs(first.top - slot(2)) < 0.01)
    }

    /// The pointer coming onto the stack while a card gathers, after the next card was set to grow
    /// out of the drop, still lets the cards below close up as that card grows into its place, so it
    /// never grows into the card above it.
    @Test func theCardsBelowCloseUpUnderThePointerAsTheNextCardGrowsOut() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 2.5)
        var grown: CardStack.Entry?
        var closest = Double.infinity
        driver.run(for: 6, step: { time, _ in
            if grown == nil, let first = driver.releases.first { grown = first.release.entry }
            guard let grown else { return }
            driver.stack.hover(true, moved: true, at: time)
            let live = driver.stack.live
            guard let index = live.firstIndex(where: { $0 === grown }), index > 0 else { return }
            let above = live[index - 1].animator.shape(at: time)
            closest = min(closest, grown.animator.shape(at: time).pillTop - (above.pillTop + above.pillHeight))
        })
        let entry = try #require(grown)
        #expect(entry.card.title == "d")
        #expect(driver.stack.hovering)
        #expect(closest > 0)
        #expect(driver.stack.live.map(\.card.title) == ["b", "c", "d"])
        for (index, card) in driver.stack.live.enumerated() { #expect(abs(card.animator.targetTop - slot(index)) < 0.5) }
    }

    /// While a card still gathers in its place the next card waits in the drop, and the count
    /// with it: the count rolls as the card starts to grow out, at the moment the drop of the card
    /// leaving starts to rise, not before.
    @Test func theCountWaitsForTheCardItGoesTo() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 8)
        driver.run(for: 4)
        let leaving = driver.stack.live[0]
        // Clicked away under the pointer, which then moves off.
        driver.stack.hover(true, at: driver.time)
        leaving.dismissed = true
        var countsBefore: Set<Int> = []
        driver.run(for: 3, step: { time, changes in
            if changes.left.contains(where: { $0.entry === leaving }) { driver.stack.hover(false, at: time) }
            if driver.releases.isEmpty, let overflow = driver.stack.overflow { countsBefore.insert(overflow.count) }
        })
        let first = try #require(driver.releases.first)
        let rise = try #require(leaving.animator.riseTime)
        #expect(first.start == rise)
        #expect(first.time < rise && rise <= first.time + 1.0 / 60 + 1e-9)
        #expect(first.release.count == 2)
        #expect(countsBefore == [2])
        // The count changed for the release at the new card's start.
        #expect(driver.stack.overflow?.changedAt == rise)
    }

    /// A card growing out of the drop shows its text sooner than a card dropping in, so it is never
    /// an empty capsule for long; the drop's count fades in as the drop rounds out.
    @Test func textAndCountComeInSooner() throws {
        var handOver = IslandAnimator(metrics: metrics, from: drop(top: 200))
        var plain = IslandAnimator(metrics: metrics, from: drop(top: 200))
        let soon = handOver.spread(into: metrics, top: 100, at: 0, with: CardStack.handOver, textAt: CardStack.handOverText)
        let late = plain.spread(into: metrics, top: 100, at: 0, with: CardStack.handOver)
        #expect(soon.sides < late.sides - 0.03)
        #expect(soon.title.first == soon.sides)

        let driver = stack(["a", "b", "c", "d"], seconds: 6)
        var cues: IslandCues?
        driver.run(for: 3, step: { _, _ in
            if cues == nil, case let .forming(_, forming) = driver.stack.overflow?.phase { cues = forming }
        })
        let forming = try #require(cues)
        #expect(CardStack.countCue(forming) == max(forming.sides - CardStack.countLead, 0))
        #expect(CardStack.countCue(forming) < forming.sides)
    }

    /// Two countdowns that end on the same tick: the cards leave together, the cards waiting grow
    /// out of the drop one after the other, and the count drops by exactly one for each card that
    /// took a place; none sticks and none shows twice.
    @Test func twoCardsRunningOutOnTheSameTickLeaveTogether() throws {
        let driver = stack(["a", "b", "c", "d", "e"], seconds: 20)
        driver.run(for: 4)
        #expect(driver.stack.overflow?.phase == .shown)
        #expect(driver.stack.overflow?.count == 2)
        let tied = Array(driver.stack.live.prefix(2))
        for entry in tied { entry.remaining = 0.5 }
        var leftSteps: [[String]] = []
        driver.run(for: 3, step: { _, changes in
            if !changes.left.isEmpty { leftSteps.append(changes.left.map(\.entry.card.title)) }
        })
        #expect(leftSteps.first == ["a", "b"])
        #expect(leftSteps.joined().filter { $0 == "a" || $0 == "b" }.count == 2)
        // Both are gone and the cards waiting took their place, one growing out of the drop at a
        // time, in the order they came.
        #expect(driver.stack.live.map(\.card.title).starts(with: ["c", "d"]))
        #expect(Set(driver.stack.live.map(\.card.title)).count == driver.stack.live.count)
        #expect(driver.releases.map(\.release.entry.card.title).prefix(2) == ["d", "e"])
        #expect(driver.stack.overflow == nil || driver.stack.overflow?.count == 0)
        #expect(driver.stack.live.count <= 3)
    }

    /// The same tie with no drop: a stack of two with one more card queued behind it. Both leave
    /// together, and the queued card comes into the room, not stuck waiting for either.
    @Test func twoCardsRunningOutOnTheSameTickLetTheQueuedCardIn() throws {
        let driver = stack(["a", "b", "c"], max: 2, seconds: 20)
        driver.run(for: 4)
        #expect(driver.stack.live.map(\.card.title).starts(with: ["a", "b"]))
        for entry in driver.stack.live.prefix(2) { entry.remaining = 0.5 }
        var leftSteps: [[String]] = []
        driver.run(for: 3, step: { _, changes in
            if !changes.left.isEmpty { leftSteps.append(changes.left.map(\.entry.card.title)) }
        })
        #expect(leftSteps == [["a", "b"]])
        #expect(driver.stack.live.map(\.card.title) == ["c"])
    }
}
