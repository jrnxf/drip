#if canImport(AppKit)
import AppKit
import DripCore
import QuartzCore

/// The overflow drop's count and, with the pointer on the drop, the titles of the cards waiting,
/// clipped to the drop as the stack draws it. The count rolls to its new number as it changes, the
/// old one out one way and the new one in from the other, landing with a small pop, or, as a card
/// grows out of the drop, rolling up with that card on its spring; the titles crossfade with the
/// count. The stack draws the drop's black shape with the rest of its outline.
///
/// The root layer is flipped, as an island's is, so y grows down from the top of the screen; x is
/// offset so the notch's center is the layer's center.
final class OverflowLayers {
    let root = CALayer()
    /// Holds the count and the titles, clipped to the drop.
    private let content = CALayer()
    private let counts = CALayer()
    /// The count, and the one it was, rolling out. They swap at every roll, so the one showing the
    /// old number rolls it out as it is and only the hidden one takes a new number: a text layer
    /// given new text while hidden can show its old text for a moment once it shows.
    private var current = CATextLayer()
    private var previous = CATextLayer()
    private let titles = CATextLayer()
    private let sizeScale: CGFloat
    private let centerX: CGFloat
    private let countFont: NSFont
    private let titleFont: NSFont
    /// What the layers show, so a change is played once.
    private var shownChange = -Double.infinity
    private var shownPeek = -Double.infinity
    private var shownTitles = ""
    private var shownIn = false
    private var shownOut = false

    /// How far a number rolls as the count changes, in points at regular size.
    static let rollDistance = 11.0
    /// How long the roll takes, and the old number's fade out.
    static let rollDuration = 0.22
    static let rollFade = 0.12
    /// How long the two numbers crossfade as they roll with a card growing out of the drop.
    static let handOverFade = 0.25

    /// The count's font at regular size, as the button's.
    static func makeCountFont(scale: CGFloat) -> NSFont { .systemFont(ofSize: 12.5 * scale, weight: .semibold) }
    /// The titles' font at regular size, as the detail's.
    static func makeTitleFont(scale: CGFloat) -> NSFont { .systemFont(ofSize: 12 * scale, weight: .regular) }

    /// The drawn width of `text` in the count's font, at regular size.
    static func countWidth(_ text: String) -> Double {
        Double(NSAttributedString(string: text, attributes: [.font: makeCountFont(scale: 1)]).size().width)
    }

    /// The drawn width of `text` in the titles' font, at regular size.
    static func titlesWidth(_ text: String) -> Double {
        Double(NSAttributedString(string: text, attributes: [.font: makeTitleFont(scale: 1)]).size().width)
    }

    init(size: CGSize, sizeScale: CGFloat, scale: CGFloat) {
        self.sizeScale = sizeScale
        centerX = size.width / 2
        countFont = Self.makeCountFont(scale: sizeScale)
        titleFont = Self.makeTitleFont(scale: sizeScale)
        root.frame = CGRect(origin: .zero, size: size)
        root.isGeometryFlipped = true
        root.contentsScale = scale
        root.zPosition = 1
        content.masksToBounds = true
        content.opacity = 0
        root.addSublayer(content)
        counts.frame = CGRect(origin: .zero, size: size)
        content.addSublayer(counts)
        let lineHeight = ceil(NSAttributedString(string: "0", attributes: [.font: countFont]).size().height)
        for layer in [previous, current] {
            layer.bounds = CGRect(x: 0, y: 0, width: 80 * sizeScale, height: lineHeight)
            layer.alignmentMode = .center
            layer.contentsScale = scale
            layer.opacity = 0
            counts.addSublayer(layer)
        }
        current.opacity = 1
        let titleHeight = ceil(NSAttributedString(string: "A", attributes: [.font: titleFont]).size().height)
        titles.bounds = CGRect(x: 0, y: 0, width: 0, height: titleHeight)
        titles.alignmentMode = .center
        titles.truncationMode = .end
        titles.contentsScale = scale
        titles.opacity = 0
        content.addSublayer(titles)
    }

    /// The layers' model values at one instant: the drop's clip, and its middle.
    struct Frame {
        var clip: CGRect
        var radius: CGFloat
        var center: CGPoint
    }

    func frame(_ shape: IslandShape, metrics: IslandMetrics) -> Frame {
        let clip = CGRect(
            x: centerX - shape.pillWidth / 2, y: shape.pillTop, width: shape.pillWidth, height: shape.pillHeight)
        // Half a point low, as the button's label sits.
        return Frame(clip: clip, radius: CGFloat(shape.pillRadius(metrics)), center: CGPoint(x: clip.midX, y: clip.midY + 0.5))
    }

    func apply(_ frame: Frame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Bounds that start where the frame does keep the content in the root's coordinates.
        content.bounds = frame.clip
        content.position = CGPoint(x: frame.clip.midX, y: frame.clip.midY)
        content.cornerRadius = frame.radius
        for layer in [previous, current, titles] { layer.position = frame.center }
        CATransaction.commit()
    }

    /// Plays `frames`, sampled evenly over `duration` from `begin`, as keyframe animations, and
    /// leaves the model at the last frame.
    func play(_ frames: [Frame], duration: Double, begin: CFTimeInterval) {
        guard let last = frames.last else { return }
        func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.duration = duration
            animation.calculationMode = .linear
            animation.beginTime = begin
            return animation
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(last)
        content.add(keyframes("bounds", frames.map { NSValue(rect: $0.clip) }), forKey: "drop")
        content.add(
            keyframes("position", frames.map { NSValue(point: CGPoint(x: $0.clip.midX, y: $0.clip.midY)) }),
            forKey: "drop.position")
        content.add(keyframes("cornerRadius", frames.map(\.radius)), forKey: "drop.radius")
        for layer in [previous, current, titles] {
            layer.add(keyframes("position", frames.map { NSValue(point: $0.center) }), forKey: "drop")
        }
        CATransaction.commit()
    }

    /// Plays what changed on `overflow` since the last call, with times on the stack's clock, which
    /// started at `started`: the count fading in as the drop forms, rolling as it ticks, crossfading
    /// with the titles as the pointer comes onto the drop or leaves it, and fading out as it goes.
    func update(_ overflow: CardStack.Overflow, started: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if !shownIn {
            shownIn = true
            current.string = count(overflow.count)
            var begin = started
            if case let .forming(start, cues) = overflow.phase { begin += start + CardStack.countCue(cues) }
            fade(content, to: 1, over: 0.18, at: begin)
        }
        if overflow.changedAt != shownChange {
            shownChange = overflow.changedAt
            roll(
                from: overflow.previous, to: overflow.count, at: started + overflow.changedAt,
                handingOver: overflow.handedOver)
        }
        if overflow.peekText != shownTitles {
            shownTitles = overflow.peekText
            titles.string = NSAttributedString(string: overflow.peekText, attributes: [
                .font: titleFont, .foregroundColor: NSColor(white: 0.78, alpha: 1),
            ])
        }
        // As wide as the drop springs to list them, less its ends.
        if overflow.peeking {
            titles.bounds.size.width = CGFloat(overflow.animator.metrics.pillWidth) - 24 * sizeScale
        }
        if overflow.peekChangedAt != shownPeek {
            shownPeek = overflow.peekChangedAt
            let begin = started + overflow.peekChangedAt
            if overflow.peeking {
                fade(counts, to: 0, over: IslandUpdate.fadeOut, at: begin)
                fade(titles, to: 1, over: IslandUpdate.fadeIn, at: begin + IslandUpdate.fadeOut)
            } else {
                fade(titles, to: 0, over: IslandUpdate.fadeOut, at: begin)
                fade(counts, to: 1, over: IslandUpdate.fadeIn, at: begin)
            }
        }
        if case let .leaving(start, _) = overflow.phase, !shownOut {
            shownOut = true
            fade(content, to: 0, over: IslandCues.fadeOut, at: started + start)
        }
    }

    /// The count's last number rolling out as the drop itself spreads into the last card waiting,
    /// at `begin`.
    func rollOut(from count: Int, at begin: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        roll(from: count, to: 0, at: begin, handingOver: true)
        CATransaction.commit()
    }

    private func count(_ value: Int) -> NSAttributedString {
        NSAttributedString(string: String(value), attributes: [.font: countFont, .foregroundColor: NSColor.white])
    }

    /// The old number rolls out one way and fades, and the new one rolls in from the other and lands
    /// with a small pop: up as the count goes up, down as it goes down. `handingOver`, as a card grows
    /// out of the drop, both roll up with that card on its spring and crossfade, with no pop. At 0
    /// only the old one rolls out.
    private func roll(from old: Int, to new: Int, at begin: CFTimeInterval, handingOver: Bool = false) {
        let direction: CGFloat = handingOver || new > old ? 1 : -1
        let distance = CGFloat(Self.rollDistance) * sizeScale * direction
        let handOver = handingOver ? CardStack.handOver : nil
        for layer in [previous, current] {
            for key in ["roll", "fade", "pop"] { layer.removeAnimation(forKey: key) }
        }
        swap(&previous, &current)
        if old > 0 {
            if (previous.string as? NSAttributedString)?.string != String(old) { previous.string = count(old) }
            move(previous, from: 0, to: -distance, at: begin, on: handOver)
            fade(previous, from: 1, to: 0, over: handingOver ? Self.handOverFade : Self.rollFade, at: begin)
        }
        guard new > 0 else {
            current.opacity = 0
            return
        }
        current.string = count(new)
        move(current, from: distance, to: 0, at: begin, on: handOver)
        fade(current, from: 0, to: 1, over: handingOver ? Self.handOverFade : Self.rollDuration, at: begin)
        guard !handingOver else { return }
        let landing = CASpringAnimation(keyPath: "transform.scale")
        let spring = IslandUpdate.pop
        landing.mass = 1
        landing.stiffness = spring.stiffness
        landing.damping = spring.damping
        landing.duration = spring.settlingTime
        landing.isAdditive = true
        landing.fromValue = IslandUpdate.popScale - 1
        landing.toValue = 0
        landing.beginTime = begin
        landing.fillMode = .backwards
        current.add(landing, forKey: "pop")
    }

    /// Moves `layer` from `from` to `to` points down, eased out over `rollDuration`, or on `spring`.
    private func move(_ layer: CALayer, from: CGFloat, to: CGFloat, at begin: CFTimeInterval, on spring: Spring? = nil) {
        let animation: CABasicAnimation
        if let spring {
            let springing = CASpringAnimation(keyPath: "transform.translation.y")
            springing.mass = 1
            springing.stiffness = spring.stiffness
            springing.damping = spring.damping
            springing.duration = spring.settlingTime
            animation = springing
        } else {
            animation = CABasicAnimation(keyPath: "transform.translation.y")
            animation.duration = Self.rollDuration
            animation.timingFunction = CardPresenters.easeOut
        }
        animation.fromValue = from
        animation.toValue = to
        animation.beginTime = begin
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "roll")
    }

    private func fade(_ layer: CALayer, from: Float? = nil, to: Float, over duration: Double, at begin: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from ?? (layer.presentation() ?? layer).opacity
        animation.toValue = to
        animation.beginTime = begin
        animation.duration = duration
        animation.timingFunction = CardPresenters.easeOut
        animation.fillMode = .backwards
        layer.opacity = to
        layer.add(animation, forKey: "fade")
    }
}
#endif
