import Foundation
import SQLite3

final class SQLiteScanSnapshotStore: StreamingScanSnapshotStoring, @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    func saveNewSnapshot(_ snapshot: ScanSnapshot) async throws -> ScanSnapshotSummary {
        try createDirectoryIfNeeded()
        let fileURL = stableDatabaseFileURL(for: snapshot.library)
        try write(snapshot, to: fileURL)
        return summary(for: snapshot, fileURL: fileURL)
    }

    func replaceSnapshot(_ snapshot: ScanSnapshot, at fileURL: URL) async throws -> ScanSnapshotSummary {
        try createDirectoryIfNeeded()
        guard fileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == directoryURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw SQLiteScanSnapshotStoreError.outsideSnapshotDirectory(fileURL.path)
        }

        let stableFileURL = stableDatabaseFileURL(for: snapshot.library)
        try write(snapshot, to: stableFileURL)
        return summary(for: snapshot, fileURL: stableFileURL)
    }

    func latestSnapshot(for library: LibraryRecord) async throws -> ScanSnapshotSummary? {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return nil }

        let fileURL = stableDatabaseFileURL(for: library)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        do {
            return try sqliteSummary(at: fileURL, expectedLibrary: library)
        } catch SQLiteScanSnapshotStoreError.notSQLiteSnapshot {
            return try legacyJSONSummary(at: fileURL, expectedLibrary: library)
        }
    }

    func loadSnapshot(at fileURL: URL, expectedLibrary: LibraryRecord) async throws -> ScanSnapshot {
        do {
            return try await loadSQLiteSnapshot(
                at: fileURL,
                expectedLibrary: expectedLibrary,
                progress: nil
            )
        } catch SQLiteScanSnapshotStoreError.notSQLiteSnapshot {
            return try legacyJSONSnapshot(at: fileURL, expectedLibrary: expectedLibrary)
        }
    }

    func loadSnapshot(
        at fileURL: URL,
        expectedLibrary: LibraryRecord,
        progress: @escaping @Sendable (ScanSnapshotLoadProgress) async -> Void
    ) async throws -> ScanSnapshot {
        do {
            return try await loadSQLiteSnapshot(
                at: fileURL,
                expectedLibrary: expectedLibrary,
                progress: progress
            )
        } catch SQLiteScanSnapshotStoreError.notSQLiteSnapshot {
            let snapshot = try legacyJSONSnapshot(at: fileURL, expectedLibrary: expectedLibrary)
            await progress(
                ScanSnapshotLoadProgress(
                    phase: .converting,
                    completedAlbums: snapshot.scanResult.albums.count,
                    totalAlbums: snapshot.scanResult.albums.count
                )
            )
            return snapshot
        }
    }

    private func createDirectoryIfNeeded() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func stableDatabaseFileURL(for library: LibraryRecord) -> URL {
        directoryURL.appendingPathComponent(
            FileScanSnapshotStore.stableDatabaseFileName(
                displayName: library.displayName,
                rootPath: library.rootPath,
                role: library.role
            ),
            isDirectory: false
        )
    }

    private func stableDatabaseFileURL(for library: ScanSnapshot.Library) -> URL {
        directoryURL.appendingPathComponent(
            FileScanSnapshotStore.stableDatabaseFileName(
                displayName: library.displayName,
                rootPath: library.rootPath,
                role: library.role
            ),
            isDirectory: false
        )
    }

    private func write(_ snapshot: ScanSnapshot, to fileURL: URL) throws {
        var db: OpaquePointer?
        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            throw SQLiteScanSnapshotStoreError.openFailed(sqliteError(db))
        }
        guard let db else { throw SQLiteScanSnapshotStoreError.openFailed("未知错误") }
        defer { sqlite3_close(db) }

        try execute(db, "PRAGMA foreign_keys = ON")
        try execute(db, "BEGIN IMMEDIATE TRANSACTION")
        do {
            try createSchema(in: db)
            try clearSnapshotTables(in: db)
            try insertSnapshot(snapshot, db: db)
            try execute(db, "COMMIT")
            CoverDropDebugLog.write("扫描快照：SQLite 已写入 \(fileURL.path)")
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    private func createSchema(in db: OpaquePointer) throws {
        try execute(db, """
        CREATE TABLE IF NOT EXISTS snapshots (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            schema_version INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            library_id TEXT NOT NULL,
            library_display_name TEXT NOT NULL,
            library_root_path TEXT NOT NULL,
            library_role TEXT NOT NULL,
            loose_audio_paths_json TEXT NOT NULL
        )
        """)
        try execute(db, """
        CREATE TABLE IF NOT EXISTS albums (
            id TEXT PRIMARY KEY,
            ordinal INTEGER NOT NULL,
            folder_path TEXT NOT NULL,
            artist_name TEXT NOT NULL,
            album_name TEXT NOT NULL,
            cover_path TEXT,
            cover_preview_path TEXT,
            cover_relative_path TEXT,
            cover_name_priority INTEGER,
            cover_depth INTEGER,
            cover_source TEXT
        )
        """)
        try execute(db, """
        CREATE TABLE IF NOT EXISTS audio_files (
            album_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            path TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            format TEXT NOT NULL,
            title TEXT,
            artist TEXT,
            album_artist TEXT,
            album TEXT,
            disc_number INTEGER,
            track_number INTEGER,
            duration_seconds INTEGER,
            embedded_artwork_path TEXT,
            read_error TEXT,
            PRIMARY KEY (album_id, ordinal),
            FOREIGN KEY (album_id) REFERENCES albums(id) ON DELETE CASCADE
        )
        """)
        try execute(db, """
        CREATE TABLE IF NOT EXISTS album_cue_sheets (
            album_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            path TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            PRIMARY KEY (album_id, ordinal),
            FOREIGN KEY (album_id) REFERENCES albums(id) ON DELETE CASCADE
        )
        """)
        try execute(db, """
        CREATE TABLE IF NOT EXISTS album_issues (
            album_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            kind TEXT NOT NULL,
            has_cue INTEGER,
            paths_json TEXT,
            reason TEXT,
            PRIMARY KEY (album_id, ordinal),
            FOREIGN KEY (album_id) REFERENCES albums(id) ON DELETE CASCADE
        )
        """)
        try execute(db, """
        CREATE TABLE IF NOT EXISTS album_name_suggestions (
            album_id TEXT PRIMARY KEY,
            artist_name TEXT NOT NULL,
            album_name TEXT NOT NULL,
            FOREIGN KEY (album_id) REFERENCES albums(id) ON DELETE CASCADE
        )
        """)
        try execute(db, """
        CREATE TABLE IF NOT EXISTS album_name_status (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            is_running INTEGER NOT NULL,
            last_error_message TEXT
        )
        """)
    }

    private func clearSnapshotTables(in db: OpaquePointer) throws {
        try execute(db, "DELETE FROM album_name_status")
        try execute(db, "DELETE FROM album_name_suggestions")
        try execute(db, "DELETE FROM album_issues")
        try execute(db, "DELETE FROM album_cue_sheets")
        try execute(db, "DELETE FROM audio_files")
        try execute(db, "DELETE FROM albums")
        try execute(db, "DELETE FROM snapshots")
    }

    private func insertSnapshot(_ snapshot: ScanSnapshot, db: OpaquePointer) throws {
        let looseAudioJSON = try encodeJSON(snapshot.scanResult.looseAudioPaths)
        try withStatement(
            db,
            """
            INSERT INTO snapshots (
                id, schema_version, created_at, library_id, library_display_name,
                library_root_path, library_role, loose_audio_paths_json
            ) VALUES (1, ?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            bindInt(snapshot.schemaVersion, to: statement, at: 1)
            bindText(iso8601String(snapshot.createdAt), to: statement, at: 2)
            bindText(snapshot.library.id.uuidString, to: statement, at: 3)
            bindText(snapshot.library.displayName, to: statement, at: 4)
            bindText(snapshot.library.rootPath, to: statement, at: 5)
            bindText(snapshot.library.role.rawValue, to: statement, at: 6)
            bindText(looseAudioJSON, to: statement, at: 7)
            try stepDone(statement, db: db)
        }

        for (albumIndex, album) in snapshot.scanResult.albums.enumerated() {
            try insertAlbum(album, ordinal: albumIndex, db: db)
            for (audioIndex, audioFile) in album.audioFiles.enumerated() {
                try insertAudioFile(audioFile, albumID: album.folderPath, ordinal: audioIndex, db: db)
            }
            for (cueSheetIndex, cueSheet) in album.cueSheets.enumerated() {
                try insertCueSheet(cueSheet, albumID: album.folderPath, ordinal: cueSheetIndex, db: db)
            }
            for (issueIndex, issue) in album.issues.enumerated() {
                try insertIssue(issue, albumID: album.folderPath, ordinal: issueIndex, db: db)
            }
        }

        if let enhancement = snapshot.albumNameEnhancement {
            for (albumID, suggestion) in enhancement.suggestionsByAlbumPath {
                try insertSuggestion(suggestion, albumID: albumID, db: db)
            }
            if let status = enhancement.status {
                try insertStatus(status, db: db)
            }
        }
    }

    private func insertAlbum(_ album: ScanSnapshot.Album, ordinal: Int, db: OpaquePointer) throws {
        try withStatement(
            db,
            """
            INSERT INTO albums (
                id, ordinal, folder_path, artist_name, album_name, cover_path,
                cover_preview_path, cover_relative_path, cover_name_priority,
                cover_depth, cover_source
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            bindText(album.folderPath, to: statement, at: 1)
            bindInt(ordinal, to: statement, at: 2)
            bindText(album.folderPath, to: statement, at: 3)
            bindText(album.artistName, to: statement, at: 4)
            bindText(album.albumName, to: statement, at: 5)
            bindTextOrNull(album.displayedCover?.path, to: statement, at: 6)
            bindTextOrNull(album.displayedCover?.previewPath, to: statement, at: 7)
            bindTextOrNull(album.displayedCover?.relativePath, to: statement, at: 8)
            bindIntOrNull(album.displayedCover?.namePriority, to: statement, at: 9)
            bindIntOrNull(album.displayedCover?.depth, to: statement, at: 10)
            bindTextOrNull(album.displayedCover?.source.rawValue, to: statement, at: 11)
            try stepDone(statement, db: db)
        }
    }

    private func insertAudioFile(
        _ audioFile: ScanSnapshot.AudioFile,
        albumID: String,
        ordinal: Int,
        db: OpaquePointer
    ) throws {
        try withStatement(
            db,
            """
            INSERT INTO audio_files (
                album_id, ordinal, path, relative_path, format, title, artist,
                album_artist, album, disc_number, track_number, duration_seconds,
                embedded_artwork_path, read_error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            bindText(albumID, to: statement, at: 1)
            bindInt(ordinal, to: statement, at: 2)
            bindText(audioFile.path, to: statement, at: 3)
            bindText(audioFile.relativePath, to: statement, at: 4)
            bindText(audioFile.format, to: statement, at: 5)
            bindTextOrNull(audioFile.metadata?.title, to: statement, at: 6)
            bindTextOrNull(audioFile.metadata?.artist, to: statement, at: 7)
            bindTextOrNull(audioFile.metadata?.albumArtist, to: statement, at: 8)
            bindTextOrNull(audioFile.metadata?.album, to: statement, at: 9)
            bindIntOrNull(audioFile.metadata?.discNumber, to: statement, at: 10)
            bindIntOrNull(audioFile.metadata?.trackNumber, to: statement, at: 11)
            bindIntOrNull(audioFile.metadata?.durationSeconds, to: statement, at: 12)
            bindTextOrNull(audioFile.metadata?.embeddedArtworkPath, to: statement, at: 13)
            bindTextOrNull(audioFile.readError, to: statement, at: 14)
            try stepDone(statement, db: db)
        }
    }

    private func insertCueSheet(
        _ cueSheet: ScanSnapshot.CueSheet,
        albumID: String,
        ordinal: Int,
        db: OpaquePointer
    ) throws {
        try withStatement(
            db,
            """
            INSERT INTO album_cue_sheets (
                album_id, ordinal, path, relative_path
            ) VALUES (?, ?, ?, ?)
            """
        ) { statement in
            bindText(albumID, to: statement, at: 1)
            bindInt(ordinal, to: statement, at: 2)
            bindText(cueSheet.path, to: statement, at: 3)
            bindText(cueSheet.relativePath, to: statement, at: 4)
            try stepDone(statement, db: db)
        }
    }

    private func insertIssue(
        _ issue: ScanSnapshot.Issue,
        albumID: String,
        ordinal: Int,
        db: OpaquePointer
    ) throws {
        let pathsJSON = try issue.paths.map { try encodeJSON($0) }
        try withStatement(
            db,
            """
            INSERT INTO album_issues (
                album_id, ordinal, kind, has_cue, paths_json, reason
            ) VALUES (?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            bindText(albumID, to: statement, at: 1)
            bindInt(ordinal, to: statement, at: 2)
            bindText(issue.kind.rawValue, to: statement, at: 3)
            bindIntOrNull(issue.hasCue.map { $0 ? 1 : 0 }, to: statement, at: 4)
            bindTextOrNull(pathsJSON, to: statement, at: 5)
            bindTextOrNull(issue.reason, to: statement, at: 6)
            try stepDone(statement, db: db)
        }
    }

    private func insertSuggestion(
        _ suggestion: ScanSnapshot.Suggestion,
        albumID: String,
        db: OpaquePointer
    ) throws {
        try withStatement(
            db,
            "INSERT INTO album_name_suggestions (album_id, artist_name, album_name) VALUES (?, ?, ?)"
        ) { statement in
            bindText(albumID, to: statement, at: 1)
            bindText(suggestion.artistName, to: statement, at: 2)
            bindText(suggestion.albumName, to: statement, at: 3)
            try stepDone(statement, db: db)
        }
    }

    private func insertStatus(_ status: ScanSnapshot.Status, db: OpaquePointer) throws {
        try withStatement(
            db,
            "INSERT INTO album_name_status (id, is_running, last_error_message) VALUES (1, ?, ?)"
        ) { statement in
            bindInt(status.isRunning ? 1 : 0, to: statement, at: 1)
            bindTextOrNull(status.lastErrorMessage, to: statement, at: 2)
            try stepDone(statement, db: db)
        }
    }

    private func sqliteSummary(at fileURL: URL, expectedLibrary: LibraryRecord) throws -> ScanSnapshotSummary {
        let db = try openExistingSQLite(at: fileURL)
        defer { sqlite3_close(db) }
        let header = try loadHeader(db: db, expectedLibrary: expectedLibrary)
        return ScanSnapshotSummary(
            fileURL: fileURL.resolvingSymlinksInPath(),
            schemaVersion: header.schemaVersion,
            createdAt: header.createdAt,
            libraryDisplayName: header.library.displayName,
            libraryRootPath: header.library.rootPath,
            libraryRole: header.library.role,
            albumCount: try albumCount(db: db)
        )
    }

    private func loadSQLiteSnapshot(
        at fileURL: URL,
        expectedLibrary: LibraryRecord,
        progress: (@Sendable (ScanSnapshotLoadProgress) async -> Void)?
    ) async throws -> ScanSnapshot {
        let db = try openExistingSQLite(at: fileURL)
        defer { sqlite3_close(db) }
        let header = try loadHeader(db: db, expectedLibrary: expectedLibrary)
        let totalAlbums = try albumCount(db: db)
        let looseAudioPaths = try decodeJSON([String].self, from: header.looseAudioPathsJSON)

        var albums: [ScanSnapshot.Album] = []
        albums.reserveCapacity(totalAlbums)
        var offset = 0
        while offset < totalAlbums {
            let batch = try loadAlbumBatch(db: db, limit: 100, offset: offset)
            albums.append(contentsOf: batch)
            offset += batch.count
            if let progress {
                let completed = min(offset, totalAlbums)
                await progress(
                    ScanSnapshotLoadProgress(
                        phase: .converting,
                        completedAlbums: completed,
                        totalAlbums: totalAlbums
                    )
                )
            }
        }

        let enhancement = try loadAlbumNameEnhancement(db: db)
        return ScanSnapshot(
            schemaVersion: header.schemaVersion,
            createdAt: header.createdAt,
            library: header.library,
            scanResult: ScanSnapshot.Result(
                albums: albums,
                looseAudioPaths: looseAudioPaths
            ),
            albumNameEnhancement: enhancement
        )
    }

    private struct Header {
        let schemaVersion: Int
        let createdAt: Date
        let library: ScanSnapshot.Library
        let looseAudioPathsJSON: String
    }

    private func loadHeader(db: OpaquePointer, expectedLibrary: LibraryRecord) throws -> Header {
        guard tableExists("snapshots", db: db) else {
            throw SQLiteScanSnapshotStoreError.notSQLiteSnapshot
        }

        return try withStatement(
            db,
            """
            SELECT schema_version, created_at, library_id, library_display_name,
                   library_root_path, library_role, loose_audio_paths_json
            FROM snapshots WHERE id = 1
            """
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw SQLiteScanSnapshotStoreError.notSQLiteSnapshot
            }

            let schemaVersion = sqlite3_column_int(statement, 0)
            guard FileScanSnapshotStore.isSupportedSchemaVersion(Int(schemaVersion)) else {
                throw SQLiteScanSnapshotStoreError.unsupportedSchemaVersion(
                    actual: Int(schemaVersion),
                    supported: ScanSnapshot.currentSchemaVersion
                )
            }

            let createdAtString = columnText(statement, 1) ?? ""
            guard let createdAt = iso8601Date(from: createdAtString) else {
                throw SQLiteScanSnapshotStoreError.invalidDate(createdAtString)
            }

            guard let libraryID = UUID(uuidString: columnText(statement, 2) ?? ""),
                  let role = LibraryRole(rawValue: columnText(statement, 5) ?? "") else {
                throw SQLiteScanSnapshotStoreError.invalidHeader
            }

            let libraryRootPath = columnText(statement, 4) ?? ""
            let expectedRootPath = FileScanSnapshotStore.normalizedPath(expectedLibrary.rootPath)
            guard FileScanSnapshotStore.normalizedPath(libraryRootPath) == expectedRootPath else {
                throw SQLiteScanSnapshotStoreError.libraryRootMismatch(
                    expected: expectedRootPath,
                    actual: libraryRootPath
                )
            }
            guard role == expectedLibrary.role else {
                throw SQLiteScanSnapshotStoreError.libraryRoleMismatch(
                    expected: expectedLibrary.role.displayName,
                    actual: role.displayName
                )
            }

            return Header(
                schemaVersion: Int(schemaVersion),
                createdAt: createdAt,
                library: ScanSnapshot.Library(
                    id: libraryID,
                    displayName: columnText(statement, 3) ?? "",
                    rootPath: libraryRootPath,
                    role: role
                ),
                looseAudioPathsJSON: columnText(statement, 6) ?? "[]"
            )
        }
    }

    private func albumCount(db: OpaquePointer) throws -> Int {
        try withStatement(db, "SELECT COUNT(*) FROM albums") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw SQLiteScanSnapshotStoreError.queryFailed(sqliteError(db))
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func loadAlbumBatch(db: OpaquePointer, limit: Int, offset: Int) throws -> [ScanSnapshot.Album] {
        try withStatement(
            db,
            """
            SELECT id, folder_path, artist_name, album_name, cover_path,
                   cover_preview_path, cover_relative_path, cover_name_priority,
                   cover_depth, cover_source
            FROM albums ORDER BY ordinal LIMIT ? OFFSET ?
            """
        ) { statement in
            bindInt(limit, to: statement, at: 1)
            bindInt(offset, to: statement, at: 2)
            var albums: [ScanSnapshot.Album] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let albumID = columnText(statement, 0) ?? ""
                let coverSource = columnText(statement, 9).flatMap(ScanSnapshot.Source.init(rawValue:))
                let cover: ScanSnapshot.Cover?
                if let coverPath = columnText(statement, 4),
                   let coverRelativePath = columnText(statement, 6),
                   let coverSource {
                    cover = ScanSnapshot.Cover(
                        path: coverPath,
                        previewPath: columnText(statement, 5),
                        relativePath: coverRelativePath,
                        namePriority: Int(sqlite3_column_int(statement, 7)),
                        depth: Int(sqlite3_column_int(statement, 8)),
                        source: coverSource
                    )
                } else {
                    cover = nil
                }
                albums.append(ScanSnapshot.Album(
                    folderPath: columnText(statement, 1) ?? "",
                    artistName: columnText(statement, 2) ?? "",
                    albumName: columnText(statement, 3) ?? "",
                    audioFiles: try loadAudioFiles(albumID: albumID, db: db),
                    cueSheets: try loadCueSheets(albumID: albumID, db: db),
                    displayedCover: cover,
                    issues: try loadIssues(albumID: albumID, db: db)
                ))
            }
            return albums
        }
    }

    private func loadAudioFiles(albumID: String, db: OpaquePointer) throws -> [ScanSnapshot.AudioFile] {
        try withStatement(
            db,
            """
            SELECT path, relative_path, format, title, artist, album_artist, album,
                   disc_number, track_number, duration_seconds, embedded_artwork_path,
                   read_error
            FROM audio_files WHERE album_id = ? ORDER BY ordinal
            """
        ) { statement in
            bindText(albumID, to: statement, at: 1)
            var audioFiles: [ScanSnapshot.AudioFile] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let metadata: ScanSnapshot.Metadata?
                if hasMetadata(statement) {
                    metadata = ScanSnapshot.Metadata(
                        title: columnText(statement, 3),
                        artist: columnText(statement, 4),
                        albumArtist: columnText(statement, 5),
                        album: columnText(statement, 6),
                        discNumber: columnIntOrNil(statement, 7),
                        trackNumber: columnIntOrNil(statement, 8),
                        durationSeconds: columnIntOrNil(statement, 9),
                        embeddedArtworkPath: columnText(statement, 10)
                    )
                } else {
                    metadata = nil
                }
                audioFiles.append(ScanSnapshot.AudioFile(
                    path: columnText(statement, 0) ?? "",
                    relativePath: columnText(statement, 1) ?? "",
                    format: columnText(statement, 2) ?? "",
                    metadata: metadata,
                    readError: columnText(statement, 11)
                ))
            }
            return audioFiles
        }
    }

    private func loadCueSheets(albumID: String, db: OpaquePointer) throws -> [ScanSnapshot.CueSheet] {
        guard tableExists("album_cue_sheets", db: db) else { return [] }
        return try withStatement(
            db,
            """
            SELECT path, relative_path
            FROM album_cue_sheets WHERE album_id = ? ORDER BY ordinal
            """
        ) { statement in
            bindText(albumID, to: statement, at: 1)
            var cueSheets: [ScanSnapshot.CueSheet] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                cueSheets.append(ScanSnapshot.CueSheet(
                    path: columnText(statement, 0) ?? "",
                    relativePath: columnText(statement, 1) ?? ""
                ))
            }
            return cueSheets
        }
    }

    private func loadIssues(albumID: String, db: OpaquePointer) throws -> [ScanSnapshot.Issue] {
        try withStatement(
            db,
            "SELECT kind, has_cue, paths_json, reason FROM album_issues WHERE album_id = ? ORDER BY ordinal"
        ) { statement in
            bindText(albumID, to: statement, at: 1)
            var issues: [ScanSnapshot.Issue] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let kind = ScanSnapshot.Issue.Kind(rawValue: columnText(statement, 0) ?? "") else {
                    throw SQLiteScanSnapshotStoreError.invalidIssueKind(columnText(statement, 0) ?? "")
                }
                let paths = try columnText(statement, 2).map { try decodeJSON([String].self, from: $0) }
                issues.append(ScanSnapshot.Issue(
                    kind: kind,
                    hasCue: columnIntOrNil(statement, 1).map { $0 != 0 },
                    paths: paths ?? nil,
                    reason: columnText(statement, 3)
                ))
            }
            return issues
        }
    }

    private func loadAlbumNameEnhancement(db: OpaquePointer) throws -> ScanSnapshot.AlbumNameEnhancement? {
        var suggestions: [String: ScanSnapshot.Suggestion] = [:]
        try withStatement(db, "SELECT album_id, artist_name, album_name FROM album_name_suggestions") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                suggestions[columnText(statement, 0) ?? ""] = ScanSnapshot.Suggestion(
                    artistName: columnText(statement, 1) ?? "",
                    albumName: columnText(statement, 2) ?? ""
                )
            }
        }

        let status = try withStatement(db, "SELECT is_running, last_error_message FROM album_name_status WHERE id = 1") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil as ScanSnapshot.Status? }
            return ScanSnapshot.Status(
                isRunning: sqlite3_column_int(statement, 0) != 0,
                lastErrorMessage: columnText(statement, 1)
            )
        }

        guard !suggestions.isEmpty || status != nil else { return nil }
        return ScanSnapshot.AlbumNameEnhancement(
            suggestionsByAlbumPath: suggestions,
            status: status
        )
    }

    private func legacyJSONSummary(at fileURL: URL, expectedLibrary: LibraryRecord) throws -> ScanSnapshotSummary? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let snapshot = try legacyJSONSnapshot(at: fileURL, expectedLibrary: expectedLibrary)
        return summary(for: snapshot, fileURL: fileURL)
    }

    private func legacyJSONSnapshot(at fileURL: URL, expectedLibrary: LibraryRecord) throws -> ScanSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ScanSnapshot.self, from: Data(contentsOf: fileURL))
        guard FileScanSnapshotStore.isSupportedSchemaVersion(snapshot.schemaVersion) else {
            throw SQLiteScanSnapshotStoreError.unsupportedSchemaVersion(
                actual: snapshot.schemaVersion,
                supported: ScanSnapshot.currentSchemaVersion
            )
        }
        let expectedRootPath = FileScanSnapshotStore.normalizedPath(expectedLibrary.rootPath)
        guard FileScanSnapshotStore.normalizedPath(snapshot.library.rootPath) == expectedRootPath else {
            throw SQLiteScanSnapshotStoreError.libraryRootMismatch(
                expected: expectedRootPath,
                actual: snapshot.library.rootPath
            )
        }
        guard snapshot.library.role == expectedLibrary.role else {
            throw SQLiteScanSnapshotStoreError.libraryRoleMismatch(
                expected: expectedLibrary.role.displayName,
                actual: snapshot.library.role.displayName
            )
        }
        return snapshot
    }

    private func summary(for snapshot: ScanSnapshot, fileURL: URL) -> ScanSnapshotSummary {
        ScanSnapshotSummary(
            fileURL: fileURL.resolvingSymlinksInPath(),
            schemaVersion: snapshot.schemaVersion,
            createdAt: snapshot.createdAt,
            libraryDisplayName: snapshot.library.displayName,
            libraryRootPath: snapshot.library.rootPath,
            libraryRole: snapshot.library.role,
            albumCount: snapshot.scanResult.albums.count
        )
    }

    private func openExistingSQLite(at fileURL: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let openedDB = db else {
            sqlite3_close(db)
            throw SQLiteScanSnapshotStoreError.notSQLiteSnapshot
        }
        guard tableExists("snapshots", db: openedDB) else {
            sqlite3_close(openedDB)
            throw SQLiteScanSnapshotStoreError.notSQLiteSnapshot
        }
        return openedDB
    }

    private func tableExists(_ tableName: String, db: OpaquePointer) -> Bool {
        (try? withStatement(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
        ) { statement in
            bindText(tableName, to: statement, at: 1)
            return sqlite3_step(statement) == SQLITE_ROW
        }) ?? false
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw SQLiteScanSnapshotStoreError.queryFailed(sqliteError(db))
        }
    }

    private func withStatement<T>(
        _ db: OpaquePointer,
        _ sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteScanSnapshotStoreError.queryFailed(sqliteError(db))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer, db: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteScanSnapshotStoreError.queryFailed(sqliteError(db))
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindTextOrNull(_ value: String?, to statement: OpaquePointer, at index: Int32) {
        if let value {
            bindText(value, to: statement, at: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindInt(_ value: Int, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    }

    private func bindIntOrNull(_ value: Int?, to statement: OpaquePointer, at index: Int32) {
        if let value {
            bindInt(value, to: statement, at: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func columnIntOrNil(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, index))
    }

    private func hasMetadata(_ statement: OpaquePointer) -> Bool {
        (3...10).contains { sqlite3_column_type(statement, Int32($0)) != SQLITE_NULL }
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(string.utf8))
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func iso8601Date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    private func sqliteError(_ db: OpaquePointer?) -> String {
        guard let db, let message = sqlite3_errmsg(db) else { return "未知 SQLite 错误" }
        return String(cString: message)
    }

}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteScanSnapshotStoreError: LocalizedError, Sendable {
    case notSQLiteSnapshot
    case openFailed(String)
    case queryFailed(String)
    case outsideSnapshotDirectory(String)
    case unsupportedSchemaVersion(actual: Int, supported: Int)
    case libraryRootMismatch(expected: String, actual: String)
    case libraryRoleMismatch(expected: String, actual: String)
    case invalidDate(String)
    case invalidHeader
    case invalidIssueKind(String)

    var errorDescription: String? {
        switch self {
        case .notSQLiteSnapshot:
            "不是 SQLite 扫描快照。"
        case .openFailed(let message):
            "无法打开 SQLite 扫描快照：\(message)"
        case .queryFailed(let message):
            "SQLite 扫描快照查询失败：\(message)"
        case .outsideSnapshotDirectory(let path):
            "扫描快照路径不在允许目录内：\(path)"
        case .unsupportedSchemaVersion(let actual, let supported):
            "扫描快照版本不兼容：\(actual)，当前支持：\(supported)"
        case .libraryRootMismatch(let expected, let actual):
            "扫描快照目录不匹配，期望 \(expected)，实际 \(actual)"
        case .libraryRoleMismatch(let expected, let actual):
            "扫描快照目录角色不匹配，期望 \(expected)，实际 \(actual)"
        case .invalidDate(let value):
            "扫描快照日期无效：\(value)"
        case .invalidHeader:
            "扫描快照头信息无效。"
        case .invalidIssueKind(let kind):
            "扫描快照异常类型无效：\(kind)"
        }
    }
}
