import Foundation

protocol FolderAccessing: Sendable {
    nonisolated func makeBookmark(for url: URL) throws -> Data
    nonisolated func resolveBookmark(_ data: Data) throws -> URL
}
