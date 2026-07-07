# CoverDrop 项目级说明

本文件给新的 Codex 会话快速理解 CoverDrop 使用。所有项目沟通、总结、代码注释、日志和文档默认使用中文。

## 项目定位

CoverDrop 是一个 macOS SwiftUI 桌面应用，用来半自动整理音乐库专辑封面。

核心流程：

1. 用户添加一个音乐库、歌手目录或单张专辑目录。
2. App 扫描目录结构，识别歌手、专辑、音频文件、已有封面和异常情况。
3. 扫描完成后显示封面墙，优先处理缺封面和需确认专辑。
4. 用户打开专辑详情，查看路径、曲目、封面状态和搜索词。
5. 用户通过内置网页或外部浏览器搜索封面，把图片拖入 App。
6. App 把拖入图片暂存，用户点保存后写入对应专辑目录下的 `cover.jpg`。

重要原则：

- 文件夹层级优先，音频标签只作为核对和辅助。
- 扫描阶段只读取和分析，不修改音乐库。
- 写入真实音乐库只能通过专门基础设施服务，界面不得直接改文件。
- LLM 结果只能影响展示和搜索词，不影响扫描边界、真实路径和封面保存位置。

## 当前架构

主要目录：

- `CoverDrop/App`：应用入口、依赖装配、顶层状态。
- `CoverDrop/Domain`：业务模型、协议、纯规则。
- `CoverDrop/Infrastructure`：文件系统、TagLib、ImageIO、Ollama 等实现。
- `CoverDrop/Features/LibraryHome`：当前主要 UI，包含音乐库列表、封面墙、详情页和搜索页。
- `CoverDropTests`：单元测试和集成测试。
- `Scripts/verify.sh`：完整构建和测试脚本。

依赖方向：

- `Features` 可以依赖 `Domain`，不要直接依赖 TagLib、ImageIO、Ollama 或 SQLite。
- `Infrastructure` 实现 `Domain/Protocols` 中的协议。
- `AppEnvironment` 负责装配真实实现，测试通过假实现注入。
- 应用可调参数放在 `AppConfiguration`。

## 当前已实现能力

- 添加音乐库，自动建议目录角色：音乐库、歌手目录、单张专辑。
- 保存音乐库记录和安全书签。
- 按目录角色扫描专辑边界、散落音频、音频标签、已有图片封面、内嵌封面。
- 封面墙支持筛选：全部、缺封面、需确认、已有封面、散落音频。
- 专辑详情显示封面、路径、曲目、异常提示、搜索词。
- 内置搜索页支持豆瓣、Bing 图片、Google 图片，默认豆瓣。
- 本地或网页图片拖入后先暂存，保存后写入 `cover.jpg`。
- 已开始接入本地 Ollama 专辑名称增强：扫描后生成展示和搜索用歌手名/专辑名，原始扫描名仍保留。
- 音乐库侧边栏支持多选：单击单选、`Shift` 连选、`Cmd` 点选/取消、`Cmd + A` 全选。
- 音乐库侧边栏右键菜单支持全选、移除、重命名、重新扫描；批量移除只删除 CoverDrop 本地记录，不删除真实音乐文件。
- 实时刷新已改为局部刷新：外部文件变更只重扫受影响专辑目录，App 内保存封面会直接更新当前 UI，不走外部变更重扫。

## 扫描规则要点

核心文件：`CoverDrop/Infrastructure/FileSystem/FileSystemLibraryScanner.swift`。

当前应保持的行为：

- `role == .album`：导入目录本身是一张专辑，子目录如 `CD1`、`CD2` 不拆成新专辑。
- `role == .artist`：导入目录是歌手目录，子目录中的专辑应归并到真实专辑根。
- `role == .library`：第一层是歌手，第二层及以下识别专辑。
- 普通结构 `歌手/专辑/歌曲` 保持为一张专辑。
- 多碟结构 `专辑/CD1/歌曲`、`专辑/CD2/歌曲` 归并到 `专辑`。
- 纯数字碟目录 `专辑/01/歌曲`、`专辑/02/歌曲` 在同一父目录下有多个纯数字含音频兄弟目录时，也归并到父专辑。
- 格式层 `WAV`、`FLAC`、`DSD`、`DFF` 等归并到父专辑。
- 泛称容器 `album`、`albums`、`专辑` 以及合集/汇总/套装目录用于辅助识别专辑边界。
- `歌手/001/真实专辑/歌曲` 中的 `001` 是编号壳，不应被当成碟目录。
- `专辑/01 第一首/track.flac`、`专辑/02 第二首/track.flac` 是一首歌一个文件夹，应归并到共同专辑。
- 版本目录如 `港版`、`日本版` 不应静默合并，需标记为需要确认。

每次新增扫描规则，必须同时增加正例和反例测试，避免规则互相误伤。

## 扫描性能要点

当前初次建库和局部刷新都围绕减少重复 I/O 优化：

- 默认专辑扫描并发为 `8`，上限 `24`，配置在 `AppConfiguration.Scan`。
- `role == .library` 时，歌手目录发现阶段会并发执行，但结果仍按路径排序，避免 UI 顺序随机跳动。
- 目录发现阶段会保留已找到的音频 URL，后续扫描专辑时复用，避免“发现专辑递归一次、扫描专辑再递归一次”。
- `role == .album` 的单专辑导入也复用第一次递归得到的音频列表。
- 封面检测先扫描专辑目录内图片；如果已经找到有效图片封面，读取音频标签时跳过内嵌 artwork 抽取。
- 只有没有有效图片封面时，才允许 `TagLibMetadataReader` 通过 AVFoundation 提取音频内嵌封面。
- 如果目录内常见封面名图片损坏，仍会继续尝试内嵌图，并记录 `invalidNamedCovers` 问题。

性能相关回归测试重点：

- `FileSystemLibraryScannerTests.scansAlbumsWithBoundedConcurrency`
- `FileSystemLibraryScannerTests.imageFileCoverSkipsEmbeddedArtworkMetadataRead`
- `AppModelImportTests.realtimeRefreshRescansChangedAlbumsConcurrently`
- `AppModelImportTests.savingCoverInsideAppDoesNotTriggerRealtimeRefresh`

## Ollama 名称增强边界

本地 LLM 第一阶段目标：

- 扫描完成后自动调用 Ollama。
- 根据路径、原始歌手名、原始专辑名、前若干首曲目和标签，生成展示用 `artistName` 与 `albumName`。
- 封面墙、详情主标题、搜索词优先使用增强名。
- 详情页仍保留原始扫描名和路径，方便排查。
- 失败时中文警告，回退原始扫描名。

默认配置：

- `baseURL = "http://localhost:11434"`
- `model = "qwen3:14b"`
- `stream = false`
- 输出必须是严格 JSON：`{"artistName":"...","albumName":"..."}`

禁止：

- 不要让 LLM 决定专辑边界。
- 不要让 LLM 改真实目录、音频标签或 `cover.jpg` 保存位置。
- 不要把 LLM 输出写入音乐文件。

## UI 现状

主要文件：

- `CoverDrop/Features/LibraryHome/LibraryHomeView.swift`：音乐库侧边栏、主页面、扫描入口、音乐库多选和右键菜单。
- `CoverDrop/Features/LibraryHome/LibraryScanSummaryView.swift`：封面墙、专辑详情、搜索页。

当前 UI 还没有拆成 `CoverWall`、`AlbumDetail`、`Anomalies` 多个 feature 目录，大量封面墙和详情页代码仍集中在一个文件里。做大改前先规划拆分边界，避免顺手重构影响功能。

音乐库列表交互约定：

- `selectedLibraryID` 仍表示详情区当前显示的单个音乐库。
- 侧边栏多选状态在 `LibraryHomeView` 内维护，不进入 `AppModel`。
- 多选菜单里的移除和重扫通过 `AppModel.removeLibraries(ids:)`、`AppModel.scanLibraries(ids:)` 执行。
- 重命名只允许单选目标，写回 `LibraryRecord.displayName`，不修改真实目录名。
- 正在扫描的音乐库禁止移除，避免扫描状态和监听状态损坏。

搜索页当前设计：

- 左侧是 `WKWebView`。
- 右侧是搜索源、专辑信息、封面预览、拖图区域和返回按钮。
- 图片拖入封面方块后自动回到详情页，仍需用户点保存才写入 `cover.jpg`。

## 验证要求

代码改动交付前默认运行：

```shell
git diff --check
zsh Scripts/verify.sh
```

如果只是新增或修改文档，可至少运行 `git diff --check`，并在交付时说明未跑完整测试的原因。

`Scripts/verify.sh` 使用独立 DerivedData 执行 clean test。失败必须先修复再交付。

## 并行会话和工作区注意事项

这个项目经常由多个 Codex 会话并行修改同一个工作区。开始实干前必须先看：

```shell
git status --short
```

规则：

- 不要回滚用户或其它会话已有改动。
- 不要使用 `git reset --hard` 或 `git checkout --` 清理工作区。
- 如果需要新实现会话，优先使用 `create_thread`，不要 fork，除非用户明确同意。
- 主会话负责架构判断和任务拆分；新会话只按明确边界实干。
- 如果发现别的会话正在改同一文件，先暂停并向用户说明冲突风险。

## 下一阶段方向

优先级建议：

1. 继续提高扫描准确率，沉淀真实目录样本和回归测试。
2. 稳定 Ollama 名称增强，让模型只做展示和搜索辅助。
3. 做“需确认”工作台，允许用户确认、合并或拆分扫描结果。
4. 扫描结果持久化，避免重启后重复扫描。

不要过早做持久化：扫描规则和 LLM 展示增强还在快速迭代时，持久化错误结果会扩大问题。
