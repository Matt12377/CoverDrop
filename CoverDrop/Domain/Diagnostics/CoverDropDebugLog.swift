import Foundation

enum CoverDropDebugLog {
    nonisolated static func write(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print("[CoverDrop] \(message())")
    }

    nonisolated private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["COVERDROP_DEBUG_LOG"] == "1"
    }
}
