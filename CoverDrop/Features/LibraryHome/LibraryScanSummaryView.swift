import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct LibraryScanSummaryView: View {
    let result: LibraryScanResult
    let appModel: AppModel

    @State private var filter: AlbumScanResultFilter = .all
    @State private var query = ""
    @State private var selectedAlbumID: AlbumScanRecord.ID?
    @State private var isShowingAlbumDetail = false

    private var filteredAlbums: [AlbumScanRecord] {
        AlbumScanResultFiltering.albums(in: result, filter: filter, query: query)
    }

    private var filteredLooseAudioPaths: [String] {
        AlbumScanResultFiltering.looseAudioPaths(in: result, filter: filter, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(spacing: 24) {
                summary("专辑", value: result.albums.count)
                summary("已有封面", value: result.albumsWithCover)
                summary("缺封面", value: result.albums.count - result.albumsWithCover)
                summary("需要确认", value: result.albumsNeedingAttention)
                summary("散落音频", value: result.looseAudioPaths.count)
            }

            filterControls

            if shouldShowAlbums {
                Divider()
                albumGrid
            } else if filter != .looseAudio {
                emptyState("没有符合筛选条件的专辑。", systemImage: "square.grid.2x2")
            }

            if shouldShowLooseAudio {
                if shouldShowAlbums {
                    Divider()
                }
                looseAudioList
            } else if filter == .looseAudio {
                emptyState("没有符合筛选条件的散落音频。", systemImage: "music.note.list")
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $isShowingAlbumDetail) {
            if let selectedAlbumID {
                AlbumDetailSheet(
                    albumID: selectedAlbumID,
                    appModel: appModel
                )
            }
        }
        .onChange(of: isShowingAlbumDetail) { _, isShowing in
            if !isShowing {
                if let selectedAlbumID {
                    appModel.cancelPendingCoverImage(forAlbumID: selectedAlbumID)
                }
                selectedAlbumID = nil
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("扫描结果")
                    .font(.headline)
                Text("按封面状态浏览专辑，先找最需要处理的部分。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(visibleResultCount) 项")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("按歌手、专辑或路径筛选", text: $query)
                .textFieldStyle(.roundedBorder)

            Picker("结果筛选", selection: $filter) {
                ForEach(AlbumScanResultFilter.allCases) { option in
                    Text(option.displayName)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var albumGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12)
                ],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(filteredAlbums) { album in
                    AlbumCoverCard(album: album, appModel: appModel) {
                        openAlbumDetail(albumID: album.id, pendingCoverURL: nil)
                    } onAcceptedCoverDrop: {
                        openAlbumDetail(albumID: album.id, pendingCoverURL: nil)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(minHeight: 320, maxHeight: .infinity)
    }

    private var looseAudioList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("散落音频", systemImage: "music.note.list")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(filteredLooseAudioPaths, id: \.self) { path in
                        Label(path, systemImage: "music.note")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                    }
                }
            }
            .frame(maxHeight: filter == .looseAudio ? 360 : 120)
        }
    }

    private var shouldShowAlbums: Bool {
        !filteredAlbums.isEmpty
    }

    private var shouldShowLooseAudio: Bool {
        !filteredLooseAudioPaths.isEmpty
    }

    private var visibleResultCount: Int {
        filteredAlbums.count + filteredLooseAudioPaths.count
    }

    private func summary(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.title2.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func emptyState(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        }
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
}

private struct AlbumCoverCard: View {
    let album: AlbumScanRecord
    let appModel: AppModel
    let onOpen: () -> Void
    let onAcceptedCoverDrop: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                cover
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        if album.needsAttention {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .padding(6)
                                .help(album.issues.map(\.displayName).joined(separator: "\n"))
                        }
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(album.albumName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .help(album.albumName)

                    Text("\(album.artistName) · \(album.audioFiles.count) 个音频")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(album.folderURL.path)
                }

                HStack(spacing: 6) {
                    statusBadge
                    if album.needsAttention {
                        Text("需确认")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }

                if let message = appModel.coverWriteMessage(for: album.id) {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isDropTargeted
                        ? AnyShapeStyle(.tint)
                        : AnyShapeStyle(.separator.opacity(0.45)),
                    lineWidth: isDropTargeted ? 3 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .help("点击查看专辑详情")
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

    private var cover: some View {
        AlbumCoverPreview(
            image: displayedCoverImage,
            placeholderSize: 34,
            cornerRadius: 8
        )
    }

    private var displayedCoverImage: NSImage? {
        guard let url = album.displayedCover?.displayURL else { return nil }
        return AlbumCoverImageLoader.loadImage(at: url)
    }

    private var statusBadge: some View {
        Text(album.displayedCover?.source.displayName ?? "缺封面")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.16), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        album.displayedCover == nil ? .secondary : .green
    }
}

private struct AlbumDetailSheet: View {
    let albumID: AlbumScanRecord.ID
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss
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
                        appModel.cancelPendingCoverImage(forAlbumID: albumID)
                        dismiss()
                    }
                }
                .frame(width: 760, height: 560)
            }
        }
        .padding(24)
        .frame(width: 760, height: 560)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
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
        VStack(alignment: .leading, spacing: 16) {
            detailToolbar(for: album)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 22) {
                        cover(for: album)
                            .frame(width: 260, height: 260)
                            .overlay(alignment: .topTrailing) {
                                if appModel.pendingCoverURL(for: album.id) != nil {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                        .padding(8)
                                        .background(.regularMaterial, in: Circle())
                                        .padding(8)
                                }
                            }

                        VStack(alignment: .leading, spacing: 10) {
                            Text(album.albumName)
                                .font(.title.bold())
                                .lineLimit(3)
                                .textSelection(.enabled)
                                .help(album.albumName)

                            Text(album.artistName)
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .help(album.artistName)

                            VStack(alignment: .leading, spacing: 7) {
                                Label("\(album.audioFiles.count) 个音频", systemImage: "music.note.list")
                                Label(
                                    album.displayedCover?.source.displayName ?? "缺封面",
                                    systemImage: album.displayedCover == nil ? "photo.badge.exclamationmark" : "photo"
                                )
                            }
                            .font(.callout)

                            Divider()

                            if let pendingCoverURL = appModel.pendingCoverURL(for: album.id) {
                                Label("待保存：\(pendingCoverURL.lastPathComponent)", systemImage: "photo.badge.plus")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.tint)
                                    .lineLimit(1)
                                    .help(pendingCoverURL.path)
                            } else if let message = appModel.coverWriteMessage(for: album.id) {
                                Label(message, systemImage: "checkmark.circle.fill")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.green)
                            }

                            detailRow("搜索词", searchKeyword(for: album))
                            detailRow("专辑路径", album.folderURL.path)
                            if let cover = album.displayedCover {
                                detailRow("封面路径", cover.url.path)
                            } else {
                                detailRow("封面路径", "无")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                    }

                    Divider()

                    if !album.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("需要确认")
                                .font(.headline)
                            ForEach(album.issues.map(\.displayName), id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    trackList(for: album)
                }
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([album.folderURL])
                }

                Spacer()

                Button("保存") {
                    savePendingCover()
                }
                .disabled(appModel.pendingCoverURL(for: album.id) == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func detailToolbar(for album: AlbumScanRecord) -> some View {
        HStack(spacing: 10) {
            Button {
                appModel.cancelPendingCoverImage(forAlbumID: albumID)
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("返回")

            Spacer()

            Button {
                isShowingCoverSearch = true
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }

            Button {
                copySearchKeyword(for: album)
            } label: {
                Label("复制搜索词", systemImage: "doc.on.doc")
            }
        }
    }

    private func trackList(for album: AlbumScanRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("歌曲列表")
                .font(.headline)

            LazyVStack(alignment: .leading, spacing: 0) {
                trackListHeader

                ForEach(album.audioFiles.map(AlbumAudioTrackDisplayItem.init(audioFile:)), id: \.relativePath) { track in
                    trackRow(track)
                }
            }
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.45))
            }
        }
    }

    private var trackListHeader: some View {
        HStack(spacing: 12) {
            Text("序号")
                .frame(width: 48, alignment: .leading)
            Text("歌曲")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("格式")
                .frame(width: 54, alignment: .leading)
            Text("时长")
                .frame(width: 58, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func trackRow(_ track: AlbumAudioTrackDisplayItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(track.sequenceText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if track.hasReadError {
                        Label("标签异常", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .help(track.readError ?? "标签读取失败")
                    }
                }

                Text(track.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(track.relativePath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.formatText)
                .font(.caption.weight(.medium))
                .frame(width: 54, alignment: .leading)

            Text(track.durationText ?? "-")
                .font(.caption.monospacedDigit())
                .foregroundStyle(track.durationText == nil ? .secondary : .primary)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func cover(for album: AlbumScanRecord) -> some View {
        AlbumCoverPreview(
            image: pendingCoverImage ?? displayedCoverImage(for: album),
            placeholderSize: 36,
            cornerRadius: 10
        )
    }

    private var pendingCoverImage: NSImage? {
        guard let pendingCoverURL = appModel.pendingCoverURL(for: albumID) else { return nil }
        return AlbumCoverImageLoader.loadImage(at: pendingCoverURL)
    }

    private func displayedCoverImage(for album: AlbumScanRecord) -> NSImage? {
        guard let url = album.displayedCover?.displayURL else { return nil }
        return AlbumCoverImageLoader.loadImage(at: url)
    }

    private func savePendingCover() {
        Task {
            let didSave = await appModel.savePendingCoverImage(forAlbumID: albumID)
            if didSave {
                dismiss()
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }

    private func searchKeyword(for album: AlbumScanRecord) -> String {
        CoverSearchKeyword.make(
            artistName: album.artistName,
            albumName: album.albumName
        )
    }

    private func copySearchKeyword(for album: AlbumScanRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(searchKeyword(for: album), forType: .string)
    }
}

private struct CoverSearchSheet: View {
    let album: AlbumScanRecord
    let appModel: AppModel
    let searchConfiguration: AppConfiguration.CoverSearch
    @Binding var selectedSourceID: AppConfiguration.CoverSearchSource.ID
    @Environment(\.dismiss) private var dismiss
    @State private var isDropTargeted = false
    @State private var webLoadErrorMessage: String?

    private let sheetSize = CGSize(width: 1320, height: 780)

    private var keyword: String {
        CoverSearchKeyword.make(
            artistName: album.artistName,
            albumName: album.albumName
        )
    }

    private var selectedSource: AppConfiguration.CoverSearchSource {
        searchConfiguration.source(id: selectedSourceID)
    }

    private var searchURL: URL? {
        selectedSource.url(for: keyword)
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let searchURL {
                    ZStack {
                        CoverSearchWebView(
                            url: searchURL,
                            errorMessage: $webLoadErrorMessage
                        )
                        .id(searchURL)

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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            sidePanel
                .frame(width: 300)
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .onAppear {
            DispatchQueue.main.async {
                if selectedSourceID.isEmpty {
                    selectedSourceID = searchConfiguration.defaultSource.id
                }
            }
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("搜索封面")
                    .font(.headline)
                Text(keyword)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(keyword)
            }

            Divider()

            Text(album.albumName)
                .font(.headline)
                .lineLimit(3)
                .help(album.albumName)

            Text(album.artistName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            AlbumCoverPreview(
                image: pendingCoverImage ?? displayedCoverImage,
                placeholderSize: 32,
                cornerRadius: 10
            )
            .frame(width: 220, height: 220)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                        style: StrokeStyle(lineWidth: 3, dash: [7])
                    )
            }
            .onDrop(
                of: CoverDropReceiver.typeIdentifiers,
                isTargeted: $isDropTargeted
            ) { providers in
                CoverDropReceiver.receive(
                    providers,
                    albumID: album.id,
                    appModel: appModel,
                    onAccepted: { dismiss() }
                )
            }
            .help("把封面图片拖到这里")

            if let pendingCoverURL = appModel.pendingCoverURL(for: album.id) {
                Label("已暂存：\(pendingCoverURL.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .lineLimit(2)
                    .help(pendingCoverURL.path)
            }

            Text("把图片拖到封面方块上，回到详情页后点击“保存”才会写入 cover.jpg。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("搜索源")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("搜索源", selection: $selectedSourceID) {
                    ForEach(searchConfiguration.enabledSources) { source in
                        Text(source.displayName)
                            .tag(source.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Button {
                    openExternally()
                } label: {
                    Label("在浏览器中打开", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .disabled(searchURL == nil)

                Button {
                    dismiss()
                } label: {
                    Label("关闭", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                dismiss()
            } label: {
                Label("返回详情保存", systemImage: "arrowshape.turn.up.backward")
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var pendingCoverImage: NSImage? {
        guard let url = appModel.pendingCoverURL(for: album.id) else { return nil }
        return AlbumCoverImageLoader.loadImage(at: url)
    }

    private var displayedCoverImage: NSImage? {
        guard let url = album.displayedCover?.displayURL else { return nil }
        return AlbumCoverImageLoader.loadImage(at: url)
    }

    private func openExternally() {
        guard let searchURL else { return }
        NSWorkspace.shared.open(searchURL)
    }
}

private enum CoverDropReceiver {
    static let imageTypeIdentifiers = [
        UTType.jpeg.identifier,
        UTType.png.identifier,
        UTType.tiff.identifier,
        "org.webmproject.webp",
        UTType.image.identifier
    ]

    static let typeIdentifiers = [
        UTType.fileURL.identifier
    ] + imageTypeIdentifiers + [
        UTType.url.identifier
    ]

    @MainActor
    static func receive(
        _ providers: [NSItemProvider],
        albumID: AlbumScanRecord.ID,
        appModel: AppModel,
        onAccepted: (() -> Void)? = nil
    ) -> Bool {
        guard providers.count == 1, let provider = providers.first else {
            appModel.errorMessage = "请一次只拖入一张图片。"
            return false
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            onAccepted?()
            loadURL(
                from: provider,
                typeIdentifier: UTType.fileURL.identifier,
                albumID: albumID,
                appModel: appModel
            )
            return true
        }

        if let imageTypeIdentifier = imageTypeIdentifiers.first(where: {
            provider.hasItemConformingToTypeIdentifier($0)
        }) {
            onAccepted?()
            loadImageData(
                from: provider,
                typeIdentifier: imageTypeIdentifier,
                albumID: albumID,
                appModel: appModel
            )
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            onAccepted?()
            loadURL(
                from: provider,
                typeIdentifier: UTType.url.identifier,
                albumID: albumID,
                appModel: appModel
            )
            return true
        }

        appModel.errorMessage = "请拖入图片文件，或网页里的图片。"
        return false
    }

    private static func loadURL(
        from provider: NSItemProvider,
        typeIdentifier: String,
        albumID: AlbumScanRecord.ID,
        appModel: AppModel
    ) {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
            if let error {
                Task { @MainActor in
                    appModel.errorMessage = "无法读取拖入的图片地址：\(error.localizedDescription)"
                }
                return
            }

            guard let url = droppedURL(from: item) else {
                Task { @MainActor in
                    appModel.errorMessage = "无法识别拖入的图片地址。"
                }
                return
            }

            Task {
                await appModel.stageDroppedCoverURL(url, forAlbumID: albumID)
            }
        }
    }

    private static func loadImageData(
        from provider: NSItemProvider,
        typeIdentifier: String,
        albumID: AlbumScanRecord.ID,
        appModel: AppModel
    ) {
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
            if let error {
                Task { @MainActor in
                    appModel.errorMessage = "无法读取拖入的网页图片：\(error.localizedDescription)"
                }
                return
            }

            guard let data else {
                Task { @MainActor in
                    appModel.errorMessage = "拖入的网页图片没有可用数据。"
                }
                return
            }

            Task { @MainActor in
                appModel.stageCoverImageData(
                    data,
                    suggestedExtension: suggestedExtension(for: typeIdentifier),
                    forAlbumID: albumID
                )
            }
        }
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

    nonisolated private static func cleanedURLString(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
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
    @Binding var errorMessage: String?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        context.coordinator.clearErrorMessage()
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(errorMessage: $errorMessage)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var errorMessage: Binding<String?>

        init(errorMessage: Binding<String?>) {
            self.errorMessage = errorMessage
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

        private static func message(for error: any Error) -> String {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCancelled {
                return "网页加载被取消。请重试或使用“在浏览器中打开”。"
            }
            return "无法加载当前搜索页：\(error.localizedDescription)。请使用“在浏览器中打开”。"
        }
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

private enum AlbumCoverImageLoader {
    static func loadImage(at url: URL) -> NSImage? {
        let options = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary

        if let source = CGImageSourceCreateWithURL(url as CFURL, options),
           CGImageSourceGetCount(source) > 0,
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options) {
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }

        return NSImage(contentsOf: url)
    }
}
