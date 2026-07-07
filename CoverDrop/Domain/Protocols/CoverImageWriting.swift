import Foundation

protocol CoverImageWriting: Sendable {
    nonisolated func writeCoverImage(
        from sourceURL: URL,
        toAlbumFolder albumFolderURL: URL
    ) async throws -> URL
}
