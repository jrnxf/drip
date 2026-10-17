import Foundation

// A card at `position = notch` is drawn as one black shape that grows out of the camera notch.
// Coordinates here are in points with x = 0 at the notch's center and y growing down from the
// top of the screen.

/// The sizes an island is built from.
public struct IslandMetrics: Equatable, Sendable {
    public var notchWidth: Double
    public var notchHeight: Double
    public var scale: Double
    /// The text block's size: title over detail, as measured by the renderer.
    public var textWidth: Double
    public var textHeight: Double
    /// The title alone in the compact font, for `ears`.
    public var compactTitleWidth: Double
    public var hasIcon: Bool

    public init(
        notchWidth: Double, notchHeight: Double, scale: Double = 1, textWidth: Double, textHeight: Double,
        compactTitleWidth: Double, hasIcon: Bool = true
    ) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.scale = scale
        self.textWidth = textWidth
        self.textHeight = textHeight
        self.compactTitleWidth = compactTitleWidth
        self.hasIcon = hasIcon
    }

    // The expanded card (`snap`).
    var cardIcon: Double { hasIcon ? 28 * scale : 0 }
    var cardRing: Double { 22 * scale }
    var cardPadding: Double { 16 * scale }
    var cardGap: Double { 12 * scale }
    var cardTextX: Double { cardPadding + (hasIcon ? cardIcon + cardGap : 0) }
    public var cardWidth: Double {
        let width = cardTextX + textWidth + cardGap + cardRing + cardPadding
        return min(max(width, notchWidth + 80 * scale), Double(CardMetrics.maxWidth))
    }
    public var cardHeight: Double { notchHeight + 2 * 14 * scale + max(textHeight, cardIcon) }
    public var cardRadius: Double { 22 * scale }
    /// The notch's own bottom corners.
    public var notchRadius: Double { min(10, notchHeight / 3) }

    // The free-floating capsule (`droplet`).
    var pillIcon: Double { hasIcon ? 24 * scale : 0 }
    var pillRing: Double { 20 * scale }
    var pillPadding: Double { 14 * scale }
    var pillGap: Double { 10 * scale }
    var pillTextX: Double { pillPadding + (hasIcon ? pillIcon + pillGap : 0) }
    public var pillWidth: Double {
        let width = pillTextX + textWidth + pillGap + pillRing + pillPadding
        return min(max(width, 200 * scale), Double(CardMetrics.maxWidth))
    }
    public var pillHeight: Double { 2 * 12 * scale + max(textHeight, pillIcon) }
    public var pillTop: Double { notchHeight + 12 * scale }
    /// The round drop the capsule starts and ends as.
    public var dropSize: Double { 26 * scale }
    /// The drop's size when it starts to form, before the notch has fed it.
    public var seedSize: Double { 12 * scale }
    /// How far apart the drop and the notch still pull on each other: the smooth union's radius.
    /// The neck between them pinches off at a third of this gap.
    public var blend: Double { 24 * scale }
    /// The drop's top while it waits inside the notch, too deep to make the notch bulge.
    public var dropTop: Double { notchHeight - blend - dropSize }

    // Ears (`ears`): an icon ear on the left, a title ear on the right, inside the menu bar.
    public var leftEar: Double { hasIcon ? 40 * scale : 12 * scale }
    public var rightEar: Double { min(compactTitleWidth + 26 * scale, Double(CardMetrics.maxWidth) / 2) }
    var earIcon: Double { 16 * scale }

    /// The widest the island gets, for sizing its window.
    public var maxWidth: Double {
        max(cardWidth, pillWidth, 2 * (notchWidth / 2 + max(leftEar, rightEar))) + 2 * IslandShape.maxShoulder
    }

    /// The tallest the island gets, overshoot included.
    public var maxHeight: Double {
        max(cardHeight, pillTop + pillHeight) + 16 * scale
    }
}

/// The island at one instant.
public struct IslandShape: Equatable, Sendable {
    /// The shape hanging from the top edge, around the notch.
    public var left: Double
    public var right: Double
    public var height: Double
    /// The droplet's capsule; it shows only for `droplet`.
    public var pillTop: Double
    public var pillWidth: Double
    public var pillHeight: Double
    /// 0 at rest, 1 fully open. Drives the content's size and place.
    public var progress: Double
    /// How strongly the drop and the notch melt together (`droplet`); 0 keeps them apart.
    public var blend: Double

    public init(
        left: Double, right: Double, height: Double, pillTop: Double, pillWidth: Double, pillHeight: Double,
        progress: Double, blend: Double = 0
    ) {
        self.left = left
        self.right = right
        self.height = height
        self.pillTop = pillTop
        self.pillWidth = pillWidth
        self.pillHeight = pillHeight
        self.progress = progress
        self.blend = blend
    }

    /// The concave flare where the shape meets the top edge, at its widest.
    public static let maxShoulder = 8.0

    /// The flare on one side, growing as the shape widens past the notch.
    public static func shoulder(overhang: Double) -> Double {
        maxShoulder * min(max(overhang / 16, 0), 1)
    }

    /// The bottom corners' radius, from the notch's to the card's as the shape drops.
    public func radius(_ metrics: IslandMetrics) -> Double {
        let drop = (height - metrics.notchHeight) / max(metrics.cardHeight - metrics.notchHeight, 1)
        let radius = metrics.notchRadius + (metrics.cardRadius - metrics.notchRadius) * min(max(drop, 0), 1)
        return min(radius, height / 2, (right - left) / 2)
    }
}

/// A point in island coordinates.
public struct IslandPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// Where the island's icon, countdown ring and text sit at one instant.
public struct IslandContentLayout: Equatable, Sendable {
    public var iconCenter: IslandPoint
    public var iconSize: Double
    public var ringCenter: IslandPoint
    public var ringSize: Double
    /// The text block's leading edge and vertical center.
    public var textX: Double
    public var textCenterY: Double
    /// `ears` shows only the title, in the compact font.
    public var compact: Bool
}

/// When each part of the content fades, in seconds after the shape starts moving; nil never shows.
public struct IslandCues: Equatable, Sendable {
    public var icon: Double?
    public var ring: Double?
    public var title: Double?
    public var detail: Double?
}

/// Moves the island through its entrance and exit with springs.
public struct IslandAnimator: Sendable {
    public let motion: NotchMotion
    public let metrics: IslandMetrics
    private var left, right, height, dropCenter, pillWidth, pillHeight, progress, blend: SpringValue

    public init(motion: NotchMotion, metrics: IslandMetrics) {
        self.motion = motion
        self.metrics = metrics
        left = SpringValue(-metrics.notchWidth / 2)
        right = SpringValue(metrics.notchWidth / 2)
        height = SpringValue(metrics.notchHeight)
        dropCenter = SpringValue(metrics.dropTop + metrics.dropSize / 2)
        pillWidth = SpringValue(motion == .droplet ? metrics.seedSize : metrics.dropSize)
        pillHeight = SpringValue(motion == .droplet ? metrics.seedSize : metrics.dropSize)
        progress = SpringValue(0)
        blend = SpringValue(motion == .droplet ? metrics.blend : 0)
    }

    /// Starts the entrance at `time` and returns when the content fades in.
    public mutating func enter(at time: Double) -> IslandCues {
        let m = metrics
        switch motion {
        case .droplet:
            // The drop swells under the notch, stretches into a neck as it falls, and pinches off;
            // only then does it spread into the capsule, while the notch pulls its half of the neck
            // back in.
            let fall = Spring(duration: 0.62, bounce: 0.2)
            let center = m.pillTop + m.pillHeight / 2
            dropCenter.animate(to: center, with: fall, at: time)
            // The notch feeds the drop as it hangs, so the bulb outgrows its neck.
            let feed = Spring(duration: 0.3)
            pillWidth.animate(to: m.dropSize, with: feed, at: time)
            pillHeight.animate(to: m.dropSize, with: feed, at: time)
            let start = dropCenter.value(at: time)
            let detached = Self.firstTime(after: time) { t in
                start + (center - start) * fall.progress(at: t - time) - m.dropSize / 2
                    >= m.notchHeight + m.blend / 3
            }
            blend.animate(to: 0, with: Spring(duration: 0.35), at: detached)
            let grow = Spring(duration: 0.5, bounce: 0.15)
            pillWidth.animate(to: m.pillWidth, with: grow, at: detached)
            pillHeight.animate(to: m.pillHeight, with: grow, at: detached)
            progress.animate(to: 1, with: grow, at: detached)
            // Text waits until the capsule is wide enough to hold it.
            let roomy = Self.firstTime(after: detached) { grow.progress(at: $0 - detached) >= 0.8 }
            return IslandCues(icon: detached - time, ring: roomy - time, title: roomy - time,
                              detail: roomy - time + 0.04)
        case .snap:
            let snap = Spring(duration: 0.26)
            left.animate(to: -m.cardWidth / 2, with: snap, at: time)
            right.animate(to: m.cardWidth / 2, with: snap, at: time)
            height.animate(to: m.cardHeight, with: snap, at: time)
            progress.animate(to: 1, with: snap, at: time)
            return IslandCues(icon: 0.06, ring: 0.08, title: 0.09, detail: 0.13)
        case .ears:
            let ears = Spring(duration: 0.4, bounce: 0.2)
            left.animate(to: -m.notchWidth / 2 - m.leftEar, with: ears, at: time)
            right.animate(to: m.notchWidth / 2 + m.rightEar, with: ears, at: time)
            progress.animate(to: 1, with: ears, at: time)
            return IslandCues(icon: m.hasIcon ? 0.06 : nil, ring: nil, title: 0.17, detail: nil)
        }
    }

    /// Starts the exit at `time`, faster than the entrance and without bounce, back into the notch.
    /// Returns when the content fades out.
    public mutating func exit(at time: Double) -> IslandCues {
        let m = metrics
        switch motion {
        case .droplet:
            // The capsule gathers back into a drop, which rises; the notch reaches for it, they merge
            // and the notch swallows it.
            let shrink = Spring(duration: 0.26)
            pillWidth.animate(to: m.dropSize, with: shrink, at: time + 0.03)
            pillHeight.animate(to: m.dropSize, with: shrink, at: time + 0.03)
            progress.animate(to: 0, with: shrink, at: time + 0.03)
            let rise = time + 0.2
            blend.animate(to: m.blend, with: Spring(duration: 0.3), at: rise)
            // Aimed past its resting place, so it is swallowed at speed instead of easing in, and the
            // notch's bulge goes flat as quickly as liquid would.
            dropCenter.animate(to: m.dropTop + m.dropSize / 2 - m.dropSize, with: Spring(duration: 0.4), at: rise)
            return IslandCues(icon: 0.14, ring: 0, title: 0, detail: 0)
        case .snap:
            let snap = Spring(duration: 0.2)
            left.animate(to: -m.notchWidth / 2, with: snap, at: time + 0.04)
            right.animate(to: m.notchWidth / 2, with: snap, at: time + 0.04)
            height.animate(to: m.notchHeight, with: snap, at: time + 0.04)
            progress.animate(to: 0, with: snap, at: time + 0.04)
            return IslandCues(icon: 0, ring: 0, title: 0, detail: 0)
        case .ears:
            let back = Spring(duration: 0.25)
            left.animate(to: -m.notchWidth / 2, with: back, at: time + 0.08)
            right.animate(to: m.notchWidth / 2, with: back, at: time + 0.08)
            progress.animate(to: 0, with: back, at: time + 0.08)
            return IslandCues(icon: 0.06, ring: nil, title: 0, detail: nil)
        }
    }

    /// Jumps straight to fully open, for reduced motion and offscreen rendering.
    public mutating func open() {
        let m = metrics
        switch motion {
        case .droplet:
            dropCenter.jump(to: m.pillTop + m.pillHeight / 2)
            pillWidth.jump(to: m.pillWidth)
            pillHeight.jump(to: m.pillHeight)
            blend.jump(to: 0)
        case .snap:
            left.jump(to: -m.cardWidth / 2)
            right.jump(to: m.cardWidth / 2)
            height.jump(to: m.cardHeight)
        case .ears:
            left.jump(to: -m.notchWidth / 2 - m.leftEar)
            right.jump(to: m.notchWidth / 2 + m.rightEar)
        }
        progress.jump(to: 1)
    }

    /// When every spring has settled.
    public var end: Double {
        [left, right, height, dropCenter, pillWidth, pillHeight, progress, blend].compactMap(\.end).max() ?? 0
    }

    public func shape(at time: Double) -> IslandShape {
        var width = pillWidth.value(at: time), tall = pillHeight.value(at: time)
        let opened = progress.value(at: time)
        if motion == .droplet {
            // A moving drop stretches along its path and keeps its area; the capsule stays rigid.
            let step = 1.0 / 240
            let speed = abs(dropCenter.value(at: time + step) - dropCenter.value(at: time - step)) / (2 * step)
            let stretch = 1 + min(speed / (3000 * metrics.scale), 0.07) * max(1 - opened, 0)
            tall *= stretch
            width /= stretch
        }
        let center = dropCenter.value(at: time)
        return IslandShape(
            left: left.value(at: time), right: right.value(at: time), height: height.value(at: time),
            pillTop: center - tall / 2, pillWidth: width, pillHeight: tall, progress: opened,
            blend: max(blend.value(at: time), 0))
    }

    /// The first time from `start`, in 1 ms steps and within 2 s, at which `condition` holds.
    private static func firstTime(after start: Double, where condition: (Double) -> Bool) -> Double {
        var time = start
        while time < start + 2, !condition(time) { time += 0.001 }
        return time
    }

    public func content(for shape: IslandShape) -> IslandContentLayout {
        let m = metrics
        let p = shape.progress
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
        switch motion {
        case .droplet:
            // The ring and text sit where the open capsule puts them and the growing capsule reveals
            // them; only the icon travels, from the middle of the drop to its place.
            let left = -m.pillWidth / 2, right = m.pillWidth / 2
            let centerY = shape.pillTop + shape.pillHeight / 2
            return IslandContentLayout(
                iconCenter: IslandPoint(lerp(0, left + m.pillPadding + m.pillIcon / 2), centerY),
                iconSize: lerp(16 * m.scale, m.pillIcon),
                ringCenter: IslandPoint(right - m.pillPadding - m.pillRing / 2, centerY), ringSize: m.pillRing,
                textX: left + m.pillTextX, textCenterY: centerY, compact: false)
        case .snap:
            let rowCenter = m.notchHeight + (m.cardHeight - m.notchHeight) / 2
            let centerY = m.notchHeight / 2 + (rowCenter - m.notchHeight / 2) * min(max(p, 0), 1.05)
            return IslandContentLayout(
                iconCenter: IslandPoint(shape.left + m.cardPadding + m.cardIcon / 2, centerY),
                iconSize: lerp(14 * m.scale, m.cardIcon),
                ringCenter: IslandPoint(shape.right - m.cardPadding - m.cardRing / 2, centerY),
                ringSize: lerp(13 * m.scale, m.cardRing),
                textX: -m.cardWidth / 2 + m.cardTextX, textCenterY: rowCenter, compact: false)
        case .ears:
            let centerY = m.notchHeight / 2
            return IslandContentLayout(
                iconCenter: IslandPoint(shape.left + m.leftEar / 2, centerY), iconSize: m.earIcon,
                ringCenter: IslandPoint(0, centerY), ringSize: 0,
                textX: m.notchWidth / 2 + 12 * m.scale, textCenterY: centerY, compact: true)
        }
    }
}
