import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CoverDrop

struct CoverSearchResultDragItemProviderTests {
    @Test("聚合搜索结果拖拽 provider 同时提供图片和 URL representation")
    func providerIncludesImageAndURLRepresentations() throws {
        let result = CoverSearchResult(
            id: "douban-1401853",
            sourceName: "豆瓣",
            albumName: "七里香",
            artistName: "周杰伦",
            thumbnailURL: URL(string: "https://img9.doubanio.com/view/subject/m/public/s3737076.jpg")!,
            imageURL: URL(string: "https://img9.doubanio.com/view/subject/l/public/s3737076.jpg")!,
            externalURL: URL(string: "https://music.douban.com/subject/1401853/")
        )

        let provider = CoverSearchResultDragItemProvider.provider(for: result)

        #expect(provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier))
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.url.identifier))
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier))
    }
}
