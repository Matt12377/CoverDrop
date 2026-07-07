import Foundation

/// 用户确认的输入目录角色。
enum LibraryRole: String, CaseIterable, Codable, Sendable {
    case library
    case artist
    case album

    nonisolated var displayName: String {
        switch self {
        case .library:
            "音乐库"
        case .artist:
            "歌手目录"
        case .album:
            "单张专辑"
        }
    }
}
