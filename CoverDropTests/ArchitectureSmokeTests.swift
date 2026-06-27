import Testing
@testable import CoverDrop

@MainActor
struct ArchitectureSmokeTests {
    @Test("应用默认进入音乐库开始页")
    func appStartsAtLibraryHome() {
        let appModel = AppModel()

        #expect(appModel.route == .libraries)
    }

    @Test("目录角色提供稳定的中文名称")
    func libraryRolesHaveChineseNames() {
        #expect(LibraryRole.library.displayName == "音乐库")
        #expect(LibraryRole.artist.displayName == "歌手目录")
        #expect(LibraryRole.album.displayName == "单张专辑")
    }
}
