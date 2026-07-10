import AppKit
import Foundation

protocol FinderAlbumFolderRevealing: Sendable {
    nonisolated func revealAlbumFolder(_ folderURL: URL) async throws
}

protocol FinderWorkspaceOpening: Sendable {
    nonisolated func finderApplicationURL() async -> URL?
    nonisolated func openFolder(
        _ folderURL: URL,
        withFinderAt finderURL: URL,
        activates: Bool
    ) async throws
    nonisolated func activateFileViewerSelecting(_ urls: [URL]) async
}

protocol XLDWorkspaceOpening: Sendable {
    nonisolated func xldApplicationURL() async -> URL?
    nonisolated func openCueSheet(
        _ cueSheetURL: URL,
        withXLDAt xldURL: URL,
        activates: Bool
    ) async throws
}

actor FinderAlbumFolderOpener: AlbumFolderOpening {
    private let folderRevealer: any FinderAlbumFolderRevealing

    init(folderRevealer: any FinderAlbumFolderRevealing = NSWorkspaceFinderAlbumFolderRevealer()) {
        self.folderRevealer = folderRevealer
    }

    func openAlbumFolder(_ folderURL: URL) async throws {
        let standardizedURL = folderURL.standardizedFileURL
        FinderAlbumFolderOpenDiagnostics.log(
            "opener.request folder=\(standardizedURL.path)"
        )

        do {
            try await folderRevealer.revealAlbumFolder(standardizedURL)
            FinderAlbumFolderOpenDiagnostics.log(
                "opener.success folder=\(standardizedURL.path)"
            )
        } catch {
            FinderAlbumFolderOpenDiagnostics.log(
                "opener.failure folder=\(standardizedURL.path) error=\(error.localizedDescription)"
            )
            throw error
        }
    }
}

actor XLDCueSheetSplitter: CueSheetSplitting {
    private let workspace: any XLDWorkspaceOpening

    init(workspace: any XLDWorkspaceOpening = NSWorkspaceXLDOpening()) {
        self.workspace = workspace
    }

    func splitCueSheet(_ cueSheetURL: URL) async throws {
        let standardizedURL = cueSheetURL.standardizedFileURL
        guard standardizedURL.pathExtension.lowercased() == "cue" else {
            throw XLDCueSheetSplitterError(message: "只能将 CUE 文件交给 XLD 分轨。")
        }

        try await MainActor.run {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw XLDCueSheetSplitterError(message: "未找到 CUE 文件。")
            }
        }

        guard let xldURL = await workspace.xldApplicationURL() else {
            throw XLDCueSheetSplitterError(message: "未找到 XLD，请先安装或打开 XLD.app。")
        }

        try await workspace.openCueSheet(
            standardizedURL,
            withXLDAt: xldURL,
            activates: true
        )
    }
}

struct NSWorkspaceFinderAlbumFolderRevealer: FinderAlbumFolderRevealing {
    private let workspace: any FinderWorkspaceOpening

    init(workspace: any FinderWorkspaceOpening = NSWorkspaceFinderWorkspaceOpening()) {
        self.workspace = workspace
    }

    nonisolated func revealAlbumFolder(_ folderURL: URL) async throws {
        let standardizedURL = folderURL.standardizedFileURL
        try await MainActor.run {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw FinderAlbumFolderOpenerError(message: "未找到专辑目录。")
            }
        }

        if let finderURL = await workspace.finderApplicationURL() {
            FinderAlbumFolderOpenDiagnostics.log(
                "workspace.openWithFinder folder=\(standardizedURL.path) finder=\(finderURL.path) activates=false"
            )
            do {
                try await workspace.openFolder(
                    standardizedURL,
                    withFinderAt: finderURL,
                    activates: false
                )
            } catch {
                FinderAlbumFolderOpenDiagnostics.log(
                    "workspace.openWithFinderFailed folder=\(standardizedURL.path) error=\(error.localizedDescription)"
                )
            }
        }

        FinderAlbumFolderOpenDiagnostics.log(
            "workspace.activateFileViewerSelecting folder=\(standardizedURL.path)"
        )
        await workspace.activateFileViewerSelecting([standardizedURL])
    }
}

struct NSWorkspaceFinderWorkspaceOpening: FinderWorkspaceOpening {
    nonisolated func finderApplicationURL() async -> URL? {
        await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
        }
    }

    nonisolated func openFolder(
        _ folderURL: URL,
        withFinderAt finderURL: URL,
        activates: Bool
    ) async throws {
        try await Self.openFolderOnMainActor(
            folderURL,
            withFinderAt: finderURL,
            activates: activates
        )
    }

    @MainActor
    private static func openFolderOnMainActor(
        _ folderURL: URL,
        withFinderAt finderURL: URL,
        activates: Bool
    ) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.open(
                [folderURL],
                withApplicationAt: finderURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    nonisolated func activateFileViewerSelecting(_ urls: [URL]) async {
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}

struct NSWorkspaceXLDOpening: XLDWorkspaceOpening {
    nonisolated func xldApplicationURL() async -> URL? {
        await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "jp.tmkk.XLD")
        }
    }

    nonisolated func openCueSheet(
        _ cueSheetURL: URL,
        withXLDAt xldURL: URL,
        activates: Bool
    ) async throws {
        try await Self.openCueSheetOnMainActor(
            cueSheetURL,
            withXLDAt: xldURL,
            activates: activates
        )
    }

    @MainActor
    private static func openCueSheetOnMainActor(
        _ cueSheetURL: URL,
        withXLDAt xldURL: URL,
        activates: Bool
    ) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.open(
                [cueSheetURL],
                withApplicationAt: xldURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

enum FinderAlbumFolderOpenDiagnostics {
    nonisolated static func log(_ message: @autoclosure () -> String) {
        print("[CoverDrop][FinderOpen] \(message())")
    }
}

private struct FinderAlbumFolderOpenerError: LocalizedError, Sendable {
    let message: String

    init(message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private struct XLDCueSheetSplitterError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
