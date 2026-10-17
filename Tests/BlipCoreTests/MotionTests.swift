import BlipCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing

struct SpringTests {
    @Test func matchesCASpringAnimationsParameters() {
        let spring = Spring(duration: 0.5, bounce: 0.2)
        #expect(abs(spring.stiffness - pow(2 * .pi / 0.5, 2)) < 1e-9)
        #expect(abs(spring.damping - 4 * .pi * 0.8 / 0.5) < 1e-9)
    }

    @Test func startsAtZeroAndSettlesAtOne() {
        for spring in [Spring(duration: 0.3), Spring(duration: 0.5, bounce: 0.2), Spring(duration: 0.55, bounce: 0.25)] {
            #expect(spring.progress(at: 0) == 0)
            #expect(spring.progress(at: -1) == 0)
            let settled = spring.settlingTime
            #expect(settled > 0 && settled < 4 * spring.duration)
            for time in stride(from: settled, to: settled + 1, by: 0.01) {
                #expect(abs(1 - spring.progress(at: time)) <= 0.001, "\(spring) at \(time)")
            }
        }
    }

    @Test func onlyABouncySpringOvershoots() {
        let calm = Spring(duration: 0.3)
        let bouncy = Spring(duration: 0.5, bounce: 0.3)
        let times = stride(from: 0.0, to: 2, by: 0.005)
        #expect(times.allSatisfy { calm.progress(at: $0) <= 1 })
        #expect(times.contains { bouncy.progress(at: $0) > 1.02 })
    }

    @Test func aValueKeepsItsPathAndVelocityWhenRetargeted() {
        var value = SpringValue(0)
        let spring = Spring(duration: 0.4, bounce: 0.15)
        value.animate(to: 100, with: spring, at: 0)
        let before = (value.value(at: 0.1), value.value(at: 0.1) - value.value(at: 0.099))
        value.animate(to: 40, with: spring, at: 0.1)
        let after = (value.value(at: 0.1), value.value(at: 0.1) - value.value(at: 0.099))
        #expect(abs(before.0 - after.0) < 1e-9)
        #expect(abs(before.1 - after.1) < 1e-9)
        #expect(value.target == 40)
        #expect(abs(value.value(at: 3) - 40) < 0.2)
        #expect(value.end == 0.1 + spring.settlingTime)
        value.jump(to: 7)
        #expect(value.value(at: 0.2) == 7)
        #expect(value.end == nil)
    }
}

struct WashPaletteTests {
    private let accents: [SRGBColor] = [
        SRGBColor(red: 0.204, green: 0.78, blue: 0.349), // systemGreen
        SRGBColor(red: 1, green: 0.584, blue: 0), // systemOrange
        SRGBColor(red: 1, green: 0.231, blue: 0.188), // systemRed
        SRGBColor(red: 0, green: 0.478, blue: 1), // systemBlue
        SRGBColor(red: 1, green: 0.8, blue: 0), // systemYellow
        SRGBColor(red: 0.655, green: 0.545, blue: 0.98), // #a78bfa
        .white,
    ]

    @Test func whiteTextReadsOnEveryAccent() {
        for accent in accents {
            let palette = WashPalette(accent: accent)
            #expect(SRGBColor.white.contrast(with: palette.top) >= WashPalette.minimumContrast, "\(accent)")
            #expect(WashPalette.detailColor(on: palette.top).contrast(with: palette.top) >= WashPalette.minimumContrast,
                    "\(accent)")
            #expect(palette.bottom.luminance < palette.top.luminance)
        }
    }

    @Test func darkAccentsAreBarelyDarkened() {
        let navy = SRGBColor(red: 0.1, green: 0.1, blue: 0.3)
        #expect(WashPalette(accent: navy).top == navy.mixed(with: .black, 0.12))
    }

    @Test func contrastMatchesWCAG() {
        #expect(abs(SRGBColor.white.contrast(with: .black) - 21) < 1e-9)
        #expect(SRGBColor.white.contrast(with: .white) == 1)
    }
}

struct IslandTests {
    private let metrics = IslandMetrics(
        notchWidth: 185, notchHeight: 32, textWidth: 180, textHeight: 34, compactTitleWidth: 90)

    @Test func everyMotionOpensToItsShapeAndClosesBackIntoTheNotch() {
        for motion in NotchMotion.allCases {
            var animator = IslandAnimator(motion: motion, metrics: metrics)
            let rest = animator.shape(at: 0)
            _ = animator.enter(at: 0)
            let open = animator.shape(at: animator.end)
            var reference = IslandAnimator(motion: motion, metrics: metrics)
            reference.open()
            let expected = reference.shape(at: 0)
            #expect(abs(open.left - expected.left) < 0.5, "\(motion)")
            #expect(abs(open.right - expected.right) < 0.5, "\(motion)")
            #expect(abs(open.height - expected.height) < 0.5, "\(motion)")
            #expect(abs(open.pillWidth - expected.pillWidth) < 0.5, "\(motion)")
            #expect(abs(open.progress - 1) < 0.001, "\(motion)")

            let leaving = animator.end
            _ = animator.exit(at: leaving)
            let closed = animator.shape(at: animator.end)
            #expect(abs(closed.left - rest.left) < 0.5, "\(motion)")
            #expect(abs(closed.right - rest.right) < 0.5, "\(motion)")
            #expect(abs(closed.height - rest.height) < 0.5, "\(motion)")
            if motion == .droplet {
                // Swallowed whole: hidden in the notch and too deep to make it bulge.
                #expect(!DropletField(metrics: metrics, shape: closed).touchesNotch)
                #expect(closed.pillTop + closed.pillHeight < metrics.notchHeight)
            }
            #expect(animator.end - leaving < leaving, "\(motion): the exit must be quicker than the entrance")
        }
    }

    @Test func exitsNeverOvershootTheNotch() {
        for motion in [NotchMotion.snap, .ears] {
            var animator = IslandAnimator(motion: motion, metrics: metrics)
            animator.open()
            _ = animator.exit(at: 0)
            for time in stride(from: 0.0, to: animator.end, by: 0.005) {
                let shape = animator.shape(at: time)
                #expect(shape.right >= metrics.notchWidth / 2 - 0.01, "\(motion) at \(time)")
                #expect(shape.height >= metrics.notchHeight - 0.01, "\(motion) at \(time)")
            }
        }
    }

    /// The loops traced below the notch: one while the drop hangs from it, two once it has broken free.
    private func loopsBelowNotch(_ shape: IslandShape) -> Int {
        loopsBelowNotch(shape, metrics: metrics)
    }

    private func loopsBelowNotch(_ shape: IslandShape, metrics: IslandMetrics) -> Int {
        let field = DropletField(metrics: metrics, shape: shape)
        guard field.touchesNotch else { return shape.pillTop > metrics.notchHeight ? 2 : 1 }
        return field.outline(above: metrics.notchHeight - 4, cell: 0.5).count
    }

    @Test func theDropHangsOnANeckThenPinchesOff() {
        var animator = IslandAnimator(motion: .droplet, metrics: metrics)
        #expect(!DropletField(metrics: metrics, shape: animator.shape(at: 0)).touchesNotch)
        _ = animator.enter(at: 0)
        let times = Array(stride(from: 0.0, to: animator.end, by: 0.004))
        let loops = times.map { loopsBelowNotch(animator.shape(at: $0)) }
        // Hanging: still one piece with the notch while the drop's top is already below it.
        let hanging = times.indices.first { loops[$0] == 1 && animator.shape(at: times[$0]).pillTop > metrics.notchHeight }
        let free = loops.firstIndex(of: 2)
        #expect(hanging != nil && free != nil && free! > hanging!, "the drop must hang before it breaks free")
        #expect(!loops[(free ?? 0)...].contains(1), "once free, the drop never rejoins the notch")
        #expect(!DropletField(metrics: metrics, shape: animator.shape(at: animator.end)).touchesNotch)
    }

    @Test func theNotchReachesForTheRisingDropAndSwallowsIt() {
        var animator = IslandAnimator(motion: .droplet, metrics: metrics)
        animator.open()
        _ = animator.exit(at: 0)
        let loops = stride(from: 0.0, to: animator.end, by: 0.004).map { loopsBelowNotch(animator.shape(at: $0)) }
        let merged = loops.firstIndex(of: 1)
        #expect(merged != nil)
        #expect(!loops[(merged ?? 0)...].contains(2), "once merged, the drop never breaks away again")
    }

    @Test func theIconLeavesOnlyOnceTheRoundDropRisesAndIsGoneBeforeItMerges() throws {
        let wide = IslandMetrics(
            notchWidth: 200, notchHeight: 37, scale: 1.2, textWidth: 520, textHeight: 34, compactTitleWidth: 90)
        for metrics in [self.metrics, wide] {
            var animator = IslandAnimator(motion: .droplet, metrics: metrics)
            animator.open()
            let open = animator.shape(at: 0)
            let cues = animator.exit(at: 0)
            func icon(at time: Double) -> Double {
                IslandCues.opacity(leaving: cues.icon, over: cues.iconFadeOut, at: time)
            }
            let times = Array(stride(from: 0.0, to: animator.end, by: 0.002))
            for time in times {
                let shape = animator.shape(at: time)
                let center = shape.pillTop + shape.pillHeight / 2
                let openCenter = open.pillTop + open.pillHeight / 2
                if center >= openCenter - 1e-6 {
                    // Still gathering where the capsule was: the icon shows in full.
                    #expect(icon(at: time) >= 0.999, "\(metrics.textWidth) at \(time)")
                }
                if icon(at: time) < 0.999 {
                    // Fading: the drop is round and on its way up.
                    #expect(shape.pillWidth <= metrics.dropSize + 2 * metrics.scale, "\(metrics.textWidth) at \(time)")
                    #expect(center < openCenter, "\(metrics.textWidth) at \(time)")
                }
                if center < openCenter, loopsBelowNotch(shape, metrics: metrics) == 1 {
                    #expect(icon(at: time) == 0, "\(metrics.textWidth) at \(time): merged with the icon showing")
                }
            }
            // It does fade, and only after the capsule has gathered into a drop.
            let fading = try #require(times.first { icon(at: $0) < 1 })
            #expect(fading > 0.2, "\(metrics.textWidth)")
        }
    }

    @Test func theFallingDropOutgrowsItsNeck() throws {
        // A real drop's bulb is wider than the neck it hangs from just before it breaks.
        var animator = IslandAnimator(motion: .droplet, metrics: metrics)
        _ = animator.enter(at: 0)
        let times = Array(stride(from: 0.0, to: 0.6, by: 0.002))
        let last = try #require(times.last { loopsBelowNotch(animator.shape(at: $0)) == 1 && $0 > 0.05 })
        let shape = animator.shape(at: last)
        let field = DropletField(metrics: metrics, shape: shape)
        let neckY = metrics.notchHeight + 0.5 * (shape.pillTop - metrics.notchHeight)
        let neck = stride(from: -30.0, to: 30, by: 0.1).filter { field.value(x: $0, y: neckY) < 0 }.count
        let bulb = stride(from: -30.0, to: 30, by: 0.1)
            .filter { field.value(x: $0, y: shape.pillTop + shape.pillHeight / 2) < 0 }.count
        #expect(neck < bulb / 2, "neck \(neck) bulb \(bulb)")
    }

    @Test func shouldersGrowWithTheOverhang() {
        #expect(IslandShape.shoulder(overhang: 0) == 0)
        #expect(IslandShape.shoulder(overhang: -5) == 0)
        #expect(IslandShape.shoulder(overhang: 8) == IslandShape.maxShoulder / 2)
        #expect(IslandShape.shoulder(overhang: 100) == IslandShape.maxShoulder)
    }

    @Test func cornersGrowFromTheNotchsToTheCards() {
        let notch = IslandShape(left: -92.5, right: 92.5, height: 32, pillTop: 0, pillWidth: 0, pillHeight: 0, progress: 0)
        #expect(notch.radius(metrics) == metrics.notchRadius)
        let card = IslandShape(
            left: -150, right: 150, height: metrics.cardHeight, pillTop: 0, pillWidth: 0, pillHeight: 0, progress: 1)
        #expect(card.radius(metrics) == metrics.cardRadius)
    }

    @Test func contentSitsInsideTheShape() {
        for motion in NotchMotion.allCases {
            var animator = IslandAnimator(motion: motion, metrics: metrics)
            animator.open()
            let shape = animator.shape(at: 0)
            let content = animator.content(for: shape)
            switch motion {
            case .droplet:
                #expect(content.iconCenter.x - content.iconSize / 2 > -shape.pillWidth / 2)
                #expect(content.ringCenter.x + content.ringSize / 2 < shape.pillWidth / 2)
                #expect(content.textX + metrics.textWidth < content.ringCenter.x)
            case .snap:
                #expect(content.iconCenter.x - content.iconSize / 2 > shape.left)
                #expect(content.ringCenter.x + content.ringSize / 2 < shape.right)
                #expect(content.textCenterY > metrics.notchHeight)
            case .ears:
                #expect(content.compact)
                #expect(content.iconCenter.x < -metrics.notchWidth / 2)
                #expect(content.textX > metrics.notchWidth / 2)
                #expect(content.textX + metrics.compactTitleWidth < shape.right)
            }
        }
    }

    @Test func earsHaveNoRingAndCueTheTextAfterTheIcon() {
        var animator = IslandAnimator(motion: .ears, metrics: metrics)
        let cues = animator.enter(at: 0)
        #expect(cues.ring == nil)
        #expect(cues.detail == nil)
        #expect((cues.icon ?? 1) < (cues.title ?? 0))
    }
}

struct DropletOutlineTests {
    @Test func aTracedCircleIsRoundAndWoundLikeTheNotch() throws {
        let metrics = IslandMetrics(
            notchWidth: 185, notchHeight: 32, textWidth: 180, textHeight: 34, compactTitleWidth: 90)
        let shape = IslandShape(
            left: -92.5, right: 92.5, height: 32, pillTop: 60, pillWidth: 20, pillHeight: 20, progress: 0, blend: 24)
        let loops = DropletField(metrics: metrics, shape: shape).outline(above: 28, cell: 0.25)
        let circle = try #require(loops.first { $0.allSatisfy { $0.y > 40 } })
        for point in circle {
            #expect(abs(((point.x * point.x) + (point.y - 70) * (point.y - 70)).squareRoot() - 10) < 0.05)
        }
        // Negative in y-down coordinates, like the notch's path: down the left, up the right.
        func area(_ loop: [IslandPoint]) -> Double {
            loop.indices.reduce(0) { sum, i in
                let a = loop[i], b = loop[(i + 1) % loop.count]
                return sum + a.x * b.y - b.x * a.y
            }
        }
        #expect(loops.allSatisfy { area($0) < 0 })
    }
}

struct TerminalLayoutTests {
    @Test func theEyebrowSitsAboveTheTitleAndTheStripeInsetsTheText() throws {
        let metrics = CardMetrics(size: .regular)
        let plain = CardLayout(
            metrics: metrics, titleSize: CGSize(width: 120, height: 17), detailSize: CGSize(width: 90, height: 15),
            hasIcon: false)
        let terminal = CardLayout(
            metrics: metrics, titleSize: CGSize(width: 120, height: 17), detailSize: CGSize(width: 90, height: 15),
            hasIcon: false, eyebrowSize: CGSize(width: 20, height: 13), leadingInset: 4)
        #expect(plain.eyebrowFrame == nil)
        let eyebrow = try #require(terminal.eyebrowFrame)
        #expect(eyebrow.minY == terminal.titleFrame.maxY + metrics.detailSpacing)
        #expect(terminal.titleFrame.minX == plain.titleFrame.minX + 4)
        #expect(terminal.size.width == plain.size.width + 4)
        #expect(terminal.size.height > plain.size.height)
        #expect(eyebrow.maxY <= terminal.size.height - metrics.verticalPadding + 1)
    }

    @Test func everyStyleHasItsOwnCorners() {
        #expect(CardStyle.hud.cornerRadius == CardMetrics.cornerRadius)
        #expect(Set(CardStyle.allCases.map(\.cornerRadius)).count == CardStyle.allCases.count)
    }
}
