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
    @State private var isSearchExpanded = false
    @State private var hoveredFilter: AlbumScanResultFilter?
    @State private var filterSlideDirection: FilterSlideDirection = .forward
    @State private var debouncedQuery = ""
    @State private var queryDebounceTask: Task<Void, Never>?
    @State private var isUnsplitSelectionMode = false
    @State private var unsplitSelection = UnsplitAlbumSelection()
    @Namespace private var filterSelectionNamespace
    @FocusState private var isQueryFocused: Bool

    private enum FilterSlideDirection {
        case forward
        case backward
    }

    private var filteredLooseAudioPaths: [String] {
        appModel.filteredLooseAudioPathsInSelectedLibrary(filter: filter, query: debouncedQuery)
    }

    var body: some View {
        let coverWallSnapshot = appModel.coverWallSnapshotInSelectedLibrary(
            filter: filter,
            query: debouncedQuery
        )
        let visibleLooseAudioPaths = filteredLooseAudioPaths

        VStack(alignment: .leading, spacing: 0) {
            libraryOverviewHeader(
                visibleAlbumCount: coverWallSnapshot.cards.count,
                visibleLooseAudioCount: visibleLooseAudioPaths.count
            )

            filteredContent(
                coverWallSnapshot: coverWallSnapshot,
                visibleLooseAudioPaths: visibleLooseAudioPaths
            )
            .id(filter)
            .transition(filterContentTransition)
        }
        .clipped()
        .background(LibraryHomeDesignToken.bgSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            bottomFilterBar
        }
        .overlay {
            albumDetailOverlay
        }
        .onChange(of: isShowingAlbumDetail) { _, isShowing in
            if !isShowing {
                clearSelectedAlbumDetail()
            }
        }
        .onChange(of: query) { _, newValue in
            scheduleQueryDebounce(newValue)
        }
        .onDisappear {
            queryDebounceTask?.cancel()
        }
    }

    @ViewBuilder
    private func filteredContent(
        coverWallSnapshot: AlbumCoverWallSnapshot,
        visibleLooseAudioPaths: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !coverWallSnapshot.cards.isEmpty {
                albumGrid(snapshot: coverWallSnapshot)
            } else if filter != .looseAudio {
                emptyState(emptyAlbumStateTitle, systemImage: "square.grid.2x2")
            }

            if !visibleLooseAudioPaths.isEmpty {
                if !coverWallSnapshot.cards.isEmpty {
                    LibraryDividerLine()
                }
                looseAudioList(paths: visibleLooseAudioPaths)
            } else if filter == .looseAudio {
                emptyState("没有符合筛选条件的散落音频。", systemImage: "music.note.list")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
                .transition(.opacity)
                .animation(detailTransitionAnimation, value: isShowingAlbumDetail)
        }
    }

    private var selectedLibrary: LibraryRecord? {
        appModel.selectedLibrary
    }

    private var selectedLibraryProgress: AlbumNameEnhancementProgress? {
        guard let library = selectedLibrary else { return nil }
        return appModel.albumNameEnhancementProgress(for: library.id)
    }

    private var currentActionDescription: String {
        guard let library = selectedLibrary else { return "等待选择音乐库" }

        if let progress = selectedLibraryProgress,
           progress.totalAlbums > 0 {
            if progress.isFinished,
               let failureSummary = appModel.albumNameEnhancementFailureSummary(for: library.id) {
                return failureSummary
            }
            return progress.actionDescription
        }

        if let refreshMessage = appModel.realtimeRefreshMessage(for: library.id) {
            return refreshMessage
        }

        if appModel.albumNameEnhancementStatus(for: library.id)?.isRunning == true {
            return "正在智能解析专辑名"
        }

        return "空闲"
    }

    private var currentActionColor: Color {
        guard let library = selectedLibrary else { return LibraryHomeDesignToken.textTertiary }

        if let progress = selectedLibraryProgress,
           progress.totalAlbums > 0 {
            if progress.isFinished,
               appModel.albumNameEnhancementFailedAlbumCount(for: library.id) > 0 {
                return LibraryHomeDesignToken.warning
            }
            return progress.isFinished ? LibraryHomeDesignToken.success : LibraryHomeDesignToken.accent
        }

        if appModel.albumNameEnhancementStatus(for: library.id)?.isRunning == true {
            return LibraryHomeDesignToken.accent
        }

        if appModel.albumNameEnhancementFailedAlbumCount(for: library.id) > 0 {
            return LibraryHomeDesignToken.warning
        }

        return LibraryHomeDesignToken.textTertiary
    }

    private var currentPageCountTitle: String {
        filter == .all ? "专辑数量" : filter.displayName
    }

    private func currentPageCount(
        visibleAlbumCount: Int,
        visibleLooseAudioCount: Int
    ) -> Int {
        filter == .looseAudio ? visibleLooseAudioCount : visibleAlbumCount
    }

    private func libraryOverviewHeader(
        visibleAlbumCount: Int,
        visibleLooseAudioCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedLibrary?.displayName ?? "未选择音乐库")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(selectedLibrary?.rootPath ?? "没有可显示的音乐库地址")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(selectedLibrary?.rootPath ?? "")

                    Text(currentActionDescription)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(currentActionColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(currentActionDescription)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let progress = selectedLibraryProgress,
                   progress.totalAlbums > 0 {
                    VStack(alignment: .trailing, spacing: 5) {
                        ScanProgressBar(fraction: progress.fraction)
                            .frame(width: 240, height: 5)

                        Text("\(progress.completedAlbums)/\(progress.totalAlbums)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                            .monospacedDigit()
                    }
                    .frame(width: 240, alignment: .trailing)
                }
            }

            SummaryStatText(
                title: currentPageCountTitle,
                value: currentPageCount(
                    visibleAlbumCount: visibleAlbumCount,
                    visibleLooseAudioCount: visibleLooseAudioCount
                ),
                valueColor: LibraryHomeDesignToken.textPrimary
            )
            .frame(maxWidth: 220, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(LibraryHomeDesignToken.bgSecondary)
        .overlay(alignment: .bottom) {
            LibraryDividerLine()
        }
    }

    private var bottomFilterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(AlbumScanResultFilter.allCases) { option in
                    filterTab(option)
                }
            }
            .padding(3)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                    }
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    }
            }
            .frame(height: 42, alignment: .leading)

            searchControl
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .background {
            LiquidGlassFilterBarBackground()
        }
        .shadow(color: Color.black.opacity(0.17), radius: 16, x: 0, y: 7)
        .shadow(color: LibraryHomeDesignToken.shadowElevated.opacity(0.28), radius: 14, x: 0, y: 6)
        .shadow(color: Color.black.opacity(0.16), radius: 3, x: 0, y: 1)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .animation(filterBarAnimation, value: filter)
        .animation(filterBarAnimation, value: isSearchExpanded)
    }

    private var filterBarAccent: Color {
        LibraryHomeDesignToken.accent
    }

    private var filterBarAnimation: Animation {
        .snappy(duration: 0.26, extraBounce: 0.03)
    }

    private var pageTransitionAnimation: Animation {
        .spring(response: 0.36, dampingFraction: 0.88, blendDuration: 0.04)
    }

    private var detailTransitionAnimation: Animation {
        .spring(response: 0.30, dampingFraction: 0.90, blendDuration: 0.04)
    }

    private var filterContentTransition: AnyTransition {
        let insertion: Edge = filterSlideDirection == .forward ? .trailing : .leading
        let removal: Edge = filterSlideDirection == .forward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertion).combined(with: .opacity),
            removal: .move(edge: removal).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var searchControl: some View {
        if isSearchExpanded {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(filterBarAccent)

                TextField("按歌手、专辑、路径或标签名筛选", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                    .focused($isQueryFocused)
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(width: 320, height: 36)
            .background {
                searchControlBackground(isActive: true)
            }
            .transition(.scale(scale: 0.92, anchor: .trailing).combined(with: .opacity))
        } else {
            Button {
                expandSearch()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(query.isEmpty ? Color.white.opacity(0.88) : Color.white)
                    .frame(width: 36, height: 36)
                    .background {
                        searchControlBackground(isActive: !query.isEmpty)
                    }
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help(query.isEmpty ? "筛选搜索" : "正在使用搜索筛选，点击展开")
            .transition(.scale(scale: 0.88, anchor: .trailing).combined(with: .opacity))
        }
    }

    private func searchControlBackground(isActive: Bool) -> some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                (isActive ? filterBarAccent : Color.white).opacity(isActive ? 0.34 : 0.08),
                                Color.white.opacity(isActive ? 0.08 : 0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                Capsule()
                    .stroke(
                        isActive ? Color.white.opacity(0.34) : Color.white.opacity(0.14),
                        lineWidth: 1
                    )
            }
            .shadow(color: isActive ? Color.black.opacity(0.22) : Color.black.opacity(0.14), radius: 7, x: 0, y: 2)
    }

    private func filterTab(_ option: AlbumScanResultFilter) -> some View {
        let isSelected = filter == option
        let isHovered = hoveredFilter == option
        return Button {
            selectFilter(option)
        } label: {
            Text(option.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.66))
                .frame(width: 74, height: 36)
                .background {
                    ZStack {
                        if isHovered {
                            hoveredFilterTabShadow
                        }

                        if isHovered && !isSelected {
                            hoveredFilterTabBackground
                        }

                        if isSelected {
                            selectedFilterTabBackground
                                .matchedGeometryEffect(id: "selectedFilterTab", in: filterSelectionNamespace)
                        }
                    }
                }
                .offset(y: isHovered ? -1 : 0)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .onHover { isHovering in
            withAnimation(filterBarAnimation) {
                hoveredFilter = isHovering ? option : nil
            }
        }
    }

    private var selectedFilterTabBackground: some View {
        ZStack {
            Capsule()
                .fill(filterBarAccent.opacity(0.94))

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.34),
                            filterBarAccent.opacity(0.26),
                            Color.black.opacity(0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Capsule()
                .inset(by: 1)
                .stroke(Color.white.opacity(0.38), lineWidth: 1)

            Capsule()
                .inset(by: 4)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        }
        .shadow(color: Color.black.opacity(0.24), radius: 4, x: 0, y: 1)
        .shadow(color: Color.black.opacity(0.14), radius: 2, x: 0, y: 1)
    }

    private var hoveredFilterTabBackground: some View {
        Capsule()
            .fill(Color.white.opacity(0.08))
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            }
    }

    private var hoveredFilterTabShadow: some View {
        Capsule()
            .fill(Color.white.opacity(0.01))
            .shadow(color: Color.black.opacity(0.30), radius: 6, x: 0, y: 2)
            .shadow(color: Color.black.opacity(0.16), radius: 2, x: 0, y: 1)
    }

    private func selectFilter(_ option: AlbumScanResultFilter) {
        let nextDirection = filterDirection(from: filter, to: option)
        withAnimation(pageTransitionAnimation) {
            filterSlideDirection = nextDirection
            filter = option
            isSearchExpanded = false
            if option != .singleFileUnsplit {
                isUnsplitSelectionMode = false
                unsplitSelection.clear()
            }
        }
        isQueryFocused = false
    }

    private func filterDirection(
        from current: AlbumScanResultFilter,
        to next: AlbumScanResultFilter
    ) -> FilterSlideDirection {
        let filters = AlbumScanResultFilter.allCases
        let currentIndex = filters.firstIndex(of: current) ?? 0
        let nextIndex = filters.firstIndex(of: next) ?? currentIndex
        return nextIndex >= currentIndex ? .forward : .backward
    }

    private func expandSearch() {
        withAnimation(filterBarAnimation) {
            isSearchExpanded = true
        }
        DispatchQueue.main.async {
            isQueryFocused = true
        }
    }

    private func scheduleQueryDebounce(_ value: String) {
        queryDebounceTask?.cancel()
        queryDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            debouncedQuery = value
        }
    }

    private func albumGrid(snapshot: AlbumCoverWallSnapshot) -> some View {
        let renderKey = AlbumCoverWallRenderKey(
            snapshotRevision: snapshot.revision,
            filter: filter,
            normalizedQuery: snapshot.normalizedQuery,
            selectedAlbumIDs: unsplitSelection.selectedAlbumIDs,
            coverWriteMessages: appModel.coverWriteMessagesByAlbumID,
            splittingAlbumIDs: appModel.splittingCueSheetAlbumIDs,
            isSelectionMode: isUnsplitSelectionMode
        )
        return EquatableAlbumCoverGrid(
            snapshot: snapshot,
            renderKey: renderKey,
            appModel: appModel,
            onOpen: { albumID in
                if isUnsplitSelectionMode, filter == .singleFileUnsplit {
                    unsplitSelection.toggle(albumID)
                } else {
                    openAlbumDetail(albumID: albumID, pendingCoverURL: nil)
                }
            },
            onAcceptedCoverDrop: { albumID in
                openAlbumDetail(albumID: albumID, pendingCoverURL: nil)
            },
            onToggleSelection: { albumID in
                isUnsplitSelectionMode = true
                unsplitSelection.toggle(albumID)
            },
            onSelectAllUnsplit: {
                isUnsplitSelectionMode = true
                unsplitSelection.clear()
                for card in snapshot.cards where card.canSplitWithXLD {
                    unsplitSelection.select(card.id)
                }
            },
            onSplitWithXLD: { albumID in
                let selectedIDs = unsplitSelection.selectedAlbumIDs
                splitUnsplitAlbumsWithXLD(
                    selectedIDs.contains(albumID) && !selectedIDs.isEmpty ? selectedIDs : Set([albumID])
                )
            }
        )
        .equatable()
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
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 112)
    }

    private var emptyAlbumStateTitle: String {
        switch filter {
        case .singleFileUnsplit:
            "没有未分轨专辑。"
        case .metadataReadFailed:
            "没有标签异常专辑。"
        case .trackNamedAudioFiles:
            "没有 track 音轨专辑。"
        case .nameEnhancementFailed:
            "没有解析失败的专辑。"
        default:
            "没有符合筛选条件的专辑。"
        }
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
        let performanceSpan = CoverDropPerformanceLog.begin(
            CoverDropPerformanceOperation.openAlbumDetail,
            context: ["albumID": albumID]
        )
        selectedAlbumID = albumID
        appModel.stageCoverImageIfProvided(pendingCoverURL, forAlbumID: albumID)
        withAnimation(detailTransitionAnimation) {
            isShowingAlbumDetail = true
        }
        performanceSpan?.finish()
    }

    private func closeAlbumDetail() {
        let performanceSpan = CoverDropPerformanceLog.begin(
            CoverDropPerformanceOperation.returnToCoverWall,
            context: ["albumID": selectedAlbumID ?? "unknown"]
        )
        withAnimation(detailTransitionAnimation) {
            isShowingAlbumDetail = false
        }
        clearSelectedAlbumDetail()
        performanceSpan?.finish()
    }

    private func clearSelectedAlbumDetail() {
        if let selectedAlbumID {
            appModel.cancelPendingCoverImage(forAlbumID: selectedAlbumID)
        }
        selectedAlbumID = nil
    }

    private func splitUnsplitAlbumsWithXLD(_ albumIDs: Set<AlbumScanRecord.ID>) {
        let targets = albumIDs.compactMap { albumID -> (AlbumScanRecord.ID, CueSheetRecord.ID)? in
            guard let album = appModel.albumInSelectedLibrary(id: albumID),
                  UnsplitAlbumSelection.canSplitWithXLD(album),
                  let cueSheet = album.cueSheets.first else {
                return nil
            }
            return (album.id, cueSheet.id)
        }

        Task {
            for target in targets {
                await appModel.splitCueSheetWithXLD(albumID: target.0, cueSheetID: target.1)
            }
        }
    }
}

private struct EquatableAlbumCoverGrid: View, Equatable {
    let snapshot: AlbumCoverWallSnapshot
    let renderKey: AlbumCoverWallRenderKey
    let appModel: AppModel
    let onOpen: (AlbumScanRecord.ID) -> Void
    let onAcceptedCoverDrop: (AlbumScanRecord.ID) -> Void
    let onToggleSelection: (AlbumScanRecord.ID) -> Void
    let onSelectAllUnsplit: () -> Void
    let onSplitWithXLD: (AlbumScanRecord.ID) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.renderKey == rhs.renderKey
    }

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(
                0,
                proxy.size.width - 2 * FixedCoverGridLayout.horizontalContentPadding
            )
            let metrics = FixedCoverGridLayout.metrics(forContentWidth: contentWidth)

            ScrollView {
                LazyVGrid(
                    columns: fixedColumns(for: metrics),
                    alignment: .leading,
                    spacing: FixedCoverGridLayout.rowSpacing
                ) {
                    ForEach(snapshot.cards) { presentation in
                        AlbumCoverCard(
                            presentation: presentation,
                            appModel: appModel,
                            coverWriteMessage: renderKey.coverWriteMessages[presentation.id],
                            isSelectionEnabled: renderKey.filter == .singleFileUnsplit,
                            isSelectionMode: renderKey.isSelectionMode,
                            isSelected: renderKey.selectedAlbumIDs.contains(presentation.id),
                            isSplittingCueSheet: renderKey.splittingAlbumIDs.contains(presentation.id),
                            onOpen: { onOpen(presentation.id) },
                            onAcceptedCoverDrop: { onAcceptedCoverDrop(presentation.id) },
                            onToggleSelection: { onToggleSelection(presentation.id) },
                            onSelectAllUnsplit: onSelectAllUnsplit,
                            onSplitWithXLD: { onSplitWithXLD(presentation.id) }
                        )
                    }
                }
                .padding(.horizontal, FixedCoverGridLayout.horizontalContentPadding)
                .padding(.top, FixedCoverGridLayout.rowSpacing)
                .padding(.bottom, 96)
            }
        }
        .frame(minHeight: 320, maxHeight: .infinity)
    }

    private func fixedColumns(
        for metrics: FixedCoverGridLayout.Metrics
    ) -> [GridItem] {
        Array(
            repeating: GridItem(
                .fixed(FixedCoverGridLayout.cardWidth),
                spacing: metrics.columnSpacing
            ),
            count: metrics.columnCount
        )
    }
}

private struct SummaryStatText: View {
    let title: String
    let value: Int
    let valueColor: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                .lineLimit(1)

            Text(value, format: .number)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LiquidGlassFilterBarBackground: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.20),
                            LibraryHomeDesignToken.accent.opacity(0.08),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            LibraryHomeDesignToken.accent.opacity(0.20),
                            Color.clear
                        ],
                        center: .topTrailing,
                        startRadius: 8,
                        endRadius: 180
                    )
                )

            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .inset(by: 4)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)

            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.26), lineWidth: 1)

            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(LibraryHomeDesignToken.accent.opacity(0.16), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

private struct AlbumCoverCard: View {
    let presentation: AlbumCoverCardPresentation
    let appModel: AppModel
    let coverWriteMessage: String?
    let isSelectionEnabled: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let isSplittingCueSheet: Bool
    let onOpen: () -> Void
    let onAcceptedCoverDrop: () -> Void
    let onToggleSelection: () -> Void
    let onSelectAllUnsplit: () -> Void
    let onSplitWithXLD: () -> Void

    @State private var isDropTargeted = false
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                coverArea

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(presentation.displayAlbumName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                            .lineLimit(2)
                            .help(presentation.displayAlbumName)

                        if presentation.hasEnhancedName {
                            Image(systemName: "sparkles")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                                .help("名称已由 Ollama 增强")
                        }

                        if let message = presentation.enhancementErrorMessage {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(LibraryHomeDesignToken.warning)
                                .help("Ollama 解析失败：\(message)")
                        }
                    }

                    Text(presentation.displayArtistName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(presentation.folderURL.path)
                        .font(.system(size: 10))
                        .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(presentation.folderURL.path)

                    HStack(spacing: 5) {
                        ForEach(presentation.formatTags, id: \.self) { tag in
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
        .frame(width: FixedCoverGridLayout.cardWidth)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusLg))
        .clipShape(RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusLg))
        .scaleEffect(isHovered ? 1.018 : 1)
        .shadow(
            color: isHovered ? Color.black.opacity(0.38) : LibraryHomeDesignToken.shadowCard,
            radius: isHovered ? 11 : 8,
            y: isHovered ? 4 : 2
        )
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
        .animation(.snappy(duration: 0.18, extraBounce: 0.02), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            if isSelectionEnabled {
                Button {
                    onToggleSelection()
                } label: {
                    Label(isSelected ? "取消选择" : "选择", systemImage: isSelected ? "minus.circle" : "checkmark.circle")
                }

                Button {
                    onSelectAllUnsplit()
                } label: {
                    Label("全选未分轨", systemImage: "checklist")
                }

                Button {
                    onSplitWithXLD()
                } label: {
                    Label("用 XLD 分轨", systemImage: "waveform")
                }
                .disabled(!presentation.canSplitWithXLD || isSplittingCueSheet)
            }
        }
        .onDrop(
            of: CoverDropReceiver.typeIdentifiers,
            isTargeted: $isDropTargeted
        ) { providers in
            CoverDropReceiver.receive(
                providers,
                albumID: presentation.id,
                appModel: appModel,
                onAccepted: onAcceptedCoverDrop
            )
        }
    }

    private var coverArea: some View {
        ZStack {
            CachedCoverFillView(
                url: presentation.coverURL,
                contentRevision: presentation.contentRevision,
                maxPixelSize: 336,
                placeholderSize: 32,
                placeholderText: "缺封面"
            )
            .frame(
                width: FixedCoverGridLayout.cardWidth,
                height: FixedCoverGridLayout.cardWidth
            )
        }
        .frame(
            width: FixedCoverGridLayout.cardWidth,
            height: FixedCoverGridLayout.cardWidth
        )
        .overlay(alignment: .topLeading) {
            statusBadge
                .padding(6)
        }
        .overlay(alignment: .topTrailing) {
            if isSelectionEnabled && (isSelectionMode || isSelected) {
                Button(action: onToggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? LibraryHomeDesignToken.accent : Color.white.opacity(0.82))
                        .frame(width: 26, height: 26)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .help(isSelected ? "取消选择" : "选择")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if presentation.needsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                    .frame(width: 20, height: 20)
                    .background(LibraryHomeDesignToken.warning, in: Circle())
                    .shadow(color: LibraryHomeDesignToken.shadowCard, radius: 4, y: 2)
                    .padding(8)
                    .help(presentation.issueHelp ?? "")
            }
        }
    }

    private var statusBadge: some View {
        if presentation.needsAttention {
            LibraryStatusPill(
                title: "需确认",
                systemImage: "exclamationmark.triangle.fill",
                foreground: LibraryHomeDesignToken.warning,
                background: LibraryHomeDesignToken.warningBg,
                border: LibraryHomeDesignToken.warning.opacity(0.35)
            )
        } else if let source = presentation.coverSourceName {
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
}

private struct AlbumDetailSheet: View {
    let albumID: AlbumScanRecord.ID
    @ObservedObject var appModel: AppModel
    let onClose: () -> Void
    @State private var isDropTargeted = false
    @State private var workflowPresentation = AlbumCoverWorkflowPresentationState()
    @State private var selectedSearchSourceID = ""
    @State private var isAlbumRemoved = false

    private var album: AlbumScanRecord? {
        appModel.albumInSelectedLibrary(id: albumID)
    }

    private var coverSearchConfiguration: AppConfiguration.CoverSearch {
        appModel.environment.configuration.coverSearch
    }

    var body: some View {
        ZStack {
            workflowContent
        }
        .frame(
            width: workflowPresentation.containerSize.width,
            height: workflowPresentation.containerSize.height
        )
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
                    isDropTargeted && workflowPresentation.usesAlbumDetailDropZone
                        ? AnyShapeStyle(LibraryHomeDesignToken.accent)
                        : AnyShapeStyle(.clear),
                    style: StrokeStyle(lineWidth: 3, dash: [8])
                )
                .padding(8)
                .allowsHitTesting(false)
        }
        .onAppear {
            DispatchQueue.main.async {
                if selectedSearchSourceID.isEmpty {
                    selectedSearchSourceID = coverSearchConfiguration.defaultSource.id
                }
                Task {
                    await checkAlbumRemoval()
                }
            }
        }
        .task(id: albumID) {
            while !Task.isCancelled && !isAlbumRemoved {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await checkAlbumRemoval()
            }
        }
        .onChange(of: album == nil) { _, isMissing in
            if isMissing {
                isAlbumRemoved = true
                workflowPresentation.handleAlbumRemoval()
            }
        }
    }

    @ViewBuilder
    private var workflowContent: some View {
        switch workflowPresentation.destination {
        case .albumDetail:
            if isAlbumRemoved || album == nil {
                removedAlbumState
            } else if let album {
                albumDetail(album)
                    .onDrop(
                        of: CoverDropReceiver.typeIdentifiers,
                        isTargeted: $isDropTargeted
                    ) { providers in
                        guard workflowPresentation.usesAlbumDetailDropZone else {
                            return false
                        }
                        return CoverDropReceiver.receive(
                            providers,
                            albumID: albumID,
                            appModel: appModel
                        )
                    }
            }
        case .coverSearch:
            if !isAlbumRemoved, let album {
                CoverSearchSheet(
                    album: album,
                    appModel: appModel,
                    searchConfiguration: coverSearchConfiguration,
                    selectedSourceID: $selectedSearchSourceID,
                    onClose: {
                        workflowPresentation.showAlbumDetail()
                    }
                )
            } else {
                removedAlbumState
            }
        }
    }

    private var removedAlbumState: some View {
        ZStack {
            Text("该专辑已移除")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(LibraryHomeDesignToken.textPrimary)

            VStack {
                Spacer()

                HStack {
                    Spacer()

                    Button {
                        onClose()
                    } label: {
                        Label("返回封面墙", systemImage: "arrow.left")
                    }
                    .buttonStyle(.coverDropSecondary(height: 34))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(LibraryHomeDesignToken.bgSecondary)
            }
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
                                        if !album.cueSheets.isEmpty {
                                            LibraryStatusPill(
                                                title: "\(album.cueSheets.count) 个 CUE",
                                                systemImage: "doc.text",
                                                foreground: LibraryHomeDesignToken.warning,
                                                background: LibraryHomeDesignToken.warningBg
                                            )
                                        }
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
                                    let performanceSpan = CoverDropPerformanceLog.begin(
                                        CoverDropPerformanceOperation.openAggregateSearch,
                                        context: [
                                            "albumID": album.id,
                                            "source": selectedSearchSourceID
                                        ]
                                    )
                                    workflowPresentation.showCoverSearch()
                                    performanceSpan?.finish()
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

                            if let message = appModel.albumNameEnhancementState(forAlbumID: album.id)?.lastErrorMessage {
                                Label("Ollama 解析失败，已回退原始名称：\(message)", systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(LibraryHomeDesignToken.warning)
                                    .lineLimit(2)
                                    .help(message)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                infoField(
                                    title: "搜索词",
                                    value: appModel.searchKeyword(for: album),
                                    monospaced: false,
                                    ollamaAction: { requestAlbumNameEnhancement(for: album) },
                                    ollamaState: appModel.albumNameEnhancementState(forAlbumID: album.id),
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

                    cueSheetList(for: album)
                    trackList(for: album)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                if let message = appModel.albumFolderOpenMessage(forAlbumID: album.id) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(LibraryHomeDesignToken.warning)
                        .lineLimit(2)
                }
                if let message = appModel.cueSheetSplitMessage(forAlbumID: album.id) {
                    Label(
                        message,
                        systemImage: message.hasPrefix("已在 XLD 中打开") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(message.hasPrefix("已在 XLD 中打开") ? LibraryHomeDesignToken.success : LibraryHomeDesignToken.warning)
                    .lineLimit(2)
                }

                HStack(spacing: 12) {
                    Button {
                        FinderAlbumFolderOpenDiagnostics.log(
                            "ui.buttonTapped albumID=\(album.id) folder=\(album.folderURL.path)"
                        )
                        Task {
                            await appModel.openAlbumFolderInFinder(albumID: album.id)
                        }
                    } label: {
                        if appModel.isOpeningAlbumFolder(album.id) {
                            Label("打开中...", systemImage: "hourglass")
                        } else {
                            Label("在 Finder 中显示", systemImage: "folder")
                        }
                    }
                    .buttonStyle(.coverDropSubtle)
                    .disabled(appModel.isOpeningAlbumFolder(album.id))

                    Spacer()

                    Button {
                        onClose()
                    } label: {
                        Label("返回封面墙", systemImage: "arrow.left")
                    }
                    .buttonStyle(.coverDropSecondary(height: 34))

                    Button {
                        savePendingCover()
                    } label: {
                        if appModel.isSavingCoverImage(for: album.id) {
                            Label("保存中...", systemImage: "hourglass")
                        } else {
                            Text("保存封面")
                        }
                    }
                    .buttonStyle(.coverDropPrimary(height: 34))
                    .disabled(
                        appModel.pendingCoverURL(for: album.id) == nil
                        || appModel.isSavingCoverImage(for: album.id)
                    )
                    .keyboardShortcut(.defaultAction)
                }
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

    @ViewBuilder
    private func cueSheetList(for album: AlbumScanRecord) -> some View {
        if !album.cueSheets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("CUE 文件")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .padding(.leading, 42)

                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(album.cueSheets) { cueSheet in
                        cueSheetRow(cueSheet, album: album)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .overlay(alignment: .top) {
                LibraryDividerLine()
            }
        }
    }

    private func cueSheetRow(_ cueSheet: CueSheetRecord, album: AlbumScanRecord) -> some View {
        let canSplit = isSingleImageCueSplitCandidate(album)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(canSplit ? LibraryHomeDesignToken.warning : LibraryHomeDesignToken.textTertiary)
                .frame(width: 32, height: 32)
                .background(LibraryHomeDesignToken.bgElevated, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusSm))

            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: cueSheet.relativePath).lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(canSplit ? "单整轨分轨文件" : "关联 CUE 文件")
                    .font(.system(size: 11))
                    .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                    .lineLimit(1)
                    .help(cueSheet.relativePath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if appModel.isSplittingCueSheet(album.id) {
                Label("打开中...", systemImage: "hourglass")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LibraryHomeDesignToken.warning)
            } else if canSplit {
                Text("XLD")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LibraryHomeDesignToken.warning)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(LibraryHomeDesignToken.bgTertiary, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusSm))
        .padding(.bottom, 6)
        .contextMenu {
            Button {
                splitCueSheet(cueSheet, for: album)
            } label: {
                Label("用 XLD 分轨", systemImage: "waveform")
            }
            .disabled(!canSplit || appModel.isSplittingCueSheet(album.id))
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
        guard !appModel.isSavingCoverImage(for: albumID) else { return }
        CoverDropDebugLog.write("保存封面：用户点击保存按钮，albumID=\(albumID)")
        Task {
            let didSave = await appModel.savePendingCoverImage(forAlbumID: albumID)
            if didSave {
                onClose()
            }
        }
    }

    private func checkAlbumRemoval() async {
        guard !isAlbumRemoved else { return }
        if await appModel.removeAlbumIfFolderMissing(albumID: albumID) || album == nil {
            isAlbumRemoved = true
            workflowPresentation.handleAlbumRemoval()
        }
    }

    private func infoField(
        title: String,
        value: String,
        monospaced: Bool = false,
        ollamaAction: (() -> Void)? = nil,
        ollamaState: AlbumNameEnhancementAlbumState? = nil,
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

            if let ollamaAction {
                Button(action: ollamaAction) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ollamaState?.isRunning == true ? LibraryHomeDesignToken.accent : LibraryHomeDesignToken.textTertiary)
                .disabled(ollamaState?.isQueued == true || ollamaState?.isRunning == true)
                .help(ollamaHelpText(for: ollamaState))
            }

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

    private func requestAlbumNameEnhancement(for album: AlbumScanRecord) {
        appModel.requestAlbumNameEnhancement(forAlbumID: album.id)
    }

    private func ollamaHelpText(for state: AlbumNameEnhancementAlbumState?) -> String {
        if state?.isRunning == true {
            return "Ollama 正在识别这张专辑"
        }
        if state?.isQueued == true {
            return "已加入 Ollama 识别队列"
        }
        if let message = state?.lastErrorMessage {
            return "上次识别失败：\(message)。点击重试"
        }
        return "用 Ollama 识别专辑名"
    }

    private func searchKeyword(for album: AlbumScanRecord) -> String {
        appModel.searchKeyword(for: album)
    }

    private func copySearchKeyword(for album: AlbumScanRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(searchKeyword(for: album), forType: .string)
    }

    private func splitCueSheet(_ cueSheet: CueSheetRecord, for album: AlbumScanRecord) {
        Task {
            await appModel.splitCueSheetWithXLD(albumID: album.id, cueSheetID: cueSheet.id)
        }
    }

    private func isSingleImageCueSplitCandidate(_ album: AlbumScanRecord) -> Bool {
        album.audioFiles.count == 1
            && album.issues.contains { issue in
                if case .singleFileNeedsConfirmation(let hasCue) = issue { return hasCue }
                return false
            }
    }
}

private struct CoverSearchSheet: View {
    let album: AlbumScanRecord
    @ObservedObject var appModel: AppModel
    let searchConfiguration: AppConfiguration.CoverSearch
    @Binding var selectedSourceID: AppConfiguration.CoverSearchSource.ID
    let onClose: () -> Void
    @State private var isDropTargeted = false
    @State private var webLoadErrorMessage: String?
    @State private var capturedWebImageURL: URL?
    @State private var capturedWebImageAt = Date.distantPast
    @State private var reloadID = UUID()
    @State private var aggregateResults: [CoverSearchResult] = []
    @State private var aggregateSearchErrorMessage: String?
    @State private var isLoadingAggregateSearch = false
    @State private var aggregateReloadID = UUID()
    @State private var selectedAggregateCountryCode = "CN"

    private var keyword: String {
        appModel.searchKeyword(for: album)
    }

    private var selectedSource: AppConfiguration.CoverSearchSource {
        searchConfiguration.source(id: selectedSourceID)
    }

    private var searchURL: URL? {
        selectedSource.url(for: keyword)
    }

    private var aggregateSearchTaskKey: String {
        [
            selectedSourceID,
            keyword,
            selectedAggregateCountryCode,
            aggregateReloadID.uuidString
        ].joined(separator: "|")
    }

    var body: some View {
        HStack(spacing: 0) {
            searchArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            sidePanel
                .frame(width: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .task(id: aggregateSearchTaskKey) {
            await loadAggregateSearchResultsIfNeeded()
        }
    }

    @ViewBuilder
    private var searchArea: some View {
        if selectedSource.kind == .aggregate {
            aggregateSearchArea
        } else {
            webSearchArea
        }
    }

    private var webSearchArea: some View {
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

    private var aggregateSearchArea: some View {
        VStack(spacing: 0) {
            aggregateSearchToolbar

            ZStack {
                aggregateSearchContent

                if isLoadingAggregateSearch && !aggregateResults.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusMd))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LibraryHomeDesignToken.bgPrimary)
        }
    }

    private var aggregateSearchToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LibraryHomeDesignToken.accent)
                Text("聚合搜索")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LibraryHomeDesignToken.textPrimary)
            }

            Text(keyword)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(LibraryHomeDesignToken.bgPrimary, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusSm))
                .help(keyword)

            HStack(spacing: 6) {
                Image(systemName: "globe.asia.australia")
                    .font(.system(size: 12, weight: .semibold))
                Text("中国大陆 CN")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(LibraryHomeDesignToken.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(LibraryHomeDesignToken.bgPrimary, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusSm))
            .help("第一版仅启用中国大陆地区，后续可扩展更多地区。")

            Button {
                aggregateReloadID = UUID()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LibraryHomeDesignToken.textSecondary)
            .disabled(isLoadingAggregateSearch)
            .help("刷新聚合搜索结果")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(LibraryHomeDesignToken.bgTertiary)
        .overlay(alignment: .bottom) {
            LibraryDividerLine()
        }
    }

    @ViewBuilder
    private var aggregateSearchContent: some View {
        if isLoadingAggregateSearch && aggregateResults.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在搜索封面...")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(LibraryHomeDesignToken.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let aggregateSearchErrorMessage {
            aggregateSearchError(aggregateSearchErrorMessage)
        } else if aggregateResults.isEmpty {
            ContentUnavailableView {
                Label("没有找到封面", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("可以换一个搜索词，或切换到右侧的网页搜索源。")
            } actions: {
                Button {
                    aggregateReloadID = UUID()
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
            }
            .foregroundStyle(LibraryHomeDesignToken.textSecondary)
        } else {
            aggregateResultsGrid
        }
    }

    private var aggregateResultsGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 16)
                ],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(aggregateResults) { result in
                    AggregateCoverResultCard(
                        result: result,
                        onDragStarted: { imageURL in
                            cacheCapturedWebImage(imageURL)
                            appModel.prefetchRemoteCoverImage(at: imageURL)
                        }
                    )
                }
            }
            .padding(20)
        }
    }

    private func aggregateSearchError(_ message: String) -> some View {
        ContentUnavailableView {
            Label("聚合搜索失败", systemImage: "network.slash")
        } description: {
            Text(message)
        } actions: {
            Button {
                aggregateReloadID = UUID()
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
        }
        .padding()
        .foregroundStyle(LibraryHomeDesignToken.textSecondary)
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
                    onClose()
                }
                .buttonStyle(.coverDropSubtle)

                Spacer()

                Button {
                    onClose()
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
                if let fallbackRemoteURL {
                    CoverDropDebugLog.write(
                        "封面拖拽：右侧拖入区域取得备用图片 URL：\(fallbackRemoteURL.absoluteString)"
                    )
                } else {
                    CoverDropDebugLog.write("封面拖拽：右侧拖入区域没有备用图片 URL")
                }
                let didAccept = CoverDropReceiver.receive(
                    providers,
                    albumID: album.id,
                    appModel: appModel,
                    fallbackRemoteURL: fallbackRemoteURL,
                    onAccepted: onClose
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(searchConfiguration.enabledSources) { source in
                        Button {
                            selectedSourceID = source.id
                        } label: {
                            Text(source.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(source.id == selectedSourceID ? LibraryHomeDesignToken.accent : LibraryHomeDesignToken.textSecondary)
                                .lineLimit(1)
                                .frame(minWidth: 58)
                                .padding(.horizontal, 9)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        onClose()
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

    @MainActor
    private func loadAggregateSearchResultsIfNeeded() async {
        guard selectedSource.kind == .aggregate else { return }

        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let performanceSpan = CoverDropPerformanceLog.begin(
            CoverDropPerformanceOperation.aggregateSearchRequest,
            context: [
                "albumID": album.id,
                "country": selectedAggregateCountryCode,
                "keywordLength": "\(trimmedKeyword.count)"
            ]
        )
        guard !trimmedKeyword.isEmpty else {
            aggregateResults = []
            aggregateSearchErrorMessage = "搜索词为空，无法执行聚合搜索。"
            isLoadingAggregateSearch = false
            performanceSpan?.finish(outcome: .failure, context: ["error": "empty_keyword"])
            return
        }

        isLoadingAggregateSearch = true
        aggregateSearchErrorMessage = nil

        do {
            let parameters = CoverSearchParameters(countryCode: selectedAggregateCountryCode)
            let results = try await appModel.environment.coverSearchClient.searchCovers(
                keyword: trimmedKeyword,
                parameters: parameters
            )

            guard !Task.isCancelled else {
                performanceSpan?.finish(outcome: .cancelled)
                return
            }
            aggregateResults = results
            aggregateSearchErrorMessage = nil
            isLoadingAggregateSearch = false
            performanceSpan?.finish(context: ["resultCount": "\(results.count)"])
        } catch {
            guard !Task.isCancelled else {
                performanceSpan?.finish(outcome: .cancelled)
                return
            }
            aggregateResults = []
            aggregateSearchErrorMessage = displayMessage(for: error)
            isLoadingAggregateSearch = false
            performanceSpan?.finish(
                outcome: .failure,
                context: ["error": error.localizedDescription]
            )
        }
    }

    private func displayMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let errorDescription = localizedError.errorDescription,
           !errorDescription.isEmpty {
            return errorDescription
        }

        let message = error.localizedDescription
        return message.isEmpty ? "聚合搜索失败，请稍后重试。" : message
    }

    private func clearCapturedWebImage() {
        capturedWebImageURL = nil
        capturedWebImageAt = .distantPast
    }
}

private struct AggregateCoverResultCard: View {
    let result: CoverSearchResult
    let onDragStarted: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            aggregateCoverImage
                .overlay(alignment: .topLeading) {
                    sourceBadge
                        .padding(8)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(result.albumName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(result.albumName)

                Text(result.artistName)
                    .font(.system(size: 12))
                    .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(result.artistName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(LibraryHomeDesignToken.bgSecondary, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusMd))
        .overlay {
            RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusMd)
                .stroke(LibraryHomeDesignToken.border)
        }
        .contentShape(RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusMd))
        .onDrag {
            onDragStarted(result.imageURL)
            CoverDropDebugLog.write(
                "封面拖拽：聚合搜索拖拽开始，已缓存备用图片 URL：\(result.imageURL.absoluteString)"
            )
            let provider = CoverSearchResultDragItemProvider.provider(for: result)
            return provider
        }
        .help("拖到右侧封面方块暂存封面")
    }

    private var aggregateCoverImage: some View {
        Color.clear
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            RemoteCoverPreviewImage(url: RemoteCoverPreviewLoader.previewURL(for: result))
        }
        .clipShape(RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusSm))
        .overlay {
            RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusSm)
                .stroke(LibraryHomeDesignToken.borderStrong)
        }
    }

    private var sourceBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "music.note")
                .font(.system(size: 9, weight: .semibold))
            Text(result.sourceName)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(LibraryHomeDesignToken.textPrimary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct RemoteCoverPreviewImage: View {
    let url: URL

    @State private var image: NSImage?
    @State private var didFail = false

    private var requestKey: String {
        url.absoluteString
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(LibraryHomeDesignToken.bgTertiary)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if didFail {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 28, weight: .regular))
                    Text("封面加载失败")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipped()
        .task(id: requestKey) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        image = nil
        didFail = false

        let loadedImage = await RemoteCoverPreviewLoader.loadImage(from: url)
        guard !Task.isCancelled else { return }

        if let loadedImage {
            image = loadedImage
        } else {
            didFail = true
        }
    }
}

enum CoverDropReceiver {
    private final class AcceptanceHandlerBox: @unchecked Sendable {
        private let action: (() -> Void)?

        @MainActor
        init(action: (() -> Void)?) {
            self.action = action
        }

        @MainActor
        func callIfPresent() {
            action?()
        }
    }

    private struct SendableItemProvider: @unchecked Sendable {
        nonisolated(unsafe) let value: NSItemProvider
    }

    private struct URLItemRepresentation: @unchecked Sendable {
        let provider: SendableItemProvider
        let typeIdentifier: String
    }

    private struct ImageDataRepresentation: @unchecked Sendable {
        let provider: SendableItemProvider
        let typeIdentifier: String
        let fallbackRemoteURL: URL?
    }

    nonisolated static let imageTypeIdentifiers = [
        UTType.jpeg.identifier,
        UTType.png.identifier,
        UTType.tiff.identifier,
        "org.webmproject.webp",
        UTType.image.identifier
    ]

    nonisolated static let urlTypeIdentifiers = [
        UTType.url.identifier
    ] + textURLTypeIdentifiers + [
        UTType.fileURL.identifier
    ]

    nonisolated static let textURLTypeIdentifiers = [
        "public.utf8-plain-text",
        "public.plain-text",
        "public.text"
    ]

    nonisolated static let typeIdentifiers = imageTypeIdentifiers + urlTypeIdentifiers

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
        let acceptanceHandler = AcceptanceHandlerBox(action: onAccepted)
        CoverDropDebugLog.write(
            "封面拖拽：可用 URL representation：\(urlRepresentations.map(\.typeIdentifier).joined(separator: ", "))"
        )

        let imageFallback = imageTypeIdentifiers.first(where: {
            provider.hasItemConformingToTypeIdentifier($0)
        }).map {
            ImageDataRepresentation(
                provider: SendableItemProvider(value: provider),
                typeIdentifier: $0,
                fallbackRemoteURL: fallbackRemoteURL
            )
        }

        if loadFirstURLIfAvailable(
            from: urlRepresentations[...],
            imageFallback: imageFallback,
            fallbackRemoteURL: fallbackRemoteURL,
            albumID: albumID,
            appModel: appModel,
            acceptanceHandler: acceptanceHandler
        ) {
            return true
        }

        if let imageFallback {
            CoverDropDebugLog.write("封面拖拽：无可用 URL，改读图片 representation：\(imageFallback.typeIdentifier)")
            loadImageData(
                from: imageFallback.provider.value,
                typeIdentifier: imageFallback.typeIdentifier,
                urlRepresentations: [],
                fallbackRemoteURL: imageFallback.fallbackRemoteURL,
                albumID: albumID,
                appModel: appModel,
                acceptanceHandler: acceptanceHandler
            )
            return true
        }

        if loadFallbackRemoteURLIfAvailable(
            fallbackRemoteURL,
            albumID: albumID,
            appModel: appModel,
            acceptanceHandler: acceptanceHandler,
            context: "没有图片或 URL representation"
        ) {
            return true
        }

        CoverDropDebugLog.write("封面拖拽：没有找到可读取的图片或 URL representation")
        appModel.errorMessage = "请拖入图片文件，或网页里的图片。"
        return false
    }

    nonisolated private static func loadURL(
        from representation: URLItemRepresentation,
        remainingRepresentations: ArraySlice<URLItemRepresentation> = [],
        imageFallback: ImageDataRepresentation? = nil,
        fallbackRemoteURL: URL? = nil,
        albumID: AlbumScanRecord.ID,
        appModel: AppModel,
        acceptanceHandler: AcceptanceHandlerBox
    ) {
        let performanceSpan = CoverDropPerformanceLog.begin(
            CoverDropPerformanceOperation.readDroppedImage,
            context: [
                "albumID": albumID,
                "representation": representation.typeIdentifier
            ]
        )
        CoverDropDebugLog.write("封面拖拽：尝试 URL representation：\(representation.typeIdentifier)")
        representation.provider.value.loadItem(forTypeIdentifier: representation.typeIdentifier, options: nil) { item, error in
            if let error {
                performanceSpan?.finish(
                    outcome: performanceOutcome(for: error),
                    context: ["error": error.localizedDescription]
                )
                CoverDropDebugLog.write(
                    "封面拖拽：读取 URL representation 失败，type=\(representation.typeIdentifier)，\(debugDescription(for: error))"
                )
                if let url = remoteURL(from: error) {
                    CoverDropDebugLog.write("封面拖拽：从 URL representation 错误文案提取到远程 URL：\(url.absoluteString)")
                    Task { @MainActor in
                        let didStage = await appModel.stageDroppedCoverURL(url, forAlbumID: albumID)
                        if didStage {
                            CoverDropDebugLog.write("封面拖拽：URL 错误文案提取结果暂存成功，URL=\(url.absoluteString)")
                            acceptanceHandler.callIfPresent()
                        } else {
                            CoverDropDebugLog.write("封面拖拽：URL 错误文案提取结果暂存失败，URL=\(url.absoluteString)")
                        }
                    }
                    return
                }

                CoverDropDebugLog.write("封面拖拽：当前 URL representation 未提取到远程 URL，尝试下一个")
                if loadFirstURLIfAvailable(
                    from: remainingRepresentations,
                    imageFallback: imageFallback,
                    fallbackRemoteURL: fallbackRemoteURL,
                    albumID: albumID,
                    appModel: appModel,
                    acceptanceHandler: acceptanceHandler
                ) {
                    return
                }

                if loadImageFallbackIfAvailable(
                    imageFallback,
                    albumID: albumID,
                    appModel: appModel,
                    acceptanceHandler: acceptanceHandler
                ) {
                    return
                }

                if loadFallbackRemoteURLIfAvailable(
                    fallbackRemoteURL,
                    albumID: albumID,
                    appModel: appModel,
                    acceptanceHandler: acceptanceHandler,
                    context: "URL representation 全部读取失败"
                ) {
                    return
                }

                Task { @MainActor in
                    appModel.errorMessage = "无法读取拖入的图片地址：\(error.localizedDescription)"
                }
                return
            }

            guard let url = droppedURL(from: item) else {
                performanceSpan?.finish(
                    outcome: .failure,
                    context: ["error": "unrecognized_item"]
                )
                CoverDropDebugLog.write(
                    "封面拖拽：URL representation 返回了无法识别的对象，type=\(representation.typeIdentifier)，对象类型=\(String(describing: item.map { Swift.type(of: $0) }))"
                )
                if loadFirstURLIfAvailable(
                    from: remainingRepresentations,
                    imageFallback: imageFallback,
                    fallbackRemoteURL: fallbackRemoteURL,
                    albumID: albumID,
                    appModel: appModel,
                    acceptanceHandler: acceptanceHandler
                ) {
                    return
                }

                if loadImageFallbackIfAvailable(
                    imageFallback,
                    albumID: albumID,
                    appModel: appModel,
                    acceptanceHandler: acceptanceHandler
                ) {
                    return
                }

                if loadFallbackRemoteURLIfAvailable(
                    fallbackRemoteURL,
                    albumID: albumID,
                    appModel: appModel,
                    acceptanceHandler: acceptanceHandler,
                    context: "URL representation 返回对象无法识别"
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
            performanceSpan?.finish(
                context: ["kind": url.isFileURL ? "file" : "remote"]
            )
            Task { @MainActor in
                let didStage = await appModel.stageDroppedCoverURL(url, forAlbumID: albumID)
                if didStage {
                    CoverDropDebugLog.write("封面拖拽：URL 暂存成功，URL=\(url.absoluteString)")
                    acceptanceHandler.callIfPresent()
                } else if loadFirstURLIfAvailable(
                    from: remainingRepresentations,
                    imageFallback: imageFallback,
                    fallbackRemoteURL: fallbackRemoteURL,
                    albumID: albumID,
                    appModel: appModel,
                    acceptanceHandler: acceptanceHandler
                ) {
                    CoverDropDebugLog.write("封面拖拽：URL 暂存失败，继续尝试下一个 URL representation")
                } else if loadImageFallbackIfAvailable(
                    imageFallback,
                    albumID: albumID,
                    appModel: appModel,
                    acceptanceHandler: acceptanceHandler
                ) {
                    CoverDropDebugLog.write("封面拖拽：URL 暂存失败，改读图片 representation")
                } else if loadFallbackRemoteURLIfAvailable(
                    fallbackRemoteURL,
                    albumID: albumID,
                    appModel: appModel,
                    acceptanceHandler: acceptanceHandler,
                    context: "URL 暂存失败"
                ) {
                    CoverDropDebugLog.write("封面拖拽：URL 暂存失败，改用备用远程 URL")
                }
            }
        }
    }

    nonisolated private static func loadImageData(
        from provider: NSItemProvider,
        typeIdentifier: String,
        urlRepresentations: [URLItemRepresentation],
        fallbackRemoteURL: URL?,
        albumID: AlbumScanRecord.ID,
        appModel: AppModel,
        acceptanceHandler: AcceptanceHandlerBox
    ) {
        let performanceSpan = CoverDropPerformanceLog.begin(
            CoverDropPerformanceOperation.readDroppedImage,
            context: [
                "albumID": albumID,
                "representation": typeIdentifier
            ]
        )
        CoverDropDebugLog.write("封面拖拽：开始读取图片数据 representation：\(typeIdentifier)")
        let sendableProvider = SendableItemProvider(value: provider)
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
            if let error {
                performanceSpan?.finish(
                    outcome: performanceOutcome(for: error),
                    context: ["error": error.localizedDescription]
                )
                CoverDropDebugLog.write(
                    "封面拖拽：读取图片数据 representation 失败，type=\(typeIdentifier)，\(debugDescription(for: error))"
                )
                if let url = remoteURL(from: error) {
                    CoverDropDebugLog.write("封面拖拽：从图片数据错误文案提取到远程 URL：\(url.absoluteString)")
                    Task { @MainActor in
                        let didStage = await appModel.stageDroppedCoverURL(url, forAlbumID: albumID)
                        if didStage {
                            CoverDropDebugLog.write("封面拖拽：图片错误文案提取结果暂存成功，URL=\(url.absoluteString)")
                            acceptanceHandler.callIfPresent()
                        } else {
                            CoverDropDebugLog.write("封面拖拽：图片错误文案提取结果暂存失败，URL=\(url.absoluteString)")
                        }
                    }
                    return
                }

                if urlRepresentations.isEmpty {
                    CoverDropDebugLog.write(
                        "封面拖拽：provider 无声明可用 URL representation，\(typeIdentifier) 无可用 loader；开始探测 URL/文本 representation。"
                    )
                }

                let fallbackURLRepresentations = urlRepresentations.isEmpty
                    ? speculativeURLRepresentations(in: sendableProvider.value)
                    : urlRepresentations
                if loadFirstURLIfAvailable(
                    from: fallbackURLRepresentations[...],
                    fallbackRemoteURL: fallbackRemoteURL,
                    albumID: albumID,
                    appModel: appModel,
                    acceptanceHandler: acceptanceHandler
                ) {
                    return
                }

                if let fallbackRemoteURL {
                    CoverDropDebugLog.write(
                        "封面拖拽：使用 WKWebView 已缓存图片 URL 暂存：\(fallbackRemoteURL.absoluteString)"
                    )
                    Task { @MainActor in
                        let didStage = await appModel.stageDroppedCoverURL(fallbackRemoteURL, forAlbumID: albumID)
                        if didStage {
                            acceptanceHandler.callIfPresent()
                        }
                    }
                    return
                }

                Task { @MainActor in
                    appModel.errorMessage = "无法读取拖入的网页图片：\(error.localizedDescription)"
                }
                return
            }

            guard let data else {
                performanceSpan?.finish(
                    outcome: .failure,
                    context: ["error": "empty_data"]
                )
                CoverDropDebugLog.write("封面拖拽：图片数据 representation 成功回调但 data 为 nil，type=\(typeIdentifier)")
                let fallbackURLRepresentations = urlRepresentations.isEmpty
                    ? speculativeURLRepresentations(in: sendableProvider.value)
                    : urlRepresentations
                if loadFirstURLIfAvailable(
                    from: fallbackURLRepresentations[...],
                    fallbackRemoteURL: fallbackRemoteURL,
                    albumID: albumID,
                    appModel: appModel,
                    acceptanceHandler: acceptanceHandler
                ) {
                    return
                }

                if let fallbackRemoteURL {
                    CoverDropDebugLog.write(
                        "封面拖拽：图片数据为空，使用 WKWebView 已缓存图片 URL 暂存：\(fallbackRemoteURL.absoluteString)"
                    )
                    Task { @MainActor in
                        let didStage = await appModel.stageDroppedCoverURL(fallbackRemoteURL, forAlbumID: albumID)
                        if didStage {
                            acceptanceHandler.callIfPresent()
                        }
                    }
                    return
                }

                Task { @MainActor in
                    appModel.errorMessage = "拖入的网页图片没有可用数据。"
                }
                return
            }

            CoverDropDebugLog.write("封面拖拽：图片数据 representation 读取成功，type=\(typeIdentifier)，大小=\(data.count) bytes")
            performanceSpan?.finish(context: ["bytes": "\(data.count)"])
            Task { @MainActor in
                let didStage = await appModel.stageCoverImageData(
                    data,
                    suggestedExtension: suggestedExtension(for: typeIdentifier),
                    forAlbumID: albumID
                )
                if didStage {
                    acceptanceHandler.callIfPresent()
                }
            }
        }
    }

    nonisolated private static func loadURLFallbackIfAvailable(
        from representations: [URLItemRepresentation],
        albumID: AlbumScanRecord.ID,
        appModel: AppModel,
        acceptanceHandler: AcceptanceHandlerBox
    ) -> Bool {
        loadFirstURLIfAvailable(
            from: representations[...],
            albumID: albumID,
            appModel: appModel,
            acceptanceHandler: acceptanceHandler
        )
    }

    nonisolated private static func loadFirstURLIfAvailable(
        from representations: ArraySlice<URLItemRepresentation>,
        imageFallback: ImageDataRepresentation? = nil,
        fallbackRemoteURL: URL? = nil,
        albumID: AlbumScanRecord.ID,
        appModel: AppModel,
        acceptanceHandler: AcceptanceHandlerBox
    ) -> Bool {
        guard let representation = representations.first else { return false }

        loadURL(
            from: representation,
            remainingRepresentations: representations.dropFirst(),
            imageFallback: imageFallback,
            fallbackRemoteURL: fallbackRemoteURL,
            albumID: albumID,
            appModel: appModel,
            acceptanceHandler: acceptanceHandler
        )
        return true
    }

    nonisolated private static func loadImageFallbackIfAvailable(
        _ imageFallback: ImageDataRepresentation?,
        albumID: AlbumScanRecord.ID,
        appModel: AppModel,
        acceptanceHandler: AcceptanceHandlerBox
    ) -> Bool {
        guard let imageFallback else { return false }
        CoverDropDebugLog.write("封面拖拽：改读图片数据 representation：\(imageFallback.typeIdentifier)")
        loadImageData(
            from: imageFallback.provider.value,
            typeIdentifier: imageFallback.typeIdentifier,
            urlRepresentations: [],
            fallbackRemoteURL: imageFallback.fallbackRemoteURL,
            albumID: albumID,
            appModel: appModel,
            acceptanceHandler: acceptanceHandler
        )
        return true
    }

    nonisolated private static func loadFallbackRemoteURLIfAvailable(
        _ fallbackRemoteURL: URL?,
        albumID: AlbumScanRecord.ID,
        appModel: AppModel,
        acceptanceHandler: AcceptanceHandlerBox,
        context: String
    ) -> Bool {
        guard let fallbackRemoteURL else { return false }
        CoverDropDebugLog.write(
            "封面拖拽：\(context)，使用 WKWebView 已缓存图片 URL 暂存：\(fallbackRemoteURL.absoluteString)"
        )
        Task { @MainActor in
            let didStage = await appModel.stageDroppedCoverURL(fallbackRemoteURL, forAlbumID: albumID)
            if didStage {
                CoverDropDebugLog.write("封面拖拽：备用远程 URL 暂存成功，URL=\(fallbackRemoteURL.absoluteString)")
                acceptanceHandler.callIfPresent()
            } else {
                CoverDropDebugLog.write("封面拖拽：备用远程 URL 暂存失败，URL=\(fallbackRemoteURL.absoluteString)")
            }
        }
        return true
    }

    nonisolated private static func urlRepresentations(in provider: NSItemProvider) -> [URLItemRepresentation] {
        let sendableProvider = SendableItemProvider(value: provider)
        return urlTypeIdentifiers
            .filter { provider.hasItemConformingToTypeIdentifier($0) }
            .map { URLItemRepresentation(provider: sendableProvider, typeIdentifier: $0) }
    }

    nonisolated private static func speculativeURLRepresentations(in provider: NSItemProvider) -> [URLItemRepresentation] {
        let sendableProvider = SendableItemProvider(value: provider)
        CoverDropDebugLog.write(
            "封面拖拽：探测全部 URL/文本 representation：\(urlTypeIdentifiers.joined(separator: ", "))"
        )
        return urlTypeIdentifiers.map {
            URLItemRepresentation(provider: sendableProvider, typeIdentifier: $0)
        }
    }

    nonisolated private static func droppedURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data {
            if let string = String(data: data, encoding: .utf8) {
                return URL(string: cleanedURLString(string))
            }

            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return url
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
        return debugDescription(for: nsError, depth: 0)
    }

    nonisolated private static func performanceOutcome(
        for error: Error
    ) -> CoverDropPerformanceOutcome {
        (error as NSError).code == NSUserCancelledError ? .cancelled : .failure
    }

    nonisolated private static func debugDescription(for error: NSError, depth: Int) -> String {
        guard depth <= 3 else {
            return "domain=\(error.domain)，code=\(error.code)，description=\(error.localizedDescription)，userInfo=<max-depth>"
        }

        let userInfo = error.userInfo
            .sorted { "\($0.key)" < "\($1.key)" }
            .map { key, value in
                if key == NSUnderlyingErrorKey,
                   let underlying = value as? NSError {
                    return "\(key)=\(debugDescription(for: underlying, depth: depth + 1))"
                }
                return "\(key)=\(String(describing: value))"
            }
            .joined(separator: "；")

        return "domain=\(error.domain)，code=\(error.code)，description=\(error.localizedDescription)，userInfo={\(userInfo)}"
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
    var contentRevision: UInt64 = 0
    let maxPixelSize: CGFloat
    let placeholderSize: CGFloat
    let placeholderText: String?

    @State private var image: NSImage?

    private var thumbnailRequestKey: String {
        "\(url?.standardizedFileURL.path ?? "empty")|\(contentRevision)@\(Int(maxPixelSize))"
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
        .task(id: thumbnailRequestKey) {
            await loadThumbnail(requestKey: thumbnailRequestKey)
        }
    }

    @MainActor
    private func loadThumbnail(requestKey: String) async {
        guard let url else {
            image = nil
            return
        }

        image = nil
        let request = CoverThumbnailLoader.Request(
            url: url,
            maxPixelSize: maxPixelSize,
            contentRevision: contentRevision
        )
        let loaded = await CoverThumbnailLoader.shared.image(for: request)

        guard !Task.isCancelled,
              requestKey == thumbnailRequestKey else {
            return
        }
        image = loaded?.image
    }
}

private struct CachedAlbumCoverPreview: View {
    let url: URL?
    var contentRevision: UInt64 = 0
    let maxPixelSize: CGFloat
    let placeholderSize: CGFloat
    let cornerRadius: CGFloat

    @State private var image: NSImage?

    private var thumbnailRequestKey: String {
        "\(url?.standardizedFileURL.path ?? "empty")|\(contentRevision)@\(Int(maxPixelSize))"
    }

    var body: some View {
        AlbumCoverPreview(
            image: image,
            placeholderSize: placeholderSize,
            cornerRadius: cornerRadius
        )
        .task(id: thumbnailRequestKey) {
            await loadThumbnail(requestKey: thumbnailRequestKey)
        }
    }

    @MainActor
    private func loadThumbnail(requestKey: String) async {
        guard let url else {
            image = nil
            return
        }

        image = nil
        let request = CoverThumbnailLoader.Request(
            url: url,
            maxPixelSize: maxPixelSize,
            contentRevision: contentRevision
        )
        let loaded = await CoverThumbnailLoader.shared.image(for: request)

        guard !Task.isCancelled,
              requestKey == thumbnailRequestKey else {
            return
        }
        image = loaded?.image
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
