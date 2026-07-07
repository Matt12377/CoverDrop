import Foundation
import Testing
@testable import CoverDrop

struct FileScanSnapshotStoreTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_767_330_305)
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test("快照写入后可以读取并恢复关键字段")
    func savedSnapshotCanBeLoadedAndRestored() async throws {
        try await withTemporaryDirectory { root in
            let store = FileScanSnapshotStore(directoryURL: root, timeZone: utc)
            let library = makeLibrary(rootPath: "/Volumes/Music", role: .library)
            let albumFolder = URL(fileURLWithPath: "/Volumes/Music/Artist/Album", isDirectory: true)
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
                            title: "第一首",
                            artist: "歌手",
                            albumArtist: "专辑歌手",
                            album: "专辑",
                            discNumber: 1,
                            trackNumber: 1,
                            durationSeconds: 245,
                            embeddedArtworkURL: albumFolder.appendingPathComponent("artwork.jpg")
                        ),
                        readError: nil
                    )
                ],
                displayedCover: CoverCandidate(
                    url: albumFolder.appendingPathComponent("cover.jpg"),
                    previewURL: albumFolder.appendingPathComponent("cover-preview.jpg"),
                    relativePath: "cover.jpg",
                    namePriority: 0,
                    depth: 0,
                    source: .file
                ),
                issues: [
                    .uncertainAlbumBoundary(reason: "版本目录需要确认")
                ]
            )
            let snapshot = ScanSnapshot(
                createdAt: fixedDate,
                library: ScanSnapshot.Library(library: library),
                scanResult: ScanSnapshot.Result(result: LibraryScanResult(
                    albums: [album],
                    looseAudioPaths: ["Loose/track.flac"]
                )),
                albumNameEnhancement: ScanSnapshot.AlbumNameEnhancement(
                    suggestionsByAlbumID: [
                        album.id: AlbumNameSuggestion(
                            artistName: "增强歌手",
                            albumName: "增强专辑"
                        )
                    ],
                    status: AlbumNameEnhancementStatus(
                        isRunning: false,
                        lastErrorMessage: nil
                    )
                )
            )

            let summary = try await store.saveNewSnapshot(snapshot)
            let loaded = try await store.loadSnapshot(at: summary.fileURL, expectedLibrary: library)
            let restoredResult = try loaded.scanResult.makeLibraryScanResult()
            let restoredAlbum = try #require(restoredResult.albums.first)

            #expect(summary.fileURL.pathExtension == "db")
            #expect(loaded.library.rootPath == "/Volumes/Music")
            #expect(restoredAlbum.folderURL.path == albumFolder.path)
            #expect(restoredAlbum.displayedCover?.source == .file)
            #expect(restoredAlbum.audioFiles.first?.metadata?.title == "第一首")
            #expect(restoredAlbum.issues.first?.displayName == "专辑边界需要确认：版本目录需要确认")
            #expect(restoredResult.looseAudioPaths == ["Loose/track.flac"])
            #expect(loaded.albumNameEnhancement?.makeSuggestionsByAlbumID()[album.id]?.albumName == "增强专辑")
        }
    }

    @Test("文件名清洗与目录角色稳定 key 命名")
    func stableDatabaseFileNameUsesLibraryRootAndRole() {
        let fileName = FileScanSnapshotStore.stableDatabaseFileName(
            displayName: " 张/三:精选?数据库 ",
            rootPath: "/Volumes/Music",
            role: .artist
        )

        #expect(fileName == "张-三-精选-数据库-artist-37c00e144f7c6e2e.db")
    }

    @Test("同地址目录重复扫描覆盖同一个稳定快照")
    func savingSameLibraryOverwritesStableSnapshot() async throws {
        try await withTemporaryDirectory { root in
            let store = FileScanSnapshotStore(directoryURL: root, timeZone: utc)
            let library = makeLibrary(rootPath: "/Volumes/Music", role: .artist)
            let first = try await store.saveNewSnapshot(makeSnapshot(
                library: library,
                createdAt: Date(timeIntervalSince1970: 100)
            ))
            let newer = try await store.saveNewSnapshot(makeSnapshot(
                library: library,
                createdAt: Date(timeIntervalSince1970: 200)
            ))

            let latest = try await store.latestSnapshot(for: library)
            let dbFiles = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "db" }

            #expect(first.fileURL == newer.fileURL)
            #expect(dbFiles.count == 1)
            #expect(latest?.fileURL == newer.fileURL)
            #expect(latest?.createdAt == newer.createdAt)
        }
    }

    @Test("不同地址目录不会误加载")
    func latestSnapshotIgnoresDifferentLibraryRoot() async throws {
        try await withTemporaryDirectory { root in
            let store = FileScanSnapshotStore(directoryURL: root, timeZone: utc)
            _ = try await store.saveNewSnapshot(makeSnapshot(
                library: makeLibrary(rootPath: "/Volumes/A", role: .library),
                createdAt: fixedDate
            ))

            let latest = try await store.latestSnapshot(for: makeLibrary(rootPath: "/Volumes/B", role: .library))

            #expect(latest == nil)
        }
    }

    @Test("schemaVersion 不兼容时加载失败")
    func incompatibleSchemaVersionFailsToLoad() async throws {
        try await withTemporaryDirectory { root in
            let store = FileScanSnapshotStore(directoryURL: root, timeZone: utc)
            let library = makeLibrary(rootPath: "/Volumes/Music", role: .library)
            let summary = try await store.saveNewSnapshot(makeSnapshot(
                library: library,
                createdAt: fixedDate,
                schemaVersion: 999
            ))

            await #expect(throws: FileScanSnapshotStoreError.self) {
                try await store.loadSnapshot(at: summary.fileURL, expectedLibrary: library)
            }
        }
    }

    private func makeSnapshot(
        library: LibraryRecord,
        createdAt: Date,
        schemaVersion: Int = ScanSnapshot.currentSchemaVersion
    ) -> ScanSnapshot {
        ScanSnapshot(
            schemaVersion: schemaVersion,
            createdAt: createdAt,
            library: ScanSnapshot.Library(library: library),
            scanResult: ScanSnapshot.Result(result: LibraryScanResult(
                albums: [],
                looseAudioPaths: []
            )),
            albumNameEnhancement: nil
        )
    }

    private func makeLibrary(rootPath: String, role: LibraryRole) -> LibraryRecord {
        LibraryRecord(
            displayName: URL(fileURLWithPath: rootPath).lastPathComponent,
            rootPath: rootPath,
            bookmarkData: Data(rootPath.utf8),
            role: role
        )
    }

    private func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverDropSnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }
}
