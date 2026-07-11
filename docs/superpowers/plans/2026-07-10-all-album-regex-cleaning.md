# 所有专辑统一正则清洗 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让有封面和无封面专辑都先经过同一套展示/搜索名称正则清洗。

**Architecture:** 移除 `AlbumDisplayNameCleaning.displayNames` 中对 `displayedCover` 的早退门禁，其余名称清洗、标签佐证和增强建议优先级保持不变。同步更新全库审计说明和项目约定。

**Tech Stack:** Swift 6、Swift Testing、zsh 全库审计脚本、Xcode 26。

## Global Constraints

- 只修改派生展示/搜索名称，不改真实音乐库和扫描快照。
- 不改变封面状态、缺封面筛选或 Ollama 调用时机。
- 不回滚共享工作区中其他会话的改动，不创建提交。

---

### Task 1: 用测试定义无封面清洗行为

**Files:**
- Modify: `CoverDropTests/Unit/AlbumDisplayNameCleaningTests.swift`

**Interfaces:**
- Consumes: `AlbumDisplayNameCleaning.displayNames(for:artistName:albumName:)`
- Produces: 无封面专辑也返回清洗后 `(artistName, albumName)` 的回归约束。

- [x] **Step 1: 把旧无封面测试改为期望清洗后的歌手名、专辑名和搜索词**
- [x] **Step 2: 单独运行 `AlbumDisplayNameCleaningTests`，确认因旧早退门禁而失败**

### Task 2: 移除封面门禁

**Files:**
- Modify: `CoverDrop/Domain/Policies/AlbumDisplayNameCleaning.swift`

**Interfaces:**
- Consumes: 现有纯规则与标签多数票逻辑。
- Produces: 不依赖 `displayedCover` 的统一展示名称结果。

- [x] **Step 1: 删除 `displayedCover == nil` 时返回原值的早退代码**
- [x] **Step 2: 运行名称清洗专项测试并确认通过**

### Task 3: 更新审计基线并完整验证

**Files:**
- Modify: `AGENTS.md`
- Modify: `docs/analysis/2026-07-10-library-filename-audit.md`

**Interfaces:**
- Consumes: `Scripts/audit_album_name_cleaning.sh` 的生产规则全库结果。
- Produces: 与新运行时行为一致的项目约定和覆盖率记录。

- [x] **Step 1: 运行全库审计，确认质量门禁通过且真实运行时变化数等于潜在变化数**
- [x] **Step 2: 更新项目约定与审计报告中的封面门禁说明和指标**
- [x] **Step 3: 运行 `git diff --check` 与 `zsh Scripts/verify.sh`，确认退出码为 0**
