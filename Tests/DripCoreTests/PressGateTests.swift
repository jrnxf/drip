import DripCore
import Testing

/// A card's buttons take a press only once they have been still for a moment, so a click meant for
/// what was there before never answers the card.
struct PressGateTests {
    private let small = IslandMetrics(notchWidth: 185, notchHeight: 32, textWidth: 180, textHeight: 34)
    private let wide = IslandMetrics(
        notchWidth: 185, notchHeight: 32, textWidth: 500, textHeight: 2 * 17 + 3 + 3 * 15, titleLines: 2,
        detailLines: 3)

    @Test func aPressCountsOnlyOnceTheButtonsHaveBeenStill() {
        #expect(PressGate.delay == 0.4)
        // Nothing has moved yet: nothing holds a press back.
        #expect(PressGate().takes(pressAt: 0))

        var gate = PressGate()
        gate.moves(until: 1)
        #expect(!gate.takes(pressAt: 0.5), "a press while the buttons move")
        #expect(!gate.takes(pressAt: 1), "a press as they stop")
        #expect(!gate.takes(pressAt: 1.39), "a press just after they stop")
        #expect(gate.takes(pressAt: 1.4))
        #expect(gate.takes(pressAt: 3))
    }

    @Test func aLaterMoveHoldsPressesBackAgainAndAnEarlierOneDoesNot() {
        var gate = PressGate()
        gate.moves(until: 1)
        gate.moves(until: 0.5)
        #expect(gate.settled == 1)
        #expect(gate.takes(pressAt: 1.4))
        // A card replaced in place, long after the first settled.
        gate.moves(until: 5)
        #expect(!gate.takes(pressAt: 5.2))
        #expect(gate.takes(pressAt: 5.4))
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
        #expect(!gate.takes(pressAt: 0.1), "a click as the card drops in")
        #expect(!gate.takes(pressAt: entered + 0.2))
        #expect(gate.takes(pressAt: entered + PressGate.delay))

        // Another card takes its place: it springs to a new size, and the clicks wait again.
        let replaced = entered + 2
        animator.resize(to: wide, at: replaced)
        #expect(animator.end > replaced)
        gate.moves(until: animator.end)
        #expect(!gate.takes(pressAt: replaced + 0.05), "a click meant for the card that was there")
        #expect(!gate.takes(pressAt: animator.end + 0.2))
        #expect(gate.takes(pressAt: animator.end + PressGate.delay))
    }
}
