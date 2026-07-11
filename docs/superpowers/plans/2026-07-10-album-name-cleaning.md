# 专辑展示名称清洗 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用完整音乐库快照驱动一套保守、字段感知、可量化验证的专辑展示名称清洗规则。

**Architecture:** 原始扫描结果和持久化数据保持不变；Domain 纯规则负责派生展示/搜索名称，`AlbumDisplayNameCleaning` 只用占非空标签至少 70% 且被目录名佐证的候选辅助选择名称，Ollama 输出后处理复用同一规则。

**Tech Stack:** Swift 6、Foundation `NSRegularExpression`、Swift Testing、Xcode 26、旧 JSON/SQLite 快照兼容模型。

## Global Constraints

- 继续保持“无封面专辑不自动清洗”的现有行为。
- 不修改真实音乐库、扫描边界、`relativePath`、音频标签或快照原始列。
- 文件夹名优先，标签只在同专辑内形成至少 70% 稳定多数且被目录名包含时辅助。
- 每条破坏性正则同时提供正例和反例。
- 不触碰当前有并行改动的 `CoverDropApp.swift`、`LibraryScanSummaryView.swift`、`FixedCoverGridLayout.swift` 及其测试。
- 共享脏工作区中不创建提交；实现完成后只报告本任务文件。

---

### Task 1: 纯名称规则的失败测试

**Files:**
- Create: `CoverDropTests/Unit/AlbumNameCleaningTests.swift`

**Interfaces:**
- Consumes: 计划中的 `AlbumNameCleaning.cleanArtistName(_:)` 与 `cleanAlbumName(_:artistName:)`。
- Produces: 数据库真实模式的正反例契约。

- [ ] **Step 1: 写数据库正例表**

加入至少以下断言：

```swift
#expect(AlbumNameCleaning.cleanAlbumName("[Qobuz] 蔡健雅 - Bored 1997 [24-96]", artistName: "蔡健雅") == "Bored")
#expect(AlbumNameCleaning.cleanAlbumName("蔡琴 - [(1983) 昨夜之灯] (FLAC)", artistName: "蔡琴") == "昨夜之灯")
#expect(AlbumNameCleaning.cleanAlbumName("2001.07.09 - 孙燕姿 - 《风筝》", artistName: "孙燕姿") == "风筝")
#expect(AlbumNameCleaning.cleanAlbumName("1994-03郭富城 - AK-47（港首版+华星）", artistName: "郭富城") == "AK-47")
#expect(AlbumNameCleaning.cleanAlbumName("东升魔音唱片 孙露 第九张专辑《寂寞诱惑》WAV+CUE", artistName: "孙露") == "寂寞诱惑")
```

- [ ] **Step 2: 写防误伤和幂等测试**

逐字断言 `1989`、`2001 A Space Odyssey`、`20 GREATEST HITS`、`No.1`、`24K Magic`、`J-GAME`、`AK-47`、`AC/DC`、`2023VIP数字专辑(1)`、`银色月光下(演唱会)`；对所有正反例断言二次清洗等于首次结果。

- [ ] **Step 3: 运行并确认 RED**

```shell
xcodebuild -project CoverDrop.xcodeproj -scheme CoverDrop -destination "platform=macOS" -derivedDataPath "${TMPDIR:-/tmp/}CoverDropNameRuleRed" CODE_SIGNING_ALLOWED=NO test -only-testing:CoverDropTests/AlbumNameCleaningTests
```

预期：编译失败，提示找不到 `AlbumNameCleaning`，证明测试覆盖尚未实现的新接口。

### Task 2: Domain 纯规则最小实现

**Files:**
- Create: `CoverDrop/Domain/Policies/AlbumNameCleaning.swift`
- Test: `CoverDropTests/Unit/AlbumNameCleaningTests.swift`

**Interfaces:**
- Produces: `cleanArtistName(_:) -> String`、`cleanAlbumName(_:artistName:) -> String`、内部规范键和可信噪音判断。

- [ ] **Step 1: 实现字段分离和有序清洗流水线**

实现日期前缀、列表壳、重复艺人、单书名号正文、尾部括号/格式/码率/碟号、边缘标点和回退。所有模式锚定开头或结尾，不全局替换正式标点。

- [ ] **Step 2: 运行 Task 1 测试并确认 GREEN**

运行相同命令，预期 `AlbumNameCleaningTests` 全部通过且没有警告。

- [ ] **Step 3: 检查幂等与删除比例保护**

若任一输入清洗为空或二次变化，修正规则而不是放宽测试。

### Task 3: 标签只作辅助的失败测试和实现

**Files:**
- Modify: `CoverDropTests/Unit/AlbumDisplayNameCleaningTests.swift`
- Modify: `CoverDrop/Domain/Policies/AlbumDisplayNameCleaning.swift`

**Interfaces:**
- Consumes: `AlbumNameCleaning`。
- Produces: 所有专辑统一使用的上下文候选选择。

- [ ] **Step 1: 写 RED 测试**

构造真实 `AudioFileRecord` 标签并断言：

```swift
// 单一且包含于目录名：白晓专辑 / 白晓 -> 展示歌手“白晓”
// 目录“2002-坚持到底”、所有 metadata.album 为“坚持到底” -> “坚持到底”
// 没有候选达到 70% 的冲突 metadata.album -> 仍使用目录清洗结果
// metadata.album 为 CDImage 或与目录完全无关 -> 不采用
// 无封面 -> 与有封面使用同一清洗结果
```

运行 `AlbumDisplayNameCleaningTests`，预期新增辅助候选断言失败。

- [ ] **Step 2: 实现一致候选与目录包含校验**

只在调用参数仍是扫描原名时读取标签；先清洗候选，再按规范键聚合。候选必须占非空标签至少 70%、非占位词，并与原始目录名互相印证；低于阈值时回退目录清洗结果。

- [ ] **Step 3: 运行并确认 GREEN**

运行 `AlbumDisplayNameCleaningTests` 与 `AlbumNameCleaningTests`，预期全部通过。

### Task 4: 统一 Ollama 后处理

**Files:**
- Modify: `CoverDrop/Infrastructure/LLM/OllamaAlbumNameSuggesting.swift`
- Modify: `CoverDropTests/Unit/AlbumNameEnhancementTests.swift`

**Interfaces:**
- Consumes: `AlbumNameCleaning`。
- Preserves: `AlbumNameSuggestionCleaner` 现有类型和方法签名。

- [ ] **Step 1: 增加 RED 断言**

断言 Ollama 返回 `[Qobuz] 蔡健雅 - Bored 1997 [24-96]` 和繁体歌手时，解析结果与 Domain 清洗一致；现有正式数字名称测试继续保留。

- [ ] **Step 2: 委托 Domain 规则**

`AlbumNameSuggestionCleaner.clean` 对歌手调用 `cleanArtistName`，对专辑调用 `cleanAlbumName(_:artistName:)`，删除原有重复正则实现。

- [ ] **Step 3: 运行名称相关测试**

运行 `AlbumNameCleaningTests`、`AlbumDisplayNameCleaningTests`、`AlbumNameEnhancementTests`，预期全部通过。

### Task 5: 全量数据库覆盖循环

**Files:**
- Read only: 用户提供的 39 MB 快照。
- Modify: `CoverDrop/Domain/Policies/AlbumNameCleaning.swift`
- Modify: `CoverDropTests/Unit/AlbumNameCleaningTests.swift`

**Interfaces:**
- Consumes: 4,867 张专辑、68,525 个音频文件。
- Produces: 遍历率、残留率、标签佐证一致率、空结果、幂等失败数。

- [ ] **Step 1: 完整遍历并建立首次报告**

逐条读取每个 `audioFiles.relativePath` 和标签；逐张调用生产清洗器。不得只看前若干行。

- [ ] **Step 2: 按残留频次补规则**

若明确结构噪音残留率大于 2%，先为最高频未覆盖模式写失败正例及相邻反例，再实现最小规则；循环到阈值达标。

- [ ] **Step 3: 验证安全指标**

要求 68,525/68,525 文件已遍历、空结果 0、幂等失败 0、稳定多数且被目录佐证的高置信标签一致率至少 98%。

### Task 6: 项目验证和说明

**Files:**
- Modify: `AGENTS.md`（仅记录最终已验证规则与边界）。

- [ ] **Step 1: 审查 diff 范围**

确认没有改动并行 UI 文件、扫描边界、快照 schema 或真实路径字段。

- [ ] **Step 2: 更新项目说明**

记录字段分离、目录优先/标签辅助、覆盖率阈值和关键反例，供后续会话延续。

- [ ] **Step 3: 完整验证**

```shell
git diff --check
zsh Scripts/verify.sh
```

预期两个命令退出码均为 0；若失败，先定位并修复，再重新完整运行。

## 计划自审

- 规格中的每个边界均有对应任务。
- 无 TBD、TODO、稍后实现或未定义接口。
- 类型名在测试、Domain、展示和 Ollama 任务中一致。
- 计划保留共享工作区现有改动，不包含提交或分支操作。
