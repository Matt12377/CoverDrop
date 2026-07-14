import Foundation
import Testing
@testable import CoverDrop

struct ITunesCoverSearchClientTests {
    @Test("iTunes 搜索请求使用默认聚合参数")
    func requestUsesDefaultAggregateParameters() throws {
        let url = try #require(ITunesCoverSearchClient.searchURL(
            keyword: "周杰伦 七里香",
            parameters: CoverSearchParameters()
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems: [URLQueryItem] = components.queryItems ?? []
        let items = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

        #expect(components.scheme == "https")
        #expect(components.host == "itunes.apple.com")
        #expect(components.path == "/search")
        #expect(items["term"] == "周杰伦 七里香")
        #expect(items["country"] == "CN")
        #expect(items["media"] == "music")
        #expect(items["entity"] == "album")
        #expect(items["limit"] == "50")
    }

    @Test("iTunes JSON 会解析为封面搜索结果")
    func decodesAlbumResults() throws {
        let data = Data(Self.fixture.utf8)

        let results = try ITunesCoverSearchClient.decodeResults(from: data)

        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.id == "itunes-536114662")
        #expect(result.sourceName == "iTunes")
        #expect(result.albumName == "七里香")
        #expect(result.artistName == "周杰伦")
        #expect(result.thumbnailURL.absoluteString.hasSuffix("/100x100bb.jpg"))
        #expect(result.imageURL.absoluteString.hasSuffix("/1200x1200bb.jpg"))
        #expect(result.externalURL?.absoluteString.contains("music.apple.com/cn/album") == true)
    }

    @Test("iTunes 空结果会返回空数组")
    func decodesEmptyResults() throws {
        let data = Data(#"{"resultCount":0,"results":[]}"#.utf8)

        let results = try ITunesCoverSearchClient.decodeResults(from: data)

        #expect(results.isEmpty)
    }

    @Test("iTunes JSON 在后台解析")
    func decodesResultsOffMainActor() async throws {
        let results = try await ITunesCoverSearchClient.decodeResultsOffMainActor(
            from: Data(Self.fixture.utf8)
        )

        #expect(results.count == 1)
    }

    @Test("iTunes 错误会提供中文说明")
    func failureDescriptionsAreChinese() {
        #expect(ITunesCoverSearchClient.Failure.badHTTPStatus(500).errorDescription == "iTunes 搜索失败：HTTP 500。")
        #expect(ITunesCoverSearchClient.Failure.invalidResponse.errorDescription == "iTunes 搜索返回了无法识别的数据。")
    }

    private static let fixture = """
    {
      "resultCount": 1,
      "results": [
        {
          "wrapperType": "collection",
          "collectionType": "Album",
          "collectionId": 536114662,
          "artistName": "周杰伦",
          "collectionName": "七里香",
          "collectionViewUrl": "https://music.apple.com/cn/album/%E4%B8%83%E9%87%8C%E9%A6%99/536114662?uo=4",
          "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/29/c1/2d/29c12de6-54b4-f549-9d9f-07d8a04221ea/JAY.jpg/100x100bb.jpg"
        }
      ]
    }
    """
}
