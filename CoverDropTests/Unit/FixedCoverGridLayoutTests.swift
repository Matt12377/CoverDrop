import CoreGraphics
import Testing
@testable import CoverDrop

struct FixedCoverGridLayoutTests {
    @Test("封面卡片宽度固定为 168pt")
    func cardWidthIsFixed() {
        #expect(FixedCoverGridLayout.cardWidth == 168)
    }

    @Test("窗口变宽但列数不变时只增加列间距")
    func widerContentExpandsSpacingWithoutChangingColumnCount() {
        let compact = FixedCoverGridLayout.metrics(forContentWidth: 1_092)
        let expanded = FixedCoverGridLayout.metrics(forContentWidth: 1_200)

        #expect(compact.columnCount == 6)
        #expect(expanded.columnCount == 6)
        #expect(expanded.columnSpacing > compact.columnSpacing)
    }

    @Test("达到阈值后新增一列且列间距不小于最小值")
    func addsColumnAtThresholdWithoutReducingSpacingBelowMinimum() {
        let beforeThreshold = FixedCoverGridLayout.metrics(forContentWidth: 1_271)
        let atThreshold = FixedCoverGridLayout.metrics(forContentWidth: 1_272)

        #expect(beforeThreshold.columnCount == 6)
        #expect(atThreshold.columnCount == 7)
        #expect(atThreshold.columnSpacing >= FixedCoverGridLayout.minimumColumnSpacing)
    }

    @Test("窄窗口退化为单列")
    func narrowContentUsesSingleColumn() {
        let metrics = FixedCoverGridLayout.metrics(forContentWidth: 167)

        #expect(metrics.columnCount == 1)
        #expect(metrics.columnSpacing == 0)
    }
}
