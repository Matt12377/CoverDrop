# 封面墙交互性能与诊断 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为封面墙到详情、搜索、拖图、保存和返回链路增加受 `COVERDROP_DEBUG_LOG=1` 控制的结构化耗时日志，并消除全墙重复名称计算、无效状态发布和主线程目录 I/O。

**Architecture:** 在 Domain/Diagnostics 中提供无业务依赖的 span 计时器，所有日志继续从命令行输出。`AlbumScanDisplayIndex` 缓存轻量 `AlbumCoverCardPresentation` 和带修订号的快照，SwiftUI 封面网格以修订号实现等价短路；详情状态仍由 `AppModel` 管理，但空取消不再发布变化。目录检查通过 detached task 离开主 actor，关键用户操作在各组件边界建立和结束 span。

**Tech Stack:** Swift 6、SwiftUI、Combine、Swift Testing、Foundation `ContinuousClock`、ImageIO。

## Global Constraints

- 所有界面文案、日志、注释和文档使用中文。
- 诊断日志仅在 `ProcessInfo.processInfo.environment["COVERDROP_DEBUG_LOG"] == "1"` 时输出。
- 日志关闭时不得求值上下文 autoclosure，不创建 UUID，不读取时钟。
- 不替换 ImageIO，不引入第三方依赖，不修改扫描边界、名称规则、快照 schema 或真实音乐文件。
- 拖图仍先暂存，只有用户点击保存才写入 `cover.jpg`；保存失败保留待保存图片。
- 修改生产代码前先写失败测试并确认失败原因。
- 交付前执行 `git diff --check` 和 `zsh Scripts/verify.sh`。

---

### Task 1: 统一的性能 span 与严格环境开关

**Files:**
- Create: `CoverDrop/Domain/Diagnostics/CoverDropPerformanceLog.swift`
- Modify: `CoverDrop/Domain/Diagnostics/CoverDropDebugLog.swift`
- Create: `CoverDropTests/Unit/CoverDropPerformanceLogTests.swift`

**Interfaces:**
- Consumes: `COVERDROP_DEBUG_LOG` 进程环境变量和标准输出。
- Produces: `CoverDropPerformanceLog.begin(_:context:) -> CoverDropPerformanceSpan?`、`CoverDropPerformanceSpan.finish(outcome:context:)`、`CoverDropPerformanceOutcome`。

- [ ] **Step 1: 写环境开关和格式的失败测试**

```swift
import Foundation
import Testing
@testable import CoverDrop

struct CoverDropPerformanceLogTests {
    @Test("只有值为 1 的环境开关才启用性能日志")
    func environmentFlagMustEqualOne() {
        #expect(CoverDropPerformanceLog.isEnabled(environment: [:]) == false)
        #expect(CoverDropPerformanceLog.isEnabled(environment: ["COVERDROP_DEBUG_LOG": "0"]) == false)
        #expect(CoverDropPerformanceLog.isEnabled(environment: ["COVERDROP_DEBUG_LOG": "1"]) == true)
    }

    @Test("性能日志字段顺序稳定且包含两位毫秒")
    func stableLineFormat() {
        let start = CoverDropPerformanceLog.startLine(
            operation: "打开详情",
            spanID: "span-1",
            thread: "main",
            context: ["albumCount": "5000", "albumID": "/Music/A"]
        )
        let end = CoverDropPerformanceLog.endLine(
            operation: "打开详情",
            spanID: "span-1",
            durationMilliseconds: 12.345,
            thread: "main",
            outcome: .success,
            context: ["albumID": "/Music/A"]
        )

        #expect(start == "[性能] 开始 operation=打开详情 span=span-1 thread=main albumCount=5000 albumID=/Music/A")
        #expect(end == "[性能] 结束 operation=打开详情 span=span-1 duration=12.35ms thread=main outcome=success albumID=/Music/A")
    }

    @Test("日志关闭时不求值上下文")
    func disabledLogDoesNotEvaluateContext() {
        var evaluationCount = 0
        let span = CoverDropPerformanceLog.beginForTesting(
            "打开详情",
            enabled: false,
            context: {
                evaluationCount += 1
                return ["albumID": "A"]
            }
        )

        #expect(span == nil)
        #expect(evaluationCount == 0)
    }
}
```

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/CoverDropPerformanceLogTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，错误为 `cannot find 'CoverDropPerformanceLog' in scope`。

- [ ] **Step 3: 实现最小 span、稳定格式和延迟上下文**

新增 `CoverDropPerformanceLog.swift`。实现要求如下，字段值中的换行和空白替换为 `_`，上下文字段按 key 排序：

```swift
import Foundation

enum CoverDropPerformanceOutcome: String, Sendable {
    case success
    case failure
    case cancelled
}

struct CoverDropPerformanceSpan: Sendable {
    let operation: String
    let spanID: String
    let startedAt: ContinuousClock.Instant
    let initialContext: [String: String]

    nonisolated func finish(
        outcome: CoverDropPerformanceOutcome = .success,
        context: @autoclosure () -> [String: String] = [:]
    ) {
        CoverDropPerformanceLog.finish(self, outcome: outcome, context: context())
    }
}

enum CoverDropPerformanceLog {
    nonisolated static func begin(
        _ operation: String,
        context: @autoclosure () -> [String: String] = [:]
    ) -> CoverDropPerformanceSpan? {
        beginForTesting(operation, enabled: isEnabled(environment: ProcessInfo.processInfo.environment), context: context)
    }

    nonisolated static func beginForTesting(
        _ operation: String,
        enabled: Bool,
        context: () -> [String: String]
    ) -> CoverDropPerformanceSpan? {
        guard enabled else { return nil }
        let span = CoverDropPerformanceSpan(
            operation: operation,
            spanID: UUID().uuidString,
            startedAt: .now,
            initialContext: context()
        )
        print(startLine(operation: operation, spanID: span.spanID, thread: threadName, context: span.initialContext))
        return span
    }

    nonisolated static func isEnabled(environment: [String: String]) -> Bool {
        environment["COVERDROP_DEBUG_LOG"] == "1"
    }
}
```

在同一文件实现 `finish`、稳定格式、字段清理和线程名。核心实现固定为：

```swift
nonisolated static func finish(
    _ span: CoverDropPerformanceSpan,
    outcome: CoverDropPerformanceOutcome,
    context: [String: String]
) {
    let duration = span.startedAt.duration(to: .now)
    let components = duration.components
    let milliseconds = Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
    print(endLine(
        operation: span.operation,
        spanID: span.spanID,
        durationMilliseconds: milliseconds,
        thread: threadName,
        outcome: outcome,
        context: span.initialContext.merging(context) { _, new in new }
    ))
}

nonisolated static var threadName: String {
    Thread.isMainThread ? "main" : "background"
}

nonisolated static func sanitized(_ value: String) -> String {
    value
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: "_")
}

nonisolated static func contextSuffix(_ context: [String: String]) -> String {
    context.keys.sorted().map { "\($0)=\(sanitized(context[$0] ?? ""))" }.joined(separator: " ")
}
```

`startLine` 和 `endLine` 使用测试中给出的精确前缀与字段顺序，把 `contextSuffix` 非空时追加在末尾。结束毫秒使用 `String(format: "%.2f", durationMilliseconds)`。`finish` 只会收到已启用时创建的 span，因此不会在关闭路径采集任何数据。

同时把 `CoverDropDebugLog.write` 改为先判断开关再求值消息，并删除 `shouldAlwaysPrint`：

```swift
enum CoverDropDebugLog {
    nonisolated static func write(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["COVERDROP_DEBUG_LOG"] == "1" else { return }
        print("[CoverDrop] \(message())")
    }
}
```

- [ ] **Step 4: 运行测试并确认 GREEN**

Run: Task 1 Step 2 的同一命令。

Expected: PASS，且测试输出中没有未开启环境开关时产生的 `[性能]` 行。

- [ ] **Step 5: 提交 Task 1**

```shell
git add CoverDrop/Domain/Diagnostics/CoverDropPerformanceLog.swift CoverDrop/Domain/Diagnostics/CoverDropDebugLog.swift CoverDropTests/Unit/CoverDropPerformanceLogTests.swift
git commit -m "feat: 添加命令行性能耗时日志"
```

---

### Task 2: 缓存封面卡片派生数据

**Files:**
- Create: `CoverDrop/Domain/Models/AlbumCoverCardPresentation.swift`
- Modify: `CoverDrop/Domain/Policies/AlbumScanDisplayIndex.swift`
- Modify: `CoverDrop/App/AppModel.swift`
- Modify: `CoverDropTests/Unit/AlbumScanDisplayIndexTests.swift`
- Modify: `CoverDropTests/Unit/AppModelImportTests.swift`

**Interfaces:**
- Consumes: `AlbumScanRecord`、现有 `displayNames` 闭包、筛选和搜索索引。
- Produces: `AlbumCoverCardPresentation`、`AlbumCoverWallSnapshot`、`AlbumScanDisplayIndex.coverWallSnapshot(filter:query:)`、`AppModel.coverWallSnapshotInSelectedLibrary(filter:query:)`。

- [ ] **Step 1: 写展示名只计算一次及局部更新的失败测试**

在 `AlbumScanDisplayIndexTests` 新增：

```swift
@Test("卡片快照复用预计算展示名且单张替换只重算该专辑")
func coverWallSnapshotCachesDerivedNames() {
    let first = makeAlbum(index: 1, hasCover: false, issues: [])
    let second = makeAlbum(index: 2, hasCover: true, issues: [])
    var calls: [AlbumScanRecord.ID: Int] = [:]
    let names: (AlbumScanRecord) -> (artistName: String, albumName: String) = { album in
        calls[album.id, default: 0] += 1
        return ("展示-\(album.artistName)", "展示-\(album.albumName)")
    }
    let index = AlbumScanDisplayIndex(
        result: LibraryScanResult(albums: [first, second], looseAudioPaths: []),
        displayNames: names
    )

    let initial = index.coverWallSnapshot(filter: .all, query: "")
    let repeated = index.coverWallSnapshot(filter: .all, query: "")
    #expect(initial.revision == repeated.revision)
    #expect(initial.cards.map(\.displayAlbumName) == ["展示-专辑 1", "展示-专辑 2"])
    #expect(calls[first.id] == 1)
    #expect(calls[second.id] == 1)

    let updatedFirst = makeAlbum(index: 1, hasCover: true, issues: [])
    _ = index.replacingAlbums([updatedFirst], displayNames: names)
    let updated = index.coverWallSnapshot(filter: .all, query: "")

    #expect(updated.revision != initial.revision)
    #expect(calls[first.id] == 2)
    #expect(calls[second.id] == 1)
}

@Test("五千张专辑重复取得相同卡片快照不重复计算派生名称")
func fiveThousandAlbumSnapshotDoesNotRecomputeNames() {
    let albums = (0..<5_000).map { makeAlbum(index: $0, hasCover: false, issues: []) }
    var callCount = 0
    let index = AlbumScanDisplayIndex(
        result: LibraryScanResult(albums: albums, looseAudioPaths: []),
        displayNames: { album in
            callCount += 1
            return (album.artistName, album.albumName)
        }
    )
    _ = index.coverWallSnapshot(filter: .all, query: "")
    _ = index.coverWallSnapshot(filter: .all, query: "")
    #expect(callCount == 5_000)
}
```

- [ ] **Step 2: 运行索引测试并确认 RED**

Run:

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AlbumScanDisplayIndexTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，错误为不存在 `coverWallSnapshot`、`AlbumCoverCardPresentation` 或 `AlbumCoverWallSnapshot`。

- [ ] **Step 3: 实现轻量展示模型和索引缓存**

新增：

```swift
import Foundation

struct AlbumCoverCardPresentation: Identifiable, Equatable, Sendable {
    let id: AlbumScanRecord.ID
    let folderPath: String
    let displayArtistName: String
    let displayAlbumName: String
    let formatTags: [String]
    let coverURL: URL?
    let coverSourceName: String?
    let issueHelp: String?
    let canSplitWithXLD: Bool
    let hasEnhancedName: Bool
    let enhancementErrorMessage: String?
}

struct AlbumCoverWallSnapshot: Equatable, Sendable {
    let revision: UInt64
    let filter: AlbumScanResultFilter
    let normalizedQuery: String
    let cards: [AlbumCoverCardPresentation]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
            && lhs.filter == rhs.filter
            && lhs.normalizedQuery == rhs.normalizedQuery
    }
}
```

在 `AlbumScanDisplayIndex` 中保存 `presentationsByID`、`revision` 和 `makePresentation: (AlbumScanRecord) -> AlbumCoverCardPresentation`。初始化时由 `AppModel.rebuildScanDisplayIndex` 传入工厂；工厂内部调用一次 `displayNames(for:in:)`，同时读取该 albumID 的名称增强建议/错误，构造完整展示模型。保存成功提示不进入展示模型，仍由 `coverWriteMessagesByAlbumID` 在网格 render key 中单独携带。

`replacingAlbums` 和 `updatingNameEnhancement` 只对目标 ID 再调用一次 `makePresentation` 并递增 revision。`coverWallSnapshot` 先复用既有筛选/搜索得到的 album ID 顺序，再从 `presentationsByID` 映射轻量卡片。使用 Task 1 的性能 span 记录 `构建封面墙展示数据`，上下文包含 `albumCount` 和 `mode=initial|incremental|read`。卡片不得再次读取整个 `AppModel`。

- [ ] **Step 4: 在 AppModel 暴露卡片快照并补充失败测试**

先在 `AppModelImportTests` 写出调用：

```swift
let snapshot = appModel.coverWallSnapshotInSelectedLibrary(filter: .all, query: "")
#expect(snapshot.cards.count == albums.count)
#expect(snapshot.cards.last?.id == albums.last?.id)
```

运行该单测确认因方法不存在而失败，再实现：

```swift
func coverWallSnapshotInSelectedLibrary(
    filter: AlbumScanResultFilter,
    query: String
) -> AlbumCoverWallSnapshot {
    guard let selectedLibraryID,
          let index = scanDisplayIndexesByLibraryID[selectedLibraryID] else {
        return AlbumCoverWallSnapshot(revision: 0, filter: filter, normalizedQuery: query, cards: [])
    }
    return index.coverWallSnapshot(filter: filter, query: query)
}
```

- [ ] **Step 5: 运行相关测试并确认 GREEN**

Run:

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AlbumScanDisplayIndexTests -only-testing:CoverDropTests/AppModelImportTests/indexedPublicReadsStayUnderInteractionBudgetForLargeLibrary CODE_SIGNING_ALLOWED=NO
```

Expected: PASS；5,000 张用例的名称闭包调用次数严格为 5,000。

- [ ] **Step 6: 提交 Task 2**

```shell
git add CoverDrop/Domain/Models/AlbumCoverCardPresentation.swift CoverDrop/Domain/Policies/AlbumScanDisplayIndex.swift CoverDrop/App/AppModel.swift CoverDropTests/Unit/AlbumScanDisplayIndexTests.swift CoverDropTests/Unit/AppModelImportTests.swift
git commit -m "perf: 缓存封面卡片展示数据"
```

---

### Task 3: 隔离封面网格并消除无效发布

**Files:**
- Modify: `CoverDrop/Domain/Models/AlbumCoverCardPresentation.swift`
- Modify: `CoverDrop/App/AppModel.swift`
- Modify: `CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift`
- Modify: `CoverDropTests/Unit/AppModelImportTests.swift`
- Create: `CoverDropTests/Unit/AlbumCoverWallSnapshotTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `AlbumCoverWallSnapshot`。
- Produces: `AlbumCoverWallRenderKey`、`EquatableAlbumCoverGrid`；无暂存项时 `cancelPendingCoverImage` 不发布 `objectWillChange`。

- [ ] **Step 1: 写空取消不发布状态的失败测试**

在 `AppModelImportTests` 新增并引入 Combine：

```swift
@Test("没有暂存封面时取消操作不发布 AppModel 变化")
func cancellingMissingPendingCoverDoesNotPublish() async {
    let album = performanceAlbum(index: 1, hasCover: false)
    let appModel = await makeScannedAppModel(
        root: URL(fileURLWithPath: "/tmp/library", isDirectory: true),
        albums: [album]
    )
    var emissionCount = 0
    let cancellable = appModel.objectWillChange.sink { emissionCount += 1 }

    appModel.cancelPendingCoverImage(forAlbumID: album.id)

    #expect(emissionCount == 0)
    withExtendedLifetime(cancellable) {}
}
```

- [ ] **Step 2: 运行单测并确认 RED**

Run:

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AppModelImportTests/cancellingMissingPendingCoverDoesNotPublish CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，`emissionCount` 为 1。

- [ ] **Step 3: 实现空取消短路并去除打开详情时的无意义取消**

```swift
func cancelPendingCoverImage(forAlbumID albumID: AlbumScanRecord.ID) {
    guard pendingCoverURLsByAlbumID[albumID] != nil else { return }
    pendingCoverURLsByAlbumID[albumID] = nil
}
```

`openAlbumDetail(albumID:pendingCoverURL:)` 只有 `pendingCoverURL` 非空时才调用 `stageCoverImage`，否则不触碰 AppModel。`closeAlbumDetail` 只调用一次清理；删除 `.onChange(of: isShowingAlbumDetail)` 中的重复清理路径，保留专辑消失时的明确清理。

- [ ] **Step 4: 写网格 render key 测试并确认 RED**

新增 `AlbumCoverWallSnapshotTests`，先引用尚不存在的 `AlbumCoverWallRenderKey`：

```swift
import Testing
@testable import CoverDrop

struct AlbumCoverWallSnapshotTests {
    @Test("详情状态不进入封面网格等价键")
    func renderIdentityUsesRevisionFilterAndQuery() {
        let first = AlbumCoverWallRenderKey(
            revision: 7,
            filter: .all,
            normalizedQuery: "",
            selectedAlbumIDs: [],
            coverWriteMessages: [:]
        )
        let same = first
        let changed = AlbumCoverWallRenderKey(
            revision: 8,
            filter: .all,
            normalizedQuery: "",
            selectedAlbumIDs: [],
            coverWriteMessages: [:]
        )
        #expect(first == same)
        #expect(first != changed)
    }
}
```

运行定向测试，Expected: FAIL，错误为不存在 `AlbumCoverWallRenderKey`。随后在 `AlbumCoverCardPresentation.swift` 新增 Equatable/Sendable 类型，字段严格为 revision、filter、normalizedQuery、selectedAlbumIDs 和 coverWriteMessages；不包含 selectedAlbumID、pendingCoverURL、保存中状态、Finder 状态或搜索状态。再增加断言验证选择集合或保存消息变化时 key 不等。

- [ ] **Step 5: 抽出 Equatable 网格并改用轻量卡片**

在 `LibraryScanSummaryView.swift` 内新增 `EquatableAlbumCoverGrid: View, Equatable`。它保存 `AlbumCoverWallSnapshot`、`AlbumCoverWallRenderKey`、列数/间距和动作闭包；`==` 只比较 render key、列数和间距，不比较闭包或 cards 数组。

`LibraryScanSummaryView.body` 改为取得一次：

```swift
let coverWallSnapshot = appModel.coverWallSnapshotInSelectedLibrary(
    filter: filter,
    query: debouncedQuery
)
```

网格 `ForEach(snapshot.cards)`，`AlbumCoverCard` 改收 `AlbumCoverCardPresentation`，不再调用 `displayAlbumName`、`displayArtistName`、`formatTags` 或读取完整专辑数组。`.equatable()` 包裹网格，使待保存 URL、搜索状态、Finder 状态等未改变 snapshot revision 的发布不会重建卡片树。

把 `.onChange(of: result.albums.map(\.id))` 替换为轻量的扫描结果修订号或 `Set`/revision，由索引在真实专辑集合变化时递增；不得在每次 body 求值映射全库 ID。

在 `openAlbumDetail` 开始 `打开详情` span，传入详情 overlay；`AlbumDetailSheet.onAppear` 回调结束 span。关闭时开始 `返回封面墙` span，在关闭状态提交后的下一次主队列迭代结束，记录当前 snapshot revision。

- [ ] **Step 6: 运行相关测试并确认 GREEN**

Run:

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AppModelImportTests/cancellingMissingPendingCoverDoesNotPublish -only-testing:CoverDropTests/AlbumCoverWallSnapshotTests -only-testing:CoverDropTests/FixedCoverGridLayoutTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS。

- [ ] **Step 7: 提交 Task 3**

```shell
git add CoverDrop/App/AppModel.swift CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift CoverDropTests/Unit/AppModelImportTests.swift CoverDropTests/Unit/AlbumCoverWallSnapshotTests.swift
git commit -m "perf: 隔离详情状态与封面网格"
```

---

### Task 4: 将目录存在性检查移出主线程

**Files:**
- Modify: `CoverDrop/App/AppModel.swift`
- Modify: `CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift`
- Modify: `CoverDropTests/Unit/AppModelImportTests.swift`

**Interfaces:**
- Consumes: 专辑 folder URL。
- Produces: `AppModel.albumFolderExistsOffMainActor(_:) async -> Bool`、异步 `removeAlbumIfFolderMissing(albumID:) async -> Bool`。

- [ ] **Step 1: 写后台执行和目录移除行为的失败测试**

在 `AppModelImportTests` 增加一个测试探针闭包版本：

```swift
@Test("专辑目录检查离开主线程执行")
func albumFolderCheckRunsOffMainThread() async {
    let wasOnMain = await AppModel.runAlbumFolderCheckOffMainActor {
        Thread.isMainThread
    }
    #expect(wasOnMain == false)
}
```

并把现有 `removeAlbumIfFolderMissing` 测试调用改为 `await`，保持其目录存在、目录消失和专辑记录更新断言不变。

- [ ] **Step 2: 运行相关测试并确认 RED**

Run:

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AppModelImportTests/albumFolderCheckRunsOffMainThread CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，错误为不存在 `runAlbumFolderCheckOffMainActor`。

- [ ] **Step 3: 实现 detached 目录检查并接入详情和保存**

```swift
nonisolated static func runAlbumFolderCheckOffMainActor<T: Sendable>(
    _ check: @escaping @Sendable () -> T
) async -> T {
    await Task.detached(priority: .utility, operation: check).value
}

nonisolated static func albumFolderExistsOffMainActor(_ folderURL: URL) async -> Bool {
    await runAlbumFolderCheckOffMainActor {
        albumFolderExists(folderURL)
    }
}
```

`removeAlbumIfFolderMissing` 改为 async，在等待期间不改变 UI，回到 MainActor 后再次确认选中库和专辑仍匹配再移除。详情轮询使用一个顺序 task，同一检查结束前不会启动下一次。保存前的 `guard Self.albumFolderExists` 改为 `guard await Self.albumFolderExistsOffMainActor`。

用 `检查专辑目录` span 包裹检查，context 包含 albumID；错误或目录不存在记录 `failure`，存在记录 `success`。

- [ ] **Step 4: 运行相关测试并确认 GREEN**

Run:

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AppModelImportTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS，包括原有三组专辑目录移除测试和新增线程测试。

- [ ] **Step 5: 提交 Task 4**

```shell
git add CoverDrop/App/AppModel.swift CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift CoverDropTests/Unit/AppModelImportTests.swift
git commit -m "perf: 后台检查专辑目录状态"
```

---

### Task 5: 补齐搜索、拖图、缩略图和保存链路耗时日志

**Files:**
- Modify: `CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift`
- Modify: `CoverDrop/App/AppModel.swift`
- Modify: `CoverDrop/Infrastructure/Images/CoverPreviewCache.swift`
- Modify: `CoverDrop/Infrastructure/Images/CoverImageStagingCache.swift`
- Modify: `CoverDrop/Infrastructure/Images/ImageIOCoverImageWriter.swift`
- Modify: `CoverDropTests/Unit/CoverDropPerformanceLogTests.swift`
- Modify: `CoverDropTests/Unit/CoverPreviewCacheTests.swift`
- Modify: `CoverDropTests/Unit/CoverImageStagingCacheTests.swift`

**Interfaces:**
- Consumes: Task 1 span API。
- Produces: 全链路稳定 operation 名称及慢缩略图汇总。

- [ ] **Step 1: 写慢操作阈值和失败 outcome 的失败测试**

在 `CoverDropPerformanceLogTests` 新增：

```swift
@Test("缩略图只有达到一百毫秒或失败时才记录")
func thumbnailThreshold() {
    #expect(CoverDropPerformanceLog.shouldReportThumbnail(durationMilliseconds: 99.99, didFail: false) == false)
    #expect(CoverDropPerformanceLog.shouldReportThumbnail(durationMilliseconds: 100, didFail: false) == true)
    #expect(CoverDropPerformanceLog.shouldReportThumbnail(durationMilliseconds: 1, didFail: true) == true)
}
```

增加以下纯格式断言，验证错误摘要中的换行被清理，`outcome=failure` 保留：

```swift
let line = CoverDropPerformanceLog.endLine(
    operation: "保存封面图片",
    spanID: "span-2",
    durationMilliseconds: 5,
    thread: "background",
    outcome: .failure,
    context: ["error": "第一行\n第二行"]
)
#expect(line.contains("outcome=failure"))
#expect(line.contains("error=第一行_第二行"))
```

- [ ] **Step 2: 运行测试并确认 RED**

Run: Task 1 的定向测试命令。

Expected: FAIL，错误为不存在 `shouldReportThumbnail`。

- [ ] **Step 3: 实现阈值并在各边界增加 span**

固定 operation 名称如下，不得在调用点另造近义名称：

```swift
enum CoverDropPerformanceOperation {
    static let buildCoverWall = "构建封面墙展示数据"
    static let openAlbumDetail = "打开详情"
    static let returnToCoverWall = "返回封面墙"
    static let loadCoverThumbnail = "加载封面缩略图"
    static let openAggregateSearch = "打开聚合搜索"
    static let aggregateSearchRequest = "聚合搜索请求"
    static let readDroppedImage = "读取拖入图片"
    static let stageCoverImage = "暂存封面图片"
    static let saveCoverImage = "保存封面图片"
    static let updateAlbumCover = "更新专辑封面记录"
    static let checkAlbumFolder = "检查专辑目录"
}
```

接入边界：

- `CoverSearchSheet.loadAggregateSearchResultsIfNeeded`：请求前 begin，成功、失败、取消分别 finish。
- `CoverDropReceiver`：从 provider load 开始到取得 URL/Data 为 `读取拖入图片`。
- `CoverImageStagingCache.stageRemoteImage` 和 `stageImageData`：下载、验证、落盘整体为 `暂存封面图片`。
- `ImageIOCoverImageWriter.writeCoverImage`：图片解码、JPEG 编码和原子替换整体为 `保存封面图片`。
- `AppModel.replaceAlbumCover`：数组/索引局部更新为 `更新专辑封面记录`。
- `CoverPreviewCache.cachedImage`：在调试开关开启时先采集时钟，但延迟输出；结束后仅当 `>= 100ms` 或返回 nil，调用 `CoverDropPerformanceLog.reportCompletedPair(...)` 连续打印配对的开始/结束行。context 包含 `maxPixelSize`、`cache=hit|miss`，路径只输出 lastPathComponent。该 API 接收 operation、duration、outcome 和 autoclosure context；日志关闭时不求值 context。

所有 catch 路径必须先 `finish(outcome: .failure, context: ["error": sanitized])` 再透传或设置现有错误。所有 `Task.isCancelled` 返回前记录 `.cancelled`。不得改变现有错误文案或业务返回值。

- [ ] **Step 4: 运行图片、拖图、搜索和保存相关测试并确认 GREEN**

Run:

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' \
  -only-testing:CoverDropTests/CoverDropPerformanceLogTests \
  -only-testing:CoverDropTests/CoverPreviewCacheTests \
  -only-testing:CoverDropTests/CoverImageStagingCacheTests \
  -only-testing:CoverDropTests/CoverDropReceiverTests \
  -only-testing:CoverDropTests/AppModelImportTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS，且未设置环境变量时测试日志没有 `[性能]` 或此前无条件输出的拖图/保存调试行。

- [ ] **Step 5: 使用环境开关手工核对命令行日志**

Run:

```shell
COVERDROP_DEBUG_LOG=1 open <构建出的 CoverDrop.app>
```

依次执行打开详情、打开聚合搜索、拖入封面、保存并返回。Expected: 每个 `开始` 都有相同 span 的 `结束`；结束行包含两位毫秒、thread 和 outcome；封面墙缩略图成功且低于 100ms 时不逐张输出。

- [ ] **Step 6: 提交 Task 5**

```shell
git add CoverDrop/Domain/Diagnostics/CoverDropPerformanceLog.swift CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift CoverDrop/App/AppModel.swift CoverDrop/Infrastructure/Images/CoverPreviewCache.swift CoverDrop/Infrastructure/Images/CoverImageStagingCache.swift CoverDrop/Infrastructure/Images/ImageIOCoverImageWriter.swift CoverDropTests/Unit/CoverDropPerformanceLogTests.swift CoverDropTests/Unit/CoverPreviewCacheTests.swift CoverDropTests/Unit/CoverImageStagingCacheTests.swift
git commit -m "feat: 记录封面处理全链路耗时"
```

---

### Task 6: 全量验证和接手文档

**Files:**
- Modify after user acceptance: `AGENTS.md`

**Interfaces:**
- Consumes: Tasks 1–5 的全部实现。
- Produces: 可交付验证结果；仅在用户确认代码达到要求后更新 `AGENTS.md`。

- [ ] **Step 1: 检查工作区和格式错误**

```shell
git status --short
git diff --check
```

Expected: 只有本任务相关文件，`git diff --check` 无输出。

- [ ] **Step 2: 运行项目完整验证**

```shell
zsh Scripts/verify.sh
```

Expected: `xcodebuild clean test` 成功，所有 Swift Testing 用例通过。

- [ ] **Step 3: 检查关闭日志时无无条件输出**

```shell
rg -n "print\(|shouldAlwaysPrint|COVERDROP_DEBUG_LOG" CoverDrop
```

Expected: 业务调用点不直接 `print`；环境变量只由诊断组件读取；不存在 `shouldAlwaysPrint`。

- [ ] **Step 4: 向用户交付并等待体验确认**

交付说明包含：根因、具体改动、测试结果、启动命令和一段示例日志。请用户用真实音乐库完成一次完整链路并提供最慢的 span 行。

- [ ] **Step 5: 用户确认达到要求后更新 AGENTS.md**

在“当前行为/封面与搜索”补充：封面墙使用预计算轻量卡片快照，详情状态不会重建整墙；`COVERDROP_DEBUG_LOG=1` 输出结构化性能 span；目录检查不在主线程。仅文档变更时再次运行 `git diff --check`。

- [ ] **Step 6: 提交接手文档（仅用户确认后）**

```shell
git add AGENTS.md
git commit -m "docs: 记录封面墙性能诊断机制"
```
