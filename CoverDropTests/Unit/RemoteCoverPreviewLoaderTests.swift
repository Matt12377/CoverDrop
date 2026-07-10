import Foundation
import Testing
@testable import CoverDrop

struct RemoteCoverPreviewLoaderTests {
    @Test("聚合结果列表预览使用缩略图 URL")
    func previewURLUsesThumbnailURL() throws {
        let thumbnailURL = try #require(URL(string: "https://example.com/cover-100.jpg"))
        let imageURL = try #require(URL(string: "https://example.com/cover-1200.jpg"))
        let result = CoverSearchResult(
            id: "sample",
            sourceName: "测试",
            albumName: "专辑",
            artistName: "艺人",
            thumbnailURL: thumbnailURL,
            imageURL: imageURL,
            externalURL: nil
        )

        #expect(RemoteCoverPreviewLoader.previewURL(for: result) == thumbnailURL)
    }

    @Test("聚合结果封面预览请求复用豆瓣图片 Referer 规则")
    func previewRequestUsesDoubanReferer() throws {
        let url = try #require(URL(string: "https://img9.doubanio.com/view/subject/l/public/s3737076.jpg"))

        let request = RemoteCoverPreviewLoader.previewImageRequest(for: url)

        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://music.douban.com/")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
        #expect(request.value(forHTTPHeaderField: "Accept")?.contains("image/") == true)
    }

    @Test("聚合结果封面预览请求允许复用缓存")
    func previewRequestCanReuseCachedData() throws {
        let url = try #require(URL(string: "https://example.com/cover-100.jpg"))

        let request = RemoteCoverPreviewLoader.previewImageRequest(for: url)

        #expect(request.cachePolicy == .returnCacheDataElseLoad)
    }
}
