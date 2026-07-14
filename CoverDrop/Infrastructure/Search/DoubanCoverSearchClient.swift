import Foundation

struct DoubanCoverSearchClient: CoverSearching {
    enum Failure: LocalizedError, Equatable {
        case invalidRequest
        case invalidResponse
        case badHTTPStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                "无法生成豆瓣搜索请求。"
            case .invalidResponse:
                "豆瓣搜索返回了无法识别的数据。"
            case .badHTTPStatus(let statusCode):
                "豆瓣搜索失败：HTTP \(statusCode)。"
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
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

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
        components.host = "search.douban.com"
        components.path = "/music/subject_search"
        components.queryItems = [
            URLQueryItem(name: "search_text", value: keyword),
            URLQueryItem(name: "cat", value: "1003")
        ]
        return components.url
    }

    nonisolated static func decodeResults(from data: Data) throws -> [CoverSearchResult] {
        guard let html = String(data: data, encoding: .utf8),
              let jsonData = dataPayload(in: html) else {
            throw Failure.invalidResponse
        }

        do {
            let response = try JSONDecoder().decode(DoubanSearchResponse.self, from: jsonData)
            return response.items.compactMap(\.coverSearchResult)
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
        let absoluteString = url.absoluteString
        let largeString = absoluteString
            .replacingOccurrences(of: "/m/public/", with: "/l/public/")
            .replacingOccurrences(of: "/s/public/", with: "/l/public/")
        return URL(string: largeString) ?? url
    }

    nonisolated private static func dataPayload(in html: String) -> Data? {
        guard let markerRange = html.range(of: "window.__DATA__"),
              let objectStart = html[markerRange.upperBound...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var current = objectStart

        while current < html.endIndex {
            let character = html[current]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else {
                if character == "\"" {
                    isInsideString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let objectEnd = html.index(after: current)
                        return Data(html[objectStart ..< objectEnd].utf8)
                    }
                }
            }

            current = html.index(after: current)
        }

        return nil
    }
}

private struct DoubanSearchResponse: Decodable, Sendable {
    let items: [DoubanSearchItem]

    private enum CodingKeys: String, CodingKey {
        case items
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([DoubanSearchItem].self, forKey: .items)
    }
}

private struct DoubanSearchItem: Decodable, Sendable {
    let id: Int?
    let title: String?
    let abstract: String?
    let coverURL: URL?
    let url: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case abstract
        case coverURL = "cover_url"
        case url
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        abstract = try container.decodeIfPresent(String.self, forKey: .abstract)
        coverURL = try container.decodeIfPresent(URL.self, forKey: .coverURL)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
    }

    nonisolated var coverSearchResult: CoverSearchResult? {
        guard let id,
              let rawTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTitle.isEmpty,
              let coverURL else {
            return nil
        }

        return CoverSearchResult(
            id: "douban-\(id)",
            sourceName: "豆瓣",
            albumName: Self.primarySegment(in: rawTitle),
            artistName: Self.artistName(from: abstract),
            thumbnailURL: coverURL,
            imageURL: DoubanCoverSearchClient.largeArtworkURL(from: coverURL),
            externalURL: url
        )
    }

    nonisolated private static func primarySegment(in value: String) -> String {
        value
            .components(separatedBy: " / ")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? value
    }

    nonisolated private static func artistName(from abstract: String?) -> String {
        guard let firstSegment = abstract?
            .components(separatedBy: " / ")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !firstSegment.isEmpty else {
            return "未知表演者"
        }
        return firstSegment
    }
}

private extension String {
    nonisolated var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
