#if canImport(AppKit)
import AppKit
import DripCore
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

    /// Where an island hangs on `screen`: from its notch, or on a screen without one, from the middle
    /// of its top edge, as if from a notch of no height. The drop then forms above the screen and
    /// oozes out of its edge, and nothing is drawn for the notch itself.
    static func island(on screen: NSScreen) -> NotchGeometry {
        NotchGeometry(screen: screen) ?? NotchGeometry(edgeOf: screen)
    }

    private init(edgeOf screen: NSScreen) {
        width = 160
        height = 0
        midX = screen.frame.midX
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
    /// Holds the icon, ring and text, clipped to the drop.
    let content = CALayer()
    let icon = CALayer()
    /// The countdown ring, or in its place the buttons, or the waiting mark of a card that waits.
    let ring = CALayer()
    let ringProgress = CAShapeLayer()
    /// Each button's place in `ring`, its capsule, and the capsule's two fills, plain and under the
    /// pointer: a question's no button first, then its yes button.
    private(set) var buttons: [(answer: CardAnswer, frame: CGRect, fill: CAShapeLayer, plain: CGColor, hover: CGColor)] = []
    /// The waiting mark's halo, which sends out its ping.
    private var halo: CAShapeLayer?
    /// The waiting mark's white countdown ring around its dot, hidden until the card stops waiting.
    private var waitingCountdown: CALayer?
    /// The × that takes the icon's place while the pointer is on the card, and its disc, lighter
    /// while the pointer is on the × itself. Nil for a card without an icon.
    private var closeMark: CALayer?
    private var closeDisc: CAShapeLayer?
    /// The arrow that takes the ring's place while the pointer is on a card a click opens an app
    /// from, so the click reads as "go to". Nil for a card with buttons.
    private var goMark: CALayer?
    let text = CALayer()
    /// Ends the text column short of the ring, with a soft edge: text the capsule is still growing to
    /// hold fades out there instead of running under the ring.
    private let textMask = CAGradientLayer()
    /// One text layer per line of the title, and of the detail.
    let titleLines: [CATextLayer]
    let detailLines: [CATextLayer]
    private let iconSide: CGFloat
    private let ringSide: CGFloat
    private let textSize: CGSize
    /// The soft edge at the end of the text column.
    private let textEdge: CGFloat

    init(card: Card, notch: NotchGeometry, scale: CGFloat, console: Console) {
        self.card = card
        let sizeScale = CGFloat(card.size.scale)
        let accent = card.color.nsColor
        let image = card.showsIconAtNotch
            ? CardIcon(card: card, pointSize: 28 * sizeScale, console: console) : nil
        func label(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5 * sizeScale, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
        }
        func width(_ label: NSAttributedString) -> CGFloat { ceil(label.size().width) + 24 * sizeScale }
        let yesLabel = card.action.map { label($0.label) }
        let noLabel = card.action?.decline.map(label)
        let buttonsWidth = yesLabel.map {
            CGFloat(IslandMetrics.buttonsWidth(
                yes: Double(width($0)), no: noLabel.map { Double(width($0)) }, scale: Double(sizeScale)))
        }
        func islandMetrics(textSize: CGSize, titleLines: Int, detailLines: Int) -> IslandMetrics {
            IslandMetrics(
                notchWidth: Double(notch.width), notchHeight: Double(notch.height), scale: Double(sizeScale),
                textWidth: Double(textSize.width), textHeight: Double(textSize.height), titleLines: titleLines,
                detailLines: detailLines, hasIcon: image != nil, actionWidth: Double(buttonsWidth ?? 0),
                declineWidth: Double(noLabel.map(width) ?? 0))
        }
        // The text column depends only on the size, the icon and the button.
        let column = CGFloat(islandMetrics(textSize: .zero, titleLines: 0, detailLines: 0).textColumn)
        let titleText = Self.lines(
            card.title, font: .systemFont(ofSize: 14 * sizeScale, weight: .semibold), color: .white, width: column,
            maxLines: Defaults.titleLines)
        let detailText = card.detail.map {
            Self.lines(
                $0, font: .systemFont(ofSize: 12 * sizeScale, weight: .regular), color: NSColor(white: 0.62, alpha: 1),
                width: column, maxLines: Defaults.detailLines)
        } ?? []
        let titleSizes = titleText.map { Self.measure($0, maxWidth: column) }
        let detailSizes = detailText.map { Self.measure($0, maxWidth: column) }
        let spacing = detailText.isEmpty ? 0 : 3 * sizeScale
        let block = CGSize(
            width: (titleSizes + detailSizes).map(\.width).max() ?? 0,
            height: (titleSizes + detailSizes).map(\.height).reduce(spacing, +))

        // One layer per line, stacked down from the top of the text block, the detail's a little below
        // the title's. Right-to-left text hugs the block's right edge.
        var top: CGFloat = 0
        func stack(_ lines: [NSAttributedString], _ sizes: [CGSize], rightToLeft: Bool) -> [CATextLayer] {
            zip(lines, sizes).map { line, lineSize in
                let layer = CATextLayer()
                layer.string = line
                layer.frame = CGRect(x: 0, y: top, width: block.width, height: lineSize.height)
                layer.truncationMode = .end
                if rightToLeft { layer.alignmentMode = .right }
                layer.contentsScale = scale
                layer.opacity = 0
                top += lineSize.height
                return layer
            }
        }
        titleLines = stack(titleText, titleSizes, rightToLeft: CardText.isRightToLeft(card.title))
        top += spacing
        detailLines = stack(detailText, detailSizes, rightToLeft: card.detail.map(CardText.isRightToLeft) ?? false)
        textSize = block
        metrics = islandMetrics(textSize: block, titleLines: titleText.count, detailLines: detailText.count)
        size = CGSize(width: ceil(metrics.maxWidth) + 40, height: ceil(metrics.maxHeight))
        iconSide = 28 * sizeScale
        ringSide = buttonsWidth ?? 20 * sizeScale
        textEdge = CGFloat(IslandUpdate.textEdge) * sizeScale

        root.frame = CGRect(origin: .zero, size: size)
        root.isGeometryFlipped = true
        root.contentsScale = scale

        shape.frame = root.bounds
        shape.fillColor = NSColor.black.cgColor
        shape.contentsScale = scale
        root.addSublayer(shape)
        content.frame = root.bounds
        content.masksToBounds = true
        root.addSublayer(content)

        // The icon is drawn at its largest and scaled down, so it stays sharp as it grows.
        icon.bounds = CGRect(x: 0, y: 0, width: iconSide, height: iconSide)
        icon.contentsScale = scale
        icon.contentsGravity = .resizeAspect
        if let image, image.isSymbol {
            // White mark on an accent disc for the built-in symbols; one-layer symbols draw white.
            let palette = NSImage.SymbolConfiguration(paletteColors: [.white, accent])
            let tinted = image.image.withSymbolConfiguration(palette) ?? image.image
            icon.contents = tinted.layerContents(forContentsScale: scale)
        } else if let image {
            // A picture, such as an agent's app icon, is drawn as it is.
            icon.contents = image.image.layerContents(forContentsScale: scale)
        }
        icon.opacity = 0
        content.addSublayer(icon)
        if image != nil { makeCloseMark(scale: scale) }

        if let yesLabel, let buttonsWidth {
            ring.bounds = CGRect(x: 0, y: 0, width: buttonsWidth, height: 26 * sizeScale)
            let rgb = accent.rgb(in: NSAppearance(named: .aqua) ?? .currentDrawing())
            let yes = NSColor(ButtonPalette(accent: rgb).fill)
            var x: CGFloat = 0
            if let noLabel {
                // White at 15 %: a quiet no beside the yes in the state's colour.
                let no = NSColor(white: 1, alpha: 0.15)
                makeButton(.no, noLabel, x: x, width: width(noLabel), fill: no, hover: NSColor(white: 1, alpha: 0.25), scale: scale)
                x += width(noLabel) + CGFloat(IslandMetrics.buttonGap) * sizeScale
            }
            // Lightened a little on hover.
            makeButton(
                .yes, yesLabel, x: x, width: width(yesLabel), fill: yes,
                hover: yes.blended(withFraction: 0.12, of: .white) ?? yes, scale: scale)
        } else if card.showsWaitingMark {
            makeWaitingMark(
                side: 20 * sizeScale, dot: CGFloat(IslandUpdate.dot) * sizeScale, lineWidth: 2.4 * sizeScale,
                inset: 1.4 * sizeScale, scale: scale)
        } else {
            makeRing(accent: accent, lineWidth: 2.4 * sizeScale, inset: 1.4 * sizeScale, glyph: card.ringGlyph, scale: scale)
        }
        if card.action == nil, card.activate != nil { makeGoMark(scale: scale) }
        ring.opacity = 0
        content.addSublayer(ring)

        text.bounds = CGRect(origin: .zero, size: textSize)
        text.anchorPoint = CGPoint(x: 0, y: 0.5)
        for line in titleLines + detailLines { text.addSublayer(line) }
        content.addSublayer(text)

        // Opaque from far left of the text to its right end, which is pinned to the column's end, then
        // clear over the soft edge. Wider than any capsule, so it only ever cuts the text's end, and
        // taller than the text, so a line rising into place is never cut.
        let reach = 2 * CGFloat(CardMetrics.maxWidth)
        textMask.bounds = CGRect(x: 0, y: 0, width: reach, height: textSize.height + 2 * 40 * sizeScale)
        textMask.anchorPoint = CGPoint(x: 1, y: 0.5)
        textMask.startPoint = CGPoint(x: 0, y: 0.5)
        textMask.endPoint = CGPoint(x: 1, y: 0.5)
        textMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        textMask.locations = [0, NSNumber(value: Double((reach - textEdge) / reach)), 1]
        textMask.contentsScale = scale
        text.mask = textMask
    }

    /// The disc's fill, plain and under the pointer.
    private static let closeFill = NSColor(white: 0.24, alpha: 1).cgColor
    private static let closeFillHovered = NSColor(white: 0.36, alpha: 1).cgColor

    /// A white symbol drawn into a layer that fills `frame`.
    private static func glyph(_ name: String, pointSize: CGFloat, frame: CGRect, scale: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = scale
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            layer.contents = image.layerContents(forContentsScale: scale)
        }
        return layer
    }

    /// The close mark over the icon, hidden until the pointer is on the card: black over the whole
    /// icon, then a grey disc with a white ×. It moves and scales with the icon.
    private func makeCloseMark(scale: CGFloat) {
        let mark = CALayer()
        mark.frame = icon.bounds
        mark.backgroundColor = NSColor.black.cgColor
        mark.opacity = 0
        let disc = CAShapeLayer()
        disc.frame = mark.bounds
        disc.path = CGPath(ellipseIn: mark.bounds.insetBy(dx: iconSide * 0.06, dy: iconSide * 0.06), transform: nil)
        disc.fillColor = Self.closeFill
        disc.contentsScale = scale
        mark.addSublayer(disc)
        mark.addSublayer(Self.glyph(
            "xmark", pointSize: iconSide * 0.4, frame: mark.bounds.insetBy(dx: iconSide * 0.31, dy: iconSide * 0.31),
            scale: scale))
        icon.addSublayer(mark)
        closeMark = mark
        closeDisc = disc
    }

    /// The "go to" mark over the ring's place, hidden until the pointer is on the card: black over
    /// the ring or the waiting mark, and a white arrow pointing up and out.
    private func makeGoMark(scale: CGFloat) {
        let mark = CALayer()
        mark.frame = ring.bounds
        mark.backgroundColor = NSColor.black.cgColor
        mark.opacity = 0
        let side = ring.bounds.width
        mark.addSublayer(Self.glyph(
            "arrow.up.forward", pointSize: side * 0.55, frame: mark.bounds.insetBy(dx: side * 0.18, dy: side * 0.18),
            scale: scale))
        ring.addSublayer(mark)
        goMark = mark
    }

    /// Where the pointer is on the card, for what the card shows under it.
    enum Pointer {
        /// On the card, off its ×: the × and the "go to" mark show.
        case card
        /// On the ×, which shows lighter.
        case close
    }

    /// Shows the × in the icon's place, and the "go to" mark in the ring's, while the pointer is on
    /// the card, at once, as a button lightens; hides them when `pointer` is nil.
    func showPointer(_ pointer: Pointer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        closeMark?.opacity = pointer == nil ? 0 : 1
        closeDisc?.fillColor = pointer == .close ? Self.closeFillHovered : Self.closeFill
        goMark?.opacity = pointer == nil ? 0 : 1
        CATransaction.commit()
    }

    /// Whether `point`, in the root's coordinates as the card is drawn now, is on its close mark: the
    /// left end of the card, its padding and its icon.
    func isOnClose(_ point: CGPoint) -> Bool {
        guard closeMark != nil, metrics.hasIcon else { return false }
        let drawn = root.presentation() ?? root
        let shownIcon = icon.presentation() ?? icon
        let iconFrame = drawn.convert(shownIcon.bounds, from: shownIcon)
        let clip = (content.presentation() ?? content).frame
        let reach = 6 * CGFloat(card.size.scale)
        return point.x >= clip.minX - 2 && point.x <= iconFrame.maxX + reach
            && point.y >= clip.minY - 2 && point.y <= clip.maxY + 2
    }

    /// A button that stands where the ring would, `x` from the left of the ring's place: a capsule
    /// filled `fill`, lighter under the pointer.
    private func makeButton(
        _ answer: CardAnswer, _ label: NSAttributedString, x: CGFloat, width: CGFloat, fill color: NSColor,
        hover: NSColor, scale: CGFloat
    ) {
        let frame = CGRect(x: x, y: 0, width: width, height: ring.bounds.height)
        let fill = CAShapeLayer()
        fill.path = CGPath(
            roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil)
        fill.fillColor = color.cgColor
        fill.contentsScale = scale
        ring.addSublayer(fill)
        buttons.append((answer, frame, fill, color.cgColor, hover.cgColor))
        let text = CATextLayer()
        text.string = label
        let textSize = label.size()
        text.frame = CGRect(
            x: frame.midX - ceil(textSize.width) / 2, y: (frame.height - ceil(textSize.height)) / 2,
            width: ceil(textSize.width), height: ceil(textSize.height))
        text.contentsScale = scale
        ring.addSublayer(text)
    }

    /// Shows the button `hovered` lightened while the pointer is on it, at once, as the other cards'
    /// button; nil for none.
    func setButtonHovered(_ hovered: CardAnswer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for button in buttons {
            let color = button.answer == hovered ? button.hover : button.plain
            if button.fill.fillColor != color { button.fill.fillColor = color }
        }
        CATransaction.commit()
    }

    /// The waiting mark of a card that waits for you, in a `side` square: a white `dot`, and over it
    /// a halo of the same size that sends out the ping, hidden until it does. Around the dot, a white
    /// countdown ring, hidden until the card stops waiting and counts down.
    private func makeWaitingMark(side: CGFloat, dot: CGFloat, lineWidth: CGFloat, inset: CGFloat, scale: CGFloat) {
        ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let countdown = CALayer()
        countdown.frame = ring.bounds
        countdown.opacity = 0
        addCountdown(to: countdown, color: .white, lineWidth: lineWidth, inset: inset, scale: scale)
        ring.addSublayer(countdown)
        waitingCountdown = countdown
        let frame = CGRect(x: (side - dot) / 2, y: (side - dot) / 2, width: dot, height: dot)
        let halo = CAShapeLayer(), core = CAShapeLayer()
        for layer in [halo, core] {
            layer.frame = frame
            layer.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: dot, height: dot), transform: nil)
            layer.fillColor = NSColor.white.cgColor
            layer.contentsScale = scale
            ring.addSublayer(layer)
        }
        halo.opacity = 0
        self.halo = halo
    }

    /// Starts the waiting mark's ping at `begin`: the halo grows from the dot's size and fades, and
    /// rests until the next one.
    private func ping(at begin: CFTimeInterval) {
        guard let halo else { return }
        let (x1, y1, x2, y2) = IslandUpdate.pingCurve
        let curve = CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = IslandUpdate.pingScale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = IslandUpdate.pingOpacity
        fade.toValue = 0
        for part in [grow, fade] {
            part.duration = IslandUpdate.ping * IslandUpdate.pingSpread
            part.timingFunction = curve
        }
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = IslandUpdate.ping
        group.repeatCount = .infinity
        group.beginTime = begin
        halo.add(group, forKey: "ping")
    }

    /// The button at `point`, in the root's coordinates as it is drawn now; nil off the buttons.
    func button(at point: CGPoint) -> CardAnswer? {
        let shown = ring.presentation() ?? ring
        let drawn = root.presentation() ?? root
        // Half the gap between two buttons, so a click there lands on the nearer one.
        let reach = buttons.count > 1 ? CGFloat(IslandMetrics.buttonGap * card.size.scale) / 2 : 4
        return buttons.first { drawn.convert($0.frame, from: shown).insetBy(dx: -reach, dy: -4).contains(point) }?.answer
    }

    /// The countdown ring: a faint track and the accent arc that drains, its centre line `inset`
    /// from the ring's edge, around the state's `glyph` when the card shows one in its ring.
    private func makeRing(accent: NSColor, lineWidth: CGFloat, inset: CGFloat, glyph: String?, scale: CGFloat) {
        ring.bounds = CGRect(x: 0, y: 0, width: ringSide, height: ringSide)
        addCountdown(to: ring, color: accent, lineWidth: lineWidth, inset: inset, scale: scale)
        let configuration = NSImage.SymbolConfiguration(pointSize: ringSide * 0.4, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let glyph, let image = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        {
            let mark = CALayer()
            mark.frame = ring.bounds.insetBy(dx: ringSide * 0.24, dy: ringSide * 0.24)
            mark.contentsGravity = .resizeAspect
            mark.contentsScale = scale
            mark.contents = image.layerContents(forContentsScale: scale)
            ring.addSublayer(mark)
        }
    }

    /// A faint track and `ringProgress`, the arc that drains, both in `color` and filling `parent`,
    /// their centre line `inset` from its edge.
    private func addCountdown(to parent: CALayer, color: NSColor, lineWidth: CGFloat, inset: CGFloat, scale: CGFloat) {
        let circle = CGPath(ellipseIn: parent.bounds.insetBy(dx: inset, dy: inset), transform: nil)
        let track = CAShapeLayer()
        track.path = circle
        track.fillColor = nil
        track.strokeColor = color.withAlphaComponent(0.28).cgColor
        track.lineWidth = lineWidth
        track.contentsScale = scale
        ringProgress.path = circle
        ringProgress.fillColor = nil
        ringProgress.strokeColor = color.cgColor
        ringProgress.lineWidth = lineWidth
        ringProgress.lineCap = .round
        ringProgress.contentsScale = scale
        // Start at twelve o'clock and drain clockwise.
        ringProgress.frame = parent.bounds
        ringProgress.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        track.frame = parent.bounds
        parent.addSublayer(track)
        parent.addSublayer(ringProgress)
    }

    /// `text` broken into at most `maxLines` lines, each cut to fit `width`, the last with an ellipsis
    /// when the text runs on. The island never leaves the cut to its text layers: on a Mac, an island
    /// handed a line wider than its text layer did not show at all, and fitting the line first makes
    /// it show (confirmed before and after on a Mac). The exact AppKit/Core Animation mechanism, why
    /// an unfitted string in the text layer hid the whole island, is not proven. So every line gets
    /// its own layer, as wide as the widest line.
    private static func lines(
        _ text: String, font: NSFont, color: NSColor, width: CGFloat, maxLines: Int
    ) -> [NSAttributedString] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if CardText.isRightToLeft(text) {
            // Every line reads right to left, however it starts.
            let paragraph = NSMutableParagraphStyle()
            paragraph.baseWritingDirection = .rightToLeft
            attributes[.paragraphStyle] = paragraph
        }
        return CardLines.wrap(text, attributes: attributes, width: width, maxLines: maxLines).map {
            NSAttributedString(string: $0, attributes: attributes)
        }
    }

    private static func measure(_ text: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let size = text.size()
        return CGSize(width: min(ceil(size.width), maxWidth), height: ceil(size.height))
    }

    /// Every text layer, title lines first.
    var textLines: [CATextLayer] { titleLines + detailLines }

    /// The island's x = 0 in layer coordinates.
    var centerX: CGFloat { size.width / 2 }

    /// Every layer's model values at one instant.
    struct Frame {
        /// Nil leaves the shape alone, for a card whose outline a stack draws.
        var path: CGPath?
        var iconPosition: CGPoint
        var iconScale: CGFloat
        var ringPosition: CGPoint
        var ringScale: CGFloat
        var textPosition: CGPoint
        /// Where the text column ends, soft edge included, from the text's leading edge.
        var textEnd: CGFloat
        /// The content's clip, in the root's coordinates: the drop.
        var clip: CGRect
        var clipRadius: CGFloat
    }

    func frame(_ islandShape: IslandShape, layout: IslandContentLayout, withPath: Bool = true) -> Frame {
        let clip = CGRect(
            x: centerX - islandShape.pillWidth / 2, y: islandShape.pillTop, width: islandShape.pillWidth,
            height: islandShape.pillHeight)
        return Frame(
            path: withPath ? IslandPath.make(islandShape, metrics: metrics, centerX: centerX) : nil,
            iconPosition: CGPoint(x: centerX + layout.iconCenter.x, y: layout.iconCenter.y),
            iconScale: CGFloat(layout.iconSize) / iconSide,
            ringPosition: CGPoint(x: centerX + layout.ringCenter.x, y: layout.ringCenter.y),
            ringScale: CGFloat(layout.ringSize) / ringSide,
            textPosition: CGPoint(x: centerX + layout.textX, y: layout.textCenterY),
            textEnd: CGFloat(layout.textRoom) + textEdge,
            clip: clip, clipRadius: CGFloat(islandShape.pillRadius(metrics)))
    }

    /// Leaves the notch itself out of the black shape, for the live screen.
    func maskNotch() {
        shape.mask = IslandPath.notchMask(size: size, metrics: metrics, centerX: centerX, scale: root.contentsScale)
    }

    /// Sets the model values without implicit animations.
    func apply(_ frame: Frame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let path = frame.path { shape.path = path }
        icon.position = frame.iconPosition
        icon.transform = CATransform3DMakeScale(frame.iconScale, frame.iconScale, 1)
        ring.position = frame.ringPosition
        ring.transform = CATransform3DMakeScale(frame.ringScale, frame.ringScale, 1)
        text.position = frame.textPosition
        textMask.position = CGPoint(x: frame.textEnd, y: textSize.height / 2)
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
        for layer in [icon, ring] { layer.opacity = 1 }
        for line in textLines { line.opacity = 1 }
        if !metrics.hasIcon { icon.opacity = 0 }
        CATransaction.commit()
    }

    /// Sets the content's opacity as the exit fades leave it `time` seconds in.
    func hideContent(at time: Double, cues: IslandCues) {
        func faded(_ cue: Double, over duration: Double = IslandCues.fadeOut) -> Float {
            Float(IslandCues.opacity(leaving: cue, over: duration, at: time))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.opacity = metrics.hasIcon ? faded(cues.sides) : 0
        ring.opacity = faded(cues.sides)
        for (layer, cue) in zip(textLines, cues.title + cues.detail) { layer.opacity = faded(cue) }
        CATransaction.commit()
    }

    /// Sets the content's opacity as the entrance fades leave it `time` seconds in.
    func showContent(at time: Double, cues: IslandCues) {
        func faded(_ cue: Double, _ duration: Double) -> Float {
            let linear = min(max((time - cue) / duration, 0), 1)
            return Float(1 - pow(1 - linear, 3))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.opacity = metrics.hasIcon ? faded(cues.sides, 0.18) : 0
        ring.opacity = faded(cues.sides, 0.18)
        for (layer, cue) in zip(textLines, cues.title + cues.detail) { layer.opacity = faded(cue, 0.25) }
        CATransaction.commit()
    }
}

extension IslandLayers {
    /// Plays `frames`, sampled evenly over `duration` from `begin`, as keyframe animations, and
    /// leaves the model at the last frame. Frames without a path leave the shape alone.
    func play(_ frames: [Frame], duration: Double, begin: CFTimeInterval? = nil) {
        func keyframes(_ keyPath: String, _ values: [Any], discrete: Bool = false) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.duration = duration
            animation.calculationMode = discrete ? .discrete : .linear
            if let begin { animation.beginTime = begin }
            return animation
        }
        guard let last = frames.last else { return }
        apply(last)
        // A traced droplet changes its number of points from frame to frame, so its frames can't be
        // blended; at 240 a second, every display frame still gets its own.
        let paths = frames.compactMap(\.path)
        if paths.count == frames.count { shape.add(keyframes("path", paths, discrete: true), forKey: "island") }
        content.add(keyframes("bounds", frames.map { NSValue(rect: $0.clip) }), forKey: "island")
        content.add(
            keyframes("position", frames.map { NSValue(point: CGPoint(x: $0.clip.midX, y: $0.clip.midY)) }),
            forKey: "island.position")
        content.add(keyframes("cornerRadius", frames.map(\.clipRadius)), forKey: "island.radius")
        icon.add(keyframes("position", frames.map { NSValue(point: $0.iconPosition) }), forKey: "island")
        icon.add(keyframes("transform.scale", frames.map(\.iconScale)), forKey: "island.scale")
        ring.add(keyframes("position", frames.map { NSValue(point: $0.ringPosition) }), forKey: "island")
        ring.add(keyframes("transform.scale", frames.map(\.ringScale)), forKey: "island.scale")
        text.add(keyframes("position", frames.map { NSValue(point: $0.textPosition) }), forKey: "island")
        let middle = textSize.height / 2
        textMask.add(
            keyframes("position", frames.map { NSValue(point: CGPoint(x: $0.textEnd, y: middle)) }), forKey: "island")
    }

    /// Fades the content in or out at the cues, counted from `begin`: 180 ms in with a 4-point rise
    /// for each line of text, 120 ms out.
    func fade(_ cues: IslandCues, into visible: Bool, at begin: CFTimeInterval = CACurrentMediaTime()) {
        var parts: [(CALayer, Double?, Bool)] = [
            (icon, metrics.hasIcon ? cues.sides : nil, false), (ring, cues.sides, false),
        ]
        parts += zip(textLines, cues.title + cues.detail).map { line, cue -> (CALayer, Double?, Bool) in
            (line, cue, true)
        }
        // One transaction for the model values and the animations alike: a model value committed on
        // its own reaches the screen a frame before the animation that should hide it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (layer, cue, isText) in parts {
            guard let cue else { continue }
            let duration = visible ? (isText ? 0.25 : 0.18) : IslandCues.fadeOut
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
            group.beginTime = begin + cue
            group.duration = duration
            group.timingFunction = CardPresenters.easeOut
            group.fillMode = .backwards
            layer.opacity = visible ? 1 : 0
            layer.add(group, forKey: "fade")
        }
    }

    /// Holds a card that waits for you, which has no countdown: its waiting mark sends out its ping
    /// from `begin` on, unless `pinging` is false, as with motion reduced, and the dot shows alone.
    func hold(pinging: Bool, at begin: CFTimeInterval = CACurrentMediaTime()) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringProgress.removeAnimation(forKey: "drain")
        ringProgress.strokeEnd = 1
        if pinging { ping(at: begin) }
        CATransaction.commit()
    }

    /// Drains the countdown ring from `fraction` full to empty over `seconds`, starting at `begin`.
    func drain(from fraction: Double = 1, over seconds: Double, at begin: CFTimeInterval = CACurrentMediaTime()) {
        let drain = CABasicAnimation(keyPath: "strokeEnd")
        drain.fromValue = fraction
        drain.toValue = 0
        drain.beginTime = begin
        drain.duration = max(seconds, 0.01)
        drain.fillMode = .both
        drain.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        showWaitingCountdown(at: begin)
        ringProgress.strokeEnd = 0
        // A fresh clock: the new drain replaces whatever a pause left behind.
        ringProgress.speed = 1
        ringProgress.timeOffset = 0
        ringProgress.beginTime = 0
        ringProgress.add(drain, forKey: "drain")
        CATransaction.commit()
    }

    /// Refills the countdown ring from `fraction` full to full, then drains it, all over `seconds`
    /// from `begin`: a card replaced in place restarts its countdown without the ring jumping.
    func refill(from fraction: Double, over seconds: Double, at begin: CFTimeInterval = CACurrentMediaTime()) {
        let refill = min(IslandUpdate.refill, seconds / 2)
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = fraction
        fill.toValue = 1
        fill.duration = refill
        fill.timingFunction = CardPresenters.easeOut
        let drain = CABasicAnimation(keyPath: "strokeEnd")
        drain.fromValue = 1
        drain.toValue = 0
        drain.beginTime = refill
        drain.duration = max(seconds - refill, 0.01)
        drain.timingFunction = CAMediaTimingFunction(name: .linear)
        let group = CAAnimationGroup()
        group.animations = [fill, drain]
        group.beginTime = begin
        group.duration = max(seconds, 0.01)
        group.fillMode = .both
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        showWaitingCountdown(at: begin)
        ringProgress.strokeEnd = 0
        ringProgress.speed = 1
        ringProgress.timeOffset = 0
        ringProgress.beginTime = 0
        ringProgress.add(group, forKey: "drain")
        CATransaction.commit()
    }

    /// For a card that stopped waiting, from `begin`: its mark stops sending out its ping, and the
    /// white countdown ring fades in around its dot.
    private func showWaitingCountdown(at begin: CFTimeInterval) {
        halo?.removeAnimation(forKey: "ping")
        guard let waitingCountdown, waitingCountdown.opacity != 1 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = begin
        fade.duration = IslandUpdate.fadeIn
        fade.timingFunction = CardPresenters.easeOut
        fade.fillMode = .backwards
        waitingCountdown.opacity = 1
        waitingCountdown.add(fade, forKey: "show")
    }

    /// How full the countdown ring is drawn right now.
    var ringFraction: Double {
        Double((ringProgress.presentation() ?? ringProgress).strokeEnd)
    }

    /// Takes the island over from `old`, the card this one replaces in place, from `begin`, while the
    /// island springs from `old`'s size to this card's. `old` sits on top of this card's layers: its
    /// lines that changed fade out as the new ones fade in, and its lines that did not are dropped at
    /// once, the new ones in their place. A new state's icon is uncovered as the old one fades, so
    /// its colour settles over the old one's, and it lands with a small pop; the ring takes its
    /// colour the same way. With motion reduced, the changes only crossfade; with no motion, they
    /// happen at once. Returns how long until `old` can go.
    func takeOver(from old: IslandLayers, motion: Motion, at begin: CFTimeInterval) -> Double {
        showContent()
        let full = motion == .full
        let fadeIn = full ? IslandUpdate.fadeIn : IslandUpdate.reducedFade
        let fadeOut = full ? IslandUpdate.fadeOut : IslandUpdate.reducedFade
        let settle = full ? IslandUpdate.settle : IslandUpdate.reducedFade
        func strings(_ lines: [CATextLayer]) -> [String] {
            lines.map { ($0.string as? NSAttributedString)?.string ?? "" }
        }
        var kept = IslandUpdate.unchanged(
            oldTitle: strings(old.titleLines), oldDetail: strings(old.detailLines),
            newTitle: strings(titleLines), newDetail: strings(detailLines), from: old.metrics, to: metrics)
        // A right-to-left line hugs the block's right edge, which moves when the block's width does.
        for (index, line) in textLines.enumerated() where line.alignmentMode == .right && textSize.width != old.textSize.width {
            kept[index] = false
        }
        let newState = IslandUpdate.changesState(from: old.card, to: card)
        let bothRings = old.card.action == nil && card.action == nil && old.card.showsWaitingMark == card.showsWaitingMark

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        old.shape.isHidden = true
        guard motion != .none else {
            for layer in [old.icon, old.ring] + old.textLines.map({ $0 as CALayer }) { layer.opacity = 0 }
            return 0
        }
        func fade(_ layer: CALayer, from: Float, to: Float, over duration: Double) {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = to
            animation.beginTime = begin
            animation.duration = duration
            animation.timingFunction = CardPresenters.easeOut
            animation.fillMode = .backwards
            layer.opacity = to
            layer.add(animation, forKey: "replace")
        }
        // Lines that stay are this card's from the start; the others cross.
        for (index, line) in textLines.enumerated() where !kept[index] {
            fade(line, from: 0, to: 1, over: fadeIn)
        }
        for (index, line) in old.textLines.enumerated() {
            if index < kept.count, kept[index] {
                line.opacity = 0
            } else {
                fade(line, from: line.opacity, to: 0, over: fadeOut)
            }
        }
        /// Lands `layer` with a small pop, on top of whatever scale the island gives it.
        func pop(_ layer: CALayer) {
            let landing = CASpringAnimation(keyPath: "transform.scale")
            let spring = IslandUpdate.pop
            landing.mass = 1
            landing.stiffness = spring.stiffness
            landing.damping = spring.damping
            landing.duration = spring.settlingTime
            let scale = (layer.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue ?? 1
            landing.isAdditive = true
            landing.fromValue = (IslandUpdate.popScale - 1) * scale
            landing.toValue = 0
            landing.beginTime = begin
            landing.fillMode = .backwards
            layer.add(landing, forKey: "pop")
        }
        // The new icon waits underneath, whole, as the old one fades off it. When the ring carries
        // the state and the icon stays, such as an agent's, the icon stays still and the state lands
        // in the ring instead.
        if newState, !IslandUpdate.landsInRing(from: old.card, to: card) {
            fade(old.icon, from: old.icon.opacity, to: 0, over: settle)
            if full, metrics.hasIcon { pop(icon) }
        } else {
            old.icon.opacity = 0
            if newState, full, card.action == nil { pop(ring) }
        }
        if bothRings {
            // One ring, which takes the new colour from the old.
            old.ring.opacity = 0
            if newState { tint(ring, from: old.ring, over: settle, at: begin) }
        } else {
            fade(ring, from: 0, to: 1, over: fadeIn)
            fade(old.ring, from: old.ring.opacity, to: 0, over: fadeOut)
        }
        return max(fadeIn, fadeOut, settle) + 0.02
    }

    /// Blends `ring`'s strokes from `old`'s colours to their own over `duration` from `begin`.
    private func tint(_ ring: CALayer, from old: CALayer, over duration: Double, at begin: CFTimeInterval) {
        let strokes = (ring.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        let previous = (old.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        for (stroke, before) in zip(strokes, previous) {
            guard let from = before.strokeColor, let to = stroke.strokeColor else { continue }
            let animation = CABasicAnimation(keyPath: "strokeColor")
            animation.fromValue = from
            animation.toValue = to
            animation.beginTime = begin
            animation.duration = duration
            animation.timingFunction = CardPresenters.easeOut
            animation.fillMode = .backwards
            stroke.add(animation, forKey: "replace")
        }
    }

    /// Freezes or resumes every animation on `layer`, where it is.
    static func pause(_ layer: CALayer, paused: Bool) {
        if paused {
            guard layer.speed != 0 else { return }
            let time = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = time
        } else {
            guard layer.speed == 0 else { return }
            let offset = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - offset
        }
    }
}

/// The island's outline as one path: the notch, and the drop, traced where it melts into the notch.
/// Every part winds the same way, so overlaps fill as a union.
enum IslandPath {
    static func make(_ shape: IslandShape, metrics: IslandMetrics, centerX: CGFloat) -> CGPath {
        let path = CGMutablePath()
        addNotch(to: path, metrics: metrics, centerX: centerX)
        let field = DropletField(metrics: metrics, shape: shape)
        if field.touchesNotch {
            addTraced(field, to: path, centerX: centerX)
        } else {
            addCapsule(shape, metrics: metrics, to: path, centerX: centerX)
        }
        return path
    }

    /// Everything but the notch, to mask the live island with: on screen the hardware notch covers
    /// that part anyway, and a screen recording, which sees what is drawn under the notch, then shows
    /// only the drop. Nil on a screen without a notch.
    static func notchMask(size: CGSize, metrics: IslandMetrics, centerX: CGFloat, scale: CGFloat) -> CAShapeLayer? {
        guard metrics.notchHeight > 0 else { return nil }
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: size))
        addNotch(to: path, metrics: metrics, centerX: centerX)
        let mask = CAShapeLayer()
        mask.frame = CGRect(origin: .zero, size: size)
        mask.path = path
        mask.fillRule = .evenOdd
        mask.contentsScale = scale
        return mask
    }

    /// The notch: down the left side, across the bottom, up the right side.
    static func addNotch(to path: CGMutablePath, metrics: IslandMetrics, centerX: CGFloat) {
        let x = { (value: Double) in centerX + CGFloat(value) }
        let left = x(-metrics.notchWidth / 2), right = x(metrics.notchWidth / 2)
        let height = CGFloat(metrics.notchHeight)
        let radius = CGFloat(min(metrics.notchRadius, metrics.notchHeight / 2, metrics.notchWidth / 2))
        path.move(to: CGPoint(x: left, y: 0))
        path.addArc(
            tangent1End: CGPoint(x: left, y: height), tangent2End: CGPoint(x: right, y: height), radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: right, y: height), tangent2End: CGPoint(x: right, y: 0), radius: radius)
        path.addLine(to: CGPoint(x: right, y: 0))
        path.closeSubpath()
    }

    /// The drop melted into its anchor, traced from `field.traceTop`: just inside the anchor, where
    /// the anchor's own shape covers the cut.
    static func addTraced(_ field: DropletField, to path: CGMutablePath, centerX: CGFloat) {
        let x = { (value: Double) in centerX + CGFloat(value) }
        for loop in field.outline(above: field.traceTop, cell: 0.5) {
            guard let first = loop.first else { continue }
            path.move(to: CGPoint(x: x(first.x), y: CGFloat(first.y)))
            for point in loop.dropFirst() { path.addLine(to: CGPoint(x: x(point.x), y: CGFloat(point.y))) }
            path.closeSubpath()
        }
    }

    /// Free of its anchor, the drop is an exact capsule, or a rounded box once it is taller than its
    /// corners; same winding: down the left, across the bottom, up the right, back across the top.
    static func addCapsule(_ shape: IslandShape, metrics: IslandMetrics, to path: CGMutablePath, centerX: CGFloat) {
        let x = { (value: Double) in centerX + CGFloat(value) }
        let top = CGFloat(shape.pillTop), pillHeight = CGFloat(shape.pillHeight)
        let pillLeft = x(-shape.pillWidth / 2), pillRight = x(shape.pillWidth / 2), bottom = top + pillHeight
        let pillRadius = CGFloat(shape.pillRadius(metrics))
        let corners = [
            CGPoint(x: pillLeft, y: bottom), CGPoint(x: pillRight, y: bottom), CGPoint(x: pillRight, y: top),
            CGPoint(x: pillLeft, y: top), CGPoint(x: pillLeft, y: bottom),
        ]
        path.move(to: CGPoint(x: pillLeft, y: top + pillRadius))
        for index in 0..<4 {
            path.addArc(tangent1End: corners[index], tangent2End: corners[index + 1], radius: pillRadius)
        }
        path.closeSubpath()
    }
}

/// A click on the island, in the view's coordinates.
struct IslandClick {
    /// Where the button went down, and where it came up.
    var down: CGPoint
    var up: CGPoint
    /// A right-click, a two-finger tap, or a click with Control or Option held: it only ever takes
    /// the card away, and brings nothing forward.
    var secondary: Bool
}

/// The island's view: reports the pointer and clicks, without ever taking focus.
final class IslandView: NSView {
    var onMove: ((CGPoint) -> Void)?
    var onClick: ((IslandClick) -> Void)?
    /// Where the last button went down.
    private var down: CGPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .assumeInside],
            owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onMove?(CGPoint(x: -1, y: -1)) }
    override func mouseDown(with event: NSEvent) { down = convert(event.locationInWindow, from: nil) }
    override func rightMouseDown(with event: NSEvent) { down = convert(event.locationInWindow, from: nil) }
    override func mouseUp(with event: NSEvent) {
        click(event, secondary: !event.modifierFlags.intersection([.control, .option]).isEmpty)
    }
    override func rightMouseUp(with event: NSEvent) { click(event, secondary: true) }
    /// No context menu: a secondary click takes the card away.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    private func click(_ event: NSEvent, secondary: Bool) {
        let up = convert(event.locationInWindow, from: nil)
        onClick?(IslandClick(down: down ?? up, up: up, secondary: secondary))
        down = nil
    }
}

/// What VoiceOver offers for a card's buttons, as the island draws them in its layers, and for the
/// card itself.
enum CardAccessibility {
    /// Brings forward the app a click on the card brings forward.
    static let open = "Open"
    /// Takes the card away without bringing anything forward.
    static let dismiss = "Dismiss"

    /// Each button's label and the answer it gives, in the order they are drawn: no, then yes.
    static func answers(to action: CardAction) -> [(String, CardAnswer)] {
        (action.decline.map { [($0, CardAnswer.no)] } ?? []) + [(action.label, .yes)]
    }
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
    /// The card this one replaced in place, while it fades out on top.
    private var retiring: IslandLayers?
    /// With full motion, every spring the island has followed, on the clock that began at `started`;
    /// each new target springs from wherever the last one left things.
    private var animator: IslandAnimator?
    private var started: CFTimeInterval = 0
    private var onFinish: ((Bool) -> Void)?
    /// When the card is fully in.
    private var openAt = CFTimeInterval.infinity
    /// Whether the card still waits for you rather than counting down.
    private var waiting = false
    /// A background drip waiting, while a question shows, to take its card's exit on once it is
    /// answered.
    private var standby: BackgroundDrip.Spawned?

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
        layers.maskNotch()
        self.layers = layers
        let frame = self.frame(holding: [layers])
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
        view.onClick = { [weak self] click in self?.click(click) }
        view.layer?.addSublayer(layers.root)
        // The text is drawn in layers, which VoiceOver cannot read: the view reads it out whole, and
        // offers the buttons as its actions.
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel(CardText.spoken(title: card.title, detail: card.detail))
        panel.contentView = view
        updateAccessibilityActions()
        panel.setFrame(frame, display: false)
        self.panel = panel

        var animator = IslandAnimator(metrics: layers.metrics)
        layers.apply(layers.frame(animator.shape(at: 0), layout: animator.content(for: animator.shape(at: 0))))
        panel.orderFrontRegardless()
        sound = CardSound(card.sound, console: console)
        CardPresenters.announce(card)

        let motion = CardPresenters.motion(for: card)
        waiting = card.waits
        if card.asksQuestion, motion == .full { standby = BackgroundDrip.spawn(handingOff: true) }
        guard motion == .full else {
            sound?.play()
            animator.open()
            let open = animator.shape(at: 0)
            layers.apply(layers.frame(open, layout: animator.content(for: open)))
            layers.showContent()
            if waiting { layers.hold(pinging: false) }
            panel.alphaValue = motion == .none ? 1 : 0
            fadePanel(to: 1, duration: motion == .none ? 0 : 0.15)
            departure = fadingDeparture(motion)
            openAt = CACurrentMediaTime() + 0.15
            schedule(after: 0.15 + card.duration)
            return
        }

        // One clock for the whole card: each new target springs from wherever the last one left things.
        // It starts once the keyframes are built, when the animations really begin.
        let enterCues = animator.enter(at: 0)
        play(animator, from: 0, layers: layers)
        let started = CACurrentMediaTime()
        self.animator = animator
        self.started = started
        // The sound lands as the island first shows: the drop starts hidden in the notch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in sound?.play() }
        layers.fade(enterCues, into: true)
        // The countdown starts once the title's first line has faded in, however many lines follow.
        let visible = (enterCues.title.first ?? enterCues.sides) + 0.25
        if waiting {
            layers.hold(pinging: true, at: CACurrentMediaTime() + visible)
        } else {
            layers.drain(over: card.seconds, at: CACurrentMediaTime() + visible)
        }
        departure = springingDeparture()
        openAt = started + visible
        schedule(after: visible + card.duration)
    }

    func stopWaiting() {
        guard waiting, departure != nil else { return }
        waiting = false
        layers?.drain(over: card.seconds)
        if hovering {
            layers.map { IslandLayers.pause($0.ringProgress, paused: true) }
        } else {
            schedule(after: card.seconds)
        }
    }

    var canReplace: Bool { departure != nil && CACurrentMediaTime() >= openAt }

    /// Turns the island into `card`'s, the card that replaces this one in place: it springs to the
    /// new card's size while what changed crossfades and a new state's colour settles, and the ring
    /// refills and starts its countdown again. With motion reduced, the size changes at once and the
    /// changes only crossfade.
    func replace(with card: Card) {
        guard canReplace, let panel, let view = panel.contentView, let old = layers else { return }
        self.card = card
        let motion = CardPresenters.motion(for: card)
        let layers = IslandLayers(card: card, notch: notch, scale: old.root.contentsScale, console: console)
        layers.maskNotch()
        self.layers = layers
        // A card replaced again before it had faded out goes at once.
        retiring?.root.removeFromSuperlayer()
        retiring = old
        let ringFraction = old.card.action == nil ? old.ringFraction : 0

        // The panel holds both islands while one turns into the other; the new one goes under the old,
        // which fades off it.
        let frame = self.frame(holding: [old, layers])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.insertSublayer(layers.root, below: old.root)
        panel.setFrame(frame, display: false)
        place(old, in: frame)
        place(layers, in: frame)
        if motion == .full {
            // Springs on from wherever the island is; one shown with motion reduced starts a clock now.
            var animator: IslandAnimator
            if let current = self.animator {
                animator = current
            } else {
                animator = IslandAnimator(metrics: old.metrics)
                animator.open()
                started = CACurrentMediaTime()
            }
            let now = CACurrentMediaTime() - started
            animator.resize(to: layers.metrics, at: now)
            self.animator = animator
            play(animator, from: now, layers: layers, retiring: old)
        } else {
            var open = IslandAnimator(metrics: layers.metrics)
            open.open()
            let shape = open.shape(at: 0)
            layers.apply(layers.frame(shape, layout: open.content(for: shape)))
            old.apply(old.frame(shape, layout: open.content(for: shape, metrics: old.metrics), withPath: false))
            animator = nil
        }
        let lingers = layers.takeOver(from: old, motion: motion, at: CACurrentMediaTime())
        CATransaction.commit()
        retire(old, after: lingers)

        panel.ignoresMouseEvents = !card.isClickable
        view.setAccessibilityLabel(CardText.spoken(title: card.title, detail: card.detail))
        updateAccessibilityActions()
        hovering = false
        sound = CardSound(card.sound, console: console)
        sound?.play()
        CardPresenters.announce(card)

        waiting = card.waits
        if waiting {
            layers.hold(pinging: motion == .full)
        } else if motion == .full {
            layers.refill(from: ringFraction, over: card.seconds)
        } else {
            layers.drain(over: card.seconds)
        }
        departure = motion == .full ? springingDeparture() : fadingDeparture(motion)
        schedule(after: card.duration)
        pointer(at: view.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    /// Takes `old` away once it has faded out, unless it is already gone.
    private func retire(_ old: IslandLayers, after seconds: Double) {
        let remove = { [weak self, weak old] in
            guard let self, let old, self.retiring === old else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            old.root.removeFromSuperlayer()
            CATransaction.commit()
            self.retiring = nil
        }
        guard seconds > 0 else { return remove() }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: remove)
    }

    /// The panel's frame for `islands`: wide and tall enough for each, centered on the notch, hanging
    /// from the top.
    private func frame(holding islands: [IslandLayers]) -> NSRect {
        let width = islands.map(\.size.width).max() ?? 0
        let height = islands.map(\.size.height).max() ?? 0
        return NSRect(x: (notch.midX - width / 2).rounded(), y: notch.top - height, width: width, height: height)
    }

    /// Hangs `layers` from the top of a panel with `frame`, centered in it.
    private func place(_ layers: IslandLayers, in frame: NSRect) {
        layers.root.frame = CGRect(
            x: (frame.width - layers.size.width) / 2, y: frame.height - layers.size.height,
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
    private func springingDeparture() -> () -> Void {
        { [self] in
            guard var animator, let layers else { return finish() }
            retiring?.root.removeFromSuperlayer()
            retiring = nil
            let now = CACurrentMediaTime() - started
            let exitCues = animator.exit(at: now)
            self.animator = animator
            play(animator, from: now, layers: layers)
            layers.fade(exitCues, into: false)
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
    /// Lets the card go on once the pointer has rested on it for `CardStack.holdLimit`; nil once it
    /// has, until the pointer moves again.
    private var holdLimit: DispatchWorkItem?

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
        holdLimit?.cancel()
        if card.action != nil, !clicked { CardActions.missed = true }
        layers?.showPointer(nil)
        panel?.ignoresMouseEvents = true
        departure()
    }

    /// A point in the view in the island's own coordinates: y down from the top of its layers.
    private func islandPoint(_ point: CGPoint, in layers: IslandLayers) -> CGPoint {
        CGPoint(x: point.x - layers.root.frame.minX, y: layers.root.frame.maxY - point.y)
    }

    /// Whether a point in the view is on the island as it is drawn right now.
    private func onIsland(_ point: CGPoint) -> Bool {
        guard let layers, let path = (layers.shape.presentation() ?? layers.shape).path else { return false }
        return path.contains(islandPoint(point, in: layers))
    }

    /// The button at a point in the view, as it is drawn right now; nil off the buttons.
    private func button(at point: CGPoint) -> CardAnswer? {
        guard let layers, card.action != nil else { return nil }
        return layers.button(at: islandPoint(point, in: layers))
    }

    /// Whether a point in the view is on the card's ×, as it is drawn right now.
    private func onClose(_ point: CGPoint) -> Bool {
        guard let layers else { return false }
        return layers.isOnClose(islandPoint(point, in: layers))
    }

    private func pointer(at point: CGPoint) {
        guard departure != nil, card.isClickable else { return }
        let inside = onIsland(point)
        layers?.setButtonHovered(inside ? button(at: point) : nil)
        let under: IslandLayers.Pointer? = inside ? (onClose(point) ? .close : .card) : nil
        layers?.showPointer(under)
        if inside {
            if !hovering || holdLimit == nil {
                // Hold the card and freeze the ring, again when the pointer moves after a rest.
                pending?.cancel()
                layers.map { IslandLayers.pause($0.ringProgress, paused: true) }
            }
            hovering = true
            armHoldLimit()
        } else if hovering {
            hovering = false
            holdLimit?.cancel()
            holdLimit = nil
            letGo()
        }
    }

    /// Lets the card go on after `CardStack.holdLimit` with the pointer resting on it, so a pointer
    /// left there never keeps it on screen.
    private func armHoldLimit() {
        holdLimit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovering else { return }
            self.holdLimit = nil
            self.letGo()
        }
        holdLimit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CardStack.holdLimit, execute: work)
    }

    /// Starts the ring again and gives the card a moment more, or its wait again for a card that
    /// waits for you: the pointer left, or rested.
    private func letGo() {
        layers.map { IslandLayers.pause($0.ringProgress, paused: false) }
        schedule(after: waiting ? card.duration : 1.5)
    }

    /// A click on a button answers with it; on the card's ×, or a secondary click anywhere, takes the
    /// card away; anywhere else on the island, it brings the sending app forward. Either way the
    /// card goes.
    private func click(_ click: IslandClick) {
        guard departure != nil, card.isClickable, onIsland(click.up) else { return }
        if click.secondary || (onClose(click.up) && onClose(click.down)) {
            return dismiss()
        }
        if let answer = button(at: click.up) {
            press(answer)
            return
        }
        if let target = card.activate { CardActions.activate(target, pane: card.pane, console: console) }
        leave(clicked: false)
    }

    /// Takes the card away without bringing anything forward: a click on its ×, a secondary click,
    /// VoiceOver's Dismiss, or `drip dismiss`. A question goes unanswered.
    func dismiss() {
        leave(clicked: false)
    }

    /// Answers the card with one of its buttons, from a click or from VoiceOver.
    private func press(_ answer: CardAnswer) {
        guard departure != nil, let action = card.action else { return }
        CardActions.answer(answer, to: action, console: console)
        leave(clicked: true)
        handOffExit()
    }

    /// Hands the exit of an answered question on to a background drip, which plays it on from where
    /// it is, so drip exits with the answer at once; with motion reduced the card goes at once, with
    /// no exit, and when no background drip can take it, the exit plays here first.
    private func handOffExit() {
        guard card.asksQuestion else { return }
        guard animator != nil, let layers else { return finish(waitingForSound: false) }
        let request = BackgroundRequest(
            handOff: .leaving(card, top: layers.metrics.pillTop, at: Date().timeIntervalSince1970))
        CATransaction.flush()
        if standby.map({ $0.send(request) }) ?? BackgroundDrip.start(request) { finish(waitingForSound: false) }
    }

    /// The card's buttons, offered to VoiceOver as the island's actions, since the island cannot
    /// take focus, then Open, for a card a click brings an app forward from, and Dismiss.
    private func updateAccessibilityActions() {
        var actions: [NSAccessibilityCustomAction] = []
        if let action = card.action {
            for (label, answer) in CardAccessibility.answers(to: action) {
                actions.append(NSAccessibilityCustomAction(name: label) { [weak self] () -> Bool in
                    guard let self, self.departure != nil else { return false }
                    self.press(answer)
                    return true
                })
            }
        }
        if card.activate != nil, card.action == nil {
            actions.append(NSAccessibilityCustomAction(name: CardAccessibility.open) { [weak self] () -> Bool in
                guard let self, self.departure != nil, let target = self.card.activate else { return false }
                CardActions.activate(target, pane: self.card.pane, console: self.console)
                self.leave(clicked: false)
                return true
            })
        }
        if card.isClickable {
            actions.append(NSAccessibilityCustomAction(name: CardAccessibility.dismiss) { [weak self] () -> Bool in
                guard let self, self.departure != nil else { return false }
                self.dismiss()
                return true
            })
        }
        panel?.contentView?.setAccessibilityCustomActions(actions)
    }

    /// Takes the card away and reports that it has gone, once, after its sound unless not
    /// `waitingForSound`.
    private func finish(waitingForSound: Bool = true) {
        guard let onFinish else { return }
        self.onFinish = nil
        panel?.orderOut(nil)
        if waitingForSound, let sound {
            sound.waitUntilDone { onFinish(true) }
        } else {
            onFinish(true)
        }
    }

    /// Samples every spring from `start` until they settle into keyframe animations, for the card
    /// and for the card it replaced while that fades out.
    private func play(
        _ animator: IslandAnimator, from start: Double, layers: IslandLayers, retiring: IslandLayers? = nil
    ) {
        let end = max(animator.end, start + 0.05)
        let count = Int(((end - start) * Self.framesPerSecond).rounded(.up))
        let shapes = (0...count).map { index in
            animator.shape(at: start + (end - start) * Double(index) / Double(count))
        }
        layers.play(shapes.map { layers.frame($0, layout: animator.content(for: $0)) }, duration: end - start)
        if let retiring {
            retiring.play(
                shapes.map { retiring.frame($0, layout: animator.content(for: $0, metrics: retiring.metrics), withPath: false) },
                duration: end - start)
        }
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
