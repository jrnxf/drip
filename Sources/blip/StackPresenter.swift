#if canImport(AppKit)
import AppKit
import BlipCore
import QuartzCore

/// How cards stack at the notch, from `BLIP_STACK` and `BLIP_STACK_MAX`. An experiment: `chain`
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
        let value = environment["BLIP_STACK"]?.lowercased() ?? Mode.chain.rawValue
        guard let mode = Mode(rawValue: value) else { return nil }
        let max = environment["BLIP_STACK_MAX"].flatMap(Int.init) ?? 3
        return StackSettings(mode: mode, max: min(Swift.max(max, 1), 6))
    }
}

/// Shows several cards at the notch at once, one below another, each grown out of the notch or out
/// of the card above it, and adopts newer blips' notch cards from the queue while it shows.
///
/// Every frame is computed on a display-rate timer rather than handed to Core Animation as
/// keyframes, so the stack can change its mind at any moment: a card leaves, the ones below close
/// the gap, a new one drops in. While the pointer is on any card, nothing moves: every countdown
/// stops, gaps stay open and new cards wait, so a card never slides out from under a click.
final class StackPresenter: CardPresenting {
    private enum Phase {
        case entering(start: Double, cues: IslandCues)
        case shown
        case leaving(start: Double, cues: IslandCues)
    }

    private final class Entry {
        var card: Card
        /// One of this blip's own cards, rather than one adopted from another blip.
        let own: Bool
        var layers: IslandLayers
        var animator: IslandAnimator
        var phase: Phase
        /// The card it grew out of and goes back into; nil for the notch.
        weak var anchor: Entry?
        /// Seconds left on its countdown, which starts once its title has faded in.
        var remaining: Double
        var countdownFrom: Double
        var sound: CardSound?

        init(card: Card, own: Bool, layers: IslandLayers, animator: IslandAnimator, phase: Phase, countdownFrom: Double) {
            self.card = card
            self.own = own
            self.layers = layers
            self.animator = animator
            self.phase = phase
            remaining = card.seconds
            self.countdownFrom = countdownFrom
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
    /// Whether to adopt newer blips' cards: only a background blip, which reports nothing about them.
    private let adopting: Bool
    private var waiting: [Card]
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
    private var lastFrame: Double = 0
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
    /// The least time between two cards dropping in.
    private static let entranceSpacing = 0.35

    /// A stack for `card` and the notch cards that follow it in `rest`, which it takes; nil when
    /// stacking is off, the card is not for the notch, there is no notch, or motion is reduced.
    static func make(
        for card: Card, rest: inout ArraySlice<Card>, adopting: Bool, console: Console
    ) -> StackPresenter? {
        guard let settings = StackSettings.current(), card.position == .notch,
              CardPresenters.motion(for: card) == .full,
              let screen = CardPresenters.targetScreen(), let notch = NotchGeometry(screen: screen)
        else { return nil }
        var cards = [card]
        while let next = rest.first, next.position == .notch {
            cards.append(next)
            rest.removeFirst()
        }
        return StackPresenter(cards: cards, settings: settings, notch: notch, adopting: adopting, console: console)
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
        // The timer keeps the stack alive until `finish` stops it.
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [self] _ in tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    // MARK: The stack

    private var now: Double { CACurrentMediaTime() - started }
    private var live: [Entry] { entries.filter { !$0.isLeaving } }

    /// Where each card still in the stack sits: its capsule's top, from the notch down.
    private func tops() -> [ObjectIdentifier: Double] {
        var tops: [ObjectIdentifier: Double] = [:]
        var top: Double?
        for entry in live {
            let metrics = entry.layers.metrics
            let at = top ?? metrics.pillTop
            tops[ObjectIdentifier(entry)] = at
            top = at + metrics.pillHeight + Self.gap
        }
        return tops
    }

    /// Moves every card to its place in the stack, unless the pointer is on it.
    private func layout() {
        guard !hovering else {
            needsLayout = true
            return
        }
        needsLayout = false
        let tops = tops()
        let time = now
        for entry in live {
            guard let top = tops[ObjectIdentifier(entry)], abs(entry.animator.targetTop - top) > 0.25 else { continue }
            entry.animator.move(to: top, at: time)
        }
    }

    /// Drops `card` into the stack: below the last card, or at the top under the notch.
    private func enter(_ card: Card, own: Bool) {
        let time = now
        let layers = makeLayers(for: card)
        container.addSublayer(layers.root)

        let above: Entry?
        let index: Int
        switch settings.mode {
        case .chain:
            above = live.last
            index = entries.count
        case .push:
            above = nil
            index = live.first.flatMap { first in entries.firstIndex { $0 === first } } ?? entries.count
        }
        let anchor = above.map { DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.layers.metrics) }
        var animator = IslandAnimator(metrics: layers.metrics, anchor: anchor)
        // Its place once the others have made room.
        var top: Double = layers.metrics.pillTop
        if let above {
            top = above.animator.targetTop + above.layers.metrics.pillHeight + Self.gap
        }
        let cues = animator.enter(at: time, top: top)
        let entry = Entry(
            card: card, own: own, layers: layers, animator: animator,
            phase: .entering(start: time, cues: cues),
            countdownFrom: time + (cues.title.first ?? cues.sides) + 0.25)
        entry.anchor = above
        entries.insert(entry, at: index)
        entry.sound = CardSound(card.sound, console: console)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { entry.sound?.play() }
        lastEntrance = time
        layout()
        updateAccessibility()
    }

    /// A card's icon, ring and text, hanging from the top of the screen and centered on the notch;
    /// the stack draws its outline.
    private func makeLayers(for card: Card) -> IslandLayers {
        let layers = IslandLayers(card: card, notch: notch, scale: scale, console: console)
        layers.shape.isHidden = true
        layers.root.frame = CGRect(
            x: (size.width - layers.size.width) / 2, y: size.height - layers.size.height,
            width: layers.size.width, height: layers.size.height)
        return layers
    }

    /// Takes `entry` back into the card above it, or into the notch.
    private func leave(_ entry: Entry, clicked: Bool) {
        guard !entry.isLeaving else { return }
        if entry.own, entry.card.action != nil, !clicked { CardActions.missed = true }
        let time = now
        let position = entries.firstIndex { $0 === entry } ?? 0
        let above = entries[..<position].last { !$0.isLeaving }
        entry.anchor = above
        let anchor = above.map { DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.layers.metrics) }
        let cues = entry.animator.exit(at: time, into: anchor)
        entry.phase = .leaving(start: time, cues: cues)
        // The cards that grew out of this one now hang from whatever is above it.
        for other in entries where other.anchor === entry { other.anchor = above }
        layout()
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
        CATransaction.commit()
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.18
        fadeIn.timingFunction = CardPresenters.easeOut
        layers.text.add(fadeIn, forKey: "replace")
        entry.card = card
        entry.layers = layers
        entry.animator = animator
        entry.remaining = card.seconds
        entry.countdownFrom = time
        entry.sound = CardSound(card.sound, console: console)
        entry.sound?.play()
        layout()
        updateAccessibility()
    }

    /// Brings in this blip's next card, or a newer blip's, when there is room and the pointer is away.
    private func admit() {
        let time = now
        guard !hovering, time - lastEntrance >= Self.entranceSpacing else { return }
        // A newer card with the same id as one on screen takes its place there.
        if adopting, time - lastAdoptionCheck >= 0.25, !ScreenLock.isLocked {
            lastAdoptionCheck = time
            let candidates = CardQueue.adoptable()
            foundAdoptable = !candidates.isEmpty
            for found in candidates {
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

    // MARK: Every frame

    private func tick() {
        let time = now
        let elapsed = max(time - lastFrame, 0)
        lastFrame = time
        updateHover()
        admit()

        for entry in entries {
            switch entry.phase {
            case let .entering(start, cues):
                let last = max(cues.sides, (cues.title + cues.detail).max() ?? 0) + 0.25
                if time - start >= last { entry.phase = .shown }
            case .shown:
                if !hovering, time >= entry.countdownFrom { entry.remaining -= elapsed }
                if entry.remaining <= 0 { leave(entry, clicked: false) }
            case .leaving:
                break
            }
        }
        let gone = entries.filter { entry in
            if case .leaving = entry.phase { return time >= entry.animator.end + 0.02 }
            return false
        }
        for entry in gone {
            entry.layers.root.removeFromSuperlayer()
            entries.removeAll { $0 === entry }
        }
        if !gone.isEmpty { updateAccessibility() }

        draw(at: time)
        // Done once nothing is on screen, nothing of its own is left, and the queue had nothing new.
        if entries.isEmpty, waiting.isEmpty, !foundAdoptable { finish() }
    }

    private func draw(at time: Double) {
        let centerX = size.width / 2
        let path = CGMutablePath()
        if let metrics = entries.first?.layers.metrics {
            IslandPath.addNotch(to: path, metrics: metrics, centerX: centerX)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in entries {
            let shape = entry.animator.shape(at: time)
            let layout = entry.animator.content(for: shape)
            entry.layers.apply(entry.layers.frame(shape, layout: layout, withPath: false))
            let metrics = entry.layers.metrics
            let anchor = entry.anchor.map {
                DropletAnchor.capsule($0.animator.shape(at: time), metrics: $0.layers.metrics)
            }
            let field = DropletField(metrics: metrics, shape: shape, anchor: anchor)
            if field.touchesNotch {
                IslandPath.addTraced(field, to: path, centerX: centerX)
            } else {
                IslandPath.addCapsule(shape, metrics: metrics, to: path, centerX: centerX)
            }
            switch entry.phase {
            case let .entering(start, cues):
                entry.layers.showContent(at: time - start, cues: cues)
            case .shown:
                entry.layers.showContent()
            case let .leaving(start, cues):
                entry.layers.hideContent(at: time - start, cues: cues)
            }
            let seconds = max(entry.card.seconds, 0.01)
            entry.layers.ringProgress.strokeEnd = CGFloat(min(max(entry.remaining / seconds, 0), 1))
        }
        liquid.path = path
        CATransaction.commit()
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
        if !inside {
            // A moment to read what was under the pointer before it goes.
            for entry in live where entry.isShown { entry.remaining = max(entry.remaining, 1.5) }
            if needsLayout { layout() }
        }
    }

    /// A click on a button runs its action; anywhere else on a card, it brings the sending app
    /// forward. Either way that card goes.
    private func click(at point: CGPoint) {
        let island = CGPoint(x: point.x - size.width / 2, y: size.height - point.y)
        guard let entry = entry(at: island), entry.isShown || !entry.isLeaving else { return }
        let time = now
        if let action = entry.card.action {
            let layout = entry.animator.content(for: entry.animator.shape(at: time))
            let half = layout.ringSize / 2 + 4
            if abs(island.x - layout.ringCenter.x) <= half, abs(island.y - layout.ringCenter.y) <= half + 4 {
                CardActions.perform(action, console: console)
                leave(entry, clicked: true)
                return
            }
        }
        if let target = entry.card.activate { CardActions.activate(target, console: console) }
        leave(entry, clicked: false)
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

/// Ends a background blip that has outlived its cards by far, whatever went wrong. A stack that
/// adopts cards pushes the end back.
enum BackgroundWatchdog {
    /// Off the main thread, which waits for the turn without running its queue.
    private static let queue = DispatchQueue(label: "blip.watchdog")
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
