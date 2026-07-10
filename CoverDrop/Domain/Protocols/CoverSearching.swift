import Foundation

protocol CoverSearching: Sendable {
    func searchCovers(
        keyword: String,
        parameters: CoverSearchParameters
    ) async throws -> [CoverSearchResult]
}
