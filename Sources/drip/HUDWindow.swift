#if canImport(AppKit)
import AppKit
import DripCore
import QuartzCore

/// Shows cards in borderless, non-activating panels.
struct HUDDisplay: CardDisplay {
    /// Shows the cards one after another and returns once the last has gone.
    func show(_ cards: [Card], locked: LockedScreen, stack settings: StackSettings?, console: Console) -> Int32 {
        // Without a GUI session, touching NSApplication can abort or hang, so check first.
        guard CGSessionCopyCurrentDictionary() != nil else {
            console.error("no GUI session: cards need a logged-in macOS desktop (for example, not over ssh)")
            return ExitStatus.noGUISession
        }
        CardQueue.waitForTurn(cards: cards)
        // Cards a stack at the notch adopted are on screen already: they only go in the history.
        let adopted = cards.indices.filter(CardQueue.isAdopted)
        if !adopted.isEmpty { record(adopted.map { cards[$0] }, missed: false, locked: locked, console: console) }
        let cards = cards.indices.filter { !adopted.contains($0) }.map { cards[$0] }
        guard !cards.isEmpty, let cards = holdWhileLocked(cards, locked: locked, console: console), !cards.isEmpty
        else {
            return ExitStatus.shown
        }
        var adopting = false
        if case .pool = locked {
            // However long the cards were held, a background drip never outlives them by much.
            BackgroundWatchdog.extend(by: cards.reduce(0) { $0 + $1.duration } + 600)
            adopting = true
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var failed = false
        // A question replaced before it showed was never answered.
        var unanswered = false
        var remaining = cards[...]
        let queuedAt = CardQueue.queuedAt
        func next() {
            guard var card = remaining.popFirst() else { return stopApplication() }
            if CardQueue.isReplaced(card) {
                unanswered = unanswered || card.asksQuestion
                return next()
            }
            // Dismissed before its turn came, by `drip dismiss` or because the agent moved on.
            if DismissRequests(environment: ProcessInfo.processInfo.environment).load()
                .dismisses(id: card.id, since: queuedAt)
            {
                unanswered = unanswered || card.asksQuestion
                return next()
            }
            if let stack = StackPresenter.make(
                for: card, rest: &remaining, adopting: adopting, settings: settings, console: console) {
                return stack.start { ok in
                    failed = failed || !ok
                    next()
                }
            }
            // Shown alone, a card with more of this drip's cards after it does not keep them waiting.
            if !remaining.isEmpty { card.waitLimit = nil }
            guard let presenter = CardPresenters.make(for: card, console: console) else {
                console.error("no GUI session: no screen to show the card on")
                failed = true
                return next()
            }
            let watch = ReplacementWatch(presenter: presenter, card: card, background: adopting)
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
        return ExitStatus.answered(missed: CardActions.missed || unanswered, declined: CardActions.declined)
    }

    /// Shows on the cards another drip's stack handed on, in that drip's place in the queue, as a
    /// background drip, and returns once they have gone.
    func resume(_ handOff: StackHandOff, console: Console) -> Int32 {
        guard CGSessionCopyCurrentDictionary() != nil else { return ExitStatus.noGUISession }
        CardQueue.join()
        BackgroundWatchdog.extend(by: handOff.cards.reduce(0) { $0 + $1.remaining } + 600)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let stack = StackPresenter.resume(handOff, console: console) else { return ExitStatus.noGUISession }
        DispatchQueue.main.async { stack.start { _ in stopApplication() } }
        app.run()
        return ExitStatus.shown
    }

    func showInBackground(_ request: BackgroundRequest, console: Console) -> Int32 {
        guard CGSessionCopyCurrentDictionary() != nil else {
            console.error("no GUI session: cards need a logged-in macOS desktop (for example, not over ssh)")
            return ExitStatus.noGUISession
        }
        if BackgroundDrip.start(request) { return ExitStatus.shown }
        console.warn("cannot start a background drip; showing the card here instead")
        return show(request.cards, locked: .wait(record: request.record), console: console)
    }

    private func record(_ cards: [Card], missed: Bool, locked: LockedScreen, console: Console) {
        do {
            try locked.record(
                cards, missed: missed, in: CardHistory(environment: ProcessInfo.processInfo.environment),
                shown: IslandLayers.shownText)
        } catch {
            console.warn("cannot record the card in the history: \(error)")
        }
    }

    /// Records the cards in the history, first holding them while the screen is locked or drip is
    /// paused. Returns the cards to show now, in this drip's turn, or nil when another drip shows
    /// them once the screen unlocks and the pause ends.
    private func holdWhileLocked(_ cards: [Card], locked: LockedScreen, console: Console) -> [Card]? {
        let environment = ProcessInfo.processInfo.environment
        func record(_ cards: [Card], missed: Bool) {
            self.record(cards, missed: missed, locked: locked, console: console)
        }
        /// Gives up the turn until the screen unlocks and any pause ends, so other drips can hold
        /// their cards too, and waits again if either starts before the turn comes back.
        func waitUntilBack() {
            repeat {
                CardQueue.leave()
                Away.waitUntilBack()
                CardQueue.waitForTurn()
            } while Away.isAway
        }

        switch locked {
        case .wait:
            let screenLocked = ScreenLock.isLocked
            let pause = DripPause(environment: environment).end()
            record(cards, missed: screenLocked || pause != nil)
            // This drip blocks its script until then, so say why.
            if screenLocked {
                console.warn("the screen is locked, so drip waits for the unlock to show the card (Ctrl-C to stop)")
                waitUntilBack()
            } else if let pause {
                console.warn(
                    "drip is paused, \(DripPause.describe(seconds: pause.timeIntervalSinceNow)) left, so drip waits "
                        + "for the pause to end to show the card (Ctrl-C to stop, drip resume to unpause)")
                waitUntilBack()
            }
            return cards
        case .pool:
            let held = HeldCards(environment: environment)
            let admission: HeldCards.Admission
            do {
                admission = try held.admit(cards, locked: Away.isAway, pid: getpid())
            } catch {
                console.warn("cannot hold cards while the screen is locked or drip is paused: \(error)")
                record(cards, missed: false)
                return cards
            }
            switch admission {
            case let .show(leftovers):
                record(cards, missed: false)
                let ids = Set(cards.compactMap(\.id))
                let stale = leftovers.filter { $0.id.map { !ids.contains($0) } ?? true }
                return MissedSummary.cards(for: CardReplacement.latest(stale)) + cards
            case .held:
                record(cards, missed: true)
                return nil
            case .holding:
                record(cards, missed: true)
                waitUntilBack()
                do {
                    return MissedSummary.cards(for: CardReplacement.latest(try held.release()))
                } catch {
                    console.warn("cannot read the cards held while the screen was locked or drip was paused: \(error)")
                    return cards
                }
            }
        }
    }

    /// Loads each card's sound and icon now, so a problem is reported before drip returns: a sound
    /// that cannot play is dropped, and an icon that cannot load falls back to the preset's.
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
            if let problem = CardIcon.problem(card.icon), CardIcon(card.icon, pointSize: 28) == nil {
                console.warn("\(problem); using the preset's icon")
                card.icon = card.fallbackIcon
            }
            // A click brings forward the terminal that shows the card's tmux pane now, which may not
            // be the one that started tmux.
            if let pane = card.pane, let app = Terminal.app(showing: pane) {
                card.activate = app
            }
            return card
        }
    }

    func isInstalled(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    var hasGUISession: Bool { CGSessionCopyCurrentDictionary() != nil }

    func front(of card: Card) -> WhenFocused.Front {
        // In tmux, the terminal that shows the pane now, which `prepare` makes the click's target too.
        let target = card.pane.flatMap(Terminal.app(showing:)) ?? card.activate
        let app = target.map { $0 == NSWorkspace.shared.frontmostApplication?.bundleIdentifier } ?? false
        // Any keyboard or mouse event, which macOS tells without the Input Monitoring permission.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return WhenFocused.Front(app: app, idle: idle)
    }

    func paneShowing(_ card: Card) -> Bool? {
        card.pane.flatMap(Terminal.isShowing)
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

    /// Whether the card is fully in and not yet leaving, so another card can take its place.
    var canReplace: Bool { get }

    /// Shows `card` in place of the current one, with its sound, and restarts the time it stays.
    func replace(with card: Card)

    /// Ends the wait of a card that waits for you, as another card waits for its turn: it counts
    /// down from now like any other card.
    func stopWaiting()

    /// Takes the card away without bringing anything forward, as a click on its × does.
    func dismiss()
}

/// While a card is on screen, looks for a newer card with the same id from another drip, and swaps
/// it in place of the shown one; takes the card away when `drip dismiss`, or the agent moving on,
/// asks; and in a background drip, puts the card away to show once a pause that starts ends.
final class ReplacementWatch {
    private let presenter: CardPresenting
    /// The card on screen, and the ticket it came from.
    private var current: Card
    private var source: String
    /// When the card on screen came, in seconds since 1970: a dismissal asked for later leaves it.
    private var since: Double
    /// Whether this is a background drip, whose card a pause puts away.
    private let background: Bool
    private var timer: Timer?

    init(presenter: CardPresenting, card: Card, background: Bool) {
        self.presenter = presenter
        current = card
        source = CardQueue.mine?.name ?? ""
        since = CardQueue.queuedAt
        self.background = background
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.look() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func look() {
        let environment = ProcessInfo.processInfo.environment
        if DismissRequests(environment: environment).load().dismisses(id: current.id, since: since) {
            stop()
            presenter.dismiss()
            return
        }
        if background, !current.asksQuestion, DripPause(environment: environment).isPaused() {
            // Paused for a screen share or a meeting: the card goes, and shows once the pause ends.
            stop()
            presenter.dismiss()
            _ = BackgroundDrip.start(BackgroundRequest(cards: [current], record: false))
            return
        }
        guard CardQueue.mine != nil, current.id != nil || current.waits else { return }
        if presenter.canReplace, let found = CardQueue.replacement(for: current, after: source),
           let id = found.card.id
        {
            // Claimed first, so the newer drip never shows the card too.
            CardQueue.claim(id, in: found.ticket)
            presenter.replace(with: found.card)
            current = found.card
            source = found.ticket
            since = QueueTicket.queuedAt(found.ticket) ?? Date().timeIntervalSince1970
            return
        }
        // A card that waits for you gives way to a newer drip waiting for its turn; a question never
        // does, and the newer drip waits for its answer.
        if current.waits, !current.waitsForAnswer,
           !CardQueue.waiting(except: Set([current.id].compactMap { $0 })).isEmpty
        {
            presenter.stopWaiting()
        }
    }
}

enum CardPresenters {
    /// The card's island, grown out of the notch of the screen with the pointer, or out of the
    /// middle of its top edge on a screen without one. Nil when there is no screen.
    static func make(for card: Card, console: Console) -> CardPresenting? {
        guard let screen = targetScreen() else { return nil }
        return IslandPresenter(card: card, notch: NotchGeometry.island(on: screen), console: console)
    }

    /// The screen with the pointer, falling back to the main screen.
    static func targetScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Has VoiceOver read `card` out as it shows. The panels never take focus, so VoiceOver would
    /// not move to them on its own. A failure, a question or a card that stays interrupts what it is
    /// reading.
    static func announce(_ card: Card) {
        let priority: NSAccessibilityPriorityLevel = card.isUrgent ? .high : .medium
        NSAccessibility.post(
            element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [
                .announcement: CardText.spoken(title: card.title, detail: card.detail),
                .priority: priority.rawValue,
            ])
    }

    /// The card's motion setting, capped by Reduce Motion.
    static func motion(for card: Card) -> Motion {
        card.motion.capped(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// The strong ease-out every entrance and exit uses.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

    /// Animates window changes, then runs `next` on a timer. Animation completion handlers never
    /// fire while the display sleeps or the screen is locked, and drip must still exit then.
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
#endif
