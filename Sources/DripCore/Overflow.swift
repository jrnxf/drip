/// The overflow drop: once the stack is full, a small round drop under the last card counts the cards
/// still waiting for room. It forms out of the last card at the place one more card would take, and
/// stays there until it goes. A card that comes while it shows drips into it from the last card and
/// the count ticks up; as room opens, the count ticks down and the next card grows out of it into the
/// place the leaving card frees, in one motion with that card going. The last card waiting is the
/// drop itself spreading into a card. Once nothing waits, it goes back into the last card. With the
/// pointer on it, it springs wide to list the waiting cards' titles, newest first, and holds the
/// stack as a card under the pointer does.
extension CardStack {
    public final class Overflow {
        public enum Phase: Equatable {
            /// Dripping out of the last card from `start`; its count fades in at `cues.sides`.
            case forming(start: Double, cues: IslandCues)
            case shown
            /// Joined to the card growing out of it until `until`.
            case releasing(until: Double)
            /// Going back into the last card from `start`, gone by `until`.
            case leaving(start: Double, until: Double)
        }

        /// Its sizes as it shows its count; `animator`'s are wider while it lists the titles.
        public internal(set) var metrics: IslandMetrics
        public internal(set) var animator: IslandAnimator
        public internal(set) var phase: Phase
        /// The count it shows, which lags the cards waiting while one drips into it.
        public internal(set) var count: Int
        /// The count before it last changed, and when it changed.
        public internal(set) var previous = 0
        public internal(set) var changedAt = -Double.infinity
        /// Whether it last changed as a card grew out of it, so the count rolls with that card.
        public internal(set) var handedOver = false
        /// Whether it is spread wide to list the waiting cards' titles, and since when, or since when
        /// it went back to its count.
        public internal(set) var peeking = false
        public internal(set) var peekChangedAt = -Double.infinity
        /// The waiting cards' titles, newest first.
        public internal(set) var titles: [String] = []
        /// The cards dripping into it.
        public internal(set) var seeds: [Seed] = []
        /// What it melts into: the card it formed under, the card growing out of it, or the card it
        /// goes back into.
        public internal(set) weak var anchor: Entry?
        var lastSeed = -Double.infinity

        init(metrics: IslandMetrics, animator: IslandAnimator, phase: Phase, count: Int, anchor: Entry) {
            self.metrics = metrics
            self.animator = animator
            self.phase = phase
            self.count = count
            self.anchor = anchor
        }

        public var isLeaving: Bool {
            if case .leaving = phase { return true }
            return false
        }

        /// What it lists while the pointer is on it.
        public var peekText: String { titles.joined(separator: " · ") }

        /// The cards still on their way into it.
        var inFlight: Int { seeds.filter { !$0.merged }.count }

        /// When every spring and every card dripping into it has settled.
        var end: Double { seeds.map(\.end).reduce(animator.end, max) }
    }

    /// A card that came while the overflow drop shows, as a small drop beading out of the bottom of
    /// the last card and falling the gap into the overflow drop, melted into each while close: a
    /// liquid bridge that pulses into the drop. Every value is a function of the time, so the
    /// renderers sample it as they sample a card.
    public struct Seed: Sendable {
        public let start: Double
        /// When it reaches the drop's middle: the count goes up.
        public let merge: Double
        /// The card it drips out of, by `Entry.id`.
        public let source: Int
        private let from: Double
        private let to: Double
        private var size: SpringValue
        /// How strongly it melts into the card it leaves, and into the drop it joins.
        private var leaving: SpringValue
        private var joining: SpringValue
        var merged = false

        /// How it falls the gap.
        static let fall = Spring(duration: 0.55)

        /// Drips out of the bottom of `card`, whose capsule ends at `bottom`, at `time`, into the
        /// overflow drop whose capsule's top is `top` and middle `middle`.
        init(from card: Entry, bottom: Double, into top: Double, middle: Double, metrics m: IslandMetrics, at time: Double) {
            let scale = m.scale
            // It beads out from just inside the card, and is fed as it hangs, as a card's drop is.
            let from = bottom - 10 * scale
            var size = SpringValue(4 * scale)
            size.animate(to: 14 * scale, with: Spring(duration: 0.3), at: time)
            let center = { (t: Double) in from + (middle - from) * Self.fall.progress(at: t - time) }
            // The neck to the card pinches off at a third of the blend, as a card's own drop does.
            var leaving = SpringValue(m.blend)
            let detached = firstTime(after: time) { [size] in center($0) - size.value(at: $0) / 2 >= bottom + m.blend / 3 }
            leaving.animate(to: 0, with: Spring(duration: 0.35), at: detached)
            var joining = SpringValue(0)
            let joined = firstTime(after: time) { [size] in center($0) + size.value(at: $0) / 2 >= top - 12 * scale }
            joining.animate(to: m.blend, with: Spring(duration: 0.3), at: joined)
            start = time
            source = card.id
            self.from = from
            to = middle
            self.size = size
            self.leaving = leaving
            self.joining = joining
            merge = firstTime(after: time) { center($0) >= middle - 5 * scale }
        }

        /// Gone into the drop by now.
        public var end: Double { merge + 0.25 }

        public func center(at time: Double) -> Double {
            from + (to - from) * Self.fall.progress(at: time - start)
        }

        /// The round seed at `time`, melting at `blend`.
        public func shape(at time: Double, blend: Double) -> IslandShape {
            let side = size.value(at: time)
            return IslandShape(pillTop: center(at: time) - side / 2, pillWidth: side, pillHeight: side, progress: 0, blend: blend)
        }

        public func leavingBlend(at time: Double) -> Double { max(leaving.value(at: time), 0) }
        public func joiningBlend(at time: Double) -> Double { max(joining.value(at: time), 0) }
    }

    /// A card grown out of the overflow drop: its entry, the count the drop showed before, and whether
    /// it was the last card waiting, which the drop itself spread into.
    public struct Release {
        public let entry: Entry
        public let count: Int
        public let last: Bool
    }

    /// The drop's sizes for `count`: round, and wider for a count too wide for that.
    func overflowMetrics(count: Int, like card: IslandMetrics) -> IslandMetrics {
        let scale = card.scale
        let text = (measureCount(String(max(count, 1))) * scale).rounded(.up)
        return overflowMetrics(width: max(card.dropSize, text + 14 * scale), like: card)
    }

    func overflowMetrics(width: Double, like card: IslandMetrics) -> IslandMetrics {
        IslandMetrics(
            notchWidth: card.notchWidth, notchHeight: card.notchHeight, scale: card.scale, textWidth: 0,
            textHeight: 0, titleLines: 0, detailLines: 0, hasIcon: false,
            fixedPill: IslandMetrics.PillSize(width: width, height: card.dropSize))
    }

    /// Whether `card`, another drip's, shows in place of a card on screen with the same id rather
    /// than taking a place of its own.
    public func swapsInPlace(_ card: Card) -> Bool {
        guard let id = card.id else { return false }
        return live.contains { $0.card.id == id && $0.isShown && CardReplacement.canSwap($0.card, for: card) }
    }

    /// Whether the next card waiting can grow out of the overflow drop now: the drop is at rest, the
    /// stack has room, and the pointer is away.
    public func canRelease(at time: Double) -> Bool {
        guard let overflow, overflow.phase == .shown else { return false }
        return hasRoom && !hovering && !overflow.peeking
    }

    /// How everything moves as the next card grows out of the overflow drop: the cards below the one
    /// leaving close up, the new card spreads into the place at the bottom, and the drop's count rolls
    /// to its new number, all on this one spring and from the same moment, as one motion.
    public static let handOver = Spring(duration: 0.5, bounce: 0.12)
    /// How far open a card growing out of the overflow drop is when its text starts to fade in:
    /// sooner than a card dropping in, so it is never an empty capsule while the stack moves.
    public static let handOverText = 0.65
    /// How long before the overflow drop has spread its count fades in, as it rounds out under the
    /// last card rather than after.
    public static let countLead = 0.2

    /// When the overflow drop forming from `start`, with `cues`, fades its count in: seconds after
    /// `start`.
    public static func countCue(_ cues: IslandCues) -> Double { max(cues.sides - countLead, 0) }

    /// Grows `card`, laid out as `metrics`, out of the overflow drop from `time`, as the count rolls
    /// down: up into the place the card leaving frees. A card that left rising gives its place up at
    /// once, so the cards below close up as it gathers and the new card spreads, the count rolling
    /// with them, all on `handOver` from `time`; one still gathering in place holds it, and the new
    /// card waits until its drop starts to rise. The drop stays where it is, joined to the new card
    /// until the neck between them pinches off. The last card waiting is the drop itself, spreading
    /// into the card. In push mode the card drops from the notch as any card does.
    @discardableResult
    public func release(_ card: Card, metrics: IslandMetrics, own: Bool, at time: Double) -> Release? {
        guard let overflow, !overflow.isLeaving else { return nil }
        let count = overflow.count
        let last = settings.mode == .chain && queued.count <= 1 && overflow.inFlight == 0
        let holding = settings.mode == .chain ? entries.filter { $0.isLeaving && $0.holdsPlaceUntil.isFinite } : []
        // The new card, and the count with it, wait for a card still gathering in place to rise.
        let start = holding.filter { !$0.rises }.map(\.holdsPlaceUntil).reduce(time, max)
        // From the cards still waiting rather than the count shown, which a card that came while no
        // seed could drip in may not have caught up with yet.
        tick(overflow, to: max(queued.count - 1 - overflow.inFlight, 0), at: start, handingOver: true)
        // No longer waiting, from now rather than the next step: it can grow out as a card leaves,
        // after the step has looked at the cards waiting.
        if let index = queued.firstIndex(of: card) { queued.remove(at: index) }
        if settings.mode == .push {
            return Release(entry: enter(card, metrics: metrics, own: own, decided: time, at: time), count: count, last: false)
        }
        for entry in holding where entry.rises { entry.holdsPlaceUntil = -.infinity }
        if holding.contains(where: \.rises) { place(at: time, with: Self.handOver) }
        var slot: Double?
        for entry in live { slot = (slot ?? entry.metrics.pillTop) + entry.metrics.pillHeight + Self.gap }
        var animator = last ? overflow.animator : IslandAnimator(metrics: metrics, from: overflow.animator.shape(at: time))
        let cues = animator.spread(
            into: metrics, top: slot ?? metrics.pillTop, at: start, with: Self.handOver, textAt: Self.handOverText)
        let entry = Entry(id: nextID, card: card, own: own, metrics: metrics, animator: animator)
        nextID += 1
        entry.anchor = live.last
        entry.phase = .entering(start: start, cues: cues)
        entry.countdownFrom = start + (cues.title.first ?? cues.sides) + 0.25
        entries.append(entry)
        lastEntrance = time
        if last {
            self.overflow = nil
        } else {
            overflow.animator.melt(at: start)
            overflow.anchor = entry
            overflow.phase = .releasing(until: start + 0.4)
        }
        return Release(entry: entry, count: count, last: last)
    }

    /// Springs the overflow drop wide to list the waiting cards' titles, `width` points wide as drawn
    /// at regular size, or back to its count when `width` is nil, from `time`. Returns whether that
    /// changed anything.
    @discardableResult
    public func peek(width: Double?, at time: Double) -> Bool {
        guard let overflow else { return false }
        guard let width else {
            guard overflow.peeking else { return false }
            overflow.peeking = false
            overflow.peekChangedAt = time
            if !overflow.isLeaving { overflow.animator.resize(to: overflow.metrics, at: time) }
            return true
        }
        guard !overflow.isLeaving, overflow.peeking || overflow.phase == .shown else { return false }
        let scale = overflow.metrics.scale
        let wide = max(min((width * scale).rounded(.up) + 26 * scale, 340 * scale), overflow.metrics.pillWidth)
        if overflow.peeking, abs(overflow.animator.metrics.pillWidth - wide) <= 0.5 { return false }
        if !overflow.peeking {
            overflow.peeking = true
            overflow.peekChangedAt = time
        }
        overflow.animator.resize(to: overflowMetrics(width: wide, like: overflow.metrics), at: time)
        return true
    }

    /// Whether `point`, as for `entry(at:time:)`, is on the overflow drop.
    public func isOnOverflow(_ point: IslandPoint, time: Double) -> Bool {
        guard let overflow, !overflow.isLeaving else { return false }
        let shape = overflow.animator.shape(at: time)
        return abs(point.x) <= shape.pillWidth / 2 + 4 && point.y >= shape.pillTop - 4
            && point.y <= shape.pillTop + shape.pillHeight + 4
    }

    /// Moves the overflow drop on to `time`, with `others`, other drips' cards waiting for this stack,
    /// oldest first, and without this drip's own cards in `replaced`: it forms, takes cards in, ticks down as they go elsewhere, and goes back in once
    /// none waits. Changes it starts begin at `start`. Returns whether anything changed.
    func advanceOverflow(_ others: [Card], replaced: [Card], to time: Double, start: Double) -> Bool {
        let own = waiting.filter { !replaced.contains($0) }
        queued = own + others + tucked.map(\.card)
        var changed = false
        if let overflow {
            switch overflow.phase {
            case let .forming(begin, cues) where time - begin >= cues.sides + 0.25:
                overflow.phase = .shown
            case let .releasing(until) where time >= until:
                overflow.phase = .shown
            case let .leaving(_, until) where time >= until + 0.02 || isSwallowed(overflow, at: time):
                self.overflow = nil
                changed = true
            default:
                break
            }
        }
        if overflow == nil, !hasRoom, !hovering, time - lastEntrance >= Self.entranceSpacing,
           !own.isEmpty || !tucked.isEmpty || others.contains(where: { !swapsInPlace($0) }),
           let holder = entries.last(where: { !$0.isLeaving || $0.holdsPlaceUntil.isFinite }),
           !holder.isLeaving, holder.animator.end <= time
        {
            formOverflow(under: holder, at: start)
            return true
        }
        guard let overflow, !overflow.isLeaving else { return changed }
        overflow.titles = queued.reversed().map(\.title)
        let target = queued.count
        for index in overflow.seeds.indices where !overflow.seeds[index].merged && time >= overflow.seeds[index].merge {
            overflow.seeds[index].merged = true
            // A card that went elsewhere on the way in merges without a tick.
            if overflow.count + overflow.inFlight < target { tick(overflow, to: overflow.count + 1, at: start) }
            changed = true
        }
        overflow.seeds.removeAll { time >= $0.end }
        let inFlight = overflow.inFlight
        // A card waiting swapped into its card on screen, was replaced, or its drip went.
        if overflow.count + inFlight > target, overflow.count > max(target - inFlight, 0) {
            tick(overflow, to: max(target - inFlight, 0), at: start)
            changed = true
        }
        if overflow.phase == .shown, overflow.count + inFlight < target, time - overflow.lastSeed >= 0.14,
           let source = live.last, source.animator.end <= time
        {
            overflow.lastSeed = time
            overflow.seeds.append(Seed(
                from: source, bottom: source.animator.targetTop + source.metrics.pillHeight,
                into: overflow.animator.targetTop,
                middle: overflow.animator.targetTop + overflow.animator.metrics.pillHeight / 2,
                metrics: overflow.metrics, at: start))
            changed = true
        } else if case .releasing = overflow.phase, overflow.count + inFlight < target {
            // Joined to the card growing out of it, it has no last card to drip from: a card that
            // comes meanwhile counts at once.
            tick(overflow, to: target - inFlight, at: start)
            changed = true
        }
        if overflow.phase == .shown, overflow.count <= 0, target == 0, overflow.seeds.isEmpty,
           time - overflow.changedAt >= 0.2
        {
            absorbOverflow(at: start)
            return true
        }
        // The drop sits just below the bottom of the cards' places, and moves only when a card of
        // another height takes the bottom place: down for a taller one, back up for a shorter one. A
        // place left with no card taking it leaves the drop where it is.
        let bottom = entries.filter { !$0.isLeaving || $0.holdsPlaceUntil.isFinite }
            .map { ($0.exit?.top ?? $0.animator.targetTop) + $0.metrics.pillHeight }.max()
        if !hasRoom, let bottom, abs(bottom + Self.gap - overflow.animator.targetTop) > 0.25 {
            overflow.animator.move(to: bottom + Self.gap, at: start)
            changed = true
        }
        return changed
    }

    /// Drips the overflow drop out of `holder`, the last card, at `time`, into the place one more
    /// card would take.
    private func formOverflow(under holder: Entry, at time: Double) {
        let metrics = overflowMetrics(count: queued.count, like: holder.metrics)
        let anchor = DropletAnchor.capsule(holder.animator.shape(at: time), metrics: holder.metrics)
        var animator = IslandAnimator(metrics: metrics, anchor: anchor)
        let cues = animator.enter(at: time, top: holder.animator.targetTop + holder.metrics.pillHeight + Self.gap)
        overflow = Overflow(
            metrics: metrics, animator: animator, phase: .forming(start: time, cues: cues), count: queued.count,
            anchor: holder)
    }

    /// Takes the empty overflow drop back into the last card, or into the notch, at `time`.
    private func absorbOverflow(at time: Double) {
        guard let overflow else { return }
        peek(width: nil, at: time)
        let into = live.last
        overflow.anchor = into
        _ = overflow.animator.exit(
            at: time, into: into.map { DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.metrics) })
        overflow.phase = .leaving(start: time, until: overflow.animator.end)
    }

    /// Sets the overflow drop's count to `count` at `time`: the drop widens or narrows to fit it, and
    /// swells as a card merges into it or gives a little as one leaves it. `handingOver` when a card
    /// grows out of it: the count then rolls with that card on `handOver`, and the drop holds still.
    func tick(_ overflow: Overflow, to count: Int, at time: Double, handingOver: Bool = false) {
        guard count != overflow.count else { return }
        let up = count > overflow.count
        overflow.previous = overflow.count
        overflow.count = count
        overflow.changedAt = time
        overflow.handedOver = handingOver
        let metrics = overflowMetrics(count: count, like: overflow.metrics)
        if abs(metrics.pillWidth - overflow.metrics.pillWidth) > 0.5 {
            overflow.metrics = metrics
            if !overflow.peeking {
                overflow.animator.resize(to: metrics, at: time, with: handingOver ? Self.handOver : IslandUpdate.resize)
            }
        }
        if !overflow.peeking, !handingOver, count > 0 { overflow.animator.swell(by: (up ? 3 : -3) * metrics.scale, at: time) }
    }

    /// Whether the overflow drop going back in is hidden inside what it went into.
    private func isSwallowed(_ overflow: Overflow, at time: Double) -> Bool {
        let shape = overflow.animator.shape(at: time)
        guard shape.pillWidth <= overflow.metrics.dropSize + 1 else { return false }
        let bottom = overflow.anchor.map {
            DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.metrics).bottom
        } ?? overflow.metrics.notchHeight
        return shape.pillTop + shape.pillHeight <= bottom - overflow.metrics.blend / 2
    }
}

/// The first time from `start`, in 1 ms steps and within 2 s, at which `condition` holds.
private func firstTime(after start: Double, where condition: (Double) -> Bool) -> Double {
    var time = start
    while time < start + 2, !condition(time) { time += 0.001 }
    return time
}
