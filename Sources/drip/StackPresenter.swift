#if canImport(AppKit)
import AppKit
import DripCore
import QuartzCore

/// How cards stack at the notch, from `DRIP_STACK` and `DRIP_STACK_MAX`. An experiment: `chain`
/// (the default) drops each new card from the bottom of the last, `push` drops it from the notch and
/// pushes the others down, and `off` shows one card at a time.
struct StackSettings {
    enum Mode: String {
        case chain, push
    }

    var mode: Mode
    /// The most cards on screen at once; the rest wait their turn.
    var max: Int

    /// Nil when stacking is off.
    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> StackSettings? {
        let value = environment["DRIP_STACK"]?.lowercased() ?? Mode.chain.rawValue
        guard let mode = Mode(rawValue: value) else { return nil }
        let max = environment["DRIP_STACK_MAX"].flatMap(Int.init) ?? 3
        return StackSettings(mode: mode, max: min(Swift.max(max, 1), 6))
    }
}

/// Shows several cards at the notch at once, one below another, each grown out of the notch or out
/// of the card above it, and adopts newer drips' notch cards from the queue while it shows.
///
/// The motion is played the way a single card's is: every spring is sampled 240 times a second into
/// keyframe animations, which Core Animation plays off the main thread. Whenever the stack changes,
/// a card coming, going or moving up, everything is sampled again from that moment, and since the
/// springs keep their velocity through a change, nothing jumps. While the pointer is on any card,
/// nothing moves: every countdown stops, gaps stay open and new cards wait, so a card never slides
/// out from under a click.
final class StackPresenter: CardPresenting {
    private enum Phase {
        case entering(start: Double, cues: IslandCues)
        case shown
        case leaving(until: Double)
    }

    private final class Entry {
        var card: Card
        /// One of this drip's own cards, rather than one adopted from another drip.
        let own: Bool
        var layers: IslandLayers
        var animator: IslandAnimator
        var phase: Phase
        /// The card it grew out of and goes back into; nil for the notch.
        weak var anchor: Entry?
        /// Seconds left on its countdown, which starts once its title has faded in.
        var remaining: Double
        var countdownFrom: Double
        /// A leaving card keeps its place until its drop starts to rise, so the cards below never
        /// run into it while it gathers.
        var holdsPlaceUntil = Double.infinity
        /// Set when the card should go as soon as nothing is still flowing into it; whether by a
        /// click on its button.
        var dismissed: Bool?
        var sound: CardSound?

        init(card: Card, own: Bool, layers: IslandLayers, animator: IslandAnimator, phase: Phase) {
            self.card = card
            self.own = own
            self.layers = layers
            self.animator = animator
            self.phase = phase
            remaining = card.seconds
            countdownFrom = 0
        }

        var isLeaving: Bool {
            if case .leaving = phase { return true }
            return false
        }

        var isShown: Bool {
            if case .shown = phase { return true }
            return false
        }
    }

    private let settings: StackSettings
    private let notch: NotchGeometry
    private let console: Console
    /// Whether to adopt newer drips' cards: only a background drip, which reports nothing about them.
    private let adopting: Bool
    private var waiting: [Card]
    /// Top to bottom, leaving cards included.
    private var entries: [Entry] = []
    private var panel: IslandPanel?
    private var view: IslandView?
    private let container = CALayer()
    /// The notch and every card's capsule, melted together where a drop is forming or returning.
    private let liquid = CAShapeLayer()
    private var size = CGSize.zero
    private var scale: CGFloat = 2
    private var timer: Timer?
    private var started: CFTimeInterval = 0
    private var lastTick: Double = 0
    private var lastAdoptionCheck = -Double.infinity
    /// Whether the last look at the queue found cards to adopt.
    private var foundAdoptable = false
    private var lastEntrance = -Double.infinity
    private var hovering = false
    /// A change to the stack waits while the pointer is on it.
    private var needsLayout = false
    private var onFinish: ((Bool) -> Void)?

    /// The gap between two cards in the stack.
    private static let gap: Double = 10
    /// The least time between two cards dropping in; a card also waits until the stack is still.
    private static let entranceSpacing = 0.35
    /// Keyframes per second when sampling the springs, as for a single card.
    private static let framesPerSecond = 240.0
    /// How long after it is decided a change starts moving. Sampling the springs takes the main
    /// thread a moment, and the keyframes start at the moment of the decision, so a change that
    /// started at once would lose its first frames; until it starts, the samples carry on where the
    /// stack was already heading.
    private static let lead = 0.06

    /// A stack for `card` and the notch cards that follow it in `rest`, which it takes; nil when
    /// stacking is off, the card is not for the notch, or motion is reduced.
    static func make(
        for card: Card, rest: inout ArraySlice<Card>, adopting: Bool, console: Console
    ) -> StackPresenter? {
        guard let settings = StackSettings.current(), card.position == .notch,
              CardPresenters.motion(for: card) == .full,
              let screen = CardPresenters.targetScreen()
        else { return nil }
        var cards = [card]
        while let next = rest.first, next.position == .notch {
            cards.append(next)
            rest.removeFirst()
        }
        return StackPresenter(
            cards: cards, settings: settings, notch: NotchGeometry.island(on: screen), adopting: adopting,
            console: console)
    }

    private init(cards: [Card], settings: StackSettings, notch: NotchGeometry, adopting: Bool, console: Console) {
        waiting = cards
        self.settings = settings
        self.notch = notch
        self.adopting = adopting
        self.console = console
    }

    var canReplace: Bool { false }
    func replace(with card: Card) {}

    func start(onFinish: @escaping (Bool) -> Void) {
        self.onFinish = onFinish
        scale = CardPresenters.targetScreen()?.backingScaleFactor ?? 2
        size = CGSize(
            width: CGFloat(CardMetrics.maxWidth) + 40,
            height: notch.height + CGFloat(settings.max) * 170 + 40)
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
        view.onClick = { [weak self] point in self?.click(at: point) }
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
        // Countdowns, the pointer and the queue; the motion itself runs in Core Animation. The timer
        // keeps the stack alive until `finish` stops it.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [self] _ in tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    // MARK: The stack

    private var now: Double { CACurrentMediaTime() - started }
    private var live: [Entry] { entries.filter { !$0.isLeaving } }

    /// Where each card that holds a place in the stack sits: its capsule's top, from the notch down.
    private func tops() -> [ObjectIdentifier: Double] {
        var tops: [ObjectIdentifier: Double] = [:]
        var top: Double?
        for entry in entries where !entry.isLeaving || entry.holdsPlaceUntil.isFinite {
            let metrics = entry.layers.metrics
            let at = top ?? metrics.pillTop
            tops[ObjectIdentifier(entry)] = at
            top = at + metrics.pillHeight + Self.gap
        }
        return tops
    }

    /// Moves every card but `incoming` to its place in the stack at `time`, unless the pointer is on
    /// it. Returns whether any card moved; the caller plays the motion.
    @discardableResult
    private func place(at time: Double, except incoming: Entry? = nil, with spring: Spring = IslandAnimator.settle) -> Bool {
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

    /// Samples every card's springs from `start` until they settle, and plays them. The samples are
    /// independent, so they are taken on every core at once; a card already at rest by `start` gets
    /// no keyframes.
    private func replan(from start: Double) {
        let begin = started + start
        let end = max(entries.map(\.animator.end).max() ?? start, start + 0.05)
        let count = Int(((end - start) * Self.framesPerSecond).rounded(.up)) + 1
        let cards = entries.map { entry in
            StackCard(
                animator: entry.animator, metrics: entry.layers.metrics,
                anchor: entry.anchor.flatMap { anchor in entries.firstIndex { $0 === anchor } })
        }
        let layers = entries.map(\.layers)
        let moving = entries.map { $0.animator.end > start }
        let centerX = size.width / 2
        var paths = [CGPath?](repeating: nil, count: count)
        var frames = [[IslandLayers.Frame?]](repeating: [IslandLayers.Frame?](repeating: nil, count: count), count: cards.count)
        paths.withUnsafeMutableBufferPointer { paths in
            DispatchQueue.concurrentPerform(iterations: count) { index in
                let time = start + (end - start) * Double(index) / Double(count - 1)
                paths[index] = Self.path(at: time, cards: cards, centerX: centerX)
            }
        }
        for (card, layer) in zip(cards.indices, layers) where moving[card] {
            frames[card].withUnsafeMutableBufferPointer { samples in
                DispatchQueue.concurrentPerform(iterations: count) { index in
                    let time = start + (end - start) * Double(index) / Double(count - 1)
                    let shape = cards[card].animator.shape(at: time)
                    samples[index] = layer.frame(shape, layout: cards[card].animator.content(for: shape), withPath: false)
                }
            }
        }
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
            } else {
                let shape = cards[card].animator.shape(at: start)
                layer.apply(layer.frame(shape, layout: cards[card].animator.content(for: shape), withPath: false))
            }
        }
        CATransaction.commit()
    }

    /// What drawing a card's outline needs, copied so the samples can be taken off the main thread.
    private struct StackCard {
        let animator: IslandAnimator
        let metrics: IslandMetrics
        /// The card it grows out of, as an index into the same list; nil for the notch.
        let anchor: Int?
    }

    /// The notch and every card at `time`, each card melted into what it grows out of while it is
    /// close enough.
    private static func path(at time: Double, cards: [StackCard], centerX: CGFloat) -> CGPath {
        let path = CGMutablePath()
        if let metrics = cards.first?.metrics {
            IslandPath.addNotch(to: path, metrics: metrics, centerX: centerX)
        }
        let shapes = cards.map { $0.animator.shape(at: time) }
        for (index, card) in cards.enumerated() {
            let anchor = card.anchor.map { DropletAnchor.capsule(shapes[$0], metrics: cards[$0].metrics) }
            let field = DropletField(metrics: card.metrics, shape: shapes[index], anchor: anchor)
            if field.touchesNotch {
                IslandPath.addTraced(field, to: path, centerX: centerX)
            } else {
                IslandPath.addCapsule(shapes[index], metrics: card.metrics, to: path, centerX: centerX)
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
        let time = decided + Self.lead
        let layers = makeLayers(for: card)
        let above = settings.mode == .chain ? live.last : nil
        let anchor = above.map { DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.layers.metrics) }
        var animator = IslandAnimator(metrics: layers.metrics, anchor: anchor)
        let entry = Entry(card: card, own: own, layers: layers, animator: animator, phase: .shown)
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
                delay = Self.delay(clearing: below, for: animator, top: layers.metrics.pillTop, at: time)
            }
        }
        let top = above.map { $0.animator.targetTop + $0.layers.metrics.pillHeight + Self.gap } ?? layers.metrics.pillTop
        let start = time + delay
        let cues = animator.enter(at: start, top: top)
        entry.animator = animator
        entry.phase = .entering(start: start, cues: cues)
        entry.countdownFrom = start + (cues.title.first ?? cues.sides) + 0.25
        // Without actions: a change to the container's sublayers would otherwise crossfade the
        // whole stack.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.addSublayer(layers.root)
        CATransaction.commit()
        layers.fade(cues, into: true, at: started + start)
        layers.drain(over: card.seconds, at: started + entry.countdownFrom)
        // The sound lands as the drop first shows.
        entry.sound = CardSound(card.sound, console: console)
        DispatchQueue.main.asyncAfter(deadline: .now() + (start - decided) + 0.05) { entry.sound?.play() }
        lastEntrance = decided
        replan(from: decided)
        updateAccessibility()
    }

    /// How long a drop coming out of the notch waits so it never touches `below` as that card moves
    /// down out of its way.
    private static func delay(clearing below: Entry, for animator: IslandAnimator, top: Double, at time: Double) -> Double {
        func clears(after delay: Double) -> Bool {
            var trial = animator
            _ = trial.enter(at: time + delay, top: top)
            return stride(from: time, through: trial.end, by: 1.0 / 60).allSatisfy { t in
                let shape = trial.shape(at: t)
                // A few points: the new capsule's bounce overshoots into the gap for a moment.
                return shape.pillTop + shape.pillHeight <= below.animator.shape(at: t).pillTop - 3
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

    /// Takes `entry` back into the card above it, or into the notch.
    private func leave(_ entry: Entry, clicked: Bool) {
        guard !entry.isLeaving else { return }
        if entry.own, entry.card.action != nil, !clicked { CardActions.missed = true }
        let decided = now
        let time = decided + Self.lead
        let position = entries.firstIndex { $0 === entry } ?? 0
        let above = entries[..<position].last { !$0.isLeaving }
        entry.anchor = above
        let anchor = above.map { DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.layers.metrics) }
        let cues = entry.animator.exit(at: time, into: anchor)
        entry.holdsPlaceUntil = entry.animator.riseTime ?? time
        entry.phase = .leaving(until: entry.animator.end)
        entry.layers.fade(cues, into: false, at: started + time)
        // The cards that grew out of this one now hang from whatever is above it.
        for other in entries where other.anchor === entry { other.anchor = above }
        replan(from: decided)
        updateAccessibility()
    }

    /// Shows `card` in place of the one `entry` shows: fully open where it is, text fading in, its
    /// countdown restarted.
    private func swap(_ entry: Entry, for card: Card) {
        let time = now
        let layers = makeLayers(for: card)
        var animator = IslandAnimator(metrics: layers.metrics, anchor: nil)
        animator.open(top: entry.animator.shape(at: time).pillTop)
        layers.showContent()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.replaceSublayer(entry.layers.root, with: layers.root)
        // With the swap, so the new text never shows for a frame before it fades in.
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.18
        fadeIn.timingFunction = CardPresenters.easeOut
        layers.text.add(fadeIn, forKey: "replace")
        CATransaction.commit()
        entry.card = card
        entry.layers = layers
        entry.animator = animator
        entry.remaining = card.seconds
        entry.countdownFrom = time
        layers.drain(over: card.seconds)
        if hovering { IslandLayers.pause(layers.ringProgress, paused: true) }
        entry.sound = CardSound(card.sound, console: console)
        entry.sound?.play()
        place(at: time + Self.lead)
        replan(from: time)
        updateAccessibility()
    }

    /// Brings in this drip's next card, or a newer drip's, when there is room and the pointer is away.
    private func admit() {
        let time = now
        // One card at a time, into a stack at rest, so a new drop never shoves cards still settling.
        guard !hovering, time - lastEntrance >= Self.entranceSpacing,
              entries.allSatisfy({ $0.animator.end <= time })
        else { return }
        if adopting, time - lastAdoptionCheck >= 0.25, !ScreenLock.isLocked {
            lastAdoptionCheck = time
            let candidates = CardQueue.adoptable()
            foundAdoptable = !candidates.isEmpty
            for found in candidates {
                // A newer card with the same id as one on screen takes its place there.
                if let id = found.card.id,
                   let shown = live.first(where: { $0.card.id == id && $0.isShown }),
                   CardReplacement.canSwap(shown.card, for: found.card)
                {
                    CardQueue.adopt(index: found.index, in: found.ticket)
                    swap(shown, for: found.card)
                    continue
                }
                guard waiting.isEmpty, live.count < settings.max else { break }
                CardQueue.adopt(index: found.index, in: found.ticket)
                BackgroundWatchdog.extend(by: found.card.seconds + 60)
                enter(found.card, own: false)
                return
            }
        }
        guard live.count < settings.max, let card = waiting.first else { return }
        waiting.removeFirst()
        if CardQueue.isReplaced(card) { return }
        enter(card, own: true)
    }

    // MARK: Every tick

    private func tick() {
        let time = now
        let elapsed = max(time - lastTick, 0)
        lastTick = time
        updateHover()
        admit()

        var released = false
        for entry in entries {
            switch entry.phase {
            case let .entering(start, cues):
                let last = max(cues.sides, (cues.title + cues.detail).max() ?? 0) + 0.25
                if time - start >= last { entry.phase = .shown }
            case .shown:
                if !hovering, time >= entry.countdownFrom { entry.remaining -= elapsed }
                if entry.remaining <= 0 || entry.dismissed != nil, !isFilling(entry) {
                    leave(entry, clicked: entry.dismissed ?? false)
                }
            case .leaving:
                // Its drop has started to rise: the cards below can close the gap behind it.
                if entry.holdsPlaceUntil.isFinite, time >= entry.holdsPlaceUntil {
                    entry.holdsPlaceUntil = -.infinity
                    released = true
                }
            }
        }
        let gone = entries.filter { entry in
            if case let .leaving(until) = entry.phase { return time >= until + 0.02 || isSwallowed(entry, at: time) }
            return false
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in gone {
            entry.layers.root.removeFromSuperlayer()
            entries.removeAll { $0 === entry }
        }
        CATransaction.commit()
        let moved = (released || needsLayout) && place(at: time + Self.lead)
        if moved || !gone.isEmpty { replan(from: time) }
        if !gone.isEmpty { updateAccessibility() }

        // Done once nothing is on screen, nothing of its own is left, and the queue had nothing new.
        if entries.isEmpty, waiting.isEmpty, !foundAdoptable { finish() }
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
    private func entry(at point: CGPoint) -> Entry? {
        let time = now
        return live.first { entry in
            let shape = entry.animator.shape(at: time)
            let rect = CGRect(
                x: -shape.pillWidth / 2, y: shape.pillTop, width: shape.pillWidth, height: shape.pillHeight)
            return rect.insetBy(dx: -2, dy: -2).contains(point)
        }
    }

    private func updateHover() {
        let inside = pointer.flatMap(entry(at:)) != nil
        guard inside != hovering else { return }
        hovering = inside
        if inside {
            for entry in live { IslandLayers.pause(entry.layers.ringProgress, paused: true) }
            return
        }
        // A moment to read what was under the pointer before it goes.
        let time = now
        for entry in live {
            if entry.isShown { entry.remaining = max(entry.remaining, 1.5) }
            let seconds = max(entry.card.seconds, 0.01)
            entry.layers.drain(
                from: min(entry.remaining / seconds, 1), over: entry.remaining,
                at: started + max(entry.countdownFrom, time))
        }
    }

    /// A click on a button runs its action; anywhere else on a card, it brings the sending app
    /// forward. Either way that card goes.
    private func click(at point: CGPoint) {
        let island = CGPoint(x: point.x - size.width / 2, y: size.height - point.y)
        guard let entry = entry(at: island) else { return }
        if let action = entry.card.action {
            let layout = entry.animator.content(for: entry.animator.shape(at: now))
            let half = layout.ringSize / 2 + 4
            if abs(island.x - layout.ringCenter.x) <= half, abs(island.y - layout.ringCenter.y) <= half + 4 {
                CardActions.perform(action, console: console)
                entry.dismissed = true
                return
            }
        }
        if let target = entry.card.activate { CardActions.activate(target, console: console) }
        entry.dismissed = entry.dismissed ?? false
    }

    /// Whether a leaving card's drop is still on its way into `entry`, which must then stay until it
    /// has merged: shrinking around it would uncover it.
    private func isFilling(_ entry: Entry) -> Bool {
        entries.contains { $0.isLeaving && $0.anchor === entry }
    }

    /// Whether a leaving card's drop is hidden inside what it went back into, far enough in that
    /// taking it away leaves no trace on the outline.
    private func isSwallowed(_ entry: Entry, at time: Double) -> Bool {
        let shape = entry.animator.shape(at: time)
        guard shape.pillWidth <= entry.layers.metrics.dropSize + 1 else { return false }
        let depth = entry.layers.metrics.blend / 2
        let bottom = entry.anchor.map {
            DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.layers.metrics).bottom
        } ?? entry.layers.metrics.notchHeight
        return shape.pillTop + shape.pillHeight <= bottom - depth
    }

    private func updateAccessibility() {
        view?.setAccessibilityLabel(
            live.map { CardText.spoken(title: $0.card.title, detail: $0.card.detail) }.joined(separator: "; "))
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
            if Date() > deadline { exit(ExitStatus.shown) }
            check()
        }
    }
}
#endif
