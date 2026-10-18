#if canImport(AppKit)
import AppKit
import DripCore

extension HUDDisplay {
    func render(
        _ card: Card, appearance: RenderCommand.Appearance, at time: Double?, leaving: Bool, to path: String,
        console: Console
    ) -> Int32 {
        guard let nsAppearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua) else {
            console.error("cannot load the \(appearance.rawValue) appearance")
            return 1
        }
        var png: Data?
        nsAppearance.performAsCurrentDrawingAppearance {
            png = card.position == .notch
                ? IslandRenderer.png(for: card, at: time, leaving: leaving, console: console)
                : CardRenderer.png(for: card, appearance: nsAppearance, console: console)
        }
        guard let png else {
            console.error("cannot render the card")
            return 1
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            console.error("cannot write \(path): \(error.localizedDescription)")
            return 1
        }
        return 0
    }
}

/// Pixels per point for offscreen renderings.
private let renderScale: CGFloat = 2

private func bitmap(size: NSSize) -> NSBitmapImageRep? {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int((size.width * renderScale).rounded()),
        pixelsHigh: Int((size.height * renderScale).rounded()),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0)
    bitmap?.size = size
    return bitmap
}

/// Draws a card offscreen. The content view (icon and labels) is the one the panel shows; only the
/// window server can draw materials and glass, so the renderer paints the card's backdrop itself
/// from the same description: the window background in place of a material, and the gradients,
/// fills, stripes and hairlines as they are.
enum CardRenderer {
    static func png(for card: Card, appearance: NSAppearance, console: Console) -> Data? {
        let built = CardViewBuilder.make(for: card, appearance: appearance, offscreen: true, console: console)
        // Render the content in the appearance the panel would give it.
        built.content.appearance = built.root.appearance ?? appearance
        let bounds = NSRect(origin: .zero, size: built.size)
        guard let content = bitmap(size: bounds.size),
              let output = bitmap(size: bounds.size),
              let context = NSGraphicsContext(bitmapImageRep: output)
        else { return nil }
        built.content.cacheDisplay(in: bounds, to: content)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        (built.root.appearance ?? appearance).performAsCurrentDrawingAppearance {
            let radius = built.cornerRadius
            let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
            shape.addClip()
            paint(built.backdrop, in: bounds, shape: shape)
            _ = content.draw(
                in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            stroke(built.backdrop, in: bounds, radius: radius)
        }
        context.flushGraphics()
        return output.representation(using: .png, properties: [:])
    }

    private static func paint(_ backdrop: CardBackdrop, in bounds: NSRect, shape: NSBezierPath) {
        switch backdrop {
        case .material:
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
        case let .glass(tint):
            // A stand-in for the glass: the window background with the faint tint glass gives it.
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
            tint.withAlphaComponent(0.12).setFill()
            shape.fill()
        case let .gradient(top, bottom):
            NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: -45)
        case let .solid(fill, _, stripe, stripeWidth):
            fill.setFill()
            shape.fill()
            stripe.setFill()
            NSRect(x: 0, y: 0, width: stripeWidth, height: bounds.height).fill()
        }
    }

    /// A layer border lies inside the bounds and follows the rounded corners.
    private static func stroke(_ backdrop: CardBackdrop, in bounds: NSRect, radius: CGFloat) {
        let color: NSColor
        switch backdrop {
        case let .material(border): color = border.withAlphaComponent(CardMetrics.borderAlpha)
        case .glass: color = NSColor.white.withAlphaComponent(0.35)
        case .gradient: return
        case let .solid(_, border, _, _): color = border
        }
        let width = CardMetrics.borderWidth
        let inset = width / 2
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
        border.lineWidth = width
        color.setStroke()
        border.stroke()
    }
}

/// Draws a notch card fully open, as it hangs from a 185 by 32 point notch (a 14-inch MacBook Pro),
/// over a strip of menu bar so the shape's edges show.
enum IslandRenderer {
    static let notch = NotchGeometry(width: 185, height: 32)

    /// - Parameters:
    ///   - time: Seconds into the entrance, or the exit when `leaving`; nil draws the card fully open.
    static func png(for card: Card, at time: Double?, leaving: Bool, console: Console) -> Data? {
        let layers = IslandLayers(card: card, notch: notch, scale: renderScale, console: console)
        var animator = IslandAnimator(metrics: layers.metrics)
        if let time, leaving {
            animator.open()
            let cues = animator.exit(at: 0)
            let shape = animator.shape(at: time)
            layers.apply(layers.frame(shape, layout: animator.content(for: shape)))
            layers.hideContent(at: time, cues: cues)
        } else if let time {
            let cues = animator.enter(at: 0)
            let shape = animator.shape(at: time)
            layers.apply(layers.frame(shape, layout: animator.content(for: shape)))
            layers.showContent(at: time, cues: cues)
        } else {
            animator.open()
            let open = animator.shape(at: 0)
            layers.apply(layers.frame(open, layout: animator.content(for: open)))
            layers.showContent()
        }

        let size = layers.size
        guard let output = bitmap(size: size), let context = NSGraphicsContext(bitmapImageRep: output) else {
            return nil
        }
        let cg = context.cgContext
        cg.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        cg.setFillColor(NSColor(white: 0.78, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: size.height - notch.height, width: size.width, height: notch.height))
        // The layer tree is flipped; CGContext's origin is at the bottom left.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        layers.root.render(in: cg)
        context.flushGraphics()
        return output.representation(using: .png, properties: [:])
    }
}
#endif
