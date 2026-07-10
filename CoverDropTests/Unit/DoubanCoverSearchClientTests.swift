import Foundation
import Testing
@testable import CoverDrop

struct DoubanCoverSearchClientTests {
    @Test("豆瓣搜索请求使用音乐搜索页参数")
    func requestUsesMusicSearchParameters() throws {
        let url = try #require(DoubanCoverSearchClient.searchURL(
            keyword: "周杰伦 七里香",
            parameters: CoverSearchParameters()
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems: [URLQueryItem] = components.queryItems ?? []
        let items = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

        #expect(components.scheme == "https")
        #expect(components.host == "search.douban.com")
        #expect(components.path == "/music/subject_search")
        #expect(items["search_text"] == "周杰伦 七里香")
        #expect(items["cat"] == "1003")
    }

    @Test("豆瓣页面数据会解析为封面搜索结果")
    func decodesSearchPageData() throws {
        let data = Data(Self.fixture.utf8)

        let results = try DoubanCoverSearchClient.decodeResults(from: data)

        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.id == "douban-1401853")
        #expect(result.sourceName == "豆瓣")
        #expect(result.albumName == "七里香")
        #expect(result.artistName == "周杰伦")
        #expect(result.thumbnailURL.absoluteString == "https://img9.doubanio.com/view/subject/m/public/s3737076.jpg")
        #expect(result.imageURL.absoluteString == "https://img9.doubanio.com/view/subject/l/public/s3737076.jpg")
        #expect(result.externalURL?.absoluteString == "https://music.douban.com/subject/1401853/")
    }

    @Test("豆瓣空结果会返回空数组")
    func decodesEmptyResults() throws {
        let data = Data("window.__DATA__ = {\"items\": []};".utf8)

        let results = try DoubanCoverSearchClient.decodeResults(from: data)

        #expect(results.isEmpty)
    }

    @Test("豆瓣错误会提供中文说明")
    func failureDescriptionsAreChinese() {
        #expect(DoubanCoverSearchClient.Failure.badHTTPStatus(403).errorDescription == "豆瓣搜索失败：HTTP 403。")
        #expect(DoubanCoverSearchClient.Failure.invalidResponse.errorDescription == "豆瓣搜索返回了无法识别的数据。")
    }

    private static let fixture = """
    <!doctype html>
    <html>
      <body>
        <script>
          window.__DATA__ = {"count":1,"items":[{"abstract":"周杰伦 / 2004 / 专辑 / CD / 流行","cover_url":"https://img9.doubanio.com/view/subject/m/public/s3737076.jpg","id":1401853,"title":"七里香 / Common Jasmin Orange","url":"https://music.douban.com/subject/1401853/"}],"total":1};
        </script>
      </body>
    </html>
    """
}
