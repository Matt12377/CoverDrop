import Foundation

protocol DirectoryRoleProbing: Sendable {
    nonisolated func suggestRole(for url: URL) async throws -> DirectoryRoleSuggestion
}
