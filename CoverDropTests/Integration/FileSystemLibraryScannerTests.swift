import Foundation
import Testing
@testable import CoverDrop

struct FileSystemLibraryScannerTests {
    @Test("音乐库按歌手和专辑两层边界扫描，并报告散落音频")
    func scansLibraryBoundariesAndLooseAudio() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("周杰伦/七里香/01.flac", under: root)
            try makeAudio("周杰伦/七里香/02.wav", under: root)
            try makeAudio("周杰伦/叶惠美/整轨.ape", under: root)
            try makeAudio("只有散曲/单曲.mp3", under: root)
            try makeAudio("根目录散曲.dsf", under: root)

            let result = try await makeScanner().scan(libraryURL: root, role: .library)

            #expect(result.albums.map(\.albumName) == ["七里香", "叶惠美"])
            #expect(result.albums.first?.audioFiles.count == 2)
            #expect(result.looseAudioPaths == ["只有散曲/单曲.mp3", "根目录散曲.dsf"])
            #expect(result.albums.last?.issues == [.singleFileNeedsConfirmation(hasCue: false)])
        }
    }

    @Test("单张专辑合并多碟子目录并按标签轨号排序")
    func mergesDiscFoldersAndSortsByMetadata() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("CD1/02.flac", under: root)
            try makeAudio("CD1/01.flac", under: root)
            try makeAudio("CD2/01.flac", under: root)

            let result = try await makeScanner().scan(libraryURL: root, role: .album)

            #expect(result.albums.count == 1)
            #expect(result.albums[0].audioFiles.map(\.relativePath) == [
                "CD1/01.flac", "CD1/02.flac", "CD2/01.flac"
            ])
        }
    }

    @Test("纯数字碟目录会归并到父专辑目录")
    func mergesPlainNumberedDiscFoldersIntoAlbumBoundary() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio(
                "韩宝仪/1996-旧情绵绵 经典金系列2CD[荣机构经典金系列][WAV]/01/01.wav",
                under: root
            )
            try makeAudio(
                "韩宝仪/1996-旧情绵绵 经典金系列2CD[荣机构经典金系列][WAV]/02/01.wav",
                under: root
            )
            let expectedFolder = root.appendingPathComponent(
                "韩宝仪/1996-旧情绵绵 经典金系列2CD[荣机构经典金系列][WAV]",
                isDirectory: true
            )

            let result = try await makeScanner().scan(
                libraryURL: root.appendingPathComponent("韩宝仪", isDirectory: true),
                role: .artist
            )
            let album = try #require(result.albums.first)

            #expect(result.albums.count == 1)
            #expect(album.artistName == "韩宝仪")
            #expect(album.albumName == "1996-旧情绵绵 经典金系列2CD[荣机构经典金系列][WAV]")
            #expect(isSameFileURL(album.folderURL, expectedFolder))
            #expect(album.audioFiles.map(\.relativePath) == ["01/01.wav", "02/01.wav"])
        }
    }

    @Test("泛称专辑目录中的编号壳目录会下钻到真实专辑")
    func skipsGenericAlbumFolderAndNumberedShell() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("歌手/album/011/真正专辑名/01.wav", under: root)
            let expectedFolder = root.appendingPathComponent(
                "歌手/album/011/真正专辑名",
                isDirectory: true
            )

            let result = try await makeScanner().scan(
                libraryURL: root.appendingPathComponent("歌手/album", isDirectory: true),
                role: .artist
            )
            let album = try #require(result.albums.first)

            #expect(result.albums.count == 1)
            #expect(album.artistName == "歌手")
            #expect(album.albumName == "真正专辑名")
            #expect(isSameFileURL(album.folderURL, expectedFolder))
        }
    }

    @Test("歌手目录中的纯数字壳目录会下钻到真实专辑")
    func skipsNumberedShellUnderArtistRoot() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("歌手/001/真正专辑名/01.wav", under: root)
            let expectedFolder = root.appendingPathComponent(
                "歌手/001/真正专辑名",
                isDirectory: true
            )

            let result = try await makeScanner().scan(
                libraryURL: root.appendingPathComponent("歌手", isDirectory: true),
                role: .artist
            )
            let album = try #require(result.albums.first)

            #expect(result.albums.count == 1)
            #expect(album.artistName == "歌手")
            #expect(album.albumName == "真正专辑名")
            #expect(isSameFileURL(album.folderURL, expectedFolder))
        }
    }

    @Test("普通歌手专辑结构保持原有边界")
    func keepsRegularArtistAlbumBoundary() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("歌手/真正专辑名/01.wav", under: root)
            let expectedFolder = root.appendingPathComponent("歌手/真正专辑名", isDirectory: true)

            let result = try await makeScanner().scan(
                libraryURL: root.appendingPathComponent("歌手", isDirectory: true),
                role: .artist
            )
            let album = try #require(result.albums.first)

            #expect(result.albums.count == 1)
            #expect(album.artistName == "歌手")
            #expect(album.albumName == "真正专辑名")
            #expect(isSameFileURL(album.folderURL, expectedFolder))
        }
    }

    @Test("多碟目录不会被当成编号壳目录拆开")
    func keepsDiscFolderInsideAlbumBoundary() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("歌手/真正专辑名/CD1/01.wav", under: root)
            let expectedFolder = root.appendingPathComponent("歌手/真正专辑名", isDirectory: true)

            let result = try await makeScanner().scan(
                libraryURL: root.appendingPathComponent("歌手", isDirectory: true),
                role: .artist
            )
            let album = try #require(result.albums.first)

            #expect(result.albums.count == 1)
            #expect(album.artistName == "歌手")
            #expect(album.albumName == "真正专辑名")
            #expect(isSameFileURL(album.folderURL, expectedFolder))
            #expect(album.audioFiles.map(\.relativePath) == ["CD1/01.wav"])
        }
    }

    @Test("歌手专辑多碟结构会合并为同一张专辑")
    func mergesDiscFoldersUnderArtistAlbumBoundary() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("歌手/真正专辑名/CD1/01.wav", under: root)
            try makeAudio("歌手/真正专辑名/CD2/01.wav", under: root)

            let result = try await makeScanner().scan(
                libraryURL: root.appendingPathComponent("歌手", isDirectory: true),
                role: .artist
            )
            let album = try #require(result.albums.first)

            #expect(result.albums.count == 1)
            #expect(album.albumName == "真正专辑名")
            #expect(album.audioFiles.map(\.relativePath) == ["CD1/01.wav", "CD2/01.wav"])
        }
    }

    @Test("格式目录会向上归并到真实专辑目录")
    func mergesFormatFolderIntoAlbumBoundary() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("歌手/真正专辑名/WAV/01.wav", under: root)
            let expectedFolder = root.appendingPathComponent("歌手/真正专辑名", isDirectory: true)

            let result = try await makeScanner().scan(
                libraryURL: root.appendingPathComponent("歌手", isDirectory: true),
                role: .artist
            )
            let album = try #require(result.albums.first)

            #expect(result.albums.count == 1)
            #expect(album.albumName == "真正专辑名")
            #expect(isSameFileURL(album.folderURL, expectedFolder))
            #expect(album.audioFiles.map(\.relativePath) == ["WAV/01.wav"])
        }
    }

    @Test("专辑汇总目录不会被当成一张大专辑")
    func splitsCollectionContainerIntoNestedAlbums() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("歌手/专辑汇总/专辑A/01.wav", under: root)
            try makeAudio("歌手/专辑汇总/专辑B/01.wav", under: root)

            let result = try await makeScanner().scan(
                libraryURL: root.appendingPathComponent("歌手", isDirectory: true),
                role: .artist
            )

            #expect(result.albums.map(\.albumName) == ["专辑A", "专辑B"])
        }
    }

    @Test("每首歌一个文件夹时归并到共同专辑目录")
    func mergesTrackFoldersIntoAlbumBoundary() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("歌手/真正专辑名/01 第一首/track.flac", under: root)
            try makeAudio("歌手/真正专辑名/02 第二首/track.flac", under: root)

            let result = try await makeScanner().scan(
                libraryURL: root.appendingPathComponent("歌手", isDirectory: true),
                role: .artist
            )
            let album = try #require(result.albums.first)

            #expect(result.albums.count == 1)
            #expect(album.albumName == "真正专辑名")
            #expect(album.audioFiles.map(\.relativePath) == [
                "01 第一首/track.flac",
                "02 第二首/track.flac"
            ])
            #expect(album.needsAttention)
            #expect(album.issues.contains {
                if case .trackNamedAudioFiles = $0 { return true }
                return false
            })
        }
    }

    @Test("版本目录不会静默合并，会标记需要确认")
    func marksVersionDirectoriesAsUncertain() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("歌手/真正专辑名/港版/01.wav", under: root)
            try makeAudio("歌手/真正专辑名/日本版/01.wav", under: root)

            let result = try await makeScanner().scan(
                libraryURL: root.appendingPathComponent("歌手", isDirectory: true),
                role: .artist
            )

            #expect(result.albums.count == 2)
            #expect(result.albums.allSatisfy { $0.needsAttention })
            #expect(AlbumScanResultFiltering.albums(
                in: result,
                filter: .needsAttention,
                query: ""
            ).count == 2)
            #expect(result.albums.flatMap(\.issues).contains {
                if case .uncertainAlbumBoundary = $0 { return true }
                return false
            })
        }
    }

    @Test("嵌套套装容器下的英文专辑名能作为真实专辑边界")
    func findsNestedAlbumInsideCollectionContainer() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio(
                "张国荣/张国荣 10张[DSD]/Leslie Cheung - Dou Feng Xin Qing/01.dff",
                under: root
            )

            let result = try await makeScanner().scan(
                libraryURL: root.appendingPathComponent("张国荣", isDirectory: true),
                role: .artist
            )
            let album = try #require(result.albums.first)

            #expect(result.albums.count == 1)
            #expect(album.artistName == "张国荣")
            #expect(album.albumName == "Leslie Cheung - Dou Feng Xin Qing")
        }
    }

    @Test("直接扫描带数量后缀的歌手目录不会把父级分类当作歌手")
    func artistRootWithAlbumCountSuffixKeepsArtistName() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio(
                "华语/孙燕姿 15张/[Qobuz] 孙燕姿 - No.13 作品 - 跳舞的梵谷 2017[24-96]/01.flac",
                under: root
            )

            let result = try await makeScanner().scan(
                libraryURL: root.appendingPathComponent("华语/孙燕姿 15张", isDirectory: true),
                role: .artist
            )
            let album = try #require(result.albums.first)

            #expect(result.albums.count == 1)
            #expect(album.artistName == "孙燕姿")
            #expect(album.artistName != "华语")
            #expect(album.albumName == "[Qobuz] 孙燕姿 - No.13 作品 - 跳舞的梵谷 2017[24-96]")
        }
    }

    @Test("标签读取失败不会中断专辑扫描")
    func metadataFailureBecomesAlbumIssue() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("01.flac", under: root)
            try makeAudio("坏文件.wav", under: root)

            let scanner = FileSystemLibraryScanner(
                metadataReader: StubMetadataReader(failingNames: ["坏文件.wav"]),
                coverDetector: EmptyCoverDetector(),
                maxConcurrentAlbums: AppConfiguration.live.scan.maxConcurrentAlbums
            )
            let result = try await scanner.scan(libraryURL: root, role: .album)

            #expect(result.albums[0].audioFiles.count == 2)
            #expect(result.albums[0].audioFiles.first { $0.relativePath == "坏文件.wav" }?.readError != nil)
            #expect(result.albums[0].issues == [.metadataReadFailed(paths: ["坏文件.wav"])])
        }
    }

    @Test("没有独立图片时使用音频内嵌图作为封面墙封面")
    func embeddedArtworkBecomesDisplayCoverWhenNoImageFileExists() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("01.flac", under: root)
            let embeddedArtworkURL = root.appendingPathComponent("Cache/embedded.jpg")
            let scanner = FileSystemLibraryScanner(
                metadataReader: StubMetadataReader(embeddedArtworkNames: [
                    "01.flac": embeddedArtworkURL
                ]),
                coverDetector: EmptyCoverDetector(),
                maxConcurrentAlbums: AppConfiguration.live.scan.maxConcurrentAlbums
            )

            let result = try await scanner.scan(libraryURL: root, role: .album)
            let cover = try #require(result.albums[0].displayedCover)

            #expect(cover.url == embeddedArtworkURL)
            #expect(cover.source == .embeddedArtwork)
            #expect(cover.relativePath == "内嵌封面：01.flac")
        }
    }

    @Test("独立图片优先于音频内嵌图")
    func imageFileCoverWinsOverEmbeddedArtwork() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("01.flac", under: root)
            let imageFileURL = root.appendingPathComponent("cover.jpg")
            let embeddedArtworkURL = root.appendingPathComponent("Cache/embedded.jpg")
            let scanner = FileSystemLibraryScanner(
                metadataReader: StubMetadataReader(embeddedArtworkNames: [
                    "01.flac": embeddedArtworkURL
                ]),
                coverDetector: StaticCoverDetector(selected: CoverCandidate(
                    url: imageFileURL,
                    relativePath: "cover.jpg",
                    namePriority: 0,
                    depth: 0
                )),
                maxConcurrentAlbums: AppConfiguration.live.scan.maxConcurrentAlbums
            )

            let result = try await scanner.scan(libraryURL: root, role: .album)
            let cover = try #require(result.albums[0].displayedCover)

            #expect(cover.url == imageFileURL)
            #expect(cover.source == .file)
        }
    }

    @Test("已有独立图片封面时跳过音频内嵌图读取")
    func imageFileCoverSkipsEmbeddedArtworkMetadataRead() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("01.flac", under: root)
            let imageFileURL = root.appendingPathComponent("cover.jpg")
            let embeddedArtworkURL = root.appendingPathComponent("Embedded/embedded.jpg")
            try writeValidPNG(to: imageFileURL)
            let metadataReader = RecordingArtworkGateMetadataReader(
                embeddedArtworkNames: ["01.flac": embeddedArtworkURL]
            )
            let scanner = FileSystemLibraryScanner(
                metadataReader: metadataReader,
                coverDetector: ImageIOCoverDetector(),
                maxConcurrentAlbums: AppConfiguration.live.scan.maxConcurrentAlbums
            )

            let result = try await scanner.scan(libraryURL: root, role: .album)
            let cover = try #require(result.albums[0].displayedCover)

            #expect(isSameFileURL(cover.url, imageFileURL))
            #expect(cover.source == .file)
            #expect(metadataReader.includeEmbeddedArtworkRequests() == [false])
            #expect(result.albums[0].audioFiles[0].metadata?.embeddedArtworkURL == nil)
        }
    }

    @Test("真实图片文件扫描结果会作为封面墙显示封面")
    func realImageFileBecomesDisplayedCover() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("01.flac", under: root)
            let imageFileURL = root.appendingPathComponent("cover.png")
            let embeddedArtworkURL = root.appendingPathComponent("Embedded/embedded.jpg")
            try writeValidPNG(to: imageFileURL)
            let scanner = FileSystemLibraryScanner(
                metadataReader: StubMetadataReader(embeddedArtworkNames: [
                    "01.flac": embeddedArtworkURL
                ]),
                coverDetector: ImageIOCoverDetector(),
                maxConcurrentAlbums: AppConfiguration.live.scan.maxConcurrentAlbums
            )

            let result = try await scanner.scan(libraryURL: root, role: .album)
            let cover = try #require(result.albums[0].displayedCover)

            #expect(isSameFileURL(cover.url, imageFileURL))
            #expect(cover.source == .file)
            #expect(cover.previewURL != nil)
            #expect(FileManager.default.fileExists(atPath: try #require(cover.previewURL).path))
        }
    }

    @Test("重扫时 cover.jpg 的新增和删除会反映到封面状态")
    func rescanningReflectsCoverFileChanges() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("01.flac", under: root)
            let scanner = FileSystemLibraryScanner(
                metadataReader: StubMetadataReader(),
                coverDetector: ImageIOCoverDetector(),
                maxConcurrentAlbums: AppConfiguration.live.scan.maxConcurrentAlbums
            )
            let coverURL = root.appendingPathComponent("cover.jpg")

            let resultBeforeCover = try await scanner.scan(libraryURL: root, role: .album)
            #expect(resultBeforeCover.albums[0].displayedCover == nil)

            try writeValidPNG(to: coverURL)
            let resultAfterCoverAdded = try await scanner.scan(libraryURL: root, role: .album)
            #expect(resultAfterCoverAdded.albums[0].displayedCover?.relativePath == "cover.jpg")

            try FileManager.default.removeItem(at: coverURL)
            let resultAfterCoverDeleted = try await scanner.scan(libraryURL: root, role: .album)
            #expect(resultAfterCoverDeleted.albums[0].displayedCover == nil)
        }
    }

    @Test("重扫时新增多个 WAV 分轨会反映到曲目列表")
    func rescanningReflectsAddedWAVTracks() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("01.wav", under: root)
            let scanner = makeScanner()

            let resultBeforeAddingTracks = try await scanner.scan(libraryURL: root, role: .album)
            #expect(resultBeforeAddingTracks.albums[0].audioFiles.map(\.relativePath) == ["01.wav"])

            try makeAudio("02.wav", under: root)
            try makeAudio("03.wav", under: root)
            let resultAfterAddingTracks = try await scanner.scan(libraryURL: root, role: .album)

            #expect(resultAfterAddingTracks.albums[0].audioFiles.map(\.relativePath) == [
                "01.wav", "02.wav", "03.wav"
            ])
        }
    }

    @Test("歌手目录没有专辑子目录时给出明确错误")
    func artistWithoutAlbumIsRejected() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("散曲.mp3", under: root)

            await #expect(throws: LibraryScanError.noAlbumsFound) {
                try await makeScanner().scan(libraryURL: root, role: .artist)
            }
        }
    }

    @Test("扩展名像音频的文件夹不会进入曲目列表")
    func audioExtensionDirectoryIsNotScannedAsTrack() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("01.wav", under: root)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("不是音频.flac", isDirectory: true),
                withIntermediateDirectories: true
            )

            let result = try await makeScanner().scan(libraryURL: root, role: .album)

            #expect(result.albums[0].audioFiles.map(\.relativePath) == ["01.wav"])
        }
    }

    @Test("扫描器按目录、标签、封面和整理阶段报告进度")
    func reportsDetailedScanProgress() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("01.flac", under: root)
            let collector = ScanProgressCollector()

            _ = try await makeScanner().scan(libraryURL: root, role: .album) { progress in
                await collector.append(progress)
            }
            let phases = await collector.snapshot().map(\.phase)

            #expect(phases.first == .discoveringAlbums)
            #expect(phases.contains(.readingMetadata))
            #expect(phases.contains(.detectingCover))
            #expect(phases.last == .finishing)
        }
    }

    @Test("音乐库扫描按专辑进行有上限的并发")
    func scansAlbumsWithBoundedConcurrency() async throws {
        try await withTemporaryDirectory { root in
            try makeAudio("歌手/甲/01.flac", under: root)
            try makeAudio("歌手/乙/01.flac", under: root)
            try makeAudio("歌手/丙/01.flac", under: root)
            let probe = ConcurrentReadProbe()
            let scanner = FileSystemLibraryScanner(
                metadataReader: DelayedMetadataReader(probe: probe),
                coverDetector: EmptyCoverDetector(),
                maxConcurrentAlbums: 2
            )

            _ = try await scanner.scan(libraryURL: root, role: .library)

            #expect(await probe.maxActiveReaders() == 2)
        }
    }

    private func makeScanner() -> FileSystemLibraryScanner {
        FileSystemLibraryScanner(
            metadataReader: StubMetadataReader(),
            coverDetector: EmptyCoverDetector(),
            maxConcurrentAlbums: AppConfiguration.live.scan.maxConcurrentAlbums
        )
    }

    private func makeAudio(_ relativePath: String, under root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0]).write(to: url)
    }

    private func writeValidPNG(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try png.write(to: url)
    }

    private func isSameFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverDropScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }
}

private struct StubMetadataReader: AudioMetadataReading {
    let failingNames: Set<String>
    let embeddedArtworkNames: [String: URL]

    init(
        failingNames: Set<String> = [],
        embeddedArtworkNames: [String: URL] = [:]
    ) {
        self.failingNames = failingNames
        self.embeddedArtworkNames = embeddedArtworkNames
    }

    func readMetadata(
        at url: URL,
        includingEmbeddedArtwork: Bool
    ) async throws -> AudioMetadata {
        if failingNames.contains(url.lastPathComponent) {
            throw StubMetadataError.unreadable
        }

        let disc = url.pathComponents.last { $0.hasPrefix("CD") }
            .flatMap { Int($0.dropFirst(2)) }
        let track = Int(url.deletingPathExtension().lastPathComponent)
        return AudioMetadata(
            title: nil,
            artist: nil,
            albumArtist: nil,
            album: nil,
            discNumber: disc,
            trackNumber: track,
            durationSeconds: nil,
            embeddedArtworkURL: includingEmbeddedArtwork
                ? embeddedArtworkNames[url.lastPathComponent]
                : nil
        )
    }
}

private final class RecordingArtworkGateMetadataReader: AudioMetadataReading, @unchecked Sendable {
    private let embeddedArtworkNames: [String: URL]
    private let lock = NSLock()
    private var requests: [Bool] = []

    init(embeddedArtworkNames: [String: URL]) {
        self.embeddedArtworkNames = embeddedArtworkNames
    }

    func readMetadata(
        at url: URL,
        includingEmbeddedArtwork: Bool
    ) async throws -> AudioMetadata {
        recordRequest(includingEmbeddedArtwork)

        return AudioMetadata(
            title: nil,
            artist: nil,
            albumArtist: nil,
            album: nil,
            discNumber: nil,
            trackNumber: nil,
            durationSeconds: nil,
            embeddedArtworkURL: includingEmbeddedArtwork
                ? embeddedArtworkNames[url.lastPathComponent]
                : nil
        )
    }

    private func recordRequest(_ includingEmbeddedArtwork: Bool) {
        lock.lock()
        requests.append(includingEmbeddedArtwork)
        lock.unlock()
    }

    func includeEmbeddedArtworkRequests() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private enum StubMetadataError: Error {
    case unreadable
}

private struct EmptyCoverDetector: CoverDetecting {
    func detectCover(in albumURL: URL) async throws -> CoverDetectionResult {
        CoverDetectionResult(selected: nil, invalidNamedPaths: [])
    }
}

private struct StaticCoverDetector: CoverDetecting {
    let selected: CoverCandidate?

    func detectCover(in albumURL: URL) async throws -> CoverDetectionResult {
        CoverDetectionResult(selected: selected, invalidNamedPaths: [])
    }
}

private struct DelayedMetadataReader: AudioMetadataReading {
    let probe: ConcurrentReadProbe

    func readMetadata(
        at url: URL,
        includingEmbeddedArtwork: Bool
    ) async throws -> AudioMetadata {
        await probe.enter()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await probe.leave()
        return AudioMetadata(
            title: nil,
            artist: nil,
            albumArtist: nil,
            album: nil,
            discNumber: nil,
            trackNumber: nil,
            durationSeconds: nil,
            embeddedArtworkURL: nil
        )
    }
}

private actor ConcurrentReadProbe {
    private var activeReaders = 0
    private var maximumActiveReaders = 0

    func enter() {
        activeReaders += 1
        maximumActiveReaders = max(maximumActiveReaders, activeReaders)
    }

    func leave() {
        activeReaders -= 1
    }

    func maxActiveReaders() -> Int {
        maximumActiveReaders
    }
}

private actor ScanProgressCollector {
    private var values: [LibraryScanProgress] = []

    func append(_ progress: LibraryScanProgress) {
        values.append(progress)
    }

    func snapshot() -> [LibraryScanProgress] {
        values
    }
}
