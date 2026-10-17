#if canImport(AppKit)
import AppKit
import BlipCore
import QuartzCore

extension CardColor {
    var nsColor: NSColor {
        switch self {
        case let .system(name):
            switch name {
            case .green: return .systemGreen
            case .orange: return .systemOrange
            case .red: return .systemRed
            case .blue: return .systemBlue
            case .purple: return .systemPurple
            case .pink: return .systemPink
            case .yellow: return .systemYellow
            case .gray: return .systemGray
            }
        case let .rgb(red, green, blue):
            return NSColor(
                srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }
}

/// The card's background: the HUD material with rounded corners and the accent border.
final class CardBackgroundView: NSVisualEffectView {
    var accent: NSColor = .clear {
        didSet { updateBorderColor() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = CardMetrics.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = CardMetrics.borderWidth
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    /// A layer's CGColor does not follow appearance changes, so resolve it for the current one.
    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.borderColor = self.accent.withAlphaComponent(CardMetrics.borderAlpha).cgColor
        }
    }
}

/// Builds the view tree for a card, laid out by `CardLayout`.
enum CardViewBuilder {
    /// - Parameter appearance: Forces light or dark; nil follows the system.
    static func makeView(for card: Card, appearance: NSAppearance?, console: Console) -> CardBackgroundView {
        let metrics = CardMetrics(size: card.size)
        let accent = card.color.nsColor

        let title = makeLabel(
            card.title, font: .systemFont(ofSize: metrics.titleFontSize, weight: .semibold), color: .labelColor)
        let detail = card.detail.map {
            makeLabel($0, font: .systemFont(ofSize: metrics.detailFontSize, weight: .regular),
                      color: .secondaryLabelColor)
        }
        let icon = symbolImage(for: card, pointSize: metrics.iconSize, console: console)
        // Measure with each label's own fitting size so the text sits exactly where it is drawn.
        let layout = CardLayout(
            metrics: metrics, titleSize: title.fittingSize, detailSize: detail?.fittingSize, hasIcon: icon != nil)

        let background = CardBackgroundView(frame: NSRect(origin: .zero, size: layout.size))
        background.appearance = appearance
        background.accent = accent

        if let icon, let iconFrame = layout.iconFrame {
            let iconView = NSImageView(frame: iconFrame)
            iconView.image = icon
            iconView.imageScaling = .scaleProportionallyDown
            iconView.contentTintColor = accent
            background.addSubview(iconView)
        }
        title.frame = layout.titleFrame
        background.addSubview(title)
        if let detail, let detailFrame = layout.detailFrame {
            detail.frame = detailFrame
            background.addSubview(detail)
        }
        return background
    }

    private static func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        // Right-to-left text hugs the right edge of the text column; the icon stays put.
        label.alignment = CardText.isRightToLeft(text) ? .right : .left
        return label
    }

    /// The card's symbol at the spec's size and weight. An unknown symbol name falls back to the
    /// preset's icon with a warning.
    private static func symbolImage(for card: Card, pointSize: CGFloat, console: Console) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        func image(_ icon: Icon) -> NSImage? {
            guard case let .symbol(name) = icon else { return nil }
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        }
        guard case let .symbol(name) = card.icon else { return nil }
        if let found = image(card.icon) { return found }
        console.warn("unknown SF Symbol '\(name)'; using the preset's icon")
        return image(card.fallbackIcon)
    }
}

/// Shows cards in a borderless, non-activating panel.
struct HUDDisplay: CardDisplay {
    func show(_ card: Card, console: Console) -> Int32 {
        // Without a GUI session, touching NSApplication can abort or hang, so check first.
        guard CGSessionCopyCurrentDictionary() != nil else {
            console.error("no GUI session: cards need a logged-in macOS desktop (for example, not over ssh)")
            return ExitStatus.noGUISession
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let presenter = CardPresenter(card: card, console: console)
        // Start once the run loop is running, after the application has finished launching.
        DispatchQueue.main.async {
            presenter.start(onFinish: stopApplication)
        }
        app.run()
        return presenter.failed ? ExitStatus.noGUISession : ExitStatus.shown
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

/// Fades one card in, holds it, fades it out, and lets its sound finish.
final class CardPresenter {
    private let card: Card
    private let console: Console
    private var panel: NSPanel?
    private var sound: NSSound?
    /// True when there was no screen to show the card on.
    private(set) var failed = false

    init(card: Card, console: Console) {
        self.card = card
        self.console = console
    }

    /// Shows the card and calls `onFinish` once it is gone, or at once when there is no screen.
    func start(onFinish: @escaping () -> Void) {
        guard let screen = Self.targetScreen() else {
            console.error("no GUI session: no screen to show the card on")
            failed = true
            onFinish()
            return
        }
        let content = CardViewBuilder.makeView(for: card, appearance: nil, console: console)
        let origin = CardLayout.origin(for: content.frame.size, in: screen.visibleFrame, position: card.position)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: content.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = content
        self.panel = panel

        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animated ? 0 : 1
        // Never makeKey or activate: the frontmost app keeps focus.
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        sound = makeSound(card.sound)
        sound?.play()

        fade(to: 1, duration: CardMetrics.fadeInDuration, timing: .easeOut, animated: animated) { [self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + card.seconds) { [self] in
                fade(to: 0, duration: CardMetrics.fadeOutDuration, timing: .easeIn, animated: animated) { [self] in
                    panel.orderOut(nil)
                    waitForSound(then: onFinish)
                }
            }
        }
    }

    /// The screen with the pointer, falling back to the main screen.
    private static func targetScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func fade(
        to alpha: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunctionName, animated: Bool,
        completion: @escaping () -> Void
    ) {
        guard let panel else { return }
        guard animated else {
            panel.alphaValue = alpha
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            panel.animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    private func makeSound(_ sound: Sound) -> NSSound? {
        switch sound {
        case .none:
            return nil
        case let .named(name):
            if let found = NSSound(named: NSSound.Name(name)) { return found }
            console.warn("unknown sound '\(name)'; system sounds are in /System/Library/Sounds")
        case let .file(path):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if let found = NSSound(contentsOf: url, byReference: true) { return found }
            console.warn("cannot play sound file '\(path)'")
        }
        return nil
    }

    /// Exiting would cut the sound off, so wait for it when it outlasts the card.
    private func waitForSound(then finish: @escaping () -> Void) {
        guard let sound, sound.isPlaying else {
            finish()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            waitForSound(then: finish)
        }
    }
}
#endif
