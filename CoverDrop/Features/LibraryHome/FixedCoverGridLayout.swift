import CoreGraphics

struct FixedCoverGridLayout {
    struct Metrics: Equatable {
        let columnCount: Int
        let columnSpacing: CGFloat
    }

    static let cardWidth: CGFloat = 168
    static let minimumColumnSpacing: CGFloat = 16
    static let horizontalContentPadding: CGFloat = 20
    static let rowSpacing: CGFloat = 16

    static func metrics(forContentWidth contentWidth: CGFloat) -> Metrics {
        let usableWidth = max(0, contentWidth)
        let columnCount = max(
            1,
            Int(
                ((usableWidth + minimumColumnSpacing)
                    / (cardWidth + minimumColumnSpacing))
                    .rounded(.down)
            )
        )

        guard columnCount > 1 else {
            return Metrics(columnCount: 1, columnSpacing: 0)
        }

        let columnSpacing = max(
            minimumColumnSpacing,
            (usableWidth - CGFloat(columnCount) * cardWidth)
                / CGFloat(columnCount - 1)
        )
        return Metrics(columnCount: columnCount, columnSpacing: columnSpacing)
    }
}
