import Foundation

final class FileScanSnapshotStore: ScanSnapshotStoring, @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let timeZone: TimeZone

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        timeZone: TimeZone = .current
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.timeZone = timeZone
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
            throw FileScanSnapshotStoreError.outsideSnapshotDirectory(fileURL.path)
        }

        let stableFileURL = stableDatabaseFileURL(for: snapshot.library)
        try write(snapshot, to: stableFileURL)
        return summary(for: snapshot, fileURL: stableFileURL)
    }

    func latestSnapshot(for library: LibraryRecord) async throws -> ScanSnapshotSummary? {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return nil }

        let fileURL = stableDatabaseFileURL(for: library)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        let snapshot = try readUncheckedSnapshot(at: fileURL)
        let expectedRootPath = Self.normalizedPath(library.rootPath)
        guard Self.normalizedPath(snapshot.library.rootPath) == expectedRootPath,
              snapshot.library.role == library.role else {
            throw FileScanSnapshotStoreError.stableFileLibraryMismatch(fileURL.path)
        }
        return summary(for: snapshot, fileURL: fileURL)
    }

    func loadSnapshot(at fileURL: URL, expectedLibrary: LibraryRecord) async throws -> ScanSnapshot {
        let snapshot = try readUncheckedSnapshot(at: fileURL)
        guard Self.isSupportedSchemaVersion(snapshot.schemaVersion) else {
            throw FileScanSnapshotStoreError.unsupportedSchemaVersion(
                actual: snapshot.schemaVersion,
                supported: ScanSnapshot.currentSchemaVersion
            )
        }

        let expectedRootPath = Self.normalizedPath(expectedLibrary.rootPath)
        guard Self.normalizedPath(snapshot.library.rootPath) == expectedRootPath else {
            throw FileScanSnapshotStoreError.libraryRootMismatch(
                expected: expectedRootPath,
                actual: snapshot.library.rootPath
            )
        }

        guard snapshot.library.role == expectedLibrary.role else {
            throw FileScanSnapshotStoreError.libraryRoleMismatch(
                expected: expectedLibrary.role.displayName,
                actual: snapshot.library.role.displayName
            )
        }

        return snapshot
    }

    private func createDirectoryIfNeeded() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func stableDatabaseFileURL(for library: LibraryRecord) -> URL {
        directoryURL.appendingPathComponent(
            Self.stableDatabaseFileName(
                displayName: library.displayName,
                rootPath: library.rootPath,
                role: library.role
            ),
            isDirectory: false
        )
    }

    private func stableDatabaseFileURL(for library: ScanSnapshot.Library) -> URL {
        directoryURL.appendingPathComponent(
            Self.stableDatabaseFileName(
                displayName: library.displayName,
                rootPath: library.rootPath,
                role: library.role
            ),
            isDirectory: false
        )
    }

    private func write(_ snapshot: ScanSnapshot, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        CoverDropDebugLog.write("扫描快照：已写入 \(fileURL.path)")
    }

    private func readUncheckedSnapshot(at fileURL: URL) throws -> ScanSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScanSnapshot.self, from: Data(contentsOf: fileURL))
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

    nonisolated static func databaseFileName(
        displayName: String,
        createdAt: Date,
        timeZone: TimeZone = .current
    ) -> String {
        "\(safeFileNameStem(displayName))-\(timestamp(createdAt, timeZone: timeZone)).db"
    }

    nonisolated static func stableDatabaseFileName(
        displayName: String,
        rootPath: String,
        role: LibraryRole
    ) -> String {
        let hashSource = "\(role.rawValue)\u{0}\(normalizedPath(rootPath))"
        return "\(safeFileNameStem(displayName))-\(role.rawValue)-\(stableHashHex(hashSource)).db"
    }

    nonisolated static func safeFileNameStem(_ displayName: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.controlCharacters)
            .union(.newlines)
        let parts = displayName
            .components(separatedBy: disallowed)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let sanitized = parts.joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        guard !sanitized.isEmpty else { return "未命名数据库" }
        if sanitized.count <= 80 { return sanitized }
        return String(sanitized.prefix(80))
    }

    nonisolated private static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    nonisolated private static func stableHashHex(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    nonisolated static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    nonisolated static func isSupportedSchemaVersion(_ schemaVersion: Int) -> Bool {
        (1...ScanSnapshot.currentSchemaVersion).contains(schemaVersion)
    }
}

enum FileScanSnapshotStoreError: LocalizedError, Sendable {
    case unsupportedSchemaVersion(actual: Int, supported: Int)
    case libraryRootMismatch(expected: String, actual: String)
    case libraryRoleMismatch(expected: String, actual: String)
    case outsideSnapshotDirectory(String)
    case noAvailableFileName(String)
    case stableFileLibraryMismatch(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let actual, let supported):
            "扫描快照版本不兼容：当前文件版本 \(actual)，应用支持版本 \(supported)。"
        case .libraryRootMismatch(let expected, let actual):
            "扫描快照目录不匹配：期望 \(expected)，实际 \(actual)。"
        case .libraryRoleMismatch(let expected, let actual):
            "扫描快照目录角色不匹配：期望 \(expected)，实际 \(actual)。"
        case .outsideSnapshotDirectory(let path):
            "不能写入总 db 文件夹之外的快照：\(path)"
        case .noAvailableFileName(let displayName):
            "无法为扫描快照生成可用文件名：\(displayName)"
        case .stableFileLibraryMismatch(let path):
            "稳定快照文件内容与当前音乐库不匹配：\(path)"
        }
    }
}
