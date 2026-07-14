import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    enum Route: Equatable {
        case libraries
        case coverWall(LibraryRecord.ID)
    }

    private enum RealtimeRefreshScope: Equatable {
        case albums(Set<AlbumScanRecord.ID>)

        var pendingMessage: String {
            switch self {
            case .albums(let albumIDs):
                "检测到 \(albumIDs.count) 张专辑目录变化，准备局部刷新..."
            }
        }

        var runningMessage: String {
            switch self {
            case .albums(let albumIDs):
                "正在局部刷新 \(albumIDs.count) 张专辑..."
            }
        }

        var logDescription: String {
            switch self {
            case .albums(let albumIDs):
                "albums(\(albumIDs.count))"
            }
        }

        func merged(with other: RealtimeRefreshScope) -> RealtimeRefreshScope {
            switch (self, other) {
            case (.albums(let lhs), .albums(let rhs)):
                return .albums(lhs.union(rhs))
            }
        }
    }

    private struct LoadedScanSnapshot: Sendable {
        let result: LibraryScanResult
        let albumNameSuggestions: [AlbumScanRecord.ID: AlbumNameSuggestion]
        let albumNameEnhancementStatus: AlbumNameEnhancementStatus?
    }

    nonisolated private enum OffMainCoverWriteResult: Sendable {
        case missingAlbumFolder
        case written(URL)
    }

    nonisolated private enum CoverWriteAccessPreparation: Sendable {
        case missingAlbumFolder
        case ready(CoverWriteSecurityScope)
    }

    nonisolated private struct CoverWriteSecurityScope: Sendable {
        let sourceURL: URL
        let libraryURL: URL
        let didStartSourceAccessing: Bool
        let didStartLibraryAccessing: Bool
    }

    private enum AlbumNameEnhancementQueueSource: Sendable {
        case albumManual
        case libraryManual

        var logDescription: String {
            switch self {
            case .albumManual:
                "手动专辑"
            case .libraryManual:
                "手动音乐库"
            }
        }

        var queuePriority: Int {
            switch self {
            case .albumManual:
                2
            case .libraryManual:
                1
            }
        }
    }

    private struct AlbumNameEnhancementQueueItem: Sendable {
        let libraryID: LibraryRecord.ID
        let albumID: AlbumScanRecord.ID
        let source: AlbumNameEnhancementQueueSource
        let allowCoveredAlbums: Bool
        let batchID: UUID?
    }

    private final class ScanSnapshotLoadProgressReporter: @unchecked Sendable {
        weak var appModel: AppModel?
        let libraryID: LibraryRecord.ID

        init(appModel: AppModel, libraryID: LibraryRecord.ID) {
            self.appModel = appModel
            self.libraryID = libraryID
        }

        func report(_ progress: ScanSnapshotLoadProgress) async {
            await MainActor.run { [weak appModel, libraryID] in
                guard let appModel,
                      appModel.loadingScanSnapshotLibraryIDs.contains(libraryID) else {
                    return
                }
                appModel.scanSnapshotLoadProgressByLibraryID[libraryID] = progress
                appModel.scanSnapshotMessagesByLibraryID[libraryID] = progress.completedDescription
            }
        }
    }

    let environment: AppEnvironment
    @Published private(set) var route: Route = .libraries
    @Published private(set) var libraries: [LibraryRecord] = []
    @Published var selectedLibraryID: LibraryRecord.ID? {
        didSet {
            guard oldValue != selectedLibraryID, let oldValue else { return }
            invalidateCoverStagingRequests(for: oldValue)
        }
    }
    @Published var pendingImport: PendingLibraryImport?
    @Published private(set) var isLoadingLibraries = false
    @Published private(set) var scanningLibraryID: LibraryRecord.ID?
    @Published private(set) var scanProgress: LibraryScanProgress?
    @Published private(set) var scanResultsByLibraryID: [LibraryRecord.ID: LibraryScanResult] = [:]
    private var scanDisplayIndexesByLibraryID: [LibraryRecord.ID: AlbumScanDisplayIndex] = [:]
    private var scanResultMutationGenerationByLibraryID: [LibraryRecord.ID: UInt64] = [:]
    @Published var errorMessage: String?
    @Published private(set) var albumNameEnhancementStatusByLibraryID: [LibraryRecord.ID: AlbumNameEnhancementStatus] = [:]
    @Published private(set) var albumNameEnhancementProgressByLibraryID: [LibraryRecord.ID: AlbumNameEnhancementProgress] = [:]
    @Published private(set) var albumNameSuggestionsByLibraryID: [LibraryRecord.ID: [AlbumScanRecord.ID: AlbumNameSuggestion]] = [:]
    @Published private(set) var albumNameEnhancementStateByAlbumID: [AlbumScanRecord.ID: AlbumNameEnhancementAlbumState] = [:]
    nonisolated(unsafe) private var albumNameEnhancementWorkerTask: Task<Void, Never>?
    private var albumNameEnhancementQueue: [AlbumNameEnhancementQueueItem] = []
    private var runningAlbumNameEnhancementItem: AlbumNameEnhancementQueueItem?
    private var runningAlbumNameEnhancementRequest: (item: AlbumNameEnhancementQueueItem, task: Task<AlbumNameSuggestion, Error>)?
    private var activeAlbumNameEnhancementBatchIDs: [LibraryRecord.ID: UUID] = [:]
    private var albumNameEnhancementSnapshotUpdateLibraryIDs: Set<LibraryRecord.ID> = []
    @Published private(set) var pendingCoverURLsByAlbumID: [AlbumScanRecord.ID: URL] = [:]
    private var coverStagingGenerationByAlbumID: [AlbumScanRecord.ID: UInt64] = [:]
    @Published private(set) var coverWriteMessagesByAlbumID: [AlbumScanRecord.ID: String] = [:]
    @Published private(set) var savingCoverAlbumIDs: Set<AlbumScanRecord.ID> = []
    @Published private(set) var albumFolderOpenMessagesByAlbumID: [AlbumScanRecord.ID: String] = [:]
    @Published private(set) var openingAlbumFolderIDs: Set<AlbumScanRecord.ID> = []
    @Published private(set) var cueSheetSplitMessagesByAlbumID: [AlbumScanRecord.ID: String] = [:]
    @Published private(set) var splittingCueSheetAlbumIDs: Set<AlbumScanRecord.ID> = []
    @Published private(set) var latestScanSnapshotsByLibraryID: [LibraryRecord.ID: ScanSnapshotSummary] = [:]
    @Published private(set) var activeScanSnapshotsByLibraryID: [LibraryRecord.ID: ScanSnapshotSummary] = [:]
    @Published private(set) var scanSnapshotMessagesByLibraryID: [LibraryRecord.ID: String] = [:]
    @Published private(set) var loadingScanSnapshotLibraryIDs: Set<LibraryRecord.ID> = []
    @Published private(set) var scanSnapshotLoadProgressByLibraryID: [LibraryRecord.ID: ScanSnapshotLoadProgress] = [:]
    @Published private(set) var realtimeRefreshMessagesByLibraryID: [LibraryRecord.ID: String] = [:]
    nonisolated(unsafe) private var libraryChangeMonitorTasksByLibraryID: [LibraryRecord.ID: Task<Void, Never>] = [:]
    nonisolated(unsafe) private var realtimeRefreshDebounceTasksByLibraryID: [LibraryRecord.ID: Task<Void, Never>] = [:]
    nonisolated(unsafe) private var libraryChangeMonitorRestartTasksByLibraryID: [LibraryRecord.ID: Task<Void, Never>] = [:]
    private var refreshingLibraryIDs: Set<LibraryRecord.ID> = []
    private var pendingRefreshLibraryIDs: Set<LibraryRecord.ID> = []
    private var pendingRealtimeRefreshScopesByLibraryID: [LibraryRecord.ID: RealtimeRefreshScope] = [:]
    private var ignoredInternalRealtimeChangePathsByLibraryID: [LibraryRecord.ID: [String: Date]] = [:]
    private let scanSnapshotUpdateQueue = ScanSnapshotUpdateQueue()
    private let taskLock = NSLock()

    init(environment: AppEnvironment = .live) {
        self.environment = environment
    }

    deinit {
        taskLock.lock()
        var allTasks: [Task<Void, Never>] = []
        allTasks.append(contentsOf: libraryChangeMonitorTasksByLibraryID.values)
        allTasks.append(contentsOf: realtimeRefreshDebounceTasksByLibraryID.values)
        allTasks.append(contentsOf: libraryChangeMonitorRestartTasksByLibraryID.values)
        if let albumNameEnhancementWorkerTask {
            allTasks.append(albumNameEnhancementWorkerTask)
        }
        taskLock.unlock()
        for task in allTasks {
            task.cancel()
        }
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

    var isSelectedLibraryLoadingScanSnapshot: Bool {
        guard let selectedLibraryID else { return false }
        return scanSnapshotLoadProgressByLibraryID[selectedLibraryID] != nil
    }

    var shouldShowCoverWallForSelectedLibrary: Bool {
        scanResultForSelectedLibrary != nil
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
            refreshLatestScanSnapshotsInBackground()
            restartLibraryChangeMonitoringForScannedLibraries()
        } catch {
            errorMessage = "无法读取音乐库列表：\(error.localizedDescription)"
        }
    }

    func selectLibrary(id: LibraryRecord.ID?) {
        selectedLibraryID = id
        if let id, scanResultsByLibraryID[id] != nil {
            route = .coverWall(id)
        }
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
            await refreshLatestScanSnapshot(for: record)
        } catch {
            errorMessage = "无法保存音乐库：\(error.localizedDescription)"
        }
    }

    func removeSelectedLibrary() async {
        guard let selectedLibraryID else { return }
        await removeLibraries(ids: [selectedLibraryID])
    }

    func removeLibraries(ids: Set<LibraryRecord.ID>) async {
        let idsToRemove = ids.intersection(Set(libraries.map(\.id)))
        guard !idsToRemove.isEmpty else { return }
        if let scanningLibraryID, idsToRemove.contains(scanningLibraryID) {
            errorMessage = "正在扫描的音乐库不能移除，请等待扫描结束。"
            return
        }

        do {
            for libraryID in idsToRemove {
                try await environment.libraryStore.remove(id: libraryID)
                clearLibraryState(for: libraryID)
            }
            libraries = try await environment.libraryStore.loadLibraries()
            if let selectedLibraryID, idsToRemove.contains(selectedLibraryID) {
                selectLibrary(id: libraries.first?.id)
            } else if selectedLibraryID == nil {
                selectLibrary(id: libraries.first?.id)
            }
        } catch {
            errorMessage = "无法移除音乐库：\(error.localizedDescription)"
        }
    }

    func renameLibrary(id libraryID: LibraryRecord.ID, displayName: String) async {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "音乐库名称不能为空。"
            return
        }
        guard let library = libraries.first(where: { $0.id == libraryID }) else { return }

        do {
            var renamedLibrary = library
            renamedLibrary.displayName = trimmedName
            try await environment.libraryStore.save(renamedLibrary)
            libraries = try await environment.libraryStore.loadLibraries()
        } catch {
            errorMessage = "无法重命名音乐库：\(error.localizedDescription)"
        }
    }

    func scanSelectedLibrary() async {
        guard let library = selectedLibrary else { return }
        await scanLibrary(library)
    }

    func scanLibraries(ids: Set<LibraryRecord.ID>) async {
        guard scanningLibraryID == nil else { return }
        let targets = libraries.filter { ids.contains($0.id) }
        for library in targets {
            await scanLibrary(library)
        }
    }

    private func scanLibrary(_ library: LibraryRecord) async {
        guard scanningLibraryID == nil else { return }
        scanningLibraryID = library.id
        scanProgress = nil
        stopLibraryChangeMonitoring(for: library.id)
        cancelAlbumNameEnhancement(for: library.id, clearsSuggestions: false)
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

            let scanner = environment.libraryScanner
            let libraryID = library.id
            let result = try await Task.detached(priority: .userInitiated) { [weak self, scanner] in
                try await scanner.scan(
                    libraryURL: url,
                    role: library.role
                ) { progress in
                    await MainActor.run {
                        guard self?.scanningLibraryID == libraryID else { return }
                        self?.scanProgress = progress
                    }
                }
            }.value
            cancelAlbumNameEnhancement(for: library.id)
            guard await setScanResult(result, for: library.id) else {
                return
            }
            await saveNewScanSnapshot(for: library, result: result)
            startLibraryChangeMonitoring(for: library)
            if selectedLibraryID == library.id {
                route = .coverWall(library.id)
            }
        } catch {
            errorMessage = "扫描失败：\(error.localizedDescription)"
            startLibraryChangeMonitoring(for: library)
        }
    }

    func albumInSelectedLibrary(id albumID: AlbumScanRecord.ID) -> AlbumScanRecord? {
        guard let selectedLibraryID else { return nil }
        return scanDisplayIndexesByLibraryID[selectedLibraryID]?.album(id: albumID)
    }

    func scanResultStats(for libraryID: LibraryRecord.ID) -> AlbumScanResultStats? {
        scanDisplayIndexesByLibraryID[libraryID]?.stats
    }

    func filteredAlbumsInSelectedLibrary(
        filter: AlbumScanResultFilter,
        query: String
    ) -> [AlbumScanRecord] {
        guard let selectedLibraryID else { return [] }
        return scanDisplayIndexesByLibraryID[selectedLibraryID]?.albums(
            filter: filter,
            query: query
        ) ?? []
    }

    func coverWallSnapshotInSelectedLibrary(
        filter: AlbumScanResultFilter,
        query: String
    ) -> AlbumCoverWallSnapshot {
        guard let selectedLibraryID,
              let index = scanDisplayIndexesByLibraryID[selectedLibraryID] else {
            return AlbumCoverWallSnapshot(
                revision: 0,
                filter: filter,
                normalizedQuery: query,
                cards: []
            )
        }
        return index.coverWallSnapshot(filter: filter, query: query)
    }

    func filteredLooseAudioPathsInSelectedLibrary(
        filter: AlbumScanResultFilter,
        query: String
    ) -> [String] {
        guard let selectedLibraryID else { return [] }
        return scanDisplayIndexesByLibraryID[selectedLibraryID]?.looseAudioPaths(
            filter: filter,
            query: query
        ) ?? []
    }

    func coverWriteMessage(for albumID: AlbumScanRecord.ID) -> String? {
        coverWriteMessagesByAlbumID[albumID]
    }

    func isSavingCoverImage(for albumID: AlbumScanRecord.ID) -> Bool {
        savingCoverAlbumIDs.contains(albumID)
    }

    func albumFolderOpenMessage(forAlbumID albumID: AlbumScanRecord.ID) -> String? {
        albumFolderOpenMessagesByAlbumID[albumID]
    }

    func isOpeningAlbumFolder(_ albumID: AlbumScanRecord.ID) -> Bool {
        openingAlbumFolderIDs.contains(albumID)
    }

    func cueSheetSplitMessage(forAlbumID albumID: AlbumScanRecord.ID) -> String? {
        cueSheetSplitMessagesByAlbumID[albumID]
    }

    func isSplittingCueSheet(_ albumID: AlbumScanRecord.ID) -> Bool {
        splittingCueSheetAlbumIDs.contains(albumID)
    }

    func albumNameEnhancementStatus(for libraryID: LibraryRecord.ID) -> AlbumNameEnhancementStatus? {
        albumNameEnhancementStatusByLibraryID[libraryID]
    }

    func albumNameEnhancementState(forAlbumID albumID: AlbumScanRecord.ID) -> AlbumNameEnhancementAlbumState? {
        albumNameEnhancementStateByAlbumID[albumID]
    }

    func albumNameEnhancementProgress(for libraryID: LibraryRecord.ID) -> AlbumNameEnhancementProgress? {
        albumNameEnhancementProgressByLibraryID[libraryID]
    }

    func isAlbumNameEnhancementRunning(for libraryID: LibraryRecord.ID) -> Bool {
        albumNameEnhancementStatusByLibraryID[libraryID]?.isRunning == true
    }

    func albumNameEnhancementFailedAlbumIDs(for libraryID: LibraryRecord.ID) -> Set<AlbumScanRecord.ID> {
        if let index = scanDisplayIndexesByLibraryID[libraryID] {
            return index.failedAlbumIDs
        }
        guard let result = scanResultsByLibraryID[libraryID] else { return [] }
        let albumIDs = Set(result.albums.map(\.id))
        return Set(albumNameEnhancementStateByAlbumID.compactMap { albumID, state in
            albumIDs.contains(albumID) && state.lastErrorMessage != nil ? albumID : nil
        })
    }

    func albumNameEnhancementFailedAlbumCount(for libraryID: LibraryRecord.ID) -> Int {
        albumNameEnhancementFailedAlbumIDs(for: libraryID).count
    }

    func albumNameEnhancementFailureSummary(for libraryID: LibraryRecord.ID) -> String? {
        let failedCount = albumNameEnhancementFailedAlbumCount(for: libraryID)
        guard failedCount > 0 else { return nil }

        if albumNameEnhancementStatusByLibraryID[libraryID]?.isRunning == true {
            return "Ollama 正在解析专辑名，已有 \(failedCount) 张专辑解析失败，已回退原始名称"
        }

        return "Ollama 解析完成，\(failedCount) 张专辑解析失败，已回退原始名称"
    }

    func requestAlbumNameEnhancement(forAlbumID albumID: AlbumScanRecord.ID) {
        guard environment.configuration.localLLM.isEnabled else {
            errorMessage = "本地 Ollama 专辑名称增强未启用。"
            return
        }
        guard let libraryID = selectedLibraryID,
              scanResultsByLibraryID[libraryID]?.albums.contains(where: { $0.id == albumID }) == true else {
            errorMessage = "当前扫描结果中已没有这张专辑。"
            return
        }

        enqueueAlbumNameEnhancement(
            AlbumNameEnhancementQueueItem(
                libraryID: libraryID,
                albumID: albumID,
                source: .albumManual,
                allowCoveredAlbums: true,
                batchID: nil
            )
        )
    }

    func requestAlbumNameEnhancement(forLibraryID libraryID: LibraryRecord.ID) {
        guard environment.configuration.localLLM.isEnabled else {
            errorMessage = "本地 Ollama 专辑名称增强未启用。"
            return
        }
        guard let result = scanResultsByLibraryID[libraryID] else {
            errorMessage = "请先扫描或加载这个音乐库。"
            return
        }
        let missingCoverAlbums = result.albums.filter(Self.isMissingCover)
        guard !missingCoverAlbums.isEmpty else {
            activeAlbumNameEnhancementBatchIDs[libraryID] = nil
            albumNameEnhancementProgressByLibraryID[libraryID] = AlbumNameEnhancementProgress(
                completedAlbums: 0,
                totalAlbums: 0,
                currentAlbumName: nil
            )
            albumNameEnhancementStatusByLibraryID[libraryID] = AlbumNameEnhancementStatus(
                isRunning: false,
                lastErrorMessage: nil
            )
            return
        }

        let batchID = UUID()
        activeAlbumNameEnhancementBatchIDs[libraryID] = batchID
        var queuedAlbumCount = 0
        for album in missingCoverAlbums {
            let didEnqueue = enqueueAlbumNameEnhancement(
                AlbumNameEnhancementQueueItem(
                    libraryID: libraryID,
                    albumID: album.id,
                    source: .libraryManual,
                    allowCoveredAlbums: false,
                    batchID: batchID
                ),
                startsWorker: false
            )
            if didEnqueue {
                queuedAlbumCount += 1
            }
        }

        guard queuedAlbumCount > 0 else {
            if !hasPendingAlbumNameEnhancement(for: libraryID) {
                albumNameEnhancementProgressByLibraryID[libraryID] = AlbumNameEnhancementProgress(
                    completedAlbums: missingCoverAlbums.count,
                    totalAlbums: missingCoverAlbums.count,
                    currentAlbumName: nil
                )
                albumNameEnhancementStatusByLibraryID[libraryID] = AlbumNameEnhancementStatus(
                    isRunning: false,
                    lastErrorMessage: albumNameEnhancementStatusByLibraryID[libraryID]?.lastErrorMessage
                )
            }
            return
        }

        albumNameEnhancementProgressByLibraryID[libraryID] = AlbumNameEnhancementProgress(
            completedAlbums: 0,
            totalAlbums: queuedAlbumCount,
            currentAlbumName: nil
        )
        albumNameEnhancementStatusByLibraryID[libraryID] = AlbumNameEnhancementStatus(
            isRunning: true,
            lastErrorMessage: nil
        )
        startAlbumNameEnhancementWorkerIfNeeded()
    }

    func stopAlbumNameEnhancement(forLibraryID libraryID: LibraryRecord.ID) {
        guard isAlbumNameEnhancementRunning(for: libraryID) else { return }

        CoverDropDebugLog.write("Ollama 名称增强：用户停止批处理，libraryID=\(libraryID)")
        activeAlbumNameEnhancementBatchIDs[libraryID] = nil
        let queuedAlbumIDs = albumNameEnhancementQueue
            .filter { $0.libraryID == libraryID }
            .map(\.albumID)
        albumNameEnhancementQueue.removeAll { $0.libraryID == libraryID }
        for albumID in queuedAlbumIDs {
            albumNameEnhancementStateByAlbumID[albumID] = nil
        }

        if runningAlbumNameEnhancementItem?.libraryID == libraryID {
            runningAlbumNameEnhancementRequest?.task.cancel()
            if let runningAlbumID = runningAlbumNameEnhancementItem?.albumID {
                albumNameEnhancementStateByAlbumID[runningAlbumID] = nil
            }
            runningAlbumNameEnhancementItem = nil
        }

        if let progress = albumNameEnhancementProgressByLibraryID[libraryID] {
            albumNameEnhancementProgressByLibraryID[libraryID] = AlbumNameEnhancementProgress(
                completedAlbums: progress.completedAlbums,
                totalAlbums: progress.totalAlbums,
                currentAlbumName: nil
            )
        }
        albumNameEnhancementStatusByLibraryID[libraryID] = AlbumNameEnhancementStatus(
            isRunning: false,
            lastErrorMessage: nil
        )
    }

    func latestScanSnapshot(for libraryID: LibraryRecord.ID) -> ScanSnapshotSummary? {
        latestScanSnapshotsByLibraryID[libraryID]
    }

    func activeScanSnapshot(for libraryID: LibraryRecord.ID) -> ScanSnapshotSummary? {
        activeScanSnapshotsByLibraryID[libraryID]
    }

    func scanSnapshotMessage(for libraryID: LibraryRecord.ID) -> String? {
        scanSnapshotMessagesByLibraryID[libraryID]
    }

    func scanSnapshotLoadProgress(for libraryID: LibraryRecord.ID) -> ScanSnapshotLoadProgress? {
        scanSnapshotLoadProgressByLibraryID[libraryID]
    }

    func isLoadingScanSnapshot(for libraryID: LibraryRecord.ID) -> Bool {
        loadingScanSnapshotLibraryIDs.contains(libraryID)
    }

    func realtimeRefreshMessage(for libraryID: LibraryRecord.ID) -> String? {
        realtimeRefreshMessagesByLibraryID[libraryID]
    }

    @discardableResult
    func removeAlbumIfFolderMissing(albumID: AlbumScanRecord.ID) async -> Bool {
        guard let selectedLibraryID,
              let album = albumInSelectedLibrary(id: albumID) else {
            return false
        }

        guard !(await Self.albumFolderExistsOffMainActor(album.folderURL)),
              self.selectedLibraryID == selectedLibraryID,
              let result = scanResultsByLibraryID[selectedLibraryID],
              albumInSelectedLibrary(id: albumID)?.folderURL == album.folderURL else {
            return false
        }

        let albums = result.albums.filter { $0.id != albumID }
        guard await setScanResult(LibraryScanResult(
            albums: albums,
            looseAudioPaths: result.looseAudioPaths
        ), for: selectedLibraryID) else {
            return false
        }
        clearTransientState(forAlbumID: albumID, inLibraryID: selectedLibraryID)
        realtimeRefreshMessagesByLibraryID[selectedLibraryID] = "专辑目录已移除"
        scheduleActiveScanSnapshotUpdate(for: selectedLibraryID)
        return true
    }

    func loadLatestScanSnapshotForSelectedLibrary() async {
        guard let library = selectedLibrary else { return }
        guard !loadingScanSnapshotLibraryIDs.contains(library.id) else { return }
        loadingScanSnapshotLibraryIDs.insert(library.id)
        scanSnapshotMessagesByLibraryID[library.id] = "正在加载最近扫描结果..."
        scanSnapshotLoadProgressByLibraryID[library.id] = ScanSnapshotLoadProgress(
            phase: .locating,
            completedAlbums: 0,
            totalAlbums: nil
        )
        defer {
            loadingScanSnapshotLibraryIDs.remove(library.id)
            scanSnapshotLoadProgressByLibraryID[library.id] = nil
        }

        do {
            if latestScanSnapshotsByLibraryID[library.id] == nil {
                await refreshLatestScanSnapshot(for: library)
                loadingScanSnapshotLibraryIDs.insert(library.id)
            }

            guard let summary = latestScanSnapshotsByLibraryID[library.id] else {
                scanSnapshotMessagesByLibraryID[library.id] = "没有找到这个目录的历史扫描快照。"
                return
            }

            let snapshotStore = environment.scanSnapshotStore
            let libraryID = library.id
            scanSnapshotLoadProgressByLibraryID[libraryID] = ScanSnapshotLoadProgress(
                phase: .reading,
                completedAlbums: 0,
                totalAlbums: summary.albumCount
            )
            let progressReporter = ScanSnapshotLoadProgressReporter(appModel: self, libraryID: libraryID)
            let loadedSnapshot = try await Task.detached(priority: .userInitiated) { [snapshotStore, progressReporter] in
                try await Self.loadScanSnapshot(
                    at: summary.fileURL,
                    expectedLibrary: library,
                    expectedAlbumCount: summary.albumCount,
                    snapshotStore: snapshotStore
                ) { progress in
                    await progressReporter.report(progress)
                }
            }.value
            cancelAlbumNameEnhancement(for: library.id)
            albumNameSuggestionsByLibraryID[library.id] = loadedSnapshot.albumNameSuggestions
            if let status = loadedSnapshot.albumNameEnhancementStatus {
                albumNameEnhancementStatusByLibraryID[library.id] = status
            }
            guard await setScanResult(loadedSnapshot.result, for: library.id) else {
                return
            }
            activeScanSnapshotsByLibraryID[library.id] = summary
            scanSnapshotMessagesByLibraryID[library.id] = "已加载快照结果：\(summary.fileURL.lastPathComponent)"
            startLibraryChangeMonitoring(for: library)
            route = .coverWall(library.id)
        } catch {
            CoverDropDebugLog.write(
                "扫描快照：加载失败，音乐库=\(library.displayName)，路径=\(library.rootPath)，原因=\(error.localizedDescription)"
            )
            errorMessage = "加载扫描快照失败：\(error.localizedDescription)"
        }
    }

    private nonisolated static func loadScanSnapshot(
        at fileURL: URL,
        expectedLibrary: LibraryRecord,
        expectedAlbumCount: Int,
        snapshotStore: any ScanSnapshotStoring,
        progress: @escaping @Sendable (ScanSnapshotLoadProgress) async -> Void
    ) async throws -> LoadedScanSnapshot {
        await progress(
            ScanSnapshotLoadProgress(
                phase: .reading,
                completedAlbums: 0,
                totalAlbums: expectedAlbumCount
            )
        )
        let snapshot: ScanSnapshot
        if let streamingStore = snapshotStore as? any StreamingScanSnapshotStoring {
            snapshot = try await streamingStore.loadSnapshot(
                at: fileURL,
                expectedLibrary: expectedLibrary,
                progress: progress
            )
        } else {
            snapshot = try await snapshotStore.loadSnapshot(
                at: fileURL,
                expectedLibrary: expectedLibrary
            )
        }

        let totalAlbums = snapshot.scanResult.albums.count
        await progress(
            ScanSnapshotLoadProgress(
                phase: .converting,
                completedAlbums: 0,
                totalAlbums: totalAlbums
            )
        )

        var albums: [AlbumScanRecord] = []
        albums.reserveCapacity(totalAlbums)
        for (index, album) in snapshot.scanResult.albums.enumerated() {
            albums.append(try album.makeAlbumScanRecord())
            let completedAlbums = index + 1
            if completedAlbums == totalAlbums || completedAlbums % 25 == 0 {
                await progress(
                    ScanSnapshotLoadProgress(
                        phase: .converting,
                        completedAlbums: completedAlbums,
                        totalAlbums: totalAlbums
                    )
                )
            }
        }

        if totalAlbums == 0 {
            await progress(
                ScanSnapshotLoadProgress(
                    phase: .converting,
                    completedAlbums: 0,
                    totalAlbums: 0
                )
            )
        }

        let result = LibraryScanResult(
            albums: albums,
            looseAudioPaths: snapshot.scanResult.looseAudioPaths
        )
        let suggestions = snapshot.albumNameEnhancement?.makeSuggestionsByAlbumID() ?? [:]
        let status = snapshot.albumNameEnhancement?.status?.makeAlbumNameEnhancementStatusForLoadedSnapshot()
        return LoadedScanSnapshot(
            result: result,
            albumNameSuggestions: suggestions,
            albumNameEnhancementStatus: status
        )
    }

    func displayArtistName(for album: AlbumScanRecord, in libraryID: LibraryRecord.ID? = nil) -> String {
        displayNames(for: album, in: libraryID).artistName
    }

    func displayAlbumName(for album: AlbumScanRecord, in libraryID: LibraryRecord.ID? = nil) -> String {
        displayNames(for: album, in: libraryID).albumName
    }

    func hasEnhancedAlbumName(for album: AlbumScanRecord, in libraryID: LibraryRecord.ID? = nil) -> Bool {
        let resolvedLibraryID = libraryID ?? selectedLibraryID
        guard let resolvedLibraryID else { return false }
        return albumNameSuggestionsByLibraryID[resolvedLibraryID]?[album.id] != nil
    }

    func displayNames(
        for album: AlbumScanRecord,
        in libraryID: LibraryRecord.ID? = nil
    ) -> (artistName: String, albumName: String) {
        let resolvedLibraryID = libraryID ?? selectedLibraryID
        if let resolvedLibraryID,
           let presentation = scanDisplayIndexesByLibraryID[resolvedLibraryID]?.presentation(id: album.id) {
            return (
                artistName: presentation.displayArtistName,
                albumName: presentation.displayAlbumName
            )
        }

        if let resolvedLibraryID,
           let suggestion = albumNameSuggestionsByLibraryID[resolvedLibraryID]?[album.id] {
            return AlbumDisplayNameCleaning.displayNames(
                for: album,
                artistName: suggestion.artistName,
                albumName: suggestion.albumName
            )
        }

        return AlbumDisplayNameCleaning.displayNames(
            for: album,
            artistName: album.artistName,
            albumName: album.albumName
        )
    }

    func searchKeyword(for album: AlbumScanRecord, in libraryID: LibraryRecord.ID? = nil) -> String {
        let names = displayNames(for: album, in: libraryID)
        return CoverSearchKeyword.make(
            artistName: names.artistName,
            albumName: names.albumName
        )
    }

    nonisolated private static func makeCoverCardPresentation(
        for album: AlbumScanRecord,
        suggestion: AlbumNameSuggestion?,
        enhancementErrorMessage: String?,
        contentRevision: UInt64
    ) -> AlbumCoverCardPresentation {
        let names = AlbumDisplayNameCleaning.displayNames(
            for: album,
            artistName: suggestion?.artistName ?? album.artistName,
            albumName: suggestion?.albumName ?? album.albumName
        )
        let issueHelp = album.issues.map(\.displayName).joined(separator: "\n")
        return AlbumCoverCardPresentation(
            id: album.id,
            folderURL: album.folderURL,
            displayArtistName: names.artistName,
            displayAlbumName: names.albumName,
            formatTags: Array(Set(album.audioFiles.map { $0.format.uppercased() }))
                .sorted()
                .prefix(2)
                .map { $0 },
            coverURL: album.displayedCover?.displayURL,
            contentRevision: contentRevision,
            coverSourceName: album.displayedCover?.source.displayName,
            needsAttention: album.needsAttention,
            issueHelp: issueHelp.isEmpty ? nil : issueHelp,
            canSplitWithXLD: AlbumScanDisplayIndex.canSplitSingleFileCue(album),
            hasEnhancedName: suggestion != nil,
            enhancementErrorMessage: enhancementErrorMessage
        )
    }

    private func makeCoverCardPresentationBuilder(
        for libraryID: LibraryRecord.ID
    ) -> @Sendable (AlbumScanRecord, UInt64) -> AlbumCoverCardPresentation {
        let suggestions = albumNameSuggestionsByLibraryID[libraryID] ?? [:]
        let errorMessages = albumNameEnhancementStateByAlbumID.compactMapValues(\.lastErrorMessage)
        return { album, contentRevision in
            Self.makeCoverCardPresentation(
                for: album,
                suggestion: suggestions[album.id],
                enhancementErrorMessage: errorMessages[album.id],
                contentRevision: contentRevision
            )
        }
    }

    private func failedAlbumIDs(in result: LibraryScanResult) -> Set<AlbumScanRecord.ID> {
        let albumIDs = Set(result.albums.map(\.id))
        return Set(albumNameEnhancementStateByAlbumID.compactMap { albumID, state in
            albumIDs.contains(albumID) && state.lastErrorMessage != nil ? albumID : nil
        })
    }

    @discardableResult
    func setScanResult(
        _ result: LibraryScanResult,
        for libraryID: LibraryRecord.ID
    ) async -> Bool {
        let mutationGeneration = beginScanResultMutation(for: libraryID)
        let failedAlbumIDs = failedAlbumIDs(in: result)
        let makePresentation = makeCoverCardPresentationBuilder(for: libraryID)
        let displayIndex = await Self.buildScanDisplayIndexOffMainActor(
            result: result,
            failedAlbumIDs: failedAlbumIDs,
            makePresentation: makePresentation
        )
        guard scanResultMutationGenerationByLibraryID[libraryID] == mutationGeneration else {
            CoverDropDebugLog.write(
                "扫描展示索引：丢弃已过期的后台构建，libraryID=\(libraryID)，专辑数=\(result.albums.count)"
            )
            return false
        }
        scanResultsByLibraryID[libraryID] = result
        scanDisplayIndexesByLibraryID[libraryID] = displayIndex
        return true
    }

    nonisolated static func buildScanDisplayIndexOffMainActor(
        result: LibraryScanResult,
        failedAlbumIDs: Set<AlbumScanRecord.ID>,
        makePresentation: @escaping @Sendable (AlbumScanRecord, UInt64) -> AlbumCoverCardPresentation
    ) async -> AlbumScanDisplayIndex {
        await Task.detached(priority: .userInitiated) {
            AlbumScanDisplayIndex(
                result: result,
                failedAlbumIDs: failedAlbumIDs,
                makePresentation: makePresentation
            )
        }.value
    }

    private func setScanResult(
        _ result: LibraryScanResult,
        replacingAlbums refreshedAlbums: [AlbumScanRecord],
        for libraryID: LibraryRecord.ID
    ) {
        beginScanResultMutation(for: libraryID)
        scanResultsByLibraryID[libraryID] = result
        if let index = scanDisplayIndexesByLibraryID[libraryID] {
            scanDisplayIndexesByLibraryID[libraryID] = index.replacingAlbums(
                refreshedAlbums,
                makePresentation: makeCoverCardPresentationBuilder(for: libraryID)
            )
        } else {
            rebuildScanDisplayIndex(for: libraryID, invalidatesPendingBuild: false)
        }
    }

    private func clearScanResult(for libraryID: LibraryRecord.ID) {
        beginScanResultMutation(for: libraryID)
        scanResultsByLibraryID[libraryID] = nil
        scanDisplayIndexesByLibraryID[libraryID] = nil
    }

    private func rebuildScanDisplayIndex(
        for libraryID: LibraryRecord.ID,
        invalidatesPendingBuild: Bool = true
    ) {
        if invalidatesPendingBuild {
            beginScanResultMutation(for: libraryID)
        }
        guard let result = scanResultsByLibraryID[libraryID] else {
            scanDisplayIndexesByLibraryID[libraryID] = nil
            return
        }
        scanDisplayIndexesByLibraryID[libraryID] = AlbumScanDisplayIndex(
            result: result,
            failedAlbumIDs: failedAlbumIDs(in: result),
            makePresentation: makeCoverCardPresentationBuilder(for: libraryID)
        )
    }

    private func updateScanDisplayIndexForNameEnhancement(
        albumID: AlbumScanRecord.ID,
        libraryID: LibraryRecord.ID
    ) {
        beginScanResultMutation(for: libraryID)
        guard let index = scanDisplayIndexesByLibraryID[libraryID],
              index.album(id: albumID) != nil else {
            rebuildScanDisplayIndex(for: libraryID, invalidatesPendingBuild: false)
            return
        }

        var failedAlbumIDs = index.failedAlbumIDs
        if albumNameEnhancementStateByAlbumID[albumID]?.lastErrorMessage != nil {
            failedAlbumIDs.insert(albumID)
        } else {
            failedAlbumIDs.remove(albumID)
        }

        scanDisplayIndexesByLibraryID[libraryID] = index.updatingNameEnhancement(
            for: albumID,
            failedAlbumIDs: failedAlbumIDs,
            makePresentation: makeCoverCardPresentationBuilder(for: libraryID)
        )
    }

    @discardableResult
    private func beginScanResultMutation(for libraryID: LibraryRecord.ID) -> UInt64 {
        let nextGeneration = (scanResultMutationGenerationByLibraryID[libraryID] ?? 0) &+ 1
        scanResultMutationGenerationByLibraryID[libraryID] = nextGeneration
        return nextGeneration
    }

    @discardableResult
    private func beginCoverStagingRequest(for albumID: AlbumScanRecord.ID) -> UInt64 {
        let nextGeneration = (coverStagingGenerationByAlbumID[albumID] ?? 0) &+ 1
        coverStagingGenerationByAlbumID[albumID] = nextGeneration
        return nextGeneration
    }

    private func isCurrentCoverStagingRequest(
        generation: UInt64,
        albumID: AlbumScanRecord.ID,
        libraryID: LibraryRecord.ID?
    ) -> Bool {
        guard let libraryID,
              selectedLibraryID == libraryID,
              coverStagingGenerationByAlbumID[albumID] == generation else {
            return false
        }
        return scanDisplayIndexesByLibraryID[libraryID]?.album(id: albumID) != nil
    }

    private func invalidateCoverStagingRequests(for libraryID: LibraryRecord.ID) {
        guard let result = scanResultsByLibraryID[libraryID] else { return }
        for album in result.albums {
            beginCoverStagingRequest(for: album.id)
        }
    }

    func pendingCoverURL(for albumID: AlbumScanRecord.ID) -> URL? {
        pendingCoverURLsByAlbumID[albumID]
    }

    func stageCoverImage(_ sourceURL: URL, forAlbumID albumID: AlbumScanRecord.ID) {
        beginCoverStagingRequest(for: albumID)
        pendingCoverURLsByAlbumID[albumID] = sourceURL
    }

    func stageCoverImageIfProvided(_ sourceURL: URL?, forAlbumID albumID: AlbumScanRecord.ID) {
        guard let sourceURL else { return }
        stageCoverImage(sourceURL, forAlbumID: albumID)
    }

    @discardableResult
    func stageCoverImageData(
        _ data: Data,
        suggestedExtension: String?,
        forAlbumID albumID: AlbumScanRecord.ID
    ) async -> Bool {
        let libraryID = selectedLibraryID
        let stagingGeneration = beginCoverStagingRequest(for: albumID)
        let performanceSpan = CoverDropPerformanceLog.begin(
            CoverDropPerformanceOperation.stageCoverImage,
            context: [
                "albumID": albumID,
                "bytes": "\(data.count)",
                "kind": "data"
            ]
        )
        do {
            let stagedURL = try await environment.coverImageStager.stageImageData(
                data,
                suggestedExtension: suggestedExtension
            )
            guard isCurrentCoverStagingRequest(
                generation: stagingGeneration,
                albumID: albumID,
                libraryID: libraryID
            ) else {
                await Self.removeDiscardedStagedCover(at: stagedURL)
                performanceSpan?.finish(
                    outcome: .cancelled,
                    context: ["reason": "stale_request"]
                )
                return false
            }
            pendingCoverURLsByAlbumID[albumID] = stagedURL
            performanceSpan?.finish()
            return true
        } catch {
            guard isCurrentCoverStagingRequest(
                generation: stagingGeneration,
                albumID: albumID,
                libraryID: libraryID
            ) else {
                performanceSpan?.finish(
                    outcome: .cancelled,
                    context: ["reason": "stale_request"]
                )
                return false
            }
            errorMessage = "无法暂存拖入的图片：\(error.localizedDescription)"
            performanceSpan?.finish(
                outcome: .failure,
                context: ["error": error.localizedDescription]
            )
            return false
        }
    }

    @discardableResult
    func stageDroppedCoverURL(_ url: URL, forAlbumID albumID: AlbumScanRecord.ID) async -> Bool {
        let performanceSpan = CoverDropPerformanceLog.begin(
            CoverDropPerformanceOperation.stageCoverImage,
            context: [
                "albumID": albumID,
                "kind": url.isFileURL ? "file" : "remote"
            ]
        )
        if url.isFileURL {
            CoverDropDebugLog.write("封面暂存：收到本地文件 URL：\(url.path)")
            stageCoverImage(url, forAlbumID: albumID)
            performanceSpan?.finish()
            return true
        }

        CoverDropDebugLog.write("封面暂存：收到远程 URL：\(url.absoluteString)")
        let didStage = await stageRemoteCoverImage(at: url, forAlbumID: albumID)
        performanceSpan?.finish(
            outcome: didStage ? .success : .failure
        )
        return didStage
    }

    func prefetchRemoteCoverImage(at remoteURL: URL) {
        guard ["http", "https"].contains(remoteURL.scheme?.lowercased()) else { return }

        Task { [coverImageStager = environment.coverImageStager] in
            await coverImageStager.prefetchRemoteImage(at: remoteURL)
        }
    }

    @discardableResult
    func stageRemoteCoverImage(at remoteURL: URL, forAlbumID albumID: AlbumScanRecord.ID) async -> Bool {
        let libraryID = selectedLibraryID
        let stagingGeneration = beginCoverStagingRequest(for: albumID)
        do {
            let stagedURL = try await environment.coverImageStager.stageRemoteImage(at: remoteURL)
            guard isCurrentCoverStagingRequest(
                generation: stagingGeneration,
                albumID: albumID,
                libraryID: libraryID
            ) else {
                await Self.removeDiscardedStagedCover(at: stagedURL)
                return false
            }
            pendingCoverURLsByAlbumID[albumID] = stagedURL
            CoverDropDebugLog.write("封面暂存：远程图片已暂存到：\(stagedURL.path)")
            return true
        } catch {
            guard isCurrentCoverStagingRequest(
                generation: stagingGeneration,
                albumID: albumID,
                libraryID: libraryID
            ) else {
                return false
            }
            CoverDropDebugLog.write("封面暂存：远程图片暂存失败，URL=\(remoteURL.absoluteString)，原因=\(error.localizedDescription)")
            errorMessage = "无法暂存网页图片：\(error.localizedDescription)"
            return false
        }
    }

    func cancelPendingCoverImage(forAlbumID albumID: AlbumScanRecord.ID) {
        beginCoverStagingRequest(for: albumID)
        guard pendingCoverURLsByAlbumID[albumID] != nil else { return }
        pendingCoverURLsByAlbumID[albumID] = nil
    }

    func savePendingCoverImage(forAlbumID albumID: AlbumScanRecord.ID) async -> Bool {
        guard !savingCoverAlbumIDs.contains(albumID) else {
            CoverDropDebugLog.write("保存封面：忽略重复保存请求，albumID=\(albumID)")
            return false
        }
        guard let sourceURL = pendingCoverURLsByAlbumID[albumID] else {
            return false
        }
        let stagingGeneration = coverStagingGenerationByAlbumID[albumID]
        let performanceSpan = CoverDropPerformanceLog.begin(
            CoverDropPerformanceOperation.saveCoverImage,
            context: ["albumID": albumID, "phase": "workflow"]
        )
        savingCoverAlbumIDs.insert(albumID)
        defer {
            savingCoverAlbumIDs.remove(albumID)
        }

        let didWrite = await writeCoverImage(from: sourceURL, forAlbumID: albumID)
        if didWrite,
           coverStagingGenerationByAlbumID[albumID] == stagingGeneration,
           pendingCoverURLsByAlbumID[albumID] == sourceURL {
            pendingCoverURLsByAlbumID[albumID] = nil
        }
        performanceSpan?.finish(outcome: didWrite ? .success : .failure)
        return didWrite
    }

    func writeCoverImage(from sourceURL: URL, forAlbumID albumID: AlbumScanRecord.ID) async -> Bool {
        guard let library = selectedLibrary,
              let result = scanResultsByLibraryID[library.id],
              let album = result.albums.first(where: { $0.id == albumID }) else {
            errorMessage = "无法定位要更新的专辑。"
            return false
        }

        let libraryID = library.id
        markInternalCoverWrite(forAlbumFolder: album.folderURL, libraryID: libraryID)

        do {
            CoverDropDebugLog.write(
                "保存封面：开始写入 cover.jpg，albumID=\(albumID)，source=\(sourceURL.path)，albumFolder=\(album.folderURL.path)"
            )
            let writeResult = try await Self.writeCoverImageOffMainActor(
                sourceURL: sourceURL,
                albumFolderURL: album.folderURL,
                libraryBookmarkData: library.bookmarkData,
                folderAccess: environment.folderAccess,
                coverImageWriter: environment.coverImageWriter
            )
            guard case .written(let coverURL) = writeResult else {
                errorMessage = "未找到专辑：\(displayAlbumName(for: album))"
                return false
            }
            CoverDropDebugLog.write(
                "保存封面：写入 cover.jpg 成功，albumID=\(albumID)，coverURL=\(coverURL.path)"
            )

            let previewURL = await Task.detached(priority: .userInitiated) {
                CoverPreviewCache.refreshedPreviewURLForUpdatedCover(coverURL)
            }.value

            replaceAlbumCover(
                albumID: albumID,
                inLibraryID: libraryID,
                with: coverURL,
                previewURL: previewURL
            )

            coverWriteMessagesByAlbumID = [albumID: "已保存封面：\(displayAlbumName(for: album))"]
            scheduleActiveScanCoverUpdate(for: albumID, libraryID: libraryID)
            return true
        } catch {
            CoverDropDebugLog.write(
                "保存封面：写入 cover.jpg 失败，albumID=\(albumID)，source=\(sourceURL.path)，原因=\(error.localizedDescription)"
            )
            errorMessage = "保存封面失败：\(error.localizedDescription)"
            return false
        }
    }

    nonisolated private static func writeCoverImageOffMainActor(
        sourceURL: URL,
        albumFolderURL: URL,
        libraryBookmarkData: Data,
        folderAccess: any FolderAccessing,
        coverImageWriter: any CoverImageWriting
    ) async throws -> OffMainCoverWriteResult {
        let preparation = try await prepareCoverWriteAccess(
            sourceURL: sourceURL,
            albumFolderURL: albumFolderURL,
            libraryBookmarkData: libraryBookmarkData,
            folderAccess: folderAccess
        )
        guard case .ready(let securityScope) = preparation else {
            return .missingAlbumFolder
        }

        do {
            let coverURL = try await Task.detached(priority: .userInitiated) {
                try await coverImageWriter.writeCoverImage(
                    from: sourceURL,
                    toAlbumFolder: albumFolderURL
                )
            }.value
            await releaseCoverWriteAccess(securityScope)
            return .written(coverURL)
        } catch {
            await releaseCoverWriteAccess(securityScope)
            throw error
        }
    }

    nonisolated private static func prepareCoverWriteAccess(
        sourceURL: URL,
        albumFolderURL: URL,
        libraryBookmarkData: Data,
        folderAccess: any FolderAccessing
    ) async throws -> CoverWriteAccessPreparation {
        try await runCoverWritePreparationOffMainActor {
            let didStartSourceAccessing = sourceURL.startAccessingSecurityScopedResource()
            do {
                let libraryURL = try folderAccess.resolveBookmark(libraryBookmarkData)
                let didStartLibraryAccessing = libraryURL.startAccessingSecurityScopedResource()
                let performanceSpan = CoverDropPerformanceLog.begin(
                    CoverDropPerformanceOperation.checkAlbumFolder,
                    context: ["path": albumFolderURL.path]
                )
                guard albumFolderExists(albumFolderURL) else {
                    performanceSpan?.finish(context: ["exists": "false"])
                    if didStartLibraryAccessing {
                        libraryURL.stopAccessingSecurityScopedResource()
                    }
                    if didStartSourceAccessing {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                    return .missingAlbumFolder
                }
                performanceSpan?.finish(context: ["exists": "true"])
                return .ready(CoverWriteSecurityScope(
                    sourceURL: sourceURL,
                    libraryURL: libraryURL,
                    didStartSourceAccessing: didStartSourceAccessing,
                    didStartLibraryAccessing: didStartLibraryAccessing
                ))
            } catch {
                if didStartSourceAccessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
                throw error
            }
        }
    }

    nonisolated static func runCoverWritePreparationOffMainActor<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try work()
                })
            }
        }
    }

    nonisolated private static func releaseCoverWriteAccess(
        _ securityScope: CoverWriteSecurityScope
    ) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if securityScope.didStartLibraryAccessing {
                    securityScope.libraryURL.stopAccessingSecurityScopedResource()
                }
                if securityScope.didStartSourceAccessing {
                    securityScope.sourceURL.stopAccessingSecurityScopedResource()
                }
                continuation.resume()
            }
        }
    }

    nonisolated private static func albumFolderExists(_ folderURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: folderURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    nonisolated static func albumFolderExistsOffMainActor(_ folderURL: URL) async -> Bool {
        let performanceSpan = CoverDropPerformanceLog.begin(
            CoverDropPerformanceOperation.checkAlbumFolder,
            context: ["path": folderURL.path]
        )
        let exists = await runAlbumFolderCheckOffMainActor {
            albumFolderExists(folderURL)
        }
        performanceSpan?.finish(context: ["exists": exists ? "true" : "false"])
        return exists
    }

    nonisolated private static func removeDiscardedStagedCover(at stagedURL: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: stagedURL)
        }.value
    }

    nonisolated static func runAlbumFolderCheckOffMainActor<T: Sendable>(
        _ check: @escaping @Sendable () -> T
    ) async -> T {
        await Task.detached(priority: .userInitiated) {
            check()
        }.value
    }

    nonisolated private static func regularFileExists(_ fileURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: fileURL.path,
            isDirectory: &isDirectory
        ) && !isDirectory.boolValue
    }

    func openAlbumFolderInFinder(albumID: AlbumScanRecord.ID) async {
        FinderAlbumFolderOpenDiagnostics.log("appModel.request albumID=\(albumID)")
        guard !openingAlbumFolderIDs.contains(albumID) else { return }
        guard let selectedLibraryID,
              let album = scanResultsByLibraryID[selectedLibraryID]?.albums.first(where: { $0.id == albumID }) else {
            FinderAlbumFolderOpenDiagnostics.log(
                "appModel.missingAlbum selectedLibraryID=\(selectedLibraryID.map(String.init) ?? "nil") albumID=\(albumID)"
            )
            errorMessage = "当前扫描结果中已没有这张专辑。"
            return
        }

        let folderExists = await Self.albumFolderExistsOffMainActor(album.folderURL)
        FinderAlbumFolderOpenDiagnostics.log(
            "appModel.resolved albumID=\(albumID) libraryID=\(selectedLibraryID) folder=\(album.folderURL.path) folderExists=\(folderExists)"
        )
        openingAlbumFolderIDs.insert(albumID)
        albumFolderOpenMessagesByAlbumID[albumID] = nil
        defer {
            FinderAlbumFolderOpenDiagnostics.log("appModel.finish albumID=\(albumID)")
            openingAlbumFolderIDs.remove(albumID)
        }

        do {
            try await environment.albumFolderOpener.openAlbumFolder(album.folderURL)
            FinderAlbumFolderOpenDiagnostics.log("appModel.success albumID=\(albumID)")
        } catch {
            FinderAlbumFolderOpenDiagnostics.log(
                "appModel.failure albumID=\(albumID) error=\(error.localizedDescription)"
            )
            albumFolderOpenMessagesByAlbumID[albumID] = "无法在 Finder 中显示：\(error.localizedDescription)"
        }
    }

    func splitCueSheetWithXLD(albumID: AlbumScanRecord.ID, cueSheetID: CueSheetRecord.ID) async {
        guard !splittingCueSheetAlbumIDs.contains(albumID) else { return }
        guard let selectedLibraryID,
              let library = libraries.first(where: { $0.id == selectedLibraryID }),
              let album = scanResultsByLibraryID[selectedLibraryID]?.albums.first(where: { $0.id == albumID }) else {
            errorMessage = "当前扫描结果中已没有这张专辑。"
            return
        }
        guard album.audioFiles.count == 1,
              album.issues.contains(where: {
                  if case .singleFileNeedsConfirmation(let hasCue) = $0 { return hasCue }
                  return false
              }) else {
            cueSheetSplitMessagesByAlbumID[albumID] = "这张专辑不是单整轨 CUE，未交给 XLD。"
            return
        }
        guard let cueSheet = album.cueSheets.first(where: { $0.id == cueSheetID }) else {
            cueSheetSplitMessagesByAlbumID[albumID] = "当前扫描结果中已没有这个 CUE 文件。"
            return
        }
        guard Self.regularFileExists(cueSheet.url) else {
            cueSheetSplitMessagesByAlbumID[albumID] = "未找到 CUE 文件：\(cueSheet.relativePath)"
            return
        }

        splittingCueSheetAlbumIDs.insert(albumID)
        cueSheetSplitMessagesByAlbumID[albumID] = nil
        defer {
            splittingCueSheetAlbumIDs.remove(albumID)
        }

        do {
            let libraryURL = try environment.folderAccess.resolveBookmark(library.bookmarkData)
            let didStartAccessing = libraryURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    libraryURL.stopAccessingSecurityScopedResource()
                }
            }

            try await environment.cueSheetSplitter.splitCueSheet(cueSheet.url)
            cueSheetSplitMessagesByAlbumID[albumID] = "已在 XLD 中打开：\(cueSheet.relativePath)"
        } catch {
            cueSheetSplitMessagesByAlbumID[albumID] = "无法用 XLD 分轨：\(error.localizedDescription)"
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
        let performanceSpan = CoverDropPerformanceLog.begin(
            CoverDropPerformanceOperation.updateAlbumCover,
            context: ["albumID": albumID]
        )
        guard let result = scanResultsByLibraryID[libraryID],
              let index = result.albums.firstIndex(where: { $0.id == albumID }) else {
            CoverDropDebugLog.write("封面保存：无法找到专辑，albumID=\(albumID)")
            performanceSpan?.finish(
                outcome: .failure,
                context: ["error": "album_not_found"]
            )
            return
        }
        CoverDropDebugLog.write("封面保存：找到专辑 index=\(index)，coverURL=\(coverURL.path)，lastPathComponent=\(coverURL.lastPathComponent)")
        let album = result.albums[index]
        var albums = result.albums
        albums[index] = AlbumScanRecord(
            folderURL: album.folderURL,
            artistName: album.artistName,
            albumName: album.albumName,
            audioFiles: album.audioFiles,
            cueSheets: album.cueSheets,
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
        let updatedAlbum = albums[index]
        setScanResult(LibraryScanResult(
            albums: albums,
            looseAudioPaths: result.looseAudioPaths
        ), replacingAlbums: [updatedAlbum], for: libraryID)
        performanceSpan?.finish(context: ["albumCount": "\(albums.count)"])
    }

    private func clearTransientState(
        forAlbumID albumID: AlbumScanRecord.ID,
        inLibraryID libraryID: LibraryRecord.ID?
    ) {
        beginCoverStagingRequest(for: albumID)
        pendingCoverURLsByAlbumID[albumID] = nil
        coverWriteMessagesByAlbumID[albumID] = nil
        savingCoverAlbumIDs.remove(albumID)
        albumFolderOpenMessagesByAlbumID[albumID] = nil
        openingAlbumFolderIDs.remove(albumID)
        cueSheetSplitMessagesByAlbumID[albumID] = nil
        splittingCueSheetAlbumIDs.remove(albumID)
        albumNameEnhancementStateByAlbumID[albumID] = nil
        albumNameEnhancementQueue.removeAll { $0.albumID == albumID }

        if let libraryID {
            albumNameSuggestionsByLibraryID[libraryID]?[albumID] = nil
            if albumNameSuggestionsByLibraryID[libraryID]?.isEmpty == true {
                albumNameSuggestionsByLibraryID[libraryID] = nil
            }
            refreshAlbumNameEnhancementStatus(for: libraryID)
            if scanDisplayIndexesByLibraryID[libraryID]?.album(id: albumID) != nil {
                updateScanDisplayIndexForNameEnhancement(
                    albumID: albumID,
                    libraryID: libraryID
                )
            }
        }
    }

    @MainActor
    private func runAlbumNameEnhancementQueue() async {
        defer {
            let snapshotUpdateLibraryIDs = albumNameEnhancementSnapshotUpdateLibraryIDs
            albumNameEnhancementSnapshotUpdateLibraryIDs.removeAll()
            albumNameEnhancementWorkerTask = nil
            finishAlbumNameEnhancementBatch(
                snapshotUpdateLibraryIDs: snapshotUpdateLibraryIDs
            )
        }

        while !Task.isCancelled {
            guard let item = dequeueAlbumNameEnhancementItem() else {
                break
            }

            runningAlbumNameEnhancementItem = item
            albumNameEnhancementStateByAlbumID[item.albumID] = AlbumNameEnhancementAlbumState(
                isQueued: false,
                isRunning: true,
                lastErrorMessage: nil
            )
            refreshAlbumNameEnhancementStatus(for: item.libraryID)

            await processAlbumNameEnhancement(item)

            runningAlbumNameEnhancementItem = nil
            refreshAlbumNameEnhancementStatus(for: item.libraryID)
        }
    }

    private func processAlbumNameEnhancement(_ item: AlbumNameEnhancementQueueItem) async {
        let countsLibraryProgress = item.source == .libraryManual
        var shouldCompleteLibraryProgress = true
        defer {
            if countsLibraryProgress, shouldCompleteLibraryProgress {
                completeAlbumNameEnhancementProgressItem(for: item.libraryID)
            }
        }

        guard let library = libraries.first(where: { $0.id == item.libraryID }) else {
            albumNameEnhancementStateByAlbumID[item.albumID] = nil
            return
        }
        guard let currentResult = scanResultsByLibraryID[item.libraryID] else {
            CoverDropDebugLog.write("Ollama 名称增强：扫描结果已不存在，跳过任务，音乐库=\(library.displayName)")
            albumNameEnhancementStateByAlbumID[item.albumID] = nil
            return
        }
        guard let album = currentResult.albums.first(where: { $0.id == item.albumID }) else {
            CoverDropDebugLog.write("Ollama 名称增强：目标专辑已不存在，跳过，albumID=\(item.albumID)")
            albumNameEnhancementStateByAlbumID[item.albumID] = nil
            return
        }
        guard item.allowCoveredAlbums || Self.isMissingCover(album) else {
            CoverDropDebugLog.write("Ollama 名称增强：自动任务跳过已有封面专辑，专辑=\(album.albumName)")
            albumNameEnhancementStateByAlbumID[item.albumID] = nil
            return
        }

        if countsLibraryProgress {
            updateAlbumNameEnhancementProgressCurrentAlbum(
                for: item.libraryID,
                albumName: displayAlbumName(for: album, in: item.libraryID)
            )
        }

        let input = AlbumNameEnhancementInputBuilder.makeInput(
            for: album,
            libraryRootPath: library.rootPath,
            maxTracks: environment.configuration.localLLM.maxTracksPerAlbum
        )

        CoverDropDebugLog.write(
            "Ollama 名称增强：准备处理，来源=\(item.source.logDescription)，封面状态=\(Self.isMissingCover(album) ? "缺封面" : "已有封面")，原始歌手=\(album.artistName)，原始专辑=\(album.albumName)，路径=\(album.folderURL.path)，输入曲目数=\(input.audioFiles.count)"
        )

        do {
            let requestTask = Task { [albumNameSuggesting = environment.albumNameSuggesting] in
                try await albumNameSuggesting.suggestAlbumName(for: input)
            }
            runningAlbumNameEnhancementRequest = (item, requestTask)
            defer {
                if runningAlbumNameEnhancementRequest?.item.albumID == item.albumID {
                    runningAlbumNameEnhancementRequest = nil
                }
            }
            let suggestion = try await requestTask.value
            guard item.source != .libraryManual || activeAlbumNameEnhancementBatchIDs[item.libraryID] == item.batchID else {
                albumNameEnhancementStateByAlbumID[item.albumID] = nil
                shouldCompleteLibraryProgress = false
                return
            }
            guard scanResultsByLibraryID[item.libraryID]?.albums.contains(where: { $0.id == item.albumID }) == true else {
                CoverDropDebugLog.write("Ollama 名称增强：目标专辑已移除，丢弃返回结果，albumID=\(item.albumID)")
                clearTransientState(forAlbumID: item.albumID, inLibraryID: item.libraryID)
                return
            }
            var suggestions = albumNameSuggestionsByLibraryID[item.libraryID] ?? [:]
            suggestions[album.id] = suggestion
            albumNameSuggestionsByLibraryID[item.libraryID] = suggestions
            albumNameEnhancementStateByAlbumID[item.albumID] = AlbumNameEnhancementAlbumState(
                isQueued: false,
                isRunning: false,
                lastErrorMessage: nil
            )
            albumNameEnhancementStatusByLibraryID[item.libraryID] = AlbumNameEnhancementStatus(
                isRunning: hasPendingAlbumNameEnhancement(for: item.libraryID),
                lastErrorMessage: nil
            )
            updateScanDisplayIndexForNameEnhancement(albumID: item.albumID, libraryID: item.libraryID)
            CoverDropDebugLog.write(
                "Ollama 名称增强：处理成功，来源=\(item.source.logDescription)，\(album.artistName) / \(album.albumName) -> \(suggestion.artistName) / \(suggestion.albumName)"
            )
            albumNameEnhancementSnapshotUpdateLibraryIDs.insert(item.libraryID)
        } catch is CancellationError {
            shouldCompleteLibraryProgress = false
            albumNameEnhancementStateByAlbumID[item.albumID] = nil
            CoverDropDebugLog.write("Ollama 名称增强：任务收到取消，专辑=\(album.albumName)")
        } catch {
            guard scanResultsByLibraryID[item.libraryID]?.albums.contains(where: { $0.id == item.albumID }) == true else {
                CoverDropDebugLog.write("Ollama 名称增强：目标专辑已移除，丢弃失败状态，albumID=\(item.albumID)")
                clearTransientState(forAlbumID: item.albumID, inLibraryID: item.libraryID)
                return
            }
            let message = error.localizedDescription
            albumNameEnhancementStateByAlbumID[item.albumID] = AlbumNameEnhancementAlbumState(
                isQueued: false,
                isRunning: false,
                lastErrorMessage: message
            )
            albumNameEnhancementStatusByLibraryID[item.libraryID] = AlbumNameEnhancementStatus(
                isRunning: hasPendingAlbumNameEnhancement(for: item.libraryID),
                lastErrorMessage: message
            )
            updateScanDisplayIndexForNameEnhancement(albumID: item.albumID, libraryID: item.libraryID)
            CoverDropDebugLog.write(
                "Ollama 名称增强：处理失败，来源=\(item.source.logDescription)，原始歌手=\(album.artistName)，原始专辑=\(album.albumName)，错误=\(message)"
            )
        }
    }

    @discardableResult
    private func enqueueAlbumNameEnhancement(
        _ item: AlbumNameEnhancementQueueItem,
        startsWorker: Bool = true
    ) -> Bool {
        guard runningAlbumNameEnhancementItem?.albumID != item.albumID,
              !albumNameEnhancementQueue.contains(where: { $0.albumID == item.albumID }) else {
            CoverDropDebugLog.write("Ollama 名称增强：专辑已在队列或正在处理，跳过重复请求，albumID=\(item.albumID)")
            return false
        }

        albumNameEnhancementQueue.append(item)
        albumNameEnhancementStateByAlbumID[item.albumID] = AlbumNameEnhancementAlbumState(
            isQueued: true,
            isRunning: false,
            lastErrorMessage: nil
        )
        albumNameEnhancementStatusByLibraryID[item.libraryID] = AlbumNameEnhancementStatus(
            isRunning: true,
            lastErrorMessage: nil
        )
        CoverDropDebugLog.write(
            "Ollama 名称增强：已加入队列，来源=\(item.source.logDescription)，libraryID=\(item.libraryID)，albumID=\(item.albumID)"
        )
        if startsWorker {
            startAlbumNameEnhancementWorkerIfNeeded()
        }
        return true
    }

    private func updateAlbumNameEnhancementProgressCurrentAlbum(
        for libraryID: LibraryRecord.ID,
        albumName: String
    ) {
        guard let progress = albumNameEnhancementProgressByLibraryID[libraryID],
              !progress.isFinished else {
            return
        }

        albumNameEnhancementProgressByLibraryID[libraryID] = AlbumNameEnhancementProgress(
            completedAlbums: progress.completedAlbums,
            totalAlbums: progress.totalAlbums,
            currentAlbumName: albumName
        )
    }

    private func completeAlbumNameEnhancementProgressItem(for libraryID: LibraryRecord.ID) {
        guard let progress = albumNameEnhancementProgressByLibraryID[libraryID],
              progress.completedAlbums < progress.totalAlbums else {
            return
        }

        let completedAlbums = min(progress.completedAlbums + 1, progress.totalAlbums)
        albumNameEnhancementProgressByLibraryID[libraryID] = AlbumNameEnhancementProgress(
            completedAlbums: completedAlbums,
            totalAlbums: progress.totalAlbums,
            currentAlbumName: completedAlbums >= progress.totalAlbums ? nil : progress.currentAlbumName
        )
    }

    private func startAlbumNameEnhancementWorkerIfNeeded() {
        guard albumNameEnhancementWorkerTask == nil else { return }
        albumNameEnhancementWorkerTask = Task { [weak self] in
            await self?.runAlbumNameEnhancementQueue()
        }
    }

    private func dequeueAlbumNameEnhancementItem() -> AlbumNameEnhancementQueueItem? {
        guard !albumNameEnhancementQueue.isEmpty else { return nil }
        let highestPriority = albumNameEnhancementQueue
            .map { $0.source.queuePriority }
            .max() ?? 0
        if let priorityIndex = albumNameEnhancementQueue.firstIndex(where: {
            $0.source.queuePriority == highestPriority
        }) {
            return albumNameEnhancementQueue.remove(at: priorityIndex)
        }
        return albumNameEnhancementQueue.removeFirst()
    }

    private func refreshAlbumNameEnhancementStatus(for libraryID: LibraryRecord.ID) {
        let previousErrorMessage = albumNameEnhancementStatusByLibraryID[libraryID]?.lastErrorMessage
        albumNameEnhancementStatusByLibraryID[libraryID] = AlbumNameEnhancementStatus(
            isRunning: hasPendingAlbumNameEnhancement(for: libraryID),
            lastErrorMessage: previousErrorMessage
        )
    }

    private func hasPendingAlbumNameEnhancement(for libraryID: LibraryRecord.ID) -> Bool {
        runningAlbumNameEnhancementItem?.libraryID == libraryID
            || albumNameEnhancementQueue.contains { $0.libraryID == libraryID }
    }

    nonisolated private static func isMissingCover(_ album: AlbumScanRecord) -> Bool {
        switch album.displayedCover {
        case .none:
            true
        case .some:
            false
        }
    }

    private func cancelAlbumNameEnhancement(
        for libraryID: LibraryRecord.ID,
        clearsSuggestions: Bool = true
    ) {
        CoverDropDebugLog.write("Ollama 名称增强：取消批处理，libraryID=\(libraryID)")
        activeAlbumNameEnhancementBatchIDs[libraryID] = nil
        albumNameEnhancementSnapshotUpdateLibraryIDs.remove(libraryID)
        let queuedAlbumIDs = albumNameEnhancementQueue
            .filter { $0.libraryID == libraryID }
            .map(\.albumID)
        albumNameEnhancementQueue.removeAll { $0.libraryID == libraryID }
        for albumID in queuedAlbumIDs {
            albumNameEnhancementStateByAlbumID[albumID] = nil
        }
        if clearsSuggestions,
           let runningAlbumNameEnhancementItem,
           runningAlbumNameEnhancementItem.libraryID == libraryID {
            runningAlbumNameEnhancementRequest?.task.cancel()
            albumNameEnhancementStateByAlbumID[runningAlbumNameEnhancementItem.albumID] = nil
        }
        if clearsSuggestions || !hasPendingAlbumNameEnhancement(for: libraryID) {
            albumNameEnhancementStatusByLibraryID[libraryID] = nil
        } else {
            refreshAlbumNameEnhancementStatus(for: libraryID)
        }
        if clearsSuggestions {
            albumNameSuggestionsByLibraryID[libraryID] = nil
            albumNameEnhancementProgressByLibraryID[libraryID] = nil
        }
    }

    private func clearLibraryState(for libraryID: LibraryRecord.ID) {
        stopLibraryChangeMonitoring(for: libraryID)
        cancelAlbumNameEnhancement(for: libraryID)
        invalidateCoverStagingRequests(for: libraryID)
        clearScanResult(for: libraryID)
        latestScanSnapshotsByLibraryID[libraryID] = nil
        activeScanSnapshotsByLibraryID[libraryID] = nil
        scanSnapshotMessagesByLibraryID[libraryID] = nil
        loadingScanSnapshotLibraryIDs.remove(libraryID)
        scanSnapshotLoadProgressByLibraryID[libraryID] = nil
        albumNameEnhancementProgressByLibraryID[libraryID] = nil
        realtimeRefreshMessagesByLibraryID[libraryID] = nil
        refreshingLibraryIDs.remove(libraryID)
        pendingRefreshLibraryIDs.remove(libraryID)
        pendingRealtimeRefreshScopesByLibraryID[libraryID] = nil
        ignoredInternalRealtimeChangePathsByLibraryID[libraryID] = nil
    }

    private func releaseAlbumNameSuggestingResourcesIfNeeded() {
        guard environment.configuration.localLLM.unloadAfterBatch,
              let releaser = environment.albumNameSuggesting as? any AlbumNameSuggestingResourceReleasing else {
            return
        }

        Task.detached {
            await releaser.releaseResources()
        }
    }

    private func finishAlbumNameEnhancementBatch(
        snapshotUpdateLibraryIDs: Set<LibraryRecord.ID>
    ) {
        let shouldReleaseResources = environment.configuration.localLLM.unloadAfterBatch
        let releaser = shouldReleaseResources
            ? environment.albumNameSuggesting as? any AlbumNameSuggestingResourceReleasing
            : nil

        Task.detached { [weak self, releaser, snapshotUpdateLibraryIDs] in
            if let releaser {
                await releaser.releaseResources()
            }
            guard !snapshotUpdateLibraryIDs.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                for libraryID in snapshotUpdateLibraryIDs {
                    scheduleActiveScanSnapshotUpdate(for: libraryID)
                }
            }
        }
    }

    private func restartLibraryChangeMonitoringForScannedLibraries() {
        let scannedLibraryIDs = Set(scanResultsByLibraryID.keys)
        for libraryID in Array(libraryChangeMonitorTasksByLibraryID.keys) where !scannedLibraryIDs.contains(libraryID) {
            stopLibraryChangeMonitoring(for: libraryID)
        }

        for library in libraries where scanResultsByLibraryID[library.id] != nil {
            startLibraryChangeMonitoring(for: library)
        }
    }

    private func startLibraryChangeMonitoring(for library: LibraryRecord) {
        guard environment.configuration.realtimeScanRefresh.isEnabled,
              scanResultsByLibraryID[library.id] != nil else {
            return
        }

        stopLibraryChangeMonitoring(for: library.id)
        let environment = environment
        let debounceSeconds = environment.configuration.realtimeScanRefresh.debounceSeconds
        let task = Task { [weak self, environment] in
            do {
                let rootURL = try environment.folderAccess.resolveBookmark(library.bookmarkData)
                let didStartAccessing = rootURL.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccessing {
                        rootURL.stopAccessingSecurityScopedResource()
                    }
                }

                CoverDropDebugLog.write(
                    "实时刷新：准备监听音乐库，名称=\(library.displayName)，路径=\(rootURL.path)，去抖=\(debounceSeconds)秒"
                )

                for try await event in environment.libraryChangeMonitor.events(for: rootURL) {
                    await MainActor.run { [weak self] in
                        self?.handleLibraryChangeEvent(event, for: library.id)
                    }
                }
            } catch is CancellationError {
                CoverDropDebugLog.write("实时刷新：监听任务已取消，音乐库=\(library.displayName)")
            } catch {
                CoverDropDebugLog.write(
                    "实时刷新：监听失败，音乐库=\(library.displayName)，路径=\(library.rootPath)，原因=\(error.localizedDescription)"
                )
                await MainActor.run {
                    self?.realtimeRefreshMessagesByLibraryID[library.id] = "目录变化监听失败：\(error.localizedDescription)"
                }
            }
        }
        libraryChangeMonitorTasksByLibraryID[library.id] = task
    }

    private func stopLibraryChangeMonitoring(for libraryID: LibraryRecord.ID) {
        libraryChangeMonitorTasksByLibraryID[libraryID]?.cancel()
        libraryChangeMonitorTasksByLibraryID[libraryID] = nil
        realtimeRefreshDebounceTasksByLibraryID[libraryID]?.cancel()
        realtimeRefreshDebounceTasksByLibraryID[libraryID] = nil
        libraryChangeMonitorRestartTasksByLibraryID[libraryID]?.cancel()
        libraryChangeMonitorRestartTasksByLibraryID[libraryID] = nil
    }

    private func scheduleRestartLibraryChangeMonitoring(for libraryID: LibraryRecord.ID, delay: TimeInterval) {
        libraryChangeMonitorRestartTasksByLibraryID[libraryID]?.cancel()
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            await MainActor.run { [weak self] in
                guard let self,
                      let library = libraries.first(where: { $0.id == libraryID }) else { return }
                startLibraryChangeMonitoring(for: library)
                CoverDropDebugLog.write("实时刷新：保存封面后恢复监听，音乐库=\(library.displayName)")
            }
        }
        libraryChangeMonitorRestartTasksByLibraryID[libraryID] = task
    }

    private func handleLibraryChangeEvent(
        _ event: LibraryChangeEvent,
        for libraryID: LibraryRecord.ID
    ) {
        guard environment.configuration.realtimeScanRefresh.isEnabled else { return }

        guard let refreshScope = realtimeRefreshScope(for: event, libraryID: libraryID) else {
            CoverDropDebugLog.write(
                "实时刷新：忽略无关目录事件，libraryID=\(libraryID)，路径=\(event.changedPaths.prefix(6).joined(separator: " | "))"
            )
            return
        }

        realtimeRefreshMessagesByLibraryID[libraryID] = refreshScope.pendingMessage
        CoverDropDebugLog.write(
            "实时刷新：收到有效目录变化，libraryID=\(libraryID)，scope=\(refreshScope.logDescription)，路径数=\(event.changedPaths.count)，等待去抖"
        )
        scheduleDebouncedRealtimeRefresh(for: libraryID, scope: refreshScope)
    }

    private func scheduleDebouncedRealtimeRefresh(
        for libraryID: LibraryRecord.ID,
        scope: RealtimeRefreshScope
    ) {
        mergePendingRealtimeRefreshScope(scope, for: libraryID)
        realtimeRefreshDebounceTasksByLibraryID[libraryID]?.cancel()
        let debounceSeconds = environment.configuration.realtimeScanRefresh.debounceSeconds
        realtimeRefreshDebounceTasksByLibraryID[libraryID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(debounceSeconds * 1_000_000_000))
            } catch {
                return
            }

            await self?.refreshLibraryAfterFileChange(libraryID: libraryID)
        }
    }

    private func refreshLibraryAfterFileChange(libraryID: LibraryRecord.ID) async {
        guard !refreshingLibraryIDs.contains(libraryID) else {
            pendingRefreshLibraryIDs.insert(libraryID)
            CoverDropDebugLog.write("实时刷新：已有刷新在运行，合并后续事件，libraryID=\(libraryID)")
            realtimeRefreshMessagesByLibraryID[libraryID] = "检测到有效目录变化，当前刷新完成后会继续合并刷新。"
            return
        }

        refreshingLibraryIDs.insert(libraryID)
        defer {
            refreshingLibraryIDs.remove(libraryID)
            pendingRefreshLibraryIDs.remove(libraryID)
        }

        while true {
            pendingRefreshLibraryIDs.remove(libraryID)
            guard let scope = consumePendingRealtimeRefreshScope(for: libraryID) else { break }
            await performLibraryRefreshAfterFileChange(libraryID: libraryID, scope: scope)

            guard pendingRefreshLibraryIDs.contains(libraryID) else { break }
            CoverDropDebugLog.write("实时刷新：刷新期间收到新事件，开始追加一轮合并刷新，libraryID=\(libraryID)")
        }
    }

    private func performLibraryRefreshAfterFileChange(
        libraryID: LibraryRecord.ID,
        scope: RealtimeRefreshScope
    ) async {
        guard let library = libraries.first(where: { $0.id == libraryID }) else { return }
        guard scanningLibraryID == nil else {
            CoverDropDebugLog.write("实时刷新：当前正在扫描，跳过本次自动刷新，libraryID=\(libraryID)")
            realtimeRefreshMessagesByLibraryID[libraryID] = "检测到目录变化，但当前正在扫描，已跳过本次自动刷新。"
            return
        }

        let startedAt = Date()
        let previousResult = scanResultsByLibraryID[libraryID]
        realtimeRefreshMessagesByLibraryID[libraryID] = scope.runningMessage

        let albumIDs: Set<AlbumScanRecord.ID>
        switch scope {
        case .albums(let changedAlbumIDs):
            albumIDs = changedAlbumIDs
        }

        await refreshChangedAlbums(
            albumIDs: albumIDs,
            library: library,
            previousResult: previousResult,
            startedAt: startedAt
        )
    }

    private func refreshChangedAlbums(
        albumIDs: Set<AlbumScanRecord.ID>,
        library: LibraryRecord,
        previousResult: LibraryScanResult?,
        startedAt: Date
    ) async {
        guard !albumIDs.isEmpty else {
            realtimeRefreshMessagesByLibraryID[library.id] = "没有可局部刷新的专辑，已避免自动全量扫描。"
            return
        }

        guard let previousResult else {
            realtimeRefreshMessagesByLibraryID[library.id] = "当前没有扫描结果，已避免自动全量扫描。请手动扫描音乐库。"
            return
        }

        guard let albumRescanner = environment.libraryScanner as? any AlbumRescanning else {
            realtimeRefreshMessagesByLibraryID[library.id] = "当前扫描器不支持局部刷新，已避免自动全量扫描。请手动扫描音乐库。"
            CoverDropDebugLog.write(
                "实时刷新：扫描器不支持局部刷新，跳过自动全量扫描，音乐库=\(library.displayName)"
            )
            return
        }

        var albums = previousResult.albums
        let refreshTargets = albums.enumerated().compactMap { index, album -> AlbumRefreshTarget? in
            guard albumIDs.contains(album.id) else { return nil }
            return AlbumRefreshTarget(index: index, album: album)
        }

        do {
            let rootURL = try environment.folderAccess.resolveBookmark(library.bookmarkData)
            let didStartAccessing = rootURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    rootURL.stopAccessingSecurityScopedResource()
                }
            }

            let refreshedAlbums = try await Self.rescanAlbumsConcurrently(
                targets: refreshTargets,
                albumRescanner: albumRescanner,
                maxConcurrentAlbums: environment.configuration.scan.maxConcurrentAlbums
            )

            guard !refreshedAlbums.isEmpty else {
                realtimeRefreshMessagesByLibraryID[library.id] = "变化路径未命中当前专辑列表，已避免自动全量扫描。请在需要时手动重新扫描音乐库。"
                return
            }

            for refreshedAlbum in refreshedAlbums {
                let oldAlbum = albums[refreshedAlbum.index]
                invalidateCoverImages(before: oldAlbum, after: refreshedAlbum.album)
                albums[refreshedAlbum.index] = refreshedAlbum.album
            }

            let result = LibraryScanResult(
                albums: albums,
                looseAudioPaths: previousResult.looseAudioPaths
            )
            let retainedSuggestions = retainedAlbumNameSuggestions(
                for: library,
                previousResult: previousResult,
                refreshedResult: result
            )
            cancelAlbumNameEnhancement(for: library.id, clearsSuggestions: false)
            albumNameSuggestionsByLibraryID[library.id] = retainedSuggestions
            setScanResult(
                result,
                replacingAlbums: refreshedAlbums.map(\.album),
                for: library.id
            )
            scheduleActiveScanSnapshotUpdate(for: library.id)

            let elapsedText = Self.formatDuration(since: startedAt)
            realtimeRefreshMessagesByLibraryID[library.id] = "已局部刷新：\(refreshedAlbums.count) 张专辑。"
            CoverDropDebugLog.write(
                "实时刷新：局部专辑刷新成功，音乐库=\(library.displayName)，耗时=\(elapsedText)，专辑数=\(refreshedAlbums.count)，并发上限=\(environment.configuration.scan.maxConcurrentAlbums)"
            )
        } catch {
            let elapsedText = Self.formatDuration(since: startedAt)
            CoverDropDebugLog.write(
                "实时刷新：局部专辑刷新失败，已保留旧扫描结果且不退回全量重扫，音乐库=\(library.displayName)，耗时=\(elapsedText)，原因=\(error.localizedDescription)"
            )
            realtimeRefreshMessagesByLibraryID[library.id] = "局部刷新失败，已保留旧扫描结果：\(error.localizedDescription)"
        }
    }

    nonisolated private static func rescanAlbumsConcurrently(
        targets: [AlbumRefreshTarget],
        albumRescanner: any AlbumRescanning,
        maxConcurrentAlbums: Int
    ) async throws -> [AlbumRefreshResult] {
        guard !targets.isEmpty else { return [] }

        let concurrentLimit = min(max(1, maxConcurrentAlbums), targets.count)
        return try await Task.detached(priority: .userInitiated) {
            var refreshedAlbums: [AlbumRefreshResult] = []
            refreshedAlbums.reserveCapacity(targets.count)

            try await withThrowingTaskGroup(of: AlbumRefreshResult.self) { group in
                var nextIndex = 0

                while nextIndex < concurrentLimit {
                    let target = targets[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        AlbumRefreshResult(
                            index: target.index,
                            album: try await albumRescanner.rescanAlbum(target.album) { _ in }
                        )
                    }
                }

                while let refreshedAlbum = try await group.next() {
                    refreshedAlbums.append(refreshedAlbum)

                    if nextIndex < targets.count {
                        let target = targets[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            AlbumRefreshResult(
                                index: target.index,
                                album: try await albumRescanner.rescanAlbum(target.album) { _ in }
                            )
                        }
                    }
                }
            }

            return refreshedAlbums
        }.value
    }

    private func invalidateCoverImages(
        before oldAlbum: AlbumScanRecord,
        after newAlbum: AlbumScanRecord
    ) {
        if let oldURL = oldAlbum.displayedCover?.displayURL {
            CoverPreviewCache.invalidateImageCache(for: oldURL)
        }
        if let newURL = newAlbum.displayedCover?.displayURL {
            CoverPreviewCache.invalidateImageCache(for: newURL)
        }
    }

    private func realtimeRefreshScope(
        for event: LibraryChangeEvent,
        libraryID: LibraryRecord.ID
    ) -> RealtimeRefreshScope? {
        let normalizedPaths = normalizedChangedPaths(from: event)
            .filter(isRelevantLibraryChangePath)
            .filter { !isIgnoredInternalRealtimeChangePath($0, libraryID: libraryID) }
        guard !normalizedPaths.isEmpty else { return nil }

        guard let result = scanResultsByLibraryID[libraryID] else {
            return nil
        }

        var albumIDs: Set<AlbumScanRecord.ID> = []
        for path in normalizedPaths {
            let url = URL(fileURLWithPath: path)
            if url.pathExtension.isEmpty,
               shouldIgnoreDirectoryMetadataChange(at: url, eventRootURL: event.rootURL, result: result) {
                continue
            }
            guard let albumID = albumID(containing: url, in: result) else {
                realtimeRefreshMessagesByLibraryID[libraryID] = "检测到当前扫描结果之外的目录变化，已避免自动全量扫描。请在需要时手动重新扫描音乐库。"
                CoverDropDebugLog.write(
                    "实时刷新：变化路径不属于已知专辑，避免自动全量扫描，libraryID=\(libraryID)，路径=\(path)"
                )
                continue
            }
            albumIDs.insert(albumID)
        }

        return albumIDs.isEmpty ? nil : .albums(albumIDs)
    }

    private func markInternalCoverWrite(
        forAlbumFolder albumFolderURL: URL,
        libraryID: LibraryRecord.ID
    ) {
        let albumFolderPath = albumFolderURL.standardizedFileURL.path
        let coverPath = albumFolderURL
            .appendingPathComponent("cover.jpg", isDirectory: false)
            .standardizedFileURL
            .path
        let expiresAt = Date().addingTimeInterval(Self.internalRealtimeChangeIgnoreSeconds)
        var ignoredPaths = ignoredInternalRealtimeChangePathsByLibraryID[libraryID] ?? [:]
        ignoredPaths[albumFolderPath] = expiresAt
        ignoredPaths[coverPath] = expiresAt
        ignoredInternalRealtimeChangePathsByLibraryID[libraryID] = ignoredPaths
        CoverDropDebugLog.write(
            "实时刷新：记录 App 内部封面写入，后续监听事件将忽略，libraryID=\(libraryID)，专辑路径=\(albumFolderPath)，封面路径=\(coverPath)"
        )
    }

    private func isIgnoredInternalRealtimeChangePath(
        _ path: String,
        libraryID: LibraryRecord.ID
    ) -> Bool {
        let now = Date()
        guard var ignoredPaths = ignoredInternalRealtimeChangePathsByLibraryID[libraryID] else {
            return false
        }

        ignoredPaths = ignoredPaths.filter { _, expiresAt in expiresAt > now }
        ignoredInternalRealtimeChangePathsByLibraryID[libraryID] = ignoredPaths.isEmpty ? nil : ignoredPaths

        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard ignoredPaths[normalizedPath] != nil else { return false }
        CoverDropDebugLog.write(
            "实时刷新：忽略 App 内部封面写入事件，libraryID=\(libraryID)，路径=\(normalizedPath)"
        )
        return true
    }

    private func shouldIgnoreDirectoryMetadataChange(
        at url: URL,
        eventRootURL: URL,
        result: LibraryScanResult
    ) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = eventRootURL.standardizedFileURL.path
        if path == rootPath {
            return true
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        return result.albums.contains { album in
            let albumPath = album.folderURL.standardizedFileURL.path
            return path == albumPath || albumPath.hasPrefix(path + "/")
        }
    }

    private func normalizedChangedPaths(from event: LibraryChangeEvent) -> [String] {
        event.changedPaths.map { path in
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path).standardizedFileURL.path
            }
            return event.rootURL
                .appendingPathComponent(path)
                .standardizedFileURL
                .path
        }
    }

    private func isRelevantLibraryChangePath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent
        guard !fileName.isEmpty,
              !fileName.hasPrefix("."),
              !fileName.hasSuffix("~"),
              fileName != ".DS_Store" else {
            return false
        }

        let ext = url.pathExtension.lowercased()
        if ext.isEmpty {
            return true
        }
        return Self.realtimeRelevantExtensions.contains(ext)
    }

    private func albumID(
        containing url: URL,
        in result: LibraryScanResult
    ) -> AlbumScanRecord.ID? {
        let path = url.standardizedFileURL.path
        return result.albums
            .filter { album in
                let albumPath = album.folderURL.standardizedFileURL.path
                return path == albumPath || path.hasPrefix(albumPath + "/")
            }
            .max { lhs, rhs in
                lhs.folderURL.standardizedFileURL.path.count < rhs.folderURL.standardizedFileURL.path.count
            }?
            .id
    }

    private func mergePendingRealtimeRefreshScope(
        _ scope: RealtimeRefreshScope,
        for libraryID: LibraryRecord.ID
    ) {
        if let existing = pendingRealtimeRefreshScopesByLibraryID[libraryID] {
            pendingRealtimeRefreshScopesByLibraryID[libraryID] = existing.merged(with: scope)
        } else {
            pendingRealtimeRefreshScopesByLibraryID[libraryID] = scope
        }
    }

    private func consumePendingRealtimeRefreshScope(
        for libraryID: LibraryRecord.ID
    ) -> RealtimeRefreshScope? {
        let scope = pendingRealtimeRefreshScopesByLibraryID[libraryID]
        pendingRealtimeRefreshScopesByLibraryID[libraryID] = nil
        return scope
    }

    private nonisolated static let coverImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff", "bmp", "gif", "avif"
    ]

    private nonisolated static let audioExtensions: Set<String> = [
        "aac", "aiff", "alac", "ape", "dsf", "dff", "flac", "m4a", "mp3", "ogg", "opus", "wav", "wv"
    ]

    private nonisolated static let realtimeRelevantExtensions: Set<String> =
        coverImageExtensions.union(audioExtensions).union(["cue", "m3u", "m3u8", "log", "txt"])

    private nonisolated static let internalRealtimeChangeIgnoreSeconds: TimeInterval = 10

    private func retainedAlbumNameSuggestions(
        for library: LibraryRecord,
        previousResult: LibraryScanResult?,
        refreshedResult: LibraryScanResult
    ) -> [AlbumScanRecord.ID: AlbumNameSuggestion] {
        guard let previousResult else { return [:] }
        let previousAlbumsByID = Dictionary(uniqueKeysWithValues: previousResult.albums.map { ($0.id, $0) })
        let existingSuggestions = albumNameSuggestionsByLibraryID[library.id] ?? [:]

        return refreshedResult.albums.reduce(into: [:]) { retained, album in
            guard let previousAlbum = previousAlbumsByID[album.id],
                  albumNameEnhancementFingerprint(for: previousAlbum) == albumNameEnhancementFingerprint(for: album),
                  let suggestion = existingSuggestions[album.id] else {
                return
            }
            retained[album.id] = suggestion
        }
    }

    private func albumNameEnhancementFingerprint(
        for album: AlbumScanRecord
    ) -> AlbumNameEnhancementFingerprint {
        AlbumNameEnhancementFingerprint(
            artistName: album.artistName,
            albumName: album.albumName,
            audioRelativePaths: album.audioFiles.map(\.relativePath).sorted()
        )
    }

    private func refreshLatestScanSnapshotsInBackground() {
        let libraryIDs = Set(libraries.map(\.id))
        guard !libraryIDs.isEmpty else { return }

        loadingScanSnapshotLibraryIDs.formUnion(libraryIDs)
        Task { [weak self] in
            await self?.refreshLatestScanSnapshots()
        }
    }

    private func refreshLatestScanSnapshots() async {
        for library in libraries {
            await refreshLatestScanSnapshot(for: library)
        }
    }

    private func refreshLatestScanSnapshot(for library: LibraryRecord) async {
        loadingScanSnapshotLibraryIDs.insert(library.id)
        defer {
            loadingScanSnapshotLibraryIDs.remove(library.id)
        }

        do {
            latestScanSnapshotsByLibraryID[library.id] = try await environment.scanSnapshotStore.latestSnapshot(for: library)
        } catch {
            CoverDropDebugLog.write(
                "扫描快照：查找最近快照失败，音乐库=\(library.displayName)，路径=\(library.rootPath)，原因=\(error.localizedDescription)"
            )
            scanSnapshotMessagesByLibraryID[library.id] = "查找历史扫描快照失败：\(error.localizedDescription)"
        }
    }

    private func saveNewScanSnapshot(for library: LibraryRecord, result: LibraryScanResult) async {
        do {
            let createdAt = Date.now
            let suggestions = albumNameSuggestionsByLibraryID[library.id] ?? [:]
            let status = albumNameEnhancementStatusByLibraryID[library.id]
            let snapshotStore = environment.scanSnapshotStore
            let summary = try await Task.detached(priority: .utility) {
                let snapshot = Self.makeScanSnapshot(
                    for: library,
                    result: result,
                    createdAt: createdAt,
                    albumNameSuggestions: suggestions,
                    albumNameEnhancementStatus: status
                )
                return try await snapshotStore.saveNewSnapshot(snapshot)
            }.value
            latestScanSnapshotsByLibraryID[library.id] = summary
            activeScanSnapshotsByLibraryID[library.id] = summary
            scanSnapshotMessagesByLibraryID[library.id] = "已保存扫描快照：\(summary.fileURL.lastPathComponent)"
        } catch {
            CoverDropDebugLog.write(
                "扫描快照：保存失败，音乐库=\(library.displayName)，路径=\(library.rootPath)，原因=\(error.localizedDescription)"
            )
            scanSnapshotMessagesByLibraryID[library.id] = "扫描已完成，但保存快照失败：\(error.localizedDescription)"
        }
    }

    private func scheduleActiveScanSnapshotUpdate(for libraryID: LibraryRecord.ID) {
        guard let library = libraries.first(where: { $0.id == libraryID }),
              let result = scanResultsByLibraryID[libraryID] else {
            return
        }

        let createdAt = activeScanSnapshotsByLibraryID[libraryID]?.createdAt ?? .now
        let activeSummary = activeScanSnapshotsByLibraryID[libraryID]
        let suggestions = albumNameSuggestionsByLibraryID[libraryID] ?? [:]
        let status = albumNameEnhancementStatusByLibraryID[libraryID]
        let snapshotStore = environment.scanSnapshotStore
        let updateQueue = scanSnapshotUpdateQueue

        Task { [weak self] in
            await updateQueue.submit(libraryID: libraryID) { [weak self, snapshotStore] in
                do {
                    let summary = try await Self.persistFullScanSnapshot(
                        library: library,
                        result: result,
                        createdAt: createdAt,
                        activeSummary: activeSummary,
                        suggestions: suggestions,
                        status: status,
                        snapshotStore: snapshotStore
                    )
                    await self?.publishScanSnapshotUpdate(summary, for: libraryID)
                } catch {
                    await self?.publishScanSnapshotUpdateFailure(error, for: libraryID)
                }
            }
        }
    }

    private func scheduleActiveScanCoverUpdate(
        for albumID: AlbumScanRecord.ID,
        libraryID: LibraryRecord.ID
    ) {
        guard let library = libraries.first(where: { $0.id == libraryID }),
              let result = scanResultsByLibraryID[libraryID],
              let album = result.albums.first(where: { $0.id == albumID }) else {
            return
        }

        let createdAt = activeScanSnapshotsByLibraryID[libraryID]?.createdAt ?? .now
        let activeSummary = activeScanSnapshotsByLibraryID[libraryID]
        let suggestions = albumNameSuggestionsByLibraryID[libraryID] ?? [:]
        let status = albumNameEnhancementStatusByLibraryID[libraryID]
        let snapshotStore = environment.scanSnapshotStore
        let updateQueue = scanSnapshotUpdateQueue
        let cover = album.displayedCover.map(ScanSnapshot.Cover.init(cover:))

        Task { [weak self] in
            await updateQueue.submit(libraryID: libraryID) { [weak self, snapshotStore] in
                do {
                    let summary: ScanSnapshotSummary
                    if let activeSummary,
                       let coverSnapshotStore = snapshotStore as? any AlbumCoverSnapshotUpdating {
                        let performanceSpan = CoverDropPerformanceLog.begin(
                            CoverDropPerformanceOperation.updateScanSnapshot,
                            context: [
                                "albumID": albumID,
                                "libraryID": libraryID.uuidString,
                                "mode": "incremental"
                            ]
                        )
                        do {
                            summary = try await coverSnapshotStore.updateAlbumCover(
                                cover,
                                forAlbumID: albumID,
                                at: activeSummary.fileURL,
                                expectedLibrary: library
                            )
                            performanceSpan?.finish()
                        } catch {
                            performanceSpan?.finish(
                                outcome: .failure,
                                context: ["error": error.localizedDescription]
                            )
                            CoverDropDebugLog.write(
                                "扫描快照：封面增量更新失败，回退全量更新，albumID=\(albumID)，原因=\(error.localizedDescription)"
                            )
                            summary = try await Self.persistFullScanSnapshot(
                                library: library,
                                result: result,
                                createdAt: createdAt,
                                activeSummary: activeSummary,
                                suggestions: suggestions,
                                status: status,
                                snapshotStore: snapshotStore
                            )
                        }
                    } else {
                        summary = try await Self.persistFullScanSnapshot(
                            library: library,
                            result: result,
                            createdAt: createdAt,
                            activeSummary: activeSummary,
                            suggestions: suggestions,
                            status: status,
                            snapshotStore: snapshotStore
                        )
                    }
                    await self?.publishScanSnapshotUpdate(summary, for: libraryID)
                } catch {
                    await self?.publishScanSnapshotUpdateFailure(error, for: libraryID)
                }
            }
        }
    }

    private nonisolated static func persistFullScanSnapshot(
        library: LibraryRecord,
        result: LibraryScanResult,
        createdAt: Date,
        activeSummary: ScanSnapshotSummary?,
        suggestions: [AlbumScanRecord.ID: AlbumNameSuggestion],
        status: AlbumNameEnhancementStatus?,
        snapshotStore: any ScanSnapshotStoring
    ) async throws -> ScanSnapshotSummary {
        let performanceSpan = CoverDropPerformanceLog.begin(
            CoverDropPerformanceOperation.updateScanSnapshot,
            context: [
                "albumCount": "\(result.albums.count)",
                "libraryID": library.id.uuidString,
                "mode": "full"
            ]
        )
        let snapshot = makeScanSnapshot(
            for: library,
            result: result,
            createdAt: createdAt,
            albumNameSuggestions: suggestions,
            albumNameEnhancementStatus: status
        )
        do {
            let summary: ScanSnapshotSummary
            if let activeSummary {
                summary = try await snapshotStore.replaceSnapshot(snapshot, at: activeSummary.fileURL)
            } else {
                summary = try await snapshotStore.saveNewSnapshot(snapshot)
            }
            performanceSpan?.finish()
            return summary
        } catch {
            performanceSpan?.finish(
                outcome: .failure,
                context: ["error": error.localizedDescription]
            )
            throw error
        }
    }

    private func publishScanSnapshotUpdate(
        _ summary: ScanSnapshotSummary,
        for libraryID: LibraryRecord.ID
    ) {
        guard libraries.contains(where: { $0.id == libraryID }) else { return }
        latestScanSnapshotsByLibraryID[libraryID] = summary
        activeScanSnapshotsByLibraryID[libraryID] = summary
        scanSnapshotMessagesByLibraryID[libraryID] = "已更新扫描快照：\(summary.fileURL.lastPathComponent)"
    }

    private func publishScanSnapshotUpdateFailure(
        _ error: any Error,
        for libraryID: LibraryRecord.ID
    ) {
        CoverDropDebugLog.write(
            "扫描快照：后台更新失败，libraryID=\(libraryID)，原因=\(error.localizedDescription)"
        )
        scanSnapshotMessagesByLibraryID[libraryID] = "更新扫描快照失败：\(error.localizedDescription)"
    }

    private func makeScanSnapshot(
        for library: LibraryRecord,
        result: LibraryScanResult,
        createdAt: Date
    ) -> ScanSnapshot {
        Self.makeScanSnapshot(
            for: library,
            result: result,
            createdAt: createdAt,
            albumNameSuggestions: albumNameSuggestionsByLibraryID[library.id] ?? [:],
            albumNameEnhancementStatus: albumNameEnhancementStatusByLibraryID[library.id]
        )
    }

    private nonisolated static func makeScanSnapshot(
        for library: LibraryRecord,
        result: LibraryScanResult,
        createdAt: Date,
        albumNameSuggestions: [AlbumScanRecord.ID: AlbumNameSuggestion],
        albumNameEnhancementStatus: AlbumNameEnhancementStatus?
    ) -> ScanSnapshot {
        ScanSnapshot(
            createdAt: createdAt,
            library: ScanSnapshot.Library(library: library),
            scanResult: ScanSnapshot.Result(result: result),
            albumNameEnhancement: ScanSnapshot.AlbumNameEnhancement(
                suggestionsByAlbumID: albumNameSuggestions,
                status: albumNameEnhancementStatus
            )
        )
    }

    nonisolated private static func formatDuration(since startedAt: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(startedAt))
    }
}

private struct AlbumRefreshTarget: Sendable {
    let index: Int
    let album: AlbumScanRecord
}

private struct AlbumRefreshResult: Sendable {
    let index: Int
    let album: AlbumScanRecord
}

private struct AlbumNameEnhancementFingerprint: Hashable {
    let artistName: String
    let albumName: String
    let audioRelativePaths: [String]
}
