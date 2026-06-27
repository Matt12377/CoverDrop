import Testing
@testable import CoverDrop

struct AppConfigurationTests {
    @Test("扫描并发默认值采用保守稳定配置")
    func scanConcurrencyDefaultIsFour() {
        #expect(AppConfiguration.live.scan.maxConcurrentAlbums == 4)
    }

    @Test("扫描并发会被限制在安全范围内")
    func scanConcurrencyIsClampedToSafeRange() {
        #expect(AppConfiguration.Scan(maxConcurrentAlbums: 0).maxConcurrentAlbums == 1)
        #expect(AppConfiguration.Scan(maxConcurrentAlbums: 99).maxConcurrentAlbums == 16)
    }

    @Test("封面搜索默认使用豆瓣并保留多源入口")
    func coverSearchUsesDoubanByDefault() {
        let configuration = AppConfiguration.live.coverSearch

        #expect(configuration.defaultSource.id == "douban")
        #expect(configuration.enabledSources.map(\.id) == ["douban", "bingImages", "googleImages"])
    }

    @Test("封面搜索关键词由歌手和专辑组成")
    func coverSearchKeywordUsesArtistAndAlbum() {
        let keyword = CoverSearchKeyword.make(
            artistName: " 周杰伦 ",
            albumName: " 七里香 "
        )

        #expect(keyword == "周杰伦 七里香")
    }

    @Test("封面搜索 URL 会编码中文空格和特殊符号")
    func coverSearchURLEncodesKeyword() throws {
        let source = AppConfiguration.CoverSearchSource(
            id: "test",
            displayName: "测试",
            urlTemplate: "https://example.com/search?q={query}"
        )

        let url = try #require(source.url(for: "王力宏 A&B = 100%"))

        #expect(url.absoluteString == "https://example.com/search?q=%E7%8E%8B%E5%8A%9B%E5%AE%8F%20A%26B%20%3D%20100%25")
    }

    @Test("多个封面搜索源能生成各自 URL")
    func coverSearchSourcesBuildTheirOwnURLs() throws {
        let search = AppConfiguration.live.coverSearch
        let keyword = "周杰伦 七里香"

        let doubanURL = try #require(search.source(id: "douban").url(for: keyword))
        let bingURL = try #require(search.source(id: "bingImages").url(for: keyword))
        let googleURL = try #require(search.source(id: "googleImages").url(for: keyword))

        #expect(doubanURL.absoluteString.contains("search.douban.com/music/subject_search"))
        #expect(doubanURL.absoluteString.contains("search_text=%E5%91%A8%E6%9D%B0%E4%BC%A6%20%E4%B8%83%E9%87%8C%E9%A6%99"))
        #expect(bingURL.absoluteString.contains("bing.com/images/search"))
        #expect(googleURL.absoluteString.contains("google.com/search"))
        #expect(bingURL.absoluteString.contains("%E5%B0%81%E9%9D%A2"))
        #expect(googleURL.absoluteString.contains("%E5%B0%81%E9%9D%A2"))
    }
}
