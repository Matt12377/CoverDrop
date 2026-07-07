import AppKit
import SwiftUI

struct LibraryHomeView: View {
    @ObservedObject var appModel: AppModel

    @State private var isDropTargeted = false
    @State private var selectedLibraryIDs: Set<LibraryRecord.ID> = []
    @State private var lastSelectedLibraryID: LibraryRecord.ID?
    @State private var libraryIDsPendingRemoval: Set<LibraryRecord.ID> = []
    @State private var libraryRenameTarget: LibraryRecord?
    @State private var libraryRenameText = ""
    @State private var keyDownMonitor: Any?

    var body: some View {
        baseView
            .alert("无法完成操作", isPresented: Binding(
                get: { appModel.errorMessage != nil },
                set: { if !$0 { appModel.errorMessage = nil } }
            )) {
                Button("好") { appModel.errorMessage = nil }
            } message: {
                Text(errorAlertMessage)
            }
            .confirmationDialog(
                removalDialogTitle,
                isPresented: Binding(
                    get: { !libraryIDsPendingRemoval.isEmpty },
                    set: { if !$0 { libraryIDsPendingRemoval = [] } }
                )
            ) {
                Button("只删除本地记录", role: .destructive) {
                    let ids = libraryIDsPendingRemoval
                    Task {
                        await appModel.removeLibraries(ids: ids)
                        selectedLibraryIDs.subtract(ids)
                        libraryIDsPendingRemoval = []
                        syncSidebarSelectionWithCurrentLibrary()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(removalDialogMessage)
            }
            .alert("重命名音乐库", isPresented: Binding(
                get: { libraryRenameTarget != nil },
                set: { if !$0 { libraryRenameTarget = nil } }
            )) {
                TextField("名称", text: $libraryRenameText)
                Button("保存") {
                    guard let target = libraryRenameTarget else { return }
                    Task {
                        await appModel.renameLibrary(
                            id: target.id,
                            displayName: libraryRenameText
                        )
                        libraryRenameTarget = nil
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(libraryRenameTarget?.rootPath ?? "")
            }
    }

    private var baseView: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 560)
        .task {
            await appModel.loadLibraries()
            syncSidebarSelectionWithCurrentLibrary()
        }
        .onAppear {
            installKeyDownMonitorIfNeeded()
        }
        .onDisappear {
            removeKeyDownMonitor()
        }
        .onChange(of: appModel.selectedLibraryID) { _, _ in
            syncSidebarSelectionWithCurrentLibrary()
        }
        .onChange(of: appModel.libraries) { _, _ in
            reconcileSidebarSelection()
        }
        .sheet(item: Binding(
            get: { appModel.pendingImport },
            set: { appModel.pendingImport = $0 }
        )) { pendingImport in
            LibraryRoleConfirmationView(
                pendingImport: pendingImport,
                onCancel: { appModel.pendingImport = nil },
                onConfirm: { role in
                    Task { await appModel.confirmImport(role: role) }
                }
            )
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LibraryHomeDesignToken.accent)
                    .frame(width: 24, height: 24)
                    .background(LibraryHomeDesignToken.accentBg, in: RoundedRectangle(cornerRadius: 7))

                Text("CoverDrop")
                    .font(.title3.bold())
                    .foregroundStyle(LibraryHomeDesignToken.textPrimary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 18)

            Text("MUSIC LIBRARY")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                .tracking(0.5)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(appModel.libraries) { library in
                        LibraryListItem(
                            library: library,
                            isSelected: selectedLibraryIDs.contains(library.id),
                            albumCount: appModel.scanResultsByLibraryID[library.id]?.albums.count,
                            identityColor: identityColor(for: library)
                        ) {
                            selectLibraryFromSidebar(library)
                        }
                        .contextMenu {
                            libraryContextMenu(for: library)
                        }
                        .padding(.horizontal, 10)
                    }
                }
            }
            .scrollIndicators(.never)

            Spacer(minLength: 12)

            Button {
            } label: {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.coverDropSecondary(height: 32))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            LibraryDividerLine()

            Button(action: chooseFolder) {
                Label("添加音乐库", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.coverDropSecondary(height: 34))
            .padding(12)
        }
        .background(LibraryHomeDesignToken.bgPrimary)
        .overlay {
            if isDropTargeted {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 24, weight: .semibold))
                    Text("拖入音乐文件夹")
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(LibraryHomeDesignToken.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LibraryHomeDesignToken.bgPrimary.opacity(0.86))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            LibraryHomeDesignToken.borderStrong,
                            style: StrokeStyle(lineWidth: 1, dash: [7])
                        )
                        .padding(8)
                }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 240)
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let url = urls.first else {
                appModel.errorMessage = "请一次只拖入一个音乐文件夹。"
                return false
            }
            Task { await appModel.prepareImport(url: url) }
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let library = appModel.selectedLibrary {
            if appModel.isSelectedLibraryScanning {
                scanProgressPage(library: library)
            } else if appModel.shouldShowCoverWallForSelectedLibrary,
               let result = appModel.scanResultForSelectedLibrary {
                coverWallPage(library: library, result: result)
            } else {
                coverWallEmptyPage
            }
        } else {
            coverWallEmptyPage
        }
    }

    private func scanProgressPage(library: LibraryRecord) -> some View {
        VStack(spacing: 12) {
            Text(appModel.scanProgress?.phase.displayName ?? "正在准备扫描")
                .font(.callout.weight(.medium))
                .foregroundStyle(LibraryHomeDesignToken.textSecondary)

            ScanProgressBar(fraction: appModel.scanProgress?.albumProgressFraction)
                .frame(width: 260, height: 6)

            Text(appModel.scanProgress?.completedDescription ?? "正在建立专辑清单…")
                .font(.caption)
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                .lineLimit(1)

            Text(library.displayName)
                .font(.caption2)
                .foregroundStyle(LibraryHomeDesignToken.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LibraryHomeDesignToken.bgSecondary.ignoresSafeArea())
    }

    private func coverWallPage(
        library: LibraryRecord,
        result: LibraryScanResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(library.displayName)
                        .font(.title3.bold())
                        .foregroundStyle(LibraryHomeDesignToken.textPrimary)
                    Text("扫描结果 · \(library.rootPath)")
                        .font(.caption)
                        .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(library.rootPath)

                    if let snapshot = appModel.activeScanSnapshot(for: library.id) {
                        Text("快照结果 · \(snapshot.fileURL.lastPathComponent)")
                            .font(.caption)
                            .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(snapshot.fileURL.path)
                    }

                    if let message = appModel.realtimeRefreshMessage(for: library.id) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(LibraryHomeDesignToken.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            LibraryDividerLine()

            LibraryScanSummaryView(result: result, appModel: appModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LibraryHomeDesignToken.bgSecondary.ignoresSafeArea())
    }

    private var coverWallEmptyPage: some View {
        Text("尚未扫描音乐库")
            .font(.callout)
            .foregroundStyle(LibraryHomeDesignToken.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(LibraryHomeDesignToken.bgSecondary.ignoresSafeArea())
    }

    private func identityColor(for library: LibraryRecord) -> Color {
        let colors = [
            LibraryHomeDesignToken.accent,
            LibraryHomeDesignToken.success,
            LibraryHomeDesignToken.warning,
            Color(red: 191 / 255, green: 90 / 255, blue: 242 / 255),
            Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255)
        ]
        return colors[abs(library.id.hashValue) % colors.count]
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择音乐文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await appModel.prepareImport(url: url) }
    }

    @ViewBuilder
    private func libraryContextMenu(for library: LibraryRecord) -> some View {
        let actionIDs = contextActionLibraryIDs(for: library.id)
        let isSingleAction = actionIDs.count == 1
        Button("全选") {
            selectAllLibraries()
        }
        .disabled(appModel.libraries.isEmpty)

        Button(appModel.scanResultsByLibraryID[library.id] == nil ? "扫描" : "重新扫描") {
            prepareContextSelection(for: library.id)
            Task { await appModel.scanLibraries(ids: [library.id]) }
        }
        .disabled(appModel.isScanningLibrary || !isSingleAction)

        Button(appModel.isLoadingScanSnapshot(for: library.id) ? "加载中" : "加载上次扫描") {
            prepareContextSelection(for: library.id)
            Task { await appModel.loadLatestScanSnapshotForSelectedLibrary() }
        }
        .disabled(
            appModel.isScanningLibrary ||
            appModel.isLoadingScanSnapshot(for: library.id) ||
            appModel.latestScanSnapshot(for: library.id) == nil ||
            !isSingleAction
        )

        Button("重命名") {
            prepareContextSelection(for: library.id)
            beginRename(libraryID: actionIDs.first)
        }
        .disabled(actionIDs.count != 1)

        Divider()

        Button("移除", role: .destructive) {
            prepareContextSelection(for: library.id)
            libraryIDsPendingRemoval = actionIDs
        }
        .disabled(actionIDs.isEmpty)
    }

    private var removalDialogTitle: String {
        libraryIDsPendingRemoval.count <= 1
            ? "从 CoverDrop 移除这个音乐库？"
            : "从 CoverDrop 移除 \(libraryIDsPendingRemoval.count) 个音乐库？"
    }

    private var errorAlertMessage: String {
        appModel.errorMessage ?? "未知错误"
    }

    private var removalDialogMessage: String {
        let libraries = appModel.libraries.filter { libraryIDsPendingRemoval.contains($0.id) }
        let paths = libraries.map(\.rootPath).joined(separator: "\n")
        return "不会删除音乐库中的任何文件。\n\(paths)"
    }

    private func selectLibraryFromSidebar(_ library: LibraryRecord) {
        let modifierFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifierFlags.contains(.shift) {
            selectLibraryRange(endingAt: library.id)
            appModel.selectLibrary(id: library.id)
            return
        }

        if modifierFlags.contains(.command) {
            toggleLibrarySelection(library.id)
            return
        }

        selectedLibraryIDs = [library.id]
        lastSelectedLibraryID = library.id
        appModel.selectLibrary(id: library.id)
    }

    private func selectLibraryRange(endingAt libraryID: LibraryRecord.ID) {
        let orderedIDs = appModel.libraries.map(\.id)
        guard let endIndex = orderedIDs.firstIndex(of: libraryID) else { return }
        let anchorID = lastSelectedLibraryID ?? appModel.selectedLibraryID ?? libraryID
        guard let startIndex = orderedIDs.firstIndex(of: anchorID) else {
            selectedLibraryIDs = [libraryID]
            lastSelectedLibraryID = libraryID
            return
        }

        let bounds = min(startIndex, endIndex)...max(startIndex, endIndex)
        selectedLibraryIDs = Set(orderedIDs[bounds])
    }

    private func toggleLibrarySelection(_ libraryID: LibraryRecord.ID) {
        if selectedLibraryIDs.contains(libraryID) {
            selectedLibraryIDs.remove(libraryID)
            if appModel.selectedLibraryID == libraryID {
                appModel.selectLibrary(id: selectedLibraryIDs.first)
            }
        } else {
            selectedLibraryIDs.insert(libraryID)
            appModel.selectLibrary(id: libraryID)
        }
        lastSelectedLibraryID = libraryID
    }

    private func selectAllLibraries() {
        let ids = appModel.libraries.map(\.id)
        selectedLibraryIDs = Set(ids)
        if lastSelectedLibraryID == nil {
            lastSelectedLibraryID = appModel.selectedLibraryID ?? ids.first
        }
        if appModel.selectedLibraryID == nil {
            appModel.selectLibrary(id: ids.first)
        }
    }

    private func contextActionLibraryIDs(for libraryID: LibraryRecord.ID) -> Set<LibraryRecord.ID> {
        selectedLibraryIDs.contains(libraryID) ? selectedLibraryIDs : [libraryID]
    }

    private func prepareContextSelection(for libraryID: LibraryRecord.ID) {
        guard !selectedLibraryIDs.contains(libraryID) else { return }
        selectedLibraryIDs = [libraryID]
        lastSelectedLibraryID = libraryID
        appModel.selectLibrary(id: libraryID)
    }

    private func beginRename(libraryID: LibraryRecord.ID?) {
        guard let libraryID,
              let library = appModel.libraries.first(where: { $0.id == libraryID }) else {
            return
        }
        libraryRenameTarget = library
        libraryRenameText = library.displayName
    }

    private func syncSidebarSelectionWithCurrentLibrary() {
        guard selectedLibraryIDs.isEmpty,
              let selectedLibraryID = appModel.selectedLibraryID else {
            return
        }
        selectedLibraryIDs = [selectedLibraryID]
        lastSelectedLibraryID = selectedLibraryID
    }

    private func reconcileSidebarSelection() {
        let validIDs = Set(appModel.libraries.map(\.id))
        selectedLibraryIDs = selectedLibraryIDs.intersection(validIDs)
        if let lastSelectedLibraryID, !validIDs.contains(lastSelectedLibraryID) {
            self.lastSelectedLibraryID = selectedLibraryIDs.first
        }

        if let selectedLibraryID = appModel.selectedLibraryID,
           validIDs.contains(selectedLibraryID) {
            syncSidebarSelectionWithCurrentLibrary()
        } else {
            appModel.selectLibrary(id: appModel.libraries.first?.id)
            syncSidebarSelectionWithCurrentLibrary()
        }
    }

    private func installKeyDownMonitorIfNeeded() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.charactersIgnoringModifiers?.lowercased() == "a",
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  !isTextInputFocused() else {
                return event
            }
            selectAllLibraries()
            return nil
        }
    }

    private func removeKeyDownMonitor() {
        guard let keyDownMonitor else { return }
        NSEvent.removeMonitor(keyDownMonitor)
        self.keyDownMonitor = nil
    }
}

private func isTextInputFocused() -> Bool {
    NSApp.keyWindow?.firstResponder is NSTextView
}

struct LibraryHomeView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryHomeView(appModel: AppModel())
    }
}

private struct LibraryListItem: View {
    let library: LibraryRecord
    let isSelected: Bool
    let albumCount: Int?
    let identityColor: Color
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(identityColor)
                    .frame(width: 6, height: 6)

                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .semibold))

                VStack(alignment: .leading, spacing: 1) {
                    Text(library.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(library.role.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let albumCount {
                    Text(albumCount, format: .number)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelected ? LibraryHomeDesignToken.accent : LibraryHomeDesignToken.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            isSelected ? LibraryHomeDesignToken.accentBg : LibraryHomeDesignToken.bgElevated,
                            in: Capsule()
                        )
                }
            }
            .foregroundStyle(isSelected ? LibraryHomeDesignToken.accent : LibraryHomeDesignToken.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusSm))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(library.rootPath)
    }

    private var rowBackground: Color {
        if isSelected {
            LibraryHomeDesignToken.accentBg
        } else if isHovered {
            LibraryHomeDesignToken.bgTertiary
        } else {
            .clear
        }
    }
}

private struct ScanProgressBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LibraryHomeDesignToken.bgElevated)

                Capsule()
                    .fill(LibraryHomeDesignToken.accent.opacity(fraction == nil ? 0.45 : 1))
                    .frame(width: progressWidth(in: proxy.size.width))
            }
        }
        .accessibilityLabel("扫描进度")
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard let fraction else {
            return max(totalWidth * 0.28, 44)
        }
        return totalWidth * CGFloat(min(max(fraction, 0), 1))
    }
}
