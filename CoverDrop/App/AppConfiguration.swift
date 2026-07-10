import Foundation

/// 应用级可调参数的统一入口。
///
/// 先用 Swift 配置文件管理，便于编译期测试和代码审查。
/// 后续如果需要让用户在界面里修改，再把这里接到持久化设置。
struct AppConfiguration: Equatable, Sendable {
    struct LocalLLM: Equatable, Sendable {
        let isEnabled: Bool
        let baseURL: String
        let model: String
        let requestTimeoutSeconds: TimeInterval
        let maxTracksPerAlbum: Int
        let enhanceCoveredAlbums: Bool
        let batchKeepAlive: String?
        let unloadAfterBatch: Bool

        init(
            isEnabled: Bool = true,
            baseURL: String = "http://127.0.0.1:11434",
            model: String = "qwen3.5:4b-mlx",
            requestTimeoutSeconds: TimeInterval = 300,
            maxTracksPerAlbum: Int = 12,
            enhanceCoveredAlbums: Bool = false,
            batchKeepAlive: String? = "30s",
            unloadAfterBatch: Bool = true
        ) {
            self.isEnabled = isEnabled
            self.baseURL = baseURL
            self.model = model
            self.requestTimeoutSeconds = max(1, requestTimeoutSeconds)
            self.maxTracksPerAlbum = max(1, maxTracksPerAlbum)
            self.enhanceCoveredAlbums = enhanceCoveredAlbums
            self.batchKeepAlive = batchKeepAlive
            self.unloadAfterBatch = unloadAfterBatch
        }
    }

    struct Scan: Equatable, Sendable {
        /// 同时扫描的专辑数量。
        ///
        /// 当前音乐库位于 SMB 网络共享时，瓶颈通常是 NAS/网络/小文件 I/O，
        /// 不是 Mac CPU。默认 12 能更充分利用等待 I/O 的时间，同时仍限制峰值压力。
        let maxConcurrentAlbums: Int

        static let minimumConcurrentAlbums = 1
        static let defaultConcurrentAlbums = 12
        static let maximumConcurrentAlbums = 24

        init(maxConcurrentAlbums: Int = Self.defaultConcurrentAlbums) {
            self.maxConcurrentAlbums = max(
                Self.minimumConcurrentAlbums,
                min(maxConcurrentAlbums, Self.maximumConcurrentAlbums)
            )
        }
    }

    struct ScanDatabases: Equatable, Sendable {
        let directoryURL: URL

        init(directoryURL: URL = Self.defaultDirectoryURL) {
            self.directoryURL = directoryURL
        }

        static var defaultDirectoryURL: URL {
            let applicationSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            return applicationSupportURL
                .appendingPathComponent("CoverDrop", isDirectory: true)
                .appendingPathComponent("ScanDatabases", isDirectory: true)
        }
    }

    struct RealtimeScanRefresh: Equatable, Sendable {
        let isEnabled: Bool
        let debounceSeconds: TimeInterval

        init(
            isEnabled: Bool = true,
            debounceSeconds: TimeInterval = 2.5
        ) {
            self.isEnabled = isEnabled
            self.debounceSeconds = max(0.1, debounceSeconds)
        }
    }

    struct CoverSearchSource: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case aggregate
            case web
        }

        let id: String
        let displayName: String
        let kind: Kind
        let urlTemplate: String?
        let isEnabled: Bool

        init(
            id: String,
            displayName: String,
            kind: Kind = .web,
            urlTemplate: String? = nil,
            isEnabled: Bool = true
        ) {
            self.id = id
            self.displayName = displayName
            self.kind = kind
            self.urlTemplate = urlTemplate
            self.isEnabled = isEnabled
        }

        func url(for keyword: String) -> URL? {
            guard kind == .web, let urlTemplate else { return nil }
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
            defaultSourceID: CoverSearchSource.ID = "aggregate"
        ) {
            self.sources = sources
            self.defaultSourceID = defaultSourceID
        }

        func source(id: CoverSearchSource.ID) -> CoverSearchSource {
            enabledSources.first { $0.id == id } ?? defaultSource
        }

        static let defaultSources: [CoverSearchSource] = [
            CoverSearchSource(
                id: "aggregate",
                displayName: "聚合搜索",
                kind: .aggregate
            ),
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
    let scanDatabases: ScanDatabases
    let realtimeScanRefresh: RealtimeScanRefresh
    let coverSearch: CoverSearch
    let localLLM: LocalLLM

    init(
        scan: Scan = Scan(),
        scanDatabases: ScanDatabases = ScanDatabases(),
        realtimeScanRefresh: RealtimeScanRefresh = RealtimeScanRefresh(),
        coverSearch: CoverSearch = CoverSearch(),
        localLLM: LocalLLM = LocalLLM()
    ) {
        self.scan = scan
        self.scanDatabases = scanDatabases
        self.realtimeScanRefresh = realtimeScanRefresh
        self.coverSearch = coverSearch
        self.localLLM = localLLM
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
