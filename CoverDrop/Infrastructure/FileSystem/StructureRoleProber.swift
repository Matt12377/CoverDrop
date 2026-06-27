import Foundation

struct StructureRoleProber: DirectoryRoleProbing {
    nonisolated private static var audioExtensions: Set<String> {
        [
            "mp3", "flac", "ape", "wav", "wave", "aif", "aiff", "aifc",
            "m4a", "mp4", "ogg", "oga", "opus", "wv", "mpc", "mpp",
            "wma", "asf", "tta", "dsf", "dff"
        ]
    }

    func suggestRole(for url: URL) async throws -> DirectoryRoleSuggestion {
        try await Task.detached(priority: .userInitiated) {
            try Self.suggestRoleSynchronously(for: url)
        }.value
    }

    nonisolated private static func suggestRoleSynchronously(for url: URL) throws -> DirectoryRoleSuggestion {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw LibraryImportError.notDirectory
        }

        let children = try visibleChildren(of: url)
        guard !children.isEmpty else {
            throw LibraryImportError.emptyDirectory
        }

        if children.contains(where: isAudioFile) {
            return DirectoryRoleSuggestion(
                role: .album,
                explanation: "当前文件夹直属包含音频，建议作为单张专辑。"
            )
        }

        let childDirectories = try children.filter { try isDirectory($0) }
        guard !childDirectories.isEmpty else {
            throw LibraryImportError.noAudioFound
        }

        let discNamedChildren = childDirectories.filter { isDiscFolderName($0.lastPathComponent) }
        if discNamedChildren.count == childDirectories.count,
           try discNamedChildren.contains(where: { try containsAudioDirectly($0) }) {
            return DirectoryRoleSuggestion(
                role: .album,
                explanation: "子目录名称类似 CD1/CD2，建议合并视为单张多碟专辑。"
            )
        }

        if try childDirectories.contains(where: { try containsAudioDirectly($0) }) {
            return DirectoryRoleSuggestion(
                role: .artist,
                explanation: "直接子目录中包含音频，建议当前文件夹作为歌手目录。"
            )
        }

        if try childDirectories.contains(where: { try containsAudioWithinTwoLevels($0) }) {
            return DirectoryRoleSuggestion(
                role: .library,
                explanation: "音频主要位于第二层目录以下，建议当前文件夹作为音乐库。"
            )
        }

        throw LibraryImportError.noAudioFound
    }

    nonisolated private static func visibleChildren(of url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        )
    }

    nonisolated private static func isDirectory(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    nonisolated private static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated private static func containsAudioDirectly(_ directory: URL) throws -> Bool {
        try visibleChildren(of: directory).contains(where: isAudioFile)
    }

    nonisolated private static func containsAudioWithinTwoLevels(_ directory: URL) throws -> Bool {
        let children = try visibleChildren(of: directory)
        if children.contains(where: isAudioFile) { return true }

        for child in children where (try? isDirectory(child)) == true {
            if try containsAudioDirectly(child) { return true }
        }
        return false
    }

    nonisolated private static func isDiscFolderName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        let prefixes = ["cd", "disc", "disk", "碟", "盘"]
        return prefixes.contains { prefix in
            guard normalized.hasPrefix(prefix) else { return false }
            let suffix = normalized.dropFirst(prefix.count)
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
    }
}

enum LibraryImportError: LocalizedError, Equatable {
    case notDirectory
    case emptyDirectory
    case noAudioFound

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            "请选择一个文件夹。"
        case .emptyDirectory:
            "这个文件夹是空的。"
        case .noAudioFound:
            "在支持的探测深度内没有找到音频文件。"
        }
    }
}
