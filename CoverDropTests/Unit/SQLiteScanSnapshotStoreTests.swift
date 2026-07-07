import Foundation
import Testing
@testable import CoverDrop

struct SQLiteScanSnapshotStoreTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_767_330_305)

    @Test("SQLite 快照写入后可以读取并恢复关键字段")
    func savedSQLiteSnapshotCanBeLoadedAndRestored() async throws {
        try await withTemporaryDirectory { root in
            let store = SQLiteScanSnapshotStore(directoryURL: root)
            let library = makeLibrary(rootPath: "/Volumes/Music", role: .library)
            let snapshot = makeSnapshot(library: library, albumCount: 2)

            let summary = try await store.saveNewSnapshot(snapshot)
            let loaded = try await store.loadSnapshot(at: summary.fileURL, expectedLibrary: library)
            let result = try loaded.scanResult.makeLibraryScanResult()
            let firstAlbum = try #require(result.albums.first)

            #expect(summary.fileURL.pathExtension == "db")
            #expect(summary.albumCount == 2)
            #expect(loaded.library.rootPath == "/Volumes/Music")
            #expect(result.albums.count == 2)
            #expect(result.looseAudioPaths == ["Loose/track.flac"])
            #expect(firstAlbum.audioFiles.first?.metadata?.title == "第一首")
            #expect(firstAlbum.displayedCover?.source == .file)
            #expect(firstAlbum.issues.first?.displayName == "专辑边界需要确认：版本目录需要确认")
            #expect(loaded.albumNameEnhancement?.makeSuggestionsByAlbumID()[firstAlbum.id]?.albumName == "增强专辑 0")
        }
    }

    @Test("同地址目录重复保存覆盖同一个 SQLite 快照")
    func savingSameLibraryOverwritesStableSQLiteSnapshot() async throws {
        try await withTemporaryDirectory { root in
            let store = SQLiteScanSnapshotStore(directoryURL: root)
            let library = makeLibrary(rootPath: "/Volumes/Music", role: .artist)
            let first = try await store.saveNewSnapshot(makeSnapshot(library: library, albumCount: 1))
            let newer = try await store.saveNewSnapshot(makeSnapshot(
                library: library,
                albumCount: 3,
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
            #expect(latest?.albumCount == 3)
            #expect(latest?.createdAt == newer.createdAt)
        }
    }

    @Test("SQLite 流式加载按批上报专辑进度")
    func streamingLoadReportsAlbumProgress() async throws {
        try await withTemporaryDirectory { root in
            let store = SQLiteScanSnapshotStore(directoryURL: root)
            let library = makeLibrary(rootPath: "/Volumes/Music", role: .library)
            let summary = try await store.saveNewSnapshot(makeSnapshot(library: library, albumCount: 205))
            let recorder = ProgressRecorder()

            _ = try await store.loadSnapshot(
                at: summary.fileURL,
                expectedLibrary: library
            ) { progress in
                await recorder.append(progress)
            }

            let progresses = await recorder.values
            #expect(progresses.contains { $0.completedAlbums == 100 && $0.totalAlbums == 205 })
            #expect(progresses.contains { $0.completedAlbums == 200 && $0.totalAlbums == 205 })
            #expect(progresses.last?.completedAlbums == 205)
            #expect(progresses.last?.albumProgressFraction == 1)
        }
    }

    @Test("SQLite store 兼容读取旧 JSON 快照")
    func sqliteStoreLoadsLegacyJSONSnapshot() async throws {
        try await withTemporaryDirectory { root in
            let legacyStore = FileScanSnapshotStore(directoryURL: root)
            let sqliteStore = SQLiteScanSnapshotStore(directoryURL: root)
            let library = makeLibrary(rootPath: "/Volumes/Music", role: .library)
            let legacySummary = try await legacyStore.saveNewSnapshot(makeSnapshot(library: library, albumCount: 1))

            let latest = try await sqliteStore.latestSnapshot(for: library)
            let loaded = try await sqliteStore.loadSnapshot(at: legacySummary.fileURL, expectedLibrary: library)

            #expect(latest?.fileURL == legacySummary.fileURL)
            #expect(loaded.scanResult.albums.count == 1)
        }
    }

    @Test("SQLite 快照路径不匹配时拒绝加载")
    func sqliteSnapshotRejectsDifferentLibraryRoot() async throws {
        try await withTemporaryDirectory { root in
            let store = SQLiteScanSnapshotStore(directoryURL: root)
            let library = makeLibrary(rootPath: "/Volumes/A", role: .library)
            let summary = try await store.saveNewSnapshot(makeSnapshot(library: library, albumCount: 1))

            await #expect(throws: SQLiteScanSnapshotStoreError.self) {
                try await store.loadSnapshot(
                    at: summary.fileURL,
                    expectedLibrary: makeLibrary(rootPath: "/Volumes/B", role: .library)
                )
            }
        }
    }

    private func makeSnapshot(
        library: LibraryRecord,
        albumCount: Int,
        createdAt: Date? = nil
    ) -> ScanSnapshot {
        let albums = (0..<albumCount).map { index in
            makeAlbum(index: index, libraryRoot: library.rootPath)
        }
        let suggestions = Dictionary(uniqueKeysWithValues: albums.map { album in
            (
                album.id,
                AlbumNameSuggestion(
                    artistName: "增强歌手 \(album.albumName)",
                    albumName: "增强专辑 \(album.albumName.split(separator: " ").last ?? "")"
                )
            )
        })
        return ScanSnapshot(
            createdAt: createdAt ?? fixedDate,
            library: ScanSnapshot.Library(library: library),
            scanResult: ScanSnapshot.Result(result: LibraryScanResult(
                albums: albums,
                looseAudioPaths: ["Loose/track.flac"]
            )),
            albumNameEnhancement: ScanSnapshot.AlbumNameEnhancement(
                suggestionsByAlbumID: suggestions,
                status: AlbumNameEnhancementStatus(isRunning: false, lastErrorMessage: nil)
            )
        )
    }

    private func makeAlbum(index: Int, libraryRoot: String) -> AlbumScanRecord {
        let albumFolder = URL(
            fileURLWithPath: "\(libraryRoot)/Artist/Album \(index)",
            isDirectory: true
        )
        return AlbumScanRecord(
            folderURL: albumFolder,
            artistName: "原始歌手",
            albumName: "原始专辑 \(index)",
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
            issues: [.uncertainAlbumBoundary(reason: "版本目录需要确认")]
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
            .appendingPathComponent("CoverDropSQLiteSnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }
}

private actor ProgressRecorder {
    private(set) var values: [ScanSnapshotLoadProgress] = []

    func append(_ progress: ScanSnapshotLoadProgress) {
        values.append(progress)
    }
}
