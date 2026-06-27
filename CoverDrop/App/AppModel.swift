import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Route: Equatable {
        case libraries
        case coverWall(LibraryRecord.ID)
    }

    let environment: AppEnvironment
    private(set) var route: Route = .libraries
    private(set) var libraries: [LibraryRecord] = []
    var selectedLibraryID: LibraryRecord.ID?
    var pendingImport: PendingLibraryImport?
    private(set) var isLoadingLibraries = false
    private(set) var scanningLibraryID: LibraryRecord.ID?
    private(set) var scanProgress: LibraryScanProgress?
    private(set) var scanResultsByLibraryID: [LibraryRecord.ID: LibraryScanResult] = [:]
    var errorMessage: String?
    private(set) var pendingCoverURLsByAlbumID: [AlbumScanRecord.ID: URL] = [:]
    private(set) var coverWriteMessagesByAlbumID: [AlbumScanRecord.ID: String] = [:]

    init(environment: AppEnvironment = .live) {
        self.environment = environment
    }

    var selectedLibrary: LibraryRecord? {
        libraries.first { $0.id == selectedLibraryID }
    }

    var scanResultForSelectedLibrary: LibraryScanResult? {
        guard let selectedLibraryID else { return nil }
        return scanResultsByLibraryID[selectedLibraryID]
    }

    var isScanningLibrary: Bool {
        scanningLibraryID != nil
    }

    var isSelectedLibraryScanning: Bool {
        scanningLibraryID == selectedLibraryID
    }

    var shouldShowCoverWallForSelectedLibrary: Bool {
        guard let selectedLibraryID else { return false }
        return route == .coverWall(selectedLibraryID) && scanResultForSelectedLibrary != nil
    }

    func loadLibraries() async {
        guard !isLoadingLibraries else { return }
        isLoadingLibraries = true
        defer { isLoadingLibraries = false }

        do {
            libraries = try await environment.libraryStore.loadLibraries()
            if selectedLibraryID == nil {
                selectedLibraryID = libraries.first?.id
            }
        } catch {
            errorMessage = "无法读取音乐库列表：\(error.localizedDescription)"
        }
    }

    func selectLibrary(id: LibraryRecord.ID?) {
        selectedLibraryID = id
        if let id, scanResultsByLibraryID[id] != nil {
            route = .coverWall(id)
        } else {
            route = .libraries
        }
    }

    func showSelectedLibraryHome() {
        route = .libraries
    }

    func prepareImport(url: URL) async {
        do {
            let normalizedURL = url.standardizedFileURL
            guard !libraries.contains(where: { $0.rootPath == normalizedURL.path }) else {
                selectedLibraryID = libraries.first { $0.rootPath == normalizedURL.path }?.id
                return
            }

            let suggestion = try await environment.roleProber.suggestRole(for: normalizedURL)
            pendingImport = PendingLibraryImport(
                url: normalizedURL,
                suggestedRole: suggestion.role,
                explanation: suggestion.explanation
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmImport(role: LibraryRole) async {
        guard let pendingImport else { return }

        do {
            let bookmarkData = try environment.folderAccess.makeBookmark(for: pendingImport.url)
            let record = LibraryRecord(
                displayName: pendingImport.url.lastPathComponent,
                rootPath: pendingImport.url.path,
                bookmarkData: bookmarkData,
                role: role
            )

            try await environment.libraryStore.save(record)
            libraries = try await environment.libraryStore.loadLibraries()
            selectedLibraryID = record.id
            self.pendingImport = nil
        } catch {
            errorMessage = "无法保存音乐库：\(error.localizedDescription)"
        }
    }

    func removeSelectedLibrary() async {
        guard let selectedLibraryID else { return }

        do {
            try await environment.libraryStore.remove(id: selectedLibraryID)
            scanResultsByLibraryID[selectedLibraryID] = nil
            libraries = try await environment.libraryStore.loadLibraries()
            selectLibrary(id: libraries.first?.id)
        } catch {
            errorMessage = "无法移除音乐库：\(error.localizedDescription)"
        }
    }

    func scanSelectedLibrary() async {
        guard let library = selectedLibrary, scanningLibraryID == nil else { return }
        scanningLibraryID = library.id
        scanProgress = nil
        defer {
            if scanningLibraryID == library.id {
                scanningLibraryID = nil
                scanProgress = nil
            }
        }

        do {
            let url = try environment.folderAccess.resolveBookmark(library.bookmarkData)
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let result = try await environment.libraryScanner.scan(
                libraryURL: url,
                role: library.role
            ) { [weak self] progress in
                await MainActor.run {
                    guard self?.scanningLibraryID == library.id else { return }
                    self?.scanProgress = progress
                }
            }
            scanResultsByLibraryID[library.id] = result
            if selectedLibraryID == library.id {
                route = .coverWall(library.id)
            }
        } catch {
            errorMessage = "扫描失败：\(error.localizedDescription)"
        }
    }

    func albumInSelectedLibrary(id albumID: AlbumScanRecord.ID) -> AlbumScanRecord? {
        scanResultForSelectedLibrary?.albums.first { $0.id == albumID }
    }

    func coverWriteMessage(for albumID: AlbumScanRecord.ID) -> String? {
        coverWriteMessagesByAlbumID[albumID]
    }

    func pendingCoverURL(for albumID: AlbumScanRecord.ID) -> URL? {
        pendingCoverURLsByAlbumID[albumID]
    }

    func stageCoverImage(_ sourceURL: URL, forAlbumID albumID: AlbumScanRecord.ID) {
        pendingCoverURLsByAlbumID[albumID] = sourceURL
    }

    @discardableResult
    func stageCoverImageData(
        _ data: Data,
        suggestedExtension: String?,
        forAlbumID albumID: AlbumScanRecord.ID
    ) -> Bool {
        do {
            let stagedURL = try CoverImageStagingCache.stageImageData(
                data,
                suggestedExtension: suggestedExtension
            )
            pendingCoverURLsByAlbumID[albumID] = stagedURL
            return true
        } catch {
            errorMessage = "无法暂存拖入的图片：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func stageDroppedCoverURL(_ url: URL, forAlbumID albumID: AlbumScanRecord.ID) async -> Bool {
        if url.isFileURL {
            stageCoverImage(url, forAlbumID: albumID)
            return true
        }

        return await stageRemoteCoverImage(at: url, forAlbumID: albumID)
    }

    @discardableResult
    func stageRemoteCoverImage(at remoteURL: URL, forAlbumID albumID: AlbumScanRecord.ID) async -> Bool {
        do {
            let stagedURL = try await CoverImageStagingCache.stageRemoteImage(at: remoteURL)
            pendingCoverURLsByAlbumID[albumID] = stagedURL
            return true
        } catch {
            errorMessage = "无法暂存网页图片：\(error.localizedDescription)"
            return false
        }
    }

    func cancelPendingCoverImage(forAlbumID albumID: AlbumScanRecord.ID) {
        pendingCoverURLsByAlbumID[albumID] = nil
    }

    func savePendingCoverImage(forAlbumID albumID: AlbumScanRecord.ID) async -> Bool {
        guard let sourceURL = pendingCoverURLsByAlbumID[albumID] else { return false }
        let didWrite = await writeCoverImage(from: sourceURL, forAlbumID: albumID)
        if didWrite {
            pendingCoverURLsByAlbumID[albumID] = nil
        }
        return didWrite
    }

    func writeCoverImage(from sourceURL: URL, forAlbumID albumID: AlbumScanRecord.ID) async -> Bool {
        guard let library = selectedLibrary,
              let result = scanResultsByLibraryID[library.id],
              let album = result.albums.first(where: { $0.id == albumID }) else {
            errorMessage = "无法定位要更新的专辑。"
            return false
        }

        let didStartSourceAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSourceAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let libraryURL = try environment.folderAccess.resolveBookmark(library.bookmarkData)
            let didStartLibraryAccessing = libraryURL.startAccessingSecurityScopedResource()
            defer {
                if didStartLibraryAccessing {
                    libraryURL.stopAccessingSecurityScopedResource()
                }
            }

            let coverURL = try await environment.coverImageWriter.writeCoverImage(
                from: sourceURL,
                toAlbumFolder: album.folderURL
            )
            let previewURL = CoverPreviewCache.refreshedPreviewURL(for: coverURL)
            replaceAlbumCover(
                albumID: albumID,
                inLibraryID: library.id,
                with: coverURL,
                previewURL: previewURL
            )
            coverWriteMessagesByAlbumID = [albumID: "已保存封面：\(album.albumName)"]
            return true
        } catch {
            errorMessage = "保存封面失败：\(error.localizedDescription)"
            return false
        }
    }

    func writeCoverImage(from sourceURL: URL, for album: AlbumScanRecord) async -> Bool {
        await writeCoverImage(from: sourceURL, forAlbumID: album.id)
    }

    private func replaceAlbumCover(
        albumID: AlbumScanRecord.ID,
        inLibraryID libraryID: LibraryRecord.ID,
        with coverURL: URL,
        previewURL: URL?
    ) {
        guard let result = scanResultsByLibraryID[libraryID] else { return }
        let albums = result.albums.map { album in
            guard album.id == albumID else { return album }
            return AlbumScanRecord(
                folderURL: album.folderURL,
                artistName: album.artistName,
                albumName: album.albumName,
                audioFiles: album.audioFiles,
                displayedCover: CoverCandidate(
                    url: coverURL,
                    previewURL: previewURL,
                    relativePath: coverURL.lastPathComponent,
                    namePriority: 0,
                    depth: 0,
                    source: .file
                ),
                issues: album.issues
            )
        }
        scanResultsByLibraryID[libraryID] = LibraryScanResult(
            albums: albums,
            looseAudioPaths: result.looseAudioPaths
        )
    }
}
