# CoverDrop AI 接手指南

本文是后续 AI 会话的首要项目说明。开始工作前先读本文，再按任务读取相关代码。除非用户明确要求，项目沟通、代码注释、日志、文档和界面文案均使用中文。

## 新会话启动顺序

1. 运行 `git status --short`，确认用户和其他会话留下的改动。
2. 阅读本文件、`README.md` 和与任务直接相关的源码；`ARCHITECTURE.md` 含有部分早期规划，只能作背景参考，不能覆盖当前代码事实。
3. 用 `rg` 定位调用链和测试，不要只根据文件名猜实现。
4. 修改前确认不会覆盖工作区已有改动；发现同一文件正被其他会话修改时，先向用户说明冲突风险。
5. 实现后运行与改动范围匹配的测试，交付前至少执行 `git diff --check`；代码改动默认执行 `zsh Scripts/verify.sh`。

禁止把未提交文件视为可清理的临时产物。不要使用 `git reset --hard`、`git checkout --` 或其他会丢失现有改动的命令。

## 项目目标与核心流程

CoverDrop 是 macOS SwiftUI 桌面应用，用于半自动整理音乐库专辑封面：

1. 用户添加音乐库、歌手目录或单张专辑目录。
2. App 保存安全书签并按用户确认的目录角色扫描。
3. 扫描器识别专辑边界、音频、CUE、已有图片、内嵌封面及异常。
4. 封面墙按状态筛选专辑，详情页展示路径、曲目、名称和问题。
5. 用户通过聚合搜索或内置网页寻找封面，将图片拖入 App 暂存。
6. 只有用户点击保存后，基础设施服务才向专辑目录写入 `cover.jpg`。

不可破坏的产品边界：

- 文件夹层级是专辑边界和真实路径的主证据；音频标签只用于核对、异常判断和展示名称辅助。
- 扫描、名称清洗和 Ollama 均不得移动、重命名或修改音乐文件及标签。
- 扫描阶段只读。真实音乐库写入只能经 `CoverImageWriting` 等专门协议实现，SwiftUI View 不得直接改文件。
- Ollama 输出只影响派生展示名与搜索词，不得决定专辑边界、真实路径或封面保存位置。
- 拖入图片先进入暂存状态；写入失败时必须保留待保存图片，不能制造“已保存”的 UI 状态。

## 技术环境

- Swift 6、SwiftUI、Xcode 工程：`CoverDrop.xcodeproj`。
- macOS deployment target：`26.4`；默认 actor isolation 为 `MainActor`，并启用 approachable concurrency。
- App Sandbox 已启用，依赖用户选择目录的读写权限、安全书签、网络客户端权限和 Finder Apple Events。
- TagLib C 通过 Homebrew 路径链接：头文件 `/opt/homebrew/include`，库 `/opt/homebrew/lib`，链接参数 `-ltag_c`。
- 持久化使用系统 `SQLite3`；图片使用 ImageIO；内置搜索页使用 WebKit；文件变化使用 FSEvents。
- XLD 是可选外部应用。CoverDrop 只把 CUE 交给 XLD，不自行分轨。
- 本地名称增强依赖 Ollama，默认 `http://127.0.0.1:11434`、模型 `qwen3.5:4b-mlx`。

常用命令：

```shell
open CoverDrop.xcodeproj
zsh Scripts/verify.sh
COVERDROP_DEBUG_LOG=1 open <构建出的 CoverDrop.app>
```

`Scripts/verify.sh` 会使用独立 DerivedData 执行 `xcodebuild clean test`，无需代码签名。若本机缺少 TagLib，先确认 Homebrew 的 `taglib` 已安装且位于上述路径。

## 架构与依赖方向

```text
CoverDrop/App                 应用入口、依赖装配、AppModel 和顶层路由
CoverDrop/Domain/Models       业务数据类型
CoverDrop/Domain/Protocols    文件系统、扫描、搜索、持久化等能力接口
CoverDrop/Domain/Policies     可独立测试的名称、筛选和展示规则
CoverDrop/Infrastructure      协议的真实实现
CoverDrop/Features/LibraryHome 当前主要界面与交互
CoverDropTests/Unit           纯规则、状态和假依赖测试
CoverDropTests/Integration    临时目录及真实基础设施集成测试
Scripts                       验证和名称清洗审计脚本
```

依赖规则：

- `Features` 通过 `AppModel` 和 `Domain` 类型工作，不直接创建或依赖 TagLib、ImageIO、Ollama、SQLite 等具体实现。
- `Infrastructure` 实现 `Domain/Protocols`；协议和纯规则不反向依赖 UI 或基础设施。
- `AppEnvironment.live` 是真实依赖的唯一主要装配点，测试通过构造 `AppEnvironment` 注入假实现。
- 应用级参数统一放在 `AppConfiguration`，不要在基础设施内部另藏默认值。
- `AppModel` 是 `@MainActor` 的顶层状态所有者。异步 I/O 可离开主线程，发布 UI 状态必须回到正确 actor。

## 关键代码地图

- `CoverDrop/App/AppModel.swift`：导入、扫描、路由、封面暂存/保存、Ollama 队列、快照和实时刷新。文件较大，修改前先定位相关状态及清理路径。
- `CoverDrop/App/AppEnvironment.swift`：生产依赖装配。
- `CoverDrop/App/AppConfiguration.swift`：扫描并发、快照目录、实时刷新、搜索源、Ollama 参数。
- `CoverDrop/Infrastructure/FileSystem/FileSystemLibraryScanner.swift`：专辑边界发现和专辑扫描核心。
- `CoverDrop/Domain/Policies/AlbumNameCleaning.swift`：歌手名/专辑名确定性清洗。
- `CoverDrop/Domain/Policies/AlbumDisplayNameCleaning.swift`：目录名、标签多数候选和 Ollama 建议的展示决策。
- `CoverDrop/Domain/Policies/AlbumScanDisplayIndex.swift`：封面墙筛选、搜索和统计索引。
- `CoverDrop/Domain/Models/AlbumCoverCardPresentation.swift`：封面墙轻量卡片数据、不可变快照和网格渲染键；不要把完整音频列表重新带回卡片热路径。
- `CoverDrop/Domain/Models/AlbumCoverWorkflowPresentationState.swift`：专辑详情与封面搜索的内联目的地、稳定容器尺寸和 drop zone 策略。
- `CoverDrop/Domain/Diagnostics/CoverDropPerformanceLog.swift`：受环境变量控制的低开销耗时记录和主线程停顿监测。
- `CoverDrop/Infrastructure/Persistence/SQLiteScanSnapshotStore.swift`：当前 SQLite 快照实现。
- `CoverDrop/Infrastructure/Persistence/ScanSnapshotUpdateQueue.swift`：按音乐库串行、FIFO 保留更新的快照持久化队列。
- `CoverDrop/Infrastructure/Persistence/FileScanSnapshotStore.swift`：旧 JSON 快照兼容实现，不要随意删除。
- `CoverDrop/Infrastructure/Images/CoverThumbnailLoader.swift`：本地封面缩略图的共享、去重、可取消、受限并发加载器。
- `CoverDrop/Infrastructure/Images/RemoteCoverImageDataCache.swift`：远程封面数据的短期缓存、请求合并、取消和受限并发。
- `CoverDrop/Features/LibraryHome/LibraryHomeView.swift`：音乐库侧栏、多选、导入和顶层页面。
- `CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift`：封面墙、内联详情/搜索与拖图，当前超过 3000 行；大改前应先提出拆分边界，不要顺手全面重构，也不要把名称清洗、同步 I/O 或全量专辑派生重新放回 View 热路径。
- `CoverDrop/Features/LibraryHome/FixedCoverGridLayout.swift`：封面墙固定网格列数/尺寸计算。

## 当前行为

### 音乐库与扫描

- 支持 `.library`、`.artist`、`.album` 三种目录角色，导入时自动建议，最终由用户确认。
- 音乐库记录保存在 `UserDefaultsLibraryStore`，包含显示名、路径、安全书签和角色。
- 一次只运行一个全库扫描；批量重扫按侧栏顺序逐个执行。
- 默认专辑扫描并发为 `12`，配置范围 `1...24`。发现结果和最终结果需保持稳定排序。
- 扫描后保存 SQLite 快照，并为已扫描音乐库启动 FSEvents 监听。
- 外部文件变化优先局部重扫受影响专辑；App 自己保存封面时直接更新 UI，并抑制对应的外部刷新事件。

### 封面与搜索

- 目录图片优先；没有有效图片时才读取并导出音频内嵌 artwork 作为缓存预览。
- 常见封面名图片损坏时继续尝试内嵌图，并记录 `invalidNamedCovers`。
- 封面墙由 `AlbumScanDisplayIndex` 预计算轻量 `AlbumCoverCardPresentation`，并按修订号、筛选项和规范化查询缓存 `AlbumCoverWallSnapshot`；卡片渲染不得逐张重新执行名称清洗或遍历完整音频列表。
- 网格子树通过快照身份和 `AlbumCoverWallRenderKey` 隔离无关的 `AppModel` 发布；新增卡片状态时必须同步更新渲染键或单卡片数据，不能靠观察整个全局模型强制刷新。
- 本地缩略图默认最多并发 `4` 个，远程预览默认最多并发 `6` 个；相同请求应共享任务，视图消失或请求变化时应可取消。图片校验、读取和解码不得同步阻塞主 actor。
- 搜索源包括聚合搜索、豆瓣、Bing 图片和 Google 图片，默认“聚合搜索”。
- 搜索页左侧为 `WKWebView`，右侧为搜索源、专辑信息和封面预览。
- 专辑详情与封面搜索在同一个工作流容器内切换，不再嵌套系统 `.sheet`；详情容器为 `680 × 520`，搜索容器为 `1100 × 700`，仅详情目的地启用外层封面 drop zone。
- 本地或远程图片拖入后自动回详情页，但仍需用户显式保存。
- 每次拖图暂存都有单专辑 generation；异步结果返回时必须同时匹配当前 generation、当前音乐库和仍存在的专辑。过期结果需清理，不能覆盖较新的拖图或取消操作。
- 保存前检查专辑目录仍存在。NAS 断开或目录消失时提示“未找到专辑”，保留暂存图片。
- 安全书签解析、目录存在检查、图片写入和预览刷新均离开主 actor；保存成功后只发布一次目标专辑更新。写入失败或保存期间收到新拖图时，必须保留当前有效的待保存图片。

### Ollama 名称增强

- 当前是手动触发，不在扫描完成后自动跑：可对单张专辑触发，也可对当前音乐库缺封面的专辑批量触发并停止。
- 批量请求默认跳过已有封面专辑；单张手动请求允许处理已有封面专辑。
- 队列串行处理并避免重复任务；切换扫描结果、移除音乐库或用户停止时要正确取消并清理状态。
- 请求输入包含原始名称、相对路径、文件夹名和最多若干首曲目标签；输出必须解析为严格的 `artistName`、`albumName`。
- 单张失败记录在专辑状态中，UI 回退确定性清洗后的原始名称，并可通过“解析失败”筛选查看，不能用全局错误打断整批任务。
- 建议和状态随扫描快照保存；加载快照后恢复派生展示数据。

### 快照

- 默认目录为 `~/Library/Application Support/CoverDrop/ScanDatabases`。
- 新快照是 SQLite；稳定文件名由音乐库路径和目录角色生成，重复扫描替换该库当前快照。
- `StreamingScanSnapshotStoring` 按专辑数报告流式加载进度。
- 保存单张封面后优先经 `AlbumCoverSnapshotUpdating` 增量更新对应 SQLite 专辑行；增量能力不可用或失败时才回退全量快照替换。
- 同一音乐库的快照写入由 `ScanSnapshotUpdateQueue` 串行执行并按 FIFO 保留全部更新，不能用“只保留最后一次”丢掉中间专辑变更。
- SQLite 增量更新必须校验快照中的音乐库 UUID，不能只凭文件路径修改可能已被替换的快照。
- 非 SQLite 文件回退到旧 `FileScanSnapshotStore` JSON 读取，以兼容历史数据。
- 旧 JSON 快照的读取和解码也必须离开主 actor，加载完成后再回主 actor 发布状态。
- `ScanSnapshot.currentSchemaVersion` 当前为 `2`。改 schema 必须提供迁移或兼容方案及回归测试。

### 性能基线与诊断

- 2026-07-14 已针对大专辑墙滚动、详情进出、聚合搜索、拖图暂存和封面保存完成定向性能重构。后续修改必须保持：滚动热路径不出现名称清洗或同步文件 I/O，非网络 UI 阶段不制造超过 `50 ms` 的主线程停顿。
- `AppModel` 仍是 `@MainActor`，但默认 actor isolation 不代表基础设施工作可以留在主线程；文件系统、书签、图片编解码、网络数据处理和 SQLite 操作必须通过明确的非隔离边界执行。
- 设置 `COVERDROP_DEBUG_LOG=1` 可启用结构化性能 span 和主线程停顿监测；默认关闭，不能为了诊断在封面墙热路径加入无条件 `print`。
- 出现“专辑越多越卡”时，先检查 `AlbumCoverWallSnapshot` 是否被无意义重建、网格等价键是否失效、卡片是否重新访问完整 `AlbumScanRecord`，再用采样确认，不要直接把界面改回同步派生。
- 详情或搜索转场回归时，先检查是否重新引入嵌套系统 Sheet/AppKit bridge；只有定向优化经真实采样仍无法达标时，才评估 `NSCollectionView` 等更大范围重写。

## 扫描边界规则

修改 `FileSystemLibraryScanner` 时必须同时添加正例和反例测试，避免规则互相误伤。当前需保持：

- `.album`：导入目录本身就是专辑，`CD1`、`CD2` 等子目录不拆分。
- `.artist`：导入目录是歌手目录，向下寻找真实专辑根。
- `.library`：第一层通常是歌手，第二层及以下识别专辑；根或歌手层直属音频可记为散落音频。
- 普通 `歌手/专辑/歌曲` 是一张专辑。
- `专辑/CD1/歌曲`、`专辑/CD2/歌曲`、格式层 `WAV`/`FLAC`/`DSD`/`DFF` 应归并到父专辑。
- 同一父目录下有多个纯数字且含音频的兄弟目录时，`专辑/01`、`专辑/02` 归并到父专辑。
- `歌手/001/真实专辑/歌曲` 的 `001` 是编号壳，不应被误判为碟目录。
- `专辑/01 第一首/track.flac`、`专辑/02 第二首/track.flac` 是逐曲文件夹，应归并到共同专辑。
- `album`、`albums`、`专辑` 及合集/汇总/套装目录可作为容器线索。
- `港版`、`日本版` 等版本目录不得静默合并，应标记边界需确认。
- 忽略隐藏项目、macOS 包和符号链接，避免越界与递归循环。

性能约束：发现阶段找到的音频 URL 应传给专辑扫描复用；已有有效图片封面时不要提取内嵌 artwork；并发结果不得导致 UI 顺序随机变化。

## 名称清洗规则

- 所有专辑无论封面状态，展示和搜索都先走 `AlbumNameCleaning`/`AlbumDisplayNameCleaning`；不要在目录链路、UI 或 Ollama 实现中再维护另一套正则。
- 清洗只影响派生名称，不修改 `AlbumScanRecord` 的真实路径、相对路径、音频标签、扫描边界或封面位置。
- `artistName` 与 `albumName` 使用字段专属规则。
- 音频标签仅在非空值达到 `70%` 稳定多数且规范化候选被原始目录名包含时，才可辅助展示名。
- `CDImage`、`Unknown Album`、`未知专辑` 等占位值计入多数票分母，但不能成为候选。
- Ollama 已提供的建议优先于标签候选，但建议仍须经过统一确定性清洗。
- 必须保留有语义的数字和标点，如 `1989`、`No.1`、`24K Magic`、`J-GAME`、`AC/DC`、`Blink-182`、`A-ha`、`家 III`。
- 新规则必须有真实正例、易误伤反例和幂等性测试。

全库审计：

```shell
zsh Scripts/audit_album_name_cleaning.sh '<扫描快照.db>'
```

目标：遍历全部音频文件名；标签候选匹配率至少 `98%`，结构噪声残余不高于 `2%`，空输出和幂等失败均为 `0`。2026-07-10 华语快照基线为 4,867 张专辑、68,525 个文件名，结构噪声残余 10/4,458（0.2243%），专辑/歌手稳定标签匹配 100%；详见 `docs/analysis/2026-07-10-library-filename-audit.md`。

## UI 交互约束

- `selectedLibraryID` 只表示详情区当前显示的单个音乐库；侧栏多选状态留在 `LibraryHomeView`，不要塞进 `AppModel`。
- 单击单选、`Shift` 连选、`Cmd` 切换、`Cmd+A` 全选；批量移除只删 CoverDrop 本地记录，不删除真实音乐文件。
- 正在扫描的音乐库禁止移除；重命名只改 `LibraryRecord.displayName`。
- 底部筛选栏覆盖在封面墙上，不用 `safeAreaInset` 顶起内容；封面墙延伸到玻璃栏后方。
- 选中筛选项为蓝色胶囊白字；按钮命中区域贴合视觉尺寸。蓝色只用于选中和状态提示，阴影以深灰为主。
- 搜索默认收起；切换筛选项时收起但不清空查询。有查询时放大镜保留轻微蓝色提示。
- 筛选切换按标签顺序左右滑动；详情进出使用轻微缩放/淡入淡出；卡片 hover 只做小幅缩放和阴影。
- 详情与封面搜索使用内联目的地切换，不要重新套用嵌套 `.sheet`；搜索态的外层区域不能抢占网页向详情拖入封面的 drop 事件。
- 固定格式控件需有稳定尺寸，任何桌面窗口尺寸下文字、按钮和封面卡不得重叠或因动态内容跳动。

## 测试策略

修改范围与重点测试：

- 扫描边界/并发：`CoverDropTests/Integration/FileSystemLibraryScannerTests.swift`
- TagLib 标签：`CoverDropTests/Integration/TagLibMetadataReaderTests.swift`
- AppModel、实时刷新、封面保存、Ollama 队列：`CoverDropTests/Unit/AppModelImportTests.swift`
- 名称清洗：`AlbumNameCleaningTests.swift`、`AlbumDisplayNameCleaningTests.swift`、`AlbumNameEnhancementTests.swift`
- 快照：`SQLiteScanSnapshotStoreTests.swift` 和 `FileScanSnapshotStoreTests.swift`
- 封面图片链路：`ImageIOCoverDetectorTests.swift`、`ImageIOCoverImageWriterTests.swift` 及各缓存/拖拽单测。
- 封面墙布局：`FixedCoverGridLayoutTests.swift`。
- 封面墙快照与内联工作流：`AlbumCoverWallSnapshotTests.swift`。
- 本地/远程图片调度：`CoverThumbnailLoaderTests.swift`、`RemoteCoverPreviewLoaderTests.swift`、`RemoteCoverImageDataCacheTests.swift`。
- 性能日志与快照写队列：`CoverDropPerformanceLogTests.swift`、`ScanSnapshotUpdateQueueTests.swift`。

高价值性能回归用例包括：

- `FileSystemLibraryScannerTests.scansAlbumsWithBoundedConcurrency`
- `FileSystemLibraryScannerTests.imageFileCoverSkipsEmbeddedArtworkMetadataRead`
- `AppModelImportTests.realtimeRefreshRescansChangedAlbumsConcurrently`
- `AppModelImportTests.savingCoverInsideAppDoesNotTriggerRealtimeRefresh`
- `AlbumCoverWallSnapshotTests.snapshotsWithSameRevisionAreNotEqual`
- `CoverDropReceiverTests.receiverCallsAcceptedAfterImageDataIsStaged`
- `ScanSnapshotUpdateQueueTests.sameLibraryPreservesEveryPendingUpdate`

交付检查：

```shell
git diff --check
zsh Scripts/verify.sh
```

仅修改文档时可只运行 `git diff --check`，交付时说明未跑完整测试。测试失败必须先查明原因，不能通过删除测试、放宽断言或绕过生产路径掩盖。

## 修改纪律与后续方向

- 保持改动集中在请求涉及的模块；不要顺手重写 `LibraryScanSummaryView` 或 `AppModel`。
- 新增基础设施能力时先在 `Domain/Protocols` 定义边界，再由 `AppEnvironment` 装配并在测试中注入假实现。
- 涉及扫描、名称、快照或封面写入的行为变化，应先补回归测试再改实现。
- 用户确认代码达到要求后，更新本文件，使下一次 AI 接手时看到的是当前事实。

推荐后续方向：继续用真实目录样本提高扫描准确率；稳定名称清洗和手动 Ollama 工作流；建设“需确认”工作台；为 SQLite schema 增加明确迁移策略与确认结果持久化。性能相关改动应以 2026-07-14 基线为下限，先用结构化日志和主线程采样证明瓶颈，再决定是否扩大重构范围。
