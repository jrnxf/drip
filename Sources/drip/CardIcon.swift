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

/// A card's icon, loaded: an SF Symbol, which takes the card's colours, or a picture, an image
/// file, an app's icon or a bundled agent mark, which is drawn as it is.
struct CardIcon {
    var image: NSImage
    var isSymbol: Bool

    /// The transparent margin around the rounded square of a macOS app icon, as a fraction of its
    /// side, which is cut off so the app's mark fills the icon's place like a symbol's disc does.
    static let appIconMargin: CGFloat = 0.095

    /// `icon` at `pointSize`: a symbol at the spec's weight, an image or an app's icon fitted into a
    /// square, or a bundled mark. Nil for no icon, and for one that cannot load.
    init?(_ icon: Icon, pointSize: CGFloat) {
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
            self.init(image: Self.drawn(mark, side: pointSize), isSymbol: false)
        }
    }

    /// The card's icon at `pointSize`. One that cannot load falls back to the preset's icon with a
    /// warning.
    init?(card: Card, pointSize: CGFloat, console: Console) {
        if let found = CardIcon(card.icon, pointSize: pointSize) {
            self = found
            return
        }
        guard let problem = Self.problem(card.icon) else { return nil }
        console.warn("\(problem); using the preset's icon")
        guard let fallback = CardIcon(card.fallbackIcon, pointSize: pointSize) else { return nil }
        self = fallback
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

    /// `mark` in a `side` square, bare for the island's black: vector paths, drawn at whatever scale
    /// the image is shown, so it stays sharp at every size.
    private static func drawn(_ mark: AgentMark, side: CGFloat) -> NSImage {
        let place = mark.placement(side: Double(side))
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
        // Flipped, so y runs down as in the SVG the paths come from.
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
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
#endif
