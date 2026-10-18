#if canImport(AppKit)
import AppKit
import BlipCore
import QuartzCore

/// The camera notch on a screen, from AppKit's safe area.
struct NotchGeometry {
    /// The notch's width and height in points.
    var width: CGFloat
    var height: CGFloat
    /// The notch's horizontal center, in screen coordinates.
    var midX: CGFloat
    /// The screen's top edge, in screen coordinates.
    var top: CGFloat

    /// Nil for a screen without a notch.
    init?(screen: NSScreen) {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX
        else { return nil }
        width = right.minX - left.maxX
        height = screen.safeAreaInsets.top
        midX = (left.maxX + right.minX) / 2
        top = screen.frame.maxY
    }

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
        midX = 0
        top = 0
    }
}

/// The island's layer tree: the black shape, the icon, the countdown ring and the text. The live
/// panel and the offscreen renderer both draw it.
///
/// The root layer is flipped, so y grows down from the top of the screen like the island's own
/// coordinates; x is offset so the notch's center is the layer's center.
final class IslandLayers {
    let card: Card
    let metrics: IslandMetrics
    let size: CGSize
    let root = CALayer()
    let shape = CAShapeLayer()
    /// Holds the icon, ring and text; for `droplet` it clips them to the drop.
    let content = CALayer()
    let icon = CALayer()
    /// The countdown ring, or a button in its place.
    let ring = CALayer()
    let ringProgress = CAShapeLayer()
    let text = CALayer()
    let title = CATextLayer()
    let detail = CATextLayer()
    private let iconSide: CGFloat
    private let ringSide: CGFloat
    private let textSize: CGSize

    init(card: Card, notch: NotchGeometry, scale: CGFloat, console: Console) {
        self.card = card
        let sizeScale = CGFloat(card.size.scale)
        let accent = card.color.nsColor
        let titleFont = NSFont.systemFont(ofSize: 14 * sizeScale, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: 12 * sizeScale, weight: .regular)
        let compactFont = NSFont.systemFont(ofSize: 12.5 * sizeScale, weight: .semibold)
        let compact = card.notch == .ears
        let maxText = CardMetrics.maxWidth - 140 * sizeScale
        // The ears title sits in the right ear, which stops at half the widest card.
        let titleText = Self.line(
            card.title, attributes: [.font: compact ? compactFont : titleFont, .foregroundColor: NSColor.white],
            width: compact ? CardMetrics.maxWidth / 2 - 26 * sizeScale : maxText)
        let detailText = card.detail.map {
            Self.line(
                $0, attributes: [.font: detailFont, .foregroundColor: NSColor(white: 0.62, alpha: 1)], width: maxText)
        }
        let titleSize = Self.measure(titleText, maxWidth: maxText)
        let detailSize = compact ? .zero : detailText.map { Self.measure($0, maxWidth: maxText) } ?? .zero
        let spacing = detailText == nil || compact ? 0 : 3 * sizeScale
        textSize = CGSize(
            width: max(titleSize.width, detailSize.width), height: titleSize.height + spacing + detailSize.height)
        let image = CardViewBuilder.symbolImage(for: card, pointSize: 28 * sizeScale, console: console)
        // ears has no room for a button; the whole island is clickable there instead.
        let buttonLabel = card.notch == .ears ? nil : card.action.map {
            NSAttributedString(string: $0.label, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5 * sizeScale, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
        }
        let buttonSize = buttonLabel.map { CGSize(width: ceil($0.size().width) + 24 * sizeScale, height: 26 * sizeScale) }
        metrics = IslandMetrics(
            notchWidth: Double(notch.width), notchHeight: Double(notch.height), scale: Double(sizeScale),
            textWidth: Double(textSize.width), textHeight: Double(textSize.height),
            compactTitleWidth: Double(titleSize.width), hasIcon: image != nil,
            actionWidth: Double(buttonSize?.width ?? 0))
        size = CGSize(width: ceil(metrics.maxWidth) + 40, height: ceil(metrics.maxHeight))
        iconSide = 28 * sizeScale
        ringSide = buttonSize?.width ?? 22 * sizeScale

        root.frame = CGRect(origin: .zero, size: size)
        root.isGeometryFlipped = true
        root.contentsScale = scale

        shape.frame = root.bounds
        shape.fillColor = NSColor.black.cgColor
        shape.contentsScale = scale
        root.addSublayer(shape)
        content.frame = root.bounds
        content.masksToBounds = card.notch == .droplet
        root.addSublayer(content)

        // The icon is drawn at its largest and scaled down, so it stays sharp as it grows.
        icon.bounds = CGRect(x: 0, y: 0, width: iconSide, height: iconSide)
        icon.contentsScale = scale
        icon.contentsGravity = .resizeAspect
        if let image {
            // White mark on an accent disc for the built-in symbols; one-layer symbols draw white.
            let palette = NSImage.SymbolConfiguration(paletteColors: [.white, accent])
            let tinted = image.withSymbolConfiguration(palette) ?? image
            icon.contents = tinted.layerContents(forContentsScale: scale)
        }
        icon.opacity = 0
        content.addSublayer(icon)

        if let buttonLabel, let buttonSize {
            makeButton(buttonLabel, size: buttonSize, accent: accent, scale: scale)
        } else {
            makeRing(accent: accent, lineWidth: 2.4 * sizeScale, scale: scale)
        }
        ring.opacity = 0
        content.addSublayer(ring)

        text.bounds = CGRect(origin: .zero, size: textSize)
        text.anchorPoint = CGPoint(x: 0, y: 0.5)
        title.string = titleText
        title.frame = CGRect(x: 0, y: 0, width: textSize.width, height: titleSize.height)
        title.truncationMode = .end
        title.contentsScale = scale
        title.opacity = 0
        text.addSublayer(title)
        if let detailText, !compact {
            detail.string = detailText
            detail.frame = CGRect(x: 0, y: titleSize.height + spacing, width: textSize.width, height: detailSize.height)
            detail.truncationMode = .end
            detail.contentsScale = scale
            detail.opacity = 0
            text.addSublayer(detail)
        }
        content.addSublayer(text)
    }

    /// The button that stands where the ring would: a capsule in the darkened accent.
    private func makeButton(_ label: NSAttributedString, size: CGSize, accent: NSColor, scale: CGFloat) {
        ring.bounds = CGRect(origin: .zero, size: size)
        let fill = CAShapeLayer()
        fill.path = CGPath(
            roundedRect: ring.bounds, cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil)
        let rgb = accent.rgb(in: NSAppearance(named: .aqua) ?? .currentDrawing())
        fill.fillColor = NSColor(WashPalette(accent: rgb).top).cgColor
        fill.contentsScale = scale
        ring.addSublayer(fill)
        let text = CATextLayer()
        text.string = label
        let textSize = label.size()
        text.frame = CGRect(
            x: (size.width - ceil(textSize.width)) / 2, y: (size.height - ceil(textSize.height)) / 2,
            width: ceil(textSize.width), height: ceil(textSize.height))
        text.contentsScale = scale
        ring.addSublayer(text)
    }

    /// The countdown ring: a faint track and the accent arc that drains.
    private func makeRing(accent: NSColor, lineWidth: CGFloat, scale: CGFloat) {
        ring.bounds = CGRect(x: 0, y: 0, width: ringSide, height: ringSide)
        let circle = CGPath(
            ellipseIn: CGRect(x: 0, y: 0, width: ringSide, height: ringSide).insetBy(dx: 1.6, dy: 1.6),
            transform: nil)
        let track = CAShapeLayer()
        track.path = circle
        track.fillColor = nil
        track.strokeColor = accent.withAlphaComponent(0.28).cgColor
        track.lineWidth = lineWidth
        track.contentsScale = scale
        ringProgress.path = circle
        ringProgress.fillColor = nil
        ringProgress.strokeColor = accent.cgColor
        ringProgress.lineWidth = lineWidth
        ringProgress.lineCap = .round
        ringProgress.contentsScale = scale
        // Start at twelve o'clock and drain clockwise.
        ringProgress.frame = ring.bounds
        ringProgress.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        track.frame = ring.bounds
        ring.addSublayer(track)
        ring.addSublayer(ringProgress)
    }

    /// One line of text cut to fit `width` with an ellipsis. The island never leaves the cut to its
    /// text layers: on a Mac, an island handed a line wider than its text layer did not show at all,
    /// and fitting the line first makes it show (confirmed before and after on a Mac). The exact
    /// AppKit/Core Animation mechanism, why an unfitted string in the text layer hid the whole
    /// island, is not proven.
    private static func line(
        _ text: String, attributes: [NSAttributedString.Key: Any], width: CGFloat
    ) -> NSAttributedString {
        let fitted = CardText.fit(text, width: Double(width)) {
            Double(ceil(NSAttributedString(string: $0, attributes: attributes).size().width))
        }
        return NSAttributedString(string: fitted, attributes: attributes)
    }

    private static func measure(_ text: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let size = text.size()
        return CGSize(width: min(ceil(size.width), maxWidth), height: ceil(size.height))
    }

    /// The island's x = 0 in layer coordinates.
    var centerX: CGFloat { size.width / 2 }

    /// Every layer's model values at one instant.
    struct Frame {
        var path: CGPath
        var iconPosition: CGPoint
        var iconScale: CGFloat
        var ringPosition: CGPoint
        var ringScale: CGFloat
        var textPosition: CGPoint
        /// The content's clip, in the root's coordinates: the drop for `droplet`, else everything.
        var clip: CGRect
        var clipRadius: CGFloat
    }

    func frame(_ islandShape: IslandShape, layout: IslandContentLayout) -> Frame {
        let clip = card.notch == .droplet
            ? CGRect(
                x: centerX - islandShape.pillWidth / 2, y: islandShape.pillTop, width: islandShape.pillWidth,
                height: islandShape.pillHeight)
            : root.bounds
        return Frame(
            path: IslandPath.make(islandShape, metrics: metrics, motion: card.notch, centerX: centerX),
            iconPosition: CGPoint(x: centerX + layout.iconCenter.x, y: layout.iconCenter.y),
            iconScale: CGFloat(layout.iconSize) / iconSide,
            ringPosition: CGPoint(x: centerX + layout.ringCenter.x, y: layout.ringCenter.y),
            ringScale: CGFloat(layout.ringSize) / ringSide,
            textPosition: CGPoint(x: centerX + layout.textX, y: layout.textCenterY),
            clip: clip, clipRadius: card.notch == .droplet ? min(clip.width, clip.height) / 2 : 0)
    }

    /// Sets the model values without implicit animations.
    func apply(_ frame: Frame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = frame.path
        icon.position = frame.iconPosition
        icon.transform = CATransform3DMakeScale(frame.iconScale, frame.iconScale, 1)
        ring.position = frame.ringPosition
        ring.transform = CATransform3DMakeScale(frame.ringScale, frame.ringScale, 1)
        text.position = frame.textPosition
        // Bounds that start where the frame does keep the content in the root's coordinates.
        content.bounds = frame.clip
        content.position = CGPoint(x: frame.clip.midX, y: frame.clip.midY)
        content.cornerRadius = frame.clipRadius
        CATransaction.commit()
    }

    /// Shows the content at once, for reduced motion and offscreen rendering.
    func showContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [icon, ring, title, detail] { layer.opacity = 1 }
        if card.notch == .ears { ring.opacity = 0 }
        if !metrics.hasIcon { icon.opacity = 0 }
        CATransaction.commit()
    }

    /// Sets the content's opacity as the exit fades leave it `time` seconds in.
    func hideContent(at time: Double, cues: IslandCues) {
        func faded(_ cue: Double?, over duration: Double = IslandCues.fadeOut) -> Float {
            Float(IslandCues.opacity(leaving: cue, over: duration, at: time))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.opacity = metrics.hasIcon ? faded(cues.icon, over: cues.iconFadeOut) : 0
        ring.opacity = card.notch == .ears ? 0 : faded(cues.ring)
        title.opacity = faded(cues.title)
        detail.opacity = faded(cues.detail)
        CATransaction.commit()
    }

    /// Sets the content's opacity as the entrance fades leave it `time` seconds in.
    func showContent(at time: Double, cues: IslandCues) {
        func faded(_ cue: Double?, _ duration: Double) -> Float {
            guard let cue else { return 0 }
            let linear = min(max((time - cue) / duration, 0), 1)
            return Float(1 - pow(1 - linear, 3))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.opacity = metrics.hasIcon ? faded(cues.icon, 0.18) : 0
        ring.opacity = faded(cues.ring, 0.18)
        title.opacity = faded(cues.title, 0.25)
        detail.opacity = faded(cues.detail, 0.25)
        CATransaction.commit()
    }
}

/// The island's outline as one path: the shape hanging from the top edge, and for `droplet` the drop,
/// traced where it melts into the notch. Every part winds the same way, so overlaps fill as a union.
enum IslandPath {
    static func make(_ shape: IslandShape, metrics: IslandMetrics, motion: NotchMotion, centerX: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let x = { (value: Double) in centerX + CGFloat(value) }
        let halfNotch = metrics.notchWidth / 2

        // The hanging shape: down the left side, across the bottom, up the right side.
        let left = shape.left, right = shape.right, height = CGFloat(shape.height)
        let radius = CGFloat(shape.radius(metrics))
        let leftFlare = CGFloat(IslandShape.shoulder(overhang: -halfNotch - left))
        let rightFlare = CGFloat(IslandShape.shoulder(overhang: right - halfNotch))
        path.move(to: CGPoint(x: x(left) - leftFlare, y: 0))
        path.addQuadCurve(to: CGPoint(x: x(left), y: leftFlare), control: CGPoint(x: x(left), y: 0))
        path.addArc(
            tangent1End: CGPoint(x: x(left), y: height), tangent2End: CGPoint(x: x(right), y: height), radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: x(right), y: height), tangent2End: CGPoint(x: x(right), y: 0), radius: radius)
        path.addLine(to: CGPoint(x: x(right), y: rightFlare))
        path.addQuadCurve(to: CGPoint(x: x(right) + rightFlare, y: 0), control: CGPoint(x: x(right), y: 0))
        path.closeSubpath()

        guard motion == .droplet else { return path }

        let field = DropletField(metrics: metrics, shape: shape)
        if field.touchesNotch {
            // Traced from just inside the notch, where the notch's own shape covers the cut.
            let top = metrics.notchHeight - 4 * metrics.scale
            for loop in field.outline(above: top, cell: 0.5) {
                guard let first = loop.first else { continue }
                path.move(to: CGPoint(x: x(first.x), y: CGFloat(first.y)))
                for point in loop.dropFirst() { path.addLine(to: CGPoint(x: x(point.x), y: CGFloat(point.y))) }
                path.closeSubpath()
            }
            return path
        }

        // Free of the notch, the drop is an exact capsule, same winding: down the left, across the
        // bottom, up the right, back across the top.
        let top = CGFloat(shape.pillTop), pillHeight = CGFloat(shape.pillHeight)
        let pillLeft = x(-shape.pillWidth / 2), pillRight = x(shape.pillWidth / 2), bottom = top + pillHeight
        let pillRadius = min(pillHeight / 2, CGFloat(shape.pillWidth) / 2)
        let corners = [
            CGPoint(x: pillLeft, y: bottom), CGPoint(x: pillRight, y: bottom), CGPoint(x: pillRight, y: top),
            CGPoint(x: pillLeft, y: top), CGPoint(x: pillLeft, y: bottom),
        ]
        path.move(to: CGPoint(x: pillLeft, y: top + pillRadius))
        for index in 0..<4 {
            path.addArc(tangent1End: corners[index], tangent2End: corners[index + 1], radius: pillRadius)
        }
        path.closeSubpath()
        return path
    }
}

/// The island's view: reports the pointer and clicks, without ever taking focus.
final class IslandView: NSView {
    var onMove: ((CGPoint) -> Void)?
    var onClick: ((CGPoint) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onMove?(CGPoint(x: -1, y: -1)) }
    override func mouseUp(with event: NSEvent) { onClick?(convert(event.locationInWindow, from: nil)) }
}

/// A panel AppKit lets cover the menu bar: windows are normally pushed below it.
final class IslandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Grows a card out of the notch, holds it while the ring drains, and takes it back in.
final class IslandPresenter: CardPresenting {
    private var card: Card
    private let notch: NotchGeometry
    private let console: Console
    private var panel: IslandPanel?
    private var sound: CardSound?
    private var layers: IslandLayers?
    private var onFinish: ((Bool) -> Void)?
    /// When the card is fully in.
    private var openAt = CFTimeInterval.infinity

    /// Keyframes per second when sampling the springs.
    private static let framesPerSecond = 240.0

    init(card: Card, notch: NotchGeometry, console: Console) {
        self.card = card
        self.notch = notch
        self.console = console
    }

    func start(onFinish: @escaping (Bool) -> Void) {
        self.onFinish = onFinish
        let scale = CardPresenters.targetScreen()?.backingScaleFactor ?? 2
        let layers = IslandLayers(card: card, notch: notch, scale: scale, console: console)
        self.layers = layers
        let frame = self.frame(for: layers)
        let panel = IslandPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the menu bar, so the island can cover it.
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // When clickable, keep AppKit's default: clicks on the island's transparent surroundings
        // still reach the menu bar beneath.
        if !card.isClickable { panel.ignoresMouseEvents = true }
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // A sublayer of AppKit's backing layer, so AppKit can't reset the root's flipped geometry.
        let view = IslandView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.onMove = { [weak self] point in self?.pointer(at: point) }
        view.onClick = { [weak self] point in self?.click(at: point) }
        view.layer?.addSublayer(layers.root)
        panel.contentView = view
        panel.setFrame(frame, display: false)
        self.panel = panel

        var animator = IslandAnimator(motion: card.notch, metrics: layers.metrics)
        layers.apply(layers.frame(animator.shape(at: 0), layout: animator.content(for: animator.shape(at: 0))))
        panel.orderFrontRegardless()
        sound = CardSound(card.sound, console: console)

        let motion = CardPresenters.motion(for: card)
        guard motion == .full else {
            sound?.play()
            animator.open()
            let open = animator.shape(at: 0)
            layers.apply(layers.frame(open, layout: animator.content(for: open)))
            layers.showContent()
            panel.alphaValue = motion == .none ? 1 : 0
            fadePanel(to: 1, duration: motion == .none ? 0 : 0.15)
            departure = fadingDeparture(motion)
            openAt = CACurrentMediaTime() + 0.15
            schedule(after: 0.15 + card.seconds)
            return
        }

        // One clock for the whole card: each new target springs from wherever the last one left things.
        // It starts once the keyframes are built, when the animations really begin.
        let enterCues = animator.enter(at: 0)
        play(animator, from: 0, layers: layers)
        let started = CACurrentMediaTime()
        // The sound lands as the island first shows: the droplet starts hidden in the notch.
        let audible = card.notch == .droplet ? 0.05 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + audible) { [self] in sound?.play() }
        fade(enterCues, into: true, layers: layers)
        let visible = (enterCues.title ?? 0) + 0.25
        drain(after: visible, layers: layers)
        departure = springingDeparture(animator, started: started, layers: layers)
        openAt = started + visible
        schedule(after: visible + card.seconds)
    }

    var canReplace: Bool { departure != nil && CACurrentMediaTime() >= openAt }

    /// Rebuilds the island for `card` fully open, with its text fading in, and restarts the ring.
    func replace(with card: Card) {
        guard canReplace, let panel, let view = panel.contentView, let old = layers else { return }
        self.card = card
        let layers = IslandLayers(card: card, notch: notch, scale: old.root.contentsScale, console: console)
        self.layers = layers
        var animator = IslandAnimator(motion: card.notch, metrics: layers.metrics)
        animator.open()
        let open = animator.shape(at: 0)
        layers.apply(layers.frame(open, layout: animator.content(for: open)))
        layers.showContent()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        old.root.removeFromSuperlayer()
        view.layer?.addSublayer(layers.root)
        CATransaction.commit()
        panel.setFrame(frame(for: layers), display: true)
        panel.ignoresMouseEvents = !card.isClickable
        hovering = false
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.18
        fadeIn.timingFunction = CardPresenters.easeOut
        layers.text.add(fadeIn, forKey: "replace")
        sound = CardSound(card.sound, console: console)
        sound?.play()

        let motion = CardPresenters.motion(for: card)
        if motion == .full {
            drain(after: 0, layers: layers)
            departure = springingDeparture(animator, started: CACurrentMediaTime(), layers: layers)
        } else {
            departure = fadingDeparture(motion)
        }
        schedule(after: card.seconds)
        pointer(at: view.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    /// The panel's frame for the island's layers: centered on the notch, hanging from the top.
    private func frame(for layers: IslandLayers) -> NSRect {
        NSRect(
            x: (notch.midX - layers.size.width / 2).rounded(), y: notch.top - layers.size.height,
            width: layers.size.width, height: layers.size.height)
    }

    /// The exit for reduced motion: the panel fades out, or goes at once.
    private func fadingDeparture(_ motion: Motion) -> () -> Void {
        { [self] in
            fadePanel(to: 0, duration: motion == .none ? 0 : 0.25) { [self] in finish() }
        }
    }

    /// The exit for full motion: back into the notch, springing from wherever `animator` has things
    /// on the clock that began at `started`.
    private func springingDeparture(
        _ animator: IslandAnimator, started: CFTimeInterval, layers: IslandLayers
    ) -> () -> Void {
        var animator = animator
        return { [self] in
            let now = CACurrentMediaTime() - started
            let exitCues = animator.exit(at: now)
            play(animator, from: now, layers: layers)
            fade(exitCues, into: false, layers: layers)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(animator.end - now, 0) + 0.02) { [self] in
                finish()
            }
        }
    }

    // MARK: Clicks and hovering, for a clickable card.

    /// Runs the exit once; nil after that.
    private var departure: (() -> Void)?
    private var pending: DispatchWorkItem?
    private var hovering = false

    private func schedule(after seconds: Double) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.leave(clicked: false) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func leave(clicked: Bool) {
        guard let departure else { return }
        self.departure = nil
        pending?.cancel()
        if card.action != nil, !clicked { CardActions.missed = true }
        panel?.ignoresMouseEvents = true
        departure()
    }

    /// Whether a point in the view is on the island as it is drawn right now.
    private func onIsland(_ point: CGPoint) -> Bool {
        guard let layers, let path = (layers.shape.presentation() ?? layers.shape).path else { return false }
        return path.contains(CGPoint(x: point.x, y: layers.size.height - point.y))
    }

    /// Whether a point in the view is on the button as it is drawn right now.
    private func onButton(_ point: CGPoint) -> Bool {
        // ears has no room for a button: the whole island is one.
        guard card.notch != .ears else { return onIsland(point) }
        guard let layers else { return false }
        let shown = layers.ring.presentation() ?? layers.ring
        let rect = (layers.root.presentation() ?? layers.root).convert(shown.bounds, from: shown)
        return rect.insetBy(dx: -4, dy: -4).contains(CGPoint(x: point.x, y: layers.size.height - point.y))
    }

    private func pointer(at point: CGPoint) {
        guard departure != nil, card.isClickable else { return }
        let inside = onIsland(point)
        guard inside != hovering else { return }
        hovering = inside
        if inside {
            // Hold the card and freeze the ring.
            pending?.cancel()
            pause(layers?.ringProgress, paused: true)
        } else {
            pause(layers?.ringProgress, paused: false)
            schedule(after: 1.5)
        }
    }

    /// A click on the button runs its action; anywhere else on the island, it brings the sending
    /// app forward. Either way the card goes.
    private func click(at point: CGPoint) {
        guard departure != nil, card.isClickable, onIsland(point) else { return }
        if let action = card.action, onButton(point) {
            CardActions.perform(action, console: console)
            leave(clicked: true)
            return
        }
        if let target = card.activate { CardActions.activate(target, console: console) }
        leave(clicked: false)
    }

    private func pause(_ layer: CALayer?, paused: Bool) {
        guard let layer else { return }
        if paused {
            let time = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = time
        } else {
            let offset = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - offset
        }
    }

    private func finish() {
        panel?.orderOut(nil)
        sound?.waitUntilDone { [self] in onFinish?(true) }
    }

    /// Samples every spring from `start` until they settle into keyframe animations.
    private func play(_ animator: IslandAnimator, from start: Double, layers: IslandLayers) {
        let end = max(animator.end, start + 0.05)
        let count = Int(((end - start) * Self.framesPerSecond).rounded(.up))
        let frames = (0...count).map { index -> IslandLayers.Frame in
            let shape = animator.shape(at: start + (end - start) * Double(index) / Double(count))
            return layers.frame(shape, layout: animator.content(for: shape))
        }
        let duration = end - start
        func keyframes(_ keyPath: String, _ values: [Any], discrete: Bool = false) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.duration = duration
            animation.calculationMode = discrete ? .discrete : .linear
            return animation
        }
        guard let last = frames.last else { return }
        layers.apply(last)
        // A traced droplet changes its number of points from frame to frame, so its frames can't be
        // blended; at 240 a second, every display frame still gets its own.
        layers.shape.add(keyframes("path", frames.map(\.path), discrete: card.notch == .droplet), forKey: "island")
        layers.content.add(keyframes("bounds", frames.map { NSValue(rect: $0.clip) }), forKey: "island")
        layers.content.add(
            keyframes("position", frames.map { NSValue(point: CGPoint(x: $0.clip.midX, y: $0.clip.midY)) }),
            forKey: "island.position")
        layers.content.add(keyframes("cornerRadius", frames.map(\.clipRadius)), forKey: "island.radius")
        layers.icon.add(keyframes("position", frames.map { NSValue(point: $0.iconPosition) }), forKey: "island")
        layers.icon.add(keyframes("transform.scale", frames.map(\.iconScale)), forKey: "island.scale")
        layers.ring.add(keyframes("position", frames.map { NSValue(point: $0.ringPosition) }), forKey: "island")
        layers.ring.add(keyframes("transform.scale", frames.map(\.ringScale)), forKey: "island.scale")
        layers.text.add(keyframes("position", frames.map { NSValue(point: $0.textPosition) }), forKey: "island")
    }

    /// Fades the content in or out at the cues: 180 ms in with a 4-point rise for text, 120 ms out
    /// unless the cues time the icon's exit fade.
    private func fade(_ cues: IslandCues, into visible: Bool, layers: IslandLayers) {
        let parts: [(CALayer, Double?, Bool)] = [
            (layers.icon, layers.metrics.hasIcon ? cues.icon : nil, false), (layers.ring, cues.ring, false),
            (layers.title, cues.title, true), (layers.detail, cues.detail, true),
        ]
        let now = CACurrentMediaTime()
        for (layer, cue, isText) in parts {
            guard let cue else { continue }
            let fadeOut = layer === layers.icon ? cues.iconFadeOut : IslandCues.fadeOut
            let duration = visible ? (isText ? 0.25 : 0.18) : fadeOut
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = visible ? 0 : 1
            opacity.toValue = visible ? 1 : 0
            let group = CAAnimationGroup()
            group.animations = [opacity]
            if visible, isText {
                let rise = CABasicAnimation(keyPath: "transform.translation.y")
                rise.fromValue = 4
                rise.toValue = 0
                group.animations?.append(rise)
            }
            group.beginTime = now + cue
            group.duration = duration
            group.timingFunction = CardPresenters.easeOut
            group.fillMode = .backwards
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = visible ? 1 : 0
            CATransaction.commit()
            layer.add(group, forKey: "fade")
        }
    }

    /// Drains the countdown ring over the card's seconds, starting `delay` from now.
    private func drain(after delay: Double, layers: IslandLayers) {
        let drain = CABasicAnimation(keyPath: "strokeEnd")
        drain.fromValue = 1
        drain.toValue = 0
        drain.beginTime = CACurrentMediaTime() + delay
        drain.duration = card.seconds
        drain.fillMode = .both
        drain.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers.ringProgress.strokeEnd = 0
        CATransaction.commit()
        layers.ringProgress.add(drain, forKey: "drain")
    }

    private func fadePanel(to alpha: CGFloat, duration: Double, completion: (() -> Void)? = nil) {
        guard let panel else { return }
        guard duration > 0 else {
            panel.alphaValue = alpha
            completion?()
            return
        }
        CardPresenters.animate(duration: duration, { panel.animator().alphaValue = alpha }, then: completion)
    }
}
#endif
