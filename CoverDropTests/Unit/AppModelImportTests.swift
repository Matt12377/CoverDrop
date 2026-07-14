import Foundation
import Combine
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

    @Test("五万张专辑下 AppModel 公开读取方法保持交互预算")
    func indexedPublicReadsStayUnderInteractionBudgetForLargeLibrary() async {
        let root = URL(fileURLWithPath: "/tmp/coverdrop-large-library", isDirectory: true)
        let albums = (0..<50_000).map { index in
            performanceAlbum(index: index, hasCover: index.isMultiple(of: 2))
        }
        let store = MemoryLibraryStore()
        let environment = AppEnvironment(
            configuration: AppConfiguration(localLLM: AppConfiguration.LocalLLM(isEnabled: false)),
            libraryStore: store,
            folderAccess: StubFolderAccess(),
            roleProber: StubRoleProber(role: .library),
            libraryScanner: StubLibraryScanner(result: LibraryScanResult(albums: albums, looseAudioPaths: [])),
            coverImageWriter: StubCoverImageWriter()
        )
        let appModel = AppModel(environment: environment)
        await appModel.prepareImport(url: root)
        await appModel.confirmImport(role: .library)
        await appModel.scanSelectedLibrary()
        let lastAlbumID = albums[49_999].id

        let lookup = measured {
            #expect(appModel.albumInSelectedLibrary(id: lastAlbumID)?.albumName == "专辑 49999")
        }
        let stats = measured {
            #expect(appModel.scanResultStats(for: appModel.selectedLibraryID!)?.albumsWithCover == 25_000)
        }
        let filter = measured {
            #expect(appModel.filteredAlbumsInSelectedLibrary(filter: .withCover, query: "").count == 25_000)
        }
        let noHitSearch = measured {
            #expect(appModel.filteredAlbumsInSelectedLibrary(filter: .all, query: "不会命中的搜索词").isEmpty)
        }

        #expect(lookup < 0.1, "AppModel albumID 查找耗时 \(lookup) 秒")
        #expect(stats < 0.1, "AppModel 统计读取耗时 \(stats) 秒")
        #expect(filter < 0.1, "AppModel 筛选耗时 \(filter) 秒")
        #expect(noHitSearch < 0.1, "AppModel 无命中搜索耗时 \(noHitSearch) 秒")
    }

    @Test("AppModel 提供预计算的封面墙卡片快照")
    func appModelProvidesCoverWallSnapshot() async throws {
        try await withTemporaryDirectory { root in
            let first = makeAlbum(
                folderURL: root.appendingPathComponent("歌手/第一张", isDirectory: true),
                albumName: "第一张",
                audioRelativePaths: ["01.flac", "02.wav"]
            )
            let second = makeAlbum(
                folderURL: root.appendingPathComponent("歌手/第二张", isDirectory: true),
                albumName: "第二张"
            )
            let appModel = await makeScannedAppModel(root: root, albums: [first, second])

            let snapshot = appModel.coverWallSnapshotInSelectedLibrary(
                filter: .all,
                query: ""
            )

            #expect(snapshot.cards.map(\.id) == [first.id, second.id])
            #expect(snapshot.cards.first?.displayAlbumName == "第一张")
            #expect(snapshot.cards.first?.formatTags == ["FLAC", "WAV"])
        }
    }

    @Test("详情和搜索重复读取复用封面墙预计算展示名")
    func repeatedDetailDisplayNameReadsReusePrecomputedPresentation() async {
        let root = URL(fileURLWithPath: "/tmp/coverdrop-precomputed-detail-names", isDirectory: true)
        let folderURL = root.appendingPathComponent("SHE合集/2005-I...Do", isDirectory: true)
        let metadata = AudioMetadata(
            title: nil,
            artist: "S.H.E",
            albumArtist: "S.H.E",
            album: "I DO",
            discNumber: nil,
            trackNumber: nil,
            durationSeconds: nil
        )
        let album = AlbumScanRecord(
            folderURL: folderURL,
            artistName: "SHE合集【qobuz】",
            albumName: "2005-I...Do",
            audioFiles: (0..<5_000).map { index in
                AudioFileRecord(
                    url: folderURL.appendingPathComponent("\(index).flac"),
                    relativePath: "\(index).flac",
                    format: "flac",
                    metadata: metadata,
                    readError: nil
                )
            },
            displayedCover: nil,
            issues: []
        )
        let appModel = await makeScannedAppModel(root: root, albums: [album])

        let elapsed = measured {
            for _ in 0..<20 {
                #expect(appModel.displayArtistName(for: album) == "S.H.E")
                #expect(appModel.displayAlbumName(for: album) == "I DO")
                #expect(appModel.searchKeyword(for: album) == "S.H.E I DO")
            }
        }

        #expect(elapsed < 0.1, "重复读取预计算展示名耗时 \(elapsed) 秒")
    }

    @Test("较早开始的后台索引构建不会覆盖较新的扫描结果")
    func staleBackgroundDisplayIndexBuildDoesNotOverwriteNewerResult() async {
        let root = URL(fileURLWithPath: "/tmp/coverdrop-index-generation", isDirectory: true)
        let appModel = await makeScannedAppModel(root: root, albums: [])
        let libraryID = appModel.selectedLibraryID!
        let slowResult = LibraryScanResult(
            albums: (0..<5_000).map { index in
                performanceAlbum(index: index, hasCover: false)
            },
            looseAudioPaths: []
        )
        let latestAlbum = performanceAlbum(index: 99_999, hasCover: true)
        let latestResult = LibraryScanResult(albums: [latestAlbum], looseAudioPaths: [])

        let slowUpdate = Task {
            await appModel.setScanResult(slowResult, for: libraryID)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await appModel.setScanResult(latestResult, for: libraryID)
        _ = await slowUpdate.value

        #expect(appModel.scanResultStats(for: libraryID)?.albumCount == 1)
        #expect(appModel.albumInSelectedLibrary(id: latestAlbum.id)?.id == latestAlbum.id)
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

    @Test("重新扫描失败时保留旧结果的名称增强一致性")
    func failedRescanKeepsExistingNameEnhancementConsistent() async throws {
        let oldAlbum = makeAlbum(
            folderURL: URL(fileURLWithPath: "/Volumes/华语/Artist/Old", isDirectory: true),
            albumName: "原始专辑"
        )
        let rescannedAlbum = makeAlbum(
            folderURL: oldAlbum.folderURL,
            albumName: "重新扫描专辑"
        )
        let scanner = SequencedLibraryScanner(outcomes: [
            .success(LibraryScanResult(albums: [oldAlbum], looseAudioPaths: [])),
            .failure("磁盘暂时不可读"),
            .success(LibraryScanResult(albums: [rescannedAlbum], looseAudioPaths: []))
        ])
        let environment = AppEnvironment(
            libraryStore: MemoryLibraryStore(),
            folderAccess: StubFolderAccess(),
            roleProber: StubRoleProber(role: .library),
            libraryScanner: scanner,
            coverImageWriter: StubCoverImageWriter(),
            albumNameSuggesting: StubAlbumNameSuggesting(
                outcome: .success(AlbumNameSuggestion(
                    artistName: "增强歌手",
                    albumName: "增强专辑"
                ))
            )
        )
        let appModel = AppModel(environment: environment)

        await appModel.prepareImport(url: URL(fileURLWithPath: "/Volumes/华语", isDirectory: true))
        await appModel.confirmImport(role: .library)
        await appModel.scanSelectedLibrary()
        let libraryID = try #require(appModel.selectedLibraryID)
        appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)
        await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)

        await appModel.scanSelectedLibrary()

        let snapshot = appModel.coverWallSnapshotInSelectedLibrary(filter: .all, query: "")
        #expect(appModel.errorMessage?.contains("磁盘暂时不可读") == true)
        #expect(appModel.hasEnhancedAlbumName(for: oldAlbum))
        #expect(appModel.displayArtistName(for: oldAlbum) == "增强歌手")
        #expect(appModel.displayAlbumName(for: oldAlbum) == "增强专辑")
        #expect(snapshot.cards.first?.hasEnhancedName == true)
        #expect(snapshot.cards.first?.displayAlbumName == "增强专辑")

        await appModel.scanSelectedLibrary()

        #expect(appModel.hasEnhancedAlbumName(for: rescannedAlbum) == false)
        #expect(appModel.displayAlbumName(for: rescannedAlbum) == "重新扫描专辑")
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

    @Test("预取远程封面不会设置待保存状态")
    func prefetchingRemoteCoverDoesNotStageImage() {
        let appModel = AppModel(environment: AppEnvironment(
            libraryStore: MemoryLibraryStore(),
            folderAccess: StubFolderAccess(),
            roleProber: StubRoleProber(role: .library),
            libraryScanner: StubLibraryScanner(),
            coverImageWriter: StubCoverImageWriter()
        ))
        let album = makeAlbum(
            folderURL: URL(fileURLWithPath: "/tmp/CoverDrop/Artist/Album", isDirectory: true),
            albumName: "Album"
        )

        appModel.prefetchRemoteCoverImage(at: URL(fileURLWithPath: "/tmp/cover.jpg"))

        #expect(appModel.pendingCoverURL(for: album.id) == nil)
    }

    @Test("拖入网页图片数据后会先暂存为本地待保存封面")
    func stagedCoverImageDataCreatesLocalPendingCover() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let appModel = await makeScannedAppModel(root: root, albums: [album])

            let didStage = await appModel.stageCoverImageData(
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

            let didStage = await appModel.stageCoverImageData(
                Data("这不是图片".utf8),
                suggestedExtension: "jpg",
                forAlbumID: album.id
            )

            #expect(!didStage)
            #expect(appModel.pendingCoverURL(for: album.id) == nil)
            #expect(appModel.errorMessage != nil)
        }
    }

    @Test("较早但较慢的拖图任务不会覆盖较新的待保存封面")
    func staleStagingCompletionDoesNotOverwriteNewerCover() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let firstStagedURL = root.appendingPathComponent("first-staged.png")
            let secondStagedURL = root.appendingPathComponent("second-staged.png")
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let stager = ControlledCoverImageStager()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                coverImageStager: stager
            )

            let firstRequest = Task {
                await appModel.stageCoverImageData(
                    Data([1]),
                    suggestedExtension: "png",
                    forAlbumID: album.id
                )
            }
            await stager.waitUntilRequestCount(1)
            let secondRequest = Task {
                await appModel.stageCoverImageData(
                    Data([2]),
                    suggestedExtension: "png",
                    forAlbumID: album.id
                )
            }
            await stager.waitUntilRequestCount(2)

            await stager.succeedRequest(at: 1, with: secondStagedURL)
            #expect(await secondRequest.value)
            await stager.succeedRequest(at: 0, with: firstStagedURL)

            #expect(!(await firstRequest.value))
            #expect(appModel.pendingCoverURL(for: album.id) == secondStagedURL)
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

    @Test("取消不存在的待保存封面不会发布状态变化")
    func cancellingMissingPendingCoverDoesNotPublishChange() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let appModel = await makeScannedAppModel(root: root, albums: [album])
            let counter = ObjectWillChangeCounter()
            let cancellable = appModel.objectWillChange.sink {
                counter.increment()
            }

            appModel.cancelPendingCoverImage(forAlbumID: album.id)

            #expect(counter.value == 0)
            withExtendedLifetime(cancellable) {}
        }
    }

    @Test("普通打开详情不会清除已拖入的待保存封面")
    func openingDetailWithoutNewCoverKeepsPendingCover() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let sourceURL = root.appendingPathComponent("source.png")
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            try writeValidPNG(to: sourceURL)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let appModel = await makeScannedAppModel(root: root, albums: [album])
            appModel.stageCoverImage(sourceURL, forAlbumID: album.id)

            appModel.stageCoverImageIfProvided(nil, forAlbumID: album.id)

            #expect(appModel.pendingCoverURL(for: album.id) == sourceURL)
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
            #expect(appModel.scanResultForSelectedLibrary?.albums.first?.displayedCover == cover)
            await waitUntil {
                appModel.albumInSelectedLibrary(id: album.id)?.displayedCover?.previewURL != nil
            }
            let refreshedCover = try #require(appModel.albumInSelectedLibrary(id: album.id)?.displayedCover)
            let previewURL = try #require(refreshedCover.previewURL)
            #expect(refreshedCover.displayURL == previewURL)
            #expect(FileManager.default.fileExists(atPath: previewURL.path))
        }
    }

    @Test("保存封面后只增量更新当前专辑的 SQLite 快照封面列")
    func savingCoverUsesIncrementalSnapshotUpdate() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let sourceURL = root.appendingPathComponent("source.png")
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            try writeValidPNG(to: sourceURL)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let snapshotStore = RecordingScanSnapshotStore(root: root)
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                snapshotStore: snapshotStore
            )

            appModel.stageCoverImage(sourceURL, forAlbumID: album.id)
            let didWrite = await appModel.savePendingCoverImage(forAlbumID: album.id)
            await waitUntil { await snapshotStore.coverUpdateCount() == 1 }

            #expect(didWrite)
            #expect(await snapshotStore.coverUpdateCount() == 1)
            #expect(await snapshotStore.lastUpdatedAlbumID() == album.id)
            #expect(await snapshotStore.lastUpdatedCover()?.relativePath == "cover.jpg")
            #expect(await snapshotStore.replaceCount() == 0)
        }
    }

    @Test("保存时专辑目录不存在会提示未找到专辑")
    func savingCoverReportsMissingAlbumWhenAlbumFolderDisappears() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let sourceURL = root.appendingPathComponent("source.png")
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            try writeValidPNG(to: sourceURL)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let writer = CountingCoverImageWriter()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                coverImageWriter: writer
            )

            appModel.stageCoverImage(sourceURL, forAlbumID: album.id)
            try FileManager.default.removeItem(at: albumFolder)
            let didWrite = await appModel.savePendingCoverImage(forAlbumID: album.id)

            #expect(!didWrite)
            #expect(appModel.errorMessage?.contains("未找到专辑") == true)
            #expect(appModel.pendingCoverURL(for: album.id) == sourceURL)
            #expect(await writer.writeCount() == 0)
        }
    }

    @Test("检查到专辑目录已删除时会从当前封面墙移除")
    func missingAlbumFolderCheckRemovesAlbumFromCurrentScanResult() async throws {
        try await withTemporaryDirectory { root in
            let removedFolder = root.appendingPathComponent("Artist/Removed", isDirectory: true)
            let keptFolder = root.appendingPathComponent("Artist/Kept", isDirectory: true)
            try FileManager.default.createDirectory(at: removedFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: keptFolder, withIntermediateDirectories: true)
            let removedAlbum = makeAlbum(folderURL: removedFolder, albumName: "Removed")
            let keptAlbum = makeAlbum(folderURL: keptFolder, albumName: "Kept")
            let appModel = await makeScannedAppModel(root: root, albums: [removedAlbum, keptAlbum])

            try FileManager.default.removeItem(at: removedFolder)
            let didRemove = await appModel.removeAlbumIfFolderMissing(albumID: removedAlbum.id)

            #expect(didRemove)
            #expect(appModel.albumInSelectedLibrary(id: removedAlbum.id) == nil)
            #expect(appModel.albumInSelectedLibrary(id: keptAlbum.id) != nil)
            #expect(appModel.scanResultForSelectedLibrary?.albums.map(\.id) == [keptAlbum.id])
        }
    }

    @Test("专辑目录仍存在时检查不会误删")
    func existingAlbumFolderCheckDoesNotRemoveAlbum() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let appModel = await makeScannedAppModel(root: root, albums: [album])

            let didRemove = await appModel.removeAlbumIfFolderMissing(albumID: album.id)

            #expect(!didRemove)
            #expect(appModel.albumInSelectedLibrary(id: album.id) == album)
            #expect(appModel.scanResultForSelectedLibrary?.albums.map(\.id) == [album.id])
        }
    }

    @Test("移除已删除专辑时会清掉待保存封面")
    func missingAlbumFolderCheckClearsPendingCover() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let sourceURL = root.appendingPathComponent("source.png")
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            try writeValidPNG(to: sourceURL)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let appModel = await makeScannedAppModel(root: root, albums: [album])

            appModel.stageCoverImage(sourceURL, forAlbumID: album.id)
            try FileManager.default.removeItem(at: albumFolder)
            let didRemove = await appModel.removeAlbumIfFolderMissing(albumID: album.id)

            #expect(didRemove)
            #expect(appModel.pendingCoverURL(for: album.id) == nil)
        }
    }

    @Test("专辑目录检查离开主线程")
    func albumFolderCheckRunsOffMainThread() async {
        let wasMainThread = await AppModel.runAlbumFolderCheckOffMainActor {
            Thread.isMainThread
        }

        #expect(wasMainThread == false)
    }

    @Test("保存封面同步准备工作离开主线程")
    func coverWritePreparationRunsOffMainThread() async throws {
        let wasMainThread = try await AppModel.runCoverWritePreparationOffMainActor {
            Thread.isMainThread
        }

        #expect(wasMainThread == false)
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
            #expect(appModel.scanResultForSelectedLibrary?.albums.first?.displayedCover == cover)
            await waitUntil {
                appModel.albumInSelectedLibrary(id: album.id)?.displayedCover?.previewURL != nil
            }
            let refreshedCover = try #require(appModel.albumInSelectedLibrary(id: album.id)?.displayedCover)
            let previewURL = try #require(refreshedCover.previewURL)
            #expect(refreshedCover.displayURL == previewURL)
            #expect(FileManager.default.fileExists(atPath: previewURL.path))
        }
    }

    @Test("保存封面期间重复点击不会并发写入")
    func savingCoverIgnoresDuplicateRequestsWhileWriteIsRunning() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let sourceURL = root.appendingPathComponent("source.png")
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            try writeValidPNG(to: sourceURL)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let writer = DelayedCountingCoverImageWriter(delayNanoseconds: 120_000_000)
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                coverImageWriter: writer
            )

            appModel.stageCoverImage(sourceURL, forAlbumID: album.id)
            async let firstSave = appModel.savePendingCoverImage(forAlbumID: album.id)
            await waitUntil {
                appModel.isSavingCoverImage(for: album.id)
            }

            let secondSave = await appModel.savePendingCoverImage(forAlbumID: album.id)
            let firstResult = await firstSave

            #expect(firstResult)
            #expect(!secondSave)
            #expect(await writer.writeCount() == 1)
            #expect(!appModel.isSavingCoverImage(for: album.id))
            #expect(appModel.pendingCoverURL(for: album.id) == nil)
        }
    }

    @Test("保存旧封面期间新拖入的封面仍保留待保存状态")
    func newerPendingCoverSurvivesOlderSaveCompletion() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            let firstSourceURL = root.appendingPathComponent("first.png")
            let secondSourceURL = root.appendingPathComponent("second.png")
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            try writeValidPNG(to: firstSourceURL)
            try writeValidPNG(to: secondSourceURL)
            let album = makeAlbum(folderURL: albumFolder, albumName: "Album")
            let writer = DelayedCountingCoverImageWriter(delayNanoseconds: 120_000_000)
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                coverImageWriter: writer
            )

            appModel.stageCoverImage(firstSourceURL, forAlbumID: album.id)
            async let firstSave = appModel.savePendingCoverImage(forAlbumID: album.id)
            await waitUntil {
                appModel.isSavingCoverImage(for: album.id)
            }
            appModel.stageCoverImage(secondSourceURL, forAlbumID: album.id)

            #expect(await firstSave)
            #expect(appModel.pendingCoverURL(for: album.id) == secondSourceURL)
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
            appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)
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
            appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)
            await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)

            #expect(appModel.displayArtistName(for: album) == "Artist")
            #expect(appModel.displayAlbumName(for: album) == "原始专辑")
            #expect(appModel.hasEnhancedAlbumName(for: album) == false)
            #expect(appModel.errorMessage == nil)
            #expect(appModel.albumNameEnhancementStatus(for: libraryID)?.lastErrorMessage != nil)
            #expect(appModel.albumNameEnhancementFailedAlbumIDs(for: libraryID) == [album.id])
            #expect(appModel.albumNameEnhancementFailureSummary(for: libraryID) == "Ollama 解析完成，1 张专辑解析失败，已回退原始名称")
        }
    }

    @Test("扫描完成后不自动进行名称增强")
    func scanningDoesNotStartNameEnhancementAutomatically() async throws {
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
            try await Task.sleep(nanoseconds: 60_000_000)
            #expect(await recorder.albumNames().isEmpty)
            #expect(appModel.albumNameEnhancementStatus(for: libraryID)?.isRunning != true)
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
            appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)
            await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)
            await waitUntil { suggester.releaseCount() == 1 }

            #expect(suggester.releaseCount() == 1)
        }
    }

    @Test("名称增强完成后不等待慢快照写入")
    func enhancementCompletionDoesNotWaitForSlowSnapshotWrite() async throws {
        try await withTemporaryDirectory { root in
            let album = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Missing", isDirectory: true),
                albumName: "Missing"
            )
            let snapshotStore = DelayingScanSnapshotStore(replaceDelaySeconds: 0.5)
            let suggester = BlockingReleasingAlbumNameSuggesting()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                albumNameSuggesting: suggester,
                snapshotStore: snapshotStore
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            #expect(appModel.activeScanSnapshot(for: libraryID) != nil)
            appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)
            await waitUntil { await suggester.albumNames() == ["Missing"] }

            let startedAt = Date()
            await suggester.releaseNext()
            await waitUntil { suggester.releaseCount() == 1 }

            #expect(Date().timeIntervalSince(startedAt) < 0.25)
            await waitUntil { snapshotStore.replaceCallCount() > 0 }
            #expect(snapshotStore.replaceCallCount() > 0)
        }
    }

    @Test("在 Finder 中显示专辑通过专用打开服务")
    func openingAlbumInFinderUsesDedicatedOpener() async throws {
        try await withTemporaryDirectory { root in
            let album = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Album", isDirectory: true),
                albumName: "Album"
            )
            let opener = RecordingAlbumFolderOpener()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                albumFolderOpener: opener
            )

            await appModel.openAlbumFolderInFinder(albumID: album.id)

            #expect(await opener.openedURLs == [album.folderURL.standardizedFileURL])
            #expect(appModel.albumFolderOpenMessage(forAlbumID: album.id) == nil)
            #expect(!appModel.isOpeningAlbumFolder(album.id))
        }
    }

    @Test("用 XLD 分轨会通过专用服务打开选中的 CUE")
    func splittingCueSheetUsesDedicatedSplitter() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let cueURL = albumFolder.appendingPathComponent("album.cue")
            try Data("FILE \"album.ape\" WAVE".utf8).write(to: cueURL)
            let album = makeAlbum(
                folderURL: albumFolder,
                albumName: "Album",
                audioRelativePaths: ["album.ape"],
                cueRelativePaths: ["album.cue"],
                issues: [.singleFileNeedsConfirmation(hasCue: true)]
            )
            let splitter = RecordingCueSheetSplitter()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                cueSheetSplitter: splitter
            )
            let cueSheetID = try #require(album.cueSheets.first?.id)

            await appModel.splitCueSheetWithXLD(albumID: album.id, cueSheetID: cueSheetID)

            #expect(await splitter.openedURLs == [cueURL.standardizedFileURL])
            #expect(appModel.cueSheetSplitMessage(forAlbumID: album.id)?.contains("已在 XLD 中打开") == true)
            #expect(!appModel.isSplittingCueSheet(album.id))
        }
    }

    @Test("CUE 文件消失时不启动 XLD 并显示错误")
    func splittingMissingCueSheetShowsError() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let album = makeAlbum(
                folderURL: albumFolder,
                albumName: "Album",
                audioRelativePaths: ["album.ape"],
                cueRelativePaths: ["album.cue"],
                issues: [.singleFileNeedsConfirmation(hasCue: true)]
            )
            let splitter = RecordingCueSheetSplitter()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                cueSheetSplitter: splitter
            )
            let cueSheetID = try #require(album.cueSheets.first?.id)

            await appModel.splitCueSheetWithXLD(albumID: album.id, cueSheetID: cueSheetID)

            #expect(await splitter.openedURLs.isEmpty)
            #expect(appModel.cueSheetSplitMessage(forAlbumID: album.id)?.contains("未找到 CUE 文件") == true)
        }
    }

    @Test("重复点击分轨时只启动一次 XLD")
    func splittingCueSheetIgnoresDuplicateRequestWhileRunning() async throws {
        try await withTemporaryDirectory { root in
            let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
            try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            let cueURL = albumFolder.appendingPathComponent("album.cue")
            try Data("FILE \"album.ape\" WAVE".utf8).write(to: cueURL)
            let album = makeAlbum(
                folderURL: albumFolder,
                albumName: "Album",
                audioRelativePaths: ["album.ape"],
                cueRelativePaths: ["album.cue"],
                issues: [.singleFileNeedsConfirmation(hasCue: true)]
            )
            let splitter = BlockingCueSheetSplitter()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                cueSheetSplitter: splitter
            )
            let cueSheetID = try #require(album.cueSheets.first?.id)

            let firstRequest = Task {
                await appModel.splitCueSheetWithXLD(albumID: album.id, cueSheetID: cueSheetID)
            }
            await waitUntil { appModel.isSplittingCueSheet(album.id) }
            await appModel.splitCueSheetWithXLD(albumID: album.id, cueSheetID: cueSheetID)
            await splitter.release()
            await firstRequest.value

            #expect(await splitter.openedURLs == [cueURL.standardizedFileURL])
        }
    }

    @Test("详情页手动识别允许处理已有封面的专辑")
    func manualEnhancementHandlesCoveredAlbum() async throws {
        try await withTemporaryDirectory { root in
            let album = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Covered", isDirectory: true),
                albumName: "Covered",
                hasCover: true
            )
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                albumNameSuggesting: StubAlbumNameSuggesting(
                    outcome: .success(AlbumNameSuggestion(
                        artistName: "LLM Artist",
                        albumName: "LLM Covered"
                    ))
                )
            )

            appModel.requestAlbumNameEnhancement(forAlbumID: album.id)
            await waitUntil {
                appModel.displayAlbumName(for: album) == "LLM Covered"
            }

            #expect(appModel.displayArtistName(for: album) == "LLM Artist")
            #expect(appModel.searchKeyword(for: album) == "LLM Artist LLM Covered")
            #expect(appModel.hasEnhancedAlbumName(for: album))
            #expect(appModel.albumNameEnhancementState(forAlbumID: album.id)?.isRunning == false)
        }
    }

    @Test("单专辑手动识别会在当前音乐库请求后优先于剩余批处理执行")
    func manualEnhancementIsInsertedAfterCurrentRunningAlbum() async throws {
        try await withTemporaryDirectory { root in
            let autoFirst = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Auto First", isDirectory: true),
                albumName: "Auto First"
            )
            let autoSecond = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Auto Second", isDirectory: true),
                albumName: "Auto Second"
            )
            let manualCovered = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Manual Covered", isDirectory: true),
                albumName: "Manual Covered",
                hasCover: true
            )
            let suggester = BlockingRecordingAlbumNameSuggesting()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [autoFirst, autoSecond, manualCovered],
                albumNameSuggesting: suggester
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)
            await waitUntil { await suggester.albumNames() == ["Auto First"] }
            appModel.requestAlbumNameEnhancement(forAlbumID: manualCovered.id)

            #expect(appModel.albumNameEnhancementState(forAlbumID: manualCovered.id)?.isQueued == true)
            await suggester.releaseNext()
            await waitUntil {
                await suggester.albumNames() == ["Auto First", "Manual Covered"]
            }

            #expect(await suggester.albumNames() == ["Auto First", "Manual Covered"])
            await suggester.releaseNext()
            await waitUntil {
                await suggester.albumNames() == ["Auto First", "Manual Covered", "Auto Second"]
            }
            await suggester.releaseNext()
        }
    }

    @Test("同一专辑重复点击手动识别只入队一次")
    func duplicateManualEnhancementRequestIsDeduplicated() async throws {
        try await withTemporaryDirectory { root in
            let album = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Covered", isDirectory: true),
                albumName: "Covered",
                hasCover: true
            )
            let suggester = BlockingRecordingAlbumNameSuggesting()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                albumNameSuggesting: suggester
            )

            appModel.requestAlbumNameEnhancement(forAlbumID: album.id)
            appModel.requestAlbumNameEnhancement(forAlbumID: album.id)
            await waitUntil { await suggester.albumNames() == ["Covered"] }
            await suggester.releaseNext()
            await waitUntil {
                appModel.albumNameEnhancementState(forAlbumID: album.id)?.isRunning == false
            }

            #expect(await suggester.albumNames() == ["Covered"])
        }
    }

    @Test("手动识别失败时保留原始名称并记录单专辑错误")
    func manualEnhancementFailureKeepsOriginalNameAndReportsAlbumError() async throws {
        try await withTemporaryDirectory { root in
            let album = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Covered", isDirectory: true),
                albumName: "Covered",
                hasCover: true
            )
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [album],
                albumNameSuggesting: StubAlbumNameSuggesting(
                    outcome: .failure("Ollama 请求失败")
                )
            )

            appModel.requestAlbumNameEnhancement(forAlbumID: album.id)
            await waitUntil {
                appModel.albumNameEnhancementState(forAlbumID: album.id)?.lastErrorMessage != nil
            }

            let state = try #require(appModel.albumNameEnhancementState(forAlbumID: album.id))
            let libraryID = try #require(appModel.selectedLibraryID)
            #expect(appModel.displayAlbumName(for: album) == "Covered")
            #expect(appModel.hasEnhancedAlbumName(for: album) == false)
            #expect(state.isQueued == false)
            #expect(state.isRunning == false)
            #expect(state.lastErrorMessage?.contains("Ollama 请求失败") == true)
            #expect(appModel.errorMessage == nil)
            #expect(appModel.albumNameEnhancementFailedAlbumIDs(for: libraryID) == [album.id])
            #expect(appModel.albumNameEnhancementFailureSummary(for: libraryID) == "Ollama 解析完成，1 张专辑解析失败，已回退原始名称")
        }
    }

    @Test("音乐库智能解析只处理缺封面的专辑")
    func libraryEnhancementOnlyHandlesMissingCoverAlbums() async throws {
        try await withTemporaryDirectory { root in
            let covered = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Covered", isDirectory: true),
                albumName: "Covered",
                hasCover: true
            )
            let missing = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Missing", isDirectory: true),
                albumName: "Missing"
            )
            let recorder = AlbumNameSuggestionRecorder()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [covered, missing],
                albumNameSuggesting: RecordingAlbumNameSuggesting(recorder: recorder)
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)
            await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)

            #expect(await recorder.albumNames() == ["Missing"])
            let progress = try #require(appModel.albumNameEnhancementProgress(for: libraryID))
            #expect(progress.completedAlbums == 1)
            #expect(progress.totalAlbums == 1)
            #expect(progress.isFinished)
        }
    }

    @Test("音乐库智能解析没有缺封面专辑时保持零进度")
    func libraryEnhancementWithoutMissingCoverAlbumsKeepsZeroProgress() async throws {
        try await withTemporaryDirectory { root in
            let covered = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Covered", isDirectory: true),
                albumName: "Covered",
                hasCover: true
            )
            let recorder = AlbumNameSuggestionRecorder()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [covered],
                albumNameSuggesting: RecordingAlbumNameSuggesting(recorder: recorder)
            )

            let libraryID = try #require(appModel.selectedLibraryID)
            appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)

            #expect(await recorder.albumNames().isEmpty)
            let progress = try #require(appModel.albumNameEnhancementProgress(for: libraryID))
            #expect(progress.completedAlbums == 0)
            #expect(progress.totalAlbums == 0)
            #expect(appModel.albumNameEnhancementStatus(for: libraryID)?.isRunning == false)
        }
    }

    @Test("音乐库智能解析运行时提供进度")
    func libraryEnhancementReportsProgress() async throws {
        try await withTemporaryDirectory { root in
            let covered = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Covered", isDirectory: true),
                albumName: "Covered",
                hasCover: true
            )
            let first = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/First", isDirectory: true),
                albumName: "First"
            )
            let second = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Second", isDirectory: true),
                albumName: "Second"
            )
            let suggester = BlockingRecordingAlbumNameSuggesting()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [covered, first, second],
                albumNameSuggesting: suggester
            )
            let libraryID = try #require(appModel.selectedLibraryID)

            appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)
            await waitUntil { await suggester.albumNames() == ["First"] }

            let runningProgress = try #require(appModel.albumNameEnhancementProgress(for: libraryID))
            #expect(runningProgress.completedAlbums == 0)
            #expect(runningProgress.totalAlbums == 2)
            #expect(runningProgress.currentAlbumName == "First")
            #expect(runningProgress.fraction == 0)
            #expect(runningProgress.actionDescription == "正在智能解析 First")

            await suggester.releaseNext()
            await waitUntil { await suggester.albumNames() == ["First", "Second"] }

            let halfwayProgress = try #require(appModel.albumNameEnhancementProgress(for: libraryID))
            #expect(halfwayProgress.completedAlbums == 1)
            #expect(halfwayProgress.totalAlbums == 2)
            #expect(halfwayProgress.currentAlbumName == "Second")
            #expect(halfwayProgress.fraction == 0.5)

            await suggester.releaseNext()
            await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)

            let finishedProgress = try #require(appModel.albumNameEnhancementProgress(for: libraryID))
            #expect(finishedProgress.completedAlbums == 2)
            #expect(finishedProgress.totalAlbums == 2)
            #expect(finishedProgress.isFinished)
            #expect(finishedProgress.actionDescription == "智能解析完成")
        }
    }

    @Test("停止音乐库智能解析会取消当前请求并清空后续队列")
    func stoppingLibraryEnhancementCancelsOnlyCurrentBatch() async throws {
        try await withTemporaryDirectory { root in
            let first = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/First", isDirectory: true),
                albumName: "First"
            )
            let second = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Second", isDirectory: true),
                albumName: "Second"
            )
            let suggester = CancellationAwareBlockingAlbumNameSuggesting()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [first, second],
                albumNameSuggesting: suggester
            )
            let libraryID = try #require(appModel.selectedLibraryID)

            appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)
            await waitUntil { suggester.albumNames() == ["First"] }
            appModel.stopAlbumNameEnhancement(forLibraryID: libraryID)
            await waitUntil { suggester.cancelledRequestCount() == 1 }
            try await Task.sleep(nanoseconds: 60_000_000)

            #expect(suggester.albumNames() == ["First"])
            #expect(appModel.hasEnhancedAlbumName(for: first, in: libraryID) == false)
            #expect(appModel.hasEnhancedAlbumName(for: second, in: libraryID) == false)
            #expect(appModel.albumNameEnhancementStatus(for: libraryID)?.isRunning == false)
            let progress = try #require(appModel.albumNameEnhancementProgress(for: libraryID))
            #expect(progress.completedAlbums == 0)
            #expect(progress.totalAlbums == 2)
        }
    }

    @Test("停止后重新智能解析会重新处理被取消的当前专辑")
    func restartingLibraryEnhancementRequeuesCancelledCurrentAlbum() async throws {
        try await withTemporaryDirectory { root in
            let first = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/First", isDirectory: true),
                albumName: "First"
            )
            let second = makeAlbum(
                folderURL: root.appendingPathComponent("Artist/Second", isDirectory: true),
                albumName: "Second"
            )
            let suggester = BlockingRecordingAlbumNameSuggesting()
            let appModel = await makeScannedAppModel(
                root: root,
                albums: [first, second],
                albumNameSuggesting: suggester
            )
            let libraryID = try #require(appModel.selectedLibraryID)

            appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)
            await waitUntil { suggester.albumNames() == ["First"] }
            appModel.stopAlbumNameEnhancement(forLibraryID: libraryID)
            appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)

            suggester.releaseNext()
            await waitUntil { suggester.albumNames() == ["First", "First"] }
            suggester.releaseNext()
            await waitUntil { suggester.albumNames() == ["First", "First", "Second"] }
            suggester.releaseNext()
            await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)

            #expect(appModel.hasEnhancedAlbumName(for: first, in: libraryID))
            #expect(appModel.hasEnhancedAlbumName(for: second, in: libraryID))
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
            await waitUntil { await snapshotStore.replaceCount() == 1 }

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

    @Test("实时局部刷新后专辑变成缺封面不会自动解析")
    func realtimeRefreshDoesNotEnhanceAlbumThatBecomesMissingCoverAutomatically() async throws {
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
            try await Task.sleep(nanoseconds: 60_000_000)

            #expect(appModel.scanResultsByLibraryID[libraryID]?.albums.first?.displayedCover == nil)
            #expect(await recorder.albumNames().isEmpty)
            #expect(appModel.albumNameEnhancementStatus(for: libraryID)?.isRunning != true)
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

    @Test("实时局部刷新不会自动重新增强名称")
    func realtimeRefreshDoesNotEnhanceChangedAlbumsAutomatically() async throws {
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
            #expect(appModel.hasEnhancedAlbumName(for: unchangedAlbum, in: libraryID) == false)
            await waitUntil { monitor.hasSubscriber(for: root) }

            monitor.emit(rootURL: root, changedPaths: ["Artist/Changed/02.wav"])
            await waitUntil { await scanner.rescanCount() == 1 }
            try await Task.sleep(nanoseconds: 60_000_000)

            #expect(await scanner.scanCount() == 1)
            #expect(appModel.hasEnhancedAlbumName(for: unchangedAlbum, in: libraryID) == false)
            #expect(appModel.hasEnhancedAlbumName(for: changedAlbumAfterRefresh, in: libraryID) == false)
            #expect(await recorder.albumNames().isEmpty)
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

private actor CountingCoverImageWriter: CoverImageWriting {
    private var count = 0

    func writeCoverImage(
        from sourceURL: URL,
        toAlbumFolder albumFolderURL: URL
    ) async throws -> URL {
        count += 1
        return albumFolderURL.appendingPathComponent("cover.jpg")
    }

    func writeCount() -> Int {
        count
    }
}

private actor DelayedCountingCoverImageWriter: CoverImageWriting {
    private let delayNanoseconds: UInt64
    private var count = 0

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func writeCoverImage(
        from sourceURL: URL,
        toAlbumFolder albumFolderURL: URL
    ) async throws -> URL {
        count += 1
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return albumFolderURL.appendingPathComponent("cover.jpg")
    }

    func writeCount() -> Int {
        count
    }
}

private actor ControlledCoverImageStager: CoverImageStaging {
    private var requestCountValue = 0
    private var continuations: [Int: CheckedContinuation<URL, any Error>] = [:]

    func stageImageData(
        _ data: Data,
        suggestedExtension: String?
    ) async throws -> URL {
        let requestIndex = requestCountValue
        requestCountValue += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[requestIndex] = continuation
        }
    }

    func stageRemoteImage(at remoteURL: URL) async throws -> URL {
        try await stageImageData(Data(), suggestedExtension: remoteURL.pathExtension)
    }

    func prefetchRemoteImage(at remoteURL: URL) async {}

    func waitUntilRequestCount(_ expectedCount: Int) async {
        while requestCountValue < expectedCount {
            await Task.yield()
        }
    }

    func succeedRequest(at index: Int, with url: URL) {
        continuations.removeValue(forKey: index)?.resume(returning: url)
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

private final class BlockingRecordingAlbumNameSuggesting: AlbumNameSuggesting, @unchecked Sendable {
    private let lock = NSLock()
    private var processedAlbumNames: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func suggestAlbumName(for input: AlbumNameEnhancementInput) async throws -> AlbumNameSuggestion {
        let originalArtistName = input.originalArtistName
        let originalAlbumName = input.originalAlbumName
        lock.withLock {
            processedAlbumNames.append(originalAlbumName)
        }
        await withCheckedContinuation { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
        }
        return AlbumNameSuggestion(
            artistName: originalArtistName,
            albumName: "\(originalAlbumName) Enhanced"
        )
    }

    func albumNames() -> [String] {
        lock.withLock {
            processedAlbumNames
        }
    }

    func releaseNext() {
        let continuation = lock.withLock {
            continuations.isEmpty ? nil : continuations.removeFirst()
        }
        continuation?.resume()
    }

    func reset() {
        lock.withLock {
            processedAlbumNames = []
            continuations = []
        }
    }
}

private final class CancellationAwareBlockingAlbumNameSuggesting: AlbumNameSuggesting, @unchecked Sendable {
    private let lock = NSLock()
    private var processedAlbumNames: [String] = []
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private var cancellationCount = 0
    private var isCancelled = false

    func suggestAlbumName(for input: AlbumNameEnhancementInput) async throws -> AlbumNameSuggestion {
        let originalArtistName = input.originalArtistName
        let originalAlbumName = input.originalAlbumName
        lock.withLock {
            processedAlbumNames.append(originalAlbumName)
        }

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let shouldCancel = lock.withLock { () -> Bool in
                    if isCancelled {
                        return true
                    }
                    continuations.append(continuation)
                    return false
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }, onCancel: { [weak self] in
            self?.cancelPendingRequests()
        })

        return AlbumNameSuggestion(
            artistName: originalArtistName,
            albumName: "\(originalAlbumName) Enhanced"
        )
    }

    func albumNames() -> [String] {
        lock.withLock {
            processedAlbumNames
        }
    }

    func cancelledRequestCount() -> Int {
        lock.withLock {
            cancellationCount
        }
    }

    private func cancelPendingRequests() {
        let pendingContinuations = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            isCancelled = true
            cancellationCount += 1
            let pending = continuations
            continuations = []
            return pending
        }
        for continuation in pendingContinuations {
            continuation.resume(throwing: CancellationError())
        }
    }
}

private final class BlockingReleasingAlbumNameSuggesting: AlbumNameSuggestingResourceReleasing, @unchecked Sendable {
    private let lock = NSLock()
    private var processedAlbumNames: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var releases = 0

    func suggestAlbumName(for input: AlbumNameEnhancementInput) async throws -> AlbumNameSuggestion {
        let originalArtistName = input.originalArtistName
        let originalAlbumName = input.originalAlbumName
        lock.withLock {
            processedAlbumNames.append(originalAlbumName)
        }
        await withCheckedContinuation { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
        }
        return AlbumNameSuggestion(
            artistName: originalArtistName,
            albumName: "\(originalAlbumName) Enhanced"
        )
    }

    func releaseResources() async {
        lock.withLock {
            releases += 1
        }
    }

    func albumNames() -> [String] {
        lock.withLock {
            processedAlbumNames
        }
    }

    func releaseNext() {
        let continuation = lock.withLock {
            continuations.isEmpty ? nil : continuations.removeFirst()
        }
        continuation?.resume()
    }

    func releaseCount() -> Int {
        lock.withLock {
            releases
        }
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

private final class DelayingScanSnapshotStore: ScanSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let replaceDelaySeconds: TimeInterval
    private var replaceCount = 0

    init(replaceDelaySeconds: TimeInterval = 0) {
        self.replaceDelaySeconds = replaceDelaySeconds
    }

    func saveNewSnapshot(_ snapshot: ScanSnapshot) async throws -> ScanSnapshotSummary {
        makeSummary(for: snapshot)
    }

    func replaceSnapshot(_ snapshot: ScanSnapshot, at fileURL: URL) async throws -> ScanSnapshotSummary {
        if replaceDelaySeconds > 0 {
            let deadline = Date().addingTimeInterval(replaceDelaySeconds)
            while Date() < deadline {
                _ = 1 + 1
            }
        }
        lock.withLock {
            replaceCount += 1
        }
        return makeSummary(for: snapshot, fileURL: fileURL)
    }

    func latestSnapshot(for library: LibraryRecord) async throws -> ScanSnapshotSummary? {
        nil
    }

    func loadSnapshot(at fileURL: URL, expectedLibrary: LibraryRecord) async throws -> ScanSnapshot {
        throw DelayingScanSnapshotStoreError()
    }

    func replaceCallCount() -> Int {
        lock.withLock {
            replaceCount
        }
    }

    private func makeSummary(
        for snapshot: ScanSnapshot,
        fileURL: URL = URL(fileURLWithPath: "/tmp/coverdrop-test-snapshot.db")
    ) -> ScanSnapshotSummary {
        ScanSnapshotSummary(
            fileURL: fileURL,
            schemaVersion: ScanSnapshot.currentSchemaVersion,
            createdAt: .now,
            libraryDisplayName: "测试音乐库",
            libraryRootPath: "/tmp/coverdrop-test-library",
            libraryRole: .library,
            albumCount: 0
        )
    }
}

private struct DelayingScanSnapshotStoreError: LocalizedError, Sendable {
    var errorDescription: String? {
        "测试快照存储不支持读取。"
    }
}

private actor RecordingAlbumFolderOpener: AlbumFolderOpening {
    private(set) var openedURLs: [URL] = []

    nonisolated func openAlbumFolder(_ folderURL: URL) async throws {
        await record(folderURL)
    }

    private func record(_ folderURL: URL) {
        openedURLs.append(folderURL)
    }
}

private actor RecordingCueSheetSplitter: CueSheetSplitting {
    private(set) var openedURLs: [URL] = []

    nonisolated func splitCueSheet(_ cueSheetURL: URL) async throws {
        await record(cueSheetURL)
    }

    private func record(_ cueSheetURL: URL) {
        openedURLs.append(cueSheetURL.standardizedFileURL)
    }
}

private actor BlockingCueSheetSplitter: CueSheetSplitting {
    private(set) var openedURLs: [URL] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    nonisolated func splitCueSheet(_ cueSheetURL: URL) async throws {
        await recordAndWait(cueSheetURL)
    }

    private func recordAndWait(_ cueSheetURL: URL) async {
        openedURLs.append(cueSheetURL.standardizedFileURL)
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

private actor RecordingScanSnapshotStore: ScanSnapshotStoring, AlbumCoverSnapshotUpdating {
    private let root: URL
    private var savedSnapshots: [ScanSnapshot] = []
    private var replacedSnapshots: [ScanSnapshot] = []
    private var coverUpdates: [(albumID: AlbumScanRecord.ID, cover: ScanSnapshot.Cover?)] = []

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

    func updateAlbumCover(
        _ cover: ScanSnapshot.Cover?,
        forAlbumID albumID: AlbumScanRecord.ID,
        at fileURL: URL,
        expectedLibrary: LibraryRecord
    ) async throws -> ScanSnapshotSummary {
        coverUpdates.append((albumID: albumID, cover: cover))
        let latestSnapshot = savedSnapshots.last
        return await MainActor.run {
            ScanSnapshotSummary(
                fileURL: fileURL,
                schemaVersion: ScanSnapshot.currentSchemaVersion,
                createdAt: .now,
                libraryDisplayName: expectedLibrary.displayName,
                libraryRootPath: expectedLibrary.rootPath,
                libraryRole: expectedLibrary.role,
                albumCount: latestSnapshot?.scanResult.albums.count ?? 0
            )
        }
    }

    func saveCount() -> Int {
        savedSnapshots.count
    }

    func replaceCount() -> Int {
        replacedSnapshots.count
    }

    func coverUpdateCount() -> Int {
        coverUpdates.count
    }

    func lastUpdatedAlbumID() -> AlbumScanRecord.ID? {
        coverUpdates.last?.albumID
    }

    func lastUpdatedCover() -> ScanSnapshot.Cover? {
        coverUpdates.last?.cover
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

private final class ObjectWillChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

private func measured(_ block: () -> Void) -> TimeInterval {
    let startedAt = Date()
    block()
    return Date().timeIntervalSince(startedAt)
}

private func performanceAlbum(index: Int, hasCover: Bool) -> AlbumScanRecord {
    let folderURL = URL(fileURLWithPath: "/tmp/歌手 \(index % 500)/专辑 \(index)", isDirectory: true)
    return AlbumScanRecord(
        folderURL: folderURL,
        artistName: "歌手 \(index % 500)",
        albumName: "专辑 \(index)",
        audioFiles: [],
        displayedCover: hasCover ? CoverCandidate(
            url: folderURL.appendingPathComponent("cover.jpg"),
            relativePath: "cover.jpg",
            namePriority: 0,
            depth: 0
        ) : nil,
        issues: []
    )
}

@MainActor
private func makeScannedAppModel(
    root: URL,
    albums: [AlbumScanRecord],
    coverImageWriter: any CoverImageWriting = ImageIOCoverImageWriter(),
    coverImageStager: any CoverImageStaging = LiveCoverImageStager(),
    albumNameSuggesting: any AlbumNameSuggesting = DisabledAlbumNameSuggesting(),
    snapshotStore: any ScanSnapshotStoring = DisabledScanSnapshotStore(),
    albumFolderOpener: any AlbumFolderOpening = DisabledAlbumFolderOpener(),
    cueSheetSplitter: any CueSheetSplitting = DisabledCueSheetSplitter()
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
        coverImageWriter: coverImageWriter,
        coverImageStager: coverImageStager,
        albumNameSuggesting: albumNameSuggesting,
        scanSnapshotStore: snapshotStore,
        albumFolderOpener: albumFolderOpener,
        cueSheetSplitter: cueSheetSplitter
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
    audioRelativePaths: [String] = [],
    cueRelativePaths: [String] = [],
    issues: [AlbumScanIssue] = []
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
        cueSheets: cueRelativePaths.map { relativePath in
            CueSheetRecord(
                url: folderURL.appendingPathComponent(relativePath),
                relativePath: relativePath
            )
        },
        displayedCover: hasCover ? CoverCandidate(
            url: folderURL.appendingPathComponent("cover.jpg"),
            relativePath: "cover.jpg",
            namePriority: 0,
            depth: 0,
            source: .file
        ) : nil,
        issues: issues
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
