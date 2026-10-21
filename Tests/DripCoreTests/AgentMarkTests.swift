@testable import DripCore
import Testing

struct AgentMarkTests {
    @Test func everyMarkParsesInsideItsViewBox() throws {
        for mark in AgentMark.all {
            for layer in mark.layers {
                #expect(try !PathSegment.parse(layer.path).isEmpty, "\(mark.name)")
            }
            let bounds = mark.bounds
            #expect(bounds.width > 0 && bounds.height > 0, "\(mark.name)")
            #expect(bounds.minX >= 0 && bounds.minY >= 0, "\(mark.name)")
            #expect(bounds.maxX <= mark.width && bounds.maxY <= mark.height, "\(mark.name)")
        }
        // Gemini's SVG fills one path four times: blue, then three colours fading out across it.
        let gemini = AgentMark.gemini.layers
        #expect(gemini.count == 4 && Set(gemini.map(\.path)).count == 1)
        #expect(gemini[0].fill == .solid(SRGBColor(red: 0x31 / 255.0, green: 0x86 / 255.0, blue: 1)))
        #expect(gemini[3].fill == .linear(x1: 3.5, y1: 13.5, x2: 17.5, y2: 12, stops: [
            AgentMark.Stop(offset: 0, color: SRGBColor(red: 0xFA / 255.0, green: 0xBC / 255.0, blue: 0x12 / 255.0), opacity: 1),
            AgentMark.Stop(offset: 0.46, color: SRGBColor(red: 0xFA / 255.0, green: 0xBC / 255.0, blue: 0x12 / 255.0), opacity: 0),
        ]))

        // The Blossom's file keeps room around it; the mark is fitted by its drawn shape.
        let blossom = AgentMark.codex.bounds
        #expect(abs(blossom.minX - 118.557) < 0.001 && abs(blossom.maxY - 600.576) < 0.001)
    }

    @Test func marksAreNamedByTheirIconValue() {
        #expect(Icon(parsing: "mark:claude") == .mark("claude"))
        #expect(Icon(parsing: "mark:codex") == .mark("codex"))
        #expect(Icon(parsing: "mark:gemini") == .mark("gemini"))
        #expect(Icon.mark("claude").problem == nil)
        #expect(Icon.mark("copilot").problem
            == "'mark:copilot' is not a mark drip bundles: mark:claude, mark:codex, mark:gemini")
        // Each mark is named for its agent, not its maker.
        #expect(Icon.mark("openai").problem != nil)
        #expect(AgentMark.named("gemini") == .gemini)
        #expect(AgentMark.named("Gemini") == nil)
    }

    @Test func absoluteCommandsReadAsWritten() throws {
        let segments = try PathSegment.parse("M1 2L3 4H5V6C7 8 9 10 11 12Z")
        #expect(segments == [
            .move(1, 2), .line(3, 4), .line(5, 4), .line(5, 6), .cubic(7, 8, 9, 10, 11, 12), .close,
        ])
    }

    @Test func relativeCommandsAndImplicitRepeats() throws {
        // Pairs after a moveto are linetos; numbers run together on signs and second points.
        let segments = try PathSegment.parse("m1 1 2 0-1.5.5l1-1zm4 4h1v1")
        #expect(segments == [
            .move(1, 1), .line(3, 1), .line(1.5, 1.5), .line(2.5, 0.5), .close,
            .move(5, 5), .line(6, 5), .line(6, 6),
        ])
    }

    @Test func smoothCurvesMirrorTheLastControlPoint() throws {
        let cubic = try PathSegment.parse("M0 0C0 1 1 2 2 2S4 3 4 4")
        #expect(cubic.last == .cubic(3, 2, 4, 3, 4, 4))
        // Without a curve before it, S takes the current point as its first control point.
        #expect(try PathSegment.parse("M1 1S2 2 3 3").last == .cubic(1, 1, 2, 2, 3, 3))

        // A quadratic is the cubic with its control points two thirds of the way to the control.
        let quadratic = try PathSegment.parse("M0 0Q3 3 6 0T12 0")
        #expect(quadratic[1] == .cubic(2, 2, 4, 2, 6, 0))
        #expect(quadratic[2] == .cubic(8, -2, 10, -2, 12, 0))
    }

    @Test func arcsBecomeQuarterTurnCubics() throws {
        // A half circle of radius 1 from (0, 0) to (2, 0), over the top with sweep 1 in SVG's
        // downward y: two quarter turns through (1, -1).
        let segments = try PathSegment.parse("M0 0A1 1 0 0 1 2 0")
        #expect(segments.count == 3)
        guard case let .cubic(_, _, _, _, x, y) = segments[1], case let .cubic(_, _, _, _, ex, ey) = segments[2]
        else {
            Issue.record("not cubics: \(segments)")
            return
        }
        #expect(abs(x - 1) < 1e-9 && abs(y + 1) < 1e-9)
        #expect(ex == 2 && ey == 0)
        // Flags may run into the next number, and radii too small to reach are scaled up.
        let compact = try PathSegment.parse("M0 0a.5.5 0 012 0")
        guard case let .cubic(_, _, _, _, cx, cy) = compact[1] else {
            Issue.record("not a cubic: \(compact)")
            return
        }
        #expect(abs(cx - 1) < 1e-9 && abs(cy + 1) < 1e-9)
    }

    @Test func malformedDataThrows() {
        #expect(throws: PathError.self) { try PathSegment.parse("1 2") }
        #expect(throws: PathError.self) { try PathSegment.parse("M1") }
        #expect(throws: PathError.self) { try PathSegment.parse("M1 2X3") }
        #expect(throws: PathError.self) { try PathSegment.parse("M0 0A1 1 0 2 1 2 0") }
    }
}
