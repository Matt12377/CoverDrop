import Foundation

struct LibraryRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    let rootPath: String
    let bookmarkData: Data
    let role: LibraryRole
    let createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        rootPath: String,
        bookmarkData: Data,
        role: LibraryRole,
        createdAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.rootPath = rootPath
        self.bookmarkData = bookmarkData
        self.role = role
        self.createdAt = createdAt
    }
}

struct PendingLibraryImport: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let suggestedRole: LibraryRole
    let explanation: String
}

struct DirectoryRoleSuggestion: Equatable, Sendable {
    let role: LibraryRole
    let explanation: String
}
