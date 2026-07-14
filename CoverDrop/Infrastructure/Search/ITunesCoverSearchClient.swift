import Foundation

struct ITunesCoverSearchClient: CoverSearching {
    enum Failure: LocalizedError, Equatable {
        case invalidRequest
        case invalidResponse
        case badHTTPStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                "无法生成 iTunes 搜索请求。"
            case .invalidResponse:
                "iTunes 搜索返回了无法识别的数据。"
            case .badHTTPStatus(let statusCode):
                "iTunes 搜索失败：HTTP \(statusCode)。"
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchCovers(
        keyword: String,
        parameters: CoverSearchParameters = CoverSearchParameters()
    ) async throws -> [CoverSearchResult] {
        guard let url = Self.searchURL(keyword: keyword, parameters: parameters) else {
            throw Failure.invalidRequest
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Failure.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw Failure.badHTTPStatus(httpResponse.statusCode)
        }

        return try await Self.decodeResultsOffMainActor(from: data)
    }

    static func searchURL(
        keyword: String,
        parameters: CoverSearchParameters
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "term", value: keyword),
            URLQueryItem(name: "country", value: parameters.countryCode),
            URLQueryItem(name: "media", value: parameters.media),
            URLQueryItem(name: "entity", value: parameters.entity),
            URLQueryItem(name: "limit", value: String(parameters.limit))
        ]
        return components.url
    }

    nonisolated static func decodeResults(from data: Data) throws -> [CoverSearchResult] {
        do {
            let response = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            return response.results.compactMap { item in
                item.coverSearchResult
            }
        } catch {
            throw Failure.invalidResponse
        }
    }

    nonisolated static func decodeResultsOffMainActor(
        from data: Data
    ) async throws -> [CoverSearchResult] {
        try await Task.detached(priority: .userInitiated) {
            try decodeResults(from: data)
        }.value
    }

    nonisolated static func largeArtworkURL(from url: URL) -> URL {
        url
            .deletingLastPathComponent()
            .appendingPathComponent("1200x1200bb.jpg")
    }
}

private struct ITunesSearchResponse: Decodable, Sendable {
    let results: [ITunesAlbumResult]

    private enum CodingKeys: String, CodingKey {
        case results
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decode([ITunesAlbumResult].self, forKey: .results)
    }
}

private struct ITunesAlbumResult: Decodable, Sendable {
    let collectionType: String?
    let collectionId: Int?
    let artistName: String?
    let collectionName: String?
    let collectionViewUrl: URL?
    let artworkUrl100: URL?

    private enum CodingKeys: String, CodingKey {
        case collectionType
        case collectionId
        case artistName
        case collectionName
        case collectionViewUrl
        case artworkUrl100
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collectionType = try container.decodeIfPresent(String.self, forKey: .collectionType)
        collectionId = try container.decodeIfPresent(Int.self, forKey: .collectionId)
        artistName = try container.decodeIfPresent(String.self, forKey: .artistName)
        collectionName = try container.decodeIfPresent(String.self, forKey: .collectionName)
        collectionViewUrl = try container.decodeIfPresent(URL.self, forKey: .collectionViewUrl)
        artworkUrl100 = try container.decodeIfPresent(URL.self, forKey: .artworkUrl100)
    }

    nonisolated var coverSearchResult: CoverSearchResult? {
        guard collectionType == nil || collectionType == "Album",
              let collectionId,
              let artistName,
              let collectionName,
              let artworkUrl100 else {
            return nil
        }

        return CoverSearchResult(
            id: "itunes-\(collectionId)",
            sourceName: "iTunes",
            albumName: collectionName,
            artistName: artistName,
            thumbnailURL: artworkUrl100,
            imageURL: ITunesCoverSearchClient.largeArtworkURL(from: artworkUrl100),
            externalURL: collectionViewUrl
        )
    }
}
