import Foundation
import Testing
@testable import CoverDrop

struct CoverImageStagingCacheTests {
    @Test("远程图片下载请求带浏览器式图片请求头")
    func remoteImageRequestUsesBrowserLikeImageHeaders() throws {
        let url = try #require(URL(string: "https://is1-ssl.mzstatic.com/image/thumb/example.jpg/600x600bb-100.jpg"))

        let request = CoverImageStagingCache.remoteImageRequest(for: url)

        #expect(request.url == url)
        #expect(request.timeoutInterval == 30)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
        #expect(request.value(forHTTPHeaderField: "Accept")?.contains("image/") == true)
        #expect(request.value(forHTTPHeaderField: "Referer") == nil)
    }

    @Test("豆瓣图片下载请求带 music.douban.com Referer")
    func doubanImageRequestUsesDoubanReferer() throws {
        let url = try #require(URL(string: "https://img1.doubanio.com/view/subject/m/public/s33672680.jpg"))

        let request = CoverImageStagingCache.remoteImageRequest(for: url)

        #expect(request.value(forHTTPHeaderField: "Referer") == "https://music.douban.com/")
        #expect(CoverImageStagingCache.imageReferer(for: url) == "https://music.douban.com/")
    }

    @Test("豆瓣子域名图片也会带 Referer")
    func doubanSubdomainImageRequestUsesDoubanReferer() throws {
        let url = try #require(URL(string: "https://img9.doubanio.com/view/subject/l/public/example.jpg"))

        let request = CoverImageStagingCache.remoteImageRequest(for: url)

        #expect(request.value(forHTTPHeaderField: "Referer") == "https://music.douban.com/")
    }
}
