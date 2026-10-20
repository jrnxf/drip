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
    /// line is round at the ends however tall its fonts are; one with more lines keeps corners of 30
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
    /// The width the content is laid out for; nil for the open capsule's. It follows the capsule
    /// only while the island springs from one card's size to the next.
    public var contentWidth: Double?

    public init(
        pillTop: Double, pillWidth: Double, pillHeight: Double, progress: Double, blend: Double = 0,
        contentWidth: Double? = nil
    ) {
        self.pillTop = pillTop
        self.pillWidth = pillWidth
        self.pillHeight = pillHeight
        self.progress = progress
        self.blend = blend
        self.contentWidth = contentWidth
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
    /// How wide the text may show, from `textX` to just short of the ring: the text column the
    /// content is laid out for.
    public var textRoom: Double
}

/// When each part of the content fades, in seconds after the shape starts moving.
public struct IslandCues: Equatable, Sendable {
    /// The icon and the countdown ring, or the button, at the capsule's two ends.
    public var sides: Double
    /// One cue for each line of the title, and of the detail.
    public var title: [Double]
    public var detail: [Double]
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

/// How a card at the notch turns into the card that replaces it in place, one with the same id: the
/// island springs to the new card's size, what changed crossfades, and a new state's colour settles
/// over the old with the icon popping as it lands.
public enum IslandUpdate {
    /// The capsule's size, its top held still, and the content riding its ends.
    public static let resize = Spring(duration: 0.4, bounce: 0.1)
    /// Text and parts that changed: the old fade out quicker than the new fade in, and both start at
    /// once, so the new text is never later than when the island was simply rebuilt (0.18 s).
    public static let fadeOut = 0.10
    public static let fadeIn = 0.18
    /// A new state's icon and ring colour settling over the old one's.
    public static let settle = 0.24
    /// The new state's icon lands from this scale, on `pop`.
    public static let popScale = 0.86
    public static let pop = Spring(duration: 0.4, bounce: 0.35)
    /// The countdown ring refilling from where it was before it drains again.
    public static let refill = 0.24
    /// With motion reduced, the size changes at once and every change crossfades this long.
    public static let reducedFade = 0.15
    /// The soft edge at the end of the text column, so text the capsule is still growing to hold
    /// fades out short of the ring instead of running under it, in points at regular size.
    public static let textEdge = 8.0

    /// Whether `new` shows a different state than `old`: another icon or another colour.
    public static func changesState(from old: Card, to new: Card) -> Bool {
        old.icon != new.icon || old.color != new.color
    }

    /// For each line of the new card, title lines first, whether it shows the same text in the same
    /// place as the old card's line, and so stays while the others change. Lines only keep their
    /// places when the title and the detail wrap to as many lines as before.
    public static func unchanged(
        oldTitle: [String], oldDetail: [String], newTitle: [String], newDetail: [String]
    ) -> [Bool] {
        guard oldTitle.count == newTitle.count, oldDetail.count == newDetail.count else {
            return Array(repeating: false, count: newTitle.count + newDetail.count)
        }
        return zip(oldTitle + oldDetail, newTitle + newDetail).map { $0 == $1 }
    }
}

/// Moves the island through its entrance and exit with springs: a drop forms under the notch, breaks
/// free on a neck and spreads into a capsule below the menu bar, then is pulled back up into the notch.
public struct IslandAnimator: Sendable {
    /// The card's sizes; a card replaced in place hands over to the new card's.
    public private(set) var metrics: IslandMetrics
    /// What the drop forms inside: the notch, or the capsule of the card above it in a stack.
    public let anchor: DropletAnchor?
    /// When the drop, gathered round on the way out, starts to rise; nil before `exit`.
    public private(set) var riseTime: Double?
    private var dropCenter, pillWidth, pillHeight, progress, blend: SpringValue
    /// The width the content is laid out for: the open capsule's, until a resize springs it along
    /// with the capsule.
    private var contentWidth: SpringValue

    /// The drop waits deep inside the notch, too deep to make it bulge, or in the middle of the
    /// capsule `anchor`, which is shallower than the notch.
    public init(metrics: IslandMetrics, anchor: DropletAnchor? = nil) {
        self.metrics = metrics
        self.anchor = anchor
        dropCenter = SpringValue(anchor?.centerY ?? metrics.dropTop + metrics.dropSize / 2)
        pillWidth = SpringValue(metrics.seedSize)
        pillHeight = SpringValue(metrics.seedSize)
        progress = SpringValue(0)
        blend = SpringValue(metrics.blend)
        contentWidth = SpringValue(metrics.pillWidth)
    }

    /// Starts the entrance at `time` and returns when the content fades in. The capsule settles with
    /// its top at `top`, below the notch unless given.
    public mutating func enter(at time: Double, top: Double? = nil) -> IslandCues {
        let m = metrics
        let anchorBottom = anchor?.bottom ?? m.notchHeight
        // The drop swells under the notch, stretches into a neck as it falls, and pinches off; only
        // then does it spread into the capsule, while the notch pulls its half of the neck back in.
        let fall = Spring(duration: 0.62, bounce: 0.2)
        let center = (top ?? m.pillTop) + m.pillHeight / 2
        dropCenter.animate(to: center, with: fall, at: time)
        // The notch feeds the drop as it hangs, so the bulb outgrows its neck.
        let feed = Spring(duration: 0.3)
        pillWidth.animate(to: m.dropSize, with: feed, at: time)
        pillHeight.animate(to: m.dropSize, with: feed, at: time)
        let start = dropCenter.value(at: time)
        let detached = Self.firstTime(after: time) { t in
            start + (center - start) * fall.progress(at: t - time) - m.dropSize / 2
                >= anchorBottom + m.blend / 3
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
            sides: roomy, title: IslandCues.lines(m.titleLines, from: roomy, step: step),
            detail: IslandCues.lines(
                m.detailLines, from: roomy + 0.04 + Double(max(m.titleLines - 1, 0)) * step, step: step))
    }

    /// Starts the exit at `time`, faster than the entrance and without bounce, back into the notch,
    /// or into the capsule above it when given that capsule's `anchor`. Returns when the content
    /// fades out.
    public mutating func exit(at time: Double, into anchor: DropletAnchor? = nil) -> IslandCues {
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
        // notch's bulge goes flat as quickly as liquid would. A capsule above is shallower than the
        // notch, so the drop aims for just under its top, where it still hides whole.
        let swallowed = anchor.map { $0.centerY - $0.halfHeight + m.dropSize / 2 + 2 * m.scale }
            ?? m.dropTop + m.dropSize / 2 - m.dropSize
        riseTime = rise
        dropCenter.animate(to: swallowed, with: Spring(duration: 0.4), at: rise)
        return IslandCues(
            sides: 0, title: IslandCues.lines(m.titleLines, from: 0, step: 0),
            detail: IslandCues.lines(m.detailLines, from: 0, step: 0))
    }

    /// Moves the open capsule so its top is at `top`, starting at `time`: a card in a stack closing
    /// the gap one above it left, or making room for a new one.
    public mutating func move(to top: Double, at time: Double, with spring: Spring = IslandAnimator.settle) {
        dropCenter.animate(to: top + metrics.pillHeight / 2, with: spring, at: time)
    }

    /// How a card in a stack glides into a gap.
    public static let settle = Spring(duration: 0.45, bounce: 0.12)
    /// How cards in a stack get out of the way of a new one: quick, so the new drop can follow
    /// almost at once, and without bounce, so they never swing back towards it.
    public static let makeRoom = Spring(duration: 0.32)

    /// Springs the open capsule from its card's size to `metrics`, a new card's, starting at `time`,
    /// with its top where it is heading. The icon and the ring ride the capsule's ends, and the text
    /// column widens or narrows with it.
    public mutating func resize(to metrics: IslandMetrics, at time: Double, with spring: Spring = IslandUpdate.resize) {
        let top = targetTop
        self.metrics = metrics
        // The center moves half as far as the bottom, on the same spring, so the top holds still.
        dropCenter.animate(to: top + metrics.pillHeight / 2, with: spring, at: time)
        pillWidth.animate(to: metrics.pillWidth, with: spring, at: time)
        pillHeight.animate(to: metrics.pillHeight, with: spring, at: time)
        contentWidth.animate(to: metrics.pillWidth, with: spring, at: time)
    }

    /// Where the capsule's top is heading.
    public var targetTop: Double { dropCenter.target - metrics.pillHeight / 2 }

    /// Jumps straight to fully open, for reduced motion and offscreen rendering, with the capsule's
    /// top at `top`, below the notch unless given.
    public mutating func open(top: Double? = nil) {
        let m = metrics
        dropCenter.jump(to: (top ?? m.pillTop) + m.pillHeight / 2)
        pillWidth.jump(to: m.pillWidth)
        pillHeight.jump(to: m.pillHeight)
        blend.jump(to: 0)
        progress.jump(to: 1)
        contentWidth.jump(to: m.pillWidth)
    }

    /// When every spring has settled.
    public var end: Double {
        [dropCenter, pillWidth, pillHeight, progress, blend, contentWidth].compactMap(\.end).max() ?? 0
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
            blend: max(blend.value(at: time), 0), contentWidth: contentWidth.value(at: time))
    }

    /// The first time from `start`, in 1 ms steps and within 2 s, at which `condition` holds.
    private static func firstTime(after start: Double, where condition: (Double) -> Bool) -> Double {
        var time = start
        while time < start + 2, !condition(time) { time += 0.001 }
        return time
    }

    public func content(for shape: IslandShape) -> IslandContentLayout {
        content(for: shape, metrics: metrics)
    }

    /// Where the content of a card of `metrics` sits in `shape`: the card being replaced, while it
    /// fades out of the island springing to the new card's size.
    public func content(for shape: IslandShape, metrics m: IslandMetrics) -> IslandContentLayout {
        // Everything sits where the open capsule puts it, and the growing capsule reveals it. While
        // the capsule springs to a new card's size, the content follows its ends.
        let width = shape.contentWidth ?? m.pillWidth
        let left = -width / 2, right = width / 2
        let centerY = shape.pillTop + shape.pillHeight / 2
        return IslandContentLayout(
            iconCenter: IslandPoint(left + m.pillPadding + m.pillIcon / 2, centerY), iconSize: m.pillIcon,
            ringCenter: IslandPoint(right - m.pillPadding - m.pillRing / 2, centerY), ringSize: m.pillRing,
            textX: left + m.pillTextX, textCenterY: centerY,
            textRoom: width - m.pillTextX - m.pillGap - m.pillRing - m.pillPadding)
    }
}
