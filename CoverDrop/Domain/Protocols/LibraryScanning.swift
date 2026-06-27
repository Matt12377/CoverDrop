import Foundation

typealias LibraryScanProgressHandler = @Sendable (LibraryScanProgress) async -> Void

protocol LibraryScanning: Sendable {
    func scan(
        libraryURL: URL,
        role: LibraryRole,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> LibraryScanResult
}

extension LibraryScanning {
    func scan(libraryURL: URL, role: LibraryRole) async throws -> LibraryScanResult {
        try await scan(libraryURL: libraryURL, role: role) { _ in }
    }
}
