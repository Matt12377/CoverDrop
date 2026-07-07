# CoverDrop UI 优化 — Codex 实现规格书

> 本文档是 HTML 原型的精确翻译，用于指导 Codex 一比一复刻到 SwiftUI 代码中。
> HTML 原型位于 `coverdrop-redesign-v3/pages/` 目录下，可直接用浏览器打开对照。

## 全局设计 Token

所有颜色值请定义为全局常量，方便后续统一调整：

```swift
// 在 AppConfiguration 或专门的 DesignTokens 中定义

enum DesignToken {
    // 背景色（已有深色模式可复用，以下为精确值）
    static let bgPrimary = Color(red: 30/255, green: 30/255, blue: 30/255)       // #1e1e1e
    static let bgSecondary = Color(red: 37/255, green: 37/255, blue: 37/255)      // #252525
    static let bgTertiary = Color(red: 45/255, green: 45/255, blue: 45/255)       // #2d2d2d
    static let bgElevated = Color(red: 58/255, green: 58/255, blue: 58/255)      // #3a3a3a

    // 文字色
    static let textPrimary = Color.white                                        // #ffffff
    static let textSecondary = Color(red: 160/255, green: 160/255, blue: 160/255)  // #a0a0a0
    static let textTertiary = Color(red: 110/255, green: 110/255, blue: 115/255)  // #6e6e73

    // 强调色
    static let accent = Color(red: 10/255, green: 132/255, blue: 255/255)         // #0a84ff
    static let accentBg = Color(red: 10/255, green: 132/255, blue: 255/255).opacity(0.12)

    // 状态色
    static let success = Color(red: 48/255, green: 209/255, blue: 88/255)        // #30d158
    static let successBg = Color(red: 48/255, green: 209/255, blue: 88/255).opacity(0.12)
    static let warning = Color(red: 255/255, green: 159/255, blue: 10/255)      // #ff9f0a
    static let warningBg = Color(red: 255/255, green: 159/255, blue: 10/255).opacity(0.12)
    static let destructive = Color(red: 255/255, green: 69/255, blue: 58/255)    // #ff453a
    static let destructiveBg = Color(red: 255/255, green: 69/255, blue: 58/255).opacity(0.12)

    // 边框
    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.15)

    // 圆角
    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 12

    // 阴影（macOS 原生风格）
    static let shadowCard = Color.black.opacity(0.3)
    static let shadowElevated = Color.black.opacity(0.5)
}
```

---

## 一、侧边栏与首页（sidebar-home.html）

> 对照原型文件：`coverdrop-redesign-v3/pages/sidebar-home.html`

### 1.1 侧边栏

**宽度**：220px（或使用 `.sidebarWidth` 系统默认）

**品牌区域**（顶部 padding 16px）：
- 图标：SF Symbols `music.note`，16px，`.accent` 色
- 文字："CoverDrop"，`.title3.bold()`，`.textPrimary`

**分区标题**："MUSIC LIBRARY"（大写），11px，`.textTertiary`，`tracking 0.5px`，padding-top 12px

**音乐库条目**（可复用组件 `LibraryListItem`）：
- 布局：HStack，icon(16px) + 文字 + 右侧计数 badge
- 高度：约 32px，padding 6px 8px，`cornerRadius(radiusSm)`
- 默认色：`.textSecondary`
- Hover：`bgTertiary`
- 选中态：`accentBg` 背景 + `.accent` 色
- 每个条目右侧有一个小彩色圆点（6px），区分不同库的身份
- 图标统一用 `folder.fill`

**底部**：设置按钮（齿轮 icon），`.secondary` 样式

**拖放目标态**：
- 整个内容区加 `border: 1px dashed borderStrong`，`padding` 增大
- 居中显示上传 icon + "拖入音乐文件夹" 文字

### 1.2 主内容区（扫描前状态）

**布局**：VStack 居中，`maxWidth 640px`

**图标区域**（关键优化点）：
- 一个圆形 `bgElevated` 背景（直径约 80px）
- 内部 `accentBg` 径向渐变发光效果（`radialGradient`）
- SF Symbols `externaldrive.fill`，28px，`.accent` 色
- 整体有轻微阴影

**库名称**：`.largeTitle.bold()`，`.textPrimary`，spacing 16px

**信息卡片**（新增）：
- 背景：`bgTertiary`，`border: 1px solid border`，`cornerRadius(radiusMd)`
- padding 16px，内容：
  - 行 1：label "目录角色" + value "音乐库"
  - 行 2：label "文件夹路径" + path（monospaced font，`.textSecondary`，truncate）
  - 行 3：label "上次扫描" + 日期

**操作按钮行**（spacing 12，居中）：
- "扫描音乐库"：`.borderedProminent`，accent 色
- "加载最近扫描结果"：`.bordered`，`.textSecondary`
- "移除"：纯文字链接，`.destructive` 色

**底部提示**：
- 小字："扫描会读取音频标签，但不会修改音乐文件。"，`.caption`，`.textTertiary`

---

## 二、封面墙（cover-wall.html）

> 对照原型文件：`coverdrop-redesign-v3/pages/cover-wall.html`

### 2.1 顶栏

**布局**：HStack，padding 12px 20px，`border-bottom: 1px solid border`

- 左侧：back chevron 按钮（28x28，`radiusSm`）+ 库名 title3 bold
- 右侧："返回音乐库" 按钮，`bgTertiary` 背景 + `borderStrong` 边框

### 2.2 统计行

**布局**：HStack，padding 8px 20px，`border-bottom: 1px solid border`

- 各统计项用 `stat-item`（HStack，gap 5px）：
  - "112 专辑"：数字 `.textPrimary`，文字 `.textTertiary`
  - "78 已有封面"：数字 `.success`
  - "34 缺封面"：数字 `.destructive`
  - "91 需确认"：数字 `.warning`
  - "0 散落音频"：数字 `.textPrimary`
- 各项之间用 1px 分隔线（`borderStrong`，高 12px）

### 2.3 筛选 + 搜索行

**布局**：HStack，padding 12px 20px，gap 12

- 左侧：`Picker` segmented 样式，5 个选项（全部/缺封面/需确认/已有封面/散落音频）
  - 背景：`bgTertiary`，`cornerRadius(radiusSm)`，内部 padding 2px
  - 选中项：`.accent` 色背景，白色文字，`cornerRadius 4px`，`shadow`
- 右侧：搜索框
  - 背景：`bgTertiary`，`border: 1px solid border`，`cornerRadius(radiusSm)`
  - placeholder："按歌手、专辑、路径或标签名筛选"
  - 左侧搜索 icon（14px，`.textTertiary`）
  - 聚焦时边框变为 `.accent`

### 2.4 专辑网格（核心改动）

**网格**：`LazyVGrid`，`adaptive(min: 168px, max: 168px)`，`spacing 16`

**卡片结构**（`AlbumCoverCard`）：

```
┌─────────────────────────┐
│                         │ ← 封面区：aspect-ratio 1:1
│   [封面图/缺封面占位]     │    overflow: hidden
│ [状态badge]              │    左上角 badge（绝对定位）
│              [⚠ icon]    │    右下角警告三角（条件显示）
│                         │
├─────────────────────────┤
│ 专辑名                  │ ← padding 8px 10px 10px
│ 歌手名                  │    专辑名：12px semibold
│ 路径                    │    歌手名：11px .textSecondary
└─────────────────────────┘    路径：10px .textTertiary
```

**卡片背景**：`bgTertiary`，`cornerRadius(radiusLg)`，`shadow`（0 2px 8px black 0.3）

**Hover 效果**：背景变为 `bgElevated`（不要 scale，保持原生 macOS 感）

**选中效果**：`outline: 2px solid .accent`，`outlineOffset: -2px`

**有封面卡片**：
- 封面图 1:1 填满容器
- 左上角 badge：`.success` 色，`successBg` 背景，`success` 边框，文字 "图片文件" + ✓ icon
- 格式标签（`[WAV]` `[DSD]`）：10px，`bgElevated` 背景，`textTertiary` 色

**缺封面卡片**：
- 背景：`bgPrimary`（更深色）
- 居中：music note icon（32px，`.textTertiary`）+ "缺封面" 文字（11px）
- 左上角 badge：`.destructive` 色，`destructiveBg` 背景

**需确认卡片**：
- 左上角 badge：`.warning` 色，`warningBg` 背景，"需确认" + ⚠ icon
- 右下角额外警告图标：20x20 圆形，`.warning` 背景，白色三角 icon，轻微阴影

---

## 三、专辑详情弹窗（album-detail.html）

> 对照原型文件：`coverdrop-redesign-v3/pages/album-detail.html`
> 实现：使用 `.sheet()` modifier，`idealWidth: 680`，`idealHeight: 520`

### 3.1 Sheet 背景

- 背景层：模糊的封面墙卡片（模拟），opacity 0.35
- 遮罩层：`Color.black.opacity(0.45)`
- Sheet 本身：`bgSecondary`，`cornerRadius(radiusLg)`，`shadow(elevated)`，`border: 1px solid borderStrong`

### 3.2 内容区（可滚动）

**顶部区域**：HStack，padding 24px，gap 24px

**左侧 — 封面**（200x200，`radiusMd`）：
- 使用 `AsyncImage` 或已有封面加载逻辑
- 右上角 "待保存" badge（`.accent` 背景，白色文字，10px，pill 形状）
- 如果没有封面，显示灰色占位 + music note icon

**右侧 — 信息区**：

**标题行**：
- 专辑名：18px bold，`.textPrimary`
- 信息 chips（HStack，gap 6）：
  - "1 个音频" chip：`accentBg` 背景，`.accent` 色，pill 形状，music note icon
  - "图片文件" chip：`successBg` 背景，`.success` 色
- "搜索封面" 按钮（accent 边框，`radiusMd`，位于标题右侧）

**分割线**：`border`，1px

**信息字段**（VStack，gap 8）：
- 搜索词：label(48px, `.textSecondary`) + value（truncate）+ 复制 icon 按钮
- 原始名：同上
- 路径：同上，monospaced font，11px，`.textSecondary`

**分割线**

**警告条**（条件显示）：
- 背景：`warningBg`，`cornerRadius(radiusSm)`
- ⚠ icon（16px，`.warning`）+ 文字 ".warning" 色

### 3.3 曲目区域

- `border-top: 1px solid border`，padding 12px 24px
- 标题 "曲目"：11px，`.textTertiary`，uppercase
- 整轨文件行：`bgTertiary` 背景，`radiusSm`，padding 8px 24px
  - 左：music note icon（32x32，`bgTertiary` 圆角方块）
  - 中：文件名 + "整轨文件" 副标题
  - 右：格式标签 "WAV"

### 3.4 底部操作栏

- `border-top: 1px solid borderStrong`，padding 16px 24px
- 左侧："在 Finder 中显示" 文字按钮，`.textSecondary`
- 右侧 HStack（gap 10）：
  - "返回封面墙"：bordered 按钮，`borderStrong` 边框
  - "保存封面"：主按钮，`.accent` 背景，白色文字，`radiusMd`

---

## 四、搜索封面弹窗（cover-search.html）

> 对照原型文件：`coverdrop-redesign-v3/pages/cover-search.html`
> 实现：使用 `.sheet()`，`idealWidth: 1100`，`idealHeight: 700`

### 4.1 整体布局

HStack（水平分割）：

**左侧 — 浏览器区域**（flex-1）：
- URL 栏：高度 40px，`bgTertiary` 背景
  - 后退/前进按钮（24x24）
  - 🔒 icon（`.success` 色，14px）
  - URL 文本（monospaced，`.textSecondary`，truncate）
  - 刷新按钮
- 下方：`WKWebView`（已有实现保留）

**右侧 — 控制面板**（320px，`bgSecondary`，`border-left: 1px solid border`）：

### 4.2 面板内容（从上到下）

**专辑信息区**（padding 16px，`border-bottom`）：
- HStack，gap 12
- 左：缩略图 56x56，`radiusMd`，右下角缺失 badge（16x16 圆形，`.warning` 背景，白色 ✕）
- 右：
  - 专辑名 14px bold，truncate
  - 歌手 12px，`.textSecondary`
  - 状态行：6px 圆点 + "当前封面：缺失"（`.warning`）

**搜索词区**（padding 12px 16px，`border-bottom`）：
- 标签 "搜索封面"（11px，`.textTertiary`，uppercase）
- HStack：
  - 关键词 pill（flex-1，`bgTertiary` 背景，`border`，`radiusMd`，monospaced）
  - 复制按钮（32x32，`borderStrong` 边框）

**拖放区域**（flex-1，居中）：
- 180x180 虚线边框区域，`borderStrong` dashed，`radiusLg`
- 内部：上传 icon（40px，`.textTertiary`）+ "拖入图片或点击选择" + "支持 JPG、PNG、WebP"
- Hover：边框变为 `.accent`，背景变为 `accentBg`

**搜索源 + 操作区**（padding 0 16px 12px）：
- Tab 行：底部 1px `border` 分割线
  - "豆瓣"（选中：`.accent` 色 + 底部 2px `.accent` 下划线）
  - "Bing" / "Google"（`.textSecondary`）
  - Tab 底部指示器用 `overlay` 的 `Rectangle` 实现
- "在浏览器中打开" 按钮：全宽，`borderStrong` 边框，32px 高

**底部操作栏**（padding 12px 16px，`border-top`）：
- 左："关闭" 文字按钮
- 右："返回详情保存" 主按钮（`.accent` 背景）

---

## 实现优先级

1. **定义 DesignToken**（全局颜色/圆角常量）
2. **封面墙网格卡片**（最高频，改卡片组件 + hover/选中效果）
3. **专辑详情 Sheet**（信息布局 + chips + 警告条）
4. **搜索封面 Sheet**（面板布局 + 拖放区 + tab 样式）
5. **侧边栏**（条目 hover/选中态 + 品牌区域）

## 不改动的部分

- WKWebView 的实际搜索逻辑
- 封面保存到文件系统的逻辑
- Ollama 名称增强逻辑
- 扫描逻辑和 AlbumScanRecord 数据模型
- `LibraryScanProgressView` 扫描进度视图
- `LibraryRoleConfirmationView` 角色确认视图

## 注意事项

- 所有改动都在 `CoverDrop/Features/LibraryHome/` 目录下
- 不要引入新的第三方依赖
- 保持 `Features` 只依赖 `Domain` 的架构约束
- 深色模式保持 macOS 系统跟随，不需要手动切换
- 不要修改文件系统写入逻辑（`Infrastructure/`）
