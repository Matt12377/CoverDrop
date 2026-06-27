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
    let coverImageWriter: any CoverImageWriting

    init(
        configuration: AppConfiguration = .live,
        libraryStore: any LibraryStore,
        folderAccess: any FolderAccessing,
        roleProber: any DirectoryRoleProbing,
        libraryScanner: any LibraryScanning,
        coverImageWriter: any CoverImageWriting
    ) {
        self.configuration = configuration
        self.libraryStore = libraryStore
        self.folderAccess = folderAccess
        self.roleProber = roleProber
        self.libraryScanner = libraryScanner
        self.coverImageWriter = coverImageWriter
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
            coverImageWriter: ImageIOCoverImageWriter()
        )
    }()
}
