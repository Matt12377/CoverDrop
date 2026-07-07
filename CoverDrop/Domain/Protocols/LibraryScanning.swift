import Foundation

typealias LibraryScanProgressHandler = @Sendable (LibraryScanProgress) async -> Void

protocol LibraryScanning: Sendable {
    nonisolated func scan(
        libraryURL: URL,
        role: LibraryRole,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> LibraryScanResult
}

protocol AlbumRescanning: Sendable {
    nonisolated func rescanAlbum(
        _ album: AlbumScanRecord,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> AlbumScanRecord
}

extension LibraryScanning {
    nonisolated func scan(libraryURL: URL, role: LibraryRole) async throws -> LibraryScanResult {
        try await scan(libraryURL: libraryURL, role: role) { _ in }
    }
}
