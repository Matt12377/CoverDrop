# 聚合封面加载与拖拽预取 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让聚合搜索缩略图复用缓存，并在拖拽开始时预取原始大图，使落下后无需重复下载，同时保留最终封面质量。

**Architecture:** 新增独立的 `RemoteCoverImageDataCache` actor，为远程图片数据提供 TTL、容量限制和同 URL 任务合并。缩略图加载器在其上叠加解码后的 `NSImage` 缓存；封面暂存器和聚合卡片拖拽共享大图数据缓存。

**Tech Stack:** Swift 6、SwiftUI、Foundation URLSession、AppKit NSCache、Swift Testing。

## Global Constraints

- 保持扫描和封面写入的既有产品边界；预取不得写入音乐库或设置待保存封面。
- 保留豆瓣 Referer、HTTP/MIME/20 MB 验证和最终大图 URL。
- 缓存最多 20 项、64 MB，TTL 为 60 秒。
- 所有新增测试和代码文案使用中文。

---

### Task 1: 远程图片数据缓存

**Files:**
- Create: `CoverDrop/Infrastructure/Images/RemoteCoverImageDataCache.swift`
- Test: `CoverDropTests/Unit/RemoteCoverImageDataCacheTests.swift`

**Interfaces:**
- Produces: `RemoteCoverImageDataCache.value(for:load:) async throws -> Data`。

- [ ] **Step 1: 写失败测试**

覆盖顺序重复 URL 只调用一次 loader、两个并发请求合并为一次 loader，以及超过 60 秒 TTL 后重新加载。

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/RemoteCoverImageDataCacheTests`

Expected: 因缓存类型不存在而失败。

- [ ] **Step 3: 实现 actor**

实现 `RemoteCoverImageDataCache`：以 URL 为键保存 `Task<Data, Error>` 和带时间戳的缓存项；成功数据按最早时间淘汰直到符合 20 项、64 MB；失败时移除进行中任务且不缓存。

- [ ] **Step 4: 运行测试确认通过**

运行 Step 2 命令，预期全部通过。

### Task 2: 缩略图缓存与请求合并

**Files:**
- Modify: `CoverDrop/Infrastructure/Images/RemoteCoverPreviewLoader.swift`
- Modify: `CoverDropTests/Unit/RemoteCoverPreviewLoaderTests.swift`

**Interfaces:**
- Consumes: `RemoteCoverImageDataCache.value(for:load:)`。
- Produces: `RemoteCoverPreviewLoader.loadImage(from:) async -> NSImage?` 的已解码缓存行为。

- [ ] **Step 1: 写失败测试**

通过可注入的数据加载闭包验证：同一 URL 第二次加载直接返回已解码图像，加载闭包计数保持为 1。

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/RemoteCoverPreviewLoaderTests`

Expected: 因缺少缓存加载接口或加载次数为 2 而失败。

- [ ] **Step 3: 实现最小缓存路径**

为 `RemoteCoverPreviewLoader` 添加受限 `NSCache<NSURL, NSImage>` 和数据缓存；保留 `returnCacheDataElseLoad`、15 秒超时与豆瓣 Referer。

- [ ] **Step 4: 运行测试确认通过**

运行 Step 2 命令，预期全部通过。

### Task 3: 拖拽大图预取与复用

**Files:**
- Modify: `CoverDrop/Infrastructure/Images/CoverImageStagingCache.swift`
- Modify: `CoverDrop/App/AppModel.swift`
- Modify: `CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift`
- Modify: `CoverDropTests/Unit/AppModelImportTests.swift`

**Interfaces:**
- Consumes: `RemoteCoverImageDataCache`。
- Produces: `AppModel.prefetchRemoteCoverImage(at:)`，只预取，不更改 `pendingCoverURLsByAlbumID`。

- [ ] **Step 1: 写失败测试**

验证预取不会设置待保存封面；验证 `stageRemoteImage` 读取预取数据时不会执行第二次下载。

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/AppModelImportTests`

Expected: 因预取接口不存在而失败。

- [ ] **Step 3: 实现预取与 UI 调用**

让 `CoverImageStagingCache.prefetchRemoteImage(at:)` 与 `stageRemoteImage(at:)` 走同一大图数据缓存；在聚合卡片 `.onDrag` 回调开始时调用 `AppModel.prefetchRemoteCoverImage(at:)`。预取失败只写调试日志，落下时沿用现有的用户可见错误处理。

- [ ] **Step 4: 运行相关测试与完整验证**

Run: `xcodebuild test -project CoverDrop.xcodeproj -scheme CoverDrop -destination 'platform=macOS' -only-testing:CoverDropTests/RemoteCoverImageDataCacheTests -only-testing:CoverDropTests/RemoteCoverPreviewLoaderTests -only-testing:CoverDropTests/AppModelImportTests && git diff --check && zsh Scripts/verify.sh`

Expected: 全部测试、格式检查与项目验证通过。
