import Foundation

enum CoverDropDebugLog {
    nonisolated static func write(_ message: @autoclosure () -> String) {
        let value = message()
        guard isEnabled || shouldAlwaysPrint(value) else { return }
        print("[CoverDrop] \(value)")
    }

    nonisolated private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["COVERDROP_DEBUG_LOG"] == "1"
    }

    nonisolated private static func shouldAlwaysPrint(_ message: String) -> Bool {
        message.hasPrefix("封面拖拽：")
            || message.hasPrefix("封面下载：")
            || message.hasPrefix("保存封面：")
            || message.hasPrefix("内置网页图片捕获：")
    }
}
