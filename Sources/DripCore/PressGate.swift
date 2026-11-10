/// When a card's buttons take a press: only once they have been still for `delay`. A click meant for
/// what was under the pointer before the card came, moved, or turned into another card in place then
/// never answers the card, such as an Allow that took the place of the card you meant to click.
public struct PressGate: Equatable, Sendable {
    /// How long a card's buttons stay still before a press on them counts.
    public static let delay = 0.4

    /// When the buttons last stopped moving or changing, or a press last did not count, in seconds
    /// on the clock of `CACurrentMediaTime` and of an event's timestamp.
    public private(set) var settled: Double

    public init(settled: Double = -.infinity) {
        self.settled = settled
    }

    /// The buttons move or change until `time`, as when a card comes, springs to a new size or is
    /// replaced in place. A time before the last one changes nothing.
    public mutating func moves(until time: Double) {
        settled = max(settled, time)
    }

    /// Whether a press that began at `time` counts: a press that began on buttons still moving or
    /// just still was meant for something else. One that does not count holds the next back for
    /// `delay` from it too, so the second click of a double-click that starts too early does not
    /// count either. Nil, a press whose start went unseen, never counts.
    public mutating func admits(pressAt time: Double?) -> Bool {
        guard let time else { return false }
        if time >= settled + Self.delay { return true }
        settled = max(settled, time)
        return false
    }
}
