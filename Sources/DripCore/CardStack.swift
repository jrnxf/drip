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
        /// Whether the next card grows out of the overflow drop as its drop starts to rise, so the cards
        /// below close up with that card, on the same spring.
        var handsOver = false
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

        /// Whether a newer card with the same id may take this card's place: it is on screen, and
        /// nothing has taken it away.
        var isSwappable: Bool { isShown && dismissed == nil }
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

        public var isEmpty: Bool {
            left.isEmpty && gone.isEmpty && !moved && stoppedWaiting.isEmpty && tucked.isEmpty && !overflowChanged
        }
    }

    public let settings: StackSettings
    /// Top to bottom, leaving cards included.
    public internal(set) var entries: [Entry] = []
    /// This drip's own cards still to drop in.
    public private(set) var waiting: [Card]
    private(set) var lastEntrance = -Double.infinity
    /// Whether a card has left since the last one came in, with a card still waiting to come in. A
    /// card whose time is up leaves before the next drops in, but after one has left, a card waiting
    /// comes in first: with cards running out as fast as they come in, as a stack of six does at
    /// the default time, the next would otherwise wait until every card on screen had gone.
    private var leftSinceEntrance = false
    /// When the last card to come in finished coming in.
    private var lastShown = -Double.infinity
    /// When the round of cards leaving together closes, on the stack's clock; nil with no round
    /// open. See `advance`.
    private var roundEnds: Double?
    /// The card that opened the round: the round is the block of cards around it.
    private var roundSeed: Entry?

    /// Notes that a card came in at `time`: the next waits out the spacing, and owes the cards due
    /// to leave nothing.
    func noteEntrance(at time: Double) {
        lastEntrance = time
        leftSinceEntrance = false
    }
    /// While the pointer is on any card nothing moves: every countdown stops, gaps stay open and new
    /// cards wait, so a card never slides out from under a click. Not for longer than `holdLimit`
    /// after the pointer last moved, so a pointer left resting on the stack never keeps it there.
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
    var nextID = 1
    /// The overflow drop under the last card, counting the cards waiting for room; nil while none
    /// waits, and in a stack that is not given the cards waiting for it.
    public internal(set) var overflow: Overflow?
    /// Every card waiting for this stack, oldest first: this drip's own, then other drips', as the
    /// last step was given them.
    public internal(set) var queued: [Card] = []
    /// The drawn width of a count on the overflow drop, at regular size, in the button's font.
    public var measureCount: (String) -> Double = { Double($0.count) * 7.5 }

    /// The gap between two cards in the stack.
    public static let gap: Double = 10
    /// The least time between two cards dropping in; a card also waits until the stack is still.
    public static let entranceSpacing = 0.35
    /// How long a round of cards leaving together stays open after its first card's time is up:
    /// cards whose time is up within it leave with that card. Far longer than a frame, so cards
    /// meant to end together always do, whatever frame each countdown started on.
    public static let roundWindow = 0.25
    /// Cards whose time is up within this of each other are tied: the topmost goes first. A few
    /// frames, so the frame each countdown started on never picks the order.
    public static let tie = 0.05
    /// About how long a card dropping in keeps the stack from rest, and so keeps a card whose time
    /// is up from leaving.
    public static let entranceSettling = 0.95
    /// The longest the stack holds still after the pointer last moved on it.
    public static let holdLimit = 5.0

    public init(settings: StackSettings, cards: [Card] = []) {
        self.settings = settings
        waiting = cards
    }

    /// The cards that are not leaving, top to bottom.
    public var live: [Entry] { entries.filter { !$0.isLeaving } }

    /// Whether enough time has passed for the next card to drop in. By default that is the least
    /// spacing and a stack at rest, which takes a card about a second to settle. With the config's
    /// `stack_delay` it is that pause after the last card is fully in, whatever the cards below are
    /// still settling; a card still coming in, and a card on its way out, still have to finish.
    private func entranceSpaced(at time: Double, starting start: Double) -> Bool {
        guard let delay = settings.delay else {
            return time - lastEntrance >= Self.entranceSpacing && entries.allSatisfy { $0.animator.end <= time }
        }
        return start - lastShown >= delay
            && entries.allSatisfy { entry in
                if case let .entering(begin, cues) = entry.phase { return begin + Self.entrance(cues) + delay <= start }
                return !entry.isLeaving || entry.animator.end <= time
            }
    }

    /// How long a card takes to come in, from its drop starting to fall until its last line of text
    /// has faded in.
    static func entrance(_ cues: IslandCues) -> Double {
        max(cues.sides, (cues.title + cues.detail).max() ?? 0) + 0.25
    }

    /// Whether a card may drop in at `time`: one at a time, into a stack at rest, so a new drop
    /// never shoves cards still settling, and never while the pointer is on the stack. The overflow
    /// drop is at rest too, with nothing dripping into it. A card whose time is up leaves first, and
    /// so does one whose time would be up before a card dropping in now had settled: that card would
    /// otherwise stay, its ring empty, until the new one was in. Unless a card has left since the
    /// last came in and another waits: that one comes in first. `start`
    /// is when a card decided now starts to move, `time` by default; with `stack_delay` it is what
    /// counts, so the next drop starts on the frame the last card's text has faded in.
    public func isReady(at time: Double, starting start: Double? = nil) -> Bool {
        isStill(at: time, starting: start ?? time)
            && (leftSinceEntrance || !hasCardDue(within: (start ?? time) - time + Self.entranceSettling))
    }

    /// Whether a newer card with the same id as one on screen may take its place at `time`: as for a
    /// card dropping in, but held back only by a card whose time is already up. A swap takes no new
    /// place, so it never keeps a card from leaving once its ring is empty.
    public func canSwap(at time: Double) -> Bool {
        isStill(at: time, starting: time) && !hasCardDue(within: 0)
    }

    private func isStill(at time: Double, starting start: Double) -> Bool {
        !hovering && entranceSpaced(at: time, starting: start)
            && overflow.map { $0.end <= time && !$0.peeking } ?? true
    }

    private func hasCardDue(within seconds: Double) -> Bool {
        entries.contains { $0.isShown && $0.remaining <= seconds && $0.dismissed == nil }
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
        entry.anchor = live.last
        entry.remaining = handed.remaining
        entry.isWaiting = handed.isWaiting
        entry.countdownFrom = time
        entries.append(entry)
        let exit = handed.leaving.flatMap { leave(entry, at: time - $0) }
        noteEntrance(at: time)
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

    /// What drops into a stack at rest next, one change at a time (call again after applying a
    /// `.swap`, which leaves the stack as it was): a newer drip's card with the same id as one on
    /// screen takes its place there; else the first `adoptable` card takes a place of its own when
    /// no card waits past a full stack; else this drip's next own card; else a card that gave way.
    /// `adoptable` is in the order the cards should come in, and `isReplaced` tells an own card a
    /// newer one has taken over. `swapping` is `canSwap(at:)` and `entering` is `isReady(at:)`, both
    /// checked once before the first call, so a card that swaps in place is never held back by a card
    /// that is only about to run out.
    public func nextAdmission(
        adoptable: [Card], isReplaced: (Card) -> Bool = { _ in false }, swapping: Bool = true, entering: Bool = true
    ) -> Admission? {
        for (index, card) in adoptable.enumerated() {
            if let shown = swapTarget(for: card) {
                if swapping { return .swap(shown, index) }
                break
            }
            guard entering, overflow == nil, waiting.isEmpty, hasRoom else { break }
            return .enter(index)
        }
        guard entering, overflow == nil else { return nil }
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
    func place(
        at time: Double, except incoming: Entry? = nil, with spring: Spring = IslandAnimator.settle, evenHovering: Bool = false
    ) -> Bool {
        guard !hovering || evenHovering else {
            needsLayout = true
            return false
        }
        needsLayout = false
        let tops = tops()
        var moved = false
        for entry in live where entry !== incoming {
            // A card still to start growing out of the overflow drop is on its way to its place.
            if case let .entering(start, _) = entry.phase, start > time { continue }
            guard let top = tops[ObjectIdentifier(entry)], abs(entry.animator.targetTop - top) > 0.25 else { continue }
            entry.animator.move(to: top, at: time, with: spring)
            moved = true
        }
        return moved
    }

    /// Drops `card`, laid out as `metrics`, into the stack at `time`: out of the bottom of the last
    /// card, or out of the notch into an empty stack. `decided`
    /// is when the stack chose to, for the spacing between entrances.
    @discardableResult
    public func enter(_ card: Card, metrics: IslandMetrics, own: Bool, decided: Double, at time: Double) -> Entry {
        let above = live.last
        let anchor = above.map { DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.metrics) }
        var animator = IslandAnimator(metrics: metrics, anchor: anchor)
        let entry = Entry(id: nextID, card: card, own: own, metrics: metrics, animator: animator)
        nextID += 1
        entry.anchor = above
        entries.append(entry)
        let top = above.map { $0.animator.targetTop + $0.metrics.pillHeight + Self.gap } ?? metrics.pillTop
        let cues = animator.enter(at: time, top: top)
        entry.animator = animator
        entry.phase = .entering(start: time, cues: cues)
        entry.countdownFrom = time + (cues.title.first ?? cues.sides) + 0.25
        noteEntrance(at: decided)
        return entry
    }

    /// Takes `entry` back into the card above it that stays, or into the notch, at `time`. Returns
    /// when its content fades out; nil when it was already leaving.
    @discardableResult
    public func leave(_ entry: Entry, at time: Double) -> IslandCues? {
        guard !entry.isLeaving else { return nil }
        leftSinceEntrance = true
        let position = entries.firstIndex { $0 === entry } ?? 0
        let above = entries[..<position].last { !$0.isLeaving }
        entry.anchor = above
        let anchor = entry.anchor.map { DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.metrics) }
        entry.exit = (time, entry.animator.shape(at: time).pillTop)
        let cues = entry.animator.exit(at: time, into: anchor)
        entry.holdsPlaceUntil = entry.animator.riseTime ?? time
        entry.phase = .leaving(until: entry.animator.end)
        // The cards that grew out of this one now hang from whatever is above it.
        for other in entries where other.anchor === entry { other.anchor = above }
        if let overflow, overflow.anchor === entry { overflow.anchor = above }
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

    /// The pointer is on the stack, or off it, at `time`; `moved` when it moved since the last call.
    /// The stack holds while the pointer is on it, until it has rested there for `holdLimit`. Letting
    /// go gives every card a moment to read what was under the pointer before it goes. Returns
    /// whether that changed anything.
    @discardableResult
    public func hover(_ on: Bool, moved: Bool = true, at time: Double = 0) -> Bool {
        if on, moved { pointerMovedAt = time }
        let holds = on && time - pointerMovedAt < Self.holdLimit
        guard holds != hovering else { return false }
        hovering = holds
        if !holds {
            for entry in live where entry.isShown { entry.remaining = max(entry.remaining, 1.5) }
        }
        return true
    }

    /// Moves the stack's clock to `time`, `elapsed` after the last step: cards finish entering, count
    /// down, leave when their time is up or they were dismissed, and are gone once their drop has
    /// merged; the cards below close the gaps. Changes it starts begin at `time + lead`.
    ///
    /// Cards whose time is up leave from a stack at rest, and those whose time is up together leave
    /// together, in one motion. The first card whose time is up opens a round that closes
    /// `roundWindow` later. The round starts from that card, the topmost when the time of several is
    /// up within `tie` of each other, and keeps it until the round's cards leave. It takes in the
    /// cards right above and below it whose time is up before the round closes: one block, so no
    /// card that stays is between two that go. They leave once the time of the last of them is up,
    /// so none goes before its ring is empty. The round compares the cards' countdowns with each other, not with the frame the step falls on,
    /// so the same cards always go together, in the same order.
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
        to time: Double, elapsed: Double, lead: Double, needsRoom: Bool = false, othersWaiting: Bool = false,
        queued others: [Card]? = nil, replaced: [Card] = []
    ) -> Changes {
        var changes = Changes()
        var released = false
        var releasedAt = Double.infinity
        var handingOver = false
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
        for entry in entries where entry.isShown {
            if !hovering, time >= entry.countdownFrom { entry.remaining -= elapsed }
        }
        // A card whose time is up while the overflow drop is still forming, or a card still growing
        // out of it, waits the moment until the drop is ready, so the next card grows out of it in
        // one motion with this one leaving rather than after it.
        let dropBusy = !hovering && overflow.map { drop in
            switch drop.phase {
            case .forming, .releasing: return !drop.peeking
            case .shown, .leaving: return false
            }
        } ?? false
        let goes = { (entry: Entry) in
            entry.isShown && (entry.remaining <= 0 || entry.dismissed != nil) && !self.isFilling(entry)
                && !(dropBusy && entry.dismissed == nil)
        }
        // Cards whose time is up leave only from a stack at rest: once the last drop has gone and the
        // cards below have closed up behind it, so each leaves from its place. A card taken away on
        // purpose goes at once.
        //
        // A leave could instead start while other cards still move, which would end every wait with
        // an empty ring. A drop is aimed at where its anchor is when it starts, though, so a card
        // dropping out of one that leaves, or rising into one that moves, comes apart. That needs
        // drops that follow an anchor as it moves: see docs/development.md, "Leaves in a moving stack".
        let atRest = entries.allSatisfy { $0.animator.end <= time }
        let timedOut = { (entry: Entry) in goes(entry) && entry.dismissed == nil }
        var round: [Entry] = []
        if atRest, entries.contains(where: timedOut) {
            let closes = roundEnds ?? time + Self.roundWindow
            roundEnds = closes
            let joins = { (entry: Entry) in
                entry.isShown && entry.dismissed == nil && entry.remaining <= closes - time
            }
            if roundSeed.map({ seed in !entries.contains { $0 === seed && joins($0) } }) ?? true {
                let soonest = entries.filter(joins).map(\.remaining).min() ?? 0
                roundSeed = entries.first { joins($0) && $0.remaining <= soonest + Self.tie }
            }
            if let seed = entries.firstIndex(where: { $0 === roundSeed }) {
                var first = seed, last = seed
                while first > 0, joins(entries[first - 1]) { first -= 1 }
                while last + 1 < entries.count, joins(entries[last + 1]) { last += 1 }
                // Not before the time of every card in it is up.
                if entries[first...last].allSatisfy({ $0.remaining <= 0 }) {
                    round = Array(entries[first...last])
                    roundEnds = nil
                    roundSeed = nil
                }
            }
        } else {
            roundEnds = nil
            roundSeed = nil
        }
        // A card leaving gathers into a round drop in place and only then rises, as it does without
        // an overflow drop. The next card waiting grows out of the drop, the cards below close up
        // and the count rolls together as the gathered drop starts to rise, so none runs into it.
        let due = entries.filter { entry in
            goes(entry) && (entry.dismissed != nil || round.contains { $0 === entry })
        }
        for entry in entries {
            switch entry.phase {
            case let .entering(start, cues):
                let last = Self.entrance(cues)
                if time - start >= last {
                    entry.phase = .shown
                    lastShown = max(lastShown, start + last)
                }
            case .shown:
                if due.contains(where: { $0 === entry }), let cues = leave(entry, at: time + lead) {
                    changes.left.append((entry, cues, time + lead, entry.dismissed ?? false))
                }
            case .leaving:
                // Its drop has started to rise: the cards below can close the gap behind it.
                if entry.holdsPlaceUntil.isFinite, time >= entry.holdsPlaceUntil {
                    releasedAt = min(releasedAt, entry.holdsPlaceUntil)
                    handingOver = handingOver || entry.handsOver
                    entry.holdsPlaceUntil = -.infinity
                    released = true
                }
            }
        }
        changes.gone = entries.filter { entry in
            if case let .leaving(until) = entry.phase {
                return time >= until + 0.02 || isSwallowed(entry, at: time)
            }
            return false
        }
        entries.removeAll { entry in changes.gone.contains { $0 === entry } }
        // The cards below close the gap from the moment its drop started to rise, together with the
        // card growing out of the overflow drop when one does, even under the pointer, as that card
        // grows into its place regardless.
        changes.moved = (released || needsLayout)
            && place(
                at: released ? releasedAt : time + lead, with: handingOver ? Self.handOver : IslandAnimator.settle,
                evenHovering: handingOver)
        if let others {
            changes.overflowChanged = advanceOverflow(others, replaced: replaced, to: time, start: time + lead)
        }
        // With no card waiting to come in, a leave owes nothing, so a card arriving later does not
        // jump ahead of one that is due.
        if queued.isEmpty { leftSinceEntrance = false }
        return changes
    }

    /// Whether a leaving card's drop, or the overflow drop, is still on its way into `entry`, which
    /// must then stay until it has merged: shrinking around it would uncover it.
    func isFilling(_ entry: Entry) -> Bool {
        entries.contains { $0.isLeaving && $0.anchor === entry } || (overflow.map { $0.isLeaving && $0.anchor === entry } ?? false)
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
                StackOutline.Card(animator: entry.animator, metrics: entry.metrics, anchor: index(entry.anchor))
            },
            overflow: overflow.map { overflow in
                StackOutline.Drop(
                    animator: overflow.animator, anchor: index(overflow.anchor),
                    seeds: overflow.seeds.map { seed in (seed, entries.firstIndex { $0.id == seed.source }) })
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
            let field = DropletField(metrics: card.metrics, shape: shapes[index], anchor: anchor)
            return field.touchesNotch ? .traced(field) : .capsule(shapes[index], card.metrics)
        }
    }

    /// The overflow drop, melted into the card it hangs from while close enough, and each card
    /// dripping into it: melted into the card it leaves while close, into the drop it joins once
    /// close, and a plain round drop between. A drawing adds these after `pieces(at:)`.
    public func overflowPieces(at time: Double) -> [Piece] {
        guard let drop = overflow else { return [] }
        let capsule = { (index: Int) in
            DropletAnchor.capsule(cards[index].animator.shape(at: time), metrics: cards[index].metrics)
        }
        let metrics = drop.animator.metrics
        let shape = drop.animator.shape(at: time)
        var pieces: [Piece] = []
        if let anchor = drop.anchor.map(capsule),
           case let field = DropletField(metrics: metrics, shape: shape, anchor: anchor), field.touchesNotch
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
