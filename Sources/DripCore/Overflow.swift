/// The overflow drop: once the stack is full, a small round drop under the last card counts the cards
/// still waiting for room. It forms out of the last card at the place one more card would take, and
/// stays there until it goes. A card that comes while it shows drips into it from the last card and
/// the count ticks up; as room opens, the count ticks down and the next card grows out of it into the
/// place the leaving card frees, in one motion with that card going. It need not be at rest for
/// that: a card grows out of it while it still rounds out, and while the card before still grows
/// out of it. The last card waiting is the drop itself spreading into a card. Once nothing waits,
/// it goes back into the last card. With the pointer on it, it springs wide to list the waiting
/// cards' titles, newest first, and holds the stack as a card under the pointer does.
extension CardStack {
    public final class Overflow {
        public enum Phase: Equatable {
            /// Dripping out of the last card from `start`; its count fades in at `cues.sides`.
            case forming(start: Double, cues: IslandCues)
            case shown
            /// Joined to the card growing out of it until `until`. A drop that still forms goes on
            /// forming instead, so its count fades in as planned.
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
        /// The count before the moment it last changed, and that moment.
        public internal(set) var previous = 0
        public internal(set) var changedAt = -Double.infinity
        /// Whether it last changed as a card grew out of it, so the count rolls with that card.
        public internal(set) var handedOver = false
        /// Whether its count last rolled up rather than down.
        public internal(set) var rollsUp = true
        /// Whether it is spread wide to list the waiting cards' titles, and since when, or since when
        /// it went back to its count.
        public internal(set) var peeking = false
        public internal(set) var peekChangedAt = -Double.infinity
        /// The waiting cards' titles, newest first.
        public internal(set) var titles: [String] = []
        /// The cards dripping into it.
        public internal(set) var seeds: [Seed] = []
        /// What it melts into: the card it formed under, the card growing out of it, or the card it
        /// goes back into; nil once that card has gone.
        public internal(set) weak var anchor: Entry?
        /// The card it formed out of, and when its neck to that card pinches off: until then it
        /// hangs from that card.
        weak var holder: Entry?
        let letsGo: Double
        var lastSeed = -Double.infinity

        init(metrics: IslandMetrics, animator: IslandAnimator, phase: Phase, count: Int, holder: Entry) {
            self.metrics = metrics
            self.animator = animator
            self.phase = phase
            self.count = count
            anchor = holder
            self.holder = holder
            letsGo = animator.letsGo ?? -.infinity
        }

        public var isLeaving: Bool {
            if case .leaving = phase { return true }
            return false
        }

        func prolong() {
            if case let .leaving(start, _) = phase { phase = .leaving(start: start, until: animator.end) }
        }

        /// What it lists while the pointer is on it.
        public var peekText: String { titles.joined(separator: " · ") }

        /// The cards still on their way into it.
        var inFlight: Int { seeds.filter { !$0.merged }.count }

        /// When every spring and every card dripping into it has settled.
        var end: Double { seeds.map(\.end).reduce(animator.end, max) }

        /// Springs the seeds dripping out of the card `source` on by `change` from `time`, where
        /// they leave it: a seed hangs from its card wherever the card goes.
        func shiftSeeds(from source: Int, by change: Double, with spring: Spring, at time: Double) {
            for index in seeds.indices where seeds[index].source == source {
                seeds[index].from.shift(by: change, with: spring, at: time)
            }
        }

        /// Moves the drop so its top is at `top` from `time`, and with it where every seed lands.
        func move(to top: Double, at time: Double) {
            let change = top - animator.targetTop
            animator.move(to: top, at: time)
            for index in seeds.indices { seeds[index].to.shift(by: change, with: IslandAnimator.settle, at: time) }
        }
    }

    /// A card that came while the overflow drop shows, as a small drop beading out of the bottom of
    /// the last card and falling the gap into the
    /// overflow drop, melted into each while close: a liquid bridge that pulses into the drop. Every
    /// value is a function of the time, so the renderers sample it as they sample a card. Where it
    /// leaves the card and where it lands are places that move with the card and with the drop.
    public struct Seed: Sendable {
        public let start: Double
        /// When it reaches the drop's middle: the count goes up.
        public let merge: Double
        /// The card it drips out of, by `Entry.id`.
        public let source: Int
        var from: SpringValue
        var to: SpringValue
        private var size: SpringValue
        /// How strongly it melts into the card it leaves, and into the drop it joins.
        private var leaving: SpringValue
        private var joining: SpringValue
        var merged = false

        /// How it falls the gap.
        static let fall = Spring(duration: 0.55)

        /// Drips out of the bottom of `card`, which ends at `bottom`, at
        /// `time`, into the overflow drop whose capsule's top is `top` and middle `middle`.
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
            self.from = SpringValue(from)
            to = SpringValue(middle)
            self.size = size
            self.leaving = leaving
            self.joining = joining
            merge = firstTime(after: time) { center($0) >= middle - 5 * scale }
        }

        /// Gone into the drop by now.
        public var end: Double { merge + 0.25 }

        public func center(at time: Double) -> Double {
            let from = from.value(at: time)
            return from + (to.value(at: time) - from) * Self.fall.progress(at: time - start)
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
        swapTarget(for: card) != nil
    }

    /// Whether the next card waiting can grow out of the overflow drop on the step to `time`, whose
    /// changes start at `start`, `time` by default. See `releaseMoment`.
    public func canRelease(at time: Double, starting start: Double? = nil) -> Bool {
        releaseMoment(at: time, starting: start ?? time) != nil
    }

    /// The moment the next card waiting starts to grow out of the overflow drop, when the step to
    /// `time` reaches it, with changes that start at `start`. Nil while none may: the stack is
    /// full, the pointer is on it, or the drop still hangs from the card it forms out of.
    ///
    /// A place is free once the drop of the card that held it starts to rise. `advance` closes the
    /// stack up from that moment, a step ahead, so the card is chosen on that same step, for that
    /// same moment: the two start as one motion. The drop is not asked to be at rest. Only its
    /// neck to the card it forms out of must have let go, about 0.35 s after it starts to form: a
    /// card cannot spread inside the card above it. That card going from its place lifts this too.
    func releaseMoment(at time: Double, starting start: Double) -> Double? {
        guard let overflow, !overflow.isLeaving, !hovering, !overflow.peeking else { return nil }
        let horizon = horizon(at: time, starting: start)
        let rises = entries.filter { $0.isLeaving && holdsPlace($0) }.map(\.holdsPlaceUntil)
        guard live.count + rises.filter({ $0 > horizon }).count < settings.max else { return nil }
        let moment = rises.filter { $0 <= horizon }.reduce(start, max)
        if overflow.letsGo > moment, let holder = overflow.holder, !holder.isLeaving || holder.holdsPlaceUntil > moment {
            return nil
        }
        return moment
    }

    /// How everything moves as the next card grows out of the overflow drop: the cards below the one
    /// leaving close up, the new card spreads into the place at the bottom, and the
    /// drop's count rolls to its new number, all on this one spring and from the same moment, as one
    /// motion.
    public static let handOver = Spring(duration: 0.5, bounce: 0.12)
    /// How far open a card growing out of the overflow drop is when its text starts to fade in:
    /// sooner than a card dropping in, so it is never an empty capsule while the stack moves.
    public static let handOverText = 0.65
    /// How long before the overflow drop has spread its count fades in, as it rounds out under the
    /// last card rather than after.
    public static let countLead = 0.2
    /// As a card grows out of the overflow drop, the drop's old number fades out over this, quick, so
    /// it is gone before the new one shows: the two are never seen one over the other while the
    /// spring carries them.
    public static let handOverCountOut = 0.05
    /// How long after the change starts the new number starts to fade in, and how long it takes.
    public static let handOverCountDelay = 0.06
    public static let handOverCountIn = 0.19

    /// When the overflow drop forming from `start`, with `cues`, fades its count in: seconds after
    /// `start`.
    public static func countCue(_ cues: IslandCues) -> Double { max(cues.sides - countLead, 0) }

    /// Grows `card`, laid out as `metrics`, out of the overflow drop, as the count goes down: up
    /// into the place the card leaving frees. `decided` is the step that chose to, and `time` is
    /// when its changes start. The card starts at `releaseMoment`: as the drops of the cards leaving
    /// start to rise. From that moment the cards below close up and the new card spreads, the count
    /// rolling with them, all on `handOver`. Nil when no card may grow out on this step.
    ///
    /// The new card starts as the drop: it takes the springs that move the drop at that moment, and
    /// the neck the drop still has to the card above it. So it is where the drop is, as fast and
    /// as melted, and its own springs add to that. The drop stays where it is, joined to the new
    /// card by a new neck until that pinches off. The last card waiting is the drop itself,
    /// spreading into the card.
    ///
    /// A card that starts while the card before it still spreads out of the drop may start inside
    /// that card: two cards with a place free at one moment are one shape at first, which parts in
    /// two. The neck between them then holds as a new one does (`rejoin`), and neither shows its
    /// content before they have parted. The step's `advance` says when that is, once the stack
    /// has closed up: see `part`.
    @discardableResult
    public func release(_ card: Card, metrics: IslandMetrics, own: Bool, decided: Double, at time: Double) -> Release? {
        guard let overflow, let start = releaseMoment(at: decided, starting: time) else { return nil }
        // What the drop shows up to that moment: another card may grow out at the same moment.
        let count = overflow.changedAt == start ? overflow.previous : overflow.count
        let last = queued.count <= 1 && overflow.inFlight == 0
        // From the cards still waiting rather than the count shown, which a card that came while no
        // seed could drip in may not have caught up with yet.
        tick(overflow, to: max(queued.count - 1 - overflow.inFlight, 0), at: start, handingOver: true)
        // No longer waiting, from now rather than the next step.
        if let index = queued.firstIndex(of: card) { queued.remove(at: index) }
        // Under the cards that still hold a place at that moment.
        var slot: Double?
        for entry in entries {
            if entry.isLeaving, entry.holdsPlaceUntil <= start {
                if holdsPlace(entry) { entry.handsOver = true }
                continue
            }
            slot = (slot ?? entry.metrics.pillTop) + entry.metrics.pillHeight + Self.gap
        }
        var animator = last ? overflow.animator : IslandAnimator(metrics: metrics, from: overflow.animator)
        // The neck the drop still has goes with the card: to the card the drop formed out of, or
        // to the card that grew out of it before.
        let above = overflow.animator.melts(at: start) ? overflow.anchor : live.last
        // Inside that card, with its middle in it, the two are one shape until they part.
        let inside = above.flatMap { above -> Entry? in
            guard above.outOfDrop, case .entering = above.phase else { return nil }
            let drop = animator.shape(at: start), card = above.animator.shape(at: start)
            return drop.pillTop + drop.pillHeight / 2 < card.pillTop + card.pillHeight ? above : nil
        }
        if inside != nil { animator.rejoin(at: start) }
        let cues = animator.spread(
            into: metrics, top: slot ?? metrics.pillTop, at: start, with: Self.handOver, textAt: Self.handOverText)
        let entry = Entry(id: nextID, card: card, own: own, metrics: metrics, animator: animator)
        nextID += 1
        entry.anchor = above
        entry.top = slot ?? metrics.pillTop
        entry.outOfDrop = true
        entry.restsAt = animator.end
        entry.phase = .entering(start: start, cues: cues)
        entry.countdownFrom = start + (cues.title.first ?? cues.sides) + 0.25
        if let inside { parting.append((entry, inside, start)) }
        entries.append(entry)
        noteEntrance(at: decided)
        if last {
            self.overflow = nil
        } else {
            overflow.animator.join(at: start)
            overflow.anchor = entry
            if case .forming = overflow.phase {} else { overflow.phase = .releasing(until: start + 0.4) }
        }
        return Release(entry: entry, count: count, last: last)
    }

    /// Holds the content of each card that started inside the card before it on this step, and of
    /// that card, until the two have parted: until the lower one is drawn clear of the upper one, a
    /// third of its blend below it, where the join between them breaks. Text never shows on two
    /// cards that are still one shape. A card that starts under the card before it, as a drop on
    /// its neck, is as the overflow drop that hangs there, and holds nothing. A card whose content
    /// already shows keeps it. Called once the stack has closed up, so each card is on its way to
    /// its place. Returns the cards whose cues moved.
    func part() -> [Entry] {
        var held: [Entry] = []
        for (entry, above, start) in parting {
            let (lower, upper) = (entry.animator, above.animator)
            let parted = firstTime(after: start) { time in
                let drop = lower.shape(at: time), card = upper.shape(at: time)
                return drop.pillTop - (card.pillTop + card.pillHeight) >= drop.blend / 3
            }
            for card in [above, entry] where hold(card, until: parted, from: start) && !held.contains(where: { $0 === card }) {
                held.append(card)
            }
        }
        parting = []
        return held
    }

    /// Fades the content of `entry`, a card on its way in, in no sooner than `moment`: every cue
    /// and the start of its countdown move as far as its first cue has to. Not for content that
    /// shows by `now`. Returns whether anything moved.
    @discardableResult
    private func hold(_ entry: Entry, until moment: Double, from now: Double) -> Bool {
        guard case let .entering(begin, cues) = entry.phase else { return false }
        let first = begin + ([cues.sides] + cues.title + cues.detail).min()!
        guard first > now, moment > first else { return false }
        let wait = moment - first
        entry.phase = .entering(start: begin, cues: IslandCues(
            sides: cues.sides + wait, title: cues.title.map { $0 + wait }, detail: cues.detail.map { $0 + wait }))
        entry.countdownFrom += wait
        return true
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
           let holder = entries.last(where: holdsPlace),
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
        // It drips from the last card, once at rest.
        if overflow.phase == .shown, overflow.count + inFlight < target, time - overflow.lastSeed >= 0.14,
           let source = live.last, source.animator.end <= time
        {
            overflow.lastSeed = time
            overflow.seeds.append(Seed(
                from: source, bottom: source.top + source.metrics.pillHeight,
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
        // place left with no card taking it leaves the drop where it is. Not before a card that
        // grows out of it has started: until then that card is the drop.
        let growsOut = entries.contains { entry in
            if entry.outOfDrop, case let .entering(begin, _) = entry.phase { return begin > start }
            return false
        }
        let bottom = entries.filter(holdsPlace).map { $0.top + $0.metrics.pillHeight }.max()
        if !hasRoom, !growsOut, let bottom, abs(bottom + Self.gap - overflow.animator.targetTop) > 0.25 {
            overflow.move(to: bottom + Self.gap, at: start)
            changed = true
        }
        return changed
    }

    /// Drips the overflow drop out of `holder`, the last card, at `time`, into the place one more
    /// card would take.
    private func formOverflow(under holder: Entry, at time: Double) {
        let metrics = overflowMetrics(count: queued.count, like: holder.metrics)
        var animator = IslandAnimator(metrics: metrics, under: holder.animator)
        let cues = animator.enter(at: time, top: holder.top + holder.metrics.pillHeight + Self.gap)
        overflow = Overflow(
            metrics: metrics, animator: animator, phase: .forming(start: time, cues: cues), count: queued.count,
            holder: holder)
    }

    /// Takes the empty overflow drop back into the last card, where that card is heading, or into
    /// the notch, at `time`.
    private func absorbOverflow(at time: Double) {
        guard let overflow else { return }
        peek(width: nil, at: time)
        let into = live.last
        overflow.anchor = into
        _ = overflow.animator.exit(at: time, into: into?.animator.resting)
        overflow.phase = .leaving(start: time, until: overflow.animator.end)
    }

    /// Sets the overflow drop's count to `count` at `time`: the drop widens or narrows to fit it, and
    /// swells as a card merges into it or gives a little as one leaves it. `handingOver` when a card
    /// grows out of it: the count then rolls with that card on `handOver`, the way that card grows,
    /// and the drop holds still. Otherwise it rolls up as it goes up and down as it goes down.
    func tick(_ overflow: Overflow, to count: Int, at time: Double, handingOver: Bool = false) {
        guard count != overflow.count else { return }
        let up = count > overflow.count
        // Changes at one moment are one roll, from the count before it.
        if overflow.changedAt != time { overflow.previous = overflow.count }
        overflow.count = count
        overflow.changedAt = time
        overflow.handedOver = handingOver
        overflow.rollsUp = handingOver || up
        let metrics = overflowMetrics(count: count, like: overflow.metrics)
        if abs(metrics.pillWidth - overflow.metrics.pillWidth) > 0.5 {
            overflow.metrics = metrics
            if !overflow.peeking {
                overflow.animator.resize(to: metrics, at: time, with: handingOver ? Self.handOver : IslandUpdate.resize)
            }
        }
        if !overflow.peeking, !handingOver, count > 0 { overflow.animator.swell(by: (up ? 3 : -3) * metrics.scale, at: time) }
    }
}

/// The first time from `start`, in 1 ms steps and within 2 s, at which `condition` holds.
private func firstTime(after start: Double, where condition: (Double) -> Bool) -> Double {
    var time = start
    while time < start + 2, !condition(time) { time += 0.001 }
    return time
}
