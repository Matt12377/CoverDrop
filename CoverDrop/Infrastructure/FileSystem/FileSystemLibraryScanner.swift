import Foundation
import OSLog

struct FileSystemLibraryScanner: LibraryScanning, AlbumRescanning {
    nonisolated private static let logger = Logger(subsystem: "com.yihe.CoverDrop", category: "音乐库扫描")

    private let metadataReader: any AudioMetadataReading
    private let coverDetector: any CoverDetecting
    private let maxConcurrentAlbums: Int

    init(
        metadataReader: any AudioMetadataReading,
        coverDetector: any CoverDetecting,
        maxConcurrentAlbums: Int
    ) {
        self.metadataReader = metadataReader
        self.coverDetector = coverDetector
        self.maxConcurrentAlbums = Swift.max(1, maxConcurrentAlbums)
    }

    nonisolated func scan(
        libraryURL: URL,
        role: LibraryRole,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> LibraryScanResult {
        let startedAt = Date()
        Self.logger.notice(
            "[扫描][开始] 角色=\(role.displayName, privacy: .public) 路径=\(libraryURL.path, privacy: .public)"
        )
        await progress(LibraryScanProgress(
            phase: .discoveringAlbums,
            targetPath: libraryURL.path,
            completedAlbums: 0,
            totalAlbums: nil,
            completedFilesInAlbum: nil,
            totalFilesInAlbum: nil
        ))

        do {
            let discoveryStartedAt = Date()
            let maxConcurrentAlbums = maxConcurrentAlbums
            let boundaries = try await Task.detached(priority: .userInitiated) {
                try await Self.discoverBoundaries(
                    root: libraryURL,
                    role: role,
                    maxConcurrentArtistDiscovery: maxConcurrentAlbums
                )
            }.value
            Self.logger.notice(
                "[扫描][目录分析完成] 专辑=\(boundaries.albums.count) 散落音频=\(boundaries.looseAudioPaths.count) 耗时=\(Self.formatDuration(since: discoveryStartedAt), privacy: .public)"
            )
            Self.logger.notice(
                "[扫描][并发] 专辑并发上限=\(Swift.min(maxConcurrentAlbums, boundaries.albums.count))"
            )

            let albums = try await scanAlbumsConcurrently(
                boundaries.albums,
                progress: progress
            )

            await progress(LibraryScanProgress(
                phase: .finishing,
                targetPath: libraryURL.path,
                completedAlbums: boundaries.albums.count,
                totalAlbums: boundaries.albums.count,
                completedFilesInAlbum: nil,
                totalFilesInAlbum: nil
            ))

            let result = LibraryScanResult(
                albums: albums.sorted {
                    if $0.artistName != $1.artistName {
                        return $0.artistName.localizedStandardCompare($1.artistName) == .orderedAscending
                    }
                    return $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending
                },
                looseAudioPaths: boundaries.looseAudioPaths.sorted()
            )
            let elapsedSeconds = Int(Date().timeIntervalSince(startedAt).rounded())
            Self.logger.notice(
                "[扫描][完成] 专辑=\(result.albums.count) 已有封面=\(result.albumsWithCover) 需要确认=\(result.albumsNeedingAttention) 耗时=\(elapsedSeconds)秒"
            )
            return result
        } catch {
            Self.logger.error("[扫描][失败] \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    nonisolated func rescanAlbum(
        _ album: AlbumScanRecord,
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> AlbumScanRecord {
        await progress(LibraryScanProgress(
            phase: .readingMetadata,
            targetPath: album.folderURL.path,
            completedAlbums: 0,
            totalAlbums: 1,
            completedFilesInAlbum: nil,
            totalFilesInAlbum: nil
        ))
        let progressReporter = ScanProgressReporter(totalAlbums: 1, progress: progress)
        let boundary = AlbumBoundary(
            folderURL: album.folderURL,
            artistName: album.artistName,
            albumName: album.albumName,
            issues: Self.boundaryIssuesRetainedDuringAlbumRescan(from: album)
        )
        let rescanned = try await scanAlbum(
            boundary,
            albumNumber: 1,
            totalAlbums: 1,
            progressReporter: progressReporter
        )
        await progressReporter.flush()
        return rescanned
    }

    nonisolated private func scanAlbumsConcurrently(
        _ boundaries: [AlbumBoundary],
        progress: @escaping LibraryScanProgressHandler
    ) async throws -> [AlbumScanRecord] {
        let progressReporter = ScanProgressReporter(
            totalAlbums: boundaries.count,
            progress: progress
        )
        let concurrentLimit = Swift.min(maxConcurrentAlbums, boundaries.count)
        var albums: [AlbumScanRecord] = []
        albums.reserveCapacity(boundaries.count)

        try await withThrowingTaskGroup(of: AlbumScanRecord.self) { group in
            var nextIndex = 0

            while nextIndex < concurrentLimit {
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    try await scanAlbum(
                        boundaries[index],
                        albumNumber: index + 1,
                        totalAlbums: boundaries.count,
                        progressReporter: progressReporter
                    )
                }
            }

            while let album = try await group.next() {
                albums.append(album)

                if nextIndex < boundaries.count {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask {
                        try await scanAlbum(
                            boundaries[index],
                            albumNumber: index + 1,
                            totalAlbums: boundaries.count,
                            progressReporter: progressReporter
                        )
                    }
                }
            }
        }

        await progressReporter.flush()

        return albums
    }

    nonisolated private func scanAlbum(
        _ boundary: AlbumBoundary,
        albumNumber: Int,
        totalAlbums: Int,
        progressReporter: ScanProgressReporter
    ) async throws -> AlbumScanRecord {
        let albumStartedAt = Date()
        let audioURLs = boundary.audioFileURLs ?? Self.recursiveAudioFiles(in: boundary.folderURL)
        let cueSheets = Self.recursiveCueSheets(in: boundary.folderURL).map { cueURL in
            CueSheetRecord(
                url: cueURL,
                relativePath: Self.relativePath(of: cueURL, under: boundary.folderURL)
            )
        }
        Self.logger.info(
            "[扫描][专辑 \(albumNumber)/\(totalAlbums)] \(boundary.artistName, privacy: .public) / \(boundary.albumName, privacy: .public) 音频=\(audioURLs.count)"
        )
        var audioFiles: [AudioFileRecord] = []
        var failedPaths: [String] = []

        await progressReporter.report(
            phase: .detectingCover,
            targetPath: boundary.folderURL.path,
            completedFilesInAlbum: nil,
            totalFilesInAlbum: audioURLs.count
        )
        Self.logger.debug("[扫描][封面] \(boundary.folderURL.path, privacy: .public)")
        let coverStartedAt = Date()
        let coverResult = try await coverDetector.detectCover(in: boundary.folderURL)
        let coverElapsed = Self.formatDuration(since: coverStartedAt)
        let shouldReadEmbeddedArtwork = coverResult.selected.isNil

        let metadataStartedAt = Date()
        for (fileIndex, audioURL) in audioURLs.enumerated() {
            await progressReporter.report(
                phase: .readingMetadata,
                targetPath: audioURL.path,
                completedFilesInAlbum: fileIndex,
                totalFilesInAlbum: audioURLs.count
            )
            Self.logger.debug(
                "[扫描][标签 \(fileIndex + 1)/\(audioURLs.count)] \(audioURL.path, privacy: .public)"
            )
            let relativePath = Self.relativePath(of: audioURL, under: boundary.folderURL)
            do {
                let metadata = try await metadataReader.readMetadata(
                    at: audioURL,
                    includingEmbeddedArtwork: shouldReadEmbeddedArtwork
                )
                audioFiles.append(AudioFileRecord(
                    url: audioURL,
                    relativePath: relativePath,
                    format: audioURL.pathExtension.uppercased(),
                    metadata: metadata,
                    readError: nil
                ))
            } catch {
                Self.logger.error(
                    "[扫描][标签失败] \(audioURL.path, privacy: .public) 原因=\(error.localizedDescription, privacy: .public)"
                )
                failedPaths.append(relativePath)
                audioFiles.append(AudioFileRecord(
                    url: audioURL,
                    relativePath: relativePath,
                    format: audioURL.pathExtension.uppercased(),
                    metadata: nil,
                    readError: error.localizedDescription
                ))
            }
        }
        let metadataElapsed = Self.formatDuration(since: metadataStartedAt)

        let embeddedArtworkCover = coverResult.selected.isNil
            ? Self.firstEmbeddedArtworkCover(in: audioFiles)
            : nil
        let displayedCover = coverResult.selected ?? embeddedArtworkCover

        if let selected = coverResult.selected {
            Self.logger.info("[扫描][封面命中] \(selected.url.path, privacy: .public)")
        } else if let embeddedArtworkCover {
            Self.logger.info("[扫描][封面命中-内嵌] \(embeddedArtworkCover.relativePath, privacy: .public)")
        } else {
            Self.logger.info("[扫描][未找到封面] \(boundary.folderURL.path, privacy: .public)")
        }
        var issues = boundary.issues
        if audioURLs.count == 1 {
            issues.append(.singleFileNeedsConfirmation(
                hasCue: !cueSheets.isEmpty
            ))
        }
        if !failedPaths.isEmpty {
            issues.append(.metadataReadFailed(paths: failedPaths))
        }
        let trackNamedPaths = audioFiles.compactMap { audioFile -> String? in
            Self.isTrackNamedAudioFile(relativePath: audioFile.relativePath) ? audioFile.relativePath : nil
        }
        if !trackNamedPaths.isEmpty {
            issues.append(.trackNamedAudioFiles(paths: trackNamedPaths))
        }
        if coverResult.selected.isNil, !coverResult.invalidNamedPaths.isEmpty {
            issues.append(.invalidNamedCovers(paths: coverResult.invalidNamedPaths))
        }

        let record = AlbumScanRecord(
            folderURL: boundary.folderURL,
            artistName: boundary.artistName,
            albumName: boundary.albumName,
            audioFiles: audioFiles.sorted(by: Self.audioSort),
            cueSheets: cueSheets,
            displayedCover: displayedCover,
            issues: issues
        )
        let completedAlbums = await progressReporter.albumCompleted()
        Self.logger.info(
            "[扫描][专辑完成 \(completedAlbums)/\(totalAlbums)] \(boundary.folderURL.path, privacy: .public) 标签耗时=\(metadataElapsed, privacy: .public) 封面耗时=\(coverElapsed, privacy: .public) 总耗时=\(Self.formatDuration(since: albumStartedAt), privacy: .public)"
        )
        return record
    }

    nonisolated private static func discoverBoundaries(
        root: URL,
        role: LibraryRole,
        maxConcurrentArtistDiscovery: Int
    ) async throws -> DiscoveredBoundaries {
        switch role {
        case .album:
            let audioFileURLs = recursiveAudioFiles(in: root)
            guard !audioFileURLs.isEmpty else {
                throw LibraryScanError.noAlbumsFound
            }
            return DiscoveredBoundaries(
                albums: [AlbumBoundary(
                    folderURL: root,
                    artistName: root.deletingLastPathComponent().lastPathComponent,
                    albumName: root.lastPathComponent,
                    audioFileURLs: audioFileURLs
                )],
                looseAudioPaths: []
            )

        case .artist:
            let discovered = try discoverArtistRoot(
                root,
                artistName: artistName(forArtistRoot: root, fallback: root.lastPathComponent)
            )
            guard !discovered.albums.isEmpty else { throw LibraryScanError.noAlbumsFound }
            return discovered

        case .library:
            var albums: [AlbumBoundary] = []
            var loose: [String] = directAudioFiles(in: root).map { relativePath(of: $0, under: root) }
            let artistURLs = try childDirectories(of: root)
            let artistResults = try await discoverArtistRootsConcurrently(
                artistURLs,
                maxConcurrentArtistDiscovery: maxConcurrentArtistDiscovery
            )

            for artistResult in artistResults.sorted(by: {
                $0.artistURL.path.localizedStandardCompare($1.artistURL.path) == .orderedAscending
            }) {
                let artistURL = artistResult.artistURL
                let discovered = artistResult.discovered
                albums.append(contentsOf: discovered.albums)
                loose.append(contentsOf: discovered.looseAudioPaths.map {
                    artistURL.lastPathComponent + "/" + $0
                })
            }

            guard !albums.isEmpty else { throw LibraryScanError.noAlbumsFound }
            return DiscoveredBoundaries(albums: albums, looseAudioPaths: loose)
        }
    }

    nonisolated private static func discoverArtistRootsConcurrently(
        _ artistURLs: [URL],
        maxConcurrentArtistDiscovery: Int
    ) async throws -> [ArtistDiscoveryResult] {
        guard !artistURLs.isEmpty else { return [] }

        let concurrentLimit = Swift.min(
            Swift.max(1, maxConcurrentArtistDiscovery),
            artistURLs.count
        )
        var results: [ArtistDiscoveryResult] = []
        results.reserveCapacity(artistURLs.count)

        try await withThrowingTaskGroup(of: ArtistDiscoveryResult.self) { group in
            var nextIndex = 0

            while nextIndex < concurrentLimit {
                let artistURL = artistURLs[nextIndex]
                nextIndex += 1
                group.addTask {
                    ArtistDiscoveryResult(
                        artistURL: artistURL,
                        discovered: try discoverArtistRoot(
                            artistURL,
                            artistName: artistName(
                                forArtistRoot: artistURL,
                                fallback: artistURL.lastPathComponent
                            )
                        )
                    )
                }
            }

            while let result = try await group.next() {
                results.append(result)

                if nextIndex < artistURLs.count {
                    let artistURL = artistURLs[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        ArtistDiscoveryResult(
                            artistURL: artistURL,
                            discovered: try discoverArtistRoot(
                                artistURL,
                                artistName: artistName(
                                    forArtistRoot: artistURL,
                                    fallback: artistURL.lastPathComponent
                                )
                            )
                        )
                    }
                }
            }
        }

        return results
    }

    nonisolated private static func discoverArtistRoot(
        _ root: URL,
        artistName: String
    ) throws -> DiscoveredBoundaries {
        let audioDirectories = try directAudioDirectories(in: root).filter {
            !isSameFileURL($0.url, root)
        }
        var albumsByPath: [String: AlbumBoundary] = [:]

        for audioDirectory in audioDirectories {
            let albumRoot = try albumRoot(
                forAudioDirectory: audioDirectory.url,
                artistRoot: root
            )
            guard !isSameFileURL(albumRoot, root) else { continue }

            let key = canonicalPath(albumRoot)
            if let existing = albumsByPath[key] {
                albumsByPath[key] = existing.appendingAudioFileURLs(audioDirectory.audioFileURLs)
            } else {
                albumsByPath[key] = AlbumBoundary(
                    folderURL: albumRoot,
                    artistName: artistName,
                    albumName: albumRoot.lastPathComponent,
                    issues: boundaryIssues(forAlbumRoot: albumRoot, artistRoot: root),
                    audioFileURLs: audioDirectory.audioFileURLs
                )
            }
        }

        let albums = albumsByPath.values.sorted {
            $0.folderURL.path.localizedStandardCompare($1.folderURL.path) == .orderedAscending
        }
        let loose = directAudioFiles(in: root).map { relativePath(of: $0, under: root) }
        return DiscoveredBoundaries(albums: albums, looseAudioPaths: loose)
    }

    nonisolated private static func artistName(forArtistRoot root: URL, fallback: String) -> String {
        let folderName = root.lastPathComponent
        if isGenericAlbumContainerName(folderName) {
            return root.deletingLastPathComponent().lastPathComponent
        }
        return sanitizedArtistName(fromFolderName: fallback)
    }

    nonisolated private static func sanitizedArtistName(fromFolderName name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(
            of: #"\s+\d+\s*[张張](?:\[[^\]]+\])?\s*$"#,
            with: "",
            options: .regularExpression
        )
        return cleaned.isEmpty ? trimmed : cleaned
    }

    nonisolated private static func isGenericAlbumContainerName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        return ["album", "albums", "专辑", "專輯"].contains(normalized)
    }

    nonisolated private static func isCollectionContainerName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        if normalized.contains("合集")
            || normalized.contains("合辑")
            || normalized.contains("全集")
            || normalized.contains("套装")
            || normalized.contains("汇总")
            || normalized.contains("彙總")
            || normalized.contains("collection") {
            return true
        }

        return normalized.range(of: #"\d+张"#, options: .regularExpression) != nil
            || normalized.range(of: #"\d+張"#, options: .regularExpression) != nil
    }

    nonisolated private static func directAudioDirectories(in root: URL) throws -> [DirectAudioDirectory] {
        var directories: [DirectAudioDirectory] = []

        func collect(from directory: URL) throws {
            let audioFileURLs = directAudioFiles(in: directory)
            if !audioFileURLs.isEmpty {
                directories.append(DirectAudioDirectory(
                    url: directory,
                    audioFileURLs: audioFileURLs
                ))
            }
            for child in try childDirectories(of: directory) {
                try collect(from: child)
            }
        }

        try collect(from: root)
        return directories.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    nonisolated private static func albumRoot(
        forAudioDirectory audioDirectory: URL,
        artistRoot: URL
    ) throws -> URL {
        let parent = audioDirectory.deletingLastPathComponent()

        if isSameFileURL(parent, artistRoot) {
            return audioDirectory
        }

        if isStructuralLayer(audioDirectory.lastPathComponent)
            || isTrackFolderLayer(audioDirectory, parent: parent) {
            return parent
        }

        if isPlainNumberedDiscLayer(audioDirectory, parent: parent, artistRoot: artistRoot) {
            return parent
        }

        return audioDirectory
    }

    nonisolated private static func boundaryIssues(
        forAlbumRoot albumRoot: URL,
        artistRoot: URL
    ) -> [AlbumScanIssue] {
        guard !isSameFileURL(albumRoot.deletingLastPathComponent(), artistRoot),
              isVersionLayerName(albumRoot.lastPathComponent),
              let siblingVersionCount = try? versionSiblingCount(around: albumRoot),
              siblingVersionCount >= 2 else {
            return []
        }

        return [.uncertainAlbumBoundary(
            reason: "同一专辑目录下存在多个版本目录，请确认是否应合并"
        )]
    }

    nonisolated private static func boundaryIssuesRetainedDuringAlbumRescan(
        from album: AlbumScanRecord
    ) -> [AlbumScanIssue] {
        album.issues.compactMap { issue in
            if case .uncertainAlbumBoundary = issue {
                return issue
            }
            return nil
        }
    }

    nonisolated private static func versionSiblingCount(around directory: URL) throws -> Int {
        let parent = directory.deletingLastPathComponent()
        return try childDirectories(of: parent).filter { sibling in
            isVersionLayerName(sibling.lastPathComponent)
                && !directAudioFiles(in: sibling).isEmpty
        }.count
    }

    nonisolated private static func isStructuralLayer(_ name: String) -> Bool {
        isDiscLayerName(name) || isFormatLayerName(name)
    }

    nonisolated private static func isPlainNumberedDiscLayer(
        _ directory: URL,
        parent: URL,
        artistRoot: URL
    ) -> Bool {
        guard !isSameFileURL(parent, artistRoot),
              isPlainNumberedDiscName(directory.lastPathComponent) else {
            return false
        }

        guard let numberedSiblings = try? childDirectories(of: parent).filter({
            !directAudioFiles(in: $0).isEmpty && isPlainNumberedDiscName($0.lastPathComponent)
        }),
              numberedSiblings.count >= 2 else {
            return false
        }

        return numberedSiblings.contains(where: { isSameFileURL($0, directory) })
    }

    nonisolated private static func isPlainNumberedDiscName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2).contains(trimmed.count),
              let value = Int(trimmed),
              value > 0 else {
            return false
        }
        return trimmed.allSatisfy(\.isNumber)
    }

    nonisolated private static func isDiscLayerName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        let prefixes = ["cd", "disc", "disk", "d", "碟", "盘", "盤"]
        return prefixes.contains { prefix in
            guard normalized.hasPrefix(prefix) else { return false }
            let suffix = normalized.dropFirst(prefix.count)
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
    }

    nonisolated private static func isFormatLayerName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        if [
            "wav", "wave", "flac", "ape", "dsd", "dff", "dsf", "sacd",
            "hires", "hirez", "highres", "lossless"
        ].contains(normalized) {
            return true
        }

        return normalized.hasPrefix("wav")
            || normalized.hasPrefix("flac")
            || normalized.hasPrefix("ape")
            || normalized.hasPrefix("dsd")
            || normalized.hasPrefix("dff")
            || normalized.hasPrefix("dsf")
    }

    nonisolated private static func isTrackFolderLayer(_ directory: URL, parent: URL) -> Bool {
        guard directAudioFiles(in: directory).count <= 1,
              let siblings = try? childDirectories(of: parent).filter({
                  !directAudioFiles(in: $0).isEmpty
              }),
              siblings.count >= 2 else {
            return false
        }

        return siblings.allSatisfy { sibling in
            directAudioFiles(in: sibling).count <= 1
                && isTrackFolderName(sibling.lastPathComponent)
        }
    }

    nonisolated private static func isTrackFolderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first,
              CharacterSet.decimalDigits.contains(first) else {
            return false
        }

        let digitPrefix = trimmed.prefix { character in
            character.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
        }
        guard (1...3).contains(digitPrefix.count) else { return false }
        guard trimmed.count > digitPrefix.count else { return true }

        let separatorIndex = trimmed.index(trimmed.startIndex, offsetBy: digitPrefix.count)
        let separator = trimmed[separatorIndex]
        return separator == " "
            || separator == "."
            || separator == "-"
            || separator == "_"
            || separator == "、"
    }

    nonisolated private static func isVersionLayerName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        return normalized.contains("版")
            || normalized.contains("version")
            || normalized.contains("edition")
            || normalized.contains("press")
    }

    nonisolated private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated private static func isSameFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    nonisolated private static func childDirectories(of root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    nonisolated private static func directAudioFiles(in root: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.filter(isAudioFile)
    }

    nonisolated private static func recursiveAudioFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            if isAudioFile(url) { files.append(url) }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    nonisolated private static func isAudioFile(_ url: URL) -> Bool {
        guard audioExtensions.contains(url.pathExtension.lowercased()),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return false
        }

        return true
    }

    nonisolated private static var audioExtensions: Set<String> {
        [
            "mp3", "flac", "ape", "wav", "wave", "aif", "aiff", "aifc",
            "m4a", "mp4", "ogg", "oga", "opus", "wv", "mpc", "mpp",
            "wma", "asf", "tta", "dsf", "dff"
        ]
    }

    nonisolated private static func recursiveCueSheets(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "cue",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            files.append(url)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    nonisolated private static func isTrackNamedAudioFile(relativePath: String) -> Bool {
        let fileStem = URL(fileURLWithPath: relativePath)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard fileStem.contains("track") else { return false }

        return fileStem.range(
            of: #"^track(?:[\s._-]*\d+)?(?:[\s._-].*)?$"#,
            options: .regularExpression
        ) != nil
    }

    nonisolated private static func relativePath(of url: URL, under root: URL) -> String {
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPrefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        guard normalizedURL.hasPrefix(rootPrefix) else { return url.lastPathComponent }
        return String(normalizedURL.dropFirst(rootPrefix.count))
    }

    nonisolated private static func audioSort(_ lhs: AudioFileRecord, _ rhs: AudioFileRecord) -> Bool {
        let leftDisc = lhs.metadata?.discNumber ?? Int.max
        let rightDisc = rhs.metadata?.discNumber ?? Int.max
        if leftDisc != rightDisc { return leftDisc < rightDisc }
        let leftTrack = lhs.metadata?.trackNumber ?? Int.max
        let rightTrack = rhs.metadata?.trackNumber ?? Int.max
        if leftTrack != rightTrack { return leftTrack < rightTrack }
        return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }

    nonisolated private static func firstEmbeddedArtworkCover(
        in audioFiles: [AudioFileRecord]
    ) -> CoverCandidate? {
        let sortedAudioFiles = audioFiles.sorted(by: audioSort)
        guard let audioFile = sortedAudioFiles.first(where: { $0.metadata?.embeddedArtworkURL != nil }),
              let artworkURL = audioFile.metadata?.embeddedArtworkURL else {
            return nil
        }

        return CoverCandidate(
            url: artworkURL,
            relativePath: "内嵌封面：\(audioFile.relativePath)",
            namePriority: 4,
            depth: Int.max,
            source: .embeddedArtwork
        )
    }

    nonisolated private static func formatDuration(since startedAt: Date) -> String {
        let seconds = Date().timeIntervalSince(startedAt)
        if seconds < 1 {
            return "\(Int((seconds * 1_000).rounded()))毫秒"
        }
        return String(format: "%.1f秒", seconds)
    }
}

private actor ScanProgressReporter {
    private let totalAlbums: Int
    private let progress: LibraryScanProgressHandler
    private var completedAlbums = 0
    private var lastReportedAt: ContinuousClock.Instant?
    private let minimumInterval: Duration = .milliseconds(80)
    private var pendingPhase: LibraryScanProgress.Phase?
    private var pendingTargetPath: String?
    private var pendingCompletedFilesInAlbum: Int?
    private var pendingTotalFilesInAlbum: Int?

    init(
        totalAlbums: Int,
        progress: @escaping LibraryScanProgressHandler
    ) {
        self.totalAlbums = totalAlbums
        self.progress = progress
    }

    func report(
        phase: LibraryScanProgress.Phase,
        targetPath: String,
        completedFilesInAlbum: Int?,
        totalFilesInAlbum: Int?
    ) async {
        pendingPhase = phase
        pendingTargetPath = targetPath
        pendingCompletedFilesInAlbum = completedFilesInAlbum
        pendingTotalFilesInAlbum = totalFilesInAlbum

        let now = ContinuousClock.now
        if let last = lastReportedAt, now - last < minimumInterval {
            return
        }
        lastReportedAt = now
        await flushPending()
    }

    func flush() async {
        await flushPending()
    }

    private func flushPending() async {
        guard let phase = pendingPhase,
              let targetPath = pendingTargetPath else { return }
        let snapshot = completedAlbums
        await progress(LibraryScanProgress(
            phase: phase,
            targetPath: targetPath,
            completedAlbums: snapshot,
            totalAlbums: totalAlbums,
            completedFilesInAlbum: pendingCompletedFilesInAlbum,
            totalFilesInAlbum: pendingTotalFilesInAlbum
        ))
    }

    func albumCompleted() -> Int {
        completedAlbums += 1
        return completedAlbums
    }
}

private struct AlbumBoundary: Sendable {
    let folderURL: URL
    let artistName: String
    let albumName: String
    let issues: [AlbumScanIssue]
    let audioFileURLs: [URL]?

    nonisolated init(
        folderURL: URL,
        artistName: String,
        albumName: String,
        issues: [AlbumScanIssue] = [],
        audioFileURLs: [URL]? = nil
    ) {
        self.folderURL = folderURL
        self.artistName = artistName
        self.albumName = albumName
        self.issues = issues
        self.audioFileURLs = audioFileURLs?.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    nonisolated func appendingAudioFileURLs(_ newAudioFileURLs: [URL]) -> AlbumBoundary {
        AlbumBoundary(
            folderURL: folderURL,
            artistName: artistName,
            albumName: albumName,
            issues: issues,
            audioFileURLs: (audioFileURLs ?? []) + newAudioFileURLs
        )
    }
}

private struct DiscoveredBoundaries: Sendable {
    let albums: [AlbumBoundary]
    let looseAudioPaths: [String]
}

private struct ArtistDiscoveryResult: Sendable {
    let artistURL: URL
    let discovered: DiscoveredBoundaries
}

private struct DirectAudioDirectory: Sendable {
    let url: URL
    let audioFileURLs: [URL]
}

enum LibraryScanError: LocalizedError, Equatable {
    case noAlbumsFound

    var errorDescription: String? {
        "没有找到符合当前目录角色的专辑文件夹。"
    }
}

private extension Optional {
    nonisolated var isNil: Bool {
        switch self {
        case .none:
            true
        case .some:
            false
        }
    }
}
