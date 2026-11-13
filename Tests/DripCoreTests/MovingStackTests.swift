@testable import DripCore // to read each card's place and the moment its countdown starts
#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif
import Testing

/// Which moments a sweep flies. A sweep moves one moment against another in steps of one frame and
/// flies the stack once for each.
///
/// - The full sweep flies every frame of the range. CI runs it, with `DRIP_FULL_SWEEP=1`.
/// - A plain `swift test` flies every `step`th frame, and every frame within `margin` of each
///   critical line: a moment where what the stack decides changes, as a drop starting to fall, its
///   neck letting go, or a drop starting to rise.
/// - Under WebAssembly, which CI's `wasm` job runs, it flies every sixteenth frame only.
///
/// Either way a sweep is cut into `parts`, each a test case of its own, so the parts run side by
/// side. The first flight of each part is checked from its first frame. The others are checked from
/// a moment before anything in them differs from that one: up to there the frames are the same.
enum Sweep {
    static let full = ProcessInfo.processInfo.environment["DRIP_FULL_SWEEP"] == "1"
    #if os(WASI)
    // One thread, and slower: every sixteenth frame, enough to tell that the engine still flies.
    static let step = 16
    static let margin = -1
    #else
    static let step = 5
    static let margin = 2
    #endif
    static let parts = [0, 1, 2, 3]

    /// The offsets of `range` that part `part` flies, with every frame near each of `lines`. All
    /// parts when `part` is nil.
    static func offsets(_ range: ClosedRange<Int>, near lines: [Int] = [], part: Int? = nil) -> [Int] {
        let flown = range.filter { offset in
            full || (offset - range.lowerBound) % step == 0 || lines.contains { abs(offset - $0) <= margin }
        }
        guard let part else { return flown }
        return flown.enumerated().filter { $0.offset % parts.count == part }.map(\.element)
    }

    /// Calls `fly` for each offset part `part` flies, with whether to check the flight from its
    /// first frame.
    static func fly(
        _ range: ClosedRange<Int>, near lines: [Int] = [], part: Int? = nil, _ fly: (Int, Bool) throws -> Void
    ) rethrows {
        for (index, offset) in offsets(range, near: lines, part: part).enumerated() { try fly(offset, index == 0) }
    }
}

/// A number cut to so many places, for messages. WebAssembly has no `String(format:)`.
private func fixed(_ value: Double, _ places: Int) -> String {
    let scale = (0..<places).reduce(1.0) { scale, _ in scale * 10 }
    return "\((value * scale).rounded() / scale)"
}

/// A stack flown frame by frame at 120 Hz, as a drawing runs one, with every rule of a moving stack
/// checked on every frame. What breaks a rule is kept in `issues`.
///
/// The rules:
/// - A change never rewrites the past or the present: every shape is where it was, as fast as it
///   was, up to the moment the change starts. Springs start from rest, so that is all it takes for
///   every place and size to be continuous, and every velocity too.
/// - No shape jumps from one frame to the next.
/// - A drop that hangs from a card moves against it the way it would against a card at rest,
///   wherever the card goes, and its neck is short enough to hold.
/// - A drop that rises aims at where its card is heading now, never at where it was, and when it is
///   taken away it is hidden inside it.
/// - Two cards that stay never touch, and no card that stays runs into a drop above it.
/// - A neck changes hands only when there is no neck.
/// - Nothing shows up, is taken away or changes hands in view: whenever a card or a drop comes,
///   goes, or melts into another card than before, the picture as it is drawn is the same at that
///   moment with the change as without it.
/// - A card that drops out of a card on its way out starts hidden whole inside it, where it is and
///   as fast as it is. Out of a drop that rises, the two are drawn as one piece until the neck lets
///   go. It never touches a drop it does not hang from.
/// - A card chosen to grow out of the overflow drop is the drop until it starts: where the drop
///   is, as large, and as fast.
///
/// Frames in which nothing moves and nothing changes are flown and not checked: every shape is
/// where the frame before had it.
final class Flight {
    static let frame = 1.0 / 120

    let stack: CardStack
    let lead: Double
    let metrics: (Card) -> IslandMetrics
    private(set) var time = 0.0
    private var steps = 0
    /// What to do before the step at or after each time.
    var script: [(time: Double, act: (Flight) -> Void)] = []
    /// Whether no card grows out of the overflow drop for now.
    var holdsReleases = false
    /// How long each step takes, in frames, by its number: a drawing that drops frames or catches
    /// up. One frame each unless set.
    var pacing: (Int) -> Double = { _ in 1 }
    private var elapsed = Flight.frame
    /// Cards of another drip, each due at a moment: it drops in as soon as the stack takes it.
    var late: [(due: Double, card: Card)] = []
    /// Each of them that came in: when it was due, when the stack took it, and the card it dropped
    /// out of, with whether that card was on its way out.
    private(set) var arrived: [(title: String, due: Double, decided: Double, from: String?, fromLeaving: Bool)] = []
    /// Frames before this moment are flown and not checked.
    var watchFrom = -Double.infinity
    private var moved = true
    /// When every spring settles, as of the last step that changed anything.
    private var settles = Double.infinity

    /// Each card that left: when it started to leave, when its time was up, whether it was taken
    /// away on purpose, how many cards started to leave at that moment, whether the pointer was
    /// on the stack, and when its drop starts to rise.
    private(set) var left: [(title: String, time: Double, due: Double, taken: Bool, together: Int, hovering: Bool, rise: Double)] = []
    /// Each card that grew out of the overflow drop: the step that chose it, when it starts, and
    /// whether it was the last card waiting, which the drop itself spreads into.
    private(set) var released: [(title: String, decided: Double, start: Double, last: Bool)] = []
    /// Each overflow drop: the step it formed on, when its neck to the card it formed out of lets
    /// go, and that card.
    private(set) var drops: [(formed: Double, letsGo: Double, holder: String?)] = []
    private var drop: ObjectIdentifier?
    /// Each card that came in: when it was decided and when its drop starts.
    private(set) var entered: [(title: String, decided: Double, start: Double)] = []
    private(set) var gone: [(title: String, time: Double)] = []
    /// Every shape on every frame, to tell two flights apart.
    private(set) var frames: [Double] = []
    private(set) var issues: [String] = []
    /// The longest any card stood still over one frame, for a flight's own checks.
    private(set) var closestGap = Double.infinity

    private var before: [Int: IslandAnimator] = [:]
    private var dropBefore: IslandAnimator?
    /// The stack as it was drawn before this step, and who melted into whom.
    private var outlineBefore = StackOutline(cards: [])
    private var joinsBefore: [Int] = []
    private var last: [Int: IslandShape] = [:]
    private var anchors: [Int: Int?] = [:]
    /// Each card that dropped out of another, as the two were when it started.
    private var hangs: [Int: (drop: IslandAnimator, card: IslandAnimator, from: Int, metrics: IslandMetrics)] = [:]
    private var dues: [Int: Double] = [:]
    /// The cards that dropped out of a drop that already rose.
    private var outOfRising: Set<Int> = []

    init(_ stack: CardStack, lead: Double = 0, metrics: @escaping (Card) -> IslandMetrics) {
        self.stack = stack
        self.lead = lead
        self.metrics = metrics
    }

    func entry(_ title: String) -> CardStack.Entry? {
        stack.entries.first { $0.card.title == title }
    }

    private func fail(_ message: String) {
        if issues.count < 12 { issues.append("\(fixed(time, 4)): " + message) }
    }

    /// Grows this drip's next card out of the overflow drop, when one may. Returns whether one
    /// came out.
    private func release() -> Bool {
        guard !holdsReleases, stack.canRelease(at: time, starting: time + lead), let card = stack.nextOwn() else { return false }
        guard let release = stack.release(card, metrics: metrics(card), own: true, decided: time, at: time + lead) else { return false }
        if case let .entering(start, _) = release.entry.phase {
            entered.append((card.title, time, start))
            released.append((card.title, time, start, release.last))
        }
        return true
    }

    /// Whether nothing more can happen before `end`: every card shows at rest with time to spare,
    /// and none is still to come or go.
    private func isOver(before end: Double) -> Bool {
        guard script.isEmpty, late.isEmpty, !stack.hovering, settles < time - 0.5 else { return false }
        guard stack.entries.allSatisfy({ $0.isShown && $0.dismissed == nil && $0.remaining > end - time + 1 }) else { return false }
        return stack.waiting.isEmpty || (!stack.hasRoom && stack.overflow?.phase == .shown)
    }

    /// Flies the stack until `end`, or until nothing more can happen before `end`.
    func run(until end: Double, each: (Flight, CardStack.Changes) -> Void = { _, _ in }) {
        while time < end, !isOver(before: end) {
            while let index = script.firstIndex(where: { $0.time <= time + 1e-9 }) {
                let item = script.remove(at: index)
                item.act(self)
            }
            let watched = time >= watchFrom
            if watched {
                before = Dictionary(uniqueKeysWithValues: stack.entries.map { ($0.id, $0.animator) })
                dropBefore = stack.overflow?.animator
                outlineBefore = stack.outline
                joinsBefore = joins()
            }
            let came = entered.count
            if stack.isReady(at: time, starting: time + lead), stack.overflow == nil, stack.hasRoom, let card = stack.nextOwn() {
                let entry = stack.enter(card, metrics: metrics(card), own: true, decided: time, at: time + lead)
                entered.append((card.title, time, time + lead))
                if let above = entry.anchor { hangs[entry.id] = (entry.animator, above.animator, above.id, above.metrics) }
                checkBirth(of: entry)
            } else if stack.isReady(at: time, starting: time + lead), stack.overflow == nil, stack.hasRoom, stack.waiting.isEmpty,
                      let index = late.firstIndex(where: { $0.due <= time + 1e-9 })
            {
                let (due, card) = late.remove(at: index)
                let entry = stack.enter(card, metrics: metrics(card), own: false, decided: time, at: time + lead)
                entered.append((card.title, time, time + lead))
                arrived.append((card.title, due, time, entry.anchor?.card.title, entry.anchor?.isLeaving ?? false))
                if let above = entry.anchor { hangs[entry.id] = (entry.animator, above.animator, above.id, above.metrics) }
                checkBirth(of: entry)
            }
            while release() {}
            let hovering = stack.hovering
            let changes = stack.advance(to: time, lead: lead, queued: [])
            for item in changes.left {
                let due = item.entry.countdownFrom + item.entry.card.duration
                let together = changes.left.filter { $0.time == item.time }.count
                left.append((
                    item.entry.card.title, item.time, dues[item.entry.id] ?? due, item.entry.dismissed != nil, together,
                    hovering, item.entry.animator.riseTime ?? item.time))
            }
            for entry in changes.gone { gone.append((entry.card.title, time)) }
            if let overflow = stack.overflow, ObjectIdentifier(overflow) != drop {
                drops.append((time, overflow.letsGo, overflow.holder?.card.title))
            }
            drop = stack.overflow.map { ObjectIdentifier($0) }
            // Nothing moves in a stack at rest: the frame before said all there is to say.
            let changed = !changes.isEmpty || entered.count != came
            if changed || !settles.isFinite { settles = stack.end }
            let moves = changed || settles >= time - Self.frame
            if watched, moves || moved { check(changes) }
            moved = moves
            each(self, changes)
            steps += 1
            let step = pacing(steps)
            var next = time + step * Self.frame
            // On the grid of whole frames, as ever.
            if step == 1, time == Double(steps - 1) * Self.frame { next = Double(steps) * Self.frame }
            elapsed = next - time
            time = next
        }
    }

    /// Says when the time of the card `title` is up after something moved its countdown, as the
    /// pointer does.
    func expectDue(_ title: String, at due: Double) {
        if let entry = entry(title) { dues[entry.id] = due }
    }

    private func middle(_ shape: IslandShape) -> Double { shape.pillTop + shape.pillHeight / 2 }

    /// Which cards and drops there are and what each melts into, as numbers that change when any of
    /// that does.
    private func joins() -> [Int] {
        var joins = stack.entries.flatMap { [$0.id, $0.anchor?.id ?? 0] }
        if let overflow = stack.overflow {
            joins += [-1, overflow.anchor?.id ?? 0, overflow.isLeaving ? 1 : 0] + overflow.seeds.map(\.source)
        }
        return joins
    }

    /// Whether each point down the line `x` points from the notch's middle is inside the picture a
    /// drawing fills from `outline` at `time`: the notch, each card melted into what it hangs from,
    /// the overflow drop and what drips into it. One point every half point, from the screen's top.
    /// The notch is `notch`, which is there with no card too.
    static func column(_ outline: StackOutline, notch: IslandMetrics?, at time: Double, x: Double) -> [Bool] {
        var filled = [Bool](repeating: false, count: 1300)
        // Each piece is asked only about the points it can reach.
        func fill(from top: Double, to bottom: Double, where inside: (Double) -> Bool) {
            let first = Swift.max(Int((top * 2).rounded(.up)), 0), last = Swift.min(Int((bottom * 2).rounded(.down)), filled.count - 1)
            guard first <= last else { return }
            for index in first...last where !filled[index] && inside(Double(index) / 2) { filled[index] = true }
        }
        func box(_ y: Double, _ centerY: Double, _ halfWidth: Double, _ halfHeight: Double, _ radius: Double) -> Bool {
            DropletField.roundedBox(
                x: x, y: y, centerX: 0, centerY: centerY, halfWidth: halfWidth, halfHeight: halfHeight, radius: radius) < 0
        }
        if let notch = notch.map({ DropletAnchor.notch($0) }) {
            fill(from: 0, to: notch.bottom) { box($0, notch.centerY, notch.halfWidth, notch.halfHeight, notch.radius) }
        }
        for piece in outline.pieces(at: time) + outline.overflowPieces(at: time) {
            switch piece {
            case let .traced(field):
                // A melt swells a shape by less than its blend.
                let bottoms = [field.anchor.bottom, field.shape.pillTop + field.shape.pillHeight] + field.hosts.map(\.anchor.bottom)
                fill(from: field.traceTop, to: (bottoms.max() ?? 0) + field.shape.blend + 1) { field.value(x: x, y: $0) < 0 }
            case let .capsule(shape, metrics):
                let radius = shape.pillRadius(metrics)
                fill(from: shape.pillTop, to: shape.pillTop + shape.pillHeight) {
                    box($0, shape.pillTop + shape.pillHeight / 2, shape.pillWidth / 2, shape.pillHeight / 2, radius)
                }
            }
        }
        return filled
    }

    /// The longest run of points down a line that are inside one picture and outside the other, in
    /// points.
    static func difference(_ a: [Bool], _ b: [Bool]) -> Double {
        if a == b { return 0 }
        var longest = 0, run = 0
        for (a, b) in zip(a, b) {
            run = a == b ? 0 : run + 1
            longest = max(longest, run)
        }
        return Double(longest) / 2
    }

    /// A drop starts in the middle of the card it drops out of, hidden whole inside it, and as
    /// fast as it: a frame later the two have hardly parted.
    private func checkBirth(of entry: CardStack.Entry) {
        guard let above = entry.anchor else { return }
        let start = time + lead
        if above.isLeaving, !stack.holdsPlace(above) || (above.animator.riseTime ?? .infinity) <= start { outOfRising.insert(entry.id) }
        let drop = entry.animator.shape(at: start), card = above.animator.shape(at: start)
        if abs(middle(drop) - middle(card)) > 1e-9 {
            fail("\(entry.card.title) starts \(middle(drop) - middle(card)) off the middle of \(above.card.title)")
        }
        if drop.pillTop < card.pillTop || drop.pillTop + drop.pillHeight > card.pillTop + card.pillHeight || drop.pillWidth > card.pillWidth {
            fail("\(entry.card.title) starts in view: \(drop) in \(card)")
        }
        let later = start + Self.frame
        let parted = (middle(entry.animator.shape(at: later)) - middle(above.animator.shape(at: later)))
        if abs(parted) > 1 { fail("\(entry.card.title) starts \(parted * 120) points a second faster than \(above.card.title)") }
    }

    private func check(_ changes: CardStack.Changes) {
        let now = time
        let entries = stack.entries
        let shapes = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.animator.shape(at: now)) })

        // A change never rewrites the past or the present.
        var moments = [now - Self.frame, now]
        if lead > 0 { moments.append(now + lead * 0.999) }
        for entry in entries + changes.gone {
            guard let was = before[entry.id], was != entry.animator else { continue }
            for moment in moments {
                let old = was.shape(at: moment), new = entry.animator.shape(at: moment)
                if abs(middle(old) - middle(new)) > 1e-9 || abs(old.pillWidth * old.pillHeight - new.pillWidth * new.pillHeight) > 1e-6
                    || abs(old.blend - new.blend) > 1e-9 || abs(old.progress - new.progress) > 1e-9
                {
                    fail("\(entry.card.title) was rewritten at \(moment): \(old) became \(new)")
                }
            }
        }
        if let was = dropBefore, let overflow = stack.overflow, !changes.overflowChanged || overflow.animator.metrics == was.metrics {
            for moment in moments {
                let old = was.shape(at: moment), new = overflow.animator.shape(at: moment)
                // The drop that spreads into the last card waiting is taken over by that card.
                if abs(middle(old) - middle(new)) > 1e-9 || abs(old.pillWidth * old.pillHeight - new.pillWidth * new.pillHeight) > 1e-6 {
                    fail("the overflow drop was rewritten at \(moment)")
                }
            }
        }

        // Nothing shows up, is taken away or changes hands in view.
        if joins() != joinsBefore {
            let after = stack.outline
            var moments = [now]
            if lead > 0 { moments.append(now + lead * 0.999) }
            for moment in moments {
                for x in [0.0, 10] {
                    let notch = after.notch ?? outlineBefore.notch
                    let change = Self.difference(
                        Self.column(outlineBefore, notch: notch, at: moment, x: x),
                        Self.column(after, notch: notch, at: moment, x: x))
                    if change > 1 {
                        fail("the picture changed by \(change) points at once, \(x) from the middle, at \(moment): \(joinsBefore) to \(joins())")
                    }
                }
            }
        }

        // No shape jumps from one frame to the next: nothing here moves faster than this, for each
        // frame a step takes.
        for entry in entries {
            guard let was = last[entry.id], let shape = shapes[entry.id] else { continue }
            let span = Swift.max(elapsed / Self.frame, 1)
            if abs(middle(shape) - middle(was)) > 45 * span || abs(shape.pillWidth - was.pillWidth) > 45 * span
                || abs(shape.pillHeight - was.pillHeight) > 12 * span || abs(shape.blend - was.blend) > 6 * span
            {
                fail("\(entry.card.title) jumped: \(was) to \(shape)")
            }
        }

        for (index, entry) in entries.enumerated() {
            guard let shape = shapes[entry.id] else { continue }
            let m = entry.metrics
            frames += [now, Double(entry.id), shape.pillTop, shape.pillWidth, shape.pillHeight, shape.blend]

            if !entry.isLeaving {
                // A drop that hangs from a card goes where the card goes.
                if let hang = hangs[entry.id], !entry.isShown, shape.blend >= m.blend - 1e-9,
                   let card = entries.first(where: { $0.id == hang.from }), let above = shapes[card.id]
                {
                    if !card.isLeaving, card.metrics == hang.metrics {
                        let planned = middle(hang.drop.shape(at: now)) - middle(hang.card.shape(at: now))
                        if abs(middle(shape) - middle(above) - planned) > 1e-6 {
                            fail("\(entry.card.title) left the card it hangs from: \(middle(shape) - middle(above)) for \(planned)")
                        }
                        if shape.pillTop - (above.pillTop + above.pillHeight) > m.blend / 3 + 0.75 {
                            fail("\(entry.card.title) hangs \(shape.pillTop - (above.pillTop + above.pillHeight)) below its card")
                        }
                    }
                    if entry.anchor !== card { fail("\(entry.card.title) melts into another card than it hangs from") }
                }
                // A neck changes hands only when there is no neck.
                if let was = anchors[entry.id], was != entry.anchor?.id, entry.animator.melts(at: now) {
                    fail("\(entry.card.title) changed the card it melts into with its neck still there")
                }
                // A drop out of a drop that rises is one piece with it until its neck lets go.
                if outOfRising.contains(entry.id), case let .entering(start, _) = entry.phase, now >= start,
                   let letsGo = entry.animator.letsGo, now < letsGo - Self.frame
                {
                    let from = entry.anchor.flatMap { shapes[$0.id] }.map(middle) ?? m.notchHeight - 1
                    let filled = Self.column(stack.outline, notch: m, at: now, x: 0)
                    let range = Int((Swift.max(from, 0) * 2).rounded(.up))..<Int((Swift.max(middle(shape), from, 0) * 2).rounded(.up))
                    if let hole = range.first(where: { !filled[$0] }) {
                        fail("\(entry.card.title) came off \(entry.anchor?.card.title ?? "the notch") before its neck let go: a gap at \(Double(hole) / 2)")
                    }
                }
                // Two cards that stay never touch, once the lower one's neck has let go.
                if !entry.animator.melts(at: now), let upper = entries[..<index].last(where: { !$0.isLeaving }),
                   let above = shapes[upper.id]
                {
                    let gap = shape.pillTop - (above.pillTop + above.pillHeight)
                    closestGap = min(closestGap, gap)
                    if gap <= 0 { fail("\(entry.card.title) overlaps \(upper.card.title) by \(-gap)") }
                }
            } else {
                // A drop that rises aims at where its card is heading now.
                let aim: Double
                if let anchor = entry.anchor {
                    let resting = anchor.animator.resting
                    aim = anchor.isLeaving
                        ? anchor.animator.targetCenter
                        : resting.centerY - resting.halfHeight + m.dropSize / 2 + 2 * m.scale
                } else {
                    aim = m.dropTop + m.dropSize / 2 - m.dropSize
                }
                if abs(entry.animator.targetCenter - aim) > 1e-6 {
                    fail("\(entry.card.title) aims at \(entry.animator.targetCenter), and its card is heading for \(aim)")
                }
                // No card that stays runs into a drop above it.
                for below in entries[(index + 1)...] where !below.isLeaving && !below.animator.melts(at: now) {
                    guard let lower = shapes[below.id] else { continue }
                    let gap = lower.pillTop - (shape.pillTop + shape.pillHeight)
                    if gap <= 0 { fail("\(below.card.title) runs into \(entry.card.title), which is leaving, by \(-gap)") }
                }
                // A card that still hangs never touches a drop it does not hang from: no part of it
                // that shows outside the card it hangs from is on a part of that drop in view.
                let floor = stack.container(of: entry).flatMap { shapes[$0.id] }.map { $0.pillTop + $0.pillHeight } ?? m.notchHeight
                for below in entries[(index + 1)...] where !below.isLeaving && below.anchor !== entry && below.animator.melts(at: now) {
                    guard let lower = shapes[below.id] else { continue }
                    let own = below.anchor.flatMap { shapes[$0.id] }.map { $0.pillTop + $0.pillHeight } ?? m.notchHeight
                    let overlap = min(lower.pillTop + lower.pillHeight, shape.pillTop + shape.pillHeight) - max(lower.pillTop, shape.pillTop, own, floor)
                    if overlap > 0 { fail("\(below.card.title) touches \(entry.card.title), a drop it does not hang from, by \(overlap)") }
                }
            }
        }

        // What is taken away is hidden inside the card it ended up in, or inside the notch.
        for entry in changes.gone {
            let shape = entry.animator.shape(at: now)
            if let into = stack.container(of: entry) {
                let card = into.animator.shape(at: now)
                if shape.pillTop < card.pillTop - 0.5 || shape.pillTop + shape.pillHeight > card.pillTop + card.pillHeight + 0.5
                    || shape.pillWidth > card.pillWidth + 0.5
                {
                    fail("\(entry.card.title) was taken away while it showed: \(shape) in \(card)")
                }
            } else if shape.pillTop + shape.pillHeight > entry.metrics.notchHeight + 0.5 {
                fail("\(entry.card.title) was taken away below the notch: \(shape)")
            }
        }

        // A card chosen to grow out of the overflow drop is the drop until it starts.
        if let overflow = stack.overflow {
            for entry in entries where entry.outOfDrop {
                guard case let .entering(start, _) = entry.phase, now < start, let card = shapes[entry.id] else { continue }
                for moment in [now, (now + start) / 2] {
                    let drop = overflow.animator.shape(at: moment), card = moment == now ? card : entry.animator.shape(at: moment)
                    // A drop stretches along its path and keeps its area.
                    if abs(middle(drop) - middle(card)) > 1e-9 || abs(drop.pillWidth * drop.pillHeight - card.pillWidth * card.pillHeight) > 1e-6 {
                        fail("\(entry.card.title) shows before it starts to grow out of the drop: \(card) for \(drop)")
                    }
                }
            }
        }

        // A seed leaves the card where the card is, and lands where the drop is.
        if let overflow = stack.overflow {
            let drop = overflow.animator.shape(at: now)
            for seed in overflow.seeds where now >= seed.start && now < seed.end {
                if abs(seed.to.value(at: now) - middle(drop)) > 0.5 { fail("a seed lands \(seed.to.value(at: now) - middle(drop)) off the drop") }
                guard let source = entries.first(where: { $0.id == seed.source && $0.isShown }), let card = shapes[source.id] else { continue }
                let from = card.pillTop + card.pillHeight - 10 * overflow.metrics.scale
                if abs(seed.from.value(at: now) - from) > 0.5 { fail("a seed leaves \(seed.from.value(at: now) - from) off its card") }
            }
        }

        last = shapes
        anchors = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.anchor?.id) })
    }
}

/// The picture a drawing fills from a stack's outline, as one field, and its inside corners.
enum Picture {
    /// Negative inside the picture: inside any piece as it is drawn. A traced piece is drawn from
    /// its `traceTop` down and no wider than its drop and the blend, as the drawing traces it.
    static func value(_ pieces: [StackOutline.Piece], x: Double, y: Double) -> Double {
        pieces.reduce(Double.infinity) { least, piece in
            let (liquid, cut) = parts(piece, x: x, y: y)
            return min(least, max(liquid, cut))
        }
    }

    /// One piece at a point: its liquid, negative inside, and the cut the drawing makes around
    /// it, negative where the piece is drawn. A plain capsule has no cut.
    static func parts(_ piece: StackOutline.Piece, x: Double, y: Double) -> (liquid: Double, cut: Double) {
        switch piece {
        case let .traced(field):
            let reach = field.shape.pillWidth / 2 + field.shape.blend + 1
            return (field.value(x: x, y: y), max(field.traceTop + 0.5 - y, abs(x) - reach))
        case let .capsule(shape, metrics):
            return (DropletField.roundedBox(
                x: x, y: y, centerX: 0, centerY: shape.pillTop + shape.pillHeight / 2, halfWidth: shape.pillWidth / 2,
                halfHeight: shape.pillHeight / 2, radius: shape.pillRadius(metrics)), -.infinity)
        }
    }

    /// What breaks the outline of liquid at a point on it, apart from a tight curve.
    /// - `cut`: the outline here is no edge of liquid at all. It is where the drawing cuts a
    ///   piece off, and no other piece covers the cut.
    /// - `crossing`: two pieces both have their edge here and meet at this angle, in radians.
    ///   Zero where they run along each other, as a card and the drop drawn against it do.
    static func breaks(_ pieces: [StackOutline.Piece], x: Double, y: Double) -> (cut: Bool, crossing: Double) {
        // Which way each piece's edge faces, for the pieces whose own edge of liquid runs through
        // here, and whether any piece has its edge of liquid near here at all.
        var facing: [(x: Double, y: Double)] = []
        var liquid = false
        for piece in pieces {
            let here = parts(piece, x: x, y: y)
            guard here.cut < 0.3 else { continue }
            liquid = liquid || abs(here.liquid) < 0.3
            guard abs(here.liquid) < 0.08 else { continue }
            let dx = parts(piece, x: x + 0.05, y: y).liquid - parts(piece, x: x - 0.05, y: y).liquid
            let dy = parts(piece, x: x, y: y + 0.05).liquid - parts(piece, x: x, y: y - 0.05).liquid
            let length = (dx * dx + dy * dy).squareRoot()
            // Flat where a join is just breaking: the edge faces no way there.
            if length > 0.02 { facing.append((dx / length, dy / length)) }
        }
        var crossing = 0.0
        for (index, a) in facing.enumerated() {
            for b in facing[(index + 1)...] { crossing = max(crossing, acos(min(max(a.x * b.x + a.y * b.y, -1), 1))) }
        }
        return (!liquid, crossing)
    }

    /// How wide the picture is along the line `y`, within `reach` of the middle, in points.
    static func width(_ pieces: [StackOutline.Piece], y: Double, reach: Double) -> Double {
        Double(stride(from: -reach, through: reach, by: 0.5).filter { value(pieces, x: $0, y: y) < 0 }.count) / 2
    }

    /// The sharpest inside corner of the picture's outline in a box: its radius in points, and
    /// where it is. Infinite with no inside corner.
    ///
    /// The box is `left` to `right` of the middle. Every shape is the same on both sides of the
    /// middle, so a box from a little left of it sees every corner.
    ///
    /// The outline is traced on a grid of half a point, as the drawing traces it, and walked in
    /// steps of one point. The radius at a step is two points over the angle the outline turns
    /// through across that step and the next: the radius of the circle that turns as much over
    /// two points. A smooth curve gives its own radius. A square corner gives 1.3 points, however
    /// the steps fall on it. A turn counts as an inside corner when the picture is not on the
    /// inner side of it: liquid bulges out, and only a join turns in.
    ///
    /// Also how many points of the outline in the box are a cut that shows, and the widest angle
    /// at which two pieces cross on it: see `breaks`.
    static func sharpestInsideCorner(
        _ pieces: [StackOutline.Piece], left: Double, top: Double, right: Double, bottom: Double
    ) -> (radius: Double, x: Double, y: Double, cut: Int, crossing: Double) {
        // Only the pieces that reach into the box.
        let pieces = pieces.filter { piece in
            switch piece {
            case let .traced(field):
                let low = ([field.anchor.bottom, field.shape.pillTop + field.shape.pillHeight] + field.hosts.map(\.anchor.bottom)).max() ?? 0
                return field.traceTop < bottom && low + field.shape.blend > top
            case let .capsule(shape, _):
                return shape.pillTop < bottom && shape.pillTop + shape.pillHeight > top
            }
        }
        let cell = 0.5, coarse = 4
        let columns = (Int(((right - left) / cell).rounded(.up)) / coarse + 1) * coarse + 1
        let rows = (Int(((bottom - top) / cell).rounded(.up)) / coarse + 1) * coarse + 1
        var values = [Double](repeating: 1, count: columns * rows)
        // The field changes by no more than the distance between two points. So a point of a
        // coarse grid that is far from the outline tells the side of every point around it, and
        // only the points near the outline are asked.
        let reach = Double(coarse) * cell * 2.squareRoot() / 2 + 0.01
        for coarseRow in stride(from: 0, to: rows, by: coarse) {
            for coarseColumn in stride(from: 0, to: columns, by: coarse) {
                let far = value(pieces, x: left + Double(coarseColumn) * cell, y: top + Double(coarseRow) * cell)
                for row in max(coarseRow - coarse / 2, 1)..<min(coarseRow + coarse / 2 + (coarse % 2 == 0 ? 0 : 1), rows - 1) {
                    for column in max(coarseColumn - coarse / 2, 1)..<min(coarseColumn + coarse / 2 + (coarse % 2 == 0 ? 0 : 1), columns - 1) {
                        values[row * columns + column] = abs(far) > reach ? far
                            : value(pieces, x: left + Double(column) * cell, y: top + Double(row) * cell)
                    }
                }
            }
        }
        var worst = (radius: Double.infinity, x: 0.0, y: 0.0, cut: 0, crossing: 0.0)
        for loop in MarchingSquares.loops(values: values, columns: columns, rows: rows) {
            let points = loop.map { IslandPoint(left + $0.x * cell, top + $0.y * cell) }
            // One point every point along the loop.
            var steps: [IslandPoint] = []
            var carried = 0.0
            for index in points.indices {
                let a = points[index], b = points[(index + 1) % points.count]
                let length = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
                var at = 1 - carried
                while at <= length {
                    steps.append(IslandPoint(a.x + (b.x - a.x) * at / length, a.y + (b.y - a.y) * at / length))
                    at += 1
                }
                carried = (carried + length).truncatingRemainder(dividingBy: 1)
            }
            guard steps.count > 6 else { continue }
            let count = steps.count
            /// How far the outline turns at step `index`, in radians, and positive for an inside corner.
            func turn(_ index: Int) -> Double {
                let p = steps[(index + count - 1) % count], q = steps[index % count], r = steps[(index + 1) % count]
                let ax = q.x - p.x, ay = q.y - p.y, bx = r.x - q.x, by = r.y - q.y
                // The loop closes on a step of another length.
                guard abs((ax * ax + ay * ay).squareRoot() - 1) < 0.2, abs((bx * bx + by * by).squareRoot() - 1) < 0.2 else { return 0 }
                let angle = abs(atan2(ax * by - ay * bx, ax * bx + ay * by))
                let dx = (p.x + r.x) / 2 - q.x, dy = (p.y + r.y) / 2 - q.y, inner = (dx * dx + dy * dy).squareRoot()
                guard angle > 1e-3, inner > 0 else { return 0 }
                return value(pieces, x: q.x + dx / inner * 0.75, y: q.y + dy / inner * 0.75) > 0 ? angle : -angle
            }
            for index in 0..<count {
                let q = steps[index]
                // Not where the box itself cuts the picture.
                if q.x < left + 3 || q.x > right - 3 || q.y < top + 3 || q.y > bottom - 3 { continue }
                let broken = breaks(pieces, x: q.x, y: q.y)
                if broken.cut { worst.cut += 1 }
                worst.crossing = max(worst.crossing, broken.crossing)
                let turned = max(turn(index), 0) + max(turn(index + 1), 0)
                guard turned > 1e-3 else { continue }
                if 2 / turned < worst.radius { (worst.radius, worst.x, worst.y) = (2 / turned, q.x, q.y) }
            }
        }
        return worst
    }
}

/// Leaves in a moving stack: a card whose time is up leaves at once, while other cards still drop
/// in, glide or leave, and every drop stays on the card it belongs to.
struct MovingStackTests {
    private static let short = IslandMetrics(notchWidth: 185, notchHeight: 32, textWidth: 130, textHeight: 17, detailLines: 0)
    private static let tall = IslandMetrics(notchWidth: 185, notchHeight: 32, textWidth: 180, textHeight: 34)

    /// Cards of two sizes by turns, so drops of different cards gather for different times.
    private static func layout(_ card: Card) -> IslandMetrics {
        (card.title.unicodeScalars.first?.value ?? 0) % 2 == 0 ? tall : short
    }

    private static func card(_ title: String, seconds: Double = 60) -> Card {
        var card = Card(preset: .info, title: title)
        card.seconds = seconds
        return card
    }

    private static let titles = ["a", "b", "c", "d", "e", "f", "g", "h"]

    /// A flight of `count` cards whose times are up at `ends`, by title, on the stack's clock; the
    /// others show for `rest` seconds. A first flight of cards that all stay tells when each
    /// countdown starts.
    private static func flight(
        _ count: Int, max: Int = 6, delay: Double? = 0, lead: Double = 0, ends: [String: Double] = [:], rest: Double = 60,
        alike: Bool = false
    ) -> Flight {
        let titles = Array(titles.prefix(count))
        let settings = StackSettings(max: max, delay: delay)
        var seconds: [String: Double] = [:]
        if !ends.isEmpty {
            let starts = alike ? alikeCountdowns[count] ?? probe(count, max: max, delay: delay, lead: lead, alike: true)
                : countdowns(count, max: max, delay: delay, lead: lead)
            for (title, end) in ends {
                // Never sooner than a card can be read at all: its time is not up as it comes in.
                if let from = starts[title] { seconds[title] = Swift.max(end - from, 0.2) }
            }
        }
        return Flight(
            CardStack(settings: settings, cards: titles.map { card($0, seconds: seconds[$0] ?? rest) }), lead: lead,
            metrics: alike ? { _ in short } : layout)
    }

    /// When each card's countdown starts in a flight of `count` cards that all stay. The same cards
    /// always give the same frames, so the kinds of stack the sweeps fly are flown once, in `known`.
    private static func countdowns(_ count: Int, max: Int = 6, delay: Double? = 0, lead: Double = 0) -> [String: Double] {
        known[key(count, max, delay, lead)] ?? probe(count, max: max, delay: delay, lead: lead)
    }

    private static func key(_ count: Int, _ max: Int, _ delay: Double?, _ lead: Double) -> String {
        "\(count) \(max) \(delay.map { "\($0)" } ?? "-") \(lead)"
    }

    private static func probe(_ count: Int, max: Int, delay: Double?, lead: Double, alike: Bool = false) -> [String: Double] {
        let titles = Array(titles.prefix(count))
        let probe = Flight(
            CardStack(settings: StackSettings(max: max, delay: delay), cards: titles.map { card($0) }), lead: lead,
            metrics: alike ? { _ in short } : layout)
        probe.run(until: Double(count) * 1.2 + 1)
        var starts: [String: Double] = [:]
        for title in titles { starts[title] = probe.entry(title)?.countdownFrom }
        return starts
    }

    private static let known: [String: [String: Double]] = {
        let kinds: [(Int, Int, Double?, Double)] = [
            (1, 6, 0, 0), (2, 6, 0, 0), (3, 6, 0, 0), (4, 6, 0, 0), (5, 6, 0, 0), (5, 6, 0, 0.06), (3, 6, 0, 0.06),
            (3, 6, nil, 0), (4, 3, 0, 0), (5, 3, 0, 0), (6, 3, 0, 0), (6, 4, 0, 0),
        ]
        var known: [String: [String: Double]] = [:]
        for (count, max, delay, lead) in kinds { known[key(count, max, delay, lead)] = probe(count, max: max, delay: delay, lead: lead) }
        return known
    }()

    /// The same for cards that are all the same size, into a stack of three, by how many cards.
    private static let alikeCountdowns: [Int: [String: Double]] = Dictionary(
        uniqueKeysWithValues: [4, 5, 6].map { ($0, probe($0, max: 3, delay: 0, lead: 0, alike: true)) })

    /// When the drop of the card `title` starts in a flight of `count` cards that all stay, and how
    /// many frames later its neck lets go and its text has faded in.
    private static func entrance(of title: String, among count: Int, max: Int = 6, delay: Double? = 0) -> (start: Double, lines: [Int]) {
        let probe = flight(count, max: max, delay: delay)
        var moments: [Double] = []
        probe.run(until: Double(count) * 1.2 + 1) { flight, _ in
            guard moments.isEmpty, let entry = flight.entry(title), case let .entering(start, cues) = entry.phase else { return }
            moments = [start, entry.animator.letsGo ?? start, start + CardStack.entrance(cues)]
        }
        let start = probe.entered.first { $0.title == title }?.start ?? 0
        return (start, lines(moments, after: start))
    }

    /// How many frames after `base` each of `moments` falls.
    private static func lines(_ moments: [Double], after base: Double) -> [Int] {
        moments.map { Int((($0 - base) / Flight.frame).rounded()) }
    }

    /// About how many frames after a card's time is up its drop starts to rise, and has gone.
    private static let rise = 31, gone = 62

    /// `lines`, and the frames at which a drop that starts to rise meets one of them.
    private static func meeting(_ lines: [Int]) -> [Int] {
        lines + lines.map { $0 - rise }
    }

    /// The step the first overflow drop forms on in a flight of `count` cards that all stay, and
    /// how many frames later its neck lets go, its count has faded in and it is at rest.
    private static func forming(_ count: Int, max: Int, alike: Bool = false) -> (start: Double, lines: [Int]) {
        let probe = flight(count, max: max, alike: alike)
        var moments: [Double] = []
        probe.run(until: Double(max) * 1.2 + 3) { flight, _ in
            guard moments.isEmpty, let overflow = flight.stack.overflow, case let .forming(start, cues) = overflow.phase else { return }
            moments = [start, overflow.letsGo, start + CardStack.countCue(cues), start + cues.sides + 0.25, overflow.end]
        }
        let start = probe.drops.first?.formed ?? 0
        return (start, lines(moments, after: start))
    }

    /// How long each card that ran out of time stayed with an empty ring, at most.
    private static func longestWait(_ flight: Flight, alone: Bool) -> Double {
        flight.left.filter { !$0.taken && ($0.together == 1) == alone }.map { $0.time - $0.due }.max() ?? 0
    }

    private static func expectClean(_ flight: Flight, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(flight.issues.isEmpty, "\(label): \(flight.issues.joined(separator: "\n"))", sourceLocation: sourceLocation)
        let early = flight.left.filter { !$0.taken && $0.time < $0.due - 1e-9 }
        #expect(early.isEmpty, "\(label): left before its ring was empty: \(early)", sourceLocation: sourceLocation)
        // A card alone leaves at the moment its time is up. Neighbours leave together, at the
        // moment the time of the last of them is up.
        let alone = longestWait(flight, alone: true), together = longestWait(flight, alone: false)
        #expect(alone < 1e-9, "\(label): a card waited \(alone) s with an empty ring", sourceLocation: sourceLocation)
        #expect(together <= CardStack.roundWindow + 1e-9, "\(label): a round waited \(together) s", sourceLocation: sourceLocation)
    }

    /// The blocks that leave: at the top, in the middle, at the bottom, and the whole stack.
    static let blocks: [[String]] = [["a"], ["a", "b"], ["b", "c"], ["c"], ["d"], ["c", "d"], ["a", "b", "c", "d"], ["a", "c"]]

    /// The block's time is up as a fifth card comes in, in steps of one frame from before its drop
    /// starts until after it has settled: above it, in the middle, and the very card it drops out of.
    @Test(arguments: blocks, Sweep.parts) func aBlockLeavesAsACardDropsIn(block: [String], part: Int) {
        let (start, lines) = Self.entrance(of: "e", among: 5)
        Sweep.fly(-40...130, near: Self.meeting(lines), part: part) { offset, whole in
            let end = start + Double(offset) * Flight.frame
            let flight = Self.flight(5, ends: Dictionary(uniqueKeysWithValues: block.map { ($0, end) }))
            if !whole { flight.watchFrom = min(end, start) - 0.3 }
            flight.run(until: end + 2.2)
            Self.expectClean(flight, "\(block) \(offset) frames after e starts")
            #expect(Set(flight.left.map(\.title)) == Set(block))
            #expect(Set(flight.stack.live.map(\.card.title)) == Set(["a", "b", "c", "d", "e"]).subtracting(block))
            #expect(flight.stack.live.allSatisfy { $0.isShown })
        }
    }

    /// The same with the changes starting a moment after they are decided, as the Mac app plans
    /// them: every leave still starts at the moment the ring is empty.
    @Test(arguments: [["a"], ["b", "c"], ["d"]]) func aBlockLeavesOnTimeWithALead(block: [String]) {
        let lead = 0.06
        let probe = Self.flight(5, lead: lead)
        probe.run(until: 7)
        let start = probe.entered.first { $0.title == "e" }?.start ?? 0
        for offset in stride(from: -40, through: 130, by: 3) {
            let end = start + Double(offset) * Flight.frame + 0.003
            let flight = Self.flight(5, lead: lead, ends: Dictionary(uniqueKeysWithValues: block.map { ($0, end) }))
            if offset > -40 { flight.watchFrom = min(end, start) - 0.3 }
            flight.run(until: end + 2.2)
            Self.expectClean(flight, "\(block) \(offset) frames after e starts, with a lead")
            #expect(Set(flight.left.map(\.title)) == Set(block))
        }
    }

    /// A card clicked away while the next card still hangs from it: the neck stays that card's
    /// until it pinches off, and the new card lands in the place the stack closes up to.
    @Test func theCardADropHangsFromIsTakenAway() {
        let (start, lines) = Self.entrance(of: "c", among: 3)
        Sweep.fly(0...60, near: lines) { offset, whole in
            let flight = Self.flight(3)
            flight.script = [(start + Double(offset) * Flight.frame, { $0.entry("b")?.dismissed = false })]
            if !whole { flight.watchFrom = start - 0.3 }
            flight.run(until: start + 3)
            Self.expectClean(flight, "b clicked \(offset) frames after c starts")
            #expect(flight.stack.live.map(\.card.title) == ["a", "c"])
            let c = flight.entry("c")
            #expect(c?.anchor === flight.entry("a"))
            #expect(abs((c?.animator.shape(at: flight.time).pillTop ?? 0) - (Self.short.pillTop + Self.short.pillHeight + CardStack.gap)) < 0.01)
        }
    }

    /// A card whose time is up while a drop is on its way into it leaves at once: the drop goes into
    /// the drop that card gathers into, and the two rise as one. In steps of one frame, from the two
    /// in one round to the first drop long gone, and three deep.
    @Test(arguments: Sweep.parts) func aCardLeavesWhileADropGoesIntoIt(part: Int) {
        Sweep.fly(1...110, near: [4, Self.rise, Self.gone], part: part) { offset, whole in
            let later = Double(offset) * Flight.frame
            let flight = Self.flight(4, ends: ["c": 8, "b": 8 + later])
            if !whole { flight.watchFrom = 7.7 }
            flight.run(until: 11)
            Self.expectClean(flight, "b \(offset) frames after c")
            #expect(flight.stack.live.map(\.card.title) == ["a", "d"])
            let three = Self.flight(5, ends: ["d": 8, "c": 8 + later, "b": 8 + 2 * later])
            if !whole { three.watchFrom = 7.7 }
            three.run(until: 12)
            Self.expectClean(three, "c \(offset) frames after d, and b after c")
            #expect(three.stack.live.map(\.card.title) == ["a", "e"])
        }
    }

    /// The same by clicks, which no round holds back: the card above goes one frame after the one
    /// below, and later, and the last of three goes into the notch.
    @Test func cardsClickedAwayOneAfterAnotherRiseAsOne() {
        Sweep.fly(1...70, near: [Self.rise, Self.gone]) { offset, whole in
            let later = Double(offset) * Flight.frame
            let flight = Self.flight(4)
            flight.script = [
                (6, { $0.entry("d")?.dismissed = false }), (6 + later, { $0.entry("c")?.dismissed = false }),
                (6 + 2 * later, { $0.entry("b")?.dismissed = false }), (6 + 3 * later, { $0.entry("a")?.dismissed = false }),
            ]
            if !whole { flight.watchFrom = 5.7 }
            flight.run(until: 9)
            Self.expectClean(flight, "clicks \(offset) frames apart")
            #expect(flight.stack.entries.isEmpty)
            #expect(flight.left.map(\.title) == ["d", "c", "b", "a"])
        }
    }

    /// A card leaves while the stack still closes up behind one that left before it: it gathers as
    /// it glides, and rises into the card above wherever that card is by then.
    @Test(arguments: [["c"], ["d"], ["c", "d"], ["b"]], Sweep.parts) func aCardLeavesWhileTheStackClosesUp(block: [String], part: Int) {
        Sweep.fly(1...110, near: [4, Self.rise, Self.gone, Self.rise + 54], part: part) { offset, whole in
            let later = Double(offset) * Flight.frame
            var ends = ["a": 8.0]
            for title in block { ends[title] = 8 + later }
            let flight = Self.flight(5, ends: ends)
            if !whole { flight.watchFrom = 7.7 }
            flight.run(until: 11.5)
            Self.expectClean(flight, "\(block) \(offset) frames after a")
            #expect(flight.left.count == 1 + block.count)
            #expect(flight.stack.live.allSatisfy { $0.isShown && abs($0.animator.shape(at: flight.time).pillTop - $0.top) < 0.01 })
        }
    }

    // MARK: The overflow drop

    /// Expects no card to have waited in the overflow drop of `flight` once it had a place: each
    /// card that grew out of the drop started within a frame of the moment it was due. The first
    /// is due as the first drop of the cards leaving starts to rise, the second with the second,
    /// and none before the drop has let go of the card it formed out of, unless that card rose.
    /// Returns the longest any card started after its place was free.
    @discardableResult
    private static func expectNoWaitInTheDrop(
        _ flight: Flight, _ label: String, sourceLocation: SourceLocation = #_sourceLocation
    ) -> Double {
        guard let drop = flight.drops.first else {
            #expect(flight.released.isEmpty, "\(label)", sourceLocation: sourceLocation)
            return 0
        }
        let rises = flight.left.map(\.rise).sorted()
        #expect(flight.released.count <= rises.count, "\(label)", sourceLocation: sourceLocation)
        let holder = flight.left.first { $0.title == drop.holder }?.rise ?? .infinity
        var longest = 0.0
        for (release, rise) in zip(flight.released, rises) {
            let due = max(rise, min(drop.letsGo, holder))
            #expect(
                release.start >= due - 1e-9 && release.start < due + Flight.frame + 1e-9,
                "\(label): \(release.title) started \(release.start - due) s after it was due", sourceLocation: sourceLocation)
            // Chosen on the step that reaches that moment, never ahead of it.
            #expect(release.start - release.decided < Flight.frame + 1e-9, "\(label)", sourceLocation: sourceLocation)
            longest = max(longest, release.start - rise)
        }
        return longest
    }

    /// Expects every card of `flight` that stays to show at rest in its place, top to bottom.
    private static func expectAtRest(_ flight: Flight, _ titles: [String], _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(flight.stack.entries.map(\.card.title) == titles, "\(label)", sourceLocation: sourceLocation)
        var top: Double?
        for entry in flight.stack.entries {
            let place = top ?? entry.metrics.pillTop
            let shape = entry.animator.shape(at: flight.time)
            #expect(
                entry.isShown && abs(shape.pillTop - place) < 0.01 && abs(shape.pillHeight - entry.metrics.pillHeight) < 0.01
                    && abs(shape.pillWidth - entry.metrics.pillWidth) < 0.01 && shape.blend < 0.01,
                "\(label): \(entry.card.title) is not at rest in its place", sourceLocation: sourceLocation)
            top = place + entry.metrics.pillHeight + CardStack.gap
        }
    }

    /// The blocks that leave a full stack of three: one, two and three cards, with and without the
    /// card the overflow drop forms out of.
    static let fullBlocks: [[String]] = [["a"], ["c"], ["a", "b"], ["b", "c"], ["a", "b", "c"]]

    /// A full stack of three with one or two cards waiting in the overflow drop. A block's time is
    /// up while the drop forms, in steps of one frame from before it starts to form until it has
    /// long been at rest. The cards waiting come out as their places are free: the first as the
    /// first drop starts to rise, the second with the second. None waits for the drop to be at
    /// rest, and none for the card before it. The one hold is the drop's neck: see
    /// `CardStack.releaseMoment`.
    @Test(arguments: fullBlocks.flatMap { block in [1, 2].map { (block, $0) } }, Sweep.parts)
    func cardsLeaveWhileTheDropForms(_ kind: ([String], Int), part: Int) {
        let (block, waiting) = kind
        let (start, lines) = Self.forming(3 + waiting, max: 3)
        let all = Array(Self.titles.prefix(3 + waiting))
        Sweep.fly(-20...140, near: Self.meeting(lines), part: part) { offset, whole in
            let end = start + Double(offset) * Flight.frame
            let flight = Self.flight(3 + waiting, max: 3, ends: Dictionary(uniqueKeysWithValues: block.map { ($0, end) }))
            if !whole { flight.watchFrom = min(end, start) - 0.3 }
            flight.run(until: end + 4.5)
            let label = "\(block) leave \(offset) frames after the drop forms, \(waiting) waiting"
            Self.expectClean(flight, label)
            #expect(Set(flight.left.map(\.title)) == Set(block), "\(label)")
            let hold = Self.expectNoWaitInTheDrop(flight, label)
            // The drop's neck holds a card for less than a tenth of a second after its place is free.
            #expect(hold < 0.1, "\(label): a card started \(hold) s after its place was free")
            let comes = min(block.count, waiting)
            Self.expectAtRest(flight, all.prefix(3).filter { !block.contains($0) } + all.dropFirst(3).prefix(comes), label)
            #expect(flight.stack.waiting.count == waiting - comes, "\(label)")
            // The drop is there for as long as a card waits in it, and counts it.
            #expect(flight.stack.overflow?.count == (comes < waiting ? waiting - comes : nil), "\(label)")
        }
    }

    /// The overflow drop is at rest with three cards waiting, and a card leaves. A second card's
    /// time is up from one frame later to long after: while the first card waiting still grows out
    /// of the drop. The second card waiting grows out as the second drop starts to rise, out of the
    /// drop as it is, and takes the neck the drop still has to the first with it.
    @Test(arguments: [["a", "b"], ["a", "c"], ["c", "b"], ["a", "b", "c"]], Sweep.parts)
    func aCardLeavesWhileACardGrowsOutOfTheDrop(block: [String], part: Int) {
        Sweep.fly(1...80, near: [4, Self.rise, Self.rise + 14, Self.rise + 48], part: part) { offset, whole in
            var ends: [String: Double] = [:]
            for (index, title) in block.enumerated() { ends[title] = 6 + Double(index * offset) * Flight.frame }
            let flight = Self.flight(6, max: 3, ends: ends)
            if !whole { flight.watchFrom = 5.7 }
            flight.run(until: 6 + Double(block.count * offset) * Flight.frame + 4.5)
            let label = "\(block) leave \(offset) frames apart, three waiting"
            Self.expectClean(flight, label)
            #expect(flight.left.map(\.title).sorted() == block.sorted(), "\(label)")
            #expect(flight.released.count == block.count, "\(label)")
            let hold = Self.expectNoWaitInTheDrop(flight, label)
            #expect(hold < Flight.frame + 1e-9, "\(label): a card started \(hold) s after its place was free")
            let waited = ["d", "e", "f"]
            Self.expectAtRest(flight, ["a", "b", "c"].filter { !block.contains($0) } + waited.prefix(block.count), label)
            #expect(flight.stack.overflow?.count == (block.count < 3 ? 3 - block.count : nil), "\(label)")
        }
    }

    /// The same on a drawing that drops frames and catches up, with the changes starting a moment
    /// after they are decided, as the Mac app plans them. The stack chooses the card on the step
    /// that reaches the moment its place is free, however long that step is, so the card starts
    /// with the stack closing up, or one step after the drop's neck lets go.
    @Test(arguments: [["a"], ["b", "c"], ["a", "b", "c"]], Sweep.parts)
    func cardsLeaveWhileTheDropFormsOnUnevenFrames(block: [String], part: Int) {
        let (start, lines) = Self.forming(5, max: 3)
        Sweep.fly(-10...110, near: Self.meeting(lines), part: part) { offset, whole in
            for lead in [0, 0.06] {
                let end = start + Double(offset) * Flight.frame
                let flight = Self.flight(5, max: 3, lead: lead, ends: Dictionary(uniqueKeysWithValues: block.map { ($0, end) }))
                if !whole { flight.watchFrom = min(end, start) - 0.3 }
                flight.pacing = { [2, 0.25, 1, 0.5, 3, 0.25, 0.25, 1.5][($0 + offset + 80) % 8] }
                flight.run(until: end + 4.5)
                let label = "\(block) leave \(offset) frames after the drop forms, lead \(lead), uneven frames"
                #expect(flight.issues.isEmpty, "\(label): \(flight.issues.joined(separator: "\n"))")
                // A leave is late only by as much as a step comes later than the one before it.
                let late = flight.left.map { $0.time - $0.due }
                #expect((late.min() ?? 0) >= -1e-9 && (late.max() ?? 0) < 3 * Flight.frame + CardStack.roundWindow, "\(label): \(late)")
                #expect(Set(flight.left.map(\.title)) == Set(block), "\(label)")
                let comes = min(block.count, 2)
                Self.expectAtRest(flight, ["a", "b", "c"].filter { !block.contains($0) } + ["d", "e"].prefix(comes), label)
                #expect(flight.stack.overflow?.count == (comes < 2 ? 1 : nil), "\(label)")
                // Each card starts on the step that reaches its moment: no later than the longest
                // step, three frames, after its place is free and the neck has let go.
                guard let drop = flight.drops.first else { continue }
                let holder = flight.left.first { $0.title == drop.holder }?.rise ?? .infinity
                for (release, rise) in zip(flight.released, flight.left.map(\.rise).sorted()) {
                    let due = max(rise, min(drop.letsGo, holder))
                    #expect(
                        release.start >= due - 1e-9 && release.start < due + 3 * Flight.frame + lead + 1e-9,
                        "\(label): \(release.title) started \(release.start - due) s after it was due")
                }
            }
        }
    }

    /// A full stack with cards waiting in the overflow drop: a block's time is up while the drop
    /// forms, shows and hands a card over, in steps of one frame. No card waits for the drop.
    @Test(arguments: [["a"], ["a", "b"], ["b"], ["c"], ["b", "c"], ["a", "b", "c"]], Sweep.parts)
    func aBlockLeavesAFullStack(block: [String], part: Int) {
        let (start, lines) = Self.forming(6, max: 3)
        #expect(start > 0)
        Sweep.fly(-30...150, near: Self.meeting(lines), part: part) { offset, whole in
            let end = start + Double(offset) * Flight.frame
            let flight = Self.flight(6, max: 3, ends: Dictionary(uniqueKeysWithValues: block.map { ($0, end) }))
            if !whole { flight.watchFrom = min(end, start) - 0.3 }
            flight.run(until: end + 4.5)
            let label = "\(block) \(offset) frames after the drop forms"
            Self.expectClean(flight, label)
            #expect(Set(flight.left.map(\.title)) == Set(block), "\(label)")
            Self.expectNoWaitInTheDrop(flight, label)
            #expect(flight.stack.live.count == 3, "\(label)")
            #expect(flight.stack.waiting.count == 3 - block.count, "\(label)")
        }
    }

    /// Flights in which cards grow out of the overflow drop: how many cards, which leave, how many
    /// frames after the first the second leaves, and whether every card is the same size. Two and
    /// three places free at one moment, with and without a card left in the drop, under a card
    /// that stays, and a second card a few frames after the first. The last two are one card
    /// alone, which the user approved before: the measures hold for it as it was.
    static let splits: [(count: Int, block: [String], apart: Int, alike: Bool)] = [true, false].flatMap { alike in
        [
            (5, ["a", "b", "c"], 0, alike), (5, ["a", "b"], 0, alike), (6, ["a", "b", "c"], 0, alike), (6, ["a", "b"], 0, alike),
            (6, ["a", "b"], 1, alike), (6, ["a", "b"], 4, alike), (6, ["a", "b"], 9, alike),
            (5, ["a"], 0, alike), (4, ["a"], 0, alike),
        ]
    }

    /// The moments the first card of a split leaves, on the stack's clock: with the drop at rest,
    /// and with the drop still rounding out, so that the cards grow out of it from two frames
    /// after its neck lets go on. The full sweep flies more of them.
    private static func splitMoments(_ split: (count: Int, block: [String], apart: Int, alike: Bool)) -> [Double] {
        guard let (start, lines) = formed[split.alike]?[split.count] else { return [6] }
        // A plain run flies the rounding drop for the cards at one moment that are the same size.
        let rounding = Sweep.full ? [2, 6, 10, 16, 24, 34] : split.alike && split.apart == 0 && split.block.count > 1 ? [2, 16] : []
        return [6] + rounding.map { start + Double(lines[1] - rise + $0) * Flight.frame }
    }

    /// `forming` for a stack of three, by whether the cards are all the same size and how many.
    private static let formed: [Bool: [Int: (start: Double, lines: [Int])]] = Dictionary(
        uniqueKeysWithValues: [true, false].map { alike in
            (alike, Dictionary(uniqueKeysWithValues: [4, 5, 6].map { ($0, forming($0, max: 3, alike: alike)) }))
        })

    /// Flies a split and calls `each` on every frame from the moment the first card grows out of
    /// the drop, for 0.6 s, with the picture as it is drawn and the cards that grew out, top to
    /// bottom. Expects the cards that waited to have come out.
    private static func flySplit(
        _ split: (count: Int, block: [String], apart: Int, alike: Bool), at moment: Double,
        each: (_ time: Double, _ pieces: [StackOutline.Piece], _ grown: [CardStack.Entry], _ drop: IslandShape?) -> Void
    ) {
        var ends: [String: Double] = [:]
        for (index, title) in split.block.enumerated() { ends[title] = moment + Double(min(index, 1) * split.apart) * Flight.frame }
        let flight = flight(split.count, max: 3, ends: ends, alike: split.alike)
        flight.watchFrom = moment - 0.3
        flight.run(until: moment + 1.4) { flight, _ in
            guard let start = flight.released.first?.start, flight.time >= start, flight.time < start + 0.6 else { return }
            let outline = flight.stack.outline
            each(
                flight.time, outline.pieces(at: flight.time) + outline.overflowPieces(at: flight.time),
                flight.stack.entries.filter { $0.outOfDrop && !$0.isLeaving }, flight.stack.overflow?.animator.shape(at: flight.time))
        }
        #expect(flight.issues.isEmpty, "\(split) at \(moment): \(flight.issues.joined(separator: "\n"))")
        #expect(flight.released.count == min(split.block.count, split.count - 3), "\(split) at \(moment)")
    }

    /// The sharpest an inside corner of liquid may be, as `Picture.sharpestInsideCorner` measures
    /// it: a radius of 1.5 points. A square corner measures 1.3.
    static let sharp = 1.5
    /// The widest angle at which the edges of two pieces may cross on the outline: 5 degrees.
    static let kink = 5 * Double.pi / 180
    /// The most frames in a row an inside corner may be sharper than that: as a join breaks. The
    /// neck of the overflow drop under one card, which the user approved, takes three.
    static let breaking = 4

    /// Cards that grow out of the overflow drop at one moment are one shape of liquid, which parts
    /// in two. Its outline has no sharp inside corner on any frame: no step where one card meets
    /// the other, and no cut. The join between two cards is the smooth blend, whose inside corners
    /// are rounder than `sharp` for as long as the capsules overlap.
    ///
    /// A join that breaks is the one exception, as for every neck: its corners close to a point
    /// as it lets go. That is over within `breaking` frames, and only once the capsules are apart.
    @Test(arguments: splits)
    func cardsOutOfTheDropAtOnceAreOneSmoothShape(_ split: (count: Int, block: [String], apart: Int, alike: Bool)) {
        for moment in Self.splitMoments(split) {
            var run = 0, longest = 0, sharpestJoined = Double.infinity, sharpest = Double.infinity
            var cut = 0, cutFrames = 0, crossing = 0.0
            var place = ""
            Self.flySplit(split, at: moment) { time, pieces, grown, drop in
                let shapes = grown.map { $0.animator.shape(at: time) } + (drop.map { [$0] } ?? [])
                // Where two shapes overlap or are joined: the lower one is less than a third of
                // its blend below the upper one, and a little more. Apart, they are plain capsules.
                let joins = zip(shapes, shapes.dropFirst()).filter { $1.pillTop - ($0.pillTop + $0.pillHeight) < $1.blend / 3 + 2 }
                guard let top = joins.map({ $0.0.pillTop + $0.0.pillHeight }).min(), let bottom = joins.map(\.1.pillTop).max(),
                      let widest = joins.map({ max($0.0.pillWidth, $0.1.pillWidth) }).max()
                else {
                    run = 0
                    return
                }
                // The join and the round ends on both sides of it.
                let ends = Self.tall.pillHeight / 2 + Self.short.blend
                let corner = Picture.sharpestInsideCorner(
                    pieces, left: -8, top: min(top, bottom) - ends, right: widest / 2 + 30, bottom: max(top, bottom) + ends)
                sharpest = min(sharpest, corner.radius)
                cut = max(cut, corner.cut)
                cutFrames += corner.cut > 0 ? 1 : 0
                crossing = max(crossing, corner.crossing)
                run = corner.radius < Self.sharp ? run + 1 : 0
                longest = max(longest, run)
                // Two shapes that overlap are one body of liquid, not a join about to break. The
                // corner belongs to the join it is nearest to.
                let nearest = joins.min { abs(corner.y - ($0.0.pillTop + $0.0.pillHeight + $0.1.pillTop) / 2) < abs(corner.y - ($1.0.pillTop + $1.0.pillHeight + $1.1.pillTop) / 2) }
                let overlap = nearest.map { $0.1.pillTop < $0.0.pillTop + $0.0.pillHeight } ?? false
                if overlap, corner.radius < sharpestJoined {
                    sharpestJoined = corner.radius
                    place = "\(fixed(time, 4)) at (\(fixed(corner.x, 1)), \(fixed(corner.y, 1)))"
                }
            }
            let label = "\(split) at \(moment)"
            #expect(cut == 0, "\(label): a cut shows on the outline, \(cut) points long, on \(cutFrames) frames")
            #expect(crossing < Self.kink, "\(label): two pieces cross on the outline at \(crossing * 180 / .pi) degrees")
            #expect(sharpestJoined >= Self.sharp, "\(label): an inside corner of radius \(sharpestJoined) while the shapes overlap, \(place)")
            #expect(longest <= Self.breaking, "\(label): an inside corner sharper than \(Self.sharp) for \(longest) frames in a row")
        }
    }

    /// No text and no icon shows on two cards that are still one shape. A card that starts inside
    /// the card before it shows its content, and so does that card, once the two have parted: the
    /// capsules do not overlap, and what joins them across the gap is no wider than a thin neck, a
    /// third of the blend. The moments are the ones the presenter fades each part in at: the cues
    /// of the card's entrance.
    @Test(arguments: splits)
    func cardsOutOfTheDropShowNoContentBeforeTheyPart(_ split: (count: Int, block: [String], apart: Int, alike: Bool)) {
        for moment in Self.splitMoments(split) {
            var worst = 0.0, shown = 0, cued: [String: Double] = [:]
            Self.flySplit(split, at: moment) { time, pieces, grown, _ in
                /// Whether any part of the card's content has started to fade in.
                func shows(_ entry: CardStack.Entry) -> Bool {
                    guard case let .entering(start, cues) = entry.phase else { return true }
                    let first = start + ([cues.sides] + cues.title + cues.detail).min()!
                    cued[entry.card.title] = first - start
                    return time > first + 1e-9
                }
                for (upper, lower) in zip(grown, grown.dropFirst()) {
                    // Asked of both, so that both are noted.
                    let visible = [shows(upper), shows(lower)].contains(true)
                    guard visible else { continue }
                    shown += 1
                    let above = upper.animator.shape(at: time), below = lower.animator.shape(at: time)
                    let gap = below.pillTop - (above.pillTop + above.pillHeight)
                    // As deep as they overlap, or as wide as they are joined.
                    let joined = gap < 0 ? max(above.pillWidth, below.pillWidth)
                        : Picture.width(pieces, y: above.pillTop + above.pillHeight + gap / 2, reach: max(above.pillWidth, below.pillWidth) / 2 + 30)
                    worst = max(worst, joined)
                }
            }
            let label = "\(split) at \(moment)"
            #expect(worst <= Self.short.blend / 3, "\(label): content shows on two cards joined \(worst) points wide")
            // Two cards did come out, and their content did show.
            if split.block.count > 1, split.count - 3 > 1 { #expect(shown > 0, "\(label)") }
        }
    }

    /// Seven cards at the default time into a stack of six, which hands each card over as one
    /// leaves: cards run out as fast as they come in, and none waits.
    @Test(arguments: [nil, 0.0]) func sevenCardsIntoAStackOfSix(delay: Double?) {
        for lead in [0, 0.06] {
            let cards = Self.titles.prefix(7).map { Self.card($0, seconds: Defaults.seconds) }
            let flight = Flight(CardStack(settings: StackSettings(max: 6, delay: delay), cards: Array(cards)), lead: lead, metrics: Self.layout)
            flight.run(until: 20)
            Self.expectClean(flight, "seven into six, delay \(String(describing: delay)), lead \(lead)")
            #expect(flight.left.map(\.title) == Array(Self.titles.prefix(7)))
            #expect(flight.left.allSatisfy { $0.together == 1 && abs($0.time - $0.due) < 1e-9 })
            #expect(flight.stack.entries.isEmpty)
        }
    }

    /// The same flight twice gives the same frames, to the last bit.
    @Test func theSameCardsGiveTheSameFrames() {
        func fly() -> Flight {
            let flight = Self.flight(6, max: 4, ends: ["a": 6, "c": 6.1, "d": 6.3, "b": 6.9], rest: 1.5)
            flight.script = [(6.5, { $0.entry("e")?.dismissed = false })]
            flight.run(until: 11)
            return flight
        }
        let first = fly(), second = fly()
        Self.expectClean(first, "a busy stack")
        #expect(first.frames == second.frames)
        #expect(first.left.map(\.time) == second.left.map(\.time))
        #expect(first.stack.entries.isEmpty)
    }

    /// The pointer starts nothing and stops nothing. No card's time runs out under it and no gap
    /// closes, and what is already in the air lands: a drop that rises is swallowed, a card that
    /// drops in opens. In steps of one frame from before a card leaves until its drop has gone.
    @Test(arguments: Sweep.parts) func thePointerHoldsWhatHasNotStarted(part: Int) {
        let hold = 1.0
        Sweep.fly(-20...100, near: [0, Self.rise, Self.gone, 72], part: part) { offset, whole in
            let on = 8 + Double(offset) * Flight.frame
            let flight = Self.flight(5, ends: ["b": 8, "d": 8.6])
            if !whole { flight.watchFrom = 7.5 }
            flight.script = [
                (on, { $0.stack.hover(true, at: $0.time) }),
                (on + hold, { flight in
                    flight.stack.hover(false, at: flight.time)
                    // Every card that shows gets a moment to be read.
                    for entry in flight.stack.live where entry.isShown && entry.remaining == 1.5 {
                        flight.expectDue(entry.card.title, at: flight.time + 1.5)
                    }
                }),
            ]
            var started: [String] = []
            var closed = false
            flight.run(until: on + hold + 4) { flight, changes in
                guard flight.stack.hovering else { return }
                started += changes.left.map(\.entry.card.title)
                closed = closed || changes.moved
            }
            #expect(flight.issues.isEmpty, "pointer on \(offset) frames after b: \(flight.issues.joined(separator: "\n"))")
            // b had started to leave before the pointer came, or it stays until the pointer has gone.
            #expect(started.isEmpty, "\(offset): \(started) started to leave under the pointer")
            #expect(!closed, "\(offset): a gap closed under the pointer")
            #expect(flight.left.allSatisfy { $0.time >= $0.due - 1e-9 })
            #expect(Set(flight.left.map(\.title)) == ["b", "d"])
            #expect(flight.stack.live.map(\.card.title) == ["a", "c", "e"])
            #expect(flight.stack.live.allSatisfy { abs($0.animator.shape(at: flight.time).pillTop - $0.top) < 0.01 })
        }
    }

    /// Each card's place and size are smooth between the frames too: sampled 40 times a frame, the
    /// middle of every shape never changes speed at once, through every hand-over of a busy stack.
    @Test func everyShapeMovesSmoothlyBetweenFrames() {
        let flight = Self.flight(6, max: 4, ends: ["a": 6, "c": 6.1, "d": 6.3, "b": 6.9], rest: 1.5)
        flight.script = [(6.5, { $0.entry("e")?.dismissed = false })]
        let step = Flight.frame / 40
        // The fastest any spring here speeds up: a drop that rises the whole stack.
        let limit = 4e5 * step * step
        var worst = 0.0
        flight.run(until: 9.5) { flight, _ in
            let from = flight.time
            for entry in flight.stack.entries {
                var a = entry.animator.shape(at: from - step), b = entry.animator.shape(at: from)
                for index in 1...40 {
                    let c = entry.animator.shape(at: from + Double(index) * step)
                    func middle(_ shape: IslandShape) -> Double { shape.pillTop + shape.pillHeight / 2 }
                    worst = max(worst, abs(middle(c) - 2 * middle(b) + middle(a)))
                    (a, b) = (b, c)
                }
            }
        }
        Self.expectClean(flight, "a busy stack")
        #expect(worst < limit, "the middle of a shape changed speed by \(worst / step) points a second at once")
    }

    /// Cards whose times are up at any moments at all, with clicks between them: forty stacks from
    /// a fixed seed, every frame checked.
    @Test func anyTimingKeepsEveryRule() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for round in 0..<40 {
            let count = 4 + Int(random() * 5)
            let max = 2 + Int(random() * 5)
            let titles = Array(Self.titles.prefix(count))
            // A few card lives apart, so the stack is busy the whole time.
            let cards = titles.map { Self.card($0, seconds: 1.5 + (random() * 3 * 60).rounded() / 60) }
            let flight = Flight(
                CardStack(settings: StackSettings(max: max, delay: random() < 0.5 ? 0 : nil), cards: cards),
                lead: random() < 0.5 ? 0 : 0.06, metrics: Self.layout)
            for title in titles where random() < 0.3 {
                flight.script.append((1 + random() * 8, { $0.entry(title)?.dismissed = false }))
            }
            flight.run(until: 30)
            Self.expectClean(flight, "stack \(round)")
            #expect(flight.stack.entries.isEmpty && flight.stack.waiting.isEmpty, "stack \(round)")
            #expect(Set(flight.left.map(\.title)).count == flight.left.count)
        }
    }

    // MARK: A card that comes in while cards leave

    /// `count` cards of which `leavers` end together, and a card of another drip, x, due `offset`
    /// frames after that moment.
    private static func arrival(_ count: Int, leavers: [String], offset: Int, delay: Double? = 0, lead: Double = 0) -> (flight: Flight, leave: Double, due: Double) {
        let from = countdowns(count, delay: delay, lead: lead)
        let leave = (from.values.max() ?? 0) + 1.5
        let cards = titles.prefix(count).map { card($0, seconds: leavers.contains($0) ? leave - (from[$0] ?? 0) : 60) }
        let flight = Flight(
            CardStack(settings: StackSettings(max: 6, delay: delay), cards: cards), lead: lead, metrics: layout)
        let due = leave + Double(offset) * Flight.frame
        flight.late = [(due, card("x"))]
        return (flight, leave, due)
    }

    /// Flies `arrival` to its end, and expects every rule kept, the cards that leave gone on time,
    /// and x in at once and at rest in its place: under the last card that stays, or at the top.
    /// Returns what x dropped out of.
    @discardableResult
    private static func expectArrival(
        _ count: Int, leavers: [String], offset: Int, delay: Double? = 0, lead: Double = 0, whole: Bool = true,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> (from: String?, fromLeaving: Bool)? {
        let (flight, leave, due) = arrival(count, leavers: leavers, offset: offset, delay: delay, lead: lead)
        if !whole { flight.watchFrom = min(leave, due) - 0.3 }
        flight.run(until: max(leave, due) + 2.6)
        let label = "\(leavers) of \(count) leave, x due \(offset) frames after"
        expectClean(flight, label, sourceLocation: sourceLocation)
        let stays = titles.prefix(count).filter { !leavers.contains($0) }
        #expect(flight.left.map(\.title).sorted() == leavers, "\(label)", sourceLocation: sourceLocation)
        #expect(flight.left.allSatisfy { abs($0.time - leave) < 1e-9 }, "\(label)", sourceLocation: sourceLocation)
        #expect(flight.stack.entries.map(\.card.title) == stays + ["x"], "\(label)", sourceLocation: sourceLocation)
        // No wait: the stack takes x on the first frame it is due.
        let x = flight.arrived.first
        #expect(x.map { $0.decided - due < Flight.frame } ?? false, "\(label): x waited", sourceLocation: sourceLocation)
        var top: Double?
        for entry in flight.stack.entries {
            let place = top ?? entry.metrics.pillTop
            let shape = entry.animator.shape(at: flight.time)
            #expect(
                entry.isShown && abs(shape.pillTop - place) < 0.01 && abs(shape.pillHeight - entry.metrics.pillHeight) < 0.01,
                "\(label): \(entry.card.title) is not at rest in its place", sourceLocation: sourceLocation)
            top = place + entry.metrics.pillHeight + CardStack.gap
        }
        return x.map { ($0.from, $0.fromLeaving) }
    }

    /// The stacks a card comes into: one, two and three cards that all leave, and the same under a
    /// card that stays.
    static let leaving: [(Int, [String])] = [
        (1, ["a"]), (2, ["a", "b"]), (3, ["a", "b", "c"]), (2, ["b"]), (3, ["b", "c"]), (4, ["b", "c", "d"]),
    ]

    /// A card is due while cards leave, in steps of one frame from half a second before they start
    /// to leave until their drops are long gone. It comes in on the frame it is due, every time: out
    /// of the last card while that card still shows, out of the capsule it gathers into, out of its
    /// drop as it rises, and out of the notch or the card above once the drop is in.
    @Test(arguments: leaving, Sweep.parts) func aCardComesInWhileCardsLeave(_ kind: (Int, [String]), part: Int) {
        let (count, leavers) = kind
        let last = leavers[leavers.count - 1], stays = count > leavers.count ? "a" : nil
        // Before they leave, out of the last card. While it gathers and rises, out of that card
        // still: 12 and 24 frames in it gathers, 36 frames in its drop rises. Once the drop is in,
        // out of what it went into.
        let before = [-60, -1], during = [0, 12, 24, 36, 44], after = [110]
        Sweep.fly(-60...110, near: before + during + after + [4, Self.rise, Self.gone], part: part) { offset, whole in
            let source = Self.expectArrival(count, leavers: leavers, offset: offset, whole: whole)
            if before.contains(offset) { #expect(source?.from == last && source?.fromLeaving == false, "\(offset)") }
            if during.contains(offset) { #expect(source?.from == last && source?.fromLeaving == true, "\(offset)") }
            if after.contains(offset) { #expect(source?.from == stays && source?.fromLeaving == false, "\(offset)") }
        }
    }

    /// The same with the changes starting a moment after they are decided, as the Mac app plans
    /// them, and with the entrances paced by the stack coming to rest.
    @Test(arguments: [(3, ["a", "b", "c"]), (3, ["b", "c"])]) func aCardComesInWithALead(count: Int, leavers: [String]) {
        for offset in stride(from: -40, through: 80, by: 3) {
            Self.expectArrival(count, leavers: leavers, offset: offset, lead: 0.06, whole: offset == -40)
            Self.expectArrival(count, leavers: leavers, offset: offset + 1, delay: nil, whole: offset == -40)
        }
    }

    /// The same on a drawing that drops frames and catches up, so a step is now two frames and now
    /// a quarter of one: the stack plans a rise a step ahead, and the step after may come sooner.
    @Test(arguments: [(3, ["a", "b", "c"]), (3, ["b", "c"])], Sweep.parts)
    func aCardComesInOnUnevenFrames(_ kind: (Int, [String]), part: Int) {
        let (count, leavers) = kind
        Sweep.fly(-10...70, near: [0, 4, Self.rise, Self.gone], part: part) { offset, whole in
            for lead in [0, 0.06] {
                let (flight, leave, due) = Self.arrival(count, leavers: leavers, offset: offset, lead: lead)
                if !whole { flight.watchFrom = min(leave, due) - 0.3 }
                flight.pacing = { [2, 0.25, 1, 0.5, 3, 0.25, 0.25, 1.5][($0 + offset + 80) % 8] }
                flight.run(until: max(leave, due) + 2.6)
                Self.expectClean(flight, "\(leavers), x due \(offset) frames after, lead \(lead), uneven frames")
                #expect(flight.stack.entries.map(\.card.title) == Self.titles.prefix(count).filter { !leavers.contains($0) } + ["x"])
                #expect(flight.stack.entries.allSatisfy { $0.isShown && abs($0.animator.shape(at: flight.time).pillTop - $0.top) < 0.01 })
                #expect(flight.arrived.first.map { $0.decided - due < 3 * Flight.frame } ?? false)
            }
        }
    }

    /// A card that drops out of a rising drop is smooth between the frames too, and so is the drop:
    /// sampled 40 times a frame, no middle changes speed at once.
    @Test func aCardOutOfADropMovesSmoothlyBetweenFrames() {
        let step = Flight.frame / 40
        let limit = 4e5 * step * step
        for (count, leavers) in [(3, ["a", "b", "c"]), (3, ["b", "c"])] {
            for offset in [3, 20, 29, 36, 44, 52] {
                let (flight, leave, due) = Self.arrival(count, leavers: leavers, offset: offset)
                var worst = 0.0
                flight.run(until: max(leave, due) + 2) { flight, _ in
                    let from = flight.time
                    guard from > leave - 0.1 else { return }
                    for entry in flight.stack.entries {
                        func middle(_ time: Double) -> Double {
                            let shape = entry.animator.shape(at: time)
                            return shape.pillTop + shape.pillHeight / 2
                        }
                        var a = middle(from - step), b = middle(from)
                        for index in 1...40 {
                            let c = middle(from + Double(index) * step)
                            worst = max(worst, abs(c - 2 * b + a))
                            (a, b) = (b, c)
                        }
                    }
                }
                Self.expectClean(flight, "\(leavers), x \(offset) frames after")
                #expect(worst < limit, "\(leavers) \(offset): a middle changed speed by \(worst / step) points a second at once")
            }
        }
    }

    /// The same arrivals twice give the same frames, to the last bit.
    @Test func theSameArrivalsGiveTheSameFrames() {
        func fly() -> Flight {
            let (flight, leave, _) = Self.arrival(4, leavers: ["b", "c", "d"], offset: 33)
            flight.late += [(leave + 0.2, Self.card("y", seconds: 1.5)), (leave + 0.4, Self.card("z", seconds: 1.2))]
            flight.run(until: leave + 8)
            return flight
        }
        let first = fly(), second = fly()
        Self.expectClean(first, "three arrivals")
        #expect(first.frames == second.frames)
        #expect(first.arrived.map(\.decided) == second.arrived.map(\.decided))
        #expect(first.arrived.count == 3)
    }

    /// Cards whose times are up at any moments at all, clicks between them, and cards of another
    /// drip due at any moments: forty stacks from a fixed seed, every frame checked, and every card
    /// comes and goes.
    @Test func anyTimingKeepsEveryRuleWithArrivals() {
        var seed: UInt64 = 0xD1B5_4A32_D192_ED03
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var outOfLeaving = 0
        for round in 0..<40 {
            let count = 2 + Int(random() * 4)
            let titles = Array(Self.titles.prefix(count))
            let cards = titles.map { Self.card($0, seconds: 1.5 + (random() * 3 * 60).rounded() / 60) }
            let flight = Flight(
                CardStack(settings: StackSettings(max: 3 + Int(random() * 4), delay: random() < 0.5 ? 0 : nil), cards: cards),
                lead: random() < 0.5 ? 0 : 0.06, metrics: Self.layout)
            for title in titles where random() < 0.3 {
                flight.script.append((1 + random() * 8, { $0.entry(title)?.dismissed = false }))
            }
            for title in ["s", "t", "u", "v"] where random() < 0.8 {
                flight.late.append((1.5 + random() * 8, Self.card(title, seconds: 1.5 + (random() * 2 * 60).rounded() / 60)))
            }
            let late = flight.late.count
            flight.run(until: 30)
            Self.expectClean(flight, "stack \(round)")
            #expect(flight.stack.entries.isEmpty && flight.stack.waiting.isEmpty && flight.late.isEmpty, "stack \(round)")
            #expect(flight.left.count == count + late, "stack \(round)")
            outOfLeaving += flight.arrived.filter(\.fromLeaving).count
        }
        // Enough of them dropped out of a card on its way out for this to be about that.
        #expect(outOfLeaving >= 5, "\(outOfLeaving) cards dropped out of a card on its way out")
    }

    /// A drop out of a drop is drawn against that drop as the drop itself is drawn: melted into the
    /// notch it goes into. The picture holds all of that drop's own, is that drop's own away from
    /// the new drop, and fills in between the new drop and the notch, which the drop alone would
    /// leave as a sharp corner.
    @Test func aDropOutOfADropIsDrawnAgainstItAsItIsDrawn() {
        let m = Self.short
        let rising = IslandShape(pillTop: 24, pillWidth: m.dropSize, pillHeight: m.dropSize, progress: 0, blend: m.blend)
        let drop = IslandShape(pillTop: 40, pillWidth: m.dropSize, pillHeight: m.dropSize, progress: 0, blend: m.blend)
        let anchor = DropletAnchor.capsule(rising, metrics: m)
        let own = DropletField(metrics: m, shape: rising)
        let alone = DropletField(metrics: m, shape: drop, anchor: anchor)
        let nested = DropletField(
            metrics: m, shape: drop, anchor: anchor, hosts: [DropletField.Host(anchor: .notch(m), blend: rising.blend)])
        var filled = 0
        for x in stride(from: -60.0, through: 60, by: 1) {
            for y in stride(from: 0.0, through: 110, by: 1) {
                let value = nested.value(x: x, y: y)
                #expect(value <= own.value(x: x, y: y) + 1e-12)
                #expect(value <= alone.value(x: x, y: y) + 1e-12)
                let away = (x * x + (y - 53) * (y - 53)).squareRoot() - m.dropSize / 2 >= m.blend + own.value(x: x, y: y)
                if away { #expect(value == own.value(x: x, y: y)) }
                if value < 0, alone.value(x: x, y: y) > 0, own.value(x: x, y: y) > 0 { filled += 1 }
            }
        }
        #expect(filled > 20)
        // Above its trace line the piece is its anchor's own, so the cut never shows.
        #expect(nested.traceTop == drop.pillTop - drop.blend - 1)
        #expect(nested.touchesNotch)
        // Without hosts nothing changes: the anchor is all there is.
        #expect(DropletField(metrics: m, shape: drop, anchor: anchor, hosts: []).value(x: 3, y: 50) == alone.value(x: 3, y: 50))
    }

    // MARK: A step that takes long

    /// A step that takes long, as when the main thread stalls or the screen sleeps, says nothing
    /// about how long the next one takes. The stack plans no further ahead than `longestStep`: a
    /// card whose time is up a second after the stall shows until then, takes the pointer and
    /// leaves as its ring is empty.
    @Test func aLongStepPlansNoLeaveFarAhead() {
        for lead in [0, 0.06] {
            let flight = Self.flight(4, lead: lead, ends: ["b": 9, "c": 9.6])
            // Two seconds in one step, from 6 to 8.
            flight.pacing = { $0 == 721 ? 240 : 1 }
            var ahead = 0.0
            var missed = 0
            flight.run(until: 12) { flight, _ in
                let now = flight.time
                for entry in flight.stack.entries where entry.isLeaving {
                    ahead = max(ahead, (entry.exit?.time ?? now) - now)
                }
                // Until its time is up, b is a card like any other: the pointer finds it.
                guard now > 7, now < 8.9, let b = flight.entry("b") else { return }
                let shape = b.animator.shape(at: now)
                if flight.stack.entry(at: IslandPoint(0, shape.pillTop + shape.pillHeight / 2), time: now) !== b { missed += 1 }
            }
            Self.expectClean(flight, "a step of two seconds, lead \(lead)")
            #expect(ahead <= lead + CardStack.longestStep + 1e-9, "a leave was planned \(ahead) s ahead, lead \(lead)")
            #expect(missed == 0, "b took no pointer on \(missed) frames before its time was up, lead \(lead)")
            #expect(flight.left.map(\.title) == ["b", "c"])

            // The pointer comes onto the stack after the stall, before b's time is up: it holds b.
            let held = Self.flight(4, lead: lead, ends: ["b": 9, "c": 9.6])
            held.pacing = { $0 == 721 ? 240 : 1 }
            var on = 0.0, off = 0.0
            held.script = [
                (8.5, { flight in
                    flight.stack.hover(true, at: flight.time)
                    on = flight.time
                }),
                (9.5, { flight in
                    flight.stack.hover(false, at: flight.time)
                    off = flight.time
                }),
            ]
            held.run(until: 14)
            #expect(held.issues.isEmpty, "the pointer after a long step, lead \(lead): \(held.issues.joined(separator: "\n"))")
            #expect(on > 0 && off > on)
            // Every card under the pointer gets a moment to be read once it has gone.
            #expect(held.left.map(\.title) == ["b", "c"])
            #expect(held.left.allSatisfy { $0.time >= off + 1.5 - 1e-9 }, "a card left under the pointer, lead \(lead): \(held.left)")
        }
    }

    /// The same for a card that grows out of the overflow drop. A step of 0.15 s just after a card
    /// starts to leave ends 0.1 s before its drop starts to rise. The card waiting is chosen on the
    /// step that reaches that moment, not on this one.
    @Test func aLongStepChoosesNoCardFarAhead() {
        for lead in [0, 0.06] {
            let flight = Self.flight(4, max: 3, lead: lead, ends: ["b": 9])
            // The step after the one b starts to leave on takes eighteen frames.
            flight.pacing = { $0 == 1082 ? 18 : 1 }
            flight.run(until: 13)
            #expect(flight.issues.isEmpty, "a long step as b leaves, lead \(lead): \(flight.issues.joined(separator: "\n"))")
            #expect(flight.released.map(\.title) == ["d"])
            let ahead = flight.released.map { $0.start - $0.decided }.max() ?? 0
            #expect(ahead <= lead + CardStack.longestStep + 1e-9, "d was chosen \(ahead) s ahead, lead \(lead)")
            // It still starts as b's drop starts to rise.
            let rise = flight.left.first?.rise ?? 0
            #expect(flight.released.allSatisfy { abs($0.start - rise) < 1e-9 }, "lead \(lead)")
            Self.expectAtRest(flight, ["a", "c", "d"], "a long step as b leaves, lead \(lead)")
        }
    }

    // MARK: Rounds

    /// Neighbours are the cards next to each other on screen. A card on its way out between two
    /// cards whose time is up together does not split their round: it is taken away, gathers or
    /// rises, and the two leave in one motion, once the time of the last is up.
    @Test func aRoundReachesAcrossACardOnItsWayOut() {
        // b is clicked long before, a moment before, on the step that plans the leave, and with it.
        for clicked in [7.6, 7.9, 8 - Flight.frame, 8] {
            for offset in 1...3 {
                let last = 8 + Double(offset) * Flight.frame
                let flight = Self.flight(4, ends: ["a": 8, "c": last])
                flight.script = [(clicked, { $0.entry("b")?.dismissed = false })]
                flight.watchFrom = 7.3
                flight.run(until: 11)
                let label = "b clicked at \(clicked), a and c \(offset) frames apart"
                Self.expectClean(flight, label)
                let a = flight.left.first { $0.title == "a" }, c = flight.left.first { $0.title == "c" }
                #expect(a != nil && a?.time == c?.time, "\(label): a left at \(a?.time ?? 0) and c at \(c?.time ?? 0)")
                #expect(abs((c?.time ?? 0) - last) < 1e-9, "\(label)")
                #expect(flight.stack.live.map(\.card.title) == ["d"], "\(label)")
            }
        }
        // A card that stays between them keeps them apart: each leaves at its own moment.
        let apart = Self.flight(4, ends: ["a": 8, "c": 8 + 2 * Flight.frame])
        apart.run(until: 11)
        Self.expectClean(apart, "b stays between a and c")
        #expect(apart.left.map(\.together) == [1, 1])
    }

    // MARK: A card that takes another's place

    /// A card that takes another's place rests once the springs of that change have settled. A
    /// glide to close a gap, still in flight, does not count, and holds no entrance back.
    @Test func aSwapDuringAGlideRestsWithItsOwnSprings() {
        let swap = 5.3
        func fly(gliding: Bool) -> (stack: CardStack, c: CardStack.Entry?) {
            let flight = Self.flight(3, delay: nil)
            flight.watchFrom = 4.5
            if gliding { flight.script = [(5, { $0.entry("a")?.dismissed = false })] }
            flight.script.append((swap, { flight in
                guard let c = flight.entry("c") else { return }
                flight.stack.swap(c, for: Self.card("c"), metrics: Self.layout(c.card), at: flight.time, reduced: false)
            }))
            flight.run(until: swap + Flight.frame)
            #expect(flight.issues.isEmpty, "\(flight.issues.joined(separator: "\n"))")
            return (flight.stack, flight.entry("c"))
        }
        let still = fly(gliding: false), gliding = fly(gliding: true)
        guard let rests = still.c?.restsAt, let c = gliding.c else {
            Issue.record("no card to swap")
            return
        }
        // The glide is still in flight when the swap has settled, or this is about nothing.
        #expect(c.animator.end > rests + 0.05)
        #expect(abs(c.restsAt - rests) < 1e-9, "the swap rests at \(c.restsAt), and at \(rests) without the glide")
        #expect(gliding.stack.isReady(at: rests + 1e-6))
    }

    // MARK: A hand-off

    /// Cards of another drip, which a stack may hand on: five that stay, each of `clicks` at its
    /// moment, and one more card, x, due at `due`.
    private static func handed(clicks: [(String, Double)], x due: Double) -> Flight {
        let flight = Flight(CardStack(settings: StackSettings(max: 6, delay: 0)), metrics: layout)
        flight.late = ["a", "b", "c", "d", "e"].map { (0, card($0)) } + [(due, card("x"))]
        flight.script = clicks.map { title, time in (time, { $0.entry(title)?.dismissed = false }) }
        // Only flown: the other tests check these rules.
        flight.watchFrom = .infinity
        return flight
    }

    /// Flies `flight` to `moment`, hands its stack on to a new one as a drip hands it on to a
    /// background drip, as JSON, and flies both on, with the same clicks and the same card dropping
    /// in. Expects the new stack to draw what the old one draws, on the frame it takes over and on
    /// every frame after it.
    private static func expectHandOff(_ flight: Flight, at moment: Double, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let began = 50.0
        var after: CardStack?
        var took = 0.0
        var worst = 0.0, picture = 0.0, counts = true, frames = 0
        var failure: (any Error)?
        var arrivals = 0
        flight.run(until: moment + 1.5) { flight, _ in
            let now = flight.time, old = flight.stack
            if after == nil, now >= moment - 1e-9 {
                do {
                    let cards = try #require(old.handOff(at: now), sourceLocation: sourceLocation)
                    let sent = try JSONEncoder().encode(StackHandOff(settings: old.settings, cards: cards))
                    let handOff = try JSONDecoder().decode(StackHandOff.self, from: sent)
                    let stack = CardStack(settings: handOff.settings)
                    for card in handOff.cards { stack.resume(card, metrics: layout(card.card), at: began) }
                    after = stack
                    took = now
                } catch {
                    failure = error
                }
            } else if let after {
                // What comes to the old stack comes to the new one: a click, and a card dropping in.
                let time = began + (now - took)
                for entry in old.entries where entry.dismissed != nil {
                    after.entries.first { $0.card.title == entry.card.title }?.dismissed = entry.dismissed
                }
                if flight.arrived.count > arrivals, let card = old.entries.last?.card {
                    after.enter(card, metrics: layout(card), own: false, decided: time, at: time)
                }
                _ = after.advance(to: time, lead: 0, queued: [])
            }
            arrivals = flight.arrived.count
            guard let after else { return }
            let time = began + (now - took)
            counts = counts && old.entries.count == after.entries.count
            for (was, new) in zip(old.entries, after.entries) {
                let a = was.animator.shape(at: now), b = new.animator.shape(at: time)
                worst = max(
                    worst, abs(a.pillTop - b.pillTop), abs(a.pillWidth - b.pillWidth), abs(a.pillHeight - b.pillHeight),
                    abs(a.blend - b.blend), abs(a.progress - b.progress))
                counts = counts && was.isLeaving == new.isLeaving && was.isShown == new.isShown
            }
            // The picture itself, on the frame it takes over and a few times a second after.
            if frames % 12 == 0 {
                for x in [0.0, 10] {
                    picture = max(picture, Flight.difference(
                        Flight.column(old.outline, notch: short, at: now, x: x),
                        Flight.column(after.outline, notch: short, at: time, x: x)))
                }
            }
            frames += 1
        }
        if let failure { throw failure }
        #expect(frames > 0, "\(label): never handed on", sourceLocation: sourceLocation)
        #expect(counts, "\(label): the new stack holds other cards than the old one", sourceLocation: sourceLocation)
        #expect(worst < 1e-6, "\(label): a card is drawn \(worst) points off", sourceLocation: sourceLocation)
        #expect(picture < 1, "\(label): the picture differs by \(picture) points", sourceLocation: sourceLocation)
    }

    /// A stack handed on while cards leave in a chain, one drop inside another, and while a card
    /// drops out of a card on its way out: the new stack draws every card where the old one does,
    /// from the frame it takes over. In steps from the first click until all is at rest.
    @Test(arguments: Sweep.parts) func aMovingStackIsHandedOnAsItIs(part: Int) throws {
        try Sweep.fly(-6...170, near: [0, 12, 24, 30, Self.rise], part: part) { offset, _ in
            let moment = 8 + Double(offset) * Flight.frame
            // d goes into c, which leaves while d is on its way in. Then e, the last card, leaves,
            // and x drops out of it as it gathers.
            let chain = Self.handed(clicks: [("d", 8), ("c", 8.1), ("e", 8.2)], x: 8.25)
            try Self.expectHandOff(chain, at: moment, "a chain, handed on \(offset) frames after the first click")
            // d and e leave together, and x drops out of e's drop as it rises.
            let rising = Self.handed(clicks: [("d", 8), ("e", 8)], x: 8 + 36 * Flight.frame)
            try Self.expectHandOff(rising, at: moment, "a rising drop, handed on \(offset) frames after the click")
        }
    }

    /// A card handed on while it drops in, and shown a moment later, is as far in as it would be
    /// by then. Its countdown starts at the same moment, and loses no time before it does.
    @Test func aCardHandedOnAsItDropsInAgesAsItWould() throws {
        let flight = Self.handed(clicks: [], x: 8.25)
        flight.run(until: 8.3)
        let took = flight.time
        let x = try #require(flight.entry("x"))
        guard case let .entering(start, cues) = x.phase else {
            Issue.record("x is not dropping in")
            return
        }
        #expect(x.countdownFrom > took + 0.5)
        let cards = try #require(flight.stack.handOff(at: took))
        for age in [0.2, 2] {
            let aged = StackHandOff(settings: flight.stack.settings, cards: cards, time: 1_000).cards(at: 1_000 + age)
            let stack = CardStack(settings: flight.stack.settings)
            for card in aged { stack.resume(card, metrics: Self.layout(card.card), at: 50) }
            let entry = try #require(stack.entries.last)
            for later in [0, 0.1, 0.4] {
                let was = x.animator.shape(at: took + age + later), now = entry.animator.shape(at: 50 + later)
                #expect(abs(was.pillTop - now.pillTop) < 1e-6 && abs(was.pillWidth - now.pillWidth) < 1e-6)
                #expect(abs(was.blend - now.blend) < 1e-6 && abs(was.progress - now.progress) < 1e-6)
            }
            // Still dropping in after 0.2 s, from the same moment and on the same cues. In after 2 s.
            if case let .entering(began, fades) = entry.phase {
                #expect(abs(began - (50 + start - took - age)) < 1e-9 && fades == cues)
            } else {
                Issue.record("x is not dropping in")
            }
            _ = stack.advance(to: 50, lead: 0)
            #expect(entry.isShown == (age == 2))
            #expect(entry.anchor === stack.entries[4])
            // Its time is counted from the moment its countdown starts, on either clock.
            let counted = max(took + age - x.countdownFrom, 0)
            #expect(abs(entry.remaining - (x.card.duration - counted)) < 1e-9)
            #expect(abs(entry.countdownFrom - (50 + max(x.countdownFrom - took - age, 0))) < 1e-9)
            // The cards that showed counted down all the while.
            #expect(abs(stack.entries[0].remaining - (flight.stack.entries[0].remaining - age)) < 1e-9)
        }
    }

    /// A drip that lays a card out another way than the drip that handed it on, or a card handed
    /// on without its springs, shows the card open in its place, and it leaves from there.
    @Test func aCardLaidOutAnotherWayShowsOpenInItsPlace() throws {
        let flight = Self.handed(clicks: [("e", 8)], x: 8.25)
        flight.run(until: 8.3)
        let cards = try #require(flight.stack.handOff(at: flight.time))
        let other = IslandMetrics(notchWidth: 185, notchHeight: 32, textWidth: 150, textHeight: 17, detailLines: 0)
        let stack = CardStack(settings: flight.stack.settings)
        for card in cards {
            let (entry, exit) = stack.resume(card, metrics: other, at: 50)
            #expect(entry.isLeaving == (card.leaving != nil) && (exit != nil) == entry.isLeaving)
            guard card.leaving == nil else { continue }
            #expect(entry.isShown)
            #expect(abs(entry.animator.shape(at: 50).pillTop - card.drawnTop) < 1e-9)
        }
        #expect(stack.entries.map(\.card.title) == ["a", "b", "c", "d", "e", "x"])
    }
}
