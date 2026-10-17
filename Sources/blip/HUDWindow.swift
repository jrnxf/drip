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
    func show(_ cards: [Card], console: Console) -> Int32 {
        // Without a GUI session, touching NSApplication can abort or hang, so check first.
        guard CGSessionCopyCurrentDictionary() != nil else {
            console.error("no GUI session: cards need a logged-in macOS desktop (for example, not over ssh)")
            return ExitStatus.noGUISession
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var failed = false
        var remaining = cards[...]
        func next() {
            guard let card = remaining.popFirst() else { return stopApplication() }
            let presenter = CardPresenters.make(for: card, console: console)
            // The presenter keeps itself alive through the timers and animations it schedules.
            presenter.start { ok in
                failed = failed || !ok
                next()
            }
        }
        // Start once the run loop is running, after the application has finished launching.
        DispatchQueue.main.async(execute: next)
        app.run()
        return failed ? ExitStatus.noGUISession : ExitStatus.shown
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

/// Shows one card and reports when it is gone.
protocol CardPresenting: AnyObject {
    /// Calls `onFinish` once the card has gone, with false when there was no screen for it.
    func start(onFinish: @escaping (Bool) -> Void)
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
    private let card: Card
    private let console: Console
    private var panel: NSPanel?
    private var sound: CardSound?

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
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = built.root
        self.panel = panel

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

        enter(frame: frame, motion: motion) { [self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + card.seconds) { [self] in
                exit(frame: frame, travel: travel, motion: motion) { [self] in
                    panel.orderOut(nil)
                    sound?.waitUntilDone { onFinish(true) }
                }
            }
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
