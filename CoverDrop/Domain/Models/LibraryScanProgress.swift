import Foundation

struct LibraryScanProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case discoveringAlbums
        case readingMetadata
        case detectingCover
        case finishing

        var displayName: String {
            switch self {
            case .discoveringAlbums:
                "正在分析音乐库目录"
            case .readingMetadata:
                "正在读取音频标签"
            case .detectingCover:
                "正在检查专辑封面"
            case .finishing:
                "正在整理扫描结果"
            }
        }
    }

    let phase: Phase
    let targetPath: String
    let completedAlbums: Int
    let totalAlbums: Int?
    let completedFilesInAlbum: Int?
    let totalFilesInAlbum: Int?

    var completedDescription: String {
        guard let totalAlbums else {
            return "正在建立专辑清单…"
        }

        var description = "已完成 \(completedAlbums) / \(totalAlbums) 张专辑"
        if let completedFilesInAlbum,
           let totalFilesInAlbum,
           totalFilesInAlbum > 0,
           completedAlbums < totalAlbums {
            description += " · 当前专辑 \(completedFilesInAlbum) / \(totalFilesInAlbum) 个音频"
        }
        return description
    }

    var albumProgressFraction: Double? {
        guard let totalAlbums, totalAlbums > 0 else { return nil }
        return Double(completedAlbums) / Double(totalAlbums)
    }
}
