---
description: 跨 harness + 5 子仓库拉 open issues，分类后输出 Markdown triage 报告（只读，不动手）
argument-hint: "[repo-name]  可选：只 triage 单个仓库（去 owner 前缀，例：nfs-rs）"
---

跨 6 个 GitHub 仓库收集并分类 open issues，产出一份 Markdown triage 报告。

## 范围

默认全 6 个（owner = `JayTsu-sh`）：

- `terrasync-harness`
- `terrasync-rs`
- `data-mover-rs`
- `smb-rs`
- `nfs-rs`
- `scheduler-rs`

如果用户传了 `$ARGUMENTS`，只处理该参数指定的那一个（去 owner 前缀，比如 `nfs-rs` 而不是 `JayTsu-sh/nfs-rs`）。

## 步骤

### 1. 抓数据（并行）

对每个目标仓库执行：

```
gh issue list --repo JayTsu-sh/<name> --state open --limit 100 \
  --json number,title,labels,createdAt,updatedAt,author,comments,url
```

**多个仓库时在同一条消息里发多个 Bash 调用并行执行**，不要串行。

### 2. 分类维度

逐条 issue 按这几个维度归类：

- **类型** — bug / feature / question / chore / 其他
  - 优先看 labels，没明确 label 则按标题/正文关键字推断
- **严重度** — blocker / high / medium / low
  - `blocker` = labels 含 `blocker`/`critical`，或正文明确写"无法编译/启动/运行"
  - `high` = `bug` + labels 含 `priority:high`/`p0`/`p1`，或评论数 ≥ 3 且 7 天内更新
  - `medium` = 普通 `bug`
  - `low` = `enhancement`/`question`/`documentation`/`good first issue`
- **新鲜度** — 基于 `updatedAt`
  - `fresh` < 7 天 / `active` < 30 天 / `stale` < 90 天 / `cold` ≥ 90 天
- **跨仓影响** — 正文/评论里提到其他 sister repo 名字时标记 `cross-repo: <名字>`
  - 已知依赖图：`terrasync-rs → nfs-rs`、`data-mover-rs → nfs-rs, smb-rs(smb crate)`
  - 改一个仓库的 API 时上游也得动 → 重点标记

### 3. 输出格式

直接输出到对话（**不写文件**）。结构：

```markdown
# Issue Triage — YYYY-MM-DD

## 总览
| Repo | Open | Blocker | High | Medium | Low | Stale |
|------|------|---------|------|--------|-----|-------|
| ... | N | B | H | M | L | S |

## Blocker / High（按优先级）
- **[repo#123](url)** _title_ — 一句话诊断（≤ 30 字）
  - labels: `bug`, `priority:high`
  - 更新: 3d ago · 评论: 5
  - cross-repo: nfs-rs（API 改动会牵连 terrasync-rs）

## Medium
（同上结构，更紧凑）

## Quick wins（如果有）
> 看着 < 30 分钟可修的小问题。**不动手**，只列出来供决策。
- [repo#456](url) typo in README — 直接 PR 即可

## Low / Stale（折叠摘要）
- terrasync-rs: 3 stale `enhancement` → 见仓库 issue 页
- ...
```

## 边界（硬约束）

- **只读**：不评论 issue、不改 label、不开 PR、不 close、不 reopen。
- 任何想"顺手处理"的冲动都要让位给报告本身——后续要不要动手由你拍板。
- 6 个仓库全 0 open issue 时，直接输出 `全 0 ✅` 就行，不要硬凑内容。
- 如果某个仓库 `gh issue list` 失败（404 / 权限不够），单独标注 "⚠️ skipped: <reason>"，继续处理其他仓库，不要终止。

## 调用 gh 时

- 已安装并 auth 完毕（`gh auth status` 应该是 `Logged in as herenke`）。
- 用 `--json` 输出，解析 JSON 比正则刮文本可靠得多。
- 不要用 `gh issue view`（每条一次往返太慢），靠 `gh issue list --json comments` 一次拉全。
