import DripCore
import Testing

/// A card's buttons take a press only once they have been still for a moment, so a click meant for
/// what was there before never answers the card.
struct PressGateTests {
    private let small = IslandMetrics(notchWidth: 185, notchHeight: 32, textWidth: 180, textHeight: 34)
    private let wide = IslandMetrics(
        notchWidth: 185, notchHeight: 32, textWidth: 500, textHeight: 2 * 17 + 3 + 3 * 15, titleLines: 2,
        detailLines: 3)

    /// Whether `gate` takes a press at `time`, with the gate left as it was.
    private func admits(_ gate: PressGate, _ time: Double?) -> Bool {
        var gate = gate
        return gate.admits(pressAt: time)
    }

    /// Whether `gate` takes each press of `times` in turn, with what each does to the gate kept.
    private func presses(_ gate: inout PressGate, _ times: [Double?]) -> [Bool] {
        times.map { gate.admits(pressAt: $0) }
    }

    @Test func aPressCountsOnlyOnceTheButtonsHaveBeenStill() {
        #expect(PressGate.delay == 0.4)
        // Nothing has moved yet: nothing holds a press back.
        #expect(admits(PressGate(), 0))

        var gate = PressGate()
        gate.moves(until: 1)
        #expect(!admits(gate, 0.5), "a press while the buttons move")
        #expect(!admits(gate, 1), "a press as they stop")
        #expect(!admits(gate, 1.39), "a press just after they stop")
        #expect(admits(gate, 1.4))
        #expect(admits(gate, 3))
        // A press that counts holds nothing back.
        let counted = presses(&gate, [1.4, 1.5])
        #expect(counted == [true, true])
        #expect(gate.settled == 1)
    }

    /// A press whose mouse-down went unseen, such as one that began before the card came: never.
    @Test func aPressWithNoStartNeverCounts() {
        var gate = PressGate()
        let unseen = presses(&gate, [nil])
        #expect(unseen == [false])
        #expect(gate.settled == -.infinity)
        gate.moves(until: 1)
        let late = presses(&gate, [nil])
        #expect(late == [false])
        #expect(gate.settled == 1)
    }

    /// The second click of a double-click that starts before the buttons settle lands after they
    /// do: it waits a full delay from the first, so it does not count either.
    @Test func aPressThatDoesNotCountHoldsTheNextBack() {
        var gate = PressGate()
        gate.moves(until: 1)
        #expect(admits(gate, 1.45), "with no press before it")

        let first = presses(&gate, [1.3])
        #expect(first == [false])
        #expect(gate.settled == 1.3)
        #expect(!admits(gate, 1.45), "the second click of the double-click")
        #expect(admits(gate, 1.75))

        // A run of early clicks pushes the gate on with each one.
        let run = presses(&gate, [1.45, 1.8, 2.25])
        #expect(run == [false, false, true])
    }

    @Test func aLaterMoveHoldsPressesBackAgainAndAnEarlierOneDoesNot() {
        var gate = PressGate()
        gate.moves(until: 1)
        gate.moves(until: 0.5)
        #expect(gate.settled == 1)
        #expect(admits(gate, 1.4))
        // A card replaced in place, long after the first settled.
        gate.moves(until: 5)
        #expect(!admits(gate, 5.2))
        #expect(admits(gate, 5.4))
    }

    /// The gate a card's presenter keeps: from the end of its entrance's springs, and again from the
    /// end of a resize to the card that replaces it.
    @Test func theButtonsSettleWithTheIslandsSprings() {
        var animator = IslandAnimator(metrics: small)
        _ = animator.enter(at: 0)
        let entered = animator.end
        #expect(entered > 0)
        var gate = PressGate()
        gate.moves(until: entered)
        #expect(!admits(gate, 0.1), "a click as the card drops in")
        #expect(!admits(gate, entered + 0.2))
        #expect(admits(gate, entered + PressGate.delay))

        // Another card takes its place: it springs to a new size, and the clicks wait again.
        let replaced = entered + 2
        animator.resize(to: wide, at: replaced)
        #expect(animator.end > replaced)
        gate.moves(until: animator.end)
        #expect(!admits(gate, replaced + 0.05), "a click meant for the card that was there")
        #expect(!admits(gate, animator.end + 0.2))
        #expect(admits(gate, animator.end + PressGate.delay))
    }
}
