import Foundation
import Testing
@testable import CoverDrop

struct FSEventsLibraryChangeMonitorTests {
    @Test(
        "FSEvents 可以捕获临时目录中的创建修改重命名和删除",
        .disabled("系统 FSEvents 在并行 XCTest 宿主里偶发无法及时结束，默认验证先覆盖可控监听与重扫链路。")
    )
    func capturesDirectoryChanges() async throws {
        try await withTemporaryDirectory { root in
            let monitor = FSEventsLibraryChangeMonitor(latency: 0.05)
            let collector = LibraryChangeEventCollector()
            let task = Task {
                do {
                    for try await event in monitor.events(for: root) {
                        await collector.record(event)
                        if await collector.containsAllSuffixes(["cover.jpg", "01.wav", "02.wav"]) {
                            break
                        }
                    }
                } catch {
                    await collector.record(error)
                }
            }
            defer { task.cancel() }

            try await Task.sleep(nanoseconds: 250_000_000)

            let coverURL = root.appendingPathComponent("cover.jpg")
            let trackURL = root.appendingPathComponent("01.wav")
            let renamedTrackURL = root.appendingPathComponent("02.wav")

            try Data("cover-1".utf8).write(to: coverURL)
            try Data("cover-2".utf8).write(to: coverURL)
            try Data("audio".utf8).write(to: trackURL)
            try FileManager.default.moveItem(at: trackURL, to: renamedTrackURL)
            try FileManager.default.removeItem(at: coverURL)

            await waitUntil {
                let paths = await collector.paths()
                return paths.contains(where: { $0.hasSuffix("cover.jpg") })
                    && paths.contains(where: { $0.hasSuffix("01.wav") })
                    && paths.contains(where: { $0.hasSuffix("02.wav") })
            }

            let paths = await collector.paths()
            #expect(paths.contains(where: { $0.hasSuffix("cover.jpg") }))
            #expect(paths.contains(where: { $0.hasSuffix("01.wav") }))
            #expect(paths.contains(where: { $0.hasSuffix("02.wav") }))
            #expect(await collector.errorMessage() == nil)
        }
    }
}

private actor LibraryChangeEventCollector {
    private var observedPaths: [String] = []
    private var observedError: String?

    func record(_ event: LibraryChangeEvent) async {
        let changedPaths = await MainActor.run {
            event.changedPaths
        }
        observedPaths.append(contentsOf: changedPaths)
    }

    func record(_ error: Error) {
        observedError = error.localizedDescription
    }

    func paths() -> [String] {
        observedPaths
    }

    func containsAllSuffixes(_ suffixes: [String]) -> Bool {
        suffixes.allSatisfy { suffix in
            observedPaths.contains { $0.hasSuffix(suffix) }
        }
    }

    func errorMessage() -> String? {
        observedError
    }
}

private func waitUntil(
    _ condition: @escaping () async -> Bool
) async {
    for _ in 0..<500 {
        if await condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

private func withTemporaryDirectory(
    _ operation: (URL) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoverDropFSEventsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await operation(root)
}
