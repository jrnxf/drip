/// When a card's buttons take a press: only once they have been still for `delay`. A click meant for
/// what was under the pointer before the card came, moved, or turned into another card in place then
/// never answers the card, such as an Allow that took the place of the card you meant to click.
public struct PressGate: Equatable, Sendable {
    /// How long a card's buttons stay still before a press on them counts.
    public static let delay = 0.4

    /// When the buttons last stopped moving or changing, in seconds on the presenter's clock.
    public private(set) var settled: Double

    public init(settled: Double = -.infinity) {
        self.settled = settled
    }

    /// The buttons move or change until `time`, as when a card comes, springs to a new size or is
    /// replaced in place. A time before the last one changes nothing.
    public mutating func moves(until time: Double) {
        settled = max(settled, time)
    }

    /// Whether a press that began at `time`, on the same clock, counts: a press that began on
    /// buttons still moving or just still was meant for something else.
    public func takes(pressAt time: Double) -> Bool {
        time >= settled + Self.delay
    }
}
