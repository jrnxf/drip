/// Several cards at the notch at once, one below another, each grown out of the notch or out of the
/// card above it: where each card sits, when the next one drops in, and how each goes and what it
/// goes back into. The Mac app draws the stack with Core Animation and the web page on a canvas; both
/// follow this.
///
/// Times are seconds on the drawing's own clock. A change decided at one moment can start a little
/// later, at `time`, so a drawing that takes a moment to sample the springs loses no frames.
public final class CardStack {
    public enum Phase: Equatable {
        case entering(start: Double, cues: IslandCues)
        case shown
        case leaving(until: Double)
    }

    public final class Entry {
        /// Unique in its stack, for the drawing to keep its own state by.
        public let id: Int
        public internal(set) var card: Card
        /// One of this drip's own cards, rather than one adopted from another drip.
        public let own: Bool
        public internal(set) var metrics: IslandMetrics
        public internal(set) var animator: IslandAnimator
        public internal(set) var phase: Phase
        /// The card it grew out of and goes back into; nil for the notch.
        public internal(set) weak var anchor: Entry?
        /// Seconds left on its countdown, which starts once its title has faded in. A card that
        /// waits for you counts down its wait limit.
        public internal(set) var remaining: Double
        public internal(set) var countdownFrom: Double = 0
        /// Whether it still waits for you, until it is clicked or replaced, or gives way to a card
        /// that needs its place and counts down its own time. A question never gives way.
        public internal(set) var isWaiting: Bool
        /// A leaving card keeps its place until its drop starts to rise, so the cards below never
        /// run into it while it gathers.
        var holdsPlaceUntil = Double.infinity
        /// Set when the card should go as soon as nothing is still flowing into it; whether by a
        /// click on its button.
        public var dismissed: Bool?
        /// The button a click landed on, when `dismissed` is true: yes, or a question's no.
        public var answer: CardAnswer?
        /// When it started to leave, and its capsule's top then.
        public internal(set) var exit: (time: Double, top: Double)?

        init(id: Int, card: Card, own: Bool, metrics: IslandMetrics, animator: IslandAnimator) {
            self.id = id
            self.card = card
            self.own = own
            self.metrics = metrics
            self.animator = animator
            phase = .shown
            remaining = card.duration
            isWaiting = card.waits
        }

        public var isLeaving: Bool {
            if case .leaving = phase { return true }
            return false
        }

        public var isShown: Bool {
            if case .shown = phase { return true }
            return false
        }
    }

    /// What changed in one step of the stack's clock.
    public struct Changes {
        /// Cards that started to leave at `time`, with their fade cues, and whether their button
        /// was clicked. A question's answer is the entry's `answer`.
        public var left: [(entry: Entry, cues: IslandCues, time: Double, clicked: Bool)] = []
        /// Cards gone from the stack, whose drawing can go too.
        public var gone: [Entry] = []
        /// Whether cards started moving to close a gap or to catch up after the pointer left.
        public var moved = false
        /// Cards that stopped waiting for you to give way, and now count down from `countdownFrom`.
        public var stoppedWaiting: [Entry] = []

        public var isEmpty: Bool { left.isEmpty && gone.isEmpty && !moved && stoppedWaiting.isEmpty }
    }

    public let settings: StackSettings
    /// Top to bottom, leaving cards included.
    public private(set) var entries: [Entry] = []
    /// This drip's own cards still to drop in.
    public private(set) var waiting: [Card]
    private var lastEntrance = -Double.infinity
    /// While the pointer is on any card nothing moves: every countdown stops, gaps stay open and new
    /// cards wait, so a card never slides out from under a click.
    public private(set) var hovering = false
    /// A change to the stack waits while the pointer is on it.
    private var needsLayout = false
    private var nextID = 1

    /// The gap between two cards in the stack.
    public static let gap: Double = 10
    /// The least time between two cards dropping in; a card also waits until the stack is still.
    public static let entranceSpacing = 0.35

    public init(settings: StackSettings, cards: [Card] = []) {
        self.settings = settings
        waiting = cards
    }

    /// The cards that are not leaving, top to bottom.
    public var live: [Entry] { entries.filter { !$0.isLeaving } }

    /// Whether a card may drop in at `time`: one at a time, into a stack at rest, so a new drop
    /// never shoves cards still settling, and never while the pointer is on the stack.
    public func isReady(at time: Double) -> Bool {
        !hovering && time - lastEntrance >= Self.entranceSpacing && entries.allSatisfy { $0.animator.end <= time }
    }

    /// Whether the stack holds fewer cards than it may show at once.
    public var hasRoom: Bool { live.count < settings.max }

    /// Whether any of this drip's own cards is still to come or on screen. A drip that waits for its
    /// question takes other drips' cards in only while it does, so it can exit soon after the answer.
    public var holdsOwn: Bool { !waiting.isEmpty || live.contains(where: \.own) }

    /// Whether every one of this drip's own cards has come and gone, leaving included.
    public var ownCardsGone: Bool { waiting.isEmpty && !entries.contains(where: \.own) }

    /// Once this drip's own cards have all been answered, or have otherwise started to go, every
    /// card in the stack, top to bottom, as it is at `time`: where each is, what it has left and how
    /// far into leaving it is. Nil while an own card still shows or is still to come. A drip that
    /// asks a question hands these on to a background drip, so it exits with the answer in the
    /// moment it is given, and its card leaves and the cards it took in play out without it.
    public func handOff(at time: Double) -> [HandedCard]? {
        guard !holdsOwn else { return nil }
        return entries.map { entry in
            HandedCard(
                card: entry.card, top: entry.exit?.top ?? entry.animator.targetTop,
                remaining: max(entry.remaining, 0), isWaiting: entry.isWaiting,
                leaving: entry.exit.map { max(time - $0.time, 0) },
                glide: entry.exit == nil && entry.isShown ? entry.animator.glide(at: time) : [])
        }
    }

    /// Shows `handed`, laid out as `metrics`, at the bottom of the stack at `time`, as it was on
    /// screen when it was handed on: open where it was, gliding on as it was, with the time it had
    /// left, and as far into leaving as it was, with its fade cues when it is leaving. Then moves
    /// every card to its place.
    @discardableResult
    public func resume(_ handed: HandedCard, metrics: IslandMetrics, at time: Double) -> (entry: Entry, exit: IslandCues?) {
        var animator = IslandAnimator(metrics: metrics)
        animator.open(top: handed.top)
        animator.resume(handed.glide, to: handed.top, at: time)
        let entry = Entry(id: nextID, card: handed.card, own: false, metrics: metrics, animator: animator)
        nextID += 1
        entry.anchor = settings.mode == .chain ? live.last : nil
        entry.remaining = handed.remaining
        entry.isWaiting = handed.isWaiting
        entry.countdownFrom = time
        entries.append(entry)
        lastEntrance = time
        let exit = handed.leaving.flatMap { leave(entry, at: time - $0) }
        place(at: time)
        return (entry, exit)
    }

    /// This drip's next own card, taken off `waiting`, when there is room.
    public func nextOwn() -> Card? {
        guard hasRoom, let card = waiting.first else { return nil }
        waiting.removeFirst()
        return card
    }

    /// Where each card that holds a place in the stack sits: its capsule's top, from the notch down.
    func tops() -> [ObjectIdentifier: Double] {
        var tops: [ObjectIdentifier: Double] = [:]
        var top: Double?
        for entry in entries where !entry.isLeaving || entry.holdsPlaceUntil.isFinite {
            let at = top ?? entry.metrics.pillTop
            tops[ObjectIdentifier(entry)] = at
            top = at + entry.metrics.pillHeight + Self.gap
        }
        return tops
    }

    /// Moves every card but `incoming` to its place in the stack at `time`, unless the pointer is on
    /// it. Returns whether any card moved.
    @discardableResult
    func place(at time: Double, except incoming: Entry? = nil, with spring: Spring = IslandAnimator.settle) -> Bool {
        guard !hovering else {
            needsLayout = true
            return false
        }
        needsLayout = false
        let tops = tops()
        var moved = false
        for entry in live where entry !== incoming {
            guard let top = tops[ObjectIdentifier(entry)], abs(entry.animator.targetTop - top) > 0.25 else { continue }
            entry.animator.move(to: top, at: time, with: spring)
            moved = true
        }
        return moved
    }

    /// Drops `card`, laid out as `metrics`, into the stack at `time`: out of the bottom of the last
    /// card, or out of the notch once the cards under it have moved down out of its way. `decided`
    /// is when the stack chose to, for the spacing between entrances.
    @discardableResult
    public func enter(_ card: Card, metrics: IslandMetrics, own: Bool, decided: Double, at time: Double) -> Entry {
        let above = settings.mode == .chain ? live.last : nil
        let anchor = above.map { DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.metrics) }
        var animator = IslandAnimator(metrics: metrics, anchor: anchor)
        let entry = Entry(id: nextID, card: card, own: own, metrics: metrics, animator: animator)
        nextID += 1
        entry.anchor = above
        var delay = 0.0
        switch settings.mode {
        case .chain:
            entries.append(entry)
        case .push:
            let below = live.first
            entries.insert(entry, at: below.flatMap { first in entries.firstIndex { $0 === first } } ?? 0)
            if !hovering, let below {
                place(at: time, except: entry, with: IslandAnimator.makeRoom)
                delay = Self.delay(clearing: below.animator, for: animator, top: metrics.pillTop, at: time)
            }
        }
        let top = above.map { $0.animator.targetTop + $0.metrics.pillHeight + Self.gap } ?? metrics.pillTop
        let start = time + delay
        let cues = animator.enter(at: start, top: top)
        entry.animator = animator
        entry.phase = .entering(start: start, cues: cues)
        entry.countdownFrom = start + (cues.title.first ?? cues.sides) + 0.25
        lastEntrance = decided
        return entry
    }

    /// How long a drop coming out of the notch waits so it never touches `below` as that card moves
    /// down out of its way.
    static func delay(clearing below: IslandAnimator, for animator: IslandAnimator, top: Double, at time: Double) -> Double {
        func clears(after delay: Double) -> Bool {
            var trial = animator
            _ = trial.enter(at: time + delay, top: top)
            return stride(from: time, through: trial.end, by: 1.0 / 60).allSatisfy { t in
                let shape = trial.shape(at: t)
                // A few points: the new capsule's bounce overshoots into the gap for a moment.
                return shape.pillTop + shape.pillHeight <= below.shape(at: t).pillTop - 3
            }
        }
        // Waiting longer only ever helps, so the shortest wait that clears is found by halving.
        var low = 0.0, high = 0.6
        guard !clears(after: low) else { return 0 }
        guard clears(after: high) else { return high }
        while high - low > 0.01 {
            let middle = (low + high) / 2
            if clears(after: middle) { high = middle } else { low = middle }
        }
        return high
    }

    /// Takes `entry` back into the card above it, or into the notch, at `time`. Returns when its
    /// content fades out; nil when it was already leaving.
    @discardableResult
    public func leave(_ entry: Entry, at time: Double) -> IslandCues? {
        guard !entry.isLeaving else { return nil }
        let position = entries.firstIndex { $0 === entry } ?? 0
        let above = entries[..<position].last { !$0.isLeaving }
        entry.anchor = above
        let anchor = above.map { DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.metrics) }
        entry.exit = (time, entry.animator.shape(at: time).pillTop)
        let cues = entry.animator.exit(at: time, into: anchor)
        entry.holdsPlaceUntil = entry.animator.riseTime ?? time
        entry.phase = .leaving(until: entry.animator.end)
        // The cards that grew out of this one now hang from whatever is above it.
        for other in entries where other.anchor === entry { other.anchor = above }
        return cues
    }

    /// Shows `card`, laid out as `metrics`, in place of the one `entry` shows, at `time`: the capsule
    /// springs to the new card's size where it is, the cards below make room or close up, and its
    /// countdown restarts. With `reduced` motion the size changes at once.
    public func swap(_ entry: Entry, for card: Card, metrics: IslandMetrics, at time: Double, reduced: Bool) {
        entry.animator.resize(to: metrics, at: time)
        if reduced { entry.animator.open(top: entry.animator.targetTop) }
        entry.card = card
        entry.metrics = metrics
        entry.remaining = card.duration
        entry.isWaiting = card.waits
        entry.countdownFrom = time
        place(at: time)
    }

    /// The pointer came onto the stack or left it. Leaving gives every card a moment to read what was
    /// under the pointer before it goes. Returns whether that changed anything.
    @discardableResult
    public func hover(_ on: Bool) -> Bool {
        guard on != hovering else { return false }
        hovering = on
        if !on {
            for entry in live where entry.isShown { entry.remaining = max(entry.remaining, 1.5) }
        }
        return true
    }

    /// Moves the stack's clock to `time`, `elapsed` after the last step: cards finish entering, count
    /// down, leave when their time is up or they were dismissed, and are gone once their drop has
    /// merged; the cards below close the gaps. Changes it starts begin at `time + lead`.
    ///
    /// Cards that wait for you give way to other cards: the oldest when a card needs room, its own
    /// or `needsRoom` another drip's, and every card in the stack is waiting; all of them when
    /// `othersWaiting`, another drip waiting for the stack to finish. A question never gives way: it
    /// stays until it is answered, replaced or its wait limit runs out, other cards stack around it,
    /// and a card with no room waits for it.
    public func advance(
        to time: Double, elapsed: Double, lead: Double, needsRoom: Bool = false, othersWaiting: Bool = false
    ) -> Changes {
        var changes = Changes()
        var released = false
        let waitingCards = live.filter(\.isWaiting)
        let yielding = waitingCards.filter { !$0.card.waitsForAnswer }
        if othersWaiting {
            changes.stoppedWaiting = yielding
        } else if needsRoom || !waiting.isEmpty, !hasRoom, waitingCards.count == live.count,
                  let oldest = yielding.min(by: { $0.id < $1.id })
        {
            changes.stoppedWaiting = [oldest]
        }
        for entry in changes.stoppedWaiting {
            entry.isWaiting = false
            entry.remaining = min(entry.remaining, entry.card.seconds)
            entry.countdownFrom = max(entry.countdownFrom, time + lead)
        }
        for entry in entries {
            switch entry.phase {
            case let .entering(start, cues):
                let last = max(cues.sides, (cues.title + cues.detail).max() ?? 0) + 0.25
                if time - start >= last { entry.phase = .shown }
            case .shown:
                if !hovering, time >= entry.countdownFrom { entry.remaining -= elapsed }
                if entry.remaining <= 0 || entry.dismissed != nil, !isFilling(entry),
                   let cues = leave(entry, at: time + lead)
                {
                    changes.left.append((entry, cues, time + lead, entry.dismissed ?? false))
                }
            case .leaving:
                // Its drop has started to rise: the cards below can close the gap behind it.
                if entry.holdsPlaceUntil.isFinite, time >= entry.holdsPlaceUntil {
                    entry.holdsPlaceUntil = -.infinity
                    released = true
                }
            }
        }
        changes.gone = entries.filter { entry in
            if case let .leaving(until) = entry.phase { return time >= until + 0.02 || isSwallowed(entry, at: time) }
            return false
        }
        entries.removeAll { entry in changes.gone.contains { $0 === entry } }
        changes.moved = (released || needsLayout) && place(at: time + lead)
        return changes
    }

    /// Whether a leaving card's drop is still on its way into `entry`, which must then stay until it
    /// has merged: shrinking around it would uncover it.
    func isFilling(_ entry: Entry) -> Bool {
        entries.contains { $0.isLeaving && $0.anchor === entry }
    }

    /// Whether a leaving card's drop is hidden inside what it went back into, far enough in that
    /// taking it away leaves no trace on the outline.
    func isSwallowed(_ entry: Entry, at time: Double) -> Bool {
        let shape = entry.animator.shape(at: time)
        guard shape.pillWidth <= entry.metrics.dropSize + 1 else { return false }
        let depth = entry.metrics.blend / 2
        let bottom = entry.anchor.map {
            DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.metrics).bottom
        } ?? entry.metrics.notchHeight
        return shape.pillTop + shape.pillHeight <= bottom - depth
    }

    // MARK: The pointer

    /// The card under `point`, x from the notch's center and y down from the screen's top, among
    /// those still in the stack.
    public func entry(at point: IslandPoint, time: Double) -> Entry? {
        live.first { entry in
            let shape = entry.animator.shape(at: time)
            let left = -shape.pillWidth / 2 - 2, top = shape.pillTop - 2
            return point.x >= left && point.x < left + shape.pillWidth + 4
                && point.y >= top && point.y < top + shape.pillHeight + 4
        }
    }

    /// Whether `point`, as for `entry(at:time:)`, is on one of `entry`'s buttons as they are drawn at
    /// `time`.
    public func isOnButton(of entry: Entry, at point: IslandPoint, time: Double) -> Bool {
        button(of: entry, at: point, time: time) != nil
    }

    /// The button of `entry` under `point`, as for `entry(at:time:)`, as it is drawn at `time`: a
    /// question's no button on the left, its yes button on the right, split halfway across the gap
    /// between them. Nil off the buttons.
    public func button(of entry: Entry, at point: IslandPoint, time: Double) -> CardAnswer? {
        guard entry.card.action != nil else { return nil }
        let layout = entry.animator.content(for: entry.animator.shape(at: time))
        let half = layout.ringSize / 2 + 4
        guard abs(point.x - layout.ringCenter.x) <= half, abs(point.y - layout.ringCenter.y) <= half + 4 else {
            return nil
        }
        let metrics = entry.animator.metrics
        guard metrics.declineWidth > 0 else { return .yes }
        let split = layout.ringCenter.x - layout.ringSize / 2 + metrics.declineWidth + metrics.buttonGap / 2
        return point.x < split ? .no : .yes
    }

    // MARK: The outline

    /// The stack's outline as values, so it can be sampled away from the stack, on other threads.
    public var outline: StackOutline {
        StackOutline(cards: entries.map { entry in
            StackOutline.Card(
                animator: entry.animator, metrics: entry.metrics,
                anchor: entry.anchor.flatMap { anchor in entries.firstIndex { $0 === anchor } })
        })
    }
}

/// The notch and every card in a stack, each card melted into what it grows out of while it is close
/// enough. A drawing adds the notch's own shape, then each piece.
public struct StackOutline: Sendable {
    public struct Card: Sendable {
        public let animator: IslandAnimator
        public let metrics: IslandMetrics
        /// The card it grows out of, as an index into the same list; nil for the notch.
        public let anchor: Int?
    }

    public enum Piece: Sendable {
        /// A drop melted into the notch or a capsule above it: trace where the field crosses zero.
        case traced(DropletField)
        /// A capsule floating free.
        case capsule(IslandShape, IslandMetrics)
    }

    public let cards: [Card]

    /// The notch's sizes, for drawing the notch itself; nil for an empty stack.
    public var notch: IslandMetrics? { cards.first?.metrics }

    public func pieces(at time: Double) -> [Piece] {
        let shapes = cards.map { $0.animator.shape(at: time) }
        return cards.enumerated().map { index, card in
            let anchor = card.anchor.map { DropletAnchor.capsule(shapes[$0], metrics: cards[$0].metrics) }
            let field = DropletField(metrics: card.metrics, shape: shapes[index], anchor: anchor)
            return field.touchesNotch ? .traced(field) : .capsule(shapes[index], card.metrics)
        }
    }
}
