import Foundation
import Testing
@testable import CoverDrop

struct CompositeCoverSearchClientTests {
    @Test("聚合搜索会把多个来源结果合并到同一个列表")
    func mergesResultsFromAllSources() async throws {
        let client = CompositeCoverSearchClient(clients: [
            StubCoverSearchClient(results: [Self.result(id: "douban-1", sourceName: "豆瓣")]),
            StubCoverSearchClient(results: [Self.result(id: "itunes-1", sourceName: "iTunes")])
        ])

        let results = try await client.searchCovers(
            keyword: "周杰伦 七里香",
            parameters: CoverSearchParameters()
        )

        #expect(results.map(\.id) == ["douban-1", "itunes-1"])
        #expect(results.map(\.sourceName) == ["豆瓣", "iTunes"])
    }

    @Test("聚合搜索允许单个来源失败并继续返回其他来源结果")
    func returnsAvailableResultsWhenOneSourceFails() async throws {
        let client = CompositeCoverSearchClient(clients: [
            StubCoverSearchClient(error: SampleError()),
            StubCoverSearchClient(results: [Self.result(id: "itunes-1", sourceName: "iTunes")])
        ])

        let results = try await client.searchCovers(
            keyword: "周杰伦 七里香",
            parameters: CoverSearchParameters()
        )

        #expect(results.map(\.id) == ["itunes-1"])
    }

    @Test("聚合搜索所有来源失败时返回中文错误")
    func failsWhenEverySourceFails() async {
        let client = CompositeCoverSearchClient(clients: [
            StubCoverSearchClient(error: SampleError()),
            StubCoverSearchClient(error: SampleError())
        ])

        do {
            _ = try await client.searchCovers(
                keyword: "周杰伦 七里香",
                parameters: CoverSearchParameters()
            )
            Issue.record("预期聚合搜索失败")
        } catch {
            #expect((error as? CompositeCoverSearchClient.Failure)?.errorDescription == "聚合搜索失败：所有搜索源都不可用。")
        }
    }

    private static func result(id: String, sourceName: String) -> CoverSearchResult {
        CoverSearchResult(
            id: id,
            sourceName: sourceName,
            albumName: "七里香",
            artistName: "周杰伦",
            thumbnailURL: URL(string: "https://example.com/\(id)-thumb.jpg")!,
            imageURL: URL(string: "https://example.com/\(id).jpg")!,
            externalURL: URL(string: "https://example.com/\(id)")
        )
    }
}

private struct StubCoverSearchClient: CoverSearching {
    let results: [CoverSearchResult]
    let error: Error?

    init(results: [CoverSearchResult] = [], error: Error? = nil) {
        self.results = results
        self.error = error
    }

    func searchCovers(
        keyword: String,
        parameters: CoverSearchParameters
    ) async throws -> [CoverSearchResult] {
        if let error {
            throw error
        }
        return results
    }
}

private struct SampleError: Error {}
