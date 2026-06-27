import AppKit
import SwiftUI

struct LibraryHomeView: View {
    let appModel: AppModel

    @State private var isDropTargeted = false
    @State private var libraryToRemove: LibraryRecord?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 560)
        .task {
            await appModel.loadLibraries()
        }
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
        .alert("无法完成操作", isPresented: Binding(
            get: { appModel.errorMessage != nil },
            set: { if !$0 { appModel.errorMessage = nil } }
        )) {
            Button("好") { appModel.errorMessage = nil }
        } message: {
            Text(appModel.errorMessage ?? "未知错误")
        }
        .confirmationDialog(
            "从 CoverDrop 移除这个音乐库？",
            isPresented: Binding(
                get: { libraryToRemove != nil },
                set: { if !$0 { libraryToRemove = nil } }
            ),
            presenting: libraryToRemove
        ) { _ in
            Button("只删除本地记录", role: .destructive) {
                Task {
                    await appModel.removeSelectedLibrary()
                    libraryToRemove = nil
                }
            }
            Button("取消", role: .cancel) {}
        } message: { library in
            Text("不会删除音乐库中的任何文件。\n\(library.rootPath)")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(appModel.libraries, selection: Binding(
                get: { appModel.selectedLibraryID },
                set: { appModel.selectLibrary(id: $0) }
            )) { library in
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.displayName)
                    Text(library.role.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(library.id)
            }

            Divider()

            Button(action: chooseFolder) {
                Label("添加音乐库", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding()
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }

    @ViewBuilder
    private var detail: some View {
        if let library = appModel.selectedLibrary {
            if appModel.shouldShowCoverWallForSelectedLibrary,
               let result = appModel.scanResultForSelectedLibrary {
                coverWallPage(library: library, result: result)
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        libraryDetail(library)
                            .frame(maxWidth: 720)
                            .padding(40)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: geometry.size.height,
                                alignment: .center
                            )
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("添加音乐库", systemImage: "folder.badge.plus")
            } description: {
                Text("点击左下角按钮，或把一个音乐文件夹拖到窗口中。")
            } actions: {
                Button("选择文件夹", action: chooseFolder)
            }
        }
    }

    private func coverWallPage(
        library: LibraryRecord,
        result: LibraryScanResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(library.displayName)
                        .font(.title2.bold())
                    Text("扫描结果 · \(library.rootPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(library.rootPath)
                }

                Spacer()

                Button("返回音乐库") {
                    appModel.showSelectedLibraryHome()
                }
            }

            LibraryScanSummaryView(result: result, appModel: appModel)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func libraryDetail(_ library: LibraryRecord) -> some View {
        VStack(alignment: .center, spacing: 20) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)

            Text(library.displayName)
                .font(.largeTitle.bold())

            VStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    Text("目录角色")
                        .foregroundStyle(.secondary)
                    Text(library.role.displayName)
                }

                HStack(spacing: 8) {
                    Text("文件夹路径")
                        .foregroundStyle(.secondary)
                    Text(library.rootPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(library.rootPath)
                }
            }

            HStack {
                Button(appModel.scanResultForSelectedLibrary == nil ? "扫描音乐库" : "重新扫描") {
                    Task { await appModel.scanSelectedLibrary() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.isScanningLibrary)

                Button("移除", role: .destructive) {
                    libraryToRemove = library
                }
            }

            if appModel.isSelectedLibraryScanning {
                if let progress = appModel.scanProgress {
                    LibraryScanProgressView(progress: progress)
                        .frame(maxWidth: 620)
                } else {
                    ProgressView("正在准备扫描…")
                        .controlSize(.small)
                }
            } else if appModel.isScanningLibrary {
                Text("另一个音乐库正在扫描，本目录尚未开始。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("扫描会读取音频标签，但不会修改音乐文件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
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
}

#Preview {
    LibraryHomeView(appModel: AppModel())
}
