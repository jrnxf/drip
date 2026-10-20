import DripCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif
import Testing

struct LayoutTests {
    private let regular = CardMetrics(size: .regular)

    @Test func metricsMatchTheSpecAtEachSize() {
        #expect(regular.iconSize == 22)
        #expect(regular.titleFontSize == 14)
        #expect(regular.detailFontSize == 12)
        #expect(regular.leadingPadding == 16)
        #expect(regular.iconGap == 10)
        #expect(regular.trailingPadding == 20)
        #expect(regular.verticalPadding == 10)
        #expect(regular.detailSpacing == 1)
        #expect(CardMetrics.cornerRadius == 14)
        #expect(CardMetrics.borderWidth == 1)
        #expect(CardMetrics.borderAlpha == 0.55)
        #expect(CardMetrics.maxWidth == 640)
        #expect(CardMetrics.fadeInDuration == 0.15)
        #expect(CardMetrics.fadeOutDuration == 0.25)

        let compact = CardMetrics(size: .compact)
        #expect(abs(compact.iconSize - 22 * 0.85) <= 1e-9)
        #expect(abs(compact.titleFontSize - 14 * 0.85) <= 1e-9)
        #expect(abs(compact.trailingPadding - 20 * 0.85) <= 1e-9)
        let large = CardMetrics(size: .large)
        #expect(large.iconSize == 27.5)
        #expect(large.detailFontSize == 15)
        #expect(large.verticalPadding == 12.5)
    }

    @Test func twoLineCard() {
        let layout = CardLayout(
            metrics: regular, titleSize: CGSize(width: 100, height: 17),
            detailSize: CGSize(width: 149.5, height: 15), hasIcon: true)
        // 16 + 22 + 10 + ceil(149.5) + 20
        #expect(layout.size == CGSize(width: 218, height: 53))
        #expect(layout.iconFrame == CGRect(x: 16, y: 15.5, width: 22, height: 22))
        #expect(layout.detailFrame == CGRect(x: 48, y: 10, width: 150, height: 15))
        #expect(layout.titleFrame == CGRect(x: 48, y: 26, width: 150, height: 17))
    }

    @Test func oneLineCardIsAtLeastIconHigh() {
        let layout = CardLayout(
            metrics: regular, titleSize: CGSize(width: 80, height: 17), detailSize: nil, hasIcon: true)
        #expect(layout.size == CGSize(width: 148, height: 42))
        #expect(layout.iconFrame == CGRect(x: 16, y: 10, width: 22, height: 22))
        #expect(layout.titleFrame == CGRect(x: 48, y: 13, width: 80, height: 17))
        #expect(layout.detailFrame == nil)
    }

    @Test func widthFollowsTheWiderLine() {
        let layout = CardLayout(
            metrics: regular, titleSize: CGSize(width: 300, height: 17),
            detailSize: CGSize(width: 120, height: 15), hasIcon: true)
        #expect(layout.size.width == 368)
    }

    @Test func widthIsCappedAt640() {
        let layout = CardLayout(
            metrics: regular, titleSize: CGSize(width: 2000, height: 17),
            detailSize: CGSize(width: 900, height: 15), hasIcon: true)
        #expect(layout.size.width == 640)
        // Typed: #expect compares an untyped `640 - 48 - 20` with a CGFloat as unequal.
        let column: CGFloat = 640 - 48 - 20
        #expect(layout.titleFrame.width == column)
        #expect(layout.detailFrame?.width == column)
        #expect(layout.titleFrame.maxX == 620)
    }

    /// Text wraps at the widest column a card has: the one it gets at the 640-point cap.
    @Test func textWrapsAtTheWidestColumn() {
        // Typed, as in widthIsCappedAt640.
        let withIcon: CGFloat = 640 - 48 - 20, withoutIcon: CGFloat = 640 - 16 - 16
        #expect(CardLayout.maxTextWidth(metrics: regular, hasIcon: true) == withIcon)
        #expect(CardLayout.maxTextWidth(metrics: regular, hasIcon: false) == withoutIcon)
        #expect(CardLayout.maxTextWidth(metrics: regular, hasIcon: false, leadingInset: 4) == withoutIcon - 4)
        let capped = CardLayout(
            metrics: regular, titleSize: CGSize(width: 2000, height: 17), detailSize: nil, hasIcon: true)
        #expect(capped.titleFrame.width == CardLayout.maxTextWidth(metrics: regular, hasIcon: true))
    }

    /// A wrapped title of two lines and a detail of three: the card grows to hold them, and the icon
    /// stays centered.
    @Test func wrappedTextMakesATallerCard() {
        let layout = CardLayout(
            metrics: regular, titleSize: CGSize(width: 572, height: 34), detailSize: CGSize(width: 560, height: 45),
            hasIcon: true)
        #expect(layout.size == CGSize(width: 640, height: 34 + 1 + 45 + 20))
        #expect(layout.detailFrame == CGRect(x: 48, y: 10, width: 572, height: 45))
        #expect(layout.titleFrame == CGRect(x: 48, y: 56, width: 572, height: 34))
        #expect(layout.iconFrame?.midY == layout.size.height / 2)
    }

    @Test func cardWithoutIconUsesEqualPadding() {
        let layout = CardLayout(
            metrics: regular, titleSize: CGSize(width: 80, height: 17), detailSize: nil, hasIcon: false)
        #expect(layout.iconFrame == nil)
        #expect(layout.size == CGSize(width: 112, height: 42))
        #expect(layout.titleFrame.minX == 16)
        #expect(layout.size.width - layout.titleFrame.maxX == 16)
    }

    @Test func everySizeGivesWholePointCardsWithBalancedPadding() throws {
        for size in CardSize.allCases {
            let metrics = CardMetrics(size: size)
            let layout = CardLayout(
                metrics: metrics, titleSize: CGSize(width: 123.4, height: 16.6),
                detailSize: CGSize(width: 99.9, height: 14.2), hasIcon: true)
            #expect(layout.size.width == layout.size.width.rounded(), "\(size)")
            #expect(layout.size.height == layout.size.height.rounded(), "\(size)")
            let detail = try #require(layout.detailFrame)
            #expect(detail.minY == detail.minY.rounded(), "\(size)")
            let icon = try #require(layout.iconFrame)
            #expect(abs(icon.minX - metrics.leadingPadding) <= 1e-9, "\(size)")
            #expect(abs(icon.midY - layout.size.height / 2) <= 1e-9, "\(size)")
            #expect(abs(layout.titleFrame.minX - (metrics.leadingPadding + metrics.iconSize + metrics.iconGap)) <= 1e-9, "\(size)")
            // Rounding the width up gives the text column under one extra point, never less room.
            let trailing = layout.size.width - layout.titleFrame.maxX
            #expect(trailing >= metrics.trailingPadding - 1e-9, "\(size)")
            #expect(trailing < metrics.trailingPadding + 1, "\(size)")
            #expect(layout.titleFrame.width >= 123.4, "\(size)")
            // The text block is centered vertically to within half a point.
            let textMid = (detail.minY + layout.titleFrame.maxY) / 2
            #expect(abs(textMid - layout.size.height / 2) <= 0.5, "\(size)")
        }
    }

    @Test func originAtEachPosition() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let size = CGSize(width: 218, height: 53)
        #expect(CardLayout.origin(for: size, in: screen, position: .bottom) == CGPoint(x: 611, y: 130))
        #expect(CardLayout.origin(for: size, in: screen, position: .center) == CGPoint(x: 611, y: 436))
        #expect(CardLayout.origin(for: size, in: screen, position: .top) == CGPoint(x: 611, y: 742))
    }

    @Test func originIsRoundedToWholePoints() {
        let screen = CGRect(x: -1512, y: 0, width: 1512, height: 945)
        let origin = CardLayout.origin(for: CGSize(width: 217, height: 53), in: screen, position: .bottom)
        // midX -756 minus 108.5 is -864.5, and 12% of 945 is 113.4.
        #expect(origin == CGPoint(x: -865, y: 113))
        #expect(origin.x == origin.x.rounded())
        #expect(origin.y == origin.y.rounded())
    }

    @Test func rightToLeftDetection() {
        #expect(CardText.isRightToLeft("שלום עולם"))
        #expect(CardText.isRightToLeft("مرحبا"))
        #expect(CardText.isRightToLeft("123 שלום"))
        #expect(!(CardText.isRightToLeft("hello שלום")))
        #expect(!CardText.isRightToLeft("ビルド完了"))
        #expect(!(CardText.isRightToLeft("🎉 done")))
        #expect(!CardText.isRightToLeft(""))
    }
}
