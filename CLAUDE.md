# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> 用户文档在 [README.md](README.md)。这里只写给 Claude / AI agent 的项目上下文。

---

## 项目性质

**terrasync-harness 不是 Cargo workspace**，是把 5 个独立 git 仓库聚到同一目录共享工具链/脚本/AI 上下文的 polyglot harness。

5 个子仓库各自独立 git、独立编译、独立发布：

```
terrasync-rs   主编排引擎（自身是 cargo workspace）
data-mover-rs  数据搬运
smb-rs         SMB 协议（自身是 cargo workspace，多 crate）
nfs-rs         NFS v3/v4.1（WASM component）
scheduler-rs   任务调度
```

跨仓库 git 依赖（通过 git URL，不是 path）：

```
terrasync-rs   ──→ nfs-rs
data-mover-rs ─┬─→ nfs-rs
               └─→ smb-rs::smb crate
```

`terrasync-rs`、`data-mover-rs`、`smb-rs`、`nfs-rs` **各自有自己的 CLAUDE.md**——改它们时优先读那个仓库的 CLAUDE.md（`scheduler-rs` 暂无）。

---

## 不要回退的架构决策

### 1. 根 `Cargo.toml` 是"空 workspace + exclude"

```toml
[workspace]
members = []
exclude = ["terrasync-rs", "data-mover-rs", "smb-rs", "nfs-rs", "scheduler-rs"]
```

只是个**隔离垫片**——防止 Cargo 从没有 `[workspace]` 的子仓库（`data-mover-rs`/`nfs-rs`/`scheduler-rs`）向上回溯时误把 harness 当成包裹 workspace。**不要往 `members` 加东西**，也**不要在 harness 根目录跑 `cargo build`**。

### 2. 跨仓库本地联调用 `[patch]`，不用 path

要让 `terrasync-rs` 临时用本地 `nfs-rs`，在 **terrasync-rs 的 `Cargo.toml`** 末尾加：

```toml
[patch."https://github.com/JayTsu-sh/nfs-rs.git"]
nfs-rs = { path = "../nfs-rs" }
```

这是**单仓库内的开发期开关**，发 PR 前必须移除。不要把 path 依赖提到 main——会破坏其他人独立 clone 该仓库的能力。

### 3. CI 暂时不做

会私有化部署（Gitea Actions / GitLab CI / Drone / Jenkins 之类）。**不要**自动生成 `.github/workflows/`。

### 4. 部署目标 Rocky Linux 9.4（RHEL 9 系，`dnf` 不是 `apt`）

本地开发者通常用 WSL Rocky 或同等容器。写 Linux 命令默认按 `dnf` 来。

### 5. 工具链 pin 在 Rust 1.95.0

[rust-toolchain.toml](rust-toolchain.toml) 锁版本，rustup 在 harness 任意子目录都会自动切到这个版本。改版本要同步评估对 5 个子仓库的影响。

> 历史：最初 pin 在 1.85.0，但 `data-mover-rs` 的 AWS SDK 传递依赖要 ≥1.91，`scheduler-rs` 源码用了 let-chains（≥1.88），`terrasync-rs` 传递依赖也要 ≥1.89，于是统一升到 stable 1.95.0。

### 6. 行尾强制 LF（Windows ↔ Linux 都一致）

- harness 自己用 [.gitattributes](.gitattributes) 强制 `* text=auto eol=lf`，二进制类型显式标 binary。
- 5 个子仓库各自是独立 git 仓，它们的 `.gitattributes` 归各自 maintainer 管——harness 不去 PR 那些仓。
- 兜底：[scripts/bootstrap.sh](scripts/bootstrap.sh) 和 [scripts/bootstrap.ps1](scripts/bootstrap.ps1) 在 clone/pull 每个子仓库之后，会写入 `core.autocrlf=false` 和 `core.eol=lf` 到该子仓库的本地 `.git/config`（不影响 tracked 内容），防止 Windows checkout 时把 LF 转成 CRLF。
- 已经被 CRLF 污染的工作目录修复方法：跑 bootstrap 把 config 落下来，然后 `git -C <repo> checkout -- .`（确认 `git diff --ignore-space-at-eol` 无真实差异后再做）。

---

## 常用命令

跨平台 [`just`](justfile)（Windows PowerShell + Linux/WSL bash 都跑得通）。harness 根目录运行：

| 命令 | 作用 |
|------|------|
| `just bootstrap` | clone/更新 5 个子仓库（幂等，`git pull --ff-only` 或 clone） |
| `just build` | 每个子仓库 `cargo build --all-targets` |
| `just test` | 每个子仓库 `cargo test --all-features` |
| `just check` | `cargo fmt --check` + `cargo clippy -D warnings`（提交前） |
| `just fmt` | 格式化所有子仓库 |
| `just clean` | 每个子仓库 `cargo clean` |
| `just status` | 5 个子仓库各自 `git status -sb` |
| `just in <repo> <cmd>` | 在指定子仓库跑任意命令，例：`just in nfs-rs cargo build` |

不装 just 时直接调脚本：`./scripts/for-each.sh <cmd>` 或 `.\scripts\for-each.ps1 <cmd>`。

**对单个仓库做事**：`cd <repo> && cargo <something>`，**不要在 harness 根跑 cargo**。

**跑单测**：在对应子仓库内 `cargo test <name>` 或 `cargo test --test <integration>`，具体走该仓库的 CLAUDE.md。

**`for-each` 在第一个失败时立刻退出**——想看全部失败而不停在第一个，得自己 `cd` 进每个仓库分别跑。

---

## 工作约定

1. **改哪个子仓库就 `cd` 进去操作**，不在 harness 根跑 cargo。
2. **每个子仓库的 commit/PR 独立**，不尝试一次 commit 跨多个子仓库。
3. **跨仓库改 API**：先在被依赖方（如 `nfs-rs`）改完测好、发 tag；调用方（如 `terrasync-rs`）再升级 git 依赖版本。本地联调期间用 `[patch]`（见决策 #2）。
4. **新增共享依赖**：每个用到的子仓库自己加，不在 harness 集中管。
5. **rustfmt/clippy 默认在 harness 根**（[rustfmt.toml](rustfmt.toml) / [clippy.toml](clippy.toml)），子仓库没有自己的配置就继承 harness 的。
6. **不要恢复 CI**——见决策 #3。
7. **不要把 harness 改回 cargo workspace**——见决策 #1。
8. **Linux 命令默认按 Rocky 9.4 (`dnf`) 写**，不是 apt。

---

## 各子仓库的 harness 视角注意点

| 子仓库 | 注意 |
|--------|------|
| **terrasync-rs** | 自身是 cargo workspace；在它根跑 `cargo build` 会编它内部所有 crate |
| **data-mover-rs** | 普通 crate，git URL 依赖 `nfs-rs` 和 `smb-rs::smb`；test 代码有几个 `unused_variable` warning 待清 |
| **smb-rs** | virtual workspace（无 `[package]`），含多个内部 crate；外部引用的是其中的 `smb` crate |
| **nfs-rs** | WASM component (`[package.metadata.component]`)。普通 `cargo build` 目前能过；若要产出真正的 WASM artifact 仍需 `cargo install cargo-component` 后用 `cargo component build` |
| **scheduler-rs** | 3 个 example（`http_api` / `remote_http` / `job_loader`）通过 `required-features` 在默认 build 时被跳过；`remote_http` 还有一处 API 漂移（`SchedulerBuilder::remote_executor` 已不存在）未修，开启 `remote-http` feature 时仍会编不过 |

---

## 已知问题 / 待办

- `scheduler-rs::examples::remote_http.rs` 调用了已经不存在的 `SchedulerBuilder::remote_executor`，开 `remote-http` feature 时仍编不过——目前只通过 `required-features` 在默认构建里规避，没修真问题。
- Windows 偶发 `os error 1224`（"用户映射区域文件锁"），cargo 写 fingerprint 失败——杀软扫描或文件句柄延迟释放导致，重试即可，不是代码 bug。
- `data-mover-rs` 的 `src/s3.rs:3095/3103/3111/3119` 有 4 个 `unused_variable` warning（test 代码），还没清。

---

## 历史背景

harness 的当前形态是几轮迭代后的稳定结果：

1. 最初尝试 Cargo workspace + path 依赖 → 失败（子仓库自带 workspace，Cargo 拒绝嵌套）
2. 尝试 GitHub Actions matrix CI (Ubuntu + Windows) → 改成 Rocky 9.4 容器 → 决定先去掉、私有化部署再做
3. justfile 最初用 bash 循环 → Windows PowerShell 解析失败 → 改成 `[unix]/[windows]` 双 recipe + 跨平台 `for-each` 脚本
4. 工具链从 1.85.0 升到 1.95.0（见决策 #5）
