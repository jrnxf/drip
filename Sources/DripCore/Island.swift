#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif

// A card is drawn as one black shape that grows out of the camera notch. Coordinates here are in
// points with x = 0 at the notch's center and y growing down from the top of the screen.

/// Numbers every card shares.
public enum CardMetrics {
    /// The widest a card gets, in points.
    public static let maxWidth: Double = 640

    /// The width of a button labelled with text `labelWidth` wide: the label rounded up to a whole
    /// point, and room for the padding either side.
    public static func buttonWidth(labelWidth: Double, scale: Double) -> Double {
        labelWidth.rounded(.up) + 24 * scale
    }
}

/// The sizes an island is built from.
public struct IslandMetrics: Equatable, Sendable, Codable {
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
    /// The buttons' width, which takes the countdown ring's place; 0 without one. A question with a
    /// no button has both: the no button's width, `buttonGap` and the yes button's.
    public var actionWidth: Double
    /// The no button's width, at the left of `actionWidth`; 0 without one.
    public var declineWidth: Double
    /// The widest the capsule may get: `CardMetrics.maxWidth`, or less on a screen narrower than that.
    public var widestPill: Double
    /// The capsule's size when it holds no card, as the overflow drop's; nil for a card's, which fits
    /// its content.
    public var fixedPill: PillSize?

    /// A capsule's width and height, in points.
    public struct PillSize: Equatable, Sendable, Codable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public init(
        notchWidth: Double, notchHeight: Double, scale: Double = 1, textWidth: Double, textHeight: Double,
        titleLines: Int = 1, detailLines: Int = 1, hasIcon: Bool = true, actionWidth: Double = 0,
        declineWidth: Double = 0, widestPill: Double = CardMetrics.maxWidth, fixedPill: PillSize? = nil
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
        self.declineWidth = declineWidth
        self.widestPill = widestPill
        self.fixedPill = fixedPill
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
        if let fixedPill { return fixedPill.width }
        let width = pillTextX + textWidth + pillGap + pillRing + pillPadding
        return min(max(width, 200 * scale), widestPill)
    }
    public var pillHeight: Double { fixedPill?.height ?? 2 * 12 * scale + max(textHeight, pillIcon) }
    public var pillTop: Double { notchHeight + 12 * scale }
    /// The capsule's ends are round up to this radius. A capsule of one title line and one detail
    /// line is round at the ends however tall its fonts are; one with more lines keeps corners of 30
    /// points instead of swelling into a blob.
    public var pillCornerRadius: Double { titleLines > 1 || detailLines > 1 ? 30 * scale : .infinity }
    /// The space between a question's no and yes buttons.
    public var buttonGap: Double { Self.buttonGap * scale }
    /// The space between a question's no and yes buttons at regular size.
    public static let buttonGap = 6.0

    /// The width of a card's buttons, as `actionWidth` takes it: the yes button's alone, or the no
    /// button's, the gap and the yes button's.
    public static func buttonsWidth(yes: Double, no: Double?, scale: Double) -> Double {
        no.map { $0 + buttonGap * scale + yes } ?? yes
    }
    /// The widest a line of text may be: 500 points at regular size in the widest capsule, less when
    /// a button is too wide for both to fit in it. It does not depend on the text.
    public var textColumn: Double {
        let room = widestPill - pillTextX - pillGap - pillRing - pillPadding
        return min(widestPill - 140 * scale, room)
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

    /// Whether `point`, x from the notch's center and y down from the screen's top, is on the
    /// capsule as it is drawn, round corners and all, or within `margin` of it. Only there does the
    /// card take the pointer: a click beside it or under it goes to the window behind.
    public func contains(_ point: IslandPoint, metrics: IslandMetrics, margin: Double = 0) -> Bool {
        // How far past the capsule's straight edges the point is, outward; negative inside them.
        let dx = abs(point.x) - pillWidth / 2 - margin
        let dy = abs(point.y - pillTop - pillHeight / 2) - pillHeight / 2 - margin
        guard dx <= 0, dy <= 0 else { return false }
        // Within a corner's square, the point must be inside its quarter circle too.
        let radius = pillRadius(metrics) + margin
        let x = dx + radius, y = dy + radius
        return x <= 0 || y <= 0 || x * x + y * y <= radius * radius
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
public struct IslandCues: Equatable, Sendable, Codable {
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

    /// The waiting mark of a card that waits for you, which has no countdown: a white dot of `dot`
    /// points at regular size, under a soft white halo that starts as the dot and grows to
    /// `pingScale` times its size as it fades, from `pingOpacity`, over the first `pingSpread` of
    /// every `ping` seconds, easing out on `pingCurve`'s control points. With motion reduced, the dot
    /// shows alone.
    public static let dot = 8.0
    public static let ping = 2.4
    public static let pingScale = 2.1
    public static let pingOpacity = 0.4
    public static let pingSpread = 0.75
    public static let pingCurve = (0.0, 0.0, 0.2, 1.0)

    /// Whether `new` shows a different state than `old`: another icon or another colour.
    public static func changesState(from old: Card, to new: Card) -> Bool {
        old.icon != new.icon || old.color != new.color
    }

    /// Whether a new state lands in the ring rather than on the icon: the ring carries the state,
    /// and the icon, such as an agent's, stays as it was.
    public static func landsInRing(from old: Card, to new: Card) -> Bool {
        new.ringGlyph != nil && old.icon == new.icon
    }

    /// For each line of the new card, title lines first, whether it shows the same text in the same
    /// place as the old card's line, and so stays while the others change. Lines only keep their
    /// places when the title and the detail wrap to as many lines as before, in a block as tall, at
    /// the same size and as far from the capsule's left end, so with an icon or without one as before.
    public static func unchanged(
        oldTitle: [String], oldDetail: [String], newTitle: [String], newDetail: [String],
        from old: IslandMetrics, to new: IslandMetrics
    ) -> [Bool] {
        guard oldTitle.count == newTitle.count, oldDetail.count == newDetail.count,
              old.scale == new.scale, old.textHeight == new.textHeight, old.pillTextX == new.pillTextX
        else {
            return Array(repeating: false, count: newTitle.count + newDetail.count)
        }
        return zip(oldTitle + oldDetail, newTitle + newDetail).map { $0 == $1 }
    }
}

/// Moves the island through its entrance and exit with springs: a drop forms under the notch, breaks
/// free on a neck and spreads into a capsule below the menu bar, then is pulled back up into the notch.
public struct IslandAnimator: Equatable, Sendable, Codable {
    /// The card's sizes; a card replaced in place hands over to the new card's.
    public private(set) var metrics: IslandMetrics
    /// What the drop forms inside: the notch, or the capsule of the card above it in a stack.
    public let anchor: DropletAnchor?
    /// When the drop, gathered round on the way out, starts to rise; nil before `exit`.
    public private(set) var riseTime: Double?
    /// When the neck of the drop pinches off on the way in, or the neck of the overflow drop to the
    /// card that grows out of it; nil before `enter` or `join`.
    public private(set) var letsGo: Double?
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

    /// A drop that waits in the middle of the card `above` and goes wherever that card goes: it
    /// takes on the springs still moving that card, so the two move as one until the drop falls, and
    /// the fall is the same curve from a card that glides as from one at rest. `anchor` is that
    /// card's capsule where it is heading.
    public init(metrics: IslandMetrics, under above: IslandAnimator) {
        self.metrics = metrics
        anchor = above.resting
        dropCenter = above.dropCenter
        pillWidth = SpringValue(metrics.seedSize)
        pillHeight = SpringValue(metrics.seedSize)
        progress = SpringValue(0)
        blend = SpringValue(metrics.blend)
        contentWidth = SpringValue(metrics.pillWidth)
    }

    /// A drop that waits in the middle of `leaving`, a card on its way out, at `time`, whether that
    /// card still gathers in its place or its drop already rises: it takes on the springs moving
    /// that card at that moment, so it is where the card is, as fast as the card is. A spring planned
    /// for later, as the rise of a card that still gathers, is that card's alone. It starts apart,
    /// hidden whole inside that card, and melts into it as it starts to fall: see `enter`.
    /// `anchor` is that card's open capsule where those springs take it: its place, while it
    /// gathers there.
    public init(metrics: IslandMetrics, outOf leaving: IslandAnimator, at time: Double) {
        self.metrics = metrics
        dropCenter = leaving.dropCenter.running(at: time)
        anchor = .open(leaving.metrics, centerY: dropCenter.target)
        pillWidth = SpringValue(metrics.seedSize)
        pillHeight = SpringValue(metrics.seedSize)
        progress = SpringValue(0)
        blend = SpringValue(0)
        contentWidth = SpringValue(metrics.pillWidth)
    }

    /// The open capsule where it is heading, at its card's size: what a drop out of it hangs from
    /// and a drop into it aims at. A place, not a moment: whatever moves the capsule there moves
    /// the drop with it.
    public var resting: DropletAnchor { .open(metrics, centerY: dropCenter.target) }

    /// The same animator on a clock that reads `offset` more at every moment: every spring and
    /// every moment it keeps is that much later, so it draws the same shape at the same moment on
    /// the other clock. A stack handed on to another drip goes on from its springs this way.
    public func shifted(by offset: Double) -> IslandAnimator {
        var animator = self
        animator.riseTime = riseTime.map { $0 + offset }
        animator.letsGo = letsGo.map { $0 + offset }
        animator.dropCenter = dropCenter.shifted(by: offset)
        animator.pillWidth = pillWidth.shifted(by: offset)
        animator.pillHeight = pillHeight.shifted(by: offset)
        animator.progress = progress.shifted(by: offset)
        animator.blend = blend.shifted(by: offset)
        animator.contentWidth = contentWidth.shifted(by: offset)
        return animator
    }

    /// Starts the entrance at `time` and returns when the content fades in. The capsule settles with
    /// its top at `top`, below the notch unless given.
    ///
    /// A drop made with `init(metrics:outOf:at:)` starts apart, and melts in from `time` on
    /// `meltIn`. Out of a card that still gathers in its place it then falls as out of a card that
    /// stays: the neck pinches off at the same moment of the fall, or sooner by itself as that card
    /// draws back. `rising` is for a drop out of a drop that already rises, with `host` the card
    /// that drop goes into, nil for the notch. The new drop is drawn against both, and the first
    /// moves away as it falls. So its neck pinches off where it is drawn a third of the blend below
    /// both, and not at a moment of the fall: out of a drop far from its host that is soon, and out
    /// of one that is nearly in, it is as out of the host itself.
    public mutating func enter(
        at time: Double, top: Double? = nil, outOf rising: IslandAnimator? = nil, into host: IslandAnimator? = nil
    ) -> IslandCues {
        let m = metrics
        let anchorBottom = anchor?.bottom ?? m.notchHeight
        // The drop swells under the notch, stretches into a neck as it falls, and pinches off; only
        // then does it spread into the capsule, while the notch pulls its half of the neck back in.
        let fall = Spring(duration: 0.62, bounce: 0.2)
        let center = (top ?? m.pillTop) + m.pillHeight / 2
        // The notch feeds the drop as it hangs, so the bulb outgrows its neck.
        let feed = Spring(duration: 0.3)
        pillWidth.animate(to: m.dropSize, with: feed, at: time)
        pillHeight.animate(to: m.dropSize, with: feed, at: time)
        // From where the drop waits to where it lands, both as places: a card that still glides
        // carries the drop it lets fall, so the neck pinches off at the same moment of the fall.
        let start = dropCenter.target
        dropCenter.animate(to: center, with: fall, at: time)
        // A drop that starts apart melts in before it shows.
        if blend.target < m.blend { blend.animate(to: m.blend, with: Self.meltIn, at: time) }
        let detached: Double
        if let rising {
            let drop = self
            detached = Self.firstTime(after: time) { t in
                let above = rising.shape(at: t), into = host?.shape(at: t)
                let floor = max(above.pillTop + above.pillHeight, into.map { $0.pillTop + $0.pillHeight } ?? m.notchHeight)
                return drop.shape(at: t).pillTop >= floor + m.blend / 3
            }
        } else {
            detached = Self.firstTime(after: time) { t in
                start + (center - start) * fall.progress(at: t - time) - m.dropSize / 2
                    >= anchorBottom + m.blend / 3
            }
        }
        letsGo = detached
        blend.animate(to: 0, with: Spring(duration: 0.35), at: detached)
        let grow = Self.grow
        pillWidth.animate(to: m.pillWidth, with: grow, at: detached)
        pillHeight.animate(to: m.pillHeight, with: grow, at: detached)
        progress.animate(to: 1, with: grow, at: detached)
        return cues(spreading: grow, from: detached, start: time)
    }

    /// How a drop out of a card on its way out melts into it: full before the drop shows.
    public static let meltIn = Spring(duration: 0.08)

    /// How a drop spreads into its capsule once it has broken free.
    public static let grow = Spring(duration: 0.5, bounce: 0.15)

    /// How far open a capsule is when its text starts to fade in.
    public static let textOpen = 0.8

    /// When the content fades in, in seconds after `start`, for a capsule spreading on `grow` from
    /// `spread`: text waits until the capsule is `open` of the way open, wide enough to hold it,
    /// then fades in line by line, the detail a little after the title.
    private func cues(spreading grow: Spring, from spread: Double, start: Double, open: Double = textOpen) -> IslandCues {
        let m = metrics
        let roomy = Self.firstTime(after: spread) { grow.progress(at: $0 - spread) >= open } - start
        let step = IslandCues.lineStagger
        return IslandCues(
            sides: roomy, title: IslandCues.lines(m.titleLines, from: roomy, step: step),
            detail: IslandCues.lines(
                m.detailLines, from: roomy + 0.04 + Double(max(m.titleLines - 1, 0)) * step, step: step))
    }

    /// A card that starts as `drop`, the overflow drop it grows out of, unopened: it takes the
    /// springs that move the drop, and those of the neck the drop still has to the card above it.
    /// So it is where the drop is, as large, as fast and as melted, whatever the drop is doing, and
    /// what `spread` adds starts from rest.
    public init(metrics: IslandMetrics, from drop: IslandAnimator) {
        self.metrics = metrics
        anchor = nil
        dropCenter = drop.dropCenter
        pillWidth = drop.pillWidth
        pillHeight = drop.pillHeight
        progress = SpringValue(0)
        blend = drop.blend
        letsGo = drop.letsGo
        contentWidth = SpringValue(metrics.pillWidth)
    }

    /// Spreads the drop, from wherever its springs are, into the open capsule of `metrics` with its
    /// top at `top`, starting at `time`, as a card's drop spreads once it has broken free: a card
    /// growing out of the overflow drop, or the overflow drop itself turning into the last card that
    /// waited. Returns when the content fades in.
    /// `textAt` is how far open the capsule is when its text starts to fade in.
    public mutating func spread(
        into metrics: IslandMetrics, top: Double, at time: Double, with grow: Spring = IslandAnimator.grow,
        textAt open: Double = IslandAnimator.textOpen
    ) -> IslandCues {
        self.metrics = metrics
        contentWidth.jump(to: metrics.pillWidth)
        dropCenter.animate(to: top + metrics.pillHeight / 2, with: grow, at: time)
        pillWidth.animate(to: metrics.pillWidth, with: grow, at: time)
        pillHeight.animate(to: metrics.pillHeight, with: grow, at: time)
        progress.animate(to: 1, with: grow, at: time)
        return cues(spreading: grow, from: time, start: time, open: open)
    }

    /// Swells the open capsule by `amount` points each way from `time`, and lets it settle back, on
    /// `IslandUpdate.pop`: the overflow drop taking a card in, or giving a little as one leaves it
    /// when `amount` is negative.
    public mutating func swell(by amount: Double, at time: Double) {
        let pop = IslandUpdate.pop
        pillWidth.animate(to: metrics.pillWidth + amount, with: pop, at: time)
        pillHeight.animate(to: metrics.pillHeight + amount, with: pop, at: time)
        pillWidth.animate(to: metrics.pillWidth, with: pop, at: time + 0.06)
        pillHeight.animate(to: metrics.pillHeight, with: pop, at: time + 0.06)
    }

    /// Melts the drop into the card that grows out of it from `time`, and lets go of it 0.12 s
    /// later: the overflow drop stays joined to that card until the neck between them pinches off.
    /// That neck starts from nothing. The one the drop had before went with the card, which starts
    /// as the drop: see `init(metrics:from:)`.
    public mutating func join(at time: Double) {
        blend = SpringValue(0)
        melt(from: time)
    }

    /// For a card that starts as the overflow drop inside the card that grew out of it before:
    /// keeps the neck it took from the drop, as it is at `time`, for as long as a new one. The
    /// two are one shape until they part, however long ago the drop joined that card. What the
    /// neck had planned for later goes, and what this adds starts from rest.
    public mutating func rejoin(at time: Double) {
        blend = blend.running(at: time)
        melt(from: time)
    }

    /// Melts in full from `time`, and lets go 0.12 s later.
    private mutating func melt(from time: Double) {
        letsGo = time + 0.12
        blend.animate(to: metrics.blend, with: Spring(duration: 0.1), at: time)
        blend.animate(to: 0, with: Spring(duration: 0.35), at: time + 0.12)
    }

    /// Starts the exit at `time`, faster than the entrance and without bounce, back into the notch,
    /// or into the capsule above it when given that capsule's `anchor`. Returns when the content
    /// fades out.
    public mutating func exit(at time: Double, into anchor: DropletAnchor? = nil) -> IslandCues {
        let m = metrics
        // The capsule gathers back into a round drop, which only then rises; the notch reaches for it,
        // they merge and the notch swallows it.
        let shrink = Self.gather
        let gather = time + Self.gatherDelay
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
        dropCenter.animate(to: swallowed, with: Self.rise, at: rise)
        return exitCues
    }

    /// When the content fades out on the exit, in seconds after it starts: all of it at once.
    public var exitCues: IslandCues {
        IslandCues(
            sides: 0, title: IslandCues.lines(metrics.titleLines, from: 0, step: 0),
            detail: IslandCues.lines(metrics.detailLines, from: 0, step: 0))
    }

    /// How a card on its way out gathers into a round drop, and how long after its exit starts.
    public static let gather = Spring(duration: 0.22)
    public static let gatherDelay = 0.03
    /// How the gathered drop rises into what swallows it.
    public static let rise = Spring(duration: 0.4)

    /// Springs `change` further than wherever the capsule's middle is heading, from `time`: what
    /// moves the card it hangs from, or the card it goes into, moves it too.
    public mutating func shift(by change: Double, at time: Double, with spring: Spring) {
        dropCenter.shift(by: change, with: spring, at: time)
    }

    /// Where the capsule's middle is heading.
    public var targetCenter: Double { dropCenter.target }

    /// Lets the melt go from `time`, as fast as a drop rises, or from when this drop starts to rise
    /// if that is later: a drop that goes into another drop becomes one with it, and two round
    /// drops in one place have nothing left to bridge.
    public mutating func merge(at time: Double) {
        blend.animate(to: 0, with: Self.rise, at: max(time, riseTime ?? time))
    }

    /// Whether the drop still melts into what it hangs from or goes into at `time`.
    public func melts(at time: Double) -> Bool {
        // A drop on its way in hangs until its neck pinches off, however little it melts yet.
        blend.value(at: time) > 0.01 || (letsGo.map { time < $0 } ?? false)
    }

    /// Moves the open capsule so its top is at `top`, starting at `time`: a card in a stack closing
    /// the gap one above it left, or making room for a new one.
    public mutating func move(to top: Double, at time: Double, with spring: Spring = IslandAnimator.settle) {
        dropCenter.animate(to: top + metrics.pillHeight / 2, with: spring, at: time)
    }

    /// How a card in a stack glides into a gap.
    public static let settle = Spring(duration: 0.45, bounce: 0.12)

    /// Springs the open capsule from its card's size to `metrics`, a new card's, starting at `time`,
    /// with its top where it is heading. The icon and the ring ride the capsule's ends, and the text
    /// column widens or narrows with it. Returns when these springs have settled.
    @discardableResult
    public mutating func resize(
        to metrics: IslandMetrics, at time: Double, with spring: Spring = IslandUpdate.resize
    ) -> Double {
        let top = targetTop
        self.metrics = metrics
        // The center moves half as far as the bottom, on the same spring, so the top holds still.
        dropCenter.animate(to: top + metrics.pillHeight / 2, with: spring, at: time)
        pillWidth.animate(to: metrics.pillWidth, with: spring, at: time)
        pillHeight.animate(to: metrics.pillHeight, with: spring, at: time)
        contentWidth.animate(to: metrics.pillWidth, with: spring, at: time)
        return time + spring.settlingTime
    }

    /// Where the capsule's top is heading.
    public var targetTop: Double { dropCenter.target - metrics.pillHeight / 2 }

    /// The springs still moving the capsule's top towards `targetTop` at `time`.
    public func glide(at time: Double) -> [SpringMotion] {
        dropCenter.motion(at: time)
    }

    /// Goes on with `glide`, as `glide(at:)` gave it, from `time`, towards the top `top`.
    public mutating func resume(_ glide: [SpringMotion], to top: Double, at time: Double) {
        dropCenter.resume(glide, to: top + metrics.pillHeight / 2, at: time)
    }

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
        letsGo = nil
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
