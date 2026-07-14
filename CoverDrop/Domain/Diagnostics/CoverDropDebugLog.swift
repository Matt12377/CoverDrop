import Foundation

enum CoverDropDebugLog {
    nonisolated static func write(_ message: @autoclosure () -> String) {
        guard CoverDropPerformanceLog.isEnabled(
            environment: ProcessInfo.processInfo.environment
        ) else {
            return
        }
        CoverDropPerformanceLog.writeLine("[CoverDrop] \(message())")
    }
}
