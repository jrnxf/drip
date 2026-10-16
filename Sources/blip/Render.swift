#if canImport(AppKit)
import AppKit
import BlipCore

extension HUDDisplay {
    func render(
        _ card: Card, appearance: RenderCommand.Appearance, scale: Double, to path: String, console: Console
    ) -> Int32 {
        guard let nsAppearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua) else {
            console.error("cannot load the \(appearance.rawValue) appearance")
            return 1
        }
        var png: Data?
        nsAppearance.performAsCurrentDrawingAppearance {
            png = CardRenderer.png(for: card, appearance: nsAppearance, scale: CGFloat(scale), console: console)
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

/// Draws a card offscreen. The view tree is the one the panel shows; only the window server can
/// draw the HUD material and a layer's border, so the renderer paints those itself: the window
/// background color in place of the material, and the border stroked from the layer's own values.
enum CardRenderer {
    static func png(for card: Card, appearance: NSAppearance, scale: CGFloat, console: Console) -> Data? {
        let view = CardViewBuilder.makeView(for: card, appearance: appearance, console: console)
        let bounds = view.bounds
        guard let content = bitmap(size: bounds.size, scale: scale),
              let output = bitmap(size: bounds.size, scale: scale),
              let context = NSGraphicsContext(bitmapImageRep: output)
        else { return nil }

        let borderWidth = view.layer?.borderWidth ?? 0
        let borderColor = view.layer?.borderColor.flatMap { NSColor(cgColor: $0) }
        let radius = view.layer?.cornerRadius ?? 0
        // Keep the border out of the cached content so it is drawn exactly once.
        view.layer?.borderWidth = 0
        view.cacheDisplay(in: bounds, to: content)
        view.layer?.borderWidth = borderWidth

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context

        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.windowBackgroundColor.setFill()
        shape.fill()
        shape.addClip()
        content.draw(
            in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        if let borderColor, borderWidth > 0 {
            // A layer border lies inside the bounds and follows the rounded corners.
            let inset = borderWidth / 2
            let border = NSBezierPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
            border.lineWidth = borderWidth
            borderColor.setStroke()
            border.stroke()
        }
        context.flushGraphics()
        return output.representation(using: .png, properties: [:])
    }

    private static func bitmap(size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
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
}
#endif
