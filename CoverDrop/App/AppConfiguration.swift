import Foundation

/// 应用级可调参数的统一入口。
///
/// 先用 Swift 配置文件管理，便于编译期测试和代码审查。
/// 后续如果需要让用户在界面里修改，再把这里接到持久化设置。
struct AppConfiguration: Equatable, Sendable {
    struct Scan: Equatable, Sendable {
        /// 同时扫描的专辑数量。
        ///
        /// 当前音乐库位于 SMB 网络共享时，瓶颈通常是 NAS/网络/小文件 I/O，
        /// 不是 Mac CPU。默认 4 更保守，适合长时间稳定扫描。
        let maxConcurrentAlbums: Int

        static let minimumConcurrentAlbums = 1
        static let defaultConcurrentAlbums = 4
        static let maximumConcurrentAlbums = 16

        init(maxConcurrentAlbums: Int = Self.defaultConcurrentAlbums) {
            self.maxConcurrentAlbums = max(
                Self.minimumConcurrentAlbums,
                min(maxConcurrentAlbums, Self.maximumConcurrentAlbums)
            )
        }
    }

    struct CoverSearchSource: Identifiable, Equatable, Sendable {
        let id: String
        let displayName: String
        let urlTemplate: String
        let isEnabled: Bool

        init(
            id: String,
            displayName: String,
            urlTemplate: String,
            isEnabled: Bool = true
        ) {
            self.id = id
            self.displayName = displayName
            self.urlTemplate = urlTemplate
            self.isEnabled = isEnabled
        }

        func url(for keyword: String) -> URL? {
            let encodedKeyword = Self.encode(keyword)
            return URL(string: urlTemplate.replacingOccurrences(of: "{query}", with: encodedKeyword))
        }

        private static func encode(_ keyword: String) -> String {
            var allowedCharacters = CharacterSet.urlQueryAllowed
            allowedCharacters.remove(charactersIn: ":#[]@!$&'()*+,;=?/")
            return keyword.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? keyword
        }
    }

    struct CoverSearch: Equatable, Sendable {
        let sources: [CoverSearchSource]
        let defaultSourceID: CoverSearchSource.ID

        var enabledSources: [CoverSearchSource] {
            sources.filter(\.isEnabled)
        }

        var defaultSource: CoverSearchSource {
            enabledSources.first { $0.id == defaultSourceID } ?? enabledSources[0]
        }

        init(
            sources: [CoverSearchSource] = Self.defaultSources,
            defaultSourceID: CoverSearchSource.ID = "douban"
        ) {
            self.sources = sources
            self.defaultSourceID = defaultSourceID
        }

        func source(id: CoverSearchSource.ID) -> CoverSearchSource {
            enabledSources.first { $0.id == id } ?? defaultSource
        }

        static let defaultSources: [CoverSearchSource] = [
            CoverSearchSource(
                id: "douban",
                displayName: "豆瓣",
                urlTemplate: "https://search.douban.com/music/subject_search?search_text={query}&cat=1003"
            ),
            CoverSearchSource(
                id: "bingImages",
                displayName: "Bing 图片",
                urlTemplate: "https://www.bing.com/images/search?q={query}%20%E5%B0%81%E9%9D%A2"
            ),
            CoverSearchSource(
                id: "googleImages",
                displayName: "Google 图片",
                urlTemplate: "https://www.google.com/search?tbm=isch&q={query}%20%E5%B0%81%E9%9D%A2"
            )
        ]
    }

    let scan: Scan
    let coverSearch: CoverSearch

    init(
        scan: Scan = Scan(),
        coverSearch: CoverSearch = CoverSearch()
    ) {
        self.scan = scan
        self.coverSearch = coverSearch
    }

    static let live = AppConfiguration()
}

enum CoverSearchKeyword {
    static func make(artistName: String, albumName: String) -> String {
        [artistName, albumName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
