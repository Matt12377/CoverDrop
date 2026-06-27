import Foundation

@MainActor
protocol LibraryStore: Sendable {
    func loadLibraries() async throws -> [LibraryRecord]
    func save(_ library: LibraryRecord) async throws
    func remove(id: LibraryRecord.ID) async throws
}
