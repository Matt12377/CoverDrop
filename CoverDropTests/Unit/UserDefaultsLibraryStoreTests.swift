import Foundation
import Testing
@testable import CoverDrop

struct UserDefaultsLibraryStoreTests {
    @Test("音乐库记录能够保存、读取和移除")
    func roundTrip() async throws {
        let suiteName = "CoverDropTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsLibraryStore(defaults: defaults)
        let library = LibraryRecord(
            displayName: "测试音乐库",
            rootPath: "/Volumes/Music",
            bookmarkData: Data([1, 2, 3]),
            role: .library
        )

        try await store.save(library)
        let loaded = try await store.loadLibraries()

        #expect(loaded == [library])

        try await store.remove(id: library.id)
        #expect(try await store.loadLibraries().isEmpty)
    }
}
