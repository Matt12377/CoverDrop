# 专辑墙与封面工作流性能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消除约 5,000 张专辑时封面墙滚动、详情进出、聚合搜索、拖图和保存链路中的可感知主线程卡顿，并提供可从终端实时读取的分段耗时证据。

**Architecture:** 保留现有 SwiftUI 外观和 `LazyVGrid`，把卡片所需数据预计算为带修订号的不可变快照，并用等价子树隔离详情专属状态。搜索改为同一工作流容器内联切换，避免系统 sheet 动画停顿。图片工作通过受限并发、相同请求合并和明确 detached 边界离开主 actor；保存成功只发布一次专辑记录更新，SQLite 快照走单专辑增量更新，其他 store 通过每库串行 FIFO 队列顺序执行全量回退。

**Tech Stack:** Swift 6、SwiftUI、Combine、Foundation、AppKit、ImageIO、SQLite3、Swift Testing、`ContinuousClock`。

## Global Constraints

- 所有项目沟通、代码注释、日志、文档和界面文案使用中文。
- Swift 6，macOS deployment target 为 `26.4`，默认 actor isolation 为 `MainActor`，并启用 approachable concurrency。
- 不修改扫描边界、真实音乐文件、音频标签、Ollama 决策或 `ScanSnapshot.currentSchemaVersion == 2`。
- 拖图仍先暂存；只有用户点击保存才写入 `cover.jpg`；保存失败必须保留待保存图片。
- Features 不新建 TagLib、ImageIO、SQLite 等具体实现；真实写入继续通过既有协议和 `AppEnvironment` 装配。
- 本轮不全面重写 `LibraryScanSummaryView.swift`，不直接替换为 `NSCollectionView`。
- `COVERDROP_DEBUG_LOG=1` 才启用结构化性能日志；关闭时不得创建 span ID、读取计时器或求值日志上下文。
- 本地缩略图峰值并发固定为 4，远程预览峰值并发固定为 6；值通过 `AppConfiguration.CoverImages` 统一提供。
- 修改生产代码前必须先写失败测试并观察到符合预期的 RED。
- 每个任务完成后运行其定向测试；交付前运行 `git diff --check` 和 `zsh Scripts/verify.sh`。

---

## 文件结构

- Create `CoverDrop/Domain/Diagnostics/CoverDropPerformanceLog.swift`：低开销 span、稳定日志格式和主线程响应延迟监视器。
- Create `CoverDrop/Domain/Models/AlbumCoverCardPresentation.swift`：轻量卡片展示数据、墙体快照和网格等价键。
- Create `CoverDrop/Domain/Models/AlbumCoverWorkflowPresentationState.swift`：详情/搜索内联目的地、容器尺寸和详情 drop zone 策略。
- Modify `CoverDrop/Domain/Policies/AlbumScanDisplayIndex.swift`：预计算 presentation、按修订号缓存墙体快照、局部更新。
- Create `CoverDrop/Infrastructure/Images/CoverThumbnailLoader.swift`：本地缩略图受限并发、请求合并和取消。
- Modify `CoverDrop/Infrastructure/Images/RemoteCoverImageDataCache.swift`：远程数据 TTL/容量缓存、并发限制和任务合并。
- Modify `CoverDrop/Infrastructure/Images/RemoteCoverPreviewLoader.swift`：先查已解码缓存，ImageIO 下采样，明确后台解码。
- Modify `CoverDrop/Infrastructure/Images/CoverImageStagingCache.swift`：远程校验和暂存落盘明确离开主 actor。
- Modify `CoverDrop/Domain/Protocols/ScanSnapshotStoring.swift`：定义可选单专辑封面增量更新能力。
- Create `CoverDrop/Infrastructure/Persistence/ScanSnapshotUpdateQueue.swift`：同一音乐库串行、FIFO 保留全部更新的快照写队列。
- Modify `CoverDrop/Infrastructure/Persistence/SQLiteScanSnapshotStore.swift`：串行 SQLite 写入和单行封面更新。
- Modify `CoverDrop/App/AppModel.swift`：轻量墙体快照入口、后台目录检查、一次封面记录更新和快照调度。
- Modify `CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift`：等价网格、保留 drop pending、结构化交互 span。

---

### Task 1: 统一性能 span 与主线程响应延迟监视

**Files:**
- Create: `CoverDrop/Domain/Diagnostics/CoverDropPerformanceLog.swift`
- Modify: `CoverDrop/Domain/Diagnostics/CoverDropDebugLog.swift`
- Modify: `CoverDrop/App/CoverDropApp.swift`
- Test: `CoverDropTests/Unit/CoverDropPerformanceLogTests.swift`

**Interfaces:**
- Produces: `CoverDropPerformanceLog.begin(_:context:) -> CoverDropPerformanceSpan?`。
- Produces: `CoverDropPerformanceSpan.finish(outcome:context:)`。
- Produces: `CoverDropPerformanceLog.makeMainThreadStallMonitor(thresholdMilliseconds:) -> Task<Void, Never>?`。

- [ ] **Step 1: 写环境开关、稳定格式和延迟上下文的失败测试**

```swift
@Test("只有值为 1 的环境变量启用性能日志")
func flagMustEqualOne() {
    #expect(CoverDropPerformanceLog.isEnabled(environment: [:]) == false)
    #expect(CoverDropPerformanceLog.isEnabled(environment: ["COVERDROP_DEBUG_LOG": "0"]) == false)
    #expect(CoverDropPerformanceLog.isEnabled(environment: ["COVERDROP_DEBUG_LOG": "1"]) == true)
}

@Test("性能日志字段顺序稳定并保留两位毫秒")
func stableFormat() {
    #expect(CoverDropPerformanceLog.endLine(
        operation: "打开详情",
        spanID: "span-1",
        durationMilliseconds: 12.345,
        thread: "main",
        outcome: .success,
        context: ["albumID": "/Music/A"]
    ) == "[性能] 结束 operation=打开详情 span=span-1 duration=12.35ms thread=main outcome=success albumID=/Music/A")
}

@Test("关闭日志时不求值上下文")
func disabledDoesNotEvaluateContext() {
    var evaluations = 0
    let span = CoverDropPerformanceLog.beginForTesting("打开详情", enabled: false) {
        evaluations += 1
        return ["albumID": "A"]
    }
    #expect(span == nil)
    #expect(evaluations == 0)
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run:

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/CoverDropPerformanceLogTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，错误为不存在 `CoverDropPerformanceLog`。

- [ ] **Step 3: 实现 span、稳定 operation 名称和调试监视器**

实现 `CoverDropPerformanceOutcome` 的 `success/failure/cancelled`；字段值中的空白和换行统一替换为 `_`，上下文按 key 排序。`begin` 必须先 guard 开关，再创建 UUID、读取 `ContinuousClock` 和求值 autoclosure。固定 operation 名称：

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
    static let updateScanSnapshot = "更新扫描快照"
    static let checkAlbumFolder = "检查专辑目录"
    static let mainThreadStall = "主线程响应延迟"
}
```

主线程监视器从 detached task 每 250ms 请求一次空的 `MainActor.run`；只在等待时间 `>= 50ms` 时输出一次完成日志。`CoverDropApp` 保存监视任务并在生命周期结束时取消。`CoverDropDebugLog.write` 改为先判断同一开关再求值消息，删除 `shouldAlwaysPrint`。

- [ ] **Step 4: 运行测试确认 GREEN**

Run: Step 2 命令。Expected: PASS，未开启开关时没有 `[性能]` 输出。

---

### Task 2: 预计算卡片 presentation 并缓存 O(1) 墙体快照

**Files:**
- Create: `CoverDrop/Domain/Models/AlbumCoverCardPresentation.swift`
- Modify: `CoverDrop/Domain/Policies/AlbumScanDisplayIndex.swift`
- Modify: `CoverDrop/App/AppModel.swift`
- Test: `CoverDropTests/Unit/AlbumScanDisplayIndexTests.swift`
- Test: `CoverDropTests/Unit/AppModelImportTests.swift`

**Interfaces:**
- Produces: `AlbumCoverCardPresentation`、`AlbumCoverWallSnapshot`、`AlbumCoverWallRenderKey`。
- Produces: `AlbumScanDisplayIndex.coverWallSnapshot(filter:query:)`。
- Produces: `AppModel.coverWallSnapshotInSelectedLibrary(filter:query:)`。

- [ ] **Step 1: 写 5,000 张专辑计算次数和存储复用的失败测试**

```swift
@Test("五千张专辑只计算一次卡片展示数据并复用快照存储")
func coverWallSnapshotCachesPresentations() {
    let albums = (0..<5_000).map { makeAlbum(index: $0, hasCover: false, issues: []) }
    var calls = 0
    let index = AlbumScanDisplayIndex(
        result: LibraryScanResult(albums: albums, looseAudioPaths: []),
        makePresentation: { album, revision in
            calls += 1
            return AlbumCoverCardPresentation.testing(album: album, contentRevision: revision)
        }
    )

    let first = index.coverWallSnapshot(filter: .all, query: "")
    let second = index.coverWallSnapshot(filter: .all, query: "")

    #expect(calls == 5_000)
    #expect(first.storageIdentity == second.storageIdentity)
}

@Test("替换两张专辑只重算两个 presentation")
func replacementIsTargeted() {
    let first = makeAlbum(index: 1, hasCover: false, issues: [])
    let second = makeAlbum(index: 2, hasCover: false, issues: [])
    let third = makeAlbum(index: 3, hasCover: false, issues: [])
    var calls: [AlbumScanRecord.ID: Int] = [:]
    let index = AlbumScanDisplayIndex(
        result: LibraryScanResult(albums: [first, second, third], looseAudioPaths: []),
        makePresentation: { album, revision in
            calls[album.id, default: 0] += 1
            return AlbumCoverCardPresentation.testing(album: album, contentRevision: revision)
        }
    )
    let initial = index.coverWallSnapshot(filter: .all, query: "")
    let thirdRevision = initial.cards.first { $0.id == third.id }?.contentRevision

    let updatedFirst = makeAlbum(index: 1, hasCover: true, issues: [])
    let updatedSecond = makeAlbum(index: 2, hasCover: true, issues: [])
    _ = index.replacingAlbums([updatedFirst, updatedSecond])
    let updated = index.coverWallSnapshot(filter: .all, query: "")

    #expect(calls[first.id] == 2)
    #expect(calls[second.id] == 2)
    #expect(calls[third.id] == 1)
    #expect(updated.cards.first { $0.id == third.id }?.contentRevision == thirdRevision)
}
```

- [ ] **Step 2: 运行索引测试确认 RED**

Run:

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AlbumScanDisplayIndexTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，错误为不存在 presentation 或 `coverWallSnapshot`。

- [ ] **Step 3: 实现轻量模型、修订号和快照缓存**

`AlbumCoverCardPresentation` 固定包含：`id`、`folderURL`、展示歌手/专辑名、最多两个格式标签、`coverURL`、单专辑 `contentRevision`、封面来源名称、`needsAttention`、问题帮助文本、`canSplitWithXLD`、名称增强标记和错误文本。不得保存全部 `audioFiles`。

`AlbumCoverWallSnapshot` 使用私有引用存储包装 `[AlbumCoverCardPresentation]`，测试只读暴露 `storageIdentity`；其 `Equatable` 只比较 `revision/filter/normalizedQuery`。索引以 `(revision, filter, normalizedQuery)` 为 key 缓存快照；相同 key 直接返回已有存储。真实专辑或建议变化时只重建目标 presentation、递增 revision 并清空旧快照缓存。

现有 `replacingAlbums` 批量更新时，每个筛选桶只取出、修改、写回一次，禁止对每张专辑重复触发数组 COW。

- [ ] **Step 4: 写 AppModel 入口测试，确认 RED 后实现 presentation 工厂**

测试 `coverWallSnapshotInSelectedLibrary(filter:query:)` 返回正确数量和顺序。工厂内部只调用一次 `displayNames(for:in:)`，并读取该 ID 的名称增强状态；`formatTags` 在这里计算，卡片 body 不再扫描音轨。

- [ ] **Step 5: 运行索引与 AppModel 定向测试确认 GREEN**

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AlbumScanDisplayIndexTests -only-testing:CoverDropTests/AppModelImportTests/indexedPublicReadsStayUnderInteractionBudgetForLargeLibrary CODE_SIGNING_ALLOWED=NO
```

Expected: PASS；初始化 5,000 次，重复读取增加 0 次，替换 k 张增加 k 次。

---

### Task 3: 隔离封面网格并修复详情/drop 状态传播

**Files:**
- Modify: `CoverDrop/Domain/Models/AlbumCoverCardPresentation.swift`
- Create: `CoverDrop/Domain/Models/AlbumCoverWorkflowPresentationState.swift`
- Modify: `CoverDrop/App/AppModel.swift`
- Modify: `CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift`
- Create: `CoverDropTests/Unit/AlbumCoverWallSnapshotTests.swift`
- Modify: `CoverDropTests/Unit/AppModelImportTests.swift`

**Interfaces:**
- Produces: `EquatableAlbumCoverGrid`，输入只有墙体快照、布局、轻量动态状态和动作闭包。
- Produces: `AlbumCoverWallRenderKey`，不包含 pending、保存中、Finder 或搜索页状态。
- Produces: `AlbumCoverWorkflowPresentationState`，详情使用 `680 × 520`，搜索使用 `1100 × 700`，仅详情目的地启用外层 drop zone。
- Changes: `openAlbumDetail` 在 `pendingCoverURL == nil` 时不取消既有 pending。

- [ ] **Step 1: 写 render key 与空取消的失败测试**

```swift
@Test("详情专属状态不进入封面网格等价键")
func renderKeyUsesOnlyGridState() {
    let first = AlbumCoverWallRenderKey(
        snapshotRevision: 7,
        filter: .all,
        normalizedQuery: "",
        selectedAlbumIDs: [],
        coverWriteMessages: [:],
        splittingAlbumIDs: []
    )
    #expect(first == first)
    #expect(first != AlbumCoverWallRenderKey(
        snapshotRevision: 8,
        filter: .all,
        normalizedQuery: "",
        selectedAlbumIDs: [],
        coverWriteMessages: [:],
        splittingAlbumIDs: []
    ))
}
```

保留并运行现有“取消不存在的待保存封面不会发布状态变化”测试；新增测试验证普通打开详情不会改变 pending。

- [ ] **Step 2: 运行测试确认 RED**

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AlbumCoverWallSnapshotTests -only-testing:CoverDropTests/AppModelImportTests/cancellingMissingPendingCoverDoesNotPublishChange CODE_SIGNING_ALLOWED=NO
```

Expected: `AlbumCoverWallRenderKey` 不存在导致 FAIL。

- [ ] **Step 3: 抽出等价网格并改用 presentation**

`LibraryScanSummaryView.body` 每次只从 AppModel 取得 O(1) 快照。`EquatableAlbumCoverGrid ==` 比较 render key 和布局，不比较闭包；`ForEach(snapshot.cards)` 的 `AlbumCoverCard` 不再调用 `displayAlbumName`、`displayArtistName`、`formatTags`，也不持有完整 `AlbumScanRecord`。

卡片 drop 成功后直接打开详情，不清理刚设置的 pending。关闭详情只执行一次清理。扫描结果替换时，`AppModel.setScanResult` 计算 deleted IDs 并定向清理 transient 状态，替代 body 内 `result.albums.map(\.id)`。

- [ ] **Step 4: 接入详情进出 span，并把搜索改为内联工作流目的地**

打开时创建 `打开详情` span，`AlbumDetailSheet` 首次 `onAppear` 结束；关闭时创建 `返回封面墙` span，在状态提交后的下一次主队列迭代结束。span 只存于视图本地 `@State`，不进入网格 render key。

`AlbumDetailSheet` 使用一个 `ZStack` 在详情和 `CoverSearchSheet` 之间切换，不再创建系统 `.sheet`。搜索页通过显式 `onClose` 返回详情；专辑移除统一返回详情。外层专辑 drop receiver 只挂在详情分支，避免与搜索页自己的 drop zone 竞争。新增状态测试覆盖容器尺寸、关闭/移除回退和 drop zone 策略。

- [ ] **Step 5: 运行网格、AppModel 和布局测试确认 GREEN**

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AlbumCoverWallSnapshotTests -only-testing:CoverDropTests/AppModelImportTests -only-testing:CoverDropTests/FixedCoverGridLayoutTests CODE_SIGNING_ALLOWED=NO
```

---

### Task 4: 受限、合并且可取消的本地缩略图加载器

**Files:**
- Modify: `CoverDrop/App/AppConfiguration.swift`
- Create: `CoverDrop/Infrastructure/Images/CoverThumbnailLoader.swift`
- Modify: `CoverDrop/Infrastructure/Images/CoverPreviewCache.swift`
- Modify: `CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift`
- Create: `CoverDropTests/Unit/CoverThumbnailLoaderTests.swift`
- Modify: `CoverDropTests/Unit/CoverPreviewCacheTests.swift`

**Interfaces:**
- Produces: `AppConfiguration.CoverImages(maxConcurrentLocalThumbnails:maxConcurrentRemotePreviews:)`，默认 `4/6`。
- Produces: `CoverThumbnailLoader.Request(url:maxPixelSize:contentRevision:)`。
- Produces: `CoverThumbnailLoader.image(for:) async -> SendableNSImage?`。

- [ ] **Step 1: 写并发上限、同 key 合并和排队取消测试**

使用注入 decoder 与 actor 计数器：发起 100 个不同 key，断言 `peakConcurrent == 4`；同一 key 的 20 个消费者断言 decoder 只执行一次；占满 4 个槽后创建第 5 个请求并立即取消，释放槽后断言第 5 个 decoder 未执行。

- [ ] **Step 2: 运行测试确认 RED**

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/CoverThumbnailLoaderTests CODE_SIGNING_ALLOWED=NO
```

Expected: `CoverThumbnailLoader` 不存在导致 FAIL。

- [ ] **Step 3: 实现 actor 加载器**

为每个 key 保存 generation、共享 task 和 consumer IDs；最后一个消费者取消且任务尚未开始时从队列移除。已开始的 ImageIO 解码允许完成，但最多 4 个。默认 decoder 必须在 `Task.detached(priority: .utility)` 内调用 `CoverPreviewCache.cachedImage`。

`CoverPreviewCache` 新增接收预计算 `contentRevision` 的缓存 key API，卡片常规加载不再调用 `thumbnailIdentity` 和 `cachedImage` 各读取一次文件资源值。保存/外部刷新通过 presentation revision 产生新 key。

- [ ] **Step 4: 替换两个 SwiftUI detached 热路径**

`CachedCoverFillView` 和 `CachedAlbumCoverPreview` 只 await 共享 loader；`.task` 取消后不得把旧图片回写到复用的卡片状态。慢于 100ms 或失败时记录 `加载封面缩略图`，成功快请求不逐卡打印。

- [ ] **Step 5: 运行图片和布局测试确认 GREEN**

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/CoverThumbnailLoaderTests -only-testing:CoverDropTests/CoverPreviewCacheTests -only-testing:CoverDropTests/FixedCoverGridLayoutTests CODE_SIGNING_ALLOWED=NO
```

---

### Task 5: 远程预览、聚合解析和拖图暂存离开主 actor

**Files:**
- Modify: `CoverDrop/Infrastructure/Images/RemoteCoverImageDataCache.swift`
- Modify: `CoverDrop/Infrastructure/Images/RemoteCoverPreviewLoader.swift`
- Modify: `CoverDrop/Infrastructure/Images/CoverImageStagingCache.swift`
- Modify: `CoverDrop/Infrastructure/Search/ITunesCoverSearchClient.swift`
- Modify: `CoverDrop/Infrastructure/Search/DoubanCoverSearchClient.swift`
- Modify: `CoverDrop/App/AppModel.swift`
- Modify: `CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift`
- Modify: `CoverDropTests/Unit/RemoteCoverImageDataCacheTests.swift`
- Modify: `CoverDropTests/Unit/RemoteCoverPreviewLoaderTests.swift`
- Modify: `CoverDropTests/Unit/CoverImageStagingCacheTests.swift`
- Modify: `CoverDropTests/Unit/ITunesCoverSearchClientTests.swift`
- Modify: `CoverDropTests/Unit/DoubanCoverSearchClientTests.swift`

**Interfaces:**
- Changes: `RemoteCoverImageDataCache` 不同 URL 峰值加载数可配置，同 URL 继续合并。
- Produces: `RemoteCoverPreviewLoader.loadImage(from:load:)`，decoded cache 命中时不调用 load。
- Produces: 两个搜索 client 的 `decodeResultsOffMainActor(from:) async throws`。

- [ ] **Step 1: 写当前未提交缓存实现缺失的失败/容量/并发测试**

新增：失败不缓存；超过项目数和字节数淘汰最早项；20 个不同 URL 峰值并发不超过 6；decoded cache 命中时数据 loader 调用数为 0；无效图片不进入 decoded cache；后台 decode/校验/落盘探针返回 `Thread.isMainThread == false`。

- [ ] **Step 2: 运行远程图片测试并确认至少一个 RED**

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/RemoteCoverImageDataCacheTests -only-testing:CoverDropTests/RemoteCoverPreviewLoaderTests -only-testing:CoverDropTests/CoverImageStagingCacheTests CODE_SIGNING_ALLOWED=NO
```

Expected: 并发上限、decoded-first 或后台执行断言失败。

- [ ] **Step 3: 补强数据缓存和远程预览**

保留现有 TTL 60 秒、20 项、64MB 和同 URL in-flight 合并。远程预览先查 `NSCache`，未命中才查数据缓存/网络；用 ImageIO 按目标像素下采样，不使用裸 `NSImage(data:)`。预览数据缓存最大并发 6；原图预取使用独立 cache/并发计数和 `.userInitiated` 优先级。

- [ ] **Step 4: 暂存校验与落盘整体 detached**

`stageRemoteImage` 在网络完成后，通过 `Task.detached(priority: .userInitiated)` 执行 `CGImageSource` 完整性校验、缓存目录创建和原子写入。保留 HTTP 状态、MIME、20MB、豆瓣 Referer 和错误文案。预取失败只记录调试日志；真实 drop 仍重试并显示错误。

- [ ] **Step 5: 搜索解析离开主 actor 并补 span**

网络返回后的豆瓣 HTML 提取和两种 JSON decode 通过 detached helper 执行。内联 `CoverSearchSheet` 记录 `打开聚合搜索` 和 `聚合搜索请求`；取消必须结束为 `cancelled`。聚合卡片和 WKWebView 捕获 HTTP(S) URL 时都触发原图预取。

- [ ] **Step 6: 运行远程图片、搜索和拖图测试确认 GREEN**

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/RemoteCoverImageDataCacheTests -only-testing:CoverDropTests/RemoteCoverPreviewLoaderTests -only-testing:CoverDropTests/CoverImageStagingCacheTests -only-testing:CoverDropTests/ITunesCoverSearchClientTests -only-testing:CoverDropTests/DoubanCoverSearchClientTests -only-testing:CoverDropTests/AppModelImportTests CODE_SIGNING_ALLOWED=NO
```

---

### Task 6: 后台目录检查、完整 JPEG 校验和单次封面记录发布

**Files:**
- Modify: `CoverDrop/App/AppModel.swift`
- Modify: `CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift`
- Modify: `CoverDrop/Infrastructure/Images/ImageIOCoverImageWriter.swift`
- Modify: `CoverDropTests/Unit/AppModelImportTests.swift`
- Modify: `CoverDropTests/Integration/ImageIOCoverImageWriterTests.swift`

**Interfaces:**
- Produces: `AppModel.albumFolderExistsOffMainActor(_:) async -> Bool`。
- Changes: `removeAlbumIfFolderMissing(albumID:)` 为 async，并在等待后重新确认选中库/专辑。
- Changes: `replaceAlbumCover` 一次写入带稳定 previewURL 的 `AlbumScanRecord`。

- [ ] **Step 1: 写后台目录检查、截断 JPEG 和一次更新测试**

```swift
@Test("专辑目录检查离开主线程")
func albumFolderCheckRunsOffMainThread() async {
    let wasMain = await AppModel.runAlbumFolderCheckOffMainActor { Thread.isMainThread }
    #expect(wasMain == false)
}
```

新增 writer 测试：制作只有 JPEG 头但无法解出首帧的截断文件，已有 `cover.jpg` 内容保持不变；完整 JPEG 仍逐字节原样复制。AppModel 测试记录目标专辑 cover 变化次数，保存成功严格为一次，最终记录已含 previewURL。

- [ ] **Step 2: 运行测试确认 RED**

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AppModelImportTests/albumFolderCheckRunsOffMainThread -only-testing:CoverDropTests/ImageIOCoverImageWriterTests CODE_SIGNING_ALLOWED=NO
```

Expected: helper 不存在或截断 JPEG 被错误接受。

- [ ] **Step 3: 实现后台目录检查和顺序轮询**

书签解析和 `fileExists` 在 detached task 执行；详情使用单个顺序 task，同一检查未结束时不启动下一次。所有检查记录 `检查专辑目录` span。保存等待期间不阻塞主 actor；目录消失仍显示“未找到专辑”并保留 pending。

- [ ] **Step 4: 完整验证 JPEG 后再原样复制**

JPEG 免重编码分支必须同时满足 `CGImageSourceGetCount > 0` 和首帧可创建；临时文件完成后才原子替换现有封面。其他格式继续转 JPEG。

- [ ] **Step 5: 保存前生成预览，主 actor 只替换一次专辑记录**

后台顺序为写 `cover.jpg` → 生成/刷新预览 → 返回 `(coverURL, previewURL)`；MainActor 再执行一次 `setScanResult(...replacingAlbums:)`。删除保存后的第二轮 `refreshCoverPreviewInBackground -> replaceAlbumCover`。pending、保存中和提示仍保持原有语义，但网格已由 Task 3 隔离。

- [ ] **Step 6: 运行 AppModel、writer 和缓存测试确认 GREEN**

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AppModelImportTests -only-testing:CoverDropTests/ImageIOCoverImageWriterTests -only-testing:CoverDropTests/CoverPreviewCacheTests CODE_SIGNING_ALLOWED=NO
```

---

### Task 7: SQLite 单专辑增量更新与全量回退串行保序

**Files:**
- Modify: `CoverDrop/Domain/Protocols/ScanSnapshotStoring.swift`
- Create: `CoverDrop/Infrastructure/Persistence/ScanSnapshotUpdateQueue.swift`
- Modify: `CoverDrop/Infrastructure/Persistence/SQLiteScanSnapshotStore.swift`
- Modify: `CoverDrop/App/AppModel.swift`
- Modify: `CoverDropTests/Integration/SQLiteScanSnapshotStoreTests.swift`
- Create: `CoverDropTests/Unit/ScanSnapshotUpdateQueueTests.swift`
- Modify: `CoverDropTests/Unit/AppModelImportTests.swift`

**Interfaces:**
- Produces: `AlbumCoverSnapshotUpdating.updateAlbumCover(_:forAlbumID:at:expectedLibrary:) async throws -> ScanSnapshotSummary`。
- Produces: `ScanSnapshotUpdateQueue.submit(libraryID:operation:)`，同一 library 最多一个 operation 在途，pending 按 FIFO 保留并顺序执行。

- [ ] **Step 1: 写 SQLite 不触碰音轨行的失败测试**

先保存包含两张专辑和多首音轨的快照，记录 `audio_files` 行数与 rowid；调用单专辑更新后断言：目标 cover 各列更新，非目标专辑不变，音轨行数和 rowid 不变。连续两次更新最终值为第二次。

- [ ] **Step 2: 写慢 store 串行/保序失败测试**

向队列快速提交同一 library 的 A、B、C；A 阻塞期间 B、C 均进入等待队列。释放后断言实际执行 `[A, B, C]`、`peakConcurrent == 1`。另一个 library 可独立执行。

- [ ] **Step 3: 运行测试确认 RED**

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/SQLiteScanSnapshotStoreTests -only-testing:CoverDropTests/ScanSnapshotUpdateQueueTests CODE_SIGNING_ALLOWED=NO
```

Expected: 增量协议和队列不存在导致 FAIL。

- [ ] **Step 4: 实现 SQLite 串行 writer 和单行 UPDATE**

所有 SQLite 写操作通过 store 内部 actor coordinator 串行，并在该 actor executor 执行同步 SQLite API。增量方法校验文件位于快照目录、header 与 library 匹配、目标 album 存在；在 `BEGIN IMMEDIATE` 中只更新 `albums.cover_*` 六列，失败回滚。不得修改 schema 或重插 `audio_files`。

- [ ] **Step 5: AppModel 保存后优先增量，其他更新走队列全量回退**

已有 active SQLite summary 且 store 支持增量时提交单专辑 cover 更新；否则捕获对应时刻的 `LibraryScanResult`，在队列 executor 构造 snapshot 并全量 replace。所有 `scheduleActiveScanSnapshotUpdate` 都进入同一每库 FIFO 队列，禁止多个 detached 全量写并发或丢弃中间更新。结束后只在库仍存在时回主 actor 更新 summary/消息。

- [ ] **Step 6: 运行快照与 AppModel 测试确认 GREEN**

```shell
xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/SQLiteScanSnapshotStoreTests -only-testing:CoverDropTests/FileScanSnapshotStoreTests -only-testing:CoverDropTests/ScanSnapshotUpdateQueueTests -only-testing:CoverDropTests/AppModelImportTests CODE_SIGNING_ALLOWED=NO
```

---

### Task 8: 补齐拖图/保存/FSEvents 耗时边界并运行真实 App 采样

**Files:**
- Modify: `CoverDrop/App/AppModel.swift`
- Modify: `CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift`
- Modify: `CoverDrop/Infrastructure/Images/CoverImageStagingCache.swift`
- Modify: `CoverDrop/Infrastructure/Images/ImageIOCoverImageWriter.swift`
- Modify: `CoverDrop/Infrastructure/FileSystem/FSEventsLibraryChangeMonitor.swift`
- Modify: `CoverDropTests/Unit/CoverDropPerformanceLogTests.swift`

**Interfaces:**
- Consumes: Task 1 span API。
- Produces: 从打开详情到返回封面墙的配对 operation 日志。

- [ ] **Step 1: 写慢缩略图阈值、错误摘要和取消 outcome 测试**

断言 `99.99ms/成功 -> false`、`100ms/成功 -> true`、`1ms/失败 -> true`；错误文本换行被清为 `_`；取消请求输出 `outcome=cancelled`。

- [ ] **Step 2: 运行日志测试确认 RED**

Run: Task 1 定向命令。Expected: 慢操作 helper 不存在导致 FAIL。

- [ ] **Step 3: 接入剩余边界**

`CoverDropReceiver` 从 provider load 到得到 URL/Data 记录 `读取拖入图片`；暂存整体记录 `暂存封面图片`；writer 记录 `保存封面图片`；主 actor 局部数组/索引更新记录 `更新专辑封面记录`；快照队列记录 `更新扫描快照 mode=incremental|full`。FSEvents 调试日志记录原始 paths/flags 数量和归属判定耗时，但不扩大忽略规则。

- [ ] **Step 4: 构建调试 App 并以环境开关启动**

```shell
xcodebuild build -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -derivedDataPath /tmp/CoverDropPerformanceDerivedData CODE_SIGNING_ALLOWED=NO
COVERDROP_DEBUG_LOG=1 /tmp/CoverDropPerformanceDerivedData/Build/Products/Debug/CoverDrop.app/Contents/MacOS/CoverDrop
```

- [ ] **Step 5: 自主操作并采样真实工作流**

使用已加载扫描快照依次执行：连续滚动、打开/关闭详情、打开聚合搜索、拖入封面、保存、返回。同步读取终端 span；在滚动和详情切换期间用 `sample <pid> 5 -file <path>` 采集主线程。验收：

- 非网络 UI span 不出现超过 50ms 的主线程阶段。
- 滚动调用树不再出现 `AlbumDisplayNameCleaning`、`AlbumNameCleaning` 或同步 `FileManager`。
- 热缓存详情打开/关闭与 pending 提交目标低于 50ms。
- 保存后的主 actor `更新专辑封面记录` 低于 50ms；本地 JPEG 总保存目标低于 150ms。
- 聚合搜索采样不再出现 `SheetBridge` 或 `NSMoveHelper` 系统 sheet 动画栈。

- [ ] **Step 6: 若定向修复后仍有 >50ms hitch，只记录证据并启用后备决策门**

只有 Time Profiler 证明瓶颈仍在 SwiftUI 网格布局/提交且不在名称、I/O 或图片解码时，才另写 `NSCollectionView + diffable data source` 设计；不得在本任务里无证据切换实现。

---

### Task 9: 全量验证与交付

**Files:**
- Modify after user acceptance only: `AGENTS.md`

- [ ] **Step 1: 检查 diff、未受控输出和格式**

```shell
git status --short
git diff --check
rg -n "print\(|shouldAlwaysPrint|COVERDROP_DEBUG_LOG" CoverDrop
```

Expected: 只有任务相关改动；`git diff --check` 无输出；环境变量只由诊断组件读取，业务调用点不直接无条件 `print`。

- [ ] **Step 2: 运行完整项目验证**

```shell
zsh Scripts/verify.sh
```

Expected: `xcodebuild clean test` exit 0，所有 Swift Testing 用例通过。

- [ ] **Step 3: 复读设计逐条核对**

逐项核对 8 个根因、产品边界、确定性自动测试和运行时验收；任何缺口回到对应 Task，不用“测试通过”代替需求核对。

- [ ] **Step 4: 向用户交付代码、实测日志和剩余风险**

交付根因、改动、测试命令/结果、运行时最慢 span、sample 结论和构建路径。用户先自行构建体验；未得到用户“达到要求”的确认前不修改 `AGENTS.md`。

- [ ] **Step 5: 用户确认后更新 AGENTS.md**

补充：封面墙使用预计算轻量快照和等价网格；本地/远程图片加载有界；目录检查、暂存、保存和 SQLite 写入离开主 actor；`COVERDROP_DEBUG_LOG=1` 输出结构化 span。仅文档变更后再次运行 `git diff --check`。
