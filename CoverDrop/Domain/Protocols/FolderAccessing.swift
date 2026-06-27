import Foundation

protocol FolderAccessing: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> URL
}
