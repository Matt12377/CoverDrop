import Foundation

/// 应用依赖的统一装配入口。
///
/// 后续阶段的目录扫描、标签读取和数据库服务都从这里注入，
/// 避免界面直接创建基础设施对象，也方便测试替换为临时实现。
struct AppEnvironment: Sendable {
    let configuration: AppConfiguration
    let libraryStore: any LibraryStore
    let folderAccess: any FolderAccessing
    let roleProber: any DirectoryRoleProbing
    let libraryScanner: any LibraryScanning
    let libraryChangeMonitor: any LibraryChangeMonitoring
    let coverImageWriter: any CoverImageWriting
    let coverDetector: any CoverDetecting
    let albumNameSuggesting: any AlbumNameSuggesting
    let scanSnapshotStore: any ScanSnapshotStoring

    init(
        configuration: AppConfiguration = .live,
        libraryStore: any LibraryStore,
        folderAccess: any FolderAccessing,
        roleProber: any DirectoryRoleProbing,
        libraryScanner: any LibraryScanning,
        libraryChangeMonitor: any LibraryChangeMonitoring = DisabledLibraryChangeMonitor(),
        coverImageWriter: any CoverImageWriting,
        coverDetector: any CoverDetecting = ImageIOCoverDetector(),
        albumNameSuggesting: any AlbumNameSuggesting = DisabledAlbumNameSuggesting(),
        scanSnapshotStore: any ScanSnapshotStoring = DisabledScanSnapshotStore()
    ) {
        self.configuration = configuration
        self.libraryStore = libraryStore
        self.folderAccess = folderAccess
        self.roleProber = roleProber
        self.libraryScanner = libraryScanner
        self.libraryChangeMonitor = libraryChangeMonitor
        self.coverImageWriter = coverImageWriter
        self.coverDetector = coverDetector
        self.albumNameSuggesting = albumNameSuggesting
        self.scanSnapshotStore = scanSnapshotStore
    }

    static let live: AppEnvironment = {
        let configuration = AppConfiguration.live
        return AppEnvironment(
            configuration: configuration,
            libraryStore: UserDefaultsLibraryStore(),
            folderAccess: SecurityScopedFolderAccess(),
            roleProber: StructureRoleProber(),
            libraryScanner: FileSystemLibraryScanner(
                metadataReader: TagLibMetadataReader(),
                coverDetector: ImageIOCoverDetector(),
                maxConcurrentAlbums: configuration.scan.maxConcurrentAlbums
            ),
            libraryChangeMonitor: FSEventsLibraryChangeMonitor(),
            coverImageWriter: ImageIOCoverImageWriter(),
            coverDetector: ImageIOCoverDetector(),
            albumNameSuggesting: OllamaAlbumNameSuggesting(
                baseURL: configuration.localLLM.baseURL,
                model: configuration.localLLM.model,
                requestTimeoutSeconds: configuration.localLLM.requestTimeoutSeconds,
                keepAlive: configuration.localLLM.batchKeepAlive
            ),
            scanSnapshotStore: FileScanSnapshotStore(
                directoryURL: configuration.scanDatabases.directoryURL
            )
        )
    }()
}
