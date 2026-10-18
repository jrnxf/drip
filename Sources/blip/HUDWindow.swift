#if canImport(AppKit)
import AppKit
import BlipCore
import QuartzCore

/// Shows cards in borderless, non-activating panels.
struct HUDDisplay: CardDisplay {
    var automaticStyle: CardStyle {
        GlassSupport.isAvailable ? .glass : .hud
    }

    var hasNotch: Bool {
        CardPresenters.targetScreen().flatMap(NotchGeometry.init(screen:)) != nil
    }

    /// Shows the cards one after another and returns once the last has gone.
    func show(_ cards: [Card], locked: LockedScreen, console: Console) -> Int32 {
        // Without a GUI session, touching NSApplication can abort or hang, so check first.
        guard CGSessionCopyCurrentDictionary() != nil else {
            console.error("no GUI session: cards need a logged-in macOS desktop (for example, not over ssh)")
            return ExitStatus.noGUISession
        }
        CardQueue.waitForTurn(cards: cards)
        guard let cards = holdWhileLocked(cards, locked: locked, console: console), !cards.isEmpty else {
            return ExitStatus.shown
        }
        if case .pool = locked {
            // However long the cards were held, a background blip never outlives them by much.
            let longest = cards.reduce(0) { $0 + $1.seconds } + 600
            DispatchQueue.global().asyncAfter(deadline: .now() + longest) { exit(ExitStatus.shown) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var failed = false
        // A question replaced before it showed was never answered.
        var unanswered = false
        var remaining = cards[...]
        func next() {
            guard let card = remaining.popFirst() else { return stopApplication() }
            if CardQueue.isReplaced(card) {
                unanswered = unanswered || card.asksQuestion
                return next()
            }
            let presenter = CardPresenters.make(for: card, console: console)
            let watch = ReplacementWatch(presenter: presenter, card: card)
            // The presenter keeps itself alive through the timers and animations it schedules.
            presenter.start { ok in
                watch.stop()
                failed = failed || !ok
                next()
            }
        }
        // Start once the run loop is running, after the application has finished launching.
        DispatchQueue.main.async(execute: next)
        app.run()
        CardActions.waitForActivations()
        if failed { return ExitStatus.noGUISession }
        return CardActions.missed || unanswered ? ExitStatus.notClicked : ExitStatus.shown
    }

    func showInBackground(_ request: BackgroundRequest, console: Console) -> Int32 {
        guard CGSessionCopyCurrentDictionary() != nil else {
            console.error("no GUI session: cards need a logged-in macOS desktop (for example, not over ssh)")
            return ExitStatus.noGUISession
        }
        if BackgroundBlip.start(request) { return ExitStatus.shown }
        console.warn("cannot start a background blip; showing the card here instead")
        return show(request.cards, locked: .wait(record: request.record), console: console)
    }

    /// Records the cards in the history, first holding them while the screen is locked. Returns the
    /// cards to show now, in this blip's turn, or nil when another blip shows them on the unlock.
    private func holdWhileLocked(_ cards: [Card], locked: LockedScreen, console: Console) -> [Card]? {
        let environment = ProcessInfo.processInfo.environment
        func record(_ cards: [Card], missed: Bool) {
            do {
                try locked.record(cards, missed: missed, in: CardHistory(environment: environment))
            } catch {
                console.warn("cannot record the card in the history: \(error)")
            }
        }
        /// Gives up the turn until the screen unlocks, so other blips can hold their cards too, and
        /// waits again if it locks before the turn comes back.
        func waitForUnlock() {
            repeat {
                CardQueue.leave()
                ScreenLock.waitUntilUnlocked()
                CardQueue.waitForTurn()
            } while ScreenLock.isLocked
        }

        switch locked {
        case .ignore:
            return cards
        case .wait:
            let missed = ScreenLock.isLocked
            record(cards, missed: missed)
            if missed { waitForUnlock() }
            return cards
        case .pool:
            let held = HeldCards(environment: environment)
            let admission: HeldCards.Admission
            do {
                admission = try held.admit(cards, locked: ScreenLock.isLocked, pid: getpid())
            } catch {
                console.warn("cannot hold cards while the screen is locked: \(error)")
                record(cards, missed: false)
                return cards
            }
            switch admission {
            case let .show(leftovers):
                record(cards, missed: false)
                return MissedSummary.cards(for: leftovers) + cards
            case .held:
                record(cards, missed: true)
                return nil
            case .holding:
                record(cards, missed: true)
                waitForUnlock()
                do {
                    return MissedSummary.cards(for: try held.release())
                } catch {
                    console.warn("cannot read the cards held while the screen was locked: \(error)")
                    return cards
                }
            }
        }
    }

    /// Loads each card's sound and icon now, so a problem is reported before blip returns: a sound
    /// that cannot play is dropped, and an unknown symbol falls back to the preset's icon.
    func prepare(_ cards: [Card], console: Console) -> [Card] {
        cards.map { card in
            var card = card
            switch card.sound {
            case .none:
                break
            case let .named(name):
                if NSSound(named: NSSound.Name(name)) == nil {
                    console.warn("unknown sound '\(name)'; system sounds are in /System/Library/Sounds")
                    card.sound = .none
                }
            case let .file(path):
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                if NSSound(contentsOf: url, byReference: true) == nil {
                    console.warn("cannot play sound file '\(path)'")
                    card.sound = .none
                }
            }
            if let target = card.action?.open, !target.contains("://"),
               !FileManager.default.fileExists(atPath: (target as NSString).expandingTildeInPath)
            {
                console.warn("'\(target)' does not exist yet; the button opens it if it does by then")
            }
            if case let .symbol(name) = card.icon, NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
                console.warn("unknown SF Symbol '\(name)'; using the preset's icon")
                card.icon = card.fallbackIcon
            }
            return card
        }
    }

    /// Ends `NSApplication.run()`. `stop` takes effect only after the next event, so post one.
    private func stopApplication() {
        NSApp.stop(nil)
        if let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, subtype: 0, data1: 0, data2: 0)
        {
            NSApp.postEvent(event, atStart: false)
        }
    }
}

/// Covers a clickable card to hold it while hovered and to dismiss it on a click off the button.
final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClick: (() -> Void)?
    /// Gets its own clicks; everything else on the card is this view's.
    weak var button: NSView?

    /// `pointerInside` is for a pointer already on the card, so its leaving still sends `onExit`.
    init(frame: NSRect, pointerInside: Bool = false) {
        super.init(frame: frame)
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if pointerInside { options.insert(.assumeInside) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let button, let superview, button.convert(button.bounds, to: superview).contains(point) {
            return button
        }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// Shows one card and reports when it is gone.
protocol CardPresenting: AnyObject {
    /// Calls `onFinish` once the card has gone, with false when there was no screen for it.
    func start(onFinish: @escaping (Bool) -> Void)

    /// Whether the card is fully in and not yet leaving, so another card can take its place.
    var canReplace: Bool { get }

    /// Shows `card` in place of the current one, with its sound, and restarts the time it stays.
    func replace(with card: Card)
}

/// While a card with an id is on screen, looks for a newer card with the same id from another blip,
/// and swaps it in place of the shown one.
final class ReplacementWatch {
    private let presenter: CardPresenting
    /// The card on screen, and the ticket it came from.
    private var current: Card
    private var source: String
    private var timer: Timer?

    init(presenter: CardPresenting, card: Card) {
        self.presenter = presenter
        current = card
        source = CardQueue.mine?.name ?? ""
        guard card.id != nil, CardQueue.mine != nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.look() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func look() {
        guard presenter.canReplace, let found = CardQueue.replacement(for: current, after: source),
              let id = found.card.id
        else { return }
        // Claimed first, so the newer blip never shows the card too.
        CardQueue.claim(id, in: found.ticket)
        presenter.replace(with: found.card)
        current = found.card
        source = found.ticket
    }
}

enum CardPresenters {
    /// An island at the notch when the card asks for one and the screen has a notch; a panel otherwise.
    static func make(for card: Card, console: Console) -> CardPresenting {
        if card.position == .notch, let screen = targetScreen(), let notch = NotchGeometry(screen: screen) {
            return IslandPresenter(card: card, notch: notch, console: console)
        }
        return CardPresenter(card: card, console: console)
    }

    /// The screen with the pointer, falling back to the main screen.
    static func targetScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// The card's motion setting, capped by Reduce Motion.
    static func motion(for card: Card) -> Motion {
        card.motion.capped(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// The strong ease-out every entrance and exit uses.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

    /// Animates window changes, then runs `next` on a timer. Animation completion handlers never
    /// fire while the display sleeps or the screen is locked, and blip must still exit then.
    static func animate(duration: TimeInterval, _ changes: () -> Void, then next: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = easeOut
            changes()
        }
        guard let next else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: next)
    }
}

/// Plays a card's sound and keeps the process alive until it has finished.
final class CardSound {
    private var sound: NSSound?

    init(_ sound: Sound, console: Console) {
        switch sound {
        case .none:
            break
        case let .named(name):
            self.sound = NSSound(named: NSSound.Name(name))
            if self.sound == nil { console.warn("unknown sound '\(name)'; system sounds are in /System/Library/Sounds") }
        case let .file(path):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            self.sound = NSSound(contentsOf: url, byReference: true)
            if self.sound == nil { console.warn("cannot play sound file '\(path)'") }
        }
    }

    func play() {
        sound?.play()
    }

    /// Exiting would cut the sound off, so wait for it when it outlasts the card.
    func waitUntilDone(then finish: @escaping () -> Void) {
        guard let sound, sound.isPlaying else {
            finish()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            waitUntilDone(then: finish)
        }
    }
}

/// Brings one card in, holds it, takes it out, and lets its sound finish.
///
/// With `motion = full` the card rises 10 points into place from the edge it sits on while it fades
/// in, and drifts back 6 points as it fades out; a `wash` card for `fail` shakes once.
final class CardPresenter: CardPresenting {
    private var card: Card
    private let console: Console
    private var panel: NSPanel?
    private var sound: CardSound?
    private var frame = NSRect.zero
    private var travel: CGFloat = 0
    private var motionAmount = Motion.full
    private var onFinish: ((Bool) -> Void)?
    /// The pending exit; hovering cancels it and leaving schedules a shorter one.
    private var departure: DispatchWorkItem?
    private var leaving = false
    /// Set once the entrance has finished.
    private var entered = false
    private var hover: HoverView?

    init(card: Card, console: Console) {
        self.card = card
        self.console = console
    }

    func start(onFinish: @escaping (Bool) -> Void) {
        guard let screen = CardPresenters.targetScreen() else {
            console.error("no GUI session: no screen to show the card on")
            onFinish(false)
            return
        }
        let built = CardViewBuilder.make(for: card, appearance: nil, console: console)
        let origin = CardLayout.origin(for: built.size, in: screen.visibleFrame, position: card.position)
        let frame = NSRect(origin: origin, size: built.size)
        let panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = !card.isClickable
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = built.root
        self.panel = panel
        self.frame = frame

        let motion = CardPresenters.motion(for: card)
        // Rise from the edge the card sits on; a centered card rises from below.
        let travel: CGFloat = card.position == .top || card.position == .notch ? 1 : -1
        panel.alphaValue = motion == .none ? 1 : 0
        if motion == .full { panel.setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY + travel * 10)) }
        // Never makeKey or activate: the frontmost app keeps focus.
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        sound = CardSound(card.sound, console: console)
        sound?.play()

        self.travel = travel
        motionAmount = motion
        self.onFinish = onFinish
        handleClicks(on: built)
        enter(frame: frame, motion: motion) { [self] in
            entered = true
            schedule(after: card.seconds)
        }
    }

    var canReplace: Bool { entered && !leaving }

    func replace(with card: Card) {
        guard canReplace, let panel, let screen = panel.screen ?? CardPresenters.targetScreen() else { return }
        self.card = card
        let built = CardViewBuilder.make(for: card, appearance: nil, console: console)
        let origin = CardLayout.origin(for: built.size, in: screen.visibleFrame, position: card.position)
        frame = NSRect(origin: origin, size: built.size)
        hover = nil
        panel.contentView = built.root
        panel.setFrame(frame, display: true)
        panel.ignoresMouseEvents = !card.isClickable
        panel.invalidateShadow()
        let held = card.isClickable && NSMouseInRect(NSEvent.mouseLocation, frame, false)
        handleClicks(on: built, pointerInside: held)
        sound = CardSound(card.sound, console: console)
        sound?.play()
        if held {
            departure?.cancel()
        } else {
            schedule(after: card.seconds)
        }
    }

    /// For a clickable card: hovering anywhere on it holds it, a click on the button runs the
    /// action, and a click anywhere else brings the sending app forward and dismisses the card.
    private func handleClicks(on built: CardContent, pointerInside: Bool = false) {
        guard card.isClickable else { return }
        if let action = card.action {
            built.button?.onClick = { [self] in
                CardActions.perform(action, console: console)
                leave(clicked: true)
            }
        }
        let hover = HoverView(frame: NSRect(origin: .zero, size: frame.size), pointerInside: pointerInside)
        hover.onEnter = { [self] in departure?.cancel() }
        hover.onExit = { [self] in schedule(after: 1.5) }
        hover.onClick = { [self] in
            if let target = card.activate { CardActions.activate(target, console: console) }
            leave(clicked: false)
        }
        hover.button = built.button
        built.root.addSubview(hover, positioned: .above, relativeTo: nil)
        self.hover = hover
    }

    private func schedule(after seconds: Double) {
        departure?.cancel()
        let work = DispatchWorkItem { [self] in leave(clicked: false) }
        departure = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func leave(clicked: Bool) {
        guard !leaving else { return }
        leaving = true
        departure?.cancel()
        if card.action != nil, !clicked { CardActions.missed = true }
        panel?.ignoresMouseEvents = true
        exit(frame: frame, travel: travel, motion: motionAmount) { [self] in
            panel?.orderOut(nil)
            sound?.waitUntilDone { [self] in onFinish?(true) }
        }
    }

    private func enter(frame: NSRect, motion: Motion, completion: @escaping () -> Void) {
        guard let panel else { return }
        switch motion {
        case .none:
            completion()
        case .subtle:
            animate(duration: 0.15, { panel.animator().alphaValue = 1 }, completion: completion)
        case .full:
            animate(duration: 0.35, {
                panel.animator().alphaValue = 1
                panel.animator().setFrame(frame, display: true)
            }) { [self] in
                if card.style == .wash, card.kind == Preset.fail.name {
                    shake(frame: frame, offsets: [-8, 7, -5, 3, 0], completion: completion)
                } else {
                    completion()
                }
            }
        }
    }

    private func exit(frame: NSRect, travel: CGFloat, motion: Motion, completion: @escaping () -> Void) {
        guard let panel else { return }
        switch motion {
        case .none:
            completion()
        case .subtle:
            animate(duration: 0.25, { panel.animator().alphaValue = 0 }, completion: completion)
        case .full:
            let away = frame.offsetBy(dx: 0, dy: travel * 6)
            animate(duration: 0.2, {
                panel.animator().alphaValue = 0
                panel.animator().setFrame(away, display: true)
            }, completion: completion)
        }
    }

    /// The wrong-password shake: quick steps through `offsets`, in points from the resting frame.
    private func shake(frame: NSRect, offsets: [CGFloat], completion: @escaping () -> Void) {
        guard let panel, let offset = offsets.first else { return completion() }
        animate(duration: 0.07, { panel.animator().setFrame(frame.offsetBy(dx: offset, dy: 0), display: true) }) {
            [self] in
            shake(frame: frame, offsets: Array(offsets.dropFirst()), completion: completion)
        }
    }

    private func animate(duration: TimeInterval, _ changes: () -> Void, completion: (() -> Void)? = nil) {
        CardPresenters.animate(duration: duration, changes, then: completion)
    }
}
#endif
