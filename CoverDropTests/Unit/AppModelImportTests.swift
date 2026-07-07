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

    @Test("扫描完成后当前音乐库显示封面墙")
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
    }

    @Test("扫描器从 AppModel 启动时不占用主线程")
    func scanRunsScannerAwayFromMainThread() async {
        let store = MemoryLibraryStore()
        let scanner = ThreadRecordingLibraryScanner()
        let environment = AppEnvironment(
            libraryStore: store,
            folderAccess: StubFolderAccess(),
            roleProber: StubRoleProber(role: .library),
            libraryScanner: scanner,
            coverImageWriter: StubCoverImageWriter()
        )
        let appModel = AppModel(environment: environment)

        await appModel.prepareImport(url: URL(fileURLWithPath: "/Volumes/华语", isDirectory: true))
        await appModel.confirmImport(role: .library)
        await appModel.scanSelectedLibrary()

        #expect(scanner.scanRanOnMainThread() == false)
        #expect(appModel.shouldShowCoverWallForSelectedLibrary)
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

    @Test("重新扫描期间保留旧结果并在完成后替换为新结果")
    func rescanKeepsOldResultUntilNewResultArrives() async throws {
        let oldAlbum = makeAlbum(
            folderURL: URL(fileURLWithPath: "/Volumes/华语/Artist/Old", isDirectory: true),
            albumName: "Old"
        )
        let newAlbum = makeAlbum(
            folderURL: URL(fileURLWithPath: "/Volumes/华语/Artist/New", isDirectory: true),
            albumName: "New"
        )
        let scanner = BlockingSecondScanLibraryScanner(outcomes: [
            LibraryScanResult(albums: [oldAlbum], looseAudioPaths: []),
            LibraryScanResult(albums: [newAlbum], looseAudioPaths: [])
        ])
        let environment = AppEnvironment(
            libraryStore: MemoryLibraryStore(),
            folderAccess: StubFolderAccess(),
            roleProber: StubRoleProber(role: .library),
            libraryScanner: scanner,
            coverImageWriter: StubCoverImageWriter()
        )
        let appModel = AppModel(environment: environment)

        await appModel.prepareImport(url: URL(fileURLWithPath: "/Volumes/华语", isDirectory: true))
        await appModel.confirmImport(role: .library)
        await appModel.scanSelectedLibrary()

        #expect(appModel.scanResultForSelectedLibrary?.albums.first?.albumName == "Old")

        let scanTask = Task { await appModel.scanSelectedLibrary() }
        await waitUntil { appModel.isSelectedLibraryScanning }

        #expect(appModel.shouldShowCoverWallForSelectedLibrary)
        #expect(appModel.scanResultForSelectedLibrary?.albums.first?.albumName == "Old")

        await scanner.releaseSecondScan()
        await scanTask.value

        #expect(appModel.scanResultForSelectedLibrary?.albums.first?.albumName == "New")
        #expect(appModel.shouldShowCoverWallForSelectedLibrary)
    }

    @Test("首次扫描失败时不生成封面墙结果")
    func firstScanFailureKeepsLibraryUnscanned() async {
        let environment = AppEnvironment(
            libraryStore: MemoryLibraryStore(),
            folderAccess: StubFolderAccess(),
            roleProber: StubRoleProber(role: .library),
            libraryScanner: SequencedLibraryScanner(outcomes: [.failure("磁盘不可读")]),
            coverImageWriter: StubCoverImageWriter()
        )
        let appModel = AppModel(environment: environment)

        await appModel.prepareImport(url: URL(fileURLWithPath: "/Volumes/华语", isDirectory: true))
        await appModel.confirmImport(role: .library)
        await appModel.scanSelectedLibrary()

        #expect(appModel.scanResultForSelectedLibrary == nil)
        #expect(!appModel.shouldShowCoverWallForSelectedLibrary)
        #expect(appModel.errorMessage?.contains("磁盘不可读") == true)
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
            await waitUntil {
                appModel.scanResultForSelectedLibrary?.albums.first?.displayedCover?.previewURL != nil
            }
            let refreshedAlbum = try #require(appModel.scanResultForSelectedLibrary?.albums.first)
            let previewURL = try #require(refreshedAlbum.displayedCover?.previewURL)
            #expect(refreshedAlbum.displayedCover?.displayURL == previewURL)
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
            await waitUntil {
                appModel.albumInSelectedLibrary(id: album.id)?.displayedCover?.previewURL != nil
            }
            let refreshedCover = try #require(appModel.albumInSelectedLibrary(id: album.id)?.displayedCover)
            let previewURL = try #require(refreshedCover.previewURL)
            #expect(refreshedCover.displayURL == previewURL)
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
            await waitUntil {
                appModel.albumInSelectedLibrary(id: album.id)?.displayedCover?.previewURL != nil
            }
            let refreshedCover = try #require(appModel.albumInSelectedLibrary(id: album.id)?.displayedCover)
            let previewURL = try #require(refreshedCover.previewURL)
            #expect(refreshedCover.displayURL == previewURL)
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

    @Test("增强后的显示名会优先用于封面墙和搜索词")
    func enhancementNamesAreUsedAfterScan() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let album = AlbumScanRecord(
                folderURL: albumFolder,
                artistName: "原始歌手",
                albumName: "原始专辑",
                audioFiles: [
                    AudioFileRecord(
                        url: albumFolder.appendingPathComponent("01.flac"),
                        relativePath: "01.flac",
                        format: "flac",
                        metadata: AudioMetadata(
                            title: "Track 1",
                            artist: "原始歌手",
                            albumArtist: "原始歌手",
                            album: "原始专辑",
                            discNumber: nil,
                            trackNumber: 1,
                            durationSeconds: nil
                        ),
                        readError: nil
                    )
                ],
                displayedCover: nil,
                issues: []
            )
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                albumNameSuggesting: StubAlbumNameSuggesting(
                    outcome: .success(AlbumNameSuggestion(
                        artistName: "LLM 歌手",
                        albumName: "LLM 专辑"
                    ))
                )
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)

            #expect(appModel.displayArtistName(for: album) == "LLM 歌手")
            #expect(appModel.displayAlbumName(for: album) == "LLM 专辑")
            #expect(appModel.hasEnhancedAlbumName(for: album))
            #expect(appModel.searchKeyword(for: album) == "LLM 歌手 LLM 专辑")
        }
    }

    @Test("增强失败时回退原始名称并记录错误")
    func enhancementFailureFallsBackAndReportsError() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let album = makeAlbum(folderURL: albumFolder, albumName: "原始专辑")
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                albumNameSuggesting: StubAlbumNameSuggesting(
                    outcome: .failure("Ollama 请求失败（404）：模型不存在")
                )
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)

            #expect(appModel.displayArtistName(for: album) == "Artist")
            #expect(appModel.displayAlbumName(for: album) == "原始专辑")
            #expect(appModel.hasEnhancedAlbumName(for: album) == false)
            #expect(appModel.errorMessage?.contains("回退原始名称") == true)
            #expect(appModel.albumNameEnhancementStatus(for: libraryID)?.lastErrorMessage != nil)
        }
    }

    @Test("名称增强默认只处理缺封面的专辑")
    func enhancementPrioritizesAlbumsMissingCover() async throws {
        try await withTemporaryDirectory { root in
            let coveredFirst = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/01 Covered", isDirectory: true),
                albumName: "01 Covered",
                hasCover: true
            )
            let missingFirst = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/02 Missing", isDirectory: true),
                albumName: "02 Missing"
            )
            let missingSecond = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/03 Missing", isDirectory: true),
                albumName: "03 Missing"
            )
            let coveredSecond = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/04 Covered", isDirectory: true),
                albumName: "04 Covered",
                hasCover: true
            )
            let recorder = AlbumNameSuggestionRecorder()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [coveredFirst, missingFirst, missingSecond, coveredSecond],
                albumNameSuggesting: RecordingAlbumNameSuggesting(recorder: recorder)
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)

            let processedAlbumNames = await recorder.albumNames()
            #expect(processedAlbumNames == [
                "02 Missing",
                "03 Missing"
            ])
        }
    }

    @Test("名称增强批处理结束后释放 Ollama 资源")
    func enhancementReleasesResourcesAfterBatch() async throws {
        try await withTemporaryDirectory { root in
            let album = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Missing", isDirectory: true),
                albumName: "Missing"
            )
            let suggester = ReleasingAlbumNameSuggesting()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                albumNameSuggesting: suggester
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)
            await waitUntil { suggester.releaseCount() == 1 }

            #expect(suggester.releaseCount() == 1)
        }
    }

    @Test("新打开同地址目录可以加载最近扫描快照")
    func latestSnapshotCanRestoreCoverWallInNewAppModel() async throws {
        try await withTemporaryDirectory { root in
            let snapshotDirectory = root.appendingPathComponent("db", isDirectory: true)
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album", hasCover: true)
            let result = LibraryScanResult(
                albums: [album],
                looseAudioPaths: ["Loose/track.flac"]
            )
            let store = MemoryLibraryStore()
            let snapshotStore = FileScanSnapshotStore(directoryURL: snapshotDirectory)
            let firstEnvironment = AppEnvironment(
                libraryStore: store,
                folderAccess: StubFolderAccess(),
                roleProber: StubRoleProber(role: .library),
                libraryScanner: StubLibraryScanner(result: result),
                coverImageWriter: StubCoverImageWriter(),
                scanSnapshotStore: snapshotStore
            )
            let firstAppModel = AppModel(environment: firstEnvironment)

            await firstAppModel.prepareImport(url: root)
            await firstAppModel.confirmImport(role: .library)
            await firstAppModel.scanSelectedLibrary()

            let libraryID = try #require(firstAppModel.selectedLibraryID)
            let savedSnapshot = try #require(firstAppModel.latestScanSnapshot(for: libraryID))
            #expect(FileManager.default.fileExists(atPath: savedSnapshot.fileURL.path))

            let secondEnvironment = AppEnvironment(
                libraryStore: store,
                folderAccess: StubFolderAccess(),
                roleProber: StubRoleProber(role: .library),
                libraryScanner: StubLibraryScanner(),
                coverImageWriter: StubCoverImageWriter(),
                scanSnapshotStore: snapshotStore
            )
            let secondAppModel = AppModel(environment: secondEnvironment)

            await secondAppModel.loadLibraries()
            await waitUntil {
                secondAppModel.latestScanSnapshot(for: libraryID)?.fileURL == savedSnapshot.fileURL
            }
            #expect(secondAppModel.latestScanSnapshot(for: libraryID)?.fileURL == savedSnapshot.fileURL)

            await secondAppModel.loadLatestScanSnapshotForSelectedLibrary()

            #expect(secondAppModel.shouldShowCoverWallForSelectedLibrary)
            #expect(secondAppModel.scanResultForSelectedLibrary?.albums.first?.albumName == "Album")
            #expect(secondAppModel.scanResultForSelectedLibrary?.looseAudioPaths == ["Loose/track.flac"])
        }
    }

    @Test("目录事件会等待去抖并合并为一次自动刷新")
    func realtimeRefreshDebouncesFileEvents() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Before", isDirectory: true)
            let firstAlbum = makeAlbum(
                folderURL: albumFolder,
                albumName: "Before"
            )
            let refreshedAlbum = makeAlbum(
                folderURL: albumFolder,
                albumName: "After"
            )
            let scanner = RecordingAlbumRescanLibraryScanner(
                initialResult: LibraryScanResult(albums: [firstAlbum], looseAudioPaths: []),
                rescannedAlbumsByID: [firstAlbum.id: refreshedAlbum]
            )
            let monitor = ControllableLibraryChangeMonitor()
            let snapshotStore = RecordingScanSnapshotStore(root: root)
            let appModel = await makeRealtimeRefreshAppModel(
                root: root,
                scanner: scanner,
                monitor: monitor,
                snapshotStore: snapshotStore,
                localLLM: AppConfiguration.LocalLLM(isEnabled: false)
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            await waitUntil { monitor.hasSubscriber(for: root) }

            monitor.emit(rootURL: root, changedPaths: ["Artist/Before/cover.jpg"])
            monitor.emit(rootURL: root, changedPaths: ["Artist/Before/01.wav"])
            try await Task.sleep(nanoseconds: 20_000_000)

            #expect(await scanner.rescanCount() == 0)

            monitor.emit(rootURL: root, changedPaths: ["Artist/Before/02.wav"])
            await waitUntil { await scanner.rescanCount() == 1 }

            #expect(await scanner.scanCount() == 1)
            #expect(await scanner.rescanCount() == 1)
            #expect(appModel.scanResultsByLibraryID[libraryID]?.albums.first?.albumName == "After")
            #expect(await snapshotStore.saveCount() == 1)
            #expect(await snapshotStore.replaceCount() == 1)
        }
    }

    @Test("实时刷新运行中连续事件不会并发扫描且会追加一轮合并局部刷新")
    func realtimeRefreshSerializesOverlappingEvents() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Initial", isDirectory: true)
            let initialAlbum = makeAlbum(
                folderURL: albumFolder,
                albumName: "Initial"
            )
            let refreshedAlbum = makeAlbum(
                folderURL: albumFolder,
                albumName: "Refreshed"
            )
            let pendingAlbum = makeAlbum(
                folderURL: albumFolder,
                albumName: "Pending"
            )
            let scanner = BlockingAlbumRescanLibraryScanner(
                initialResult: LibraryScanResult(albums: [initialAlbum], looseAudioPaths: []),
                rescanOutcomes: [refreshedAlbum, pendingAlbum]
            )
            let monitor = ControllableLibraryChangeMonitor()
            let appModel = await makeRealtimeRefreshAppModel(
                root: root,
                scanner: scanner,
                monitor: monitor,
                localLLM: AppConfiguration.LocalLLM(isEnabled: false)
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            await waitUntil { monitor.hasSubscriber(for: root) }

            monitor.emit(rootURL: root, changedPaths: ["Artist/Initial/01.wav"])
            await waitUntil { await scanner.rescanCount() == 1 }

            monitor.emit(rootURL: root, changedPaths: ["Artist/Initial/01.wav"])
            monitor.emit(rootURL: root, changedPaths: ["Artist/Initial/02.wav"])
            try await Task.sleep(nanoseconds: 120_000_000)

            #expect(await scanner.scanCount() == 1)
            #expect(await scanner.rescanCount() == 1)

            await scanner.releaseFirstRescan()
            await waitUntil { await scanner.rescanCount() == 2 }
            await waitUntil {
                appModel.scanResultsByLibraryID[libraryID]?.albums.first?.albumName == "Pending"
            }

            #expect(await scanner.scanCount() == 1)
            #expect(appModel.scanResultsByLibraryID[libraryID]?.albums.first?.albumName == "Pending")
        }
    }

    @Test("实时刷新后同一路径新增 cover 会轻量更新封面状态")
    func realtimeRefreshUpdatesCoverStateForRenamedCoverWithoutFullRescan() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let missingCoverAlbum = makeAlbum(
                folderURL: albumFolder,
                albumName: "Album"
            )
            let coveredAlbum = makeAlbum(
                folderURL: albumFolder,
                albumName: "Album",
                hasCover: true
            )
            let scanner = RecordingAlbumRescanLibraryScanner(
                initialResult: LibraryScanResult(albums: [missingCoverAlbum], looseAudioPaths: []),
                rescannedAlbumsByID: [missingCoverAlbum.id: coveredAlbum]
            )
            let monitor = ControllableLibraryChangeMonitor()
            let appModel = await makeRealtimeRefreshAppModel(
                root: root,
                scanner: scanner,
                monitor: monitor,
                localLLM: AppConfiguration.LocalLLM(isEnabled: false)
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            await waitUntil { monitor.hasSubscriber(for: root) }
            #expect(appModel.scanResultsByLibraryID[libraryID]?.albums.first?.displayedCover == nil)

            monitor.emit(rootURL: root, changedPaths: ["Artist/Album/cover.jpg"])
            await waitUntil { await scanner.rescanCount() == 1 }

            #expect(await scanner.scanCount() == 1)
            #expect(await scanner.rescannedAlbumIDs() == [missingCoverAlbum.id])
            #expect(appModel.scanResultsByLibraryID[libraryID]?.albums.first?.displayedCover?.relativePath == "cover.jpg")
            #expect(appModel.realtimeRefreshMessage(for: libraryID)?.contains("局部刷新") == true)
        }
    }

    @Test("实时局部刷新后专辑变成缺封面会进入名称增强队列")
    func realtimeRefreshEnhancesAlbumThatBecomesMissingCover() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let coveredAlbum = makeAlbum(
                folderURL: albumFolder,
                albumName: "Album",
                hasCover: true,
                audioRelativePaths: ["01.flac"]
            )
            let missingAfterRefresh = makeAlbum(
                folderURL: albumFolder,
                albumName: "Album",
                audioRelativePaths: ["01.flac"]
            )
            let scanner = RecordingAlbumRescanLibraryScanner(
                initialResult: LibraryScanResult(albums: [coveredAlbum], looseAudioPaths: []),
                rescannedAlbumsByID: [coveredAlbum.id: missingAfterRefresh]
            )
            let monitor = ControllableLibraryChangeMonitor()
            let recorder = AlbumNameSuggestionRecorder()
            let appModel = await makeRealtimeRefreshAppModel(
                root: root,
                scanner: scanner,
                monitor: monitor,
                albumNameSuggesting: RecordingAlbumNameSuggesting(recorder: recorder),
                localLLM: AppConfiguration.LocalLLM(isEnabled: true)
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            try await Task.sleep(nanoseconds: 60_000_000)
            #expect(await recorder.albumNames() == [])
            await waitUntil { monitor.hasSubscriber(for: root) }

            monitor.emit(rootURL: root, changedPaths: ["Artist/Album/cover.jpg"])
            await waitUntil { await scanner.rescanCount() == 1 }
            await waitUntil { await recorder.albumNames() == ["Album"] }

            #expect(appModel.scanResultsByLibraryID[libraryID]?.albums.first?.displayedCover == nil)
            #expect(await recorder.albumNames() == ["Album"])
        }
    }

    @Test("App 内保存封面会立即更新封面墙且不会触发实时刷新")
    func savingCoverInsideAppDoesNotTriggerRealtimeRefresh() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let sourceURL = root.appendingPathComponent("source.png")
            try writeValidPNG(to: sourceURL)
            let missingCoverAlbum = makeAlbum(
                folderURL: albumFolder,
                albumName: "Album"
            )
            let scanner = RecordingAlbumRescanLibraryScanner(
                initialResult: LibraryScanResult(albums: [missingCoverAlbum], looseAudioPaths: []),
                rescannedAlbumsByID: [missingCoverAlbum.id: missingCoverAlbum]
            )
            let monitor = ControllableLibraryChangeMonitor()
            let appModel = await makeRealtimeRefreshAppModel(
                root: root,
                scanner: scanner,
                monitor: monitor,
                localLLM: AppConfiguration.LocalLLM(isEnabled: false)
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            await waitUntil { monitor.hasSubscriber(for: root) }

            appModel.stageCoverImage(sourceURL, forAlbumID: missingCoverAlbum.id)
            let didWrite = await appModel.savePendingCoverImage(forAlbumID: missingCoverAlbum.id)

            #expect(didWrite)
            #expect(await scanner.scanCount() == 1)
            #expect(await scanner.rescanCount() == 0)
            #expect(appModel.scanResultsByLibraryID[libraryID]?.albums.first?.displayedCover?.relativePath == "cover.jpg")

            monitor.emit(rootURL: root, changedPaths: [
                "Artist/Album/cover.jpg",
                "Artist/Album"
            ])
            try await Task.sleep(nanoseconds: 160_000_000)

            #expect(await scanner.rescanCount() == 0)
            #expect(appModel.scanResultsByLibraryID[libraryID]?.albums.first?.displayedCover?.relativePath == "cover.jpg")
        }
    }

    @Test("App 内保存封面不会启动新的名称增强")
    func savingCoverInsideAppDoesNotTriggerAlbumNameEnhancement() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let sourceURL = root.appendingPathComponent("source.png")
            try writeValidPNG(to: sourceURL)
            let missingCoverAlbum = makeAlbum(
                folderURL: albumFolder,
                albumName: "Album"
            )
            let scanner = RecordingAlbumRescanLibraryScanner(
                initialResult: LibraryScanResult(albums: [missingCoverAlbum], looseAudioPaths: []),
                rescannedAlbumsByID: [missingCoverAlbum.id: missingCoverAlbum]
            )
            let monitor = ControllableLibraryChangeMonitor()
            let recorder = AlbumNameSuggestionRecorder()
            let appModel = await makeRealtimeRefreshAppModel(
                root: root,
                scanner: scanner,
                monitor: monitor,
                albumNameSuggesting: RecordingAlbumNameSuggesting(recorder: recorder),
                localLLM: AppConfiguration.LocalLLM(isEnabled: true)
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)
            await recorder.reset()

            appModel.stageCoverImage(sourceURL, forAlbumID: missingCoverAlbum.id)
            let didWrite = await appModel.savePendingCoverImage(forAlbumID: missingCoverAlbum.id)
            monitor.emit(rootURL: root, changedPaths: [
                "Artist/Album/cover.jpg",
                "Artist/Album"
            ])
            try await Task.sleep(nanoseconds: 160_000_000)

            #expect(didWrite)
            #expect(await scanner.rescanCount() == 0)
            #expect(await recorder.albumNames() == [])
            #expect(appModel.scanResultsByLibraryID[libraryID]?.albums.first?.displayedCover?.relativePath == "cover.jpg")
        }
    }

    @Test("无关目录事件不会触发自动刷新")
    func realtimeRefreshIgnoresIrrelevantFileEvents() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let album = makeAlbum(
                folderURL: albumFolder,
                albumName: "Album"
            )
            let scanner = SequencedLibraryScanner(outcomes: [
                .success(LibraryScanResult(albums: [album], looseAudioPaths: []))
            ])
            let monitor = ControllableLibraryChangeMonitor()
            let appModel = await makeRealtimeRefreshAppModel(
                root: root,
                scanner: scanner,
                monitor: monitor,
                localLLM: AppConfiguration.LocalLLM(isEnabled: false)
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            await waitUntil { monitor.hasSubscriber(for: root) }

            monitor.emit(rootURL: root, changedPaths: ["Artist/Album/Thumbs.db"])
            monitor.emit(rootURL: root, changedPaths: ["Artist/Album/.DS_Store"])
            monitor.emit(rootURL: root, changedPaths: ["Artist"])
            monitor.emit(rootURL: root, changedPaths: ["Artist/Album"])
            monitor.emit(rootURL: root, changedPaths: [root.path])
            try await Task.sleep(nanoseconds: 120_000_000)

            #expect(await scanner.scanCount() == 1)
            #expect(appModel.realtimeRefreshMessage(for: libraryID) == nil)
        }
    }

    @Test("实时局部刷新失败时保留旧结果且不回退全量扫描")
    func realtimeRefreshFailureKeepsPreviousResult() async throws {
        try await withTemporaryDirectory { root in
            let album = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Before", isDirectory: true),
                albumName: "Album"
            )
            let scanner = FailingAlbumRescanLibraryScanner(
                initialResult: LibraryScanResult(albums: [album], looseAudioPaths: []),
                message: "磁盘暂时不可读"
            )
            let monitor = ControllableLibraryChangeMonitor()
            let appModel = await makeRealtimeRefreshAppModel(
                root: root,
                scanner: scanner,
                monitor: monitor,
                localLLM: AppConfiguration.LocalLLM(isEnabled: false)
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            await waitUntil { monitor.hasSubscriber(for: root) }

            monitor.emit(rootURL: root, changedPaths: ["Artist/Before/cover.jpg"])
            await waitUntil { await scanner.rescanCount() == 1 }

            #expect(await scanner.scanCount() == 1)
            #expect(appModel.scanResultsByLibraryID[libraryID]?.albums.first?.albumName == "Album")
            #expect(appModel.realtimeRefreshMessage(for: libraryID)?.contains("局部刷新失败") == true)
            #expect(appModel.realtimeRefreshMessage(for: libraryID)?.contains("已保留旧扫描结果") == true)
        }
    }

    @Test("实时局部刷新只为音频结构变化的专辑重新增强名称")
    func realtimeRefreshOnlyEnhancesChangedAlbums() async throws {
        try await withTemporaryDirectory { root in
            let unchangedAlbum = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Unchanged", isDirectory: true),
                albumName: "Unchanged",
                audioRelativePaths: ["01.flac"]
            )
            let changedAlbum = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Changed", isDirectory: true),
                albumName: "Changed",
                audioRelativePaths: ["01.wav"]
            )
            let changedAlbumAfterRefresh = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Changed", isDirectory: true),
                albumName: "Changed",
                audioRelativePaths: ["01.wav", "02.wav"]
            )
            let scanner = RecordingAlbumRescanLibraryScanner(
                initialResult: LibraryScanResult(albums: [unchangedAlbum, changedAlbum], looseAudioPaths: []),
                rescannedAlbumsByID: [changedAlbum.id: changedAlbumAfterRefresh]
            )
            let monitor = ControllableLibraryChangeMonitor()
            let recorder = AlbumNameSuggestionRecorder()
            let appModel = await makeRealtimeRefreshAppModel(
                root: root,
                scanner: scanner,
                monitor: monitor,
                albumNameSuggesting: RecordingAlbumNameSuggesting(recorder: recorder),
                localLLM: AppConfiguration.LocalLLM(isEnabled: true)
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)
            #expect(appModel.hasEnhancedAlbumName(for: unchangedAlbum, in: libraryID))
            await recorder.reset()
            await waitUntil { monitor.hasSubscriber(for: root) }

            monitor.emit(rootURL: root, changedPaths: ["Artist/Changed/02.wav"])
            await waitUntil { await scanner.rescanCount() == 1 }
            await waitUntil { await recorder.albumNames() == ["Changed"] }

            #expect(await scanner.scanCount() == 1)
            #expect(appModel.hasEnhancedAlbumName(for: unchangedAlbum, in: libraryID))
            #expect(await recorder.albumNames() == ["Changed"])
        }
    }

    @Test("实时局部刷新会并发重扫多个变更专辑")
    func realtimeRefreshRescansChangedAlbumsConcurrently() async throws {
        try await withTemporaryDirectory { root in
            let firstAlbum = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/First", isDirectory: true),
                albumName: "First",
                audioRelativePaths: ["01.wav"]
            )
            let secondAlbum = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Second", isDirectory: true),
                albumName: "Second",
                audioRelativePaths: ["01.wav"]
            )
            let refreshedFirstAlbum = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/First", isDirectory: true),
                albumName: "First",
                audioRelativePaths: ["01.wav", "02.wav"]
            )
            let refreshedSecondAlbum = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Second", isDirectory: true),
                albumName: "Second",
                audioRelativePaths: ["01.wav", "02.wav"]
            )
            let scanner = RecordingAlbumRescanLibraryScanner(
                initialResult: LibraryScanResult(albums: [firstAlbum, secondAlbum], looseAudioPaths: []),
                rescannedAlbumsByID: [
                    firstAlbum.id: refreshedFirstAlbum,
                    secondAlbum.id: refreshedSecondAlbum
                ],
                rescanDelayNanoseconds: 120_000_000
            )
            let monitor = ControllableLibraryChangeMonitor()
            let appModel = await makeRealtimeRefreshAppModel(
                root: root,
                scanner: scanner,
                monitor: monitor,
                localLLM: AppConfiguration.LocalLLM(isEnabled: false)
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            await waitUntil { monitor.hasSubscriber(for: root) }

            monitor.emit(rootURL: root, changedPaths: [
                "Artist/First/02.wav",
                "Artist/Second/02.wav"
            ])

            await waitUntil { await scanner.maxActiveRescans() == 2 }
            await waitUntil { appModel.realtimeRefreshMessage(for: libraryID)?.contains("局部刷新") == true }

            #expect(await scanner.rescanCount() == 2)
            #expect(appModel.scanResultsByLibraryID[libraryID]?.albums.count == 2)
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

private final class ThreadRecordingLibraryScanner: LibraryScanning, @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var didRunOnMainThread: Bool?

    nonisolated func scan(
        libraryURL: URL,
        role: LibraryRole,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> LibraryScanResult {
        lock.withLock {
            didRunOnMainThread = Thread.isMainThread
        }
        await progress(LibraryScanProgress(
            phase: .finishing,
            targetPath: libraryURL.path,
            completedAlbums: 0,
            totalAlbums: 0,
            completedFilesInAlbum: nil,
            totalFilesInAlbum: nil
        ))
        return LibraryScanResult(albums: [], looseAudioPaths: [])
    }

    func scanRanOnMainThread() -> Bool? {
        lock.withLock {
            didRunOnMainThread
        }
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

private actor RecordingCoverDetector: CoverDetecting {
    private let result: CoverDetectionResult
    private var count = 0
    private var albumURLs: [URL] = []

    init(result: CoverDetectionResult) {
        self.result = result
    }

    func detectCover(in albumURL: URL) async throws -> CoverDetectionResult {
        count += 1
        albumURLs.append(albumURL)
        return result
    }

    func detectCount() -> Int {
        count
    }

    func detectedAlbumURLs() -> [URL] {
        albumURLs
    }
}

private struct StubAlbumNameSuggesting: AlbumNameSuggesting {
    enum Outcome: Sendable {
        case success(AlbumNameSuggestion)
        case failure(String)
    }

    let outcome: Outcome

    func suggestAlbumName(for input: AlbumNameEnhancementInput) async throws -> AlbumNameSuggestion {
        switch outcome {
        case .success(let suggestion):
            return suggestion
        case .failure(let message):
            throw StubAlbumNameSuggestingError(message: message)
        }
    }
}

private struct StubAlbumNameSuggestingError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

private actor AlbumNameSuggestionRecorder {
    private var processedAlbumNames: [String] = []

    func record(albumName: String) {
        processedAlbumNames.append(albumName)
    }

    func albumNames() -> [String] {
        processedAlbumNames
    }

    func reset() {
        processedAlbumNames = []
    }
}

private struct RecordingAlbumNameSuggesting: AlbumNameSuggesting {
    let recorder: AlbumNameSuggestionRecorder

    func suggestAlbumName(for input: AlbumNameEnhancementInput) async throws -> AlbumNameSuggestion {
        await recorder.record(albumName: input.originalAlbumName)
        return AlbumNameSuggestion(
            artistName: input.originalArtistName,
            albumName: input.originalAlbumName
        )
    }
}

private final class ReleasingAlbumNameSuggesting: AlbumNameSuggestingResourceReleasing, @unchecked Sendable {
    private let lock = NSLock()
    private var releases = 0

    func suggestAlbumName(for input: AlbumNameEnhancementInput) async throws -> AlbumNameSuggestion {
        AlbumNameSuggestion(
            artistName: input.originalArtistName,
            albumName: input.originalAlbumName
        )
    }

    func releaseResources() async {
        lock.withLock {
            releases += 1
        }
    }

    func releaseCount() -> Int {
        lock.withLock {
            releases
        }
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

private actor BlockingSecondScanLibraryScanner: LibraryScanning {
    private var outcomes: [LibraryScanResult]
    private var count = 0
    private var secondScanContinuation: CheckedContinuation<Void, Never>?
    private var isSecondScanReleased = false

    init(outcomes: [LibraryScanResult]) {
        self.outcomes = outcomes
    }

    func scan(
        libraryURL: URL,
        role: LibraryRole,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> LibraryScanResult {
        count += 1
        let currentCount = count
        if currentCount == 2 {
            await waitForSecondScanRelease()
        }
        let index = min(currentCount - 1, max(0, outcomes.count - 1))
        return outcomes[index]
    }

    func scanCount() -> Int {
        count
    }

    func releaseSecondScan() {
        isSecondScanReleased = true
        secondScanContinuation?.resume()
        secondScanContinuation = nil
    }

    private func waitForSecondScanRelease() async {
        guard !isSecondScanReleased else { return }
        await withCheckedContinuation { continuation in
            secondScanContinuation = continuation
        }
    }
}

private actor SequencedLibraryScanner: LibraryScanning {
    enum Outcome: Sendable {
        case success(LibraryScanResult)
        case failure(String)
    }

    private var outcomes: [Outcome]
    private var count = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func scan(
        libraryURL: URL,
        role: LibraryRole,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> LibraryScanResult {
        count += 1
        let index = min(count - 1, max(0, outcomes.count - 1))
        switch outcomes[index] {
        case .success(let result):
            return result
        case .failure(let message):
            throw SequencedLibraryScannerError(message: message)
        }
    }

    func scanCount() -> Int {
        count
    }
}

private actor RecordingAlbumRescanLibraryScanner: LibraryScanning, AlbumRescanning {
    private let initialResult: LibraryScanResult
    private let rescannedAlbumsByID: [AlbumScanRecord.ID: AlbumScanRecord]
    private let rescanDelayNanoseconds: UInt64
    private var fullScanCount = 0
    private var albumRescanCount = 0
    private var activeAlbumRescanCount = 0
    private var maxActiveAlbumRescanCount = 0
    private var albumIDs: [AlbumScanRecord.ID] = []

    init(
        initialResult: LibraryScanResult,
        rescannedAlbumsByID: [AlbumScanRecord.ID: AlbumScanRecord],
        rescanDelayNanoseconds: UInt64 = 0
    ) {
        self.initialResult = initialResult
        self.rescannedAlbumsByID = rescannedAlbumsByID
        self.rescanDelayNanoseconds = rescanDelayNanoseconds
    }

    func scan(
        libraryURL: URL,
        role: LibraryRole,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> LibraryScanResult {
        fullScanCount += 1
        return initialResult
    }

    func rescanAlbum(
        _ album: AlbumScanRecord,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> AlbumScanRecord {
        albumRescanCount += 1
        activeAlbumRescanCount += 1
        maxActiveAlbumRescanCount = max(maxActiveAlbumRescanCount, activeAlbumRescanCount)
        defer {
            activeAlbumRescanCount -= 1
        }

        let albumID = await album.id
        albumIDs.append(albumID)
        if rescanDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: rescanDelayNanoseconds)
        }
        return rescannedAlbumsByID[albumID] ?? album
    }

    func scanCount() -> Int {
        fullScanCount
    }

    func rescanCount() -> Int {
        albumRescanCount
    }

    func rescannedAlbumIDs() -> [AlbumScanRecord.ID] {
        albumIDs
    }

    func maxActiveRescans() -> Int {
        maxActiveAlbumRescanCount
    }
}

private actor BlockingAlbumRescanLibraryScanner: LibraryScanning, AlbumRescanning {
    private let initialResult: LibraryScanResult
    private let rescanOutcomes: [AlbumScanRecord]
    private var fullScanCount = 0
    private var albumRescanCount = 0
    private var firstRescanContinuation: CheckedContinuation<Void, Never>?
    private var isFirstRescanReleased = false

    init(
        initialResult: LibraryScanResult,
        rescanOutcomes: [AlbumScanRecord]
    ) {
        self.initialResult = initialResult
        self.rescanOutcomes = rescanOutcomes
    }

    func scan(
        libraryURL: URL,
        role: LibraryRole,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> LibraryScanResult {
        fullScanCount += 1
        return initialResult
    }

    func rescanAlbum(
        _ album: AlbumScanRecord,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> AlbumScanRecord {
        albumRescanCount += 1
        let currentCount = albumRescanCount
        if currentCount == 1 {
            await waitForFirstRescanRelease()
        }
        let index = min(currentCount - 1, max(0, rescanOutcomes.count - 1))
        return rescanOutcomes[index]
    }

    func scanCount() -> Int {
        fullScanCount
    }

    func rescanCount() -> Int {
        albumRescanCount
    }

    func releaseFirstRescan() {
        isFirstRescanReleased = true
        firstRescanContinuation?.resume()
        firstRescanContinuation = nil
    }

    private func waitForFirstRescanRelease() async {
        guard !isFirstRescanReleased else { return }
        await withCheckedContinuation { continuation in
            firstRescanContinuation = continuation
        }
    }
}

private actor FailingAlbumRescanLibraryScanner: LibraryScanning, AlbumRescanning {
    private let initialResult: LibraryScanResult
    private let message: String
    private var fullScanCount = 0
    private var albumRescanCount = 0

    init(
        initialResult: LibraryScanResult,
        message: String
    ) {
        self.initialResult = initialResult
        self.message = message
    }

    func scan(
        libraryURL: URL,
        role: LibraryRole,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> LibraryScanResult {
        fullScanCount += 1
        return initialResult
    }

    func rescanAlbum(
        _ album: AlbumScanRecord,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> AlbumScanRecord {
        albumRescanCount += 1
        throw SequencedLibraryScannerError(message: message)
    }

    func scanCount() -> Int {
        fullScanCount
    }

    func rescanCount() -> Int {
        albumRescanCount
    }
}

private struct SequencedLibraryScannerError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

private final class ControllableLibraryChangeMonitor: LibraryChangeMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var continuationsByRootPath: [String: AsyncThrowingStream<LibraryChangeEvent, Error>.Continuation] = [:]

    func events(for rootURL: URL) -> AsyncThrowingStream<LibraryChangeEvent, Error> {
        let rootPath = rootURL.standardizedFileURL.path
        return AsyncThrowingStream { continuation in
            lock.withLock {
                continuationsByRootPath[rootPath] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.continuationsByRootPath[rootPath] = nil
                }
            }
        }
    }

    func emit(rootURL: URL, changedPaths: [String]) {
        let rootPath = rootURL.standardizedFileURL.path
        let continuation = lock.withLock {
            continuationsByRootPath[rootPath]
        }
        continuation?.yield(LibraryChangeEvent(
            rootURL: rootURL,
            changedPaths: changedPaths
        ))
    }

    func hasSubscriber(for rootURL: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        return lock.withLock {
            continuationsByRootPath[rootPath] != nil
        }
    }
}

private actor RecordingScanSnapshotStore: ScanSnapshotStoring {
    private let root: URL
    private var savedSnapshots: [ScanSnapshot] = []
    private var replacedSnapshots: [ScanSnapshot] = []

    init(root: URL) {
        self.root = root
    }

    func saveNewSnapshot(_ snapshot: ScanSnapshot) async throws -> ScanSnapshotSummary {
        savedSnapshots.append(snapshot)
        let fileURL = root.appendingPathComponent("snapshot-\(savedSnapshots.count).json")
        return await summary(for: snapshot, fileURL: fileURL)
    }

    func replaceSnapshot(_ snapshot: ScanSnapshot, at fileURL: URL) async throws -> ScanSnapshotSummary {
        replacedSnapshots.append(snapshot)
        return await summary(for: snapshot, fileURL: fileURL)
    }

    func latestSnapshot(for library: LibraryRecord) async throws -> ScanSnapshotSummary? {
        nil
    }

    func loadSnapshot(at fileURL: URL, expectedLibrary: LibraryRecord) async throws -> ScanSnapshot {
        throw RecordingScanSnapshotStoreError()
    }

    func saveCount() -> Int {
        savedSnapshots.count
    }

    func replaceCount() -> Int {
        replacedSnapshots.count
    }

    private nonisolated func summary(
        for snapshot: ScanSnapshot,
        fileURL: URL
    ) async -> ScanSnapshotSummary {
        await MainActor.run {
            ScanSnapshotSummary(
                fileURL: fileURL,
                schemaVersion: snapshot.schemaVersion,
                createdAt: snapshot.createdAt,
                libraryDisplayName: snapshot.library.displayName,
                libraryRootPath: snapshot.library.rootPath,
                libraryRole: snapshot.library.role,
                albumCount: snapshot.scanResult.albums.count
            )
        }
    }
}

private struct RecordingScanSnapshotStoreError: LocalizedError, Sendable {
    var errorDescription: String? {
        "测试快照不可加载。"
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
    albums: [AlbumScanRecord],
    albumNameSuggesting: any AlbumNameSuggesting = DisabledAlbumNameSuggesting()
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
        coverImageWriter: ImageIOCoverImageWriter(),
        albumNameSuggesting: albumNameSuggesting
    )
    let appModel = AppModel(environment: environment)
    await appModel.prepareImport(url: root)
    await appModel.confirmImport(role: .library)
    await appModel.scanSelectedLibrary()
    return appModel
}

@MainActor
private func makeRealtimeRefreshAppModel(
    root: URL,
    scanner: any LibraryScanning,
    monitor: any LibraryChangeMonitoring,
    snapshotStore: any ScanSnapshotStoring = DisabledScanSnapshotStore(),
    coverDetector: any CoverDetecting = ImageIOCoverDetector(),
    albumNameSuggesting: any AlbumNameSuggesting = DisabledAlbumNameSuggesting(),
    localLLM: AppConfiguration.LocalLLM
) async -> AppModel {
    let store = MemoryLibraryStore()
    let environment = AppEnvironment(
        configuration: AppConfiguration(
            realtimeScanRefresh: AppConfiguration.RealtimeScanRefresh(debounceSeconds: 0.05),
            localLLM: localLLM
        ),
        libraryStore: store,
        folderAccess: StubFolderAccess(),
        roleProber: StubRoleProber(role: .library),
        libraryScanner: scanner,
        libraryChangeMonitor: monitor,
        coverImageWriter: ImageIOCoverImageWriter(),
        coverDetector: coverDetector,
        albumNameSuggesting: albumNameSuggesting,
        scanSnapshotStore: snapshotStore
    )
    let appModel = AppModel(environment: environment)
    await appModel.prepareImport(url: root)
    await appModel.confirmImport(role: .library)
    await appModel.scanSelectedLibrary()
    return appModel
}

@MainActor
private func waitForAlbumNameEnhancement(
    toFinishIn appModel: AppModel,
    libraryID: LibraryRecord.ID
) async {
    for _ in 0..<200 {
        if let status = appModel.albumNameEnhancementStatus(for: libraryID),
           !status.isRunning {
            return
        }
        await Task.yield()
    }
}

private func makeAlbum(
    folderURL: URL,
    albumName: String,
    hasCover: Bool = false,
    audioRelativePaths: [String] = []
) -> AlbumScanRecord {
    AlbumScanRecord(
        folderURL: folderURL,
        artistName: "Artist",
        albumName: albumName,
        audioFiles: audioRelativePaths.map { relativePath in
            AudioFileRecord(
                url: folderURL.appendingPathComponent(relativePath),
                relativePath: relativePath,
                format: URL(fileURLWithPath: relativePath).pathExtension,
                metadata: nil,
                readError: nil
            )
        },
        displayedCover: hasCover ? CoverCandidate(
            url: folderURL.appendingPathComponent("cover.jpg"),
            relativePath: "cover.jpg",
            namePriority: 0,
            depth: 0,
            source: .file
        ) : nil,
        issues: []
    )
}

private func waitUntil(
    _ condition: @escaping () async -> Bool
) async {
    for _ in 0..<200 {
        if await condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

private func waitUntil(
    _ condition: @escaping () -> Bool
) async {
    let asyncCondition: () async -> Bool = {
        condition()
    }
    await waitUntil(asyncCondition)
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
