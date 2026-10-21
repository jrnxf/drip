#if canImport(AppKit)
import AppKit
import DripCore
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

extension NSColor {
    /// This color's sRGB components as it looks in `appearance`.
    func rgb(in appearance: NSAppearance) -> SRGBColor {
        var rgb = SRGBColor.black
        appearance.performAsCurrentDrawingAppearance {
            if let color = self.usingColorSpace(.sRGB) {
                rgb = SRGBColor(
                    red: Double(color.redComponent), green: Double(color.greenComponent),
                    blue: Double(color.blueComponent))
            }
        }
        return rgb
    }

    convenience init(_ rgb: SRGBColor) {
        self.init(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }
}

/// What sits behind a card's content. The panel builds it from views and layers; the offscreen
/// renderer paints the same description, because only the window server can draw materials.
enum CardBackdrop {
    /// The HUD material with an accent hairline.
    case material(border: NSColor)
    /// The system glass, tinted with the accent.
    case glass(tint: NSColor)
    /// A diagonal gradient from the top-leading corner.
    case gradient(top: NSColor, bottom: NSColor)
    /// A solid fill with a hairline and a stripe down the leading edge.
    case solid(fill: NSColor, border: NSColor, stripe: NSColor, stripeWidth: CGFloat)
}

/// A built card: the transparent content view (icon and labels), what goes behind it, and the
/// root view that puts the two together for a panel.
struct CardContent {
    var root: NSView
    var content: NSView
    var backdrop: CardBackdrop
    var cornerRadius: CGFloat
    var size: CGSize
    var button: ActionButtonView?
}

/// The card's background for `hud`: the HUD material with rounded corners and the accent border.
final class CardBackgroundView: NSVisualEffectView {
    var accent: NSColor = .clear {
        didSet { updateBorderColor() }
    }

    init(frame: NSRect, cornerRadius: CGFloat) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
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

/// A view whose backing layer is a gradient, for `wash`.
final class GradientView: NSView {
    override func makeBackingLayer() -> CALayer {
        CAGradientLayer()
    }
}

/// Builds the view tree for a card, laid out by `CardLayout`.
enum CardViewBuilder {
    /// - Parameters:
    ///   - appearance: Forces light or dark; nil follows the system.
    ///   - offscreen: Keeps `glass` as `glass` where the system has none, for renderings that must
    ///     not depend on the machine.
    static func make(
        for card: Card, appearance: NSAppearance?, offscreen: Bool = false, console: Console
    ) -> CardContent {
        let metrics = CardMetrics(size: card.size)
        let accent = card.color.nsColor
        let style = offscreen ? card.style : resolvedStyle(card.style)
        let radius = style.cornerRadius
        let colors = TextColors(style: style, accent: accent)

        let titleFont: NSFont, detailFont: NSFont
        if style == .terminal {
            titleFont = .monospacedSystemFont(ofSize: metrics.titleFontSize * 0.96, weight: .semibold)
            detailFont = .monospacedSystemFont(ofSize: metrics.detailFontSize, weight: .regular)
        } else {
            titleFont = .systemFont(ofSize: metrics.titleFontSize, weight: .semibold)
            detailFont = .systemFont(ofSize: metrics.detailFontSize, weight: .regular)
        }
        let icon = style == .terminal ? nil : icon(for: card, pointSize: metrics.iconSize, console: console)
        let stripeWidth: CGFloat = style == .terminal ? 4 : 0
        // A button takes the trailing padding's place and brings its own: a gap after the text, and
        // room after the button.
        let trailing = CardLayout.trailing(metrics: metrics, hasIcon: icon != nil)
        let buttonGap = 14 * metrics.scale, buttonTrailing = 12 * metrics.scale
        let button = card.action.map {
            ActionButtonView(label: $0.label, look: ActionButtonView.look(for: style, accent: accent, scale: metrics.scale))
        }
        let buttonRoom = button.map { buttonGap + $0.frame.width + buttonTrailing - trailing } ?? 0
        // Text wraps where a card at its widest, button included, would otherwise cut it.
        let width = CardLayout.maxTextWidth(metrics: metrics, hasIcon: icon != nil, leadingInset: stripeWidth)
            - buttonRoom
        let title = makeLabel(
            card.title, font: titleFont, color: colors.title, width: width, maxLines: Defaults.titleLines)
        let detail = card.detail.map {
            makeLabel($0, font: detailFont, color: colors.detail, width: width, maxLines: Defaults.detailLines)
        }
        let eyebrow = style == .terminal
            ? makeLabel(
                card.kind.uppercased(),
                font: .monospacedSystemFont(ofSize: metrics.detailFontSize * 0.92, weight: .semibold),
                color: colors.eyebrow, width: width, maxLines: 1)
            : nil
        // Measure with each label's own fitting size so the text sits exactly where it is drawn.
        let layout = CardLayout(
            metrics: metrics, titleSize: title.fittingSize, detailSize: detail?.fittingSize, hasIcon: icon != nil,
            eyebrowSize: eyebrow?.fittingSize, leadingInset: stripeWidth)
        var size = layout.size
        if let button {
            let x = size.width - trailing + buttonGap
            button.setFrameOrigin(NSPoint(x: x, y: ((size.height - button.frame.height) / 2).rounded()))
            size.width = x + button.frame.width + buttonTrailing
        }
        let bounds = NSRect(origin: .zero, size: size)

        // Added in reading order, which VoiceOver follows: the kind, the title, the detail, the button.
        let content = NSView(frame: bounds)
        if let icon, let iconFrame = layout.iconFrame {
            let iconView = NSImageView(frame: iconFrame)
            iconView.image = icon.image
            iconView.imageScaling = .scaleProportionallyDown
            // A picture is drawn as it is; only a symbol takes the card's colour.
            if icon.isSymbol { iconView.contentTintColor = colors.icon }
            content.addSubview(iconView)
        }
        if let eyebrow, let eyebrowFrame = layout.eyebrowFrame {
            eyebrow.frame = eyebrowFrame
            content.addSubview(eyebrow)
        }
        title.frame = layout.titleFrame
        content.addSubview(title)
        if let detail, let detailFrame = layout.detailFrame {
            detail.frame = detailFrame
            content.addSubview(detail)
        }
        if let button { content.addSubview(button) }

        let backdrop: CardBackdrop
        switch style {
        case .hud:
            backdrop = .material(border: accent)
        case .glass:
            backdrop = .glass(tint: accent)
        case .wash:
            // The gradient follows the accent's light-mode color, whatever the appearance.
            let palette = WashPalette(accent: accent.rgb(in: NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()))
            backdrop = .gradient(top: NSColor(palette.top), bottom: NSColor(palette.bottom))
        case .terminal:
            backdrop = .solid(
                fill: NSColor(srgbRed: 0.086, green: 0.09, blue: 0.102, alpha: 1),
                border: NSColor(srgbRed: 0.17, green: 0.176, blue: 0.2, alpha: 1),
                stripe: accent, stripeWidth: stripeWidth)
        }
        let root = makeRoot(backdrop, bounds: bounds, radius: radius, content: content)
        // wash and terminal draw fixed colors; keep their accent and labels in the matching appearance.
        switch style {
        case .wash: root.appearance = NSAppearance(named: .aqua)
        case .terminal: root.appearance = NSAppearance(named: .darkAqua)
        case .hud, .glass: root.appearance = appearance
        }
        return CardContent(
            root: root, content: content, backdrop: backdrop, cornerRadius: radius, size: size, button: button)
    }

    /// `glass` needs macOS 26 and a compiler that knows it; elsewhere it is `hud`.
    static func resolvedStyle(_ style: CardStyle) -> CardStyle {
        guard style == .glass else { return style }
        return GlassSupport.isAvailable ? .glass : .hud
    }

    private static func makeRoot(_ backdrop: CardBackdrop, bounds: NSRect, radius: CGFloat, content: NSView) -> NSView {
        switch backdrop {
        case let .material(border):
            let view = CardBackgroundView(frame: bounds, cornerRadius: radius)
            view.accent = border
            view.addSubview(content)
            return view
        case let .glass(tint):
            if let view = GlassSupport.makeView(frame: bounds, cornerRadius: radius, tint: tint, content: content) {
                return view
            }
            let view = CardBackgroundView(frame: bounds, cornerRadius: radius)
            view.accent = tint
            view.addSubview(content)
            return view
        case let .gradient(top, bottom):
            let view = GradientView(frame: bounds)
            view.wantsLayer = true
            if let gradient = view.layer as? CAGradientLayer {
                gradient.colors = [top.cgColor, bottom.cgColor]
                // Layer coordinates start at the bottom left: run from the top-leading corner.
                gradient.startPoint = CGPoint(x: 0, y: 1)
                gradient.endPoint = CGPoint(x: 1, y: 0)
                gradient.cornerRadius = radius
                gradient.cornerCurve = .continuous
                gradient.masksToBounds = true
            }
            view.addSubview(content)
            return view
        case let .solid(fill, border, stripe, stripeWidth):
            let view = NSView(frame: bounds)
            view.wantsLayer = true
            view.layer?.backgroundColor = fill.cgColor
            view.layer?.borderColor = border.cgColor
            view.layer?.borderWidth = CardMetrics.borderWidth
            view.layer?.cornerRadius = radius
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = true
            let stripeView = NSView(frame: NSRect(x: 0, y: 0, width: stripeWidth, height: bounds.height))
            stripeView.wantsLayer = true
            stripeView.layer?.backgroundColor = stripe.cgColor
            view.addSubview(stripeView)
            view.addSubview(content)
            return view
        }
    }

    private struct TextColors {
        var title: NSColor
        var detail: NSColor
        var icon: NSColor
        var eyebrow: NSColor

        init(style: CardStyle, accent: NSColor) {
            switch style {
            case .hud, .glass:
                title = .labelColor
                detail = .secondaryLabelColor
                icon = accent
                eyebrow = accent
            case .wash:
                title = .white
                detail = NSColor.white.withAlphaComponent(WashPalette.detailOpacity)
                icon = .white
                eyebrow = .white
            case .terminal:
                title = NSColor(srgbRed: 0.925, green: 0.925, blue: 0.937, alpha: 1)
                detail = NSColor(srgbRed: 0.553, green: 0.561, blue: 0.588, alpha: 1)
                icon = accent
                eyebrow = accent
            }
        }
    }

    /// A label showing `text` in at most `maxLines` lines no wider than `width`, broken where it
    /// would otherwise be cut. The last line ends in an ellipsis when the text runs on.
    static func makeLabel(_ text: String, font: NSFont, color: NSColor, width: CGFloat, maxLines: Int) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        // Right-to-left text hugs the right edge of the text column; the icon stays put.
        let rightToLeft = CardText.isRightToLeft(text)
        label.alignment = rightToLeft ? .right : .left
        // Each line is measured as this label draws it, padding included, so none is ever clipped.
        let lines = CardLines.wrap(text, attributes: [.font: font], width: width, maxLines: maxLines) {
            label.stringValue = $0
            return Double(label.fittingSize.width)
        }
        label.stringValue = lines.joined(separator: "\n")
        if lines.count > 1 {
            // The lines are broken already: one per paragraph, never wrapped again or cut. Every line
            // reads in the text's own direction, however it starts.
            label.baseWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
            label.usesSingleLineMode = false
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byClipping
            label.setAccessibilityValue(text)
        } else {
            // Exactly the label a card had before text wrapped, so a line that fits looks the same.
            label.usesSingleLineMode = true
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        return label
    }

    /// The card's icon at `pointSize`, `onBlack` at the notch. One that cannot load falls back to the
    /// preset's icon with a warning.
    static func icon(for card: Card, pointSize: CGFloat, onBlack: Bool = false, console: Console) -> CardIcon? {
        if let found = CardIcon(card.icon, pointSize: pointSize, onBlack: onBlack) { return found }
        guard let problem = CardIcon.problem(card.icon) else { return nil }
        console.warn("\(problem); using the preset's icon")
        return CardIcon(card.fallbackIcon, pointSize: pointSize)
    }
}

/// A card's icon, loaded: an SF Symbol, which takes the card's colours, or a picture, an image
/// file, an app's icon or a bundled agent mark, which is drawn as it is.
struct CardIcon {
    var image: NSImage
    var isSymbol: Bool

    /// The transparent margin around the rounded square of a macOS app icon, as a fraction of its
    /// side, which is cut off so the app's mark fills the icon's place like a symbol's disc does.
    static let appIconMargin: CGFloat = 0.095

    /// `icon` at `pointSize`: a symbol at the spec's weight, an image or an app's icon fitted into a
    /// square, or a bundled mark, bare when it is drawn `onBlack`, else on its disc. Nil for no
    /// icon, and for one that cannot load.
    init?(_ icon: Icon, pointSize: CGFloat, onBlack: Bool = false) {
        switch icon {
        case .none:
            return nil
        case let .symbol(name):
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            else { return nil }
            self.init(image: symbol, isSymbol: true)
        case let .image(path):
            guard let picture = NSImage(contentsOfFile: path), picture.isValid,
                  let fitted = Self.fitted(picture, side: pointSize, margin: 0)
            else { return nil }
            self.init(image: fitted, isSymbol: false)
        case let .app(identifier):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
                  let fitted = Self.fitted(
                      NSWorkspace.shared.icon(forFile: url.path), side: pointSize, margin: Self.appIconMargin)
            else { return nil }
            self.init(image: fitted, isSymbol: false)
        case let .mark(name):
            guard let mark = AgentMark.named(name) else { return nil }
            self.init(image: Self.drawn(mark, side: pointSize, onDisc: !onBlack), isSymbol: false)
        }
    }

    private init(image: NSImage, isSymbol: Bool) {
        self.image = image
        self.isSymbol = isSymbol
    }

    /// Why `icon` cannot load, for the warning before drip falls back to the preset's icon.
    static func problem(_ icon: Icon) -> String? {
        switch icon {
        case .none: return nil
        case let .symbol(name): return "unknown SF Symbol '\(name)'"
        case let .image(path): return "cannot load the image '\(path)'"
        case let .app(identifier): return "no app with the bundle identifier '\(identifier)' is installed"
        case let .mark(name): return Icon.mark(name).problem
        }
    }

    /// `mark` in a `side` square, on its neutral disc when `onDisc`: vector paths, drawn at whatever
    /// scale the image is shown, so it stays sharp at every size.
    private static func drawn(_ mark: AgentMark, side: CGFloat, onDisc: Bool) -> NSImage {
        let place = mark.placement(side: Double(side), onDisc: onDisc)
        let transform = CGAffineTransform(
            a: CGFloat(place.scale), b: 0, c: 0, d: CGFloat(place.scale), tx: CGFloat(place.x), ty: CGFloat(place.y))
        let layers = zip(mark.layers, mark.outlines).map { layer, segments -> (CGPath, AgentMark.Paint) in
            let path = CGMutablePath()
            for segment in segments {
                switch segment {
                case let .move(x, y):
                    path.move(to: CGPoint(x: x, y: y), transform: transform)
                case let .line(x, y):
                    path.addLine(to: CGPoint(x: x, y: y), transform: transform)
                case let .cubic(x1, y1, x2, y2, x, y):
                    path.addCurve(
                        to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2),
                        transform: transform)
                case .close:
                    path.closeSubpath()
                }
            }
            return (path, layer.fill)
        }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        let disc = NSColor(AgentMark.disc).cgColor
        // Flipped, so y runs down as in the SVG the paths come from.
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            if onDisc {
                // As wide as a symbol's disc.
                context.setFillColor(disc)
                context.fillEllipse(in: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02))
            }
            for (path, paint) in layers {
                switch paint {
                case let .solid(color):
                    context.addPath(path)
                    context.setFillColor(NSColor(color).cgColor)
                    context.fillPath()
                case let .linear(x1, y1, x2, y2, stops):
                    let colors = stops.map {
                        NSColor(srgbRed: $0.color.red, green: $0.color.green, blue: $0.color.blue, alpha: $0.opacity)
                            .cgColor
                    }
                    var locations = stops.map { CGFloat($0.offset) }
                    guard let gradient = CGGradient(
                        colorsSpace: sRGB, colors: colors as CFArray, locations: &locations)
                    else { continue }
                    context.saveGState()
                    context.addPath(path)
                    context.clip()
                    context.drawLinearGradient(
                        gradient, start: CGPoint(x: x1, y: y1).applying(transform),
                        end: CGPoint(x: x2, y: y2).applying(transform),
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    context.restoreGState()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// `image` drawn into a `side` square, keeping its proportions, with `margin` of its side cut off
    /// all round first. Drawn at whatever scale it is shown, so it stays sharp as the island grows,
    /// and never a template, so nothing tints it.
    private static func fitted(_ image: NSImage, side: CGFloat, margin: CGFloat) -> NSImage? {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return nil }
        let crop = NSRect(origin: .zero, size: source).insetBy(dx: source.width * margin, dy: source.height * margin)
        let fitted = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let scale = min(rect.width / crop.width, rect.height / crop.height)
            let size = NSSize(width: crop.width * scale, height: crop.height * scale)
            let target = NSRect(
                x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            image.draw(in: target, from: crop, operation: .sourceOver, fraction: 1)
            return true
        }
        fitted.isTemplate = false
        return fitted
    }
}

/// The macOS 26 glass, behind a compiler and an availability check.
enum GlassSupport {
    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }

    static func makeView(frame: NSRect, cornerRadius: CGFloat, tint: NSColor, content: NSView) -> NSView? {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint.withAlphaComponent(0.12)
            glass.contentView = content
            return glass
        }
        #endif
        return nil
    }
}
#endif
