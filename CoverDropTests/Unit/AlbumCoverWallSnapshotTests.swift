import Testing
@testable import CoverDrop

struct AlbumCoverWallSnapshotTests {
    @Test("相同 revision 的不同封面墙快照仍有独立身份")
    func snapshotsWithSameRevisionAreNotEqual() {
        let first = AlbumCoverWallSnapshot(
            revision: 1,
            filter: .all,
            normalizedQuery: "",
            cards: []
        )
        let second = AlbumCoverWallSnapshot(
            revision: 1,
            filter: .all,
            normalizedQuery: "",
            cards: []
        )

        #expect(first == first)
        #expect(first != second)
    }

    @Test("详情专属状态不进入封面网格等价键")
    func renderKeyUsesOnlyGridState() {
        let first = AlbumCoverWallRenderKey(
            snapshotRevision: 7,
            filter: .all,
            normalizedQuery: "",
            selectedAlbumIDs: [],
            coverWriteMessages: [:],
            splittingAlbumIDs: []
        )

        #expect(first == first)
        #expect(first != AlbumCoverWallRenderKey(
            snapshotRevision: 8,
            filter: .all,
            normalizedQuery: "",
            selectedAlbumIDs: [],
            coverWriteMessages: [:],
            splittingAlbumIDs: []
        ))
    }

    @Test("聚合搜索复用应用内覆盖容器并扩展到搜索尺寸")
    func aggregateSearchUsesExpandedWorkflowContainer() {
        var presentation = AlbumCoverWorkflowPresentationState()

        #expect(presentation.destination == .albumDetail)
        #expect(presentation.usesAlbumDetailDropZone)
        #expect(presentation.containerSize.width == 680)
        #expect(presentation.containerSize.height == 520)

        presentation.showCoverSearch()

        #expect(presentation.destination == .coverSearch)
        #expect(!presentation.usesAlbumDetailDropZone)
        #expect(presentation.containerSize.width == 1_100)
        #expect(presentation.containerSize.height == 700)
    }

    @Test("关闭搜索或专辑移除都会回到详情目的地")
    func closingSearchOrRemovingAlbumReturnsToDetail() {
        var presentation = AlbumCoverWorkflowPresentationState()
        presentation.showCoverSearch()
        presentation.showAlbumDetail()
        #expect(presentation.destination == .albumDetail)

        presentation.showCoverSearch()
        presentation.handleAlbumRemoval()
        #expect(presentation.destination == .albumDetail)
    }
}
