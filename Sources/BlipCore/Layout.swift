#if canImport(CoreGraphics)
// On Darwin, Foundation does not bring in the CoreGraphics overlay that gives CGRect, CGSize and
// CGPoint their Swift initializers, members and Equatable conformance.
import CoreGraphics
#endif
import Foundation

/// The rendering numbers from the spec, scaled for a card size.
public struct CardMetrics: Equatable, Sendable {
    public static let cornerRadius: CGFloat = 14
    public static let borderWidth: CGFloat = 1
    public static let borderAlpha: CGFloat = 0.55
    public static let maxWidth: CGFloat = 640
    public static let fadeInDuration = 0.15
    public static let fadeOutDuration = 0.25
    /// The card's distance from the top or bottom of the screen, as a fraction of its height.
    public static let edgeInsetFraction: CGFloat = 0.12

    public let scale: CGFloat

    public init(size: CardSize) {
        scale = CGFloat(size.scale)
    }

    /// The icon's frame side and its SF Symbol point size.
    public var iconSize: CGFloat { 22 * scale }
    public var titleFontSize: CGFloat { 14 * scale }
    public var detailFontSize: CGFloat { 12 * scale }
    public var leadingPadding: CGFloat { 16 * scale }
    public var iconGap: CGFloat { 10 * scale }
    /// 16 plus 4 to optically balance the round icon.
    public var trailingPadding: CGFloat { 20 * scale }
    public var verticalPadding: CGFloat { 10 * scale }
    /// The gap between the title and the detail line.
    public var detailSpacing: CGFloat { 1 * scale }
}

/// Frames for every element of a card, in a bottom-left-origin coordinate space (AppKit's).
public struct CardLayout: Equatable, Sendable {
    public var size: CGSize
    public var iconFrame: CGRect?
    public var titleFrame: CGRect
    public var detailFrame: CGRect?

    /// Lays out a card from the measured sizes of its labels.
    ///
    /// - Parameters:
    ///   - titleSize: The title label's own fitting size.
    ///   - detailSize: The detail label's own fitting size, or nil for a one-line card.
    ///   - hasIcon: False when the card shows no icon.
    public init(metrics: CardMetrics, titleSize: CGSize, detailSize: CGSize?, hasIcon: Bool) {
        let textX = metrics.leadingPadding + (hasIcon ? metrics.iconSize + metrics.iconGap : 0)
        // Without an icon there is nothing round to balance, so both sides get the leading padding.
        let trailing = hasIcon ? metrics.trailingPadding : metrics.leadingPadding
        let maxTextWidth = CardMetrics.maxWidth - textX - trailing
        let textWidth = min((max(titleSize.width, detailSize?.width ?? 0)).rounded(.up), maxTextWidth)
        let width = min((textX + textWidth + trailing).rounded(.up), CardMetrics.maxWidth)
        // The text column takes any fraction of a point the width was rounded up by.
        let columnWidth = width - textX - trailing

        let textHeight = titleSize.height + (detailSize.map { metrics.detailSpacing + $0.height } ?? 0)
        let contentHeight = max(textHeight, metrics.iconSize)
        let height = (contentHeight + 2 * metrics.verticalPadding).rounded(.up)
        let textY = ((height - textHeight) / 2).rounded()

        size = CGSize(width: width, height: height)
        iconFrame = hasIcon
            ? CGRect(
                x: metrics.leadingPadding,
                y: (height - metrics.iconSize) / 2,
                width: metrics.iconSize,
                height: metrics.iconSize)
            : nil
        if let detailSize {
            detailFrame = CGRect(x: textX, y: textY, width: columnWidth, height: detailSize.height)
            titleFrame = CGRect(
                x: textX,
                y: textY + detailSize.height + metrics.detailSpacing,
                width: columnWidth,
                height: titleSize.height)
        } else {
            detailFrame = nil
            titleFrame = CGRect(x: textX, y: textY, width: columnWidth, height: titleSize.height)
        }
    }

    /// The card's window origin on a screen, rounded to whole points.
    ///
    /// - Parameter visibleFrame: The target screen's visible frame (without menu bar and Dock).
    public static func origin(for size: CGSize, in visibleFrame: CGRect, position: Position) -> CGPoint {
        let inset = visibleFrame.height * CardMetrics.edgeInsetFraction
        let x = visibleFrame.midX - size.width / 2
        let y: CGFloat
        switch position {
        case .bottom: y = visibleFrame.minY + inset
        case .center: y = visibleFrame.midY - size.height / 2
        case .top: y = visibleFrame.maxY - inset - size.height
        }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }
}
