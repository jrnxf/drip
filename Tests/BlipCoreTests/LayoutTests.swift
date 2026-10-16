import BlipCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import XCTest

final class LayoutTests: XCTestCase {
    private let regular = CardMetrics(size: .regular)

    func testMetricsMatchTheSpecAtEachSize() {
        XCTAssertEqual(regular.iconSize, 22)
        XCTAssertEqual(regular.titleFontSize, 14)
        XCTAssertEqual(regular.detailFontSize, 12)
        XCTAssertEqual(regular.leadingPadding, 16)
        XCTAssertEqual(regular.iconGap, 10)
        XCTAssertEqual(regular.trailingPadding, 20)
        XCTAssertEqual(regular.verticalPadding, 10)
        XCTAssertEqual(regular.detailSpacing, 1)
        XCTAssertEqual(CardMetrics.cornerRadius, 14)
        XCTAssertEqual(CardMetrics.borderWidth, 1)
        XCTAssertEqual(CardMetrics.borderAlpha, 0.55)
        XCTAssertEqual(CardMetrics.maxWidth, 640)
        XCTAssertEqual(CardMetrics.fadeInDuration, 0.15)
        XCTAssertEqual(CardMetrics.fadeOutDuration, 0.25)

        let compact = CardMetrics(size: .compact)
        XCTAssertEqual(compact.iconSize, 22 * 0.85, accuracy: 1e-9)
        XCTAssertEqual(compact.titleFontSize, 14 * 0.85, accuracy: 1e-9)
        XCTAssertEqual(compact.trailingPadding, 20 * 0.85, accuracy: 1e-9)
        let large = CardMetrics(size: .large)
        XCTAssertEqual(large.iconSize, 27.5)
        XCTAssertEqual(large.detailFontSize, 15)
        XCTAssertEqual(large.verticalPadding, 12.5)
    }

    func testTwoLineCard() {
        let layout = CardLayout(
            metrics: regular, titleSize: CGSize(width: 100, height: 17),
            detailSize: CGSize(width: 149.5, height: 15), hasIcon: true)
        // 16 + 22 + 10 + ceil(149.5) + 20
        XCTAssertEqual(layout.size, CGSize(width: 218, height: 53))
        XCTAssertEqual(layout.iconFrame, CGRect(x: 16, y: 15.5, width: 22, height: 22))
        XCTAssertEqual(layout.detailFrame, CGRect(x: 48, y: 10, width: 150, height: 15))
        XCTAssertEqual(layout.titleFrame, CGRect(x: 48, y: 26, width: 150, height: 17))
    }

    func testOneLineCardIsAtLeastIconHigh() {
        let layout = CardLayout(
            metrics: regular, titleSize: CGSize(width: 80, height: 17), detailSize: nil, hasIcon: true)
        XCTAssertEqual(layout.size, CGSize(width: 148, height: 42))
        XCTAssertEqual(layout.iconFrame, CGRect(x: 16, y: 10, width: 22, height: 22))
        XCTAssertEqual(layout.titleFrame, CGRect(x: 48, y: 13, width: 80, height: 17))
        XCTAssertNil(layout.detailFrame)
    }

    func testWidthFollowsTheWiderLine() {
        let layout = CardLayout(
            metrics: regular, titleSize: CGSize(width: 300, height: 17),
            detailSize: CGSize(width: 120, height: 15), hasIcon: true)
        XCTAssertEqual(layout.size.width, 368)
    }

    func testWidthIsCappedAt640() {
        let layout = CardLayout(
            metrics: regular, titleSize: CGSize(width: 2000, height: 17),
            detailSize: CGSize(width: 900, height: 15), hasIcon: true)
        XCTAssertEqual(layout.size.width, 640)
        XCTAssertEqual(layout.titleFrame.width, 640 - 48 - 20)
        XCTAssertEqual(layout.detailFrame?.width, 640 - 48 - 20)
        XCTAssertEqual(layout.titleFrame.maxX, 620)
    }

    func testCardWithoutIconUsesEqualPadding() {
        let layout = CardLayout(
            metrics: regular, titleSize: CGSize(width: 80, height: 17), detailSize: nil, hasIcon: false)
        XCTAssertNil(layout.iconFrame)
        XCTAssertEqual(layout.size, CGSize(width: 112, height: 42))
        XCTAssertEqual(layout.titleFrame.minX, 16)
        XCTAssertEqual(layout.size.width - layout.titleFrame.maxX, 16)
    }

    func testEverySizeGivesWholePointCardsWithBalancedPadding() throws {
        for size in CardSize.allCases {
            let metrics = CardMetrics(size: size)
            let layout = CardLayout(
                metrics: metrics, titleSize: CGSize(width: 123.4, height: 16.6),
                detailSize: CGSize(width: 99.9, height: 14.2), hasIcon: true)
            XCTAssertEqual(layout.size.width, layout.size.width.rounded(), "\(size)")
            XCTAssertEqual(layout.size.height, layout.size.height.rounded(), "\(size)")
            let detail = try XCTUnwrap(layout.detailFrame)
            XCTAssertEqual(detail.minY, detail.minY.rounded(), "\(size)")
            let icon = try XCTUnwrap(layout.iconFrame)
            XCTAssertEqual(icon.minX, metrics.leadingPadding, accuracy: 1e-9, "\(size)")
            XCTAssertEqual(icon.midY, layout.size.height / 2, accuracy: 1e-9, "\(size)")
            XCTAssertEqual(layout.titleFrame.minX, metrics.leadingPadding + metrics.iconSize + metrics.iconGap,
                           accuracy: 1e-9, "\(size)")
            // Rounding the width up gives the text column under one extra point, never less room.
            let trailing = layout.size.width - layout.titleFrame.maxX
            XCTAssertGreaterThanOrEqual(trailing, metrics.trailingPadding - 1e-9, "\(size)")
            XCTAssertLessThan(trailing, metrics.trailingPadding + 1, "\(size)")
            XCTAssertGreaterThanOrEqual(layout.titleFrame.width, 123.4, "\(size)")
            // The text block is centered vertically to within half a point.
            let textMid = (detail.minY + layout.titleFrame.maxY) / 2
            XCTAssertEqual(textMid, layout.size.height / 2, accuracy: 0.5, "\(size)")
        }
    }

    func testOriginAtEachPosition() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let size = CGSize(width: 218, height: 53)
        XCTAssertEqual(CardLayout.origin(for: size, in: screen, position: .bottom), CGPoint(x: 611, y: 130))
        XCTAssertEqual(CardLayout.origin(for: size, in: screen, position: .center), CGPoint(x: 611, y: 436))
        XCTAssertEqual(CardLayout.origin(for: size, in: screen, position: .top), CGPoint(x: 611, y: 742))
    }

    func testOriginIsRoundedToWholePoints() {
        let screen = CGRect(x: -1512, y: 0, width: 1512, height: 945)
        let origin = CardLayout.origin(for: CGSize(width: 217, height: 53), in: screen, position: .bottom)
        // midX -756 minus 108.5 is -864.5, and 12% of 945 is 113.4.
        XCTAssertEqual(origin, CGPoint(x: -865, y: 113))
        XCTAssertEqual(origin.x, origin.x.rounded())
        XCTAssertEqual(origin.y, origin.y.rounded())
    }

    func testRightToLeftDetection() {
        XCTAssertTrue(CardText.isRightToLeft("שלום עולם"))
        XCTAssertTrue(CardText.isRightToLeft("مرحبا"))
        XCTAssertTrue(CardText.isRightToLeft("123 שלום"))
        XCTAssertFalse(CardText.isRightToLeft("hello שלום"))
        XCTAssertFalse(CardText.isRightToLeft("ビルド完了"))
        XCTAssertFalse(CardText.isRightToLeft("🎉 done"))
        XCTAssertFalse(CardText.isRightToLeft(""))
    }
}
