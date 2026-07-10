import Foundation

struct CompositeCoverSearchClient: CoverSearching {
    enum Failure: LocalizedError, Equatable {
        case allSourcesFailed

        var errorDescription: String? {
            switch self {
            case .allSourcesFailed:
                "聚合搜索失败：所有搜索源都不可用。"
            }
        }
    }

    let clients: [any CoverSearching]

    init(clients: [any CoverSearching]) {
        self.clients = clients
    }

    func searchCovers(
        keyword: String,
        parameters: CoverSearchParameters
    ) async throws -> [CoverSearchResult] {
        guard !clients.isEmpty else { return [] }

        var successfulResults: [(index: Int, results: [CoverSearchResult])] = []
        var failureCount = 0

        await withTaskGroup(of: SourceSearchResponse.self) { group in
            for (index, client) in clients.enumerated() {
                group.addTask {
                    do {
                        let results = try await client.searchCovers(
                            keyword: keyword,
                            parameters: parameters
                        )
                        return SourceSearchResponse(index: index, results: results)
                    } catch {
                        return SourceSearchResponse(index: index, results: nil)
                    }
                }
            }

            for await response in group {
                if let results = response.results {
                    successfulResults.append((index: response.index, results: results))
                } else {
                    failureCount += 1
                }
            }
        }

        let results = successfulResults
            .sorted { $0.index < $1.index }
            .flatMap(\.results)

        if results.isEmpty, failureCount == clients.count {
            throw Failure.allSourcesFailed
        }

        return results
    }

    static let live = CompositeCoverSearchClient(clients: [
        DoubanCoverSearchClient(),
        ITunesCoverSearchClient()
    ])
}

private struct SourceSearchResponse: Sendable {
    let index: Int
    let results: [CoverSearchResult]?
}
