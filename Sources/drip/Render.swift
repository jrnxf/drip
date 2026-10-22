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
            png = IslandRenderer.png(for: card, at: time, leaving: leaving, console: console)
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

/// Draws a card fully open, as it hangs from a 185 by 32 point notch (a 14-inch MacBook Pro),
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
