import Foundation
import Testing
@testable import CoverDrop

struct FinderAlbumFolderOpenerTests {
    @Test("在 Finder 中显示专辑目录通过 NSWorkspace 执行")
    func openingAlbumFolderUsesWorkspaceRevealer() async throws {
        let revealer = RecordingFinderAlbumFolderRevealer()
        let opener = FinderAlbumFolderOpener(folderRevealer: revealer)
        let albumURL = URL(fileURLWithPath: "/Volumes/Music/Artist/Album", isDirectory: true)

        try await opener.openAlbumFolder(albumURL)

        #expect(await revealer.revealedURLs == [albumURL.standardizedFileURL])
    }

    @Test("Finder 显示失败时向上抛出错误")
    func openingAlbumFolderPropagatesWorkspaceFailure() async {
        let revealer = RecordingFinderAlbumFolderRevealer(
            error: NSError(
                domain: "NSWorkspaceAlbumFolderRevealerTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法显示目录"]
            )
        )
        let opener = FinderAlbumFolderOpener(folderRevealer: revealer)
        let albumURL = URL(fileURLWithPath: "/Volumes/Music/Artist/Album", isDirectory: true)

        await #expect(throws: (any Error).self) {
            try await opener.openAlbumFolder(albumURL)
        }

        #expect(await revealer.revealedURLs == [albumURL.standardizedFileURL])
    }

    @Test("优先让 Finder 在当前桌面打开目录且随后确保可见")
    func workspaceRevealerOpensFolderWithFinderWithoutActivationThenRevealsIt() async throws {
        let workspace = RecordingFinderWorkspaceOpening()
        let revealer = NSWorkspaceFinderAlbumFolderRevealer(workspace: workspace)
        let albumURL = try makeExistingDirectory()

        try await revealer.revealAlbumFolder(albumURL)

        let expectedFinderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        #expect(await workspace.openRequests == [
            FinderWorkspaceOpenRequest(
                folderURL: albumURL.standardizedFileURL,
                finderURL: expectedFinderURL,
                activates: false
            )
        ])
        #expect(await workspace.activatedURLs == [[albumURL.standardizedFileURL]])
    }

    @Test("指定 Finder 打开失败时仍显示目录")
    func workspaceRevealerFallsBackToActivateFileViewerWhenFinderOpenFails() async throws {
        let workspace = RecordingFinderWorkspaceOpening(
            openError: NSError(
                domain: "NSWorkspaceAlbumFolderRevealerTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "指定 Finder 打开失败"]
            )
        )
        let revealer = NSWorkspaceFinderAlbumFolderRevealer(workspace: workspace)
        let albumURL = try makeExistingDirectory()

        try await revealer.revealAlbumFolder(albumURL)

        #expect(await workspace.activatedURLs == [[albumURL.standardizedFileURL]])
    }

    @Test("用 XLD 打开 CUE 文件通过 NSWorkspace 执行")
    func openingCueSheetUsesXLDWorkspace() async throws {
        let workspace = RecordingXLDWorkspaceOpening()
        let splitter = XLDCueSheetSplitter(workspace: workspace)
        let cueURL = try makeExistingCueSheet()

        try await splitter.splitCueSheet(cueURL)

        #expect(await workspace.openRequests == [
            XLDCueSheetOpenRequest(
                cueSheetURL: cueURL.standardizedFileURL,
                xldURL: URL(fileURLWithPath: "/Applications/XLD.app"),
                activates: true
            )
        ])
    }

    @Test("找不到 XLD 时分轨入口抛出中文错误")
    func openingCueSheetFailsWhenXLDIsMissing() async throws {
        let workspace = RecordingXLDWorkspaceOpening(xldURL: nil)
        let splitter = XLDCueSheetSplitter(workspace: workspace)
        let cueURL = try makeExistingCueSheet()

        await #expect(throws: (any Error).self) {
            try await splitter.splitCueSheet(cueURL)
        }

        #expect(await workspace.openRequests.isEmpty)
    }

    @Test("CUE 文件不存在时不会启动 XLD")
    func openingMissingCueSheetFailsBeforeOpeningXLD() async {
        let workspace = RecordingXLDWorkspaceOpening()
        let splitter = XLDCueSheetSplitter(workspace: workspace)
        let cueURL = URL(fileURLWithPath: "/Volumes/Music/missing.cue")

        await #expect(throws: (any Error).self) {
            try await splitter.splitCueSheet(cueURL)
        }

        #expect(await workspace.openRequests.isEmpty)
    }

    @Test("非 CUE 文件不会交给 XLD 分轨")
    func openingNonCueFileFailsBeforeOpeningXLD() async throws {
        let workspace = RecordingXLDWorkspaceOpening()
        let splitter = XLDCueSheetSplitter(workspace: workspace)
        let audioURL = try makeExistingCueSheet().deletingPathExtension().appendingPathExtension("ape")
        try Data([0]).write(to: audioURL)

        await #expect(throws: (any Error).self) {
            try await splitter.splitCueSheet(audioURL)
        }

        #expect(await workspace.openRequests.isEmpty)
    }
}

private func makeExistingDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
    )
    return directoryURL
}

private func makeExistingCueSheet() throws -> URL {
    let directoryURL = try makeExistingDirectory()
    let cueURL = directoryURL.appendingPathComponent("album.cue")
    try Data("""
    FILE "album.ape" WAVE
      TRACK 01 AUDIO
        INDEX 01 00:00:00
    """.utf8).write(to: cueURL)
    return cueURL
}

private struct FinderWorkspaceOpenRequest: Equatable, Sendable {
    let folderURL: URL
    let finderURL: URL
    let activates: Bool
}

private actor RecordingFinderWorkspaceOpening: FinderWorkspaceOpening {
    private(set) var openRequests: [FinderWorkspaceOpenRequest] = []
    private(set) var activatedURLs: [[URL]] = []
    private let finderURL: URL?
    private let openError: (any Error)?

    init(
        finderURL: URL? = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
        openError: (any Error)? = nil
    ) {
        self.finderURL = finderURL
        self.openError = openError
    }

    func finderApplicationURL() async -> URL? {
        finderURL
    }

    func openFolder(
        _ folderURL: URL,
        withFinderAt finderURL: URL,
        activates: Bool
    ) async throws {
        openRequests.append(FinderWorkspaceOpenRequest(
            folderURL: folderURL,
            finderURL: finderURL,
            activates: activates
        ))
        if let openError {
            throw openError
        }
    }

    func activateFileViewerSelecting(_ urls: [URL]) async {
        activatedURLs.append(urls)
    }
}

private actor RecordingFinderAlbumFolderRevealer: FinderAlbumFolderRevealing {
    private(set) var revealedURLs: [URL] = []
    private let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func revealAlbumFolder(_ folderURL: URL) async throws {
        revealedURLs.append(folderURL)
        if let error {
            throw error
        }
    }
}

private struct XLDCueSheetOpenRequest: Equatable, Sendable {
    let cueSheetURL: URL
    let xldURL: URL
    let activates: Bool
}

private actor RecordingXLDWorkspaceOpening: XLDWorkspaceOpening {
    private(set) var openRequests: [XLDCueSheetOpenRequest] = []
    private let xldURL: URL?
    private let openError: (any Error)?

    init(
        xldURL: URL? = URL(fileURLWithPath: "/Applications/XLD.app"),
        openError: (any Error)? = nil
    ) {
        self.xldURL = xldURL
        self.openError = openError
    }

    func xldApplicationURL() async -> URL? {
        xldURL
    }

    func openCueSheet(
        _ cueSheetURL: URL,
        withXLDAt xldURL: URL,
        activates: Bool
    ) async throws {
        openRequests.append(XLDCueSheetOpenRequest(
            cueSheetURL: cueSheetURL,
            xldURL: xldURL,
            activates: activates
        ))
        if let openError {
            throw openError
        }
    }
}
