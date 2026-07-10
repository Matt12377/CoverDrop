# Library Overview And Enhancement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让封面墙头部只显示当前页面对应数量，把当前动作移到音乐库地址下方，把进度条缩短放到右上角并在下方显示 `xxx/xxx`，同时让音乐库级智能解析只处理当前音乐库缺封面的专辑。

**Architecture:** 行为变更集中在 `AppModel.requestAlbumNameEnhancement(forLibraryID:)`，复用现有 `isMissingCover(_:)` 和队列去重逻辑，不改变详情页单专辑手动解析。UI 变更集中在 `LibraryScanSummaryView`，用当前 `filteredAlbums` / `filteredLooseAudioPaths` 的可见结果作为头部数量来源，避免另建统计缓存。

**Tech Stack:** Swift 6、SwiftUI、Swift Testing、macOS AppKit/SwiftUI 应用、现有 `Scripts/verify.sh` 验证脚本。

## Global Constraints

- 所有用户可见文案、注释、文档使用中文。
- 不提交 `default.profraw`。
- 不回滚用户或其它会话已有改动。
- 手动单专辑智能解析继续允许已有封面专辑。
- 音乐库级智能解析只解析当前音乐库缺封面的专辑。
- 进度条下方显示 `completedAlbums/totalAlbums` 格式。

---

### Task 1: 音乐库智能解析范围测试

**Files:**
- Modify: `CoverDropTests/Unit/AppModelImportTests.swift`

**Interfaces:**
- Consumes: `AppModel.requestAlbumNameEnhancement(forLibraryID:)`
- Produces: 测试约束：音乐库级解析跳过已有封面，进度总数只包含缺封面。

- [ ] **Step 1: Write the failing test**

把 `libraryEnhancementHandlesCoveredAlbums` 改成只期待缺封面专辑被处理：

```swift
@Test("音乐库智能解析只处理缺封面的专辑")
func libraryEnhancementOnlyHandlesMissingCoverAlbums() async throws {
    try await withTemporaryDirectory { root in
        let covered = makeAlbum(
            folderURL: root.appendingPathComponent("Artist/Covered", isDirectory: true),
            albumName: "Covered",
            hasCover: true
        )
        let missing = makeAlbum(
            folderURL: root.appendingPathComponent("Artist/Missing", isDirectory: true),
            albumName: "Missing"
        )
        let recorder = AlbumNameSuggestionRecorder()
        let appModel = await makeScannedAppModel(
            root: root,
            albums: [covered, missing],
            albumNameSuggesting: RecordingAlbumNameSuggesting(recorder: recorder)
        )

        let libraryID = try #require(appModel.selectedLibraryID)
        await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)
        await recorder.reset()

        appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)
        await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)

        #expect(await recorder.albumNames() == ["Missing"])
        let progress = try #require(appModel.albumNameEnhancementProgress(for: libraryID))
        #expect(progress.completedAlbums == 1)
        #expect(progress.totalAlbums == 1)
        #expect(progress.isFinished)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AppModelImportTests/libraryEnhancementOnlyHandlesMissingCoverAlbums
```

Expected: FAIL，实际 recorder 仍包含 `["Covered", "Missing"]`，证明旧逻辑还在处理已有封面。

- [ ] **Step 3: Add a zero-target progress regression test**

新增测试，锁定“全是已有封面时音乐库级解析不排队，进度为 0/0”：

```swift
@Test("音乐库智能解析没有缺封面专辑时保持零进度")
func libraryEnhancementWithoutMissingCoverAlbumsKeepsZeroProgress() async throws {
    try await withTemporaryDirectory { root in
        let covered = makeAlbum(
            folderURL: root.appendingPathComponent("Artist/Covered", isDirectory: true),
            albumName: "Covered",
            hasCover: true
        )
        let recorder = AlbumNameSuggestionRecorder()
        let appModel = await makeScannedAppModel(
            root: root,
            albums: [covered],
            albumNameSuggesting: RecordingAlbumNameSuggesting(recorder: recorder)
        )

        let libraryID = try #require(appModel.selectedLibraryID)
        appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)

        #expect(await recorder.albumNames().isEmpty)
        let progress = try #require(appModel.albumNameEnhancementProgress(for: libraryID))
        #expect(progress.completedAlbums == 0)
        #expect(progress.totalAlbums == 0)
        #expect(progress.isFinished == true)
        #expect(appModel.albumNameEnhancementStatus(for: libraryID)?.isRunning == false)
    }
}
```

- [ ] **Step 4: Run new test to verify it fails**

Run:

```bash
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AppModelImportTests/libraryEnhancementWithoutMissingCoverAlbumsKeepsZeroProgress
```

Expected: FAIL，实际 recorder 会记录 `Covered` 或进度为 `1/1`。

### Task 2: 音乐库智能解析只排队缺封面专辑

**Files:**
- Modify: `CoverDrop/App/AppModel.swift`
- Test: `CoverDropTests/Unit/AppModelImportTests.swift`

**Interfaces:**
- Consumes: `Self.isMissingCover(_:)`
- Produces: `requestAlbumNameEnhancement(forLibraryID:)` 仅对缺封面专辑创建 `.libraryManual` 队列项，且 `allowCoveredAlbums` 为 `false`。

- [ ] **Step 1: Write minimal implementation**

把 `requestAlbumNameEnhancement(forLibraryID:)` 中的目标集合改成 `missingCoverAlbums`：

```swift
let missingCoverAlbums = result.albums.filter(Self.isMissingCover)
guard !missingCoverAlbums.isEmpty else {
    albumNameEnhancementProgressByLibraryID[libraryID] = AlbumNameEnhancementProgress(
        completedAlbums: 0,
        totalAlbums: 0,
        currentAlbumName: nil
    )
    albumNameEnhancementStatusByLibraryID[libraryID] = AlbumNameEnhancementStatus(
        isRunning: false,
        lastErrorMessage: nil
    )
    return
}

var queuedAlbumCount = 0
for album in missingCoverAlbums {
    let didEnqueue = enqueueAlbumNameEnhancement(
        AlbumNameEnhancementQueueItem(
            libraryID: libraryID,
            albumID: album.id,
            source: .libraryManual,
            allowCoveredAlbums: false
        ),
        startsWorker: false
    )
    if didEnqueue {
        queuedAlbumCount += 1
    }
}
```

无新队列且没有 pending 时，完成进度用 `missingCoverAlbums.count`：

```swift
albumNameEnhancementProgressByLibraryID[libraryID] = AlbumNameEnhancementProgress(
    completedAlbums: missingCoverAlbums.count,
    totalAlbums: missingCoverAlbums.count,
    currentAlbumName: nil
)
```

- [ ] **Step 2: Run targeted tests to verify pass**

Run:

```bash
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AppModelImportTests/libraryEnhancementOnlyHandlesMissingCoverAlbums -only-testing:CoverDropTests/AppModelImportTests/libraryEnhancementWithoutMissingCoverAlbumsKeepsZeroProgress -only-testing:CoverDropTests/AppModelImportTests/manualEnhancementHandlesCoveredAlbum
```

Expected: PASS，且单专辑已有封面手动解析测试继续通过。

### Task 3: 封面墙头部当前页数量与进度布局

**Files:**
- Modify: `CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift`

**Interfaces:**
- Consumes: `filteredAlbums`、`filteredLooseAudioPaths`、`AlbumScanResultFilter.displayName`、`AlbumNameEnhancementProgress`
- Produces: `libraryOverviewHeader(visibleAlbumCount:visibleLooseAudioCount:)` 显示当前筛选和搜索后的数量。

- [ ] **Step 1: Pass visible counts into header**

在 `body` 中改为：

```swift
libraryOverviewHeader(
    visibleAlbumCount: visibleAlbums.count,
    visibleLooseAudioCount: visibleLooseAudioPaths.count
)
```

- [ ] **Step 2: Replace five stats with one current-page count**

新增两个私有计算 helper：

```swift
private var currentPageCountTitle: String {
    filter == .all ? "专辑数量" : filter.displayName
}

private func currentPageCount(
    visibleAlbumCount: Int,
    visibleLooseAudioCount: Int
) -> Int {
    filter == .looseAudio ? visibleLooseAudioCount : visibleAlbumCount
}
```

将五个 `SummaryStatText` 改为单个：

```swift
SummaryStatText(
    title: currentPageCountTitle,
    value: currentPageCount(
        visibleAlbumCount: visibleAlbumCount,
        visibleLooseAudioCount: visibleLooseAudioCount
    ),
    valueColor: LibraryHomeDesignToken.textPrimary
)
.frame(maxWidth: 220, alignment: .leading)
```

- [ ] **Step 3: Move action text below library path and remove label**

在音乐库名和路径 `VStack` 内，路径下方加入：

```swift
Text(currentActionDescription)
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(currentActionColor)
    .lineLimit(1)
    .truncationMode(.tail)
    .help(currentActionDescription)
```

删除右侧 `Text("当前动作")` 和右侧动作文字。

- [ ] **Step 4: Move compact progress to top-right**

右侧区域只在 `selectedLibraryProgress.totalAlbums > 0` 时显示，宽度约 240：

```swift
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
}
```

删除原来头部底部的整行进度块，避免动作文案重复。

- [ ] **Step 5: Build compile check**

Run:

```bash
xcodebuild build -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS'
```

Expected: BUILD SUCCEEDED。

### Task 4: Final Verification

**Files:**
- Verify only.

**Interfaces:**
- Consumes: 所有前面任务产物。
- Produces: 可交付的验证结果。

- [ ] **Step 1: Check whitespace**

Run:

```bash
git diff --check
```

Expected: no output, exit 0.

- [ ] **Step 2: Run full project verification**

Run:

```bash
zsh Scripts/verify.sh
```

Expected: `** TEST SUCCEEDED **` and exit 0.

- [ ] **Step 3: Inspect final diff**

Run:

```bash
git diff -- CoverDrop/App/AppModel.swift CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift CoverDropTests/Unit/AppModelImportTests.swift docs/superpowers/plans/2026-07-10-library-overview-and-enhancement.md
```

Expected: diff only includes planned changes.

## Self-Review

- Spec coverage: 当前页数量、搜索后数量、右上角短进度条、`xxx/xxx`、动作移到路径下方、移除“当前动作”标签、音乐库级只解析缺封面均有任务覆盖。
- Placeholder scan: 无 `TBD` / `TODO` / “稍后实现”占位。
- Type consistency: 使用现有 `AlbumScanResultFilter`、`AlbumNameEnhancementProgress`、`AppModel` 方法名，未新增跨文件公开接口。
