import Foundation
import SQLite3
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
            #expect(firstAlbum.cueSheets.map(\.relativePath) == ["album.cue"])
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

    @Test("旧音乐库的全量替换不会覆盖同路径的新音乐库快照")
    func staleReplacementDoesNotOverwriteNewLibrarySnapshot() async throws {
        try await withTemporaryDirectory { root in
            let store = SQLiteScanSnapshotStore(directoryURL: root)
            let oldLibrary = makeLibrary(rootPath: "/Volumes/Music", role: .library)
            let newLibrary = makeLibrary(rootPath: "/Volumes/Music", role: .library)
            let oldSnapshot = makeSnapshot(library: oldLibrary, albumCount: 1)
            let oldSummary = try await store.saveNewSnapshot(oldSnapshot)
            let newSummary = try await store.saveNewSnapshot(makeSnapshot(
                library: newLibrary,
                albumCount: 3
            ))

            #expect(oldSummary.fileURL == newSummary.fileURL)
            await #expect(throws: SQLiteScanSnapshotStoreError.self) {
                try await store.replaceSnapshot(oldSnapshot, at: oldSummary.fileURL)
            }

            let loaded = try await store.loadSnapshot(
                at: newSummary.fileURL,
                expectedLibrary: newLibrary
            )
            #expect(loaded.library.id == newLibrary.id)
            #expect(loaded.scanResult.albums.count == 3)
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

    @Test("旧 JSON 快照读取和解码离开主线程")
    func legacyJSONWorkRunsOffMainThread() async throws {
        let wasMainThread = try await SQLiteScanSnapshotStore.runLegacyJSONWorkOffMainActor {
            Thread.isMainThread
        }

        #expect(!wasMainThread)
    }

    @Test("SQLite store 兼容读取没有 CUE 字段的 v1 JSON 快照")
    func sqliteStoreLoadsVersionOneJSONSnapshotWithoutCueSheets() async throws {
        try await withTemporaryDirectory { root in
            let store = SQLiteScanSnapshotStore(directoryURL: root)
            let library = makeLibrary(rootPath: "/Volumes/Music", role: .library)
            let fileURL = root.appendingPathComponent("legacy-v1.db")
            try Data("""
            {
              "schemaVersion" : 1,
              "createdAt" : "2026-01-02T03:04:05Z",
              "library" : {
                "id" : "\(library.id.uuidString)",
                "displayName" : "\(library.displayName)",
                "rootPath" : "\(library.rootPath)",
                "role" : "\(library.role.rawValue)"
              },
              "scanResult" : {
                "albums" : [
                  {
                    "folderPath" : "\(library.rootPath)/Artist/Album",
                    "artistName" : "Artist",
                    "albumName" : "Album",
                    "audioFiles" : [],
                    "displayedCover" : null,
                    "issues" : []
                  }
                ],
                "looseAudioPaths" : []
              },
              "albumNameEnhancement" : null
            }
            """.utf8).write(to: fileURL)

            let loaded = try await store.loadSnapshot(at: fileURL, expectedLibrary: library)
            let result = try loaded.scanResult.makeLibraryScanResult()

            #expect(loaded.schemaVersion == 1)
            #expect(result.albums.first?.cueSheets == [])
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

    @Test("更新单张专辑封面时不重写音频行")
    func incrementalCoverUpdatePreservesAudioRows() async throws {
        try await withTemporaryDirectory { root in
            let store = SQLiteScanSnapshotStore(directoryURL: root)
            let library = makeLibrary(rootPath: "/Volumes/Music", role: .library)
            let snapshot = makeSnapshot(library: library, albumCount: 2)
            let summary = try await store.saveNewSnapshot(snapshot)
            let album = try #require(snapshot.scanResult.albums.first)
            let rowIDsBefore = try audioFileRowIDs(at: summary.fileURL)
            let updatedCover = ScanSnapshot.Cover(
                path: "\(album.folderPath)/cover-new.jpg",
                previewPath: "\(album.folderPath)/cover-new-preview.jpg",
                relativePath: "cover-new.jpg",
                namePriority: 0,
                depth: 0,
                source: .file
            )

            let updatedSummary = try await store.updateAlbumCover(
                updatedCover,
                forAlbumID: album.folderPath,
                at: summary.fileURL,
                expectedLibrary: library
            )
            let loaded = try await store.loadSnapshot(
                at: updatedSummary.fileURL,
                expectedLibrary: library
            )
            let updatedAlbum = try #require(loaded.scanResult.albums.first)

            #expect(try audioFileRowIDs(at: summary.fileURL) == rowIDsBefore)
            #expect(updatedSummary.albumCount == 2)
            #expect(updatedAlbum.displayedCover == updatedCover)
        }
    }

    @Test("增量封面更新拒绝同路径但身份不同的音乐库")
    func incrementalCoverUpdateRejectsDifferentLibraryIdentity() async throws {
        try await withTemporaryDirectory { root in
            let store = SQLiteScanSnapshotStore(directoryURL: root)
            let originalLibrary = makeLibrary(rootPath: "/Volumes/Music", role: .library)
            let replacementLibrary = makeLibrary(rootPath: "/Volumes/Music", role: .library)
            let snapshot = makeSnapshot(library: originalLibrary, albumCount: 1)
            let summary = try await store.saveNewSnapshot(snapshot)
            let album = try #require(snapshot.scanResult.albums.first)

            #expect(originalLibrary.id != replacementLibrary.id)
            await #expect(throws: SQLiteScanSnapshotStoreError.self) {
                try await store.updateAlbumCover(
                    nil,
                    forAlbumID: album.folderPath,
                    at: summary.fileURL,
                    expectedLibrary: replacementLibrary
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
            cueSheets: [
                CueSheetRecord(
                    url: albumFolder.appendingPathComponent("album.cue"),
                    relativePath: "album.cue"
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

    private func audioFileRowIDs(at fileURL: URL) throws -> [Int64] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            throw SQLiteScanSnapshotStoreError.openFailed("测试无法打开数据库")
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT rowid FROM audio_files ORDER BY album_id, ordinal",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            sqlite3_finalize(statement)
            throw SQLiteScanSnapshotStoreError.queryFailed("测试无法读取音频行")
        }
        defer { sqlite3_finalize(statement) }

        var rowIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rowIDs.append(sqlite3_column_int64(statement, 0))
        }
        return rowIDs
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
