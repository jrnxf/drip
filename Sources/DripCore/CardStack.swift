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
        /// Whether a card grows out of the overflow drop as its drop starts to rise, so the cards
        /// below close up with that card, on the same spring and on the same step.
        var handsOver = false
        /// Set when the card should go as soon as nothing is still flowing into it; whether by a
        /// click on its button.
        public var dismissed: Bool?
        /// The button a click landed on, when `dismissed` is true: yes, or a question's no.
        public var answer: CardAnswer?
        /// When it started to leave, and its capsule's top then. The top moves on with its place
        /// while it still holds one.
        public internal(set) var exit: (time: Double, top: Double)?
        /// The top of the place it holds in the stack: where its capsule sits once nothing moves it.
        var top = 0.0
        /// When the springs of its own coming in have settled, or those of a card taking its place.
        /// A glide to close a gap does not count.
        var restsAt = -Double.infinity
        /// Whether it grew out of the overflow drop rather than out of the card above it.
        var outOfDrop = false
        /// Whether it dropped out of a card on its way out: its neck is drawn against that card's
        /// drop as the drop itself is drawn, melted into what it goes into.
        var outOfLeaving = false
        /// The moment on the stack's clock its countdown has been counted to.
        var countedTo = -Double.infinity

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

        /// Whether a newer card with the same id may take this card's place: it is on screen, and
        /// nothing has taken it away.
        var isSwappable: Bool { isShown && dismissed == nil }

        func prolong() {
            if isLeaving { phase = .leaving(until: animator.end) }
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
        /// Cards that waited for you and gave way to a card that needed their place: they leave, and
        /// wait in `tucked` to come back. They are in `left` too.
        public var tucked: [Entry] = []
        /// Whether the overflow drop formed, took a card in, ticked, moved, went back in or was gone.
        public var overflowChanged = false
        /// Cards on their way in whose content fades in later than they were given: a card that
        /// started inside the card before it as both grow out of the overflow drop, and that card.
        /// The cues in their `phase` and their `countdownFrom` are new.
        public var held: [Entry] = []

        public var isEmpty: Bool {
            left.isEmpty && gone.isEmpty && !moved && stoppedWaiting.isEmpty && tucked.isEmpty && !overflowChanged
                && held.isEmpty
        }
    }

    public let settings: StackSettings
    /// Top to bottom, leaving cards included.
    public internal(set) var entries: [Entry] = []
    /// This drip's own cards still to drop in.
    public private(set) var waiting: [Card]
    private(set) var lastEntrance = -Double.infinity
    /// When the last card to come in finished coming in.
    private var lastShown = -Double.infinity

    /// Notes that a card came in at `time`: the next waits out the spacing.
    func noteEntrance(at time: Double) {
        lastEntrance = time
    }
    /// While the pointer is on any card nothing new starts: every countdown stops, no card's time
    /// runs out, gaps stay open and new cards wait, so a card never slides out from under a click.
    /// What is already in the air lands: a drop that rises is swallowed, a card that drops in
    /// opens, a glide ends. Not for longer than `holdLimit` after the pointer last moved, so a
    /// pointer left resting on the stack never keeps it there.
    public private(set) var hovering = false
    /// When the pointer last moved on the stack, or came onto it. A still pointer that a card leaves
    /// from under and the next slides under does not count, so it never holds the stack again.
    private var pointerMovedAt = -Double.infinity
    /// Whether a card that waits for you and gives way to a card that needs its place goes back into
    /// the overflow drop, to come back once there is room, rather than counting down and leaving. A
    /// background drip's stack does; one that waits for its question's answer, which hands its
    /// cards on as they are when it is answered, does not.
    public var tucks = false
    /// Cards that waited for you and gave way to a card that needed their place, oldest first, with
    /// what they have left of their wait, whether each was this drip's own and the id of the entry
    /// that showed it: they wait in the overflow drop after every other card.
    public internal(set) var tucked: [(card: Card, own: Bool, entry: Int)] = []
    /// A change to the stack waits while the pointer is on it.
    private var needsLayout = false
    /// The moment the last step moved the clock to; nil before the first.
    private(set) var clock: Double?
    /// The furthest ahead anything looked since the last step: see `horizon`.
    private var reached = -Double.infinity
    var nextID = 1
    /// The overflow drop under the last card, counting the cards waiting for room; nil while none
    /// waits, and in a stack that is not given the cards waiting for it.
    public internal(set) var overflow: Overflow?
    /// Cards that started inside the card before it since the last step, each with that card and
    /// the moment it started: see `part`.
    var parting: [(entry: Entry, above: Entry, start: Double)] = []
    /// Every card waiting for this stack, oldest first: this drip's own, then other drips', as the
    /// last step was given them.
    public internal(set) var queued: [Card] = []
    /// The drawn width of a count on the overflow drop, at regular size, in the button's font.
    public var measureCount: (String) -> Double = { Double($0.count) * 7.5 }

    /// The gap between two cards in the stack.
    public static let gap: Double = 10
    /// The least time between two cards dropping in; a card also waits until the last is in.
    public static let entranceSpacing = 0.35
    /// Cards whose time is up within this of each other end together: neighbours among them leave
    /// together, in one motion, once the time of the last is up. Two frames of a 60 Hz screen: longer
    /// than the frame a countdown happens to start on, so cards meant to end together always do,
    /// and the longest a card whose time is up stays for a neighbour, too short to see its ring
    /// stand empty. A neighbour whose time is up later than that leaves on its own, at its moment.
    public static let roundWindow = 1.0 / 30
    /// The longest step the stack plans ahead for: three frames of a 60 Hz screen. A step tells how
    /// long the next one takes, and a step longer than this tells nothing: the main thread stalled,
    /// the screen slept or the page was hidden. A drawing whose every step is longer starts a leave
    /// late, by as much as its step is longer than this.
    public static let longestStep = 0.05
    /// The longest the stack holds still after the pointer last moved on it.
    public static let holdLimit = 5.0

    public init(settings: StackSettings, cards: [Card] = []) {
        self.settings = settings
        waiting = cards
    }

    /// The cards that are not leaving, top to bottom.
    public var live: [Entry] { entries.filter { !$0.isLeaving } }

    /// Whether enough time has passed for the next card to drop in. By default that is the least
    /// spacing and every card in, its drop landed and spread, which takes a card about a second.
    /// With the config's `stack_delay` it is that pause after the last card is fully in. Cards
    /// that glide to close a gap, and cards on their way out above, hold nothing back: a drop goes
    /// wherever the card it hangs from goes.
    private func entranceSpaced(at time: Double, starting start: Double) -> Bool {
        guard let delay = settings.delay else {
            return time - lastEntrance >= Self.entranceSpacing && live.allSatisfy { $0.restsAt <= time }
        }
        return start - lastShown >= delay
            && live.allSatisfy { entry in
                if case let .entering(begin, cues) = entry.phase { return begin + Self.entrance(cues) + delay <= start }
                return true
            }
    }

    /// How long a card takes to come in, from its drop starting to fall until its last line of text
    /// has faded in.
    static func entrance(_ cues: IslandCues) -> Double {
        max(cues.sides, (cues.title + cues.detail).max() ?? 0) + 0.25
    }

    /// Whether a card may drop in at `time`, or a newer card with the same id as one on screen may
    /// take its place: one at a time, once the last is in, and never while the pointer is on the
    /// stack. The overflow drop is at rest too, with nothing dripping into it. Nothing else holds
    /// a card back: it drops out of whatever is last in the stack, a card on its way out included,
    /// and no card dropping in holds a card whose time is up. `start` is when a card decided now
    /// starts to move, `time` by default. With `stack_delay` it is what counts, so the next drop
    /// starts on the frame the last card's text has faded in.
    public func isReady(at time: Double, starting start: Double? = nil) -> Bool {
        !hovering && entranceSpaced(at: time, starting: start ?? time)
            && overflow.map { $0.end <= time && !$0.peeking } ?? true
    }

    /// When every spring in the stack has settled, the overflow drop's and what drips into it
    /// included.
    public var end: Double {
        entries.map(\.animator.end).reduce(overflow?.end ?? 0, max)
    }

    /// This drip's own cards on screen with an id, which a newer drip's card with the same id takes
    /// the place of: shown, not leaving and not taken away. A stack that takes no cards in looks for
    /// those newer cards itself, as a drip that shows one card at a time does.
    public var replaceable: [Entry] { live.filter { $0.own && $0.card.id != nil && $0.isSwappable } }

    /// The card on screen that `card`, with the same id, takes the place of: shown, not leaving and
    /// not taken away, and able to swap. A card already taken away, as by a click or `drip dismiss`,
    /// is left to go, so a newer card never swaps into it only to go with it; it comes in as a card
    /// of its own instead.
    public func swapTarget(for card: Card) -> Entry? {
        guard let id = card.id else { return nil }
        return live.first { $0.card.id == id && $0.isSwappable && CardReplacement.canSwap($0.card, for: card) }
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
    ///
    /// Each card goes with its springs and with what it hangs from, as `HandedMotion`. A picture is
    /// its springs and nothing else, so the stack that takes the cards draws on what this one
    /// drew, whatever each card was doing: dropping in, gliding, or rising inside another drop.
    public func handOff(at time: Double) -> [HandedCard]? {
        guard !holdsOwn else { return nil }
        return entries.enumerated().map { index, entry in
            var entrance: HandedMotion.Entrance?
            if case let .entering(start, cues) = entry.phase { entrance = .init(start: start - time, cues: cues) }
            let above = entry.anchor.flatMap { anchor in entries[..<index].lastIndex { $0 === anchor } }
            let motion = HandedMotion(
                animator: entry.animator.shifted(by: -time), anchor: above.map { index - $0 }, entrance: entrance,
                place: entry.top, rises: entry.isLeaving && holdsPlace(entry) ? entry.holdsPlaceUntil - time : nil,
                countsIn: max(entry.countdownFrom - time, 0), restsAt: entry.restsAt > time ? entry.restsAt - time : nil,
                outOfDrop: entry.outOfDrop, outOfLeaving: entry.outOfLeaving,
                dismissed: entry.isLeaving ? nil : entry.dismissed)
            return HandedCard(
                card: entry.card, top: entry.exit?.top ?? entry.animator.targetTop,
                remaining: max(entry.remaining, 0), isWaiting: entry.isWaiting,
                leaving: entry.exit.map { max(time - $0.time, 0) },
                glide: entry.exit == nil && entry.isShown ? entry.animator.glide(at: time) : [], motion: motion)
        }
    }

    /// Shows `handed`, laid out as `metrics`, at the bottom of the stack at `time`, as it was on
    /// screen when it was handed on, with the time it had left, and returns its fade cues when it
    /// is leaving. Then moves every card to its place. Call it for each card handed on, top to
    /// bottom.
    ///
    /// With its `motion`, the card goes on from its own springs: it is drawn where it was, as fast
    /// as it was, and hangs from the card it hung from. Without, or laid out another way than the
    /// drip that handed it on laid it out, it shows open where it was, glides on as it was, and
    /// leaves from as far into leaving as it was, into the card above it that stays.
    @discardableResult
    public func resume(_ handed: HandedCard, metrics: IslandMetrics, at time: Double) -> (entry: Entry, exit: IslandCues?) {
        let count = entries.count
        let motion = handed.motion.flatMap { motion in
            motion.animator.metrics == metrics && (motion.anchor.map { $0 >= 1 && $0 <= count } ?? true) ? motion : nil
        }
        var animator = motion?.animator.shifted(by: time) ?? IslandAnimator(metrics: metrics)
        if motion == nil {
            animator.open(top: handed.top)
            animator.resume(handed.glide, to: handed.top, at: time)
        }
        let entry = Entry(id: nextID, card: handed.card, own: false, metrics: metrics, animator: animator)
        nextID += 1
        entry.remaining = handed.remaining
        entry.isWaiting = handed.isWaiting
        var exit: IslandCues?
        if let motion {
            entry.anchor = motion.anchor.map { entries[count - $0] }
            entry.top = motion.place
            entry.countdownFrom = time + motion.countsIn
            entry.restsAt = motion.restsAt.map { time + $0 } ?? -.infinity
            entry.outOfDrop = motion.outOfDrop
            entry.outOfLeaving = motion.outOfLeaving
            entry.dismissed = motion.dismissed
            if let leaving = handed.leaving {
                entry.exit = (time - leaving, handed.top)
                entry.holdsPlaceUntil = motion.rises.map { time + $0 } ?? -.infinity
                entry.phase = .leaving(until: animator.end)
                exit = animator.exitCues
            } else if let entrance = motion.entrance {
                entry.phase = .entering(start: time + entrance.start, cues: entrance.cues)
            }
            entries.append(entry)
        } else {
            entry.anchor = live.last
            entry.top = handed.top
            entry.countdownFrom = time
            entries.append(entry)
            exit = handed.leaving.flatMap { leave(entry, at: time - $0) }
        }
        noteEntrance(at: time)
        // The stack that handed it on moved its clock to this moment: the next step plans ahead
        // from here, as that stack would have.
        clock = clock ?? time
        place(at: time)
        return (entry, exit)
    }

    /// This drip's next own card, taken off `waiting`, when there is room.
    public func nextOwn() -> Card? {
        guard hasRoom, let card = waiting.first else { return nil }
        waiting.removeFirst()
        return card
    }

    /// The oldest card that gave way and waits to come back, taken off `tucked`, when there is room
    /// and no card of this drip's own waits first.
    public func nextTucked() -> (card: Card, own: Bool, entry: Int)? {
        guard hasRoom, waiting.isEmpty, !tucked.isEmpty else { return nil }
        return tucked.removeFirst()
    }

    /// What the stack takes in next, as `nextAdmission(adoptable:isReplaced:)` decides it. The
    /// `Int` is an index into the `adoptable` cards that call was given.
    public enum Admission {
        /// The adoptable card shows in place of the shown `Entry` with the same id.
        case swap(Entry, Int)
        /// The adoptable card drops in as a card of its own.
        case enter(Int)
        /// This drip's next own card drops in, taken with `nextOwn()`.
        case own
        /// This drip's next own card was replaced since it was queued: it is dropped with
        /// `dropWaiting(at: 0)`, and nothing else drops in this step.
        case skipOwn
        /// The oldest card that gave way comes back, taken with `nextTucked()`.
        case tucked
    }

    /// What drops into the stack next, one change at a time (call again after applying a
    /// `.swap`, which leaves the stack as it was): a newer drip's card with the same id as one on
    /// screen takes its place there; else the first `adoptable` card takes a place of its own when
    /// no card waits past a full stack; else this drip's next own card; else a card that gave way.
    /// `adoptable` is in the order the cards should come in, and `isReplaced` tells an own card a
    /// newer one has taken over. Call it while `isReady(at:)` holds, checked once before the first
    /// call.
    public func nextAdmission(adoptable: [Card], isReplaced: (Card) -> Bool = { _ in false }) -> Admission? {
        for (index, card) in adoptable.enumerated() {
            if let shown = swapTarget(for: card) { return .swap(shown, index) }
            guard overflow == nil, waiting.isEmpty, hasRoom else { break }
            return .enter(index)
        }
        guard overflow == nil else { return nil }
        if hasRoom, let own = waiting.first { return isReplaced(own) ? .skipOwn : .own }
        if adoptable.isEmpty, hasRoom, waiting.isEmpty, !tucked.isEmpty { return .tucked }
        return nil
    }

    /// What grows out of the overflow drop next: this drip's own card first, else the first
    /// `adoptable` card that does not show in place of one on screen, else a card that gave way.
    /// Cases as for `Admission`, with `.enter` the adopted card's index.
    public func nextRelease(adoptable: [Card], isReplaced: (Card) -> Bool = { _ in false }) -> Admission? {
        if hasRoom, let own = waiting.first { return isReplaced(own) ? .skipOwn : .own }
        if let index = adoptable.firstIndex(where: { !swapsInPlace($0) }) { return .enter(index) }
        if hasRoom, waiting.isEmpty, !tucked.isEmpty { return .tucked }
        return nil
    }

    /// Forgets the cards that gave way and wait to come back for which `drops` holds: a newer card
    /// with the same id took their place, or they were dismissed. Returns whether any went.
    @discardableResult
    public func dropTucked(where drops: (Card) -> Bool) -> Bool {
        let count = tucked.count
        tucked.removeAll { drops($0.card) }
        return tucked.count != count
    }

    /// Forgets this drip's own card still to drop in at `index` of `waiting`, and returns it.
    @discardableResult
    public func dropWaiting(at index: Int) -> Card? {
        guard waiting.indices.contains(index) else { return nil }
        return waiting.remove(at: index)
    }

    /// Forgets the card that gave way at `index` of `tucked`.
    public func dropTucked(at index: Int) {
        guard tucked.indices.contains(index) else { return }
        tucked.remove(at: index)
    }

    /// Forgets this drip's own cards still to drop in for which `drops` holds, as when they were
    /// dismissed before they showed. Returns the cards that went.
    @discardableResult
    public func dropWaiting(where drops: (Card) -> Bool) -> [Card] {
        let dropped = waiting.filter(drops)
        waiting.removeAll(where: drops)
        return dropped
    }

    /// Where each card that holds a place in the stack sits: its capsule's top, from the notch down.
    func tops() -> [ObjectIdentifier: Double] {
        var tops: [ObjectIdentifier: Double] = [:]
        var top: Double?
        for entry in entries where holdsPlace(entry) {
            let at = top ?? entry.metrics.pillTop
            tops[ObjectIdentifier(entry)] = at
            top = at + entry.metrics.pillHeight + Self.gap
        }
        return tops
    }

    /// Whether `entry` holds a place in the stack: every card that stays, and a card on its way out
    /// until its drop starts to rise.
    func holdsPlace(_ entry: Entry) -> Bool {
        !entry.isLeaving || entry.holdsPlaceUntil.isFinite
    }

    /// Moves every card to its place in the stack from `time`, unless the pointer is on it. Returns
    /// whether any card moved.
    ///
    /// Places are springs that add up, and that is what keeps a drop on the card it belongs to
    /// while the stack moves. Whatever moves a card is added to everything that hangs from it or
    /// goes into it, from the same moment and on the same spring, so the way a drop moves against
    /// its card is the one curve it was given when it started, wherever the card is by then.
    @discardableResult
    func place(at time: Double, with spring: Spring = IslandAnimator.settle) -> Bool {
        guard !hovering else {
            needsLayout = true
            return false
        }
        needsLayout = false
        let tops = tops()
        var moves: [ObjectIdentifier: Double] = [:]
        for entry in entries {
            guard let top = tops[ObjectIdentifier(entry)], abs(top - entry.top) > 0.25 else { continue }
            // A card still to start growing out of the overflow drop is on its way to its place.
            if entry.outOfDrop, case let .entering(start, _) = entry.phase, start > time { continue }
            let change = top - entry.top
            entry.top = top
            entry.exit?.top += change
            moves[ObjectIdentifier(entry)] = change
            shift(entry, by: change, with: spring, at: time)
            // A card on its way out glides with its place while it gathers, and still rises to
            // where it was going.
            if entry.isLeaving, let rise = entry.animator.riseTime {
                shift(entry, by: -change, with: IslandAnimator.rise, at: max(rise, time))
            }
            overflow?.shiftSeeds(from: entry.id, by: change, with: spring, at: time)
        }
        // What goes into a card goes where the card goes.
        for drop in drops {
            guard let anchor = drop.anchor, !anchor.isLeaving, let change = moves[ObjectIdentifier(anchor)] else {
                continue
            }
            follow(drop, by: change, with: spring, at: time)
        }
        return !moves.isEmpty
    }

    /// Every drop on its way in: each card on its way out, top to bottom, then the overflow drop
    /// going back in.
    private var drops: [any StackPiece] {
        let cards: [any StackPiece] = entries.filter(\.isLeaving)
        return cards + (overflow.flatMap { $0.isLeaving ? [$0] : nil } ?? [])
    }

    /// Springs `piece` on by `change` from `time`, and with it whatever goes into its drop: a drop
    /// inside a drop is one drop.
    private func shift(_ piece: any StackPiece, by change: Double, with spring: Spring, at time: Double) {
        piece.animator.shift(by: change, at: time, with: spring)
        guard piece.isLeaving else { return }
        piece.prolong()
        for rider in drops where rider.anchor === piece { follow(rider, by: change, with: spring, at: time) }
    }

    /// Carries a move of what `drop` goes into over to it. Once it has started to rise the two
    /// move as one. While it still gathers in its place only its aim moves: from the moment it
    /// rises, on the spring it rises on.
    private func follow(_ drop: any StackPiece, by change: Double, with spring: Spring, at time: Double) {
        if let rise = drop.animator.riseTime, time < rise {
            shift(drop, by: change, with: IslandAnimator.rise, at: rise)
        } else {
            shift(drop, by: change, with: spring, at: time)
        }
    }

    /// Drops `card`, laid out as `metrics`, into the stack at `time`: out of the bottom of the last
    /// card, wherever that card is and however it moves, or out of the notch into an empty stack.
    /// `decided` is when the stack chose to, for the spacing between entrances.
    ///
    /// The last card may be on its way out. The new card then drops out of that card as it is, and
    /// falls from it into its own place, under the last card that holds one, on the same curve as
    /// out of a card that stays. Out of the capsule that still gathers in its place, it is as out
    /// of a card that starts to leave a moment later: it lands under that place, and closes up as
    /// the drop rises. Out of the drop that rises, it moves with the drop, and its neck lets go
    /// once it is drawn clear of that drop and of what the drop goes into. `advance` keeps that
    /// drop, hidden, for as long as the neck is drawn.
    @discardableResult
    public func enter(_ card: Card, metrics: IslandMetrics, own: Bool, decided: Double, at time: Double) -> Entry {
        let above = entries.last
        let leaving = above.flatMap { $0.isLeaving ? $0 : nil }
        // Its drop rises: by the clock, or as `advance` already planned it a step ahead, when the
        // stack closed up. Either way the new card moves with the drop from the moment it rises.
        let rise = leaving?.animator.riseTime ?? .infinity
        let rising = leaving.flatMap { rise <= time || !holdsPlace($0) ? $0 : nil }
        var animator = leaving.map { IslandAnimator(metrics: metrics, outOf: $0.animator, at: rising == nil ? time : max(time, rise)) }
            ?? above.map { IslandAnimator(metrics: metrics, under: $0.animator) } ?? IslandAnimator(metrics: metrics)
        let entry = Entry(id: nextID, card: card, own: own, metrics: metrics, animator: animator)
        nextID += 1
        entry.anchor = above
        entry.outOfLeaving = leaving != nil
        // Under the last card that holds a place: the card it hangs from, unless that one rises.
        let holder = leaving == nil ? above : entries.last { holdsPlace($0) && $0 !== rising }
        entries.append(entry)
        let top = holder.map { $0.top + $0.metrics.pillHeight + Self.gap } ?? metrics.pillTop
        let cues = animator.enter(
            at: time, top: top, outOf: rising?.animator, into: rising.flatMap(container(of:))?.animator)
        entry.animator = animator
        entry.top = top
        entry.restsAt = animator.end
        entry.phase = .entering(start: time, cues: cues)
        entry.countdownFrom = time + (cues.title.first ?? cues.sides) + 0.25
        noteEntrance(at: decided)
        return entry
    }

    /// Takes `entry` back into the card above it that stays, or into the notch, at `time`: into
    /// where that card is heading, and `place` keeps the drop on it if it moves again. Returns when
    /// its content fades out; nil when it was already leaving.
    ///
    /// A drop still on its way into `entry`, the overflow drop included, goes into the drop `entry`
    /// gathers into instead: to its middle as it gathers, then up with it, as one drop.
    @discardableResult
    public func leave(_ entry: Entry, at time: Double) -> IslandCues? {
        guard !entry.isLeaving else { return nil }
        let position = entries.firstIndex { $0 === entry } ?? 0
        let above = entries[..<position].last { !$0.isLeaving }
        let riders = drops.filter { $0.anchor === entry }
        entry.anchor = above
        let middle = entry.animator.targetCenter
        entry.exit = (time, entry.animator.shape(at: time).pillTop)
        let cues = entry.animator.exit(at: time, into: above?.animator.resting)
        let rise = entry.animator.riseTime ?? time
        let lift = entry.animator.targetCenter - middle
        entry.holdsPlaceUntil = rise
        entry.phase = .leaving(until: entry.animator.end)
        let gather = time + IslandAnimator.gatherDelay
        for rider in riders {
            let start = max(gather, rider.animator.riseTime ?? gather)
            shift(rider, by: middle - rider.animator.targetCenter, with: IslandAnimator.gather, at: start)
            rider.animator.merge(at: start)
            follow(rider, by: lift, with: IslandAnimator.rise, at: rise)
        }
        // The cards that grew out of this one hang from whatever is above it once their necks have
        // pinched off: see `rehang`.
        return cues
    }

    /// Hangs every card that stays from the card above it that stays, once it no longer melts into
    /// a card on its way out: a neck is drawn against the card it hangs from, so it changes hands
    /// only when there is no neck left to draw.
    private func rehang(at time: Double) {
        for (index, entry) in entries.enumerated() where !entry.isLeaving {
            let above = entries[..<index].last { !$0.isLeaving }
            guard entry.anchor !== above else { continue }
            if let anchor = entry.anchor, anchor.isLeaving, entry.animator.melts(at: time) { continue }
            entry.anchor = above
        }
    }

    /// Shows `card`, laid out as `metrics`, in place of the one `entry` shows, at `time`: the capsule
    /// springs to the new card's size where it is, the cards below make room or close up, and its
    /// countdown restarts. With `reduced` motion the size changes at once.
    public func swap(_ entry: Entry, for card: Card, metrics: IslandMetrics, at time: Double, reduced: Bool) {
        let settled = entry.animator.resize(to: metrics, at: time)
        if reduced { entry.animator.open(top: entry.animator.targetTop) }
        entry.card = card
        entry.metrics = metrics
        entry.remaining = card.duration
        entry.isWaiting = card.waits
        entry.countdownFrom = time
        // Once the springs of this change have settled, and those of its own coming in. A glide
        // still in flight does not count.
        entry.restsAt = reduced ? time : max(entry.restsAt, settled)
        place(at: time)
    }

    /// The pointer is on the stack, or off it, at `time`; `moved` when it moved since the last call.
    /// The stack holds while the pointer is on it, until it has rested there for `holdLimit`. Letting
    /// go gives every card a moment to read what was under the pointer before it goes. Returns
    /// whether that changed anything.
    @discardableResult
    public func hover(_ on: Bool, moved: Bool = true, at time: Double = 0) -> Bool {
        if on, moved { pointerMovedAt = time }
        let holds = on && time - pointerMovedAt < Self.holdLimit
        guard holds != hovering else { return false }
        // The hold starts and ends at `time`, not on the step before it.
        count(to: time)
        hovering = holds
        if !holds {
            for entry in live where entry.isShown { entry.remaining = max(entry.remaining, 1.5) }
        }
        return true
    }

    /// Counts every countdown down to `time`. Each runs on the clock from the moment it starts, not
    /// from the step a card is first seen on, so a card's time is up at the moment its ring is
    /// empty. The time the pointer holds the stack does not count.
    private func count(to time: Double) {
        for entry in entries {
            if !hovering, entry.isShown, time > max(entry.countedTo, entry.countdownFrom) {
                entry.remaining -= time - max(entry.countedTo, entry.countdownFrom)
            }
            if hovering || entry.isShown { entry.countedTo = max(entry.countedTo, time) }
        }
    }

    /// The moment the time of `entry`, a card that shows, is up, on the stack's clock at `time`.
    private func due(_ entry: Entry, at time: Double) -> Double {
        max(time, entry.countdownFrom) + entry.remaining
    }

    /// The cards whose time is up by `horizon`, as the rounds they leave in, each with the moment
    /// it leaves: the moment the time of its last card is up.
    ///
    /// A round is a block of neighbours: cards next to each other on screen once this step is done.
    /// A card on its way out is not between its neighbours, and nor is one taken away, which goes
    /// on this step. The cards whose time is up within `roundWindow` of the first end together,
    /// and the topmost of them opens the round. It takes in the cards right above and below it
    /// that end with it: one block, with no card that stays between two that go. Every other card
    /// whose time is up opens a round of its own the same way, so two blocks apart from each other
    /// leave in the same step, each into what is above it. The rounds compare the cards' countdowns
    /// with each other, not with the frame the step falls on, so the same cards always go together,
    /// in the same order.
    private func rounds(at time: Double, by horizon: Double) -> [(cards: [Entry], time: Double)] {
        let row = entries.filter { !$0.isLeaving && !($0.isShown && $0.dismissed != nil) }
        var taken = Set<ObjectIdentifier>()
        var rounds: [(cards: [Entry], time: Double)] = []
        while true {
            let open = row.indices.filter { row[$0].isShown && !taken.contains(ObjectIdentifier(row[$0])) }
            guard let soonest = open.map({ due(row[$0], at: time) }).min(), soonest <= horizon else { return rounds }
            let closes = soonest + Self.roundWindow
            let joins = { (index: Int) in open.contains(index) && self.due(row[index], at: time) <= closes }
            guard let seed = open.first(where: joins) else { return rounds }
            var first = seed, last = seed
            while first > 0, joins(first - 1) { first -= 1 }
            while last + 1 < row.count, joins(last + 1) { last += 1 }
            let cards = Array(row[first...last])
            for card in cards { taken.insert(ObjectIdentifier(card)) }
            // Not before the time of every card in it is up, so none goes before its ring is empty.
            let ends = cards.map { due($0, at: time) }.max() ?? soonest
            if ends <= horizon { rounds.append((cards, ends)) }
        }
    }

    /// Moves the stack's clock to `time`: cards finish entering, count down, leave when their time
    /// is up or they were dismissed, and are gone once their drop has merged; the cards below close
    /// the gaps. Changes it starts begin at `time + lead`.
    ///
    /// A card leaves the moment its time is up, whatever the rest of the stack is doing: other cards
    /// may still drop in, glide or leave. Cards whose time is up together leave together, in one
    /// motion: see `rounds`. What can be known ahead is planned ahead, as far as `horizon` reaches:
    /// a card whose time is up within the next step, and no sooner than `lead`, starts to leave at
    /// that moment exactly, not on the step after it, so its ring is empty as its text starts to
    /// fade, and the cards below a drop close up from the moment it rises. A card taken away on
    /// purpose goes at once.
    ///
    /// Given `queued`, other drips' cards waiting for this stack, oldest first, the overflow drop
    /// counts them and this drip's own cards still to come while the stack is full; without, it never
    /// shows. It leaves out this drip's own cards `replaced` says a newer card with the same id
    /// replaced, as they never show.
    ///
    /// Cards that wait for you give way to other cards: the oldest when a card needs room, its own
    /// or `needsRoom` another drip's, and every card in the stack is waiting; all of them when
    /// `othersWaiting`, another drip waiting for the stack to finish. A question never gives way: it
    /// stays until it is answered, replaced or its wait limit runs out, other cards stack around it,
    /// and a card with no room waits for it.
    public func advance(
        to time: Double, lead: Double, needsRoom: Bool = false, othersWaiting: Bool = false,
        queued others: [Card]? = nil, replaced: [Card] = []
    ) -> Changes {
        var changes = Changes()
        let waitingCards = live.filter(\.isWaiting)
        let yielding = waitingCards.filter { !$0.card.waitsForAnswer }
        if othersWaiting {
            changes.stoppedWaiting = yielding
        } else if needsRoom || !waiting.isEmpty, !hasRoom, waitingCards.count == live.count,
                  let oldest = yielding.min(by: { $0.id < $1.id })
        {
            if tucks, oldest.dismissed == nil {
                // Back into the overflow drop, with what it has left of its wait, after the cards
                // already waiting there.
                var card = oldest.card
                card.waitLimit = max(oldest.remaining, 1)
                tucked.append((card, oldest.own, oldest.id))
                oldest.dismissed = false
                changes.tucked = [oldest]
            } else if !tucks {
                changes.stoppedWaiting = [oldest]
            }
        }
        for entry in changes.stoppedWaiting {
            entry.isWaiting = false
            entry.remaining = min(entry.remaining, entry.card.seconds)
            entry.countdownFrom = max(entry.countdownFrom, time + lead)
        }
        for entry in entries {
            guard case let .entering(start, cues) = entry.phase, time - start >= Self.entrance(cues) else { continue }
            entry.phase = .shown
            lastShown = max(lastShown, start + Self.entrance(cues))
        }
        count(to: time)
        let horizon = horizon(at: time, starting: time + lead)
        var leaves: [(entry: Entry, time: Double)] = entries
            .filter { $0.isShown && $0.dismissed != nil }.map { ($0, time + lead) }
        // The pointer holds every card whose time is up: none starts to leave under it.
        if !hovering {
            for round in rounds(at: time, by: horizon) {
                leaves += round.cards.map { ($0, max(round.time, time + lead)) }
            }
        }
        for entry in entries {
            if let leaving = leaves.first(where: { $0.entry === entry }), let cues = leave(entry, at: leaving.time) {
                changes.left.append((entry, cues, leaving.time, entry.dismissed ?? false))
            }
        }
        // A card leaving gathers into a round drop in place and only then rises. The cards below
        // close the gap from the moment its drop starts to rise, so none runs into it, together
        // with the card growing out of the overflow drop when one does: `release` chose this step
        // for it, and looked no further ahead than this step does.
        let rising = entries.filter { $0.isLeaving && holdsPlace($0) && $0.holdsPlaceUntil <= horizon }
        for rise in Set(rising.map(\.holdsPlaceUntil)).sorted() {
            var handingOver = false
            for entry in rising where entry.holdsPlaceUntil == rise {
                handingOver = handingOver || entry.handsOver
                entry.holdsPlaceUntil = -.infinity
            }
            let moved = place(at: max(rise, time + lead), with: handingOver ? Self.handOver : IslandAnimator.settle)
            changes.moved = changes.moved || moved
        }
        if needsLayout, place(at: time + lead) { changes.moved = true }
        // Now that every card is on its way to its place.
        changes.held = part()
        // A drop is gone once it is hidden inside what it went back into. Not while anything still
        // hangs from it or is on its way into it: that is drawn against it, so it stays, hidden,
        // until the last of them has let go or is hidden too.
        var gone = entries.filter { $0.isLeaving && (time >= $0.animator.end + 0.02 || isSwallowed($0, at: time)) }
        while let held = gone.firstIndex(where: { entry in
            entries.contains { other in
                other.anchor === entry
                    && (other.isLeaving ? !gone.contains { $0 === other } : other.animator.melts(at: time))
            } || (overflow.map { $0.anchor === entry && ($0.isLeaving || $0.animator.melts(at: time)) } ?? false)
        }) {
            gone.remove(at: held)
        }
        changes.gone = gone
        entries.removeAll { entry in gone.contains { $0 === entry } }
        rehang(at: time)
        if let others, advanceOverflow(others, replaced: replaced, to: time, start: time + lead) {
            changes.overflowChanged = true
        }
        clock = time
        reached = -.infinity
        return changes
    }

    /// As far ahead as the step to `time` plans, when its changes start at `start`: from `start`,
    /// as long again as the step took. The next step is likely as long, so what is due before it
    /// is planned on this one, for its exact moment. A step tells nothing past `longestStep`.
    ///
    /// A step has one horizon. What is decided before `advance`, as a card to grow out of the
    /// overflow drop, asks here, and `advance` then looks at least as far: so the place that card
    /// was promised is free on the same step, whenever the drawing read its clock and whatever its
    /// lead is by then.
    func horizon(at time: Double, starting start: Double) -> Double {
        let step = clock.map { min(max(time - $0, 0), Self.longestStep) } ?? 0
        reached = max(reached, start + step)
        return reached
    }

    /// What a drop on its way in ends up in: the card that stays at the top of the chain of drops
    /// it rises with, or nil for the notch.
    func container(of drop: any StackPiece) -> Entry? {
        var into = drop.anchor
        while let drop = into, drop.isLeaving { into = drop.anchor }
        return into
    }

    /// Whether a drop on its way in is hidden inside what it ends up in, far enough in that taking
    /// it away leaves no trace on the outline.
    func isSwallowed(_ drop: any StackPiece, at time: Double) -> Bool {
        let shape = drop.animator.shape(at: time)
        guard shape.pillWidth <= drop.metrics.dropSize + 1 else { return false }
        let depth = drop.metrics.blend / 2
        let bottom = container(of: drop).map {
            DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.metrics).bottom
        } ?? drop.metrics.notchHeight
        return shape.pillTop + shape.pillHeight <= bottom - depth
    }

    // MARK: The pointer

    /// The card under `point`, x from the notch's center and y down from the screen's top, among
    /// those still in the stack: on its capsule as it is drawn at `time`, or within 2 points of it.
    public func entry(at point: IslandPoint, time: Double) -> Entry? {
        live.first { $0.animator.shape(at: time).contains(point, metrics: $0.metrics, margin: 2) }
    }

    /// The card under `point`, as for `entry(at:time:)`, that takes clicks. A card `--activate none`
    /// leaves without a button neither holds the stack nor is taken away by a click. The pointer
    /// passes through to the window below everywhere but on such a card.
    public func clickableEntry(at point: IslandPoint, time: Double) -> Entry? {
        entry(at: point, time: time).flatMap { $0.card.isClickable ? $0 : nil }
    }

    /// Whether `point`, as for `entry(at:time:)`, is on `entry`'s close mark as it is drawn at `time`:
    /// the left end of its capsule, its padding and its icon, where a pointer on the card shows a ×
    /// in place of the icon. A click there takes the card away without bringing anything forward.
    /// Never for a card without an icon.
    public func isOnClose(of entry: Entry, at point: IslandPoint, time: Double) -> Bool {
        guard entry.metrics.hasIcon else { return false }
        let shape = entry.animator.shape(at: time)
        let layout = entry.animator.content(for: shape)
        let left = -shape.pillWidth / 2
        return point.x >= left - 2 && point.x <= layout.iconCenter.x + layout.iconSize / 2 + 6 * entry.metrics.scale
            && point.y >= shape.pillTop - 2 && point.y <= shape.pillTop + shape.pillHeight + 2
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
        let index = { (entry: Entry?) in entry.flatMap { entry in self.entries.firstIndex { $0 === entry } } }
        return StackOutline(
            cards: entries.map { entry in
                StackOutline.Card(
                    animator: entry.animator, metrics: entry.metrics, anchor: index(entry.anchor),
                    isLeaving: entry.isLeaving, outOfLeaving: entry.outOfLeaving)
            },
            overflow: overflow.map { overflow in
                StackOutline.Drop(
                    animator: overflow.animator, anchor: index(overflow.anchor),
                    seeds: overflow.seeds.map { seed in (seed, entries.firstIndex { $0.id == seed.source }) })
            })
    }
}

/// A piece of a stack that moves on its own springs: a card, or the overflow drop. On its way out
/// it is a drop that goes into `anchor`, and what moves `anchor` moves it too.
protocol StackPiece: AnyObject {
    var metrics: IslandMetrics { get }
    var animator: IslandAnimator { get set }
    /// What it melts into; nil for the notch.
    var anchor: CardStack.Entry? { get }
    var isLeaving: Bool { get }
    /// Keeps it until its springs have settled, after a change to them on its way out.
    func prolong()
}

extension CardStack.Entry: StackPiece {}
extension CardStack.Overflow: StackPiece {}

/// The notch and every card in a stack, each card melted into what it grows out of while it is close
/// enough. A drawing adds the notch's own shape, then each piece.
public struct StackOutline: Sendable {
    public struct Card: Sendable {
        public let animator: IslandAnimator
        public let metrics: IslandMetrics
        /// The card it grows out of, as an index into the same list; nil for the notch.
        public let anchor: Int?
        /// Whether it is on its way out: a drop, melted into what it goes into.
        public let isLeaving: Bool
        /// Whether it dropped out of a card on its way out.
        public let outOfLeaving: Bool
    }

    public enum Piece: Sendable {
        /// A drop melted into the notch or a capsule above it: trace where the field crosses zero.
        case traced(DropletField)
        /// A capsule floating free.
        case capsule(IslandShape, IslandMetrics)
    }

    /// The overflow drop, and the cards dripping into it.
    public struct Drop: Sendable {
        public let animator: IslandAnimator
        /// What it melts into, as an index into `cards`; nil for nothing.
        public let anchor: Int?
        /// Each seed, with the card it drips out of as an index into `cards`; nil for one gone.
        public let seeds: [(seed: CardStack.Seed, source: Int?)]
    }

    public let cards: [Card]
    public let overflow: Drop?

    public init(cards: [Card], overflow: Drop? = nil) {
        self.cards = cards
        self.overflow = overflow
    }

    /// The notch's sizes, for drawing the notch itself; nil for an empty stack.
    public var notch: IslandMetrics? { cards.first?.metrics }

    public func pieces(at time: Double) -> [Piece] {
        let shapes = cards.map { $0.animator.shape(at: time) }
        return cards.enumerated().map { index, card in
            let anchor = card.anchor.map { DropletAnchor.capsule(shapes[$0], metrics: cards[$0].metrics) }
            let hosts = card.anchor.map { self.hosts(under: $0, for: shapes[index], outOfLeaving: card.outOfLeaving, shapes) } ?? []
            let field = DropletField(metrics: card.metrics, shape: shapes[index], anchor: anchor, hosts: hosts)
            return field.touchesNotch ? .traced(field) : .capsule(shapes[index], card.metrics)
        }
    }

    /// What `shape`, which hangs from the card at `above`, is drawn against besides that card, when
    /// that card is itself drawn melted into something. Two kinds of drop need it, as only they
    /// show where their anchor melts:
    /// - A drop out of a drop: it is drawn against that drop as the drop is drawn itself.
    /// - A drop as wide as its anchor, as a card that grows out of the overflow drop beside the
    ///   card before it: its melt runs up the anchor's round ends, to where the anchor's own melt is.
    private func hosts(under above: Int, for shape: IslandShape, outOfLeaving: Bool, _ shapes: [IslandShape]) -> [DropletField.Host] {
        if outOfLeaving, cards[above].isLeaving { return hosts(of: above, shapes) }
        let anchor = DropletAnchor.capsule(shapes[above], metrics: cards[above].metrics)
        return DropletField.spills(shape, over: anchor) && melts(above, shapes) ? hosts(of: above, shapes) : []
    }

    /// Whether the card at `index` is drawn melted into what it hangs from or goes into.
    private func melts(_ index: Int, _ shapes: [IslandShape]) -> Bool {
        let card = cards[index]
        let into = card.anchor.map { DropletAnchor.capsule(shapes[$0], metrics: cards[$0].metrics) }
        return DropletField(metrics: card.metrics, shape: shapes[index], anchor: into).touchesNotch
    }

    /// What the drop at `index` goes into, outermost first: the notch or the card that stays, then
    /// each drop between, each with how strongly the next melts into it as `pieces(at:)` draws it.
    /// A card that stays and still melts into what it hangs from counts as a drop between.
    private func hosts(of index: Int, _ shapes: [IslandShape]) -> [DropletField.Host] {
        let card = cards[index]
        let into = card.anchor.map { DropletAnchor.capsule(shapes[$0], metrics: cards[$0].metrics) }
        let host = DropletField.Host(anchor: into ?? .notch(card.metrics), blend: melts(index, shapes) ? shapes[index].blend : 0)
        guard let above = card.anchor, cards[above].isLeaving || melts(above, shapes) else { return [host] }
        return hosts(of: above, shapes) + [host]
    }

    /// The overflow drop, melted into the card it hangs from while close enough, and each card
    /// dripping into it: melted into the card it leaves while close, into the drop it joins once
    /// close, and a plain round drop between. A drawing adds these after `pieces(at:)`.
    public func overflowPieces(at time: Double) -> [Piece] {
        guard let drop = overflow else { return [] }
        let shapes = cards.map { $0.animator.shape(at: time) }
        let capsule = { (index: Int) in DropletAnchor.capsule(shapes[index], metrics: cards[index].metrics) }
        let metrics = drop.animator.metrics
        let shape = drop.animator.shape(at: time)
        var pieces: [Piece] = []
        let hosts = drop.anchor.map { self.hosts(under: $0, for: shape, outOfLeaving: false, shapes) } ?? []
        if let anchor = drop.anchor.map(capsule),
           case let field = DropletField(metrics: metrics, shape: shape, anchor: anchor, hosts: hosts), field.touchesNotch
        {
            pieces.append(.traced(field))
        } else {
            pieces.append(.capsule(shape, metrics))
        }
        let into = DropletAnchor.capsule(shape, metrics: metrics)
        for (seed, source) in drop.seeds where time >= seed.start && time < seed.end {
            var melted = false
            let leaving = seed.leavingBlend(at: time)
            if let from = source.map(capsule), leaving > 0.01,
               case let field = DropletField(metrics: metrics, shape: seed.shape(at: time, blend: leaving), anchor: from),
               field.touchesNotch
            {
                pieces.append(.traced(field))
                melted = true
            }
            let joining = seed.joiningBlend(at: time)
            let joined = seed.shape(at: time, blend: joining)
            if joining > 0.01, joined.pillTop + joined.pillHeight > into.centerY - into.halfHeight - joining {
                // Traced from above the seed, which falls into the drop from above.
                pieces.append(.traced(DropletField(
                    metrics: metrics, shape: joined, anchor: into, traceTop: joined.pillTop - joining - 1)))
                melted = true
            }
            if !melted { pieces.append(.capsule(seed.shape(at: time, blend: 0), metrics)) }
        }
        return pieces
    }
}
