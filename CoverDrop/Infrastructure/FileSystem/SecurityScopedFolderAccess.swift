import Foundation

struct SecurityScopedFolderAccess: FolderAccessing {
    nonisolated func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
    }

    nonisolated func resolveBookmark(_ data: Data) throws -> URL {
        var isStale = false
        return try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}
