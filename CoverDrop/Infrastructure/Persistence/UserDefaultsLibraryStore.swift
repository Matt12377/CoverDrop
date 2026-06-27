import Foundation

@MainActor
final class UserDefaultsLibraryStore: LibraryStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey = "已保存的音乐库.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadLibraries() async throws -> [LibraryRecord] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return try JSONDecoder().decode([LibraryRecord].self, from: data)
            .sorted { $0.createdAt < $1.createdAt }
    }

    func save(_ library: LibraryRecord) async throws {
        var libraries = try await loadLibraries()
        libraries.removeAll { $0.id == library.id || $0.rootPath == library.rootPath }
        libraries.append(library)
        try persist(libraries)
    }

    func remove(id: LibraryRecord.ID) async throws {
        var libraries = try await loadLibraries()
        libraries.removeAll { $0.id == id }
        try persist(libraries)
    }

    private func persist(_ libraries: [LibraryRecord]) throws {
        defaults.set(try JSONEncoder().encode(libraries), forKey: storageKey)
    }
}
