#if canImport(AppKit)
import AppKit
import BlipCore

/// The pill button at a card's trailing edge. Drawn in `draw(_:)` rather than with layer properties,
/// so the offscreen renderer captures it too.
final class ActionButtonView: NSView {
    struct Look {
        var fill: NSColor
        var hoverFill: NSColor
        var border: NSColor?
        var text: NSColor
        var font: NSFont
        var radius: CGFloat?
    }

    var onClick: (() -> Void)?
    private let title: NSAttributedString
    private let look: Look
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    static let height: CGFloat = 26
    static let horizontalPadding: CGFloat = 12

    init(label: String, look: Look) {
        self.look = look
        title = NSAttributedString(string: label, attributes: [.font: look.font, .foregroundColor: look.text])
        let size = CGSize(
            width: ceil(title.size().width) + 2 * Self.horizontalPadding, height: Self.height)
        super.init(frame: NSRect(origin: .zero, size: size))
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Clicks land on the first try even though the panel never becomes key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        // A pressed button shrinks a little, so the click is felt before the card goes.
        let inset: CGFloat = pressed ? 1 : 0
        let rect = bounds.insetBy(dx: inset + 0.5, dy: inset + 0.5)
        let radius = look.radius ?? rect.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        (hovering || pressed ? look.hoverFill : look.fill).setFill()
        path.fill()
        if let border = look.border {
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let size = title.size()
        title.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    static func look(for style: CardStyle, accent: NSColor, scale: CGFloat) -> Look {
        let font = NSFont.systemFont(ofSize: 12.5 * scale, weight: .semibold)
        switch style {
        case .hud, .glass:
            // Darkened until white text reads on it, like the wash style's background.
            let fill = NSColor(WashPalette(accent: accent.rgb(in: NSAppearance(named: .aqua) ?? .currentDrawing())).top)
            return Look(
                fill: fill, hoverFill: fill.blended(withFraction: 0.12, of: .white) ?? fill, border: nil,
                text: .white, font: font, radius: nil)
        case .wash:
            return Look(
                fill: NSColor(white: 1, alpha: 0.2), hoverFill: NSColor(white: 1, alpha: 0.3), border: nil,
                text: .white, font: font, radius: nil)
        case .terminal:
            return Look(
                fill: .clear, hoverFill: accent.withAlphaComponent(0.16), border: accent, text: accent,
                font: .monospacedSystemFont(ofSize: 12 * scale, weight: .semibold), radius: 4)
        }
    }
}

/// What a click on a card's button does.
enum CardActions {
    /// Set when a card with a button went away without the button being clicked.
    static var missed = false

    static func perform(_ action: CardAction, console: Console) {
        guard let target = action.open else { return }
        let url = target.contains("://") ? URL(string: target) : URL(fileURLWithPath: (target as NSString)
            .expandingTildeInPath)
        guard let url, NSWorkspace.shared.open(url) else {
            console.error("cannot open \(target)")
            return
        }
    }
}
#endif
