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
    /// How many lines the title and the detail wrapped to; 0 detail lines for a card without one.
    public var titleLines: Int
    public var detailLines: Int
    public var hasIcon: Bool
    /// A button's width, which takes the countdown ring's place; 0 without one.
    public var actionWidth: Double

    public init(
        notchWidth: Double, notchHeight: Double, scale: Double = 1, textWidth: Double, textHeight: Double,
        titleLines: Int = 1, detailLines: Int = 1, hasIcon: Bool = true, actionWidth: Double = 0
    ) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.scale = scale
        self.textWidth = textWidth
        self.textHeight = textHeight
        self.titleLines = titleLines
        self.detailLines = detailLines
        self.hasIcon = hasIcon
        self.actionWidth = actionWidth
    }

    /// The notch's own bottom corners.
    public var notchRadius: Double { min(10, notchHeight / 3) }

    // The free-floating capsule.
    var pillIcon: Double { hasIcon ? 24 * scale : 0 }
    var pillRing: Double { actionWidth > 0 ? actionWidth : 20 * scale }
    var pillPadding: Double { 14 * scale }
    var pillGap: Double { 10 * scale }
    var pillTextX: Double { pillPadding + (hasIcon ? pillIcon + pillGap : 0) }
    public var pillWidth: Double {
        let width = pillTextX + textWidth + pillGap + pillRing + pillPadding
        return min(max(width, 200 * scale), Double(CardMetrics.maxWidth))
    }
    public var pillHeight: Double { 2 * 12 * scale + max(textHeight, pillIcon) }
    public var pillTop: Double { notchHeight + 12 * scale }
    /// The capsule's ends are round up to this radius. A capsule of one title line and one detail
    /// line is round at the ends however tall its fonts are; one of more lines keeps corners of 30
    /// points instead of swelling into a blob.
    public var pillCornerRadius: Double { titleLines > 1 || detailLines > 1 ? 30 * scale : .infinity }
    /// The widest a line of text may be: 500 points at regular size, less when a button is too wide
    /// for both to fit in the widest capsule. It does not depend on the text.
    public var textColumn: Double {
        let room = Double(CardMetrics.maxWidth) - pillTextX - pillGap - pillRing - pillPadding
        return min(Double(CardMetrics.maxWidth) - 140 * scale, room)
    }
    /// The round drop the capsule starts and ends as.
    public var dropSize: Double { 26 * scale }
    /// The drop's size when it starts to form, before the notch has fed it.
    public var seedSize: Double { 12 * scale }
    /// How far apart the drop and the notch still pull on each other: the smooth union's radius.
    /// The neck between them pinches off at a third of this gap.
    public var blend: Double { 24 * scale }
    /// The drop's top while it waits inside the notch, too deep to make the notch bulge.
    public var dropTop: Double { notchHeight - blend - dropSize }

    /// The widest the island gets, for sizing its window.
    public var maxWidth: Double { max(pillWidth, notchWidth) }

    /// The tallest the island gets, overshoot included.
    public var maxHeight: Double { pillTop + pillHeight + 16 * scale }
}

/// The island at one instant: the notch, and the drop that grows into the capsule below it.
public struct IslandShape: Equatable, Sendable {
    public var pillTop: Double
    public var pillWidth: Double
    public var pillHeight: Double
    /// 0 at rest, 1 fully open. Drives the content's size and place.
    public var progress: Double
    /// How strongly the drop and the notch melt together; 0 keeps them apart.
    public var blend: Double

    public init(pillTop: Double, pillWidth: Double, pillHeight: Double, progress: Double, blend: Double = 0) {
        self.pillTop = pillTop
        self.pillWidth = pillWidth
        self.pillHeight = pillHeight
        self.progress = progress
        self.blend = blend
    }

    /// The drop's corner radius: fully round until it reaches the capsule's corners.
    public func pillRadius(_ metrics: IslandMetrics) -> Double {
        min(pillWidth / 2, pillHeight / 2, metrics.pillCornerRadius)
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
}

/// When each part of the content fades, in seconds after the shape starts moving.
public struct IslandCues: Equatable, Sendable {
    public var icon: Double
    public var ring: Double
    /// One cue for each line of the title, and of the detail.
    public var title: [Double]
    public var detail: [Double]
    /// How long the icon takes to fade out on the exit; the other parts take `fadeOut`.
    public var iconFadeOut = IslandCues.fadeOut

    /// How long a part takes to fade out on the exit.
    public static let fadeOut = 0.12
    /// On the entrance, each wrapped line fades in this long after the line above it.
    public static let lineStagger = 0.03

    /// How visible a part cued at `cue` is `time` seconds into the exit, fading linearly over `duration`.
    public static func opacity(leaving cue: Double, over duration: Double = fadeOut, at time: Double) -> Double {
        guard duration > 0 else { return time < cue ? 1 : 0 }
        return 1 - min(max((time - cue) / duration, 0), 1)
    }

    /// `count` cues from `first`, one `step` apart.
    static func lines(_ count: Int, from first: Double, step: Double) -> [Double] {
        (0..<max(count, 0)).map { first + Double($0) * step }
    }
}

/// Moves the island through its entrance and exit with springs: a drop forms under the notch, breaks
/// free on a neck and spreads into a capsule below the menu bar, then is pulled back up into the notch.
public struct IslandAnimator: Sendable {
    public let metrics: IslandMetrics
    private var dropCenter, pillWidth, pillHeight, progress, blend: SpringValue

    public init(metrics: IslandMetrics) {
        self.metrics = metrics
        dropCenter = SpringValue(metrics.dropTop + metrics.dropSize / 2)
        pillWidth = SpringValue(metrics.seedSize)
        pillHeight = SpringValue(metrics.seedSize)
        progress = SpringValue(0)
        blend = SpringValue(metrics.blend)
    }

    /// Starts the entrance at `time` and returns when the content fades in.
    public mutating func enter(at time: Double) -> IslandCues {
        let m = metrics
        // The drop swells under the notch, stretches into a neck as it falls, and pinches off; only
        // then does it spread into the capsule, while the notch pulls its half of the neck back in.
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
        // Text waits until the capsule is wide enough to hold it, then fades in line by line, the
        // detail a little after the title.
        let roomy = Self.firstTime(after: detached) { grow.progress(at: $0 - detached) >= 0.8 } - time
        let step = IslandCues.lineStagger
        return IslandCues(
            icon: detached - time, ring: roomy, title: IslandCues.lines(m.titleLines, from: roomy, step: step),
            detail: IslandCues.lines(
                m.detailLines, from: roomy + 0.04 + Double(max(m.titleLines - 1, 0)) * step, step: step))
    }

    /// Starts the exit at `time`, faster than the entrance and without bounce, back into the notch.
    /// Returns when the content fades out.
    public mutating func exit(at time: Double) -> IslandCues {
        let m = metrics
        // The capsule gathers back into a round drop, which only then rises; the notch reaches for it,
        // they merge and the notch swallows it.
        let shrink = Spring(duration: 0.22)
        let gather = time + 0.03
        pillWidth.animate(to: m.dropSize, with: shrink, at: gather)
        pillHeight.animate(to: m.dropSize, with: shrink, at: gather)
        progress.animate(to: 0, with: shrink, at: gather)
        // Round to the eye once both sides are within 2 points of the drop's.
        let (width, tall) = (pillWidth, pillHeight)
        let rise = Self.firstTime(after: gather) { t in
            max(abs(width.value(at: t) - m.dropSize), abs(tall.value(at: t) - m.dropSize)) <= 2 * m.scale
        }
        blend.animate(to: m.blend, with: Spring(duration: 0.3), at: rise)
        // Aimed past its resting place, so it is swallowed at speed instead of easing in, and the
        // notch's bulge goes flat as quickly as liquid would.
        dropCenter.animate(to: m.dropTop + m.dropSize / 2 - m.dropSize, with: Spring(duration: 0.4), at: rise)
        // The icon stays until the round drop starts to rise and is gone before it melts into the
        // notch, which happens when the gap closes to a third of the blend. That moment is found to
        // the millisecond, so the fade ends the millisecond before.
        let merged = Self.firstTime(after: rise) { t in
            let shape = self.shape(at: t)
            return shape.pillTop < m.notchHeight + shape.blend / 3
        }
        return IslandCues(
            icon: rise - time, ring: 0, title: IslandCues.lines(m.titleLines, from: 0, step: 0),
            detail: IslandCues.lines(m.detailLines, from: 0, step: 0), iconFadeOut: max(merged - 0.001 - rise, 0.01))
    }

    /// Jumps straight to fully open, for reduced motion and offscreen rendering.
    public mutating func open() {
        let m = metrics
        dropCenter.jump(to: m.pillTop + m.pillHeight / 2)
        pillWidth.jump(to: m.pillWidth)
        pillHeight.jump(to: m.pillHeight)
        blend.jump(to: 0)
        progress.jump(to: 1)
    }

    /// When every spring has settled.
    public var end: Double {
        [dropCenter, pillWidth, pillHeight, progress, blend].compactMap(\.end).max() ?? 0
    }

    public func shape(at time: Double) -> IslandShape {
        var width = pillWidth.value(at: time), tall = pillHeight.value(at: time)
        let opened = progress.value(at: time)
        // A moving drop stretches along its path and keeps its area; the capsule stays rigid.
        let step = 1.0 / 240
        let speed = abs(dropCenter.value(at: time + step) - dropCenter.value(at: time - step)) / (2 * step)
        let stretch = 1 + min(speed / (3000 * metrics.scale), 0.07) * max(1 - opened, 0)
        tall *= stretch
        width /= stretch
        let center = dropCenter.value(at: time)
        return IslandShape(
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
        // The ring and text sit where the open capsule puts them and the growing capsule reveals them;
        // only the icon travels, from the middle of the drop to its place.
        let left = -m.pillWidth / 2, right = m.pillWidth / 2
        let centerY = shape.pillTop + shape.pillHeight / 2
        return IslandContentLayout(
            iconCenter: IslandPoint(lerp(0, left + m.pillPadding + m.pillIcon / 2), centerY),
            iconSize: lerp(16 * m.scale, m.pillIcon),
            ringCenter: IslandPoint(right - m.pillPadding - m.pillRing / 2, centerY), ringSize: m.pillRing,
            textX: left + m.pillTextX, textCenterY: centerY)
    }
}
