# Terrasync Harness

这是 Terrasync 项目的 **polyglot harness（项目根，不是 Cargo workspace）**。

为什么不是 Cargo workspace？因为子仓库里 `terrasync-rs` 和 `smb-rs` **本身已经是 Cargo workspace**，Cargo 不允许 workspace 嵌套；而且子仓库间已经通过 git URL 互引，不依赖外层 workspace。所以 harness 的角色定位是：**统一开发环境、共享工具链/CI/脚本/Claude 上下文**——但每个子仓库各自独立编译、独立发布。

5 个独立仓库：

| 仓库 | 职责 |
|------|------|
| [terrasync-rs](https://github.com/JayTsu-sh/terrasync-rs) | 主编排引擎（内部 workspace） |
| [data-mover-rs](https://github.com/JayTsu-sh/data-mover-rs) | 数据搬运 |
| [smb-rs](https://github.com/JayTsu-sh/smb-rs) | SMB 协议（内部 workspace，多 crate） |
| [nfs-rs](https://github.com/JayTsu-sh/nfs-rs) | NFS v3 / v4.1 客户端（WASM component） |
| [scheduler-rs](https://github.com/JayTsu-sh/scheduler-rs) | 任务调度 |

依赖图（已存在的 git 依赖）：

```
terrasync-rs   ─→ nfs-rs
data-mover-rs ─┬→ nfs-rs
               └→ smb-rs (smb crate)
```

---

## 新成员上手（3 步）

### 1. 装好工具链

- [rustup](https://rustup.rs/) — harness 根目录的 `rust-toolchain.toml` 会让 rustup 自动切到 1.85.0
- Git
- 可选：[just](https://github.com/casey/just) — 跨仓库命令编排
- 可选：[cargo-component](https://github.com/bytecodealliance/cargo-component) — 给 nfs-rs 用（WASM component）

### 2. Clone harness

```bash
git clone https://github.com/JayTsu-sh/terrasync-harness.git
cd terrasync-harness
```

### 3. 跑 bootstrap 拉所有子仓库

**Windows (PowerShell):**
```powershell
.\scripts\bootstrap.ps1
```

**macOS / Linux / WSL:**
```bash
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

SSH 而非 HTTPS：
```bash
TERRASYNC_PROTO=ssh ./scripts/bootstrap.sh
```

脚本幂等：已存在的仓库 `git pull --ff-only`，否则 clone。

### 4. 验证

```bash
just build      # 在每个子仓库里跑 cargo build
just test       # 在每个子仓库里跑 cargo test
```

---

## 常用命令（justfile orchestrator）

```bash
just            # 列出命令
just bootstrap  # 拉/更新所有子仓库
just build      # 遍历每个子仓库 cargo build
just test       # 遍历每个子仓库 cargo test
just check      # fmt --check + clippy（提交前）
just fmt        # 一键格式化所有子仓库
just status     # 5 个子仓库各自 git status
just in nfs-rs cargo build   # 在指定子仓库跑命令
```

不装 just 也行，直接 `cd` 进每个子仓库跑标准 cargo 命令。

---

## 跨仓库本地联调（按需）

例：开发 `nfs-rs` 改了 API，想让 `terrasync-rs` 立刻用上本地版本而不是远端 git。在 **terrasync-rs 自己的 `Cargo.toml`** 末尾加：

```toml
[patch."https://github.com/JayTsu-sh/nfs-rs.git"]
nfs-rs = { path = "../nfs-rs" }
```

这是单仓库内的开发期开关，**不要提交到 main**——发 PR 前移除，等 `nfs-rs` 发了新 tag 再升级 git 依赖版本。

---

## 目录结构

```
terrasync-harness/          ← 项目根（不是 Cargo workspace）
├── rust-toolchain.toml     ← 锁 Rust 1.85.0（rustup 向上查找）
├── rustfmt.toml            ← 默认风格（子仓库可覆盖）
├── clippy.toml             ← 默认阈值（子仓库可覆盖）
├── justfile                ← 跨仓库 orchestrator
├── .gitignore              ← 忽略 5 个子仓库目录
├── README.md
├── scripts/
│   ├── bootstrap.ps1       ← 拉/更新子仓库（Windows）
│   ├── bootstrap.sh        ← 拉/更新子仓库（Linux/WSL）
│   ├── for-each.ps1        ← 在每个子仓库依次执行命令（Windows）
│   └── for-each.sh         ← 在每个子仓库依次执行命令（Linux/WSL）
├── terrasync-rs/           ← 独立 git repo，本身是 workspace
├── data-mover-rs/          ← 独立 git repo
├── smb-rs/                 ← 独立 git repo，本身是 workspace
├── nfs-rs/                 ← 独立 git repo（WASM component）
└── scheduler-rs/           ← 独立 git repo
```

> 5 个子仓库在 harness 的 `.gitignore` 里，不会被 harness 跟踪。

---

## 日常工作流

- **写代码**：在子仓库里改，独立 commit/PR 到对应 GitHub repo
- **跨仓库联调**：用 `[patch]` 把 git 依赖临时指向本地路径
- **同步更新**：`just bootstrap` 拉所有仓库最新代码
- **用 Claude Code**：在 `terrasync-harness/` 根目录启动 `claude`，让它一次看到所有 5 个仓库
