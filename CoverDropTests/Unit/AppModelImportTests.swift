import Foundation
import Testing
@testable import CoverDrop

@MainActor
struct AppModelImportTests {
    @Test("确认目录角色后音乐库进入列表")
    func confirmedImportIsSaved() async throws {
        let store = MemoryLibraryStore()
        let environment = AppEnvironment(
            libraryStore: store,
            folderAccess: StubFolderAccess(),
            roleProber: StubRoleProber(role: .library),
            libraryScanner: StubLibraryScanner(),
            coverImageWriter: StubCoverImageWriter()
        )
        let appModel = AppModel(environment: environment)
        let url = URL(fileURLWithPath: "/Volumes/TestMusic", isDirectory: true)

        await appModel.prepareImport(url: url)
        #expect(appModel.pendingImport?.suggestedRole == .library)

        await appModel.confirmImport(role: .artist)

        #expect(appModel.libraries.count == 1)
        #expect(appModel.libraries.first?.role == .artist)
        #expect(appModel.selectedLibraryID == appModel.libraries.first?.id)
        #expect(appModel.pendingImport == nil)
    }

    @Test("切换侧栏时只有真正扫描的音乐库显示扫描状态")
    func scanningStateBelongsToActiveLibrary() async {
        let store = MemoryLibraryStore()
        let gate = ScanGate()
        let environment = AppEnvironment(
            libraryStore: store,
            folderAccess: StubFolderAccess(),
            roleProber: StubRoleProber(role: .library),
            libraryScanner: ControlledLibraryScanner(gate: gate),
            coverImageWriter: StubCoverImageWriter()
        )
        let appModel = AppModel(environment: environment)

        await appModel.prepareImport(url: URL(fileURLWithPath: "/Volumes/华语", isDirectory: true))
        await appModel.confirmImport(role: .library)
        let firstLibraryID = appModel.selectedLibraryID
        await appModel.prepareImport(url: URL(fileURLWithPath: "/Volumes/阿杜", isDirectory: true))
        await appModel.confirmImport(role: .artist)
        let secondLibraryID = appModel.selectedLibraryID

        appModel.selectLibrary(id: firstLibraryID)
        let scanTask = Task { await appModel.scanSelectedLibrary() }
        while appModel.scanProgress == nil {
            await Task.yield()
        }

        #expect(appModel.isSelectedLibraryScanning)
        #expect(appModel.scanningLibraryID == firstLibraryID)

        appModel.selectLibrary(id: secondLibraryID)
        #expect(appModel.isScanningLibrary)
        #expect(!appModel.isSelectedLibraryScanning)
        #expect(appModel.scanningLibraryID == firstLibraryID)

        await gate.release()
        await scanTask.value
        #expect(!appModel.isScanningLibrary)
    }

    @Test("扫描完成后自动进入当前音乐库的封面墙")
    func scanCompletionShowsCoverWall() async {
        let store = MemoryLibraryStore()
        let environment = AppEnvironment(
            libraryStore: store,
            folderAccess: StubFolderAccess(),
            roleProber: StubRoleProber(role: .library),
            libraryScanner: StubLibraryScanner(),
            coverImageWriter: StubCoverImageWriter()
        )
        let appModel = AppModel(environment: environment)

        await appModel.prepareImport(url: URL(fileURLWithPath: "/Volumes/华语", isDirectory: true))
        await appModel.confirmImport(role: .library)
        await appModel.scanSelectedLibrary()

        #expect(appModel.shouldShowCoverWallForSelectedLibrary)

        appModel.showSelectedLibraryHome()
        #expect(!appModel.shouldShowCoverWallForSelectedLibrary)
    }

    @Test("切换音乐库后已完成的扫描结果仍然保留")
    func scannedResultsAreRetainedPerLibrary() async {
        let store = MemoryLibraryStore()
        let environment = AppEnvironment(
            libraryStore: store,
            folderAccess: StubFolderAccess(),
            roleProber: StubRoleProber(role: .library),
            libraryScanner: StubLibraryScanner(),
            coverImageWriter: StubCoverImageWriter()
        )
        let appModel = AppModel(environment: environment)

        await appModel.prepareImport(url: URL(fileURLWithPath: "/Volumes/张学友", isDirectory: true))
        await appModel.confirmImport(role: .artist)
        let scannedLibraryID = appModel.selectedLibraryID
        await appModel.scanSelectedLibrary()
        #expect(appModel.shouldShowCoverWallForSelectedLibrary)

        await appModel.prepareImport(url: URL(fileURLWithPath: "/Volumes/阿杜", isDirectory: true))
        await appModel.confirmImport(role: .artist)
        #expect(!appModel.shouldShowCoverWallForSelectedLibrary)

        appModel.selectLibrary(id: scannedLibraryID)
        #expect(appModel.shouldShowCoverWallForSelectedLibrary)
        #expect(appModel.scanResultForSelectedLibrary != nil)
    }

    @Test("保存封面后当前扫描结果中的专辑来源更新为图片文件")
    func coverWriteUpdatesAlbumCoverSource() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let sourceURL = root.appendingPathComponent("source.png")
            try writeValidPNG(to: sourceURL)
            let writtenURL = albumFolder.appendingPathComponent("cover.jpg")
            let album = AlbumScanRecord(
                folderURL: albumFolder,
                artistName: "Artist",
                albumName: "Album",
                audioFiles: [],
                displayedCover: CoverCandidate(
                    url: albumFolder.appendingPathComponent("embedded.jpg"),
                    relativePath: "embedded.jpg",
                    namePriority: 0,
                    depth: 0,
                    source: .embeddedArtwork
                ),
                issues: []
            )
            let store = MemoryLibraryStore()
            let environment = AppEnvironment(
                libraryStore: store,
                folderAccess: StubFolderAccess(),
                roleProber: StubRoleProber(role: .library),
                libraryScanner: StubLibraryScanner(result: LibraryScanResult(
                    albums: [album],
                    looseAudioPaths: []
                )),
                coverImageWriter: ImageIOCoverImageWriter()
            )
            let appModel = AppModel(environment: environment)

            await appModel.prepareImport(url: root)
            await appModel.confirmImport(role: .library)
            await appModel.scanSelectedLibrary()
            let didWrite = await appModel.writeCoverImage(from: sourceURL, for: album)

            #expect(didWrite)
            let updatedAlbum = try #require(appModel.scanResultForSelectedLibrary?.albums.first)
            #expect(updatedAlbum.displayedCover?.source == .file)
            #expect(updatedAlbum.displayedCover?.relativePath == "cover.jpg")
            #expect(updatedAlbum.displayedCover?.url == writtenURL)
            let previewURL = try #require(updatedAlbum.displayedCover?.previewURL)
            #expect(updatedAlbum.displayedCover?.displayURL == previewURL)
            #expect(FileManager.default.fileExists(atPath: previewURL.path))
            #expect(appModel.albumInSelectedLibrary(id: album.id)?.displayedCover?.source == .file)
        }
    }

    @Test("拖入图片但未保存时不会生成 cover.jpg")
    func stagedCoverDoesNotWriteUntilSaved() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let sourceURL = root.appendingPathComponent("source.png")
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            try writeValidPNG(to: sourceURL)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let appModel = await makeScannedAppModel(root: root, albums: [album])

            appModel.stageCoverImage(sourceURL, forAlbumID: album.id)

            #expect(appModel.pendingCoverURL(for: album.id) == sourceURL)
            #expect(!FileManager.default.fileExists(atPath: albumFolder.appendingPathComponent("cover.jpg").path))
        }
    }

    @Test("拖入网页图片数据后会先暂存为本地待保存封面")
    func stagedCoverImageDataCreatesLocalPendingCover() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let appModel = await makeScannedAppModel(root: root, albums: [album])

            let didStage = appModel.stageCoverImageData(
                try validPNGData(),
                suggestedExtension: "png",
                forAlbumID: album.id
            )

            let pendingURL = try #require(appModel.pendingCoverURL(for: album.id))
            #expect(didStage)
            #expect(pendingURL.isFileURL)
            #expect(pendingURL.pathExtension == "png")
            #expect(FileManager.default.fileExists(atPath: pendingURL.path))
            #expect(!FileManager.default.fileExists(atPath: albumFolder.appendingPathComponent("cover.jpg").path))
        }
    }

    @Test("拖入非图片数据时不会进入待保存状态")
    func invalidStagedCoverImageDataIsRejected() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let appModel = await makeScannedAppModel(root: root, albums: [album])

            let didStage = appModel.stageCoverImageData(
                Data("这不是图片".utf8),
                suggestedExtension: "jpg",
                forAlbumID: album.id
            )

            #expect(!didStage)
            #expect(appModel.pendingCoverURL(for: album.id) == nil)
            #expect(appModel.errorMessage != nil)
        }
    }

    @Test("拖入本地文件 URL 时仍沿用原待保存链路")
    func droppedLocalCoverURLIsStagedDirectly() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let sourceURL = root.appendingPathComponent("source.png")
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            try writeValidPNG(to: sourceURL)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let appModel = await makeScannedAppModel(root: root, albums: [album])

            let didStage = await appModel.stageDroppedCoverURL(sourceURL, forAlbumID: album.id)

            #expect(didStage)
            #expect(appModel.pendingCoverURL(for: album.id) == sourceURL)
        }
    }

    @Test("取消待保存封面后不会生成或替换 cover.jpg")
    func cancellingStagedCoverDoesNotWriteOrReplace() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let sourceURL = root.appendingPathComponent("source.png")
            let existingCoverURL = albumFolder.appendingPathComponent("cover.jpg")
            let existingData = Data("旧封面".utf8)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            try writeValidPNG(to: sourceURL)
            try existingData.write(to: existingCoverURL)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let appModel = await makeScannedAppModel(root: root, albums: [album])

            appModel.stageCoverImage(sourceURL, forAlbumID: album.id)
            appModel.cancelPendingCoverImage(forAlbumID: album.id)
            let didWrite = await appModel.savePendingCoverImage(forAlbumID: album.id)

            #expect(!didWrite)
            #expect(appModel.pendingCoverURL(for: album.id) == nil)
            #expect(try Data(contentsOf: existingCoverURL) == existingData)
        }
    }

    @Test("点击保存后才生成或替换 cover.jpg")
    func savingStagedCoverWritesCoverJPEG() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let sourceURL = root.appendingPathComponent("source.png")
            let existingCoverURL = albumFolder.appendingPathComponent("cover.jpg")
            let existingData = Data("旧封面".utf8)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            try writeValidPNG(to: sourceURL)
            try existingData.write(to: existingCoverURL)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let appModel = await makeScannedAppModel(root: root, albums: [album])

            appModel.stageCoverImage(sourceURL, forAlbumID: album.id)
            let didWrite = await appModel.savePendingCoverImage(forAlbumID: album.id)

            #expect(didWrite)
            #expect(appModel.pendingCoverURL(for: album.id) == nil)
            #expect(try Data(contentsOf: existingCoverURL) != existingData)
            let cover = try #require(appModel.albumInSelectedLibrary(id: album.id)?.displayedCover)
            #expect(cover.source == .file)
            #expect(cover.url == existingCoverURL)
            let previewURL = try #require(cover.previewURL)
            #expect(cover.displayURL == previewURL)
            #expect(FileManager.default.fileExists(atPath: previewURL.path))
        }
    }

    @Test("特殊层级专辑保存时 cover.jpg 写入扫描出的专辑根目录")
    func stagedCoverWritesToScannedAlbumRoot() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let discFolder = albumFolder.appendingPathComponent("CD1", isDirectory: true)
            let sourceURL = root.appendingPathComponent("source.png")
            try FileManager.default.createDirectory(at: discFolder, withIntermediateDirectories: true)
            try writeValidPNG(to: sourceURL)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let appModel = await makeScannedAppModel(root: root, albums: [album])

            appModel.stageCoverImage(sourceURL, forAlbumID: album.id)
            let didWrite = await appModel.savePendingCoverImage(forAlbumID: album.id)

            #expect(didWrite)
            #expect(FileManager.default.fileExists(atPath: albumFolder.appendingPathComponent("cover.jpg").path))
            #expect(!FileManager.default.fileExists(atPath: discFolder.appendingPathComponent("cover.jpg").path))
            let cover = try #require(appModel.albumInSelectedLibrary(id: album.id)?.displayedCover)
            #expect(cover.url == albumFolder.appendingPathComponent("cover.jpg"))
            let previewURL = try #require(cover.previewURL)
            #expect(cover.displayURL == previewURL)
            #expect(FileManager.default.fileExists(atPath: previewURL.path))
        }
    }

    @Test("成功提示只属于最近保存的 albumID")
    func coverWriteMessageBelongsToCurrentAlbumOnly() async throws {
        try await withTemporaryDirectory { root in
            let firstFolder = root.appendingPathComponent("Artist/First", isDirectory: true)
            let secondFolder = root.appendingPathComponent("Artist/Second", isDirectory: true)
            let sourceURL = root.appendingPathComponent("source.png")
            try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
            try writeValidPNG(to: sourceURL)
            let firstAlbum = makeAlbum(folderURL: firstFolder, albumName: "First")
            let secondAlbum = makeAlbum(folderURL: secondFolder, albumName: "Second")
            let appModel = await makeScannedAppModel(root: root, albums: [firstAlbum, secondAlbum])

            appModel.stageCoverImage(sourceURL, forAlbumID: firstAlbum.id)
            await appModel.savePendingCoverImage(forAlbumID: firstAlbum.id)
            #expect(appModel.coverWriteMessage(for: firstAlbum.id) != nil)
            #expect(appModel.coverWriteMessage(for: secondAlbum.id) == nil)

            appModel.stageCoverImage(sourceURL, forAlbumID: secondAlbum.id)
            await appModel.savePendingCoverImage(forAlbumID: secondAlbum.id)
            #expect(appModel.coverWriteMessage(for: firstAlbum.id) == nil)
            #expect(appModel.coverWriteMessage(for: secondAlbum.id) != nil)
        }
    }
}

@MainActor
private final class MemoryLibraryStore: LibraryStore, @unchecked Sendable {
    private var libraries: [LibraryRecord] = []

    func loadLibraries() -> [LibraryRecord] {
        libraries
    }

    func save(_ library: LibraryRecord) {
        libraries.removeAll { $0.id == library.id || $0.rootPath == library.rootPath }
        libraries.append(library)
    }

    func remove(id: LibraryRecord.ID) {
        libraries.removeAll { $0.id == id }
    }
}

private struct StubFolderAccess: FolderAccessing {
    func makeBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> URL {
        URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true)
    }
}

private struct StubRoleProber: DirectoryRoleProbing {
    let role: LibraryRole

    func suggestRole(for url: URL) async throws -> DirectoryRoleSuggestion {
        DirectoryRoleSuggestion(role: role, explanation: "测试建议")
    }
}

private struct StubLibraryScanner: LibraryScanning {
    var result = LibraryScanResult(albums: [], looseAudioPaths: [])

    func scan(
        libraryURL: URL,
        role: LibraryRole,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> LibraryScanResult {
        result
    }
}

private struct StubCoverImageWriter: CoverImageWriting {
    var writtenURL: URL?

    func writeCoverImage(
        from sourceURL: URL,
        toAlbumFolder albumFolderURL: URL
    ) async throws -> URL {
        writtenURL ?? albumFolderURL.appendingPathComponent("cover.jpg")
    }
}

private struct ControlledLibraryScanner: LibraryScanning {
    let gate: ScanGate

    func scan(
        libraryURL: URL,
        role: LibraryRole,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> LibraryScanResult {
        await progress(LibraryScanProgress(
            phase: .readingMetadata,
            targetPath: libraryURL.appendingPathComponent("01.flac").path,
            completedAlbums: 0,
            totalAlbums: 1,
            completedFilesInAlbum: 0,
            totalFilesInAlbum: 1
        ))
        await gate.waitUntilReleased()
        return LibraryScanResult(albums: [], looseAudioPaths: [])
    }
}

private actor ScanGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func waitUntilReleased() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func makeScannedAppModel(
    root: URL,
    albums: [AlbumScanRecord]
) async -> AppModel {
    let store = MemoryLibraryStore()
    let environment = AppEnvironment(
        libraryStore: store,
        folderAccess: StubFolderAccess(),
        roleProber: StubRoleProber(role: .library),
        libraryScanner: StubLibraryScanner(result: LibraryScanResult(
            albums: albums,
            looseAudioPaths: []
        )),
        coverImageWriter: ImageIOCoverImageWriter()
    )
    let appModel = AppModel(environment: environment)
    await appModel.prepareImport(url: root)
    await appModel.confirmImport(role: .library)
    await appModel.scanSelectedLibrary()
    return appModel
}

private func makeAlbum(
    folderURL: URL,
    albumName: String
) -> AlbumScanRecord {
    AlbumScanRecord(
        folderURL: folderURL,
        artistName: "Artist",
        albumName: albumName,
        audioFiles: [],
        displayedCover: nil,
        issues: []
    )
}

private func writeValidPNG(to url: URL) throws {
    try validPNGData().write(to: url)
}

private func validPNGData() throws -> Data {
    try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    ))
}

private func withTemporaryDirectory(
    _ operation: (URL) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoverDropAppModelTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await operation(root)
}
