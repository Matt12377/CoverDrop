# 手动音乐库智能解析控制 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 扫描后不自动解析专辑名；用户手动启动当前音乐库缺封面专辑的智能解析，并能安全停止当前音乐库的解析批次。

**Architecture:** `AppModel` 继续使用单一优先队列，但每次音乐库手动批次带有唯一 ID，且当前 Ollama 请求由独立 `Task` 持有。停止操作仅移除同一音乐库的排队项、取消同一批次的当前请求，并丢弃取消后迟到的结果；不会取消其他音乐库或单专辑手动解析。`LibraryHomeView` 只根据既有 `isAlbumNameEnhancementRunning(for:)` 决定“停止解析”是否可用。

**Tech Stack:** Swift 6、SwiftUI、Swift Testing、现有 `xcodebuild` 与 `Scripts/verify.sh`。

## Global Constraints

- 所有用户可见文案、注释、文档使用中文。
- 不提交 `default.profraw`。
- 不回滚当前工作区已有的总览 UI 与缺封面范围改动。
- 初次扫描、重新扫描与实时局部刷新都不得自动启动名称增强。
- 单专辑详情手动解析仍可解析已有封面的专辑。
- 停止只影响传入 `libraryID` 的当前音乐库批次，已成功结果保留，停止不记为失败。

---

### Task 1: 锁定手动启动与停止语义

**Files:**
- Modify: `CoverDropTests/Unit/AppModelImportTests.swift`

**Interfaces:**
- Consumes: `makeScannedAppModel(root:albums:albumNameSuggesting:)`、`AppModel.requestAlbumNameEnhancement(forLibraryID:)`。
- Produces: 对扫描后不自动解析、手动解析范围和停止语义的回归测试。

- [ ] **Step 1: 将自动解析测试改为扫描后不请求 Ollama**

把现有“名称增强默认只处理缺封面的专辑”测试改为以下断言，验证完成 `scanSelectedLibrary()` 后没有任何 LLM 请求：

```swift
@Test("扫描完成后不自动进行名称增强")
func scanningDoesNotStartNameEnhancementAutomatically() async throws {
    try await withTemporaryDirectory { root in
        let missing = makeAlbum(
            folderURL: root.appendingPathComponent("Artist/Missing", isDirectory: true),
            albumName: "Missing"
        )
        let recorder = AlbumNameSuggestionRecorder()
        let appModel = await makeScannedAppModel(
            root: root,
            albums: [missing],
            albumNameSuggesting: RecordingAlbumNameSuggesting(recorder: recorder)
        )

        #expect(await recorder.albumNames().isEmpty)
        let libraryID = try #require(appModel.selectedLibraryID)
        #expect(appModel.albumNameEnhancementStatus(for: libraryID)?.isRunning != true)
    }
}
```

- [ ] **Step 2: 将依赖扫描自动解析的测试显式改为手动启动**

在所有需要等待 `BlockingRecordingAlbumNameSuggesting` 或 `RecordingAlbumNameSuggesting` 请求的测试里，先取得 `libraryID`，再调用：

```swift
appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)
```

保留覆盖“音乐库批次只处理缺封面”和“详情页单专辑可处理已有封面”的既有断言。

- [ ] **Step 3: 写入停止当前音乐库批次的失败测试**

使用可响应 `Task` 取消的测试用 suggester，让第一张专辑处于请求中、第二张仍排队；调用停止后断言第一张没有写入增强名、第二张从未请求、状态非运行、进度为 `0/2`：

```swift
@Test("停止音乐库智能解析会取消当前请求并清空后续队列")
func stoppingLibraryEnhancementCancelsOnlyCurrentBatch() async throws {
    try await withTemporaryDirectory { root in
        let first = makeAlbum(folderURL: root.appendingPathComponent("Artist/First"), albumName: "First")
        let second = makeAlbum(folderURL: root.appendingPathComponent("Artist/Second"), albumName: "Second")
        let suggester = CancellationAwareBlockingAlbumNameSuggesting()
        let appModel = await makeScannedAppModel(root: root, albums: [first, second], albumNameSuggesting: suggester)
        let libraryID = try #require(appModel.selectedLibraryID)

        appModel.requestAlbumNameEnhancement(forLibraryID: libraryID)
        await waitUntil { await suggester.albumNames() == ["First"] }
        appModel.stopAlbumNameEnhancement(forLibraryID: libraryID)
        await waitForAlbumNameEnhancement(toFinishIn: appModel, libraryID: libraryID)

        #expect(await suggester.albumNames() == ["First"])
        #expect(!appModel.hasEnhancedAlbumName(for: first, in: libraryID))
        #expect(!appModel.hasEnhancedAlbumName(for: second, in: libraryID))
        #expect(appModel.albumNameEnhancementStatus(for: libraryID)?.isRunning == false)
        let progress = try #require(appModel.albumNameEnhancementProgress(for: libraryID))
        #expect(progress.completedAlbums == 0)
        #expect(progress.totalAlbums == 2)
    }
}
```

- [ ] **Step 4: 运行新增测试并确认 RED**

Run:

```bash
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AppModelImportTests/scanningDoesNotStartNameEnhancementAutomatically -only-testing:CoverDropTests/AppModelImportTests/stoppingLibraryEnhancementCancelsOnlyCurrentBatch
```

Expected: FAIL；当前扫描会自动调用 Ollama，且 `stopAlbumNameEnhancement(forLibraryID:)` 尚不存在。

### Task 2: 移除自动启动并实现按音乐库停止

**Files:**
- Modify: `CoverDrop/App/AppModel.swift`
- Test: `CoverDropTests/Unit/AppModelImportTests.swift`

**Interfaces:**
- Produces: `func stopAlbumNameEnhancement(forLibraryID libraryID: LibraryRecord.ID)`；音乐库手动队列项携带批次 ID。

- [ ] **Step 1: 删除扫描路径上的自动入口**

从 `scanLibrary(_:)` 删除：

```swift
startAlbumNameEnhancement(for: library, result: result)
```

从实时局部刷新成功路径删除 `albumIDsNeedingNameEnhancement` 的计算和对应 `startAlbumNameEnhancement(...)` 调用。保留刷新时的 `cancelAlbumNameEnhancement(for:clearsSuggestions:false)`，避免刷新期间把旧扫描结果写回。

- [ ] **Step 2: 为音乐库手动批次加入 ID 与当前请求句柄**

扩展 `AlbumNameEnhancementQueueItem`，为音乐库手动请求记录 `batchID: UUID?`；在 `AppModel` 保存：

```swift
private var activeAlbumNameEnhancementBatchIDs: [LibraryRecord.ID: UUID] = [:]
private var runningAlbumNameEnhancementRequest: (item: AlbumNameEnhancementQueueItem, task: Task<AlbumNameSuggestion, Error>)?
```

`requestAlbumNameEnhancement(forLibraryID:)` 每次启动时创建 `UUID()`，保存为该库的 active ID，并把它传给所有 `.libraryManual` 队列项。单专辑手动解析和遗留自动项保持 `nil`。

- [ ] **Step 3: 让运行中的 Ollama 调用可单独取消，并拒绝迟到结果**

在 `processAlbumNameEnhancement(_:)` 中用独立请求任务调用 suggester：

```swift
let requestTask = Task { [albumNameSuggesting = environment.albumNameSuggesting] in
    try await albumNameSuggesting.suggestAlbumName(for: input)
}
runningAlbumNameEnhancementRequest = (item, requestTask)
defer { runningAlbumNameEnhancementRequest = nil }
let suggestion = try await requestTask.value
```

在写入 suggestion 前，音乐库手动项必须满足：

```swift
item.source != .libraryManual || activeAlbumNameEnhancementBatchIDs[item.libraryID] == item.batchID
```

否则清除当前专辑临时状态并直接返回。`CancellationError` 路径清除当前专辑临时状态，且不增加该批次的已完成进度。

- [ ] **Step 4: 实现公开停止方法**

新增：

```swift
func stopAlbumNameEnhancement(forLibraryID libraryID: LibraryRecord.ID) {
    guard isAlbumNameEnhancementRunning(for: libraryID) else { return }
    activeAlbumNameEnhancementBatchIDs[libraryID] = nil
    let queuedAlbumIDs = albumNameEnhancementQueue
        .filter { $0.libraryID == libraryID }
        .map(\.albumID)
    albumNameEnhancementQueue.removeAll { $0.libraryID == libraryID }
    for albumID in queuedAlbumIDs {
        albumNameEnhancementStateByAlbumID[albumID] = nil
    }
    if runningAlbumNameEnhancementItem?.libraryID == libraryID {
        runningAlbumNameEnhancementRequest?.task.cancel()
    }
    albumNameEnhancementStatusByLibraryID[libraryID] = AlbumNameEnhancementStatus(
        isRunning: false,
        lastErrorMessage: nil
    )
    rebuildScanDisplayIndex(for: libraryID)
}
```

使内部 `cancelAlbumNameEnhancement(for:clearsSuggestions:)` 同时清理 active batch ID 和匹配的请求句柄，确保重扫、加载快照和移除音乐库不会遗留请求。

- [ ] **Step 5: 运行 AppModel 目标测试并确认 GREEN**

Run:

```bash
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AppModelImportTests
```

Expected: PASS，且没有扫描后自动请求、停止后继续下一张或停止被记录为失败的断言失败。

### Task 3: 加入“停止解析”菜单入口

**Files:**
- Modify: `CoverDrop/Features/LibraryHome/LibraryHomeView.swift`

**Interfaces:**
- Consumes: `AppModel.isAlbumNameEnhancementRunning(for:)`、`AppModel.stopAlbumNameEnhancement(forLibraryID:)`。
- Produces: “停止解析”在“智能解析”正下方，且只在该库运行中可点。

- [ ] **Step 1: 在智能解析按钮下方新增停止按钮**

在现有“智能解析” `Button` 之后加入：

```swift
Button("停止解析") {
    prepareContextSelection(for: library.id)
    appModel.stopAlbumNameEnhancement(forLibraryID: library.id)
}
.disabled(
    !appModel.isAlbumNameEnhancementRunning(for: library.id) ||
    !isSingleAction
)
```

不要复用扫描状态禁用条件：停止解析在解析进行中必须仍可点击。

- [ ] **Step 2: 编译检查**

Run:

```bash
xcodebuild build -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS'
```

Expected: `** BUILD SUCCEEDED **`。

### Task 4: 完整验证与审查

**Files:**
- Verify only.

- [ ] **Step 1: 检查空白与计划完整性**

Run:

```bash
git diff --check
rg -n -i 'T[B]D|TO[D]O|稍后实现' docs/superpowers/plans/2026-07-10-manual-library-enhancement-control.md
```

Expected: `git diff --check` 无输出；`rg` 无匹配。

- [ ] **Step 2: 运行项目完整验证**

Run:

```bash
zsh Scripts/verify.sh
```

Expected: `** TEST SUCCEEDED **` 且命令退出码为 0。

- [ ] **Step 3: 审阅最终差异**

Run:

```bash
git diff -- CoverDrop/App/AppModel.swift CoverDrop/Features/LibraryHome/LibraryHomeView.swift CoverDropTests/Unit/AppModelImportTests.swift docs/superpowers
```

Expected: 只包含顶部总览、手动智能解析、停止控制及其测试/文档。

## Self-Review

- Spec coverage: 无自动解析、手动音乐库入口、仅缺封面、停止按钮状态、当前请求取消、队列清理和已完成结果保留均有任务覆盖。
- Placeholder scan: 无待定标记、待办标记或模糊的后续实现项。
- Type consistency: 所有公开方法、队列字段和测试名在本计划中使用一致；UI 仅依赖 `AppModel` 公开查询/操作方法。
