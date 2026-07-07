import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct LibraryScanSummaryView: View {
    let result: LibraryScanResult
    @ObservedObject var appModel: AppModel

    @State private var filter: AlbumScanResultFilter = .all
    @State private var query = ""
    @State private var selectedAlbumID: AlbumScanRecord.ID?
    @State private var isShowingAlbumDetail = false
    @FocusState private var isQueryFocused: Bool

    private var filteredAlbums: [AlbumScanRecord] {
        AlbumScanResultFiltering.albums(
            in: result,
            filter: filter,
            query: query,
            displayNames: { album in
                (
                    artistName: appModel.displayArtistName(for: album),
                    albumName: appModel.displayAlbumName(for: album)
                )
            }
        )
    }

    private var filteredLooseAudioPaths: [String] {
        AlbumScanResultFiltering.looseAudioPaths(in: result, filter: filter, query: query)
    }

    var body: some View {
        let visibleAlbums = filteredAlbums
        let visibleLooseAudioPaths = filteredLooseAudioPaths

        VStack(alignment: .leading, spacing: 0) {
            statsRow(visibleResultCount: visibleAlbums.count + visibleLooseAudioPaths.count)

            filterControls

            if !visibleAlbums.isEmpty {
                albumGrid(albums: visibleAlbums)
            } else if filter != .looseAudio {
                emptyState("没有符合筛选条件的专辑。", systemImage: "square.grid.2x2")
            }

            if !visibleLooseAudioPaths.isEmpty {
                if !visibleAlbums.isEmpty {
                    LibraryDividerLine()
                }
                looseAudioList(paths: visibleLooseAudioPaths)
            } else if filter == .looseAudio {
                emptyState("没有符合筛选条件的散落音频。", systemImage: "music.note.list")
            }
        }
        .background(LibraryHomeDesignToken.bgSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            albumDetailOverlay
        }
        .onChange(of: isShowingAlbumDetail) { _, isShowing in
            if !isShowing {
                clearSelectedAlbumDetail()
            }
        }
        .onChange(of: result.albums.map(\.id)) { _, albumIDs in
            guard let selectedAlbumID,
                  !albumIDs.contains(selectedAlbumID) else {
                return
            }
            appModel.reportSelectedAlbumDisappeared(albumID: selectedAlbumID)
            isShowingAlbumDetail = false
            clearSelectedAlbumDetail()
        }
    }

    @ViewBuilder
    private var albumDetailOverlay: some View {
        if isShowingAlbumDetail, let selectedAlbumID {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    closeAlbumDetail()
                }
                .overlay {
                    AlbumDetailSheet(
                        albumID: selectedAlbumID,
                        appModel: appModel,
                        onClose: closeAlbumDetail
                    )
                    .onTapGesture {}
                }
                .transition(.opacity)
        }
    }

    private func statsRow(visibleResultCount: Int) -> some View {
        HStack(spacing: 10) {
            statItem(title: "专辑", value: result.albums.count, valueColor: LibraryHomeDesignToken.textPrimary)
            statDivider
            statItem(title: "已有封面", value: result.albumsWithCover, valueColor: LibraryHomeDesignToken.success)
            statDivider
            statItem(
                title: "缺封面",
                value: result.albums.count - result.albumsWithCover,
                valueColor: LibraryHomeDesignToken.destructive
            )
            statDivider
            statItem(title: "需确认", value: result.albumsNeedingAttention, valueColor: LibraryHomeDesignToken.warning)
            statDivider
            statItem(title: "散落音频", value: result.looseAudioPaths.count, valueColor: LibraryHomeDesignToken.textPrimary)

            Spacer()

            Text("\(visibleResultCount) 项")
                .font(.caption.weight(.medium))
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            LibraryDividerLine()
        }
    }

    private var filterControls: some View {
        HStack(spacing: 12) {
            Picker("结果筛选", selection: $filter) {
                ForEach(AlbumScanResultFilter.allCases) { option in
                    Text(option.displayName)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 390)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                TextField("按歌手、专辑、路径或标签名筛选", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                    .focused($isQueryFocused)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(LibraryHomeDesignToken.bgTertiary, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusSm))
            .overlay {
                RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusSm)
                    .stroke(isQueryFocused ? LibraryHomeDesignToken.accent : LibraryHomeDesignToken.border)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            LibraryDividerLine()
        }
    }

    private func albumGrid(albums: [AlbumScanRecord]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 168, maximum: 168), spacing: 16)
                ],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(albums) { album in
                    AlbumCoverCard(
                        album: album,
                        appModel: appModel,
                        displayAlbumName: appModel.displayAlbumName(for: album),
                        displayArtistName: appModel.displayArtistName(for: album),
                        hasEnhancedAlbumName: appModel.hasEnhancedAlbumName(for: album),
                        coverWriteMessage: appModel.coverWriteMessage(for: album.id)
                    ) {
                        openAlbumDetail(albumID: album.id, pendingCoverURL: nil)
                    } onAcceptedCoverDrop: {
                        openAlbumDetail(albumID: album.id, pendingCoverURL: nil)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(minHeight: 320, maxHeight: .infinity)
    }

    private func looseAudioList(paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("散落音频", systemImage: "music.note.list")
                .font(.headline)
                .foregroundStyle(LibraryHomeDesignToken.textPrimary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(paths, id: \.self) { path in
                        Label(path, systemImage: "music.note")
                            .font(.caption)
                            .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                    }
                }
            }
            .frame(maxHeight: filter == .looseAudio ? 360 : 120)
        }
        .padding(20)
    }

    private func statItem(title: String, value: Int, valueColor: Color) -> some View {
        HStack(spacing: 5) {
            Text(value, format: .number)
                .font(.callout.bold())
                .foregroundStyle(valueColor)
            Text(title)
                .font(.caption)
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
        }
    }

    private var statDivider: some View {
        Rectangle()
            .fill(LibraryHomeDesignToken.borderStrong)
            .frame(width: 1, height: 12)
    }

    private func emptyState(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        }
        .foregroundStyle(LibraryHomeDesignToken.textSecondary)
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private func openAlbumDetail(
        albumID: AlbumScanRecord.ID,
        pendingCoverURL: URL?
    ) {
        selectedAlbumID = albumID
        if let pendingCoverURL {
            appModel.stageCoverImage(pendingCoverURL, forAlbumID: albumID)
        } else {
            appModel.cancelPendingCoverImage(forAlbumID: albumID)
        }
        isShowingAlbumDetail = true
    }

    private func closeAlbumDetail() {
        isShowingAlbumDetail = false
        clearSelectedAlbumDetail()
    }

    private func clearSelectedAlbumDetail() {
        if let selectedAlbumID {
            appModel.cancelPendingCoverImage(forAlbumID: selectedAlbumID)
        }
        selectedAlbumID = nil
    }
}

private struct AlbumCoverCard: View {
    let album: AlbumScanRecord
    let appModel: AppModel
    let displayAlbumName: String
    let displayArtistName: String
    let hasEnhancedAlbumName: Bool
    let coverWriteMessage: String?
    let onOpen: () -> Void
    let onAcceptedCoverDrop: () -> Void

    @State private var isDropTargeted = false
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                coverArea

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(displayAlbumName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                            .lineLimit(2)
                            .help(displayAlbumName)

                        if hasEnhancedAlbumName {
                            Image(systemName: "sparkles")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                                .help("名称已由 Ollama 增强")
                        }
                    }

                    Text(displayArtistName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(album.folderURL.path)
                        .font(.system(size: 10))
                        .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(album.folderURL.path)

                    HStack(spacing: 5) {
                        ForEach(formatTags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(LibraryHomeDesignToken.bgElevated, in: Capsule())
                        }

                        Spacer(minLength: 0)

                        if let message = coverWriteMessage {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(LibraryHomeDesignToken.success)
                                .help(message)
                        }
                    }
                    .frame(height: 16)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 168)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusLg))
        .clipShape(RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusLg))
        .shadow(color: LibraryHomeDesignToken.shadowCard, radius: 8, y: 2)
        .overlay {
            RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusLg)
                .stroke(
                    isDropTargeted
                        ? AnyShapeStyle(LibraryHomeDesignToken.accent)
                        : AnyShapeStyle(LibraryHomeDesignToken.border),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: isDropTargeted ? [7] : [])
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .help("点击查看专辑详情")
        .onHover { isHovered = $0 }
        .onDrop(
            of: CoverDropReceiver.typeIdentifiers,
            isTargeted: $isDropTargeted
        ) { providers in
            CoverDropReceiver.receive(
                providers,
                albumID: album.id,
                appModel: appModel,
                onAccepted: onAcceptedCoverDrop
            )
        }
    }

    private var coverArea: some View {
        ZStack {
            CachedCoverFillView(
                url: displayedCoverURL,
                maxPixelSize: 336,
                placeholderSize: 32,
                placeholderText: "缺封面"
            )
            .frame(width: 168, height: 168)
        }
        .frame(width: 168, height: 168)
        .overlay(alignment: .topLeading) {
            statusBadge
                .padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            if album.needsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                    .frame(width: 20, height: 20)
                    .background(LibraryHomeDesignToken.warning, in: Circle())
                    .shadow(color: LibraryHomeDesignToken.shadowCard, radius: 4, y: 2)
                    .padding(8)
                    .help(album.issues.map(\.displayName).joined(separator: "\n"))
            }
        }
    }

    private var displayedCoverURL: URL? {
        album.displayedCover?.displayURL
    }

    private var statusBadge: some View {
        if album.needsAttention {
            LibraryStatusPill(
                title: "需确认",
                systemImage: "exclamationmark.triangle.fill",
                foreground: LibraryHomeDesignToken.warning,
                background: LibraryHomeDesignToken.warningBg,
                border: LibraryHomeDesignToken.warning.opacity(0.35)
            )
        } else if let source = album.displayedCover?.source.displayName {
            LibraryStatusPill(
                title: source,
                systemImage: "checkmark",
                foreground: LibraryHomeDesignToken.success,
                background: LibraryHomeDesignToken.successBg,
                border: LibraryHomeDesignToken.success.opacity(0.35)
            )
        } else {
            LibraryStatusPill(
                title: "缺封面",
                systemImage: nil,
                foreground: LibraryHomeDesignToken.destructive,
                background: LibraryHomeDesignToken.destructiveBg,
                border: LibraryHomeDesignToken.destructive.opacity(0.35)
            )
        }
    }

    private var cardBackground: Color {
        isHovered ? LibraryHomeDesignToken.bgElevated : LibraryHomeDesignToken.bgTertiary
    }

    private var formatTags: [String] {
        Array(Set(album.audioFiles.map { $0.format.uppercased() }))
            .sorted()
            .prefix(2)
            .map { $0 }
    }
}

private struct AlbumDetailSheet: View {
    let albumID: AlbumScanRecord.ID
    @ObservedObject var appModel: AppModel
    let onClose: () -> Void
    @State private var isDropTargeted = false
    @State private var isShowingCoverSearch = false
    @State private var selectedSearchSourceID = ""

    private var album: AlbumScanRecord? {
        appModel.albumInSelectedLibrary(id: albumID)
    }

    private var coverSearchConfiguration: AppConfiguration.CoverSearch {
        appModel.environment.configuration.coverSearch
    }

    var body: some View {
        Group {
            if let album {
                albumDetail(album)
            } else {
                ContentUnavailableView {
                    Label("找不到这张专辑", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("当前扫描结果中已没有这张专辑。")
                } actions: {
                    Button("取消") {
                        onClose()
                    }
                }
                .frame(width: 760, height: 560)
            }
        }
        .frame(width: 680, height: 520)
        .background(LibraryHomeDesignToken.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusLg))
        .shadow(color: LibraryHomeDesignToken.shadowElevated, radius: 24, y: 10)
        .overlay {
            RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusLg)
                .stroke(LibraryHomeDesignToken.borderStrong)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isDropTargeted ? AnyShapeStyle(LibraryHomeDesignToken.accent) : AnyShapeStyle(.clear),
                    style: StrokeStyle(lineWidth: 3, dash: [8])
                )
                .padding(8)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $isShowingCoverSearch) {
            if let album {
                CoverSearchSheet(
                    album: album,
                    appModel: appModel,
                    searchConfiguration: coverSearchConfiguration,
                    selectedSourceID: $selectedSearchSourceID
                )
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                if selectedSearchSourceID.isEmpty {
                    selectedSearchSourceID = coverSearchConfiguration.defaultSource.id
                }
            }
        }
        .onDrop(
            of: CoverDropReceiver.typeIdentifiers,
            isTargeted: $isDropTargeted
        ) { providers in
            CoverDropReceiver.receive(
                providers,
                albumID: albumID,
                appModel: appModel
            )
        }
    }

    private func albumDetail(_ album: AlbumScanRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 22) {
                        cover(for: album)
                            .frame(width: 200, height: 200)
                            .overlay(alignment: .topTrailing) {
                                if appModel.pendingCoverURL(for: album.id) != nil {
                                    Text("待保存")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(LibraryHomeDesignToken.accent, in: Capsule())
                                        .padding(8)
                                }
                            }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(appModel.displayAlbumName(for: album))
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                        .help(appModel.displayAlbumName(for: album))

                                    HStack(spacing: 6) {
                                        LibraryStatusPill(
                                            title: "\(album.audioFiles.count) 个音频",
                                            systemImage: "music.note",
                                            foreground: LibraryHomeDesignToken.accent,
                                            background: LibraryHomeDesignToken.accentBg
                                        )
                                        LibraryStatusPill(
                                            title: album.displayedCover?.source.displayName ?? "缺封面",
                                            systemImage: album.displayedCover == nil ? "photo.badge.exclamationmark" : "photo",
                                            foreground: album.displayedCover == nil ? LibraryHomeDesignToken.destructive : LibraryHomeDesignToken.success,
                                            background: album.displayedCover == nil ? LibraryHomeDesignToken.destructiveBg : LibraryHomeDesignToken.successBg
                                        )
                                    }
                                }

                                Spacer(minLength: 0)

                                Button {
                                    isShowingCoverSearch = true
                                } label: {
                                    Label("搜索封面", systemImage: "magnifyingglass")
                                }
                                .buttonStyle(.coverDropSecondary(height: 32))
                            }

                            LibraryDividerLine()

                            if let pendingCoverURL = appModel.pendingCoverURL(for: album.id) {
                                Label("待保存：\(pendingCoverURL.lastPathComponent)", systemImage: "photo.badge.plus")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(LibraryHomeDesignToken.accent)
                                    .lineLimit(1)
                                    .help(pendingCoverURL.path)
                            } else if let message = appModel.coverWriteMessage(for: album.id) {
                                Label(message, systemImage: "checkmark.circle.fill")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(LibraryHomeDesignToken.success)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                infoField(
                                    title: "搜索词",
                                    value: appModel.searchKeyword(for: album),
                                    monospaced: false,
                                    copyAction: { copySearchKeyword(for: album) }
                                )
                                infoField(title: "原始名", value: "\(album.artistName) / \(album.albumName)")
                                infoField(title: "路径", value: album.folderURL.path, monospaced: true)
                            }

                            LibraryDividerLine()

                            if !album.issues.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(album.issues.map(\.displayName), id: \.self) { issue in
                                        Label(issue, systemImage: "exclamationmark.triangle")
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(LibraryHomeDesignToken.warning)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(10)
                                .background(LibraryHomeDesignToken.warningBg, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusSm))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                    }
                    .padding(24)

                    trackList(for: album)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([album.folderURL])
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                .buttonStyle(.coverDropSubtle)

                Spacer()

                Button {
                    onClose()
                } label: {
                    Label("返回封面墙", systemImage: "arrow.left")
                }
                .buttonStyle(.coverDropSecondary(height: 34))

                Button("保存封面") {
                    savePendingCover()
                }
                .buttonStyle(.coverDropPrimary(height: 34))
                .disabled(appModel.pendingCoverURL(for: album.id) == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(LibraryHomeDesignToken.bgSecondary)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(LibraryHomeDesignToken.borderStrong)
                    .frame(height: 1)
            }
        }
    }

    private func trackList(for album: AlbumScanRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("曲目")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                .tracking(0.5)
                .textCase(.uppercase)
                .padding(.leading, 42)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(album.audioFiles) { audioFile in
                    trackRow(AlbumAudioTrackDisplayItem(audioFile: audioFile))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            LibraryDividerLine()
        }
    }

    private func trackRow(_ track: AlbumAudioTrackDisplayItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                .frame(width: 32, height: 32)
                .background(LibraryHomeDesignToken.bgElevated, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusSm))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if track.hasReadError {
                        Label("标签异常", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(LibraryHomeDesignToken.warning)
                            .help(track.readError ?? "标签读取失败")
                    }
                }

                Text(track.sequenceText == "-" ? "整轨文件" : "音频文件")
                    .font(.system(size: 11))
                    .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                    .lineLimit(1)
                    .help(track.relativePath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.formatText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(LibraryHomeDesignToken.bgTertiary, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusSm))
        .padding(.bottom, 6)
    }

    private func cover(for album: AlbumScanRecord) -> some View {
        CachedAlbumCoverPreview(
            url: pendingCoverURL ?? displayedCoverURL(for: album),
            maxPixelSize: 600,
            placeholderSize: 36,
            cornerRadius: 10
        )
    }

    private var pendingCoverURL: URL? {
        appModel.pendingCoverURL(for: albumID)
    }

    private func displayedCoverURL(for album: AlbumScanRecord) -> URL? {
        album.displayedCover?.displayURL
    }

    private func savePendingCover() {
        CoverDropDebugLog.write("保存封面：用户点击保存按钮，albumID=\(albumID)")
        Task {
            let didSave = await appModel.savePendingCoverImage(forAlbumID: albumID)
            if didSave {
                onClose()
            }
        }
    }

    private func infoField(
        title: String,
        value: String,
        monospaced: Bool = false,
        copyAction: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                .frame(width: 48, alignment: .leading)

            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .caption)
                .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let copyAction {
                Button(action: copyAction) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                .help("复制搜索词")
            }
        }
    }

    private func searchKeyword(for album: AlbumScanRecord) -> String {
        appModel.searchKeyword(for: album)
    }

    private func copySearchKeyword(for album: AlbumScanRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(searchKeyword(for: album), forType: .string)
    }
}

private struct CoverSearchSheet: View {
    let album: AlbumScanRecord
    @ObservedObject var appModel: AppModel
    let searchConfiguration: AppConfiguration.CoverSearch
    @Binding var selectedSourceID: AppConfiguration.CoverSearchSource.ID
    @Environment(\.dismiss) private var dismiss
    @State private var isDropTargeted = false
    @State private var webLoadErrorMessage: String?
    @State private var capturedWebImageURL: URL?
    @State private var capturedWebImageAt = Date.distantPast
    @State private var reloadID = UUID()

    private let sheetSize = CGSize(width: 1100, height: 700)

    private var keyword: String {
        appModel.searchKeyword(for: album)
    }

    private var selectedSource: AppConfiguration.CoverSearchSource {
        searchConfiguration.source(id: selectedSourceID)
    }

    private var searchURL: URL? {
        selectedSource.url(for: keyword)
    }

    var body: some View {
        HStack(spacing: 0) {
            browserArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            sidePanel
                .frame(width: 320)
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .background(LibraryHomeDesignToken.bgPrimary)
        .onAppear {
            DispatchQueue.main.async {
                if selectedSourceID.isEmpty {
                    selectedSourceID = searchConfiguration.defaultSource.id
                }
            }
        }
        .onChange(of: searchURL) {
            clearCapturedWebImage()
        }
    }

    private var browserArea: some View {
        VStack(spacing: 0) {
            urlBar

            Group {
                if let searchURL {
                    ZStack {
                        CoverSearchWebView(
                            url: searchURL,
                            reloadID: reloadID,
                            errorMessage: $webLoadErrorMessage,
                            onImageURLCaptured: { imageURL in
                                cacheCapturedWebImage(imageURL)
                            }
                        )

                        if let webLoadErrorMessage {
                            webLoadError(webLoadErrorMessage)
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("无法生成搜索页面", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("请检查搜索源配置。")
                    }
                    .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                }
            }
        }
    }

    private var urlBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left")
                .frame(width: 24, height: 24)
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
            Image(systemName: "chevron.right")
                .frame(width: 24, height: 24)
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)

            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LibraryHomeDesignToken.success)
                Text(searchURL?.absoluteString ?? "无法生成搜索页面")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(LibraryHomeDesignToken.bgPrimary, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusSm))

            Button {
                reloadID = UUID()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LibraryHomeDesignToken.textSecondary)
            .disabled(searchURL == nil)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(LibraryHomeDesignToken.bgTertiary)
        .overlay(alignment: .bottom) {
            LibraryDividerLine()
        }
    }

    private func webLoadError(_ message: String) -> some View {
        ContentUnavailableView {
            Label("内置网页加载失败", systemImage: "network.slash")
        } description: {
            Text(message)
        } actions: {
            Button {
                openExternally()
            } label: {
                Label("在浏览器中打开", systemImage: "safari")
            }
            .disabled(searchURL == nil)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(32)
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelAlbumInfo
            keywordPanel

            dropZone
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            sourceTabs

            HStack {
                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.coverDropSubtle)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Label("返回详情保存", systemImage: "arrow.left")
                }
                .buttonStyle(.coverDropPrimary(height: 34))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .top) {
                LibraryDividerLine()
            }
        }
        .background(LibraryHomeDesignToken.bgSecondary)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LibraryHomeDesignToken.border)
                .frame(width: 1)
        }
    }

    private var panelAlbumInfo: some View {
        HStack(spacing: 12) {
            CachedAlbumCoverPreview(
                url: pendingCoverURL ?? displayedCoverURL,
                maxPixelSize: 160,
                placeholderSize: 18,
                cornerRadius: LibraryHomeDesignToken.radiusMd
            )
            .frame(width: 56, height: 56)
            .overlay(alignment: .bottomTrailing) {
                if album.displayedCover == nil {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                        .frame(width: 16, height: 16)
                        .background(LibraryHomeDesignToken.warning, in: Circle())
                        .offset(x: 4, y: 4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(appModel.displayAlbumName(for: album))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(appModel.displayAlbumName(for: album))
                Text(appModel.displayArtistName(for: album))
                    .font(.system(size: 12))
                    .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(album.displayedCover == nil ? LibraryHomeDesignToken.warning : LibraryHomeDesignToken.success)
                        .frame(width: 6, height: 6)
                    Text("当前封面：\(album.displayedCover == nil ? "缺失" : "已有")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(album.displayedCover == nil ? LibraryHomeDesignToken.warning : LibraryHomeDesignToken.success)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .overlay(alignment: .bottom) {
            LibraryDividerLine()
        }
    }

    private var keywordPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("搜索封面")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                .tracking(0.5)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                Text(keyword)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .background(LibraryHomeDesignToken.bgTertiary, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusMd))
                    .overlay {
                        RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusMd)
                            .stroke(LibraryHomeDesignToken.border)
                    }
                    .help(keyword)

                Button {
                    copyKeyword()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                .background(LibraryHomeDesignToken.bgTertiary, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusMd))
                .overlay {
                    RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusMd)
                        .stroke(LibraryHomeDesignToken.borderStrong)
                }
                .help("复制搜索词")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            LibraryDividerLine()
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Button {
                chooseCoverImage()
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 40, weight: .regular))
                    Text("拖入图片或点击选择")
                        .font(.callout.weight(.medium))
                    Text("支持 JPG、PNG、WebP")
                        .font(.caption)
                        .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                }
                .foregroundStyle(isDropTargeted ? LibraryHomeDesignToken.accent : LibraryHomeDesignToken.textTertiary)
                .frame(width: 180, height: 180)
                .background(isDropTargeted ? LibraryHomeDesignToken.accentBg : .clear, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusLg))
                .overlay {
                    RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusLg)
                        .stroke(
                            isDropTargeted ? LibraryHomeDesignToken.accent : LibraryHomeDesignToken.borderStrong,
                            style: StrokeStyle(lineWidth: 1, dash: [7])
                        )
                }
            }
            .buttonStyle(.plain)
            .onDrop(
                of: CoverDropReceiver.typeIdentifiers,
                isTargeted: $isDropTargeted
            ) { providers in
                let fallbackRemoteURL = freshCapturedWebImageURL()
                let didAccept = CoverDropReceiver.receive(
                    providers,
                    albumID: album.id,
                    appModel: appModel,
                    fallbackRemoteURL: fallbackRemoteURL,
                    onAccepted: { dismiss() }
                )
                if didAccept {
                    clearCapturedWebImage()
                }
                return didAccept
            }

            if let pendingCoverURL = appModel.pendingCoverURL(for: album.id) {
                Label("已暂存：\(pendingCoverURL.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LibraryHomeDesignToken.success)
                    .lineLimit(2)
                    .help(pendingCoverURL.path)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceTabs: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(searchConfiguration.enabledSources) { source in
                    Button {
                        selectedSourceID = source.id
                    } label: {
                        Text(source.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(source.id == selectedSourceID ? LibraryHomeDesignToken.accent : LibraryHomeDesignToken.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(source.id == selectedSourceID ? LibraryHomeDesignToken.accent : .clear)
                                    .frame(height: 2)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(alignment: .bottom) {
                LibraryDividerLine()
            }

            Button {
                openExternally()
            } label: {
                Label("在浏览器中打开", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.coverDropSecondary(height: 34))
            .disabled(searchURL == nil)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var pendingCoverURL: URL? {
        appModel.pendingCoverURL(for: album.id)
    }

    private var displayedCoverURL: URL? {
        album.displayedCover?.displayURL
    }

    private func openExternally() {
        guard let searchURL else { return }
        NSWorkspace.shared.open(searchURL)
    }

    private func copyKeyword() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(keyword, forType: .string)
    }

    private func chooseCoverImage() {
        let panel = NSOpenPanel()
        panel.title = "选择封面图片"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .image]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        appModel.stageCoverImage(url, forAlbumID: album.id)
        dismiss()
    }

    private func cacheCapturedWebImage(_ imageURL: URL) {
        capturedWebImageURL = imageURL
        capturedWebImageAt = Date()
        CoverDropDebugLog.write(
            "内置网页图片捕获：已缓存图片 URL，等待用户拖到右侧封面方块后再暂存：\(imageURL.absoluteString)"
        )
    }

    private func freshCapturedWebImageURL() -> URL? {
        guard let capturedWebImageURL else { return nil }

        let elapsedSeconds = Date().timeIntervalSince(capturedWebImageAt)
        guard elapsedSeconds <= 30 else {
            CoverDropDebugLog.write(
                "内置网页图片捕获：已缓存图片 URL 超过 30 秒，忽略旧缓存：\(capturedWebImageURL.absoluteString)"
            )
            return nil
        }

        return capturedWebImageURL
    }

    private func clearCapturedWebImage() {
        capturedWebImageURL = nil
        capturedWebImageAt = .distantPast
    }
}

private enum CoverDropReceiver {
    private struct SendableItemProvider: @unchecked Sendable {
        nonisolated(unsafe) let value: NSItemProvider
    }

    private struct URLItemRepresentation: @unchecked Sendable {
        let provider: SendableItemProvider
        let typeIdentifier: String
    }

    static let imageTypeIdentifiers = [
        UTType.jpeg.identifier,
        UTType.png.identifier,
        UTType.tiff.identifier,
        "org.webmproject.webp",
        UTType.image.identifier
    ]

    static let urlTypeIdentifiers = [
        UTType.url.identifier
    ] + textURLTypeIdentifiers + [
        UTType.fileURL.identifier
    ]

    static let textURLTypeIdentifiers = [
        "public.utf8-plain-text",
        "public.plain-text",
        "public.text"
    ]

    static let typeIdentifiers = imageTypeIdentifiers + urlTypeIdentifiers

    @MainActor
    static func receive(
        _ providers: [NSItemProvider],
        albumID: AlbumScanRecord.ID,
        appModel: AppModel,
        fallbackRemoteURL: URL? = nil,
        onAccepted: (() -> Void)? = nil
    ) -> Bool {
        guard providers.count == 1, let provider = providers.first else {
            appModel.errorMessage = "请一次只拖入一张图片。"
            return false
        }

        CoverDropDebugLog.write(
            "封面拖拽：provider 暴露类型：\(provider.registeredTypeIdentifiers.joined(separator: ", "))"
        )
        let urlRepresentations = urlRepresentations(in: provider)
        CoverDropDebugLog.write(
            "封面拖拽：可用 URL representation：\(urlRepresentations.map(\.typeIdentifier).joined(separator: ", "))"
        )

        if let imageTypeIdentifier = imageTypeIdentifiers.first(where: {
            provider.hasItemConformingToTypeIdentifier($0)
        }) {
            CoverDropDebugLog.write("封面拖拽：优先读取图片 representation：\(imageTypeIdentifier)")
            onAccepted?()
            loadImageData(
                from: provider,
                typeIdentifier: imageTypeIdentifier,
                urlRepresentations: urlRepresentations,
                fallbackRemoteURL: fallbackRemoteURL,
                albumID: albumID,
                appModel: appModel
            )
            return true
        }

        if loadFirstURLIfAvailable(
            from: urlRepresentations,
            fallbackRemoteURL: fallbackRemoteURL,
            albumID: albumID,
            appModel: appModel
        ) {
            onAccepted?()
            return true
        }

        CoverDropDebugLog.write("封面拖拽：没有找到可读取的图片或 URL representation")
        appModel.errorMessage = "请拖入图片文件，或网页里的图片。"
        return false
    }

    nonisolated private static func loadURL(
        from representation: URLItemRepresentation,
        remainingRepresentations: ArraySlice<URLItemRepresentation> = [],
        albumID: AlbumScanRecord.ID,
        appModel: AppModel
    ) {
        CoverDropDebugLog.write("封面拖拽：开始读取 URL representation：\(representation.typeIdentifier)")
        representation.provider.value.loadItem(forTypeIdentifier: representation.typeIdentifier, options: nil) { item, error in
            if let error {
                CoverDropDebugLog.write(
                    "封面拖拽：读取 URL representation 失败，type=\(representation.typeIdentifier)，\(debugDescription(for: error))"
                )
                if let url = remoteURL(from: error) {
                    CoverDropDebugLog.write("封面拖拽：从 URL representation 错误文案提取到远程 URL：\(url.absoluteString)")
                    Task {
                        await appModel.stageDroppedCoverURL(url, forAlbumID: albumID)
                    }
                    return
                }

                CoverDropDebugLog.write("封面拖拽：当前 URL representation 未提取到远程 URL，尝试下一个")
                if loadFirstURLIfAvailable(
                    from: remainingRepresentations,
                    albumID: albumID,
                    appModel: appModel
                ) {
                    return
                }

                Task { @MainActor in
                    appModel.errorMessage = "无法读取拖入的图片地址：\(error.localizedDescription)"
                }
                return
            }

            guard let url = droppedURL(from: item) else {
                CoverDropDebugLog.write(
                    "封面拖拽：URL representation 返回了无法识别的对象，type=\(representation.typeIdentifier)，对象类型=\(String(describing: item.map { Swift.type(of: $0) }))"
                )
                if loadFirstURLIfAvailable(
                    from: remainingRepresentations,
                    albumID: albumID,
                    appModel: appModel
                ) {
                    return
                }

                Task { @MainActor in
                    appModel.errorMessage = "无法识别拖入的图片地址。"
                }
                return
            }

            CoverDropDebugLog.write(
                "封面拖拽：URL representation 读取成功，type=\(representation.typeIdentifier)，URL=\(url.absoluteString)"
            )
            Task {
                await appModel.stageDroppedCoverURL(url, forAlbumID: albumID)
            }
        }
    }

    private static func loadImageData(
        from provider: NSItemProvider,
        typeIdentifier: String,
        urlRepresentations: [URLItemRepresentation],
        fallbackRemoteURL: URL?,
        albumID: AlbumScanRecord.ID,
        appModel: AppModel
    ) {
        CoverDropDebugLog.write("封面拖拽：开始读取图片数据 representation：\(typeIdentifier)")
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
            if let error {
                CoverDropDebugLog.write(
                    "封面拖拽：读取图片数据 representation 失败，type=\(typeIdentifier)，\(debugDescription(for: error))"
                )
                if let url = remoteURL(from: error) {
                    CoverDropDebugLog.write("封面拖拽：从图片数据错误文案提取到远程 URL：\(url.absoluteString)")
                    Task {
                        await appModel.stageDroppedCoverURL(url, forAlbumID: albumID)
                    }
                    return
                }

                if urlRepresentations.isEmpty {
                    CoverDropDebugLog.write(
                        "封面拖拽：provider 无 URL representation，\(typeIdentifier) 无可用 loader；如果来自内置搜索页，将尝试使用 WKWebView 已缓存图片 URL。"
                    )
                }

                if loadURLFallbackIfAvailable(
                    from: urlRepresentations,
                    albumID: albumID,
                    appModel: appModel
                ) {
                    return
                }

                if let fallbackRemoteURL {
                    CoverDropDebugLog.write(
                        "封面拖拽：使用 WKWebView 已缓存图片 URL 暂存：\(fallbackRemoteURL.absoluteString)"
                    )
                    Task {
                        await appModel.stageDroppedCoverURL(fallbackRemoteURL, forAlbumID: albumID)
                    }
                    return
                }

                Task { @MainActor in
                    appModel.errorMessage = "无法读取拖入的网页图片：\(error.localizedDescription)"
                }
                return
            }

            guard let data else {
                CoverDropDebugLog.write("封面拖拽：图片数据 representation 成功回调但 data 为 nil，type=\(typeIdentifier)")
                if loadURLFallbackIfAvailable(
                    from: urlRepresentations,
                    albumID: albumID,
                    appModel: appModel
                ) {
                    return
                }

                if let fallbackRemoteURL {
                    CoverDropDebugLog.write(
                        "封面拖拽：图片数据为空，使用 WKWebView 已缓存图片 URL 暂存：\(fallbackRemoteURL.absoluteString)"
                    )
                    Task {
                        await appModel.stageDroppedCoverURL(fallbackRemoteURL, forAlbumID: albumID)
                    }
                    return
                }

                Task { @MainActor in
                    appModel.errorMessage = "拖入的网页图片没有可用数据。"
                }
                return
            }

            CoverDropDebugLog.write("封面拖拽：图片数据 representation 读取成功，type=\(typeIdentifier)，大小=\(data.count) bytes")
            Task { @MainActor in
                appModel.stageCoverImageData(
                    data,
                    suggestedExtension: suggestedExtension(for: typeIdentifier),
                    forAlbumID: albumID
                )
            }
        }
    }

    nonisolated private static func loadURLFallbackIfAvailable(
        from representations: [URLItemRepresentation],
        albumID: AlbumScanRecord.ID,
        appModel: AppModel
    ) -> Bool {
        loadFirstURLIfAvailable(
            from: representations[...],
            albumID: albumID,
            appModel: appModel
        )
    }

    nonisolated private static func loadFirstURLIfAvailable(
        from representations: ArraySlice<URLItemRepresentation>,
        albumID: AlbumScanRecord.ID,
        appModel: AppModel
    ) -> Bool {
        guard let representation = representations.first else { return false }

        loadURL(
            from: representation,
            remainingRepresentations: representations.dropFirst(),
            albumID: albumID,
            appModel: appModel
        )
        return true
    }

    private static func loadFirstURLIfAvailable(
        from representations: [URLItemRepresentation],
        fallbackRemoteURL: URL?,
        albumID: AlbumScanRecord.ID,
        appModel: AppModel
    ) -> Bool {
        if loadFirstURLIfAvailable(
            from: representations[...],
            albumID: albumID,
            appModel: appModel
        ) {
            return true
        }

        guard let fallbackRemoteURL else { return false }
        CoverDropDebugLog.write(
            "封面拖拽：没有 URL representation，使用 WKWebView 已缓存图片 URL 暂存：\(fallbackRemoteURL.absoluteString)"
        )
        Task {
            await appModel.stageDroppedCoverURL(fallbackRemoteURL, forAlbumID: albumID)
        }
        return true
    }

    private static func urlRepresentations(in provider: NSItemProvider) -> [URLItemRepresentation] {
        let sendableProvider = SendableItemProvider(value: provider)
        return urlTypeIdentifiers
            .filter { provider.hasItemConformingToTypeIdentifier($0) }
            .map { URLItemRepresentation(provider: sendableProvider, typeIdentifier: $0) }
    }

    nonisolated private static func droppedURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return url
            }

            if let string = String(data: data, encoding: .utf8) {
                return URL(string: cleanedURLString(string))
            }
        }

        if let string = item as? String {
            return URL(string: cleanedURLString(string))
        }

        if let string = item as? NSString {
            return URL(string: cleanedURLString(string as String))
        }

        return nil
    }

    nonisolated private static func remoteURL(from error: Error) -> URL? {
        CoverDropRemoteURLExtractor.firstRemoteURL(in: error)
    }

    nonisolated private static func cleanedURLString(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func debugDescription(for error: Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain)，code=\(nsError.code)，description=\(nsError.localizedDescription)"
    }

    nonisolated private static func suggestedExtension(for typeIdentifier: String) -> String? {
        switch typeIdentifier {
        case UTType.jpeg.identifier:
            return "jpg"
        case UTType.png.identifier:
            return "png"
        case UTType.tiff.identifier:
            return "tiff"
        case "org.webmproject.webp":
            return "webp"
        default:
            return nil
        }
    }
}

private struct CoverSearchWebView: NSViewRepresentable {
    let url: URL
    let reloadID: UUID
    @Binding var errorMessage: String?
    let onImageURLCaptured: (URL) -> Void

    private static let imageMessageHandlerName = "coverDropImageCapture"

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addUserScript(Self.imageCaptureScript)
        configuration.userContentController.add(
            context.coordinator,
            name: Self.imageMessageHandlerName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        CoverDropDebugLog.write("内置网页图片捕获：已安装 dragstart 缓存脚本。")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onImageURLCaptured = onImageURLCaptured
        let requestID = "\(url.absoluteString)#\(reloadID.uuidString)"
        guard context.coordinator.lastRequestID != requestID else { return }
        context.coordinator.lastRequestID = requestID
        context.coordinator.clearErrorMessage()
        webView.load(URLRequest(url: url))
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: imageMessageHandlerName
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            errorMessage: $errorMessage,
            onImageURLCaptured: onImageURLCaptured
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var errorMessage: Binding<String?>
        var onImageURLCaptured: (URL) -> Void
        var lastRequestID: String?

        init(
            errorMessage: Binding<String?>,
            onImageURLCaptured: @escaping (URL) -> Void
        ) {
            self.errorMessage = errorMessage
            self.onImageURLCaptured = onImageURLCaptured
        }

        func clearErrorMessage() {
            DispatchQueue.main.async { [errorMessage] in
                errorMessage.wrappedValue = nil
            }
        }

        private func setErrorMessage(_ message: String?) {
            DispatchQueue.main.async { [errorMessage] in
                errorMessage.wrappedValue = message
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            setErrorMessage(Self.message(for: error))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            setErrorMessage(Self.message(for: error))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            setErrorMessage("内置网页进程已终止。请使用“在浏览器中打开”继续搜索。")
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == CoverSearchWebView.imageMessageHandlerName else {
                return
            }

            guard let payload = message.body as? [String: Any],
                  let urlString = payload["url"] as? String,
                  let url = URL(string: urlString),
                  ["http", "https"].contains(url.scheme?.lowercased()) else {
                CoverDropDebugLog.write("内置网页图片捕获：收到无效图片 URL payload：\(message.body)")
                return
            }

            CoverDropDebugLog.write(
                "内置网页图片捕获：dragstart 捕获图片 URL：\(url.absoluteString)"
            )
            onImageURLCaptured(url)
        }

        private static func message(for error: any Error) -> String? {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCancelled {
                return nil
            }
            return "无法加载当前搜索页：\(error.localizedDescription)。请使用“在浏览器中打开”。"
        }
    }

    private static let imageCaptureScript = WKUserScript(
        source: """
        (() => {
          if (window.__coverDropImageCaptureInstalled) {
            return;
          }
          window.__coverDropImageCaptureInstalled = true;

          function imageFromEvent(event) {
            const candidates = [];
            if (event.target) {
              candidates.push(event.target);
            }
            if (typeof event.composedPath === 'function') {
              candidates.push(...event.composedPath());
            }

            for (const candidate of candidates) {
              if (!candidate || candidate === window || candidate === document) {
                continue;
              }
              if (candidate.tagName === 'IMG') {
                return candidate;
              }
              if (candidate.closest) {
                const image = candidate.closest('img');
                if (image) {
                  return image;
                }
              }
            }
            return null;
          }

          function absoluteURL(value) {
            if (!value) {
              return null;
            }
            try {
              return new URL(value, document.baseURI).href;
            } catch (_) {
              return null;
            }
          }

          function sendImageURL(event) {
            const image = imageFromEvent(event);
            const url = image ? absoluteURL(image.currentSrc || image.src || image.getAttribute('src')) : null;
            if (!url || !/^https?:\\/\\//i.test(url)) {
              return;
            }

            window.webkit.messageHandlers.coverDropImageCapture.postMessage({
              url,
              alt: image.alt || ''
            });
          }

          document.addEventListener('dragstart', sendImageURL, true);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: false
    )
}

private struct CachedCoverFillView: View {
    let url: URL?
    let maxPixelSize: CGFloat
    let placeholderSize: CGFloat
    let placeholderText: String?

    @State private var image: NSImage?

    private var thumbnailIdentity: String {
        CoverPreviewCache.thumbnailIdentity(for: url, maxPixelSize: maxPixelSize)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: placeholderSize, weight: .medium))
                    if let placeholderText {
                        Text(placeholderText)
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LibraryHomeDesignToken.bgPrimary)
            }
        }
        .task(id: thumbnailIdentity) {
            await loadThumbnail(expectedIdentity: thumbnailIdentity)
        }
    }

    @MainActor
    private func loadThumbnail(expectedIdentity: String) async {
        guard let url else {
            image = nil
            return
        }

        image = nil
        let maxPixelSize = maxPixelSize
        let loadedImage = await Task.detached(priority: .utility) {
            CoverPreviewCache.cachedImage(for: url, maxPixelSize: maxPixelSize)
        }.value

        guard !Task.isCancelled,
              expectedIdentity == thumbnailIdentity else {
            return
        }
        image = loadedImage
    }
}

private struct CachedAlbumCoverPreview: View {
    let url: URL?
    let maxPixelSize: CGFloat
    let placeholderSize: CGFloat
    let cornerRadius: CGFloat

    @State private var image: NSImage?

    private var thumbnailIdentity: String {
        CoverPreviewCache.thumbnailIdentity(for: url, maxPixelSize: maxPixelSize)
    }

    var body: some View {
        AlbumCoverPreview(
            image: image,
            placeholderSize: placeholderSize,
            cornerRadius: cornerRadius
        )
        .task(id: thumbnailIdentity) {
            await loadThumbnail(expectedIdentity: thumbnailIdentity)
        }
    }

    @MainActor
    private func loadThumbnail(expectedIdentity: String) async {
        guard let url else {
            image = nil
            return
        }

        image = nil
        let maxPixelSize = maxPixelSize
        let loadedImage = await Task.detached(priority: .utility) {
            CoverPreviewCache.cachedImage(for: url, maxPixelSize: maxPixelSize)
        }.value

        guard !Task.isCancelled,
              expectedIdentity == thumbnailIdentity else {
            return
        }
        image = loadedImage
    }
}

private struct AlbumCoverPreview: View {
    let image: NSImage?
    let placeholderSize: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let containerSize = geometry.size

            ZStack {
                if let image {
                    let fittedSize = fittedImageSize(
                        imageSize: image.size,
                        containerSize: containerSize
                    )

                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.secondary.opacity(0.12))
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: fittedSize.width, height: fittedSize.height)
                    }
                    .frame(width: fittedSize.width, height: fittedSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(.separator.opacity(0.45))
                    }
                    .frame(width: containerSize.width, height: containerSize.height)
                } else {
                    ZStack {
                        Rectangle()
                            .fill(.secondary.opacity(0.12))
                        Image(systemName: "music.note")
                            .font(.system(size: placeholderSize))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: containerSize.width, height: containerSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(.separator.opacity(0.45))
                    }
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
    }

    private func fittedImageSize(
        imageSize: NSSize,
        containerSize: CGSize
    ) -> CGSize {
        let maxWidth = max(1, containerSize.width)
        let maxHeight = max(1, containerSize.height)
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: maxWidth, height: maxHeight)
        }

        let imageAspectRatio = imageSize.width / imageSize.height
        let containerAspectRatio = maxWidth / maxHeight
        if imageAspectRatio > containerAspectRatio {
            return CGSize(width: maxWidth, height: maxWidth / imageAspectRatio)
        } else {
            return CGSize(width: maxHeight * imageAspectRatio, height: maxHeight)
        }
    }
}
