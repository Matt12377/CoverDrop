import Foundation

protocol DirectoryRoleProbing: Sendable {
    func suggestRole(for url: URL) async throws -> DirectoryRoleSuggestion
}
