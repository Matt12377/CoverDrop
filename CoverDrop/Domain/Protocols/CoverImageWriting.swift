import Foundation

protocol CoverImageWriting: Sendable {
    func writeCoverImage(
        from sourceURL: URL,
        toAlbumFolder albumFolderURL: URL
    ) async throws -> URL
}
