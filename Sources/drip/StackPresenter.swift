#if canImport(AppKit)
import AppKit
import DripCore
import QuartzCore

/// Shows several cards at the notch at once, one below another, each grown out of the notch or out
/// of the card above it, and adopts newer drips' cards from the queue while it shows: a
/// background drip's stack always, and a stack that waits for its question's answer while that
/// shows, so other cards stack around the question instead of waiting for it.
///
/// The motion is played the way a single card's is: every spring is sampled 240 times a second into
/// keyframe animations, which Core Animation plays off the main thread. Whenever the stack changes,
/// a card coming, going or moving up, everything is sampled again from that moment, and since the
/// springs keep their velocity through a change, nothing jumps. While the pointer is on any card,
/// nothing moves: every countdown stops, gaps stay open and new cards wait, so a card never slides
/// out from under a click.
///
/// Where the cards sit, when they come and go and what they go back into is `CardStack`'s, which the
/// web page follows too; this draws it.
final class StackPresenter: CardPresenting {
    /// What draws one card of the stack.
    private final class Drawing {
        var layers: IslandLayers
        var sound: CardSound?
        /// The card this one replaced in place, fading out on top of it until `retiringUntil`.
        var retiring: IslandLayers?
        var retiringUntil = -Double.infinity

        init(layers: IslandLayers) {
            self.layers = layers
        }
    }

    private let stack: CardStack
    /// By `CardStack.Entry.id`.
    private var drawings: [Int: Drawing] = [:]
    private let notch: NotchGeometry
    private let console: Console
    /// Whether this is a background drip's stack, which reports nothing about its cards: it adopts
    /// every newer drip's card it can, and a watchdog makes sure it ends.
    private let adopting: Bool
    /// Whether one of this drip's own cards is a question that waits for its answer.
    private let asks: Bool
    /// Whether one of this drip's own cards asks a question: the drip then exits as soon as its own
    /// cards have been answered or have started to go, and hands the rest on.
    private let questions: Bool
    /// A background drip waiting, while a question shows, to take the stack on once it is answered.
    private var standby: BackgroundDrip.Spawned?
    /// What another drip's stack handed on, to show as it is there when this one starts.
    private var handed: StackHandOff?
    /// Whether no background drip could take the cards this stack took in, so it shows them itself.
    private var handOffFailed = false
    private var panel: IslandPanel?
    private var view: IslandView?
    private let container = CALayer()
    /// The notch and every card's capsule, melted together where a drop is forming or returning.
    private let liquid = CAShapeLayer()
    private var size = CGSize.zero
    private var scale: CGFloat = 2
    private var timer: Timer?
    private var started: CFTimeInterval = 0
    /// Whether the stack has put its first frames on screen; until then its clock holds while it
    /// samples, so the first drop never starts partway through.
    private var playing = false
    /// How long after it is decided a change starts moving: `minimumLead`, or longer when sampling
    /// the springs took longer than that last time, as in a debug build or on a busy Mac.
    private var lead = minimumLead
    private var lastTick: Double = 0
    private var lastAdoptionCheck = -Double.infinity
    /// When the stack last looked for dismissals and a pause.
    private var lastRequestCheck = -Double.infinity
    /// Whether the last look at the queue found cards to adopt.
    private var foundAdoptable = false
    /// Whether the last look at the queue found a card to adopt with no room for it.
    private var needsRoom = false
    /// Whether the last look at the queue found a newer drip waiting that the stack cannot adopt.
    private var othersWaiting = false
    /// This drip's own cards still to come that the last look at the queue found a newer card with
    /// the same id replaced, which the overflow drop leaves out of its count.
    private var replacedOwn: [Card] = []
    /// Newer drips' cards the stack can take in, oldest first, as the last look at the queue found
    /// them, less those taken in since.
    private var others: [(ticket: String, index: Int, card: Card)] = []
    /// The overflow drop's count and titles, while it shows, and for a moment after the drop itself
    /// spread into the last card waiting.
    private var overflowLayers: OverflowLayers?
    /// The overflow drop `overflowLayers` draws.
    private var drawnOverflow: CardStack.Overflow?
    /// The card the drop spread into, which the count's last number rolls out over, until when.
    private var spreadInto: (entry: Int, until: Double)?
    private var onFinish: ((Bool) -> Void)?
    /// When each card on screen came, in seconds since 1970, by `CardStack.Entry.id`: a dismissal
    /// asked for later leaves it.
    private var arrivals: [Int: Double] = [:]
    /// When this drip's own cards were queued, in seconds since 1970.
    private let queuedAt = CardQueue.queuedAt
    /// Where the pointer was at the last tick, to tell a resting pointer from one that moves.
    private var lastPointer: CGPoint?
    /// Whether the cursor is the pointing hand, over a card.
    private var pointing = false
    /// Whether the cards were put away for the pause that holds now, to show once it ends.
    private var putAway = false

    /// Keyframes per second when sampling the springs, as for a single card.
    private static let framesPerSecond = 240.0
    /// The least time after it is decided a change starts moving. Sampling the springs takes the
    /// main thread a moment, and the keyframes start at the moment of the decision, so a change that
    /// started at once would lose its first frames; until it starts, the samples carry on where the
    /// stack was already heading.
    private static let minimumLead = 0.06
    /// The longest `lead`, so a very slow sample never holds a change back for long.
    private static let maximumLead = 0.5

    /// A stack for `card` and the cards that follow it in `rest`, which it takes; nil when stacking
    /// is off or motion is reduced. `settings` given replace those of `stack` and `DRIP_STACK`.
    static func make(
        for card: Card, rest: inout ArraySlice<Card>, adopting: Bool, settings: StackSettings?,
        console: Console
    ) -> StackPresenter? {
        guard let settings = settings ?? StackSettings.current(environment: ProcessInfo.processInfo.environment),
              CardPresenters.motion(for: card) == .full,
              let screen = CardPresenters.targetScreen()
        else { return nil }
        let cards = [card] + rest
        rest.removeAll()
        return StackPresenter(
            cards: cards, settings: settings, notch: NotchGeometry.island(on: screen), adopting: adopting,
            console: console)
    }

    private init(cards: [Card], settings: StackSettings, notch: NotchGeometry, adopting: Bool, console: Console) {
        stack = CardStack(settings: settings, cards: cards)
        // A background drip's card that waits for you and gives way goes back into the overflow drop
        // to come back; one that waits for its question's answer hands its cards on as they are.
        stack.tucks = adopting
        self.notch = notch
        self.adopting = adopting
        asks = cards.contains(where: \.waitsForAnswer)
        questions = cards.contains(where: \.asksQuestion)
        self.console = console
        stack.measureCount = OverflowLayers.countWidth
    }

    /// A background drip's stack for the cards another drip's stack handed on; nil without a screen.
    static func resume(_ handOff: StackHandOff, console: Console) -> StackPresenter? {
        guard let screen = CardPresenters.targetScreen() else { return nil }
        let presenter = StackPresenter(
            cards: [], settings: handOff.settings, notch: NotchGeometry.island(on: screen), adopting: true,
            console: console)
        presenter.handed = handOff
        return presenter
    }

    var canReplace: Bool { false }
    func replace(with card: Card) {}
    /// The stack's cards give way on their own, as `CardStack` decides.
    func stopWaiting() {}

    /// Takes every card away without bringing anything forward.
    func dismiss() {
        for entry in stack.live { dismiss(entry) }
    }

    func start(onFinish: @escaping (Bool) -> Void) {
        self.onFinish = onFinish
        scale = CardPresenters.targetScreen()?.backingScaleFactor ?? 2
        // Room for the overflow drop under the last card, and its overshoot.
        size = CGSize(
            width: CGFloat(CardMetrics.maxWidth) + 40,
            height: notch.height + CGFloat(stack.settings.max) * 170 + 100)
        let frame = NSRect(
            x: (notch.midX - size.width / 2).rounded(), y: notch.top - size.height, width: size.width,
            height: size.height)
        let panel = IslandPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let view = IslandView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.onClick = { [weak self] click in self?.click(click) }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)

        container.frame = CGRect(origin: .zero, size: size)
        liquid.frame = container.bounds
        liquid.isGeometryFlipped = true
        liquid.fillColor = NSColor.black.cgColor
        liquid.contentsScale = scale
        container.addSublayer(liquid)
        view.layer?.addSublayer(container)
        panel.contentView = view
        panel.setFrame(frame, display: false)
        self.panel = panel
        self.view = view
        panel.orderFrontRegardless()

        started = CACurrentMediaTime()
        if let handed { resumeHanded(handed) }
        if questions, !adopting { standby = BackgroundDrip.spawn(handingOff: true) }
        // Countdowns, the pointer and the queue; the motion itself runs in Core Animation. The timer
        // keeps the stack alive until `finish` stops it.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [self] _ in tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    // MARK: The stack

    private var now: Double { CACurrentMediaTime() - started }
    private var hovering: Bool { stack.hovering }

    /// Samples every card's springs from `start` until they settle, and plays them. The samples are
    /// independent, so they are taken on every core at once; a card already at rest by `start` gets
    /// no keyframes.
    private func replan(from start: Double) {
        let sampling = CACurrentMediaTime()
        let entries = stack.entries
        let end = max(stack.end, start + 0.05)
        let count = Int(((end - start) * Self.framesPerSecond).rounded(.up)) + 1
        let outline = stack.outline
        let cards = entries.map(\.animator)
        let drawings = entries.map { self.drawings[$0.id]! }
        let layers = drawings.map(\.layers)
        let retiring = drawings.map(\.retiring)
        let moving = entries.map { $0.animator.end > start }
        let centerX = size.width / 2
        var paths = [CGPath?](repeating: nil, count: count)
        var frames = [[IslandLayers.Frame?]](repeating: [IslandLayers.Frame?](repeating: nil, count: count), count: cards.count)
        paths.withUnsafeMutableBufferPointer { paths in
            DispatchQueue.concurrentPerform(iterations: count) { index in
                let time = start + (end - start) * Double(index) / Double(count - 1)
                paths[index] = Self.path(at: time, outline: outline, centerX: centerX)
            }
        }
        for (card, layer) in zip(cards.indices, layers) where moving[card] {
            frames[card].withUnsafeMutableBufferPointer { samples in
                DispatchQueue.concurrentPerform(iterations: count) { index in
                    let time = start + (end - start) * Double(index) / Double(count - 1)
                    let shape = cards[card].shape(at: time)
                    samples[index] = layer.frame(shape, layout: cards[card].content(for: shape), withPath: false)
                }
            }
        }
        // A card replaced in place keeps to the capsule springing to the new card's size as it fades.
        var retiringFrames = [[IslandLayers.Frame]](repeating: [], count: cards.count)
        for card in cards.indices where moving[card] {
            guard let old = retiring[card] else { continue }
            retiringFrames[card] = (0..<count).map { index in
                let time = start + (end - start) * Double(index) / Double(count - 1)
                let shape = cards[card].shape(at: time)
                return old.frame(shape, layout: cards[card].content(for: shape, metrics: old.metrics), withPath: false)
            }
        }
        // The overflow drop's count rides the drop, or the card the drop spread into.
        var overflowFrames: [OverflowLayers.Frame] = []
        if let layers = overflowLayers {
            let spread = spreadInto.flatMap { spread in entries.first { $0.id == spread.entry } }
            if let animator = stack.overflow?.animator ?? spread?.animator {
                let metrics = stack.overflow?.animator.metrics ?? spread?.metrics ?? animator.metrics
                overflowFrames = (0..<count).map { index in
                    let time = start + (end - start) * Double(index) / Double(count - 1)
                    return layers.frame(animator.shape(at: time), metrics: metrics)
                }
            }
        }
        let cost = CACurrentMediaTime() - sampling
        lead = min(max(Self.minimumLead, cost * 1.5), Self.maximumLead)
        if !playing {
            // Nothing is on screen yet: the clock waits for the samples instead of skipping ahead.
            started += max(CACurrentMediaTime() - (started + start), 0)
            playing = true
        }
        let begin = started + start
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let values = paths.compactMap { $0 }
        liquid.path = values.last
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = values
        animation.duration = end - start
        animation.calculationMode = .discrete
        animation.beginTime = begin
        liquid.add(animation, forKey: "stack")
        for (card, layer) in zip(cards.indices, layers) {
            if moving[card] {
                layer.play(frames[card].compactMap { $0 }, duration: end - start, begin: begin)
                if let old = retiring[card] { old.play(retiringFrames[card], duration: end - start, begin: begin) }
            } else {
                let shape = cards[card].shape(at: start)
                layer.apply(layer.frame(shape, layout: cards[card].content(for: shape), withPath: false))
            }
        }
        overflowLayers?.play(overflowFrames, duration: end - start, begin: begin)
        CATransaction.commit()
    }

    /// The notch and every card at `time`, each card melted into what it grows out of while it is
    /// close enough.
    private static func path(at time: Double, outline: StackOutline, centerX: CGFloat) -> CGPath {
        let path = CGMutablePath()
        if let metrics = outline.notch {
            IslandPath.addNotch(to: path, metrics: metrics, centerX: centerX)
        }
        for piece in outline.pieces(at: time) + outline.overflowPieces(at: time) {
            switch piece {
            case let .traced(field):
                IslandPath.addTraced(field, to: path, centerX: centerX)
            case let .capsule(shape, metrics):
                IslandPath.addCapsule(shape, metrics: metrics, to: path, centerX: centerX)
            }
        }
        return path
    }

    /// A card's icon, ring and text, hanging from the top of the screen and centered on the notch;
    /// the stack draws its outline.
    private func makeLayers(for card: Card) -> IslandLayers {
        let layers = IslandLayers(card: card, notch: notch, scale: scale, console: console)
        layers.shape.isHidden = true
        if liquid.mask == nil {
            liquid.mask = IslandPath.notchMask(size: size, metrics: layers.metrics, centerX: size.width / 2, scale: scale)
        }
        layers.root.frame = CGRect(
            x: (size.width - layers.size.width) / 2, y: size.height - layers.size.height,
            width: layers.size.width, height: layers.size.height)
        return layers
    }

    /// Drops `card` into the stack: out of the bottom of the last card, or out of the notch once the
    /// cards under it have moved down out of its way.
    private func enter(_ card: Card, own: Bool) {
        let decided = now
        let layers = makeLayers(for: card)
        let entry = stack.enter(card, metrics: layers.metrics, own: own, decided: decided, at: decided + lead)
        show(entry, layers: layers, decided: decided)
    }

    /// Grows the next card waiting out of the overflow drop: this drip's own first, then the oldest
    /// newer drip's that does not show in place of a card on screen.
    private func release() {
        let card: Card
        let own: Bool
        if let next = stack.nextOwn() {
            // Replaced since it was queued: the drop's count goes down instead.
            if CardQueue.isReplaced(next) { return }
            card = next
            own = true
        } else if let index = others.firstIndex(where: { !stack.swapsInPlace($0.card) }) {
            let found = others.remove(at: index)
            CardQueue.adopt(index: found.index, in: found.ticket)
            if adopting { BackgroundWatchdog.extend(by: found.card.duration + 60) }
            card = found.card
            own = false
        } else if let tucked = stack.nextTucked() {
            // A card that gave way comes back once the cards that needed its place have had theirs.
            card = tucked.card
            own = tucked.own
        } else {
            return
        }
        let decided = now
        let layers = makeLayers(for: card)
        guard let release = stack.release(card, metrics: layers.metrics, own: own, at: decided + lead) else { return }
        if release.last, let overflowLayers {
            // The drop itself spreads into the card, and its last number rolls out over it.
            spreadInto = (release.entry.id, decided + lead + 0.3)
            overflowLayers.rollOut(from: release.count, at: started + decided + lead)
        }
        show(release.entry, layers: layers, decided: decided)
    }

    /// Draws `entry`, which `layers` lay out, as it drops in or grows out of the overflow drop,
    /// decided at `decided`: its content fades in on its cues, its countdown starts, and its sound
    /// plays as it first shows.
    private func show(_ entry: CardStack.Entry, layers: IslandLayers, decided: Double) {
        let card = entry.card
        let drawing = Drawing(layers: layers)
        drawings[entry.id] = drawing
        arrivals[entry.id] = arrivals[entry.id] ?? Date().timeIntervalSince1970
        guard case let .entering(start, cues) = entry.phase else { return }
        // Without actions: a change to the container's sublayers would otherwise crossfade the
        // whole stack.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.addSublayer(layers.root)
        CATransaction.commit()
        // First, since the first plan may move the clock.
        replan(from: decided)
        layers.fade(cues, into: true, at: started + start)
        if entry.isWaiting {
            layers.hold(pinging: true, at: started + entry.countdownFrom)
        } else {
            layers.drain(over: card.seconds, at: started + entry.countdownFrom)
        }
        // The sound and VoiceOver's announcement land as the drop first shows.
        drawing.sound = CardSound(card.sound, console: console)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(start - now, 0) + 0.05) {
            drawing.sound?.play()
            CardPresenters.announce(card)
        }
        updateAccessibility()
    }

    /// Shows the cards another drip's stack handed on where they were, as they were: no drop, no
    /// sound and no announcement, each counting down what it had left, and one that was leaving as
    /// far into it, all as they are by now. Then tells that drip, so its stack can go.
    private func resumeHanded(_ handOff: StackHandOff) {
        let decided = now
        var resumed: [(entry: CardStack.Entry, exit: IslandCues?, layers: IslandLayers)] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for card in handOff.cards(at: Date().timeIntervalSince1970) {
            let layers = makeLayers(for: card.card)
            let (entry, exit) = stack.resume(card, metrics: layers.metrics, at: decided)
            drawings[entry.id] = Drawing(layers: layers)
            arrivals[entry.id] = handOff.time ?? Date().timeIntervalSince1970
            container.addSublayer(layers.root)
            resumed.append((entry, exit, layers))
        }
        CATransaction.commit()
        handed = nil
        replan(from: decided)
        for (entry, exit, layers) in resumed {
            layers.showContent()
            if let exit, let leaving = entry.exit {
                layers.fade(exit, into: false, at: started + leaving.time)
            } else if entry.isWaiting {
                layers.hold(pinging: true, at: started + decided)
            } else {
                layers.drain(
                    from: min(entry.remaining / max(entry.card.seconds, 0.01), 1), over: entry.remaining,
                    at: started + decided)
            }
        }
        updateAccessibility()
        CATransaction.flush()
        BackgroundDrip.sayShown()
    }

    /// Shows `card` in place of the one `entry` shows: the capsule springs to the new card's size
    /// where it is, the cards below make room or close up, what changed crossfades and a new state's
    /// colour settles, and its countdown restarts, the ring refilling first. With motion reduced, the
    /// size changes at once and the changes only crossfade.
    private func swap(_ entry: CardStack.Entry, for card: Card) {
        guard let drawing = drawings[entry.id] else { return }
        let motion = CardPresenters.motion(for: card)
        let decided = now
        let time = decided + lead
        let old = drawing.layers
        let layers = makeLayers(for: card)
        let ringFraction = old.card.action == nil ? old.ringFraction : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // One card fading out at a time: one replaced again before it had gone goes at once.
        drawing.retiring?.root.removeFromSuperlayer()
        // Under the old card, which fades off it.
        container.insertSublayer(layers.root, below: old.root)
        CATransaction.commit()
        stack.swap(entry, for: card, metrics: layers.metrics, at: time, reduced: motion != .full)
        arrivals[entry.id] = Date().timeIntervalSince1970
        drawing.layers = layers
        drawing.retiring = old
        replan(from: decided)
        let lingers = layers.takeOver(from: old, motion: motion, at: started + time)
        drawing.retiringUntil = time + lingers
        if entry.isWaiting {
            layers.hold(pinging: true, at: started + time)
        } else {
            layers.refill(from: ringFraction, over: card.seconds, at: started + time)
            if hovering { IslandLayers.pause(layers.ringProgress, paused: true) }
        }
        drawing.sound = CardSound(card.sound, console: console)
        drawing.sound?.play()
        CardPresenters.announce(card)
        updateAccessibility()
    }

    /// Whether the stack takes newer drips' cards in now: a background drip's always; one that waits
    /// for its question's answer only while its own cards show, and only cards that count down. Once
    /// its own cards have gone, it hands the rest on and exits.
    private var adoptsNow: Bool { adopting || (asks && stack.holdsOwn) }

    /// Brings in this drip's next card, or a newer drip's, when there is room and the pointer is away:
    /// dropped in while no card waits past a full stack, else grown out of the overflow drop.
    private func admit() {
        let time = now
        if time - lastRequestCheck >= 0.25 {
            lastRequestCheck = time
            takeAwayDismissed()
            putAwayForPause()
        }
        if !adoptsNow {
            foundAdoptable = false
            othersWaiting = false
            needsRoom = false
            others = []
            if time - lastAdoptionCheck >= 0.25 {
                lastAdoptionCheck = time
                replacedOwn = stack.waiting.filter(CardQueue.isReplaced)
            }
        } else if time - lastAdoptionCheck >= 0.25, !Away.isAway {
            // The queue is looked at whatever the stack is doing, so the overflow drop's count stays
            // true and the next card can grow out of it the moment room opens.
            lastAdoptionCheck = time
            let dismissals = DismissRequests(environment: ProcessInfo.processInfo.environment).load()
            others = CardQueue.adoptable().filter { found in
                // Dismissed before it showed: taken in, so its drip skips it, and never shown.
                if dismissals.dismisses(id: found.card.id, since: QueueTicket.queuedAt(found.ticket) ?? 0) {
                    CardQueue.adopt(index: found.index, in: found.ticket)
                    return false
                }
                return adopting || !found.card.waits
            }
            // A newer card with the same id as one that gave way takes its place.
            let newer = Set(others.compactMap(\.card.id))
            stack.dropTucked { $0.id.map(newer.contains) ?? false }
            replacedOwn = stack.waiting.filter(CardQueue.isReplaced)
            foundAdoptable = !others.isEmpty
            // Cards that wait for you give way to newer drips' cards.
            if stack.live.contains(where: \.isWaiting) {
                let shown = Set(stack.live.compactMap(\.card.id))
                othersWaiting = CardQueue.waiting(except: shown).contains { !$0.adoptable }
                needsRoom = !stack.hasRoom && others.contains { found in
                    !(found.card.id.map(shown.contains) ?? false)
                }
            } else {
                othersWaiting = false
                needsRoom = false
            }
        }
        if stack.isReady(at: time) {
            for found in others {
                // A newer card with the same id as one on screen takes its place there.
                if let id = found.card.id,
                   let shown = stack.live.first(where: { $0.card.id == id && $0.isShown }),
                   CardReplacement.canSwap(shown.card, for: found.card)
                {
                    CardQueue.adopt(index: found.index, in: found.ticket)
                    others.removeAll { $0.ticket == found.ticket && $0.index == found.index }
                    swap(shown, for: found.card)
                    continue
                }
                guard stack.overflow == nil, stack.waiting.isEmpty, stack.hasRoom else { break }
                CardQueue.adopt(index: found.index, in: found.ticket)
                others.removeAll { $0.ticket == found.ticket && $0.index == found.index }
                if adopting { BackgroundWatchdog.extend(by: found.card.duration + 60) }
                enter(found.card, own: false)
                return
            }
            if stack.overflow == nil, let card = stack.nextOwn() {
                if CardQueue.isReplaced(card) { return }
                enter(card, own: true)
                return
            }
            if stack.overflow == nil, others.isEmpty, let tucked = stack.nextTucked() {
                enter(tucked.card, own: tucked.own)
                return
            }
        }
        if stack.canRelease(at: time) { release() }
    }

    // MARK: Every tick

    private func tick() {
        let time = now
        let elapsed = max(time - lastTick, 0)
        lastTick = time
        updateHover()
        admit()

        let changes = stack.advance(
            to: time, elapsed: elapsed, lead: lead, needsRoom: needsRoom, othersWaiting: othersWaiting,
            queued: others.map(\.card), replaced: replacedOwn)
        for entry in changes.stoppedWaiting {
            guard let layers = drawings[entry.id]?.layers else { continue }
            layers.drain(over: entry.card.seconds, at: started + entry.countdownFrom)
            if hovering { IslandLayers.pause(layers.ringProgress, paused: true) }
        }
        for left in changes.left {
            if left.entry.own, left.entry.card.action != nil, !left.clicked { CardActions.missed = true }
            drawings[left.entry.id]?.layers.showPointer(nil)
            drawings[left.entry.id]?.layers.fade(left.cues, into: false, at: started + left.time)
        }
        for entry in changes.gone { arrivals[entry.id] = nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in stack.entries + changes.gone {
            guard let drawing = drawings[entry.id], drawing.retiring != nil,
                  time >= drawing.retiringUntil || entry.isLeaving
            else { continue }
            drawing.retiring?.root.removeFromSuperlayer()
            drawing.retiring = nil
        }
        for entry in changes.gone {
            drawings.removeValue(forKey: entry.id)?.layers.root.removeFromSuperlayer()
        }
        CATransaction.commit()
        let drop = updateOverflow(at: time)
        if !changes.isEmpty || drop { replan(from: time) }
        if let overflow = stack.overflow { overflowLayers?.update(overflow, started: started) }
        if !changes.left.isEmpty || !changes.gone.isEmpty || changes.overflowChanged { updateAccessibility() }

        // Done once nothing is on screen, nothing of its own is left, and the queue had nothing new.
        if adopting || handOffFailed {
            if stack.entries.isEmpty, stack.waiting.isEmpty, stack.tucked.isEmpty, !foundAdoptable, stack.overflow == nil {
                finish()
            }
        } else if questions || stack.ownCardsGone, let cards = stack.handOff(at: time) {
            // A question's answer never waits for its card to go, nor for the cards it took in: a
            // background drip shows them on, where they are, or this stack does when none can.
            let request = BackgroundRequest(
                handOff: StackHandOff(settings: stack.settings, cards: cards, time: Date().timeIntervalSince1970))
            CATransaction.flush()
            if cards.isEmpty || (standby.map { $0.send(request) } ?? BackgroundDrip.start(request)) {
                finish()
            } else {
                handOffFailed = true
            }
        }
    }

    /// Puts the overflow drop's count on screen as the drop forms, and takes it away once the drop
    /// has gone and its last number has rolled out. Returns whether the drawing changed.
    private func updateOverflow(at time: Double) -> Bool {
        if let spread = spreadInto, time >= spread.until { spreadInto = nil }
        let overflow = stack.overflow
        guard overflow !== drawnOverflow || (overflow == nil && spreadInto == nil && overflowLayers != nil) else {
            return false
        }
        // A drop that spread into the last card waiting keeps its count until it has rolled out.
        if overflow == nil, spreadInto != nil { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overflowLayers?.root.removeFromSuperlayer()
        overflowLayers = nil
        spreadInto = nil
        if let overflow {
            let layers = OverflowLayers(size: size, sizeScale: CGFloat(overflow.metrics.scale), scale: scale)
            container.addSublayer(layers.root)
            overflowLayers = layers
        }
        drawnOverflow = overflow
        CATransaction.commit()
        return true
    }

    // MARK: The pointer

    /// The pointer in island coordinates: x from the notch's center, y down from the screen's top.
    private var pointer: CGPoint? {
        guard let panel else { return nil }
        let location = NSEvent.mouseLocation
        guard NSMouseInRect(location, panel.frame, false) else { return nil }
        return CGPoint(x: location.x - panel.frame.midX, y: notch.top - location.y)
    }

    /// The card under `point`, in island coordinates, among those still in the stack.
    private func entry(at point: CGPoint) -> CardStack.Entry? {
        stack.entry(at: IslandPoint(Double(point.x), Double(point.y)), time: now)
    }

    /// The button of `entry` at `point`, in island coordinates, as it is drawn now; nil off them.
    private func button(of entry: CardStack.Entry, at point: CGPoint) -> CardAnswer? {
        stack.button(of: entry, at: IslandPoint(Double(point.x), Double(point.y)), time: now)
    }

    private func updateHover() {
        let at = pointer
        let moved = at != lastPointer
        lastPointer = at
        let under = at.flatMap(entry(at:))
        for entry in stack.live {
            guard let layers = drawings[entry.id]?.layers else { continue }
            let here = entry === under ? at : nil
            layers.setButtonHovered(here.flatMap { button(of: entry, at: $0) })
            let shown: IslandLayers.Pointer? = here.map { isOnClose(of: entry, at: $0) ? .close : .card }
            layers.showPointer(shown)
        }
        // Only as the pointer comes onto a card or leaves it: other apps keep their own cursor.
        if (under != nil) != pointing {
            pointing = under != nil
            CardCursor.set(pointing: pointing)
        }
        // On the overflow drop, the drop springs wide to list the titles waiting, newest first. A
        // click on it does nothing.
        let onDrop = at.map { stack.isOnOverflow(IslandPoint(Double($0.x), Double($0.y)), time: now) } ?? false
        let titles = onDrop ? stack.overflow.map { OverflowLayers.titlesWidth($0.peekText) } : nil
        if stack.peek(width: titles, at: now + lead) {
            replan(from: now)
            if let overflow = stack.overflow { overflowLayers?.update(overflow, started: started) }
        }
        let inside = under != nil || onDrop
        guard stack.hover(inside, moved: moved, at: now) else { return }
        if stack.hovering {
            for entry in stack.live where !entry.isWaiting {
                if let drawing = drawings[entry.id] { IslandLayers.pause(drawing.layers.ringProgress, paused: true) }
            }
            return
        }
        // The stack gave each card a moment to read what was under the pointer before it goes; a
        // card that waits for you goes on waiting.
        let time = now
        for entry in stack.live where !entry.isWaiting {
            let seconds = max(entry.card.seconds, 0.01)
            drawings[entry.id]?.layers.drain(
                from: min(entry.remaining / seconds, 1), over: entry.remaining,
                at: started + max(entry.countdownFrom, time))
        }
    }

    /// Whether `point`, in island coordinates, is on `entry`'s × as it is drawn now.
    private func isOnClose(of entry: CardStack.Entry, at point: CGPoint) -> Bool {
        stack.isOnClose(of: entry, at: IslandPoint(Double(point.x), Double(point.y)), time: now)
    }

    /// A click on a button answers with it; on a card's ×, or a secondary click anywhere on a card,
    /// takes that card away; anywhere else on a card, it brings the sending app forward. Either way
    /// that card goes.
    private func click(_ click: IslandClick) {
        let island = { (point: CGPoint) in CGPoint(x: point.x - self.size.width / 2, y: self.size.height - point.y) }
        let up = island(click.up), down = island(click.down)
        guard let entry = entry(at: up) else { return }
        if click.secondary || (isOnClose(of: entry, at: up) && entry === self.entry(at: down) && isOnClose(of: entry, at: down)) {
            return dismiss(entry)
        }
        if let answer = button(of: entry, at: up) {
            press(answer, on: entry)
            return
        }
        if let target = entry.card.activate { CardActions.activate(target, pane: entry.card.pane, console: console) }
        entry.dismissed = entry.dismissed ?? false
    }

    /// Takes `entry` away without bringing anything forward: a click on its ×, a secondary click,
    /// VoiceOver's Dismiss, or `drip dismiss`. A question goes unanswered.
    private func dismiss(_ entry: CardStack.Entry) {
        guard !entry.isLeaving else { return }
        entry.dismissed = entry.dismissed ?? false
        drawings[entry.id]?.layers.showPointer(nil)
    }

    /// Takes away the cards `drip dismiss`, or an agent moving on, asked to: those on screen that
    /// came before the request, and this drip's own and those that gave way that are still to come.
    private func takeAwayDismissed() {
        let dismissals = DismissRequests(environment: ProcessInfo.processInfo.environment).load()
        guard !dismissals.isEmpty else { return }
        for entry in stack.live where dismissals.dismisses(id: entry.card.id, since: arrivals[entry.id] ?? queuedAt) {
            dismiss(entry)
        }
        stack.dropWaiting { dismissals.dismisses(id: $0.id, since: queuedAt) }
        stack.dropTucked { dismissals.dismisses(id: $0.id, since: queuedAt) }
    }

    /// When a pause starts while a background drip shows cards, as for a screen share, takes them
    /// all away, and every card still to come, and hands them to a new background drip, which holds
    /// them until the pause ends, as it would any card. A question stays: its drip waits on it.
    private func putAwayForPause() {
        guard adopting else { return }
        let paused = DripPause(environment: ProcessInfo.processInfo.environment).isPaused()
        defer { putAway = paused }
        guard paused, !putAway else { return }
        let shown = stack.live.filter { !$0.card.asksQuestion }
        var cards = shown.map(\.card)
        for entry in shown { dismiss(entry) }
        cards += stack.waiting
        stack.dropWaiting { _ in true }
        cards += stack.tucked.map(\.card)
        stack.dropTucked { _ in true }
        // Newer drips' cards are held by their own drips while paused; this stack is done.
        others = []
        foundAdoptable = false
        if !cards.isEmpty { _ = BackgroundDrip.start(BackgroundRequest(cards: cards, record: true)) }
    }

    /// Answers `entry` with one of its buttons, from a click or from VoiceOver.
    private func press(_ answer: CardAnswer, on entry: CardStack.Entry) {
        guard let action = entry.card.action, !entry.isLeaving, entry.dismissed == nil else { return }
        CardActions.answer(answer, to: action, console: console)
        entry.answer = answer
        entry.dismissed = true
        // The answer goes out now, not once the card has gone.
        tick()
    }

    /// Reads the cards out whole, and offers each card's buttons as the stack's actions, then Open,
    /// for a card a click brings an app forward from, and Dismiss, each named with the card's title:
    /// the stack never takes focus.
    private func updateAccessibility() {
        let waiting = stack.overflow.map { ["\($0.count) more waiting: \($0.peekText)"] } ?? []
        view?.setAccessibilityLabel(
            (stack.live.map { CardText.spoken(title: $0.card.title, detail: $0.card.detail) } + waiting)
                .joined(separator: "; "))
        var actions: [NSAccessibilityCustomAction] = []
        for entry in stack.live {
            let title = entry.card.title
            if let action = entry.card.action {
                for (label, answer) in CardAccessibility.answers(to: action) {
                    actions.append(NSAccessibilityCustomAction(name: "\(label): \(title)") {
                        [weak self, weak entry] () -> Bool in
                        guard let self, let entry, !entry.isLeaving else { return false }
                        self.press(answer, on: entry)
                        return true
                    })
                }
            } else if entry.card.activate != nil {
                actions.append(NSAccessibilityCustomAction(name: "\(CardAccessibility.open): \(title)") {
                    [weak self, weak entry] () -> Bool in
                    guard let self, let entry, !entry.isLeaving, let target = entry.card.activate else { return false }
                    CardActions.activate(target, pane: entry.card.pane, console: self.console)
                    entry.dismissed = entry.dismissed ?? false
                    return true
                })
            }
            actions.append(NSAccessibilityCustomAction(name: "\(CardAccessibility.dismiss): \(title)") {
                [weak self, weak entry] () -> Bool in
                guard let self, let entry, !entry.isLeaving else { return false }
                self.dismiss(entry)
                return true
            })
        }
        view?.setAccessibilityCustomActions(actions)
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        onFinish?(true)
        onFinish = nil
    }
}

/// Ends a background drip that has outlived its cards by far, whatever went wrong. A stack that
/// adopts cards pushes the end back.
enum BackgroundWatchdog {
    /// Off the main thread, which waits for the turn without running its queue.
    private static let queue = DispatchQueue(label: "drip.watchdog")
    nonisolated(unsafe) private static var deadline = Date.distantFuture
    nonisolated(unsafe) private static var armed = false

    static func extend(by seconds: Double) {
        queue.sync {
            let end = Date().addingTimeInterval(seconds)
            deadline = armed ? max(deadline, end) : end
            guard !armed else { return }
            armed = true
            check()
        }
    }

    private static func check() {
        queue.asyncAfter(deadline: .now() + 5) {
            // It exits from the main thread, between AppKit's own work rather than in the middle of it.
            if Date() > deadline { DispatchQueue.main.async { exit(ExitStatus.shown) } }
            check()
        }
    }
}
#endif
