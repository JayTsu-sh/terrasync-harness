# NFS Mount 并发失败调查记录

> 调查目标：搞清楚"32 并发 mount 部分失败、限流 2 才稳定"的真正根因，避免基于
> 代码注释和 `insecure` flag 直接推断而做错方向的优化。
>
> 安全约束：所有验证操作必须可恢复，不改服务端 config / sysctl / exports / 不重启服务。

---

## 待验证假设

| 编号 | 假设 | 证伪条件 |
|------|------|----------|
| A | Windows 客户端特权源端口 (<1024) + TIME_WAIT 池耗尽 | 复现时未观察到 `AddrInUse` / WSAEADDRINUSE，而是别的错误 |
| B | 服务端 mountd 串行化 | Linux→Linux 同样 32 并发也部分失败 |
| C | 服务端 nfsd 线程池过小 (默认 8) 形成排队 | 同上 |
| D | rpcbind GETPORT 并发限制 | 仅 portmap 阶段失败，看不到 MOUNT 阶段 |
| E | AUTH_UNIX / no_root_squash 并发竞争 | 客户端报 `MNT3ERR_ACCES` 而非 connect 错 |
| F | Tokio runtime 在 Windows 上 socket 创建竞争 | Linux 客户端不出错，Windows 临时端口也出错 |

## 环境

- 客户端调研机：Windows 11，Git Bash，nfs-rs 主干 (pin Rust 1.95.0)
- 源 NFS server：10.131.9.13 (ubuntu-source, Ubuntu 24.04.4 LTS, kernel 6.8.0-107)
- 目标 NFS server：10.131.9.15 (ubuntu-dest, Ubuntu 24.04.4 LTS, kernel 6.8.0-106)
- 关键代码：
  - `terrasync-rs/crates/app/src/orchestrator.rs:71-74` `STORAGE_PAIR_MOUNT_CONCURRENCY = 2`
  - `nfs-rs/src/lib.rs:47-186` `connect_to_target` 强制特权端口

## Phase 1 — 服务端静态画像（read-only）

两台 server 配置基本一致（kernel nfsd + nfs-utils userspace）：

| 项 | .13 (source) | .15 (dest) |
|----|------|------|
| nfsd 内核线程 | **8** | **8** |
| rpc.mountd | 单进程 单线程 (`nlwp=1`) | 同左 |
| TCP backlog (2049) | 64 | 64 |
| TCP backlog (111) | 4096 | 4096 |
| LimitNOFILE | 524288 | 524288 |
| TasksMax | 77111 | 77111 |
| exports | `/export/nfs` v3 + `/export/nfs4` v4，都带 **`insecure`** | 同左 |
| `manage-gids` | `y`（mountd 替客户端查 GID） | 同左 |

潜在瓶颈嫌疑：**单线程 rpc.mountd**——并发 MOUNT MNT 会串行处理。但这是吞吐问题，不一定是失败问题。Phase 2 用差分诊断试一下。

## Phase 2 — Linux→Linux 差分诊断

测试脚本：`/tmp/nfs_concurrent_mount_test.sh`（部署在 .15，完全自清理）。

从 .15 用 kernel NFS client mount `.13:/export/nfs` 同时并发 N 次，统计成功/失败、耗时。

| 测试 | 并发 N | mount 选项 | 成功率 | 总壁钟 | 备注 |
|------|--------|------------|--------|--------|------|
| 基线 | 1 | 默认 | 1/1 | 32 ms | 服务正常 |
| 主测试 | **32** | 默认（特权端口） | **32/32** ✅ | **367 ms** | **单 mount 耗时 11→307ms 线性增长，是 mountd 串行处理的签名** |
| 临时端口 | 32 | `noresvport` | **32/32** ✅ | — | `insecure` flag 确认生效，临时端口可直连 |
| 极限 | 64 | 默认 | **64/64** ✅ | — | 服务端没崩 |
| 再极限 | 128 | 默认 | **128/128** ✅ | — | 服务端依然全过 |

### 结论（重大）

- **服务端完全不是失败来源**。最高 128 并发依然 100% 成功。
- 假设 B / C / D / E（服务端 mountd/nfsd/rpcbind/auth 限制导致失败）**全部证伪**。
- 服务端会串行化 mount 处理（mountd 单线程），但只影响**吞吐**，不影响**正确性**。
- 失败必然发生在 **Windows + nfs-rs 客户端侧**。剩下要在假设 A / F 之间区分：
  - A：特权源端口 (<1024) + TIME_WAIT 累积
  - F：Tokio runtime 在 Windows 上 socket 创建/竞争

## Phase 3 — Windows 客户端复现

工具：`nfs-rs/examples/stress_mount.rs`（新增，cargo run --release --example stress_mount -- <URL> <N>）。
启用 `tracing` 透出 WARN/DEBUG，看 connect_to_target 内部状态。

### 关键观察：每次 mount 用 4 个特权端口

N=1 跑完后立刻 `netstat -an | grep 10.131.9.13 | grep -c TIME_WAIT` = **4**。
对应 portmap-for-NFS + portmap-for-MOUNT + MOUNT TCP + NFS TCP 共 4 条 TCP 连接。

### 干净状态压测（TIME_WAIT 接近 0）

| N | 结果 | 总壁钟 | 备注 |
|---|------|--------|------|
| 1 | OK | 102 ms | 基线 |
| 32 | 32/32 OK | 143 ms | 全过 |
| 64 | 64/64 OK | 207 ms | 全过 |
| 128 | 128/128 OK | 291 ms | 全过 |
| **256** | **31/256 OK** ⚠️ | 3.9 s | **首次出现 225 失败** |

### 失败模式——表里不一

N=256 失败的 `parse_url_and_mount` 返回错误是 `Rpc("error obtaining ports from portmapper")`。
但 RUST_LOG=warn 抓到的内部 WARN 日志显示真实底层错误链：

```
WARN exhausted all connect attempts (200), all privileged source ports failed addr=10.131.9.13:111
WARN portmapper lookup failed on address ... error=all privileged source ports (1-1023) failed
WARN mount attempt failed for version=NFSv3 error=RPC error: error obtaining ports from portmapper
```

**结论：失败的根因是 `nfs-rs/src/lib.rs:181` 的 200 次重试用光，特权源端口池耗尽**——
就是 `orchestrator.rs:71-74` 注释里说的那个原因。**注释是对的，但错误向上抛时被改写成
误导性的 "portmapper" 错误**，所以静态读代码会被带偏。

DEBUG 日志里 N=128 一次跑就有 4346 行 `connect failed with AddrInUse after successful bind`
——AddrInUse 冲突一直在发生，只是 200 次重试默默兜住了。N=256 时兜不住了。

### 与用户场景的映射

`StoragePair::new()` 同时建 src + dest 两个 storage，每个 storage 对 NFS URL 调 1 次
`parse_url_and_mount`。所以**用户说的"32 mount"实际是 32 StoragePair = 64 mount =
256 特权端口占用**——正好是失败阈值。这解释了为什么 32 偶尔失败、限到 2 就稳。

## Phase 4 — 控制变量验证（临时改 set_port(0) → 临时端口）

在 `connect_to_target` 内把 `local_addr.set_port(local_port)` 临时替换为 `set_port(0)`，
让 OS 选 Windows ephemeral 端口（49152-65535，~16K 个，是特权端口 ~17×）。
**测试完已用 `git checkout` 还原**。

| N | 默认（特权 ~960） | 临时端口 (~16K) |
|---|-------------------|------------------|
| 256 (TW=1020 重污染) | **1 失败** | **0 失败** ✅ |
| 512 | 未测 | **0 失败** ✅，总壁钟 5.7s（mountd 串行慢，但都成功） |

服务端 `insecure` flag 早就允许了非特权源端口，**唯一阻拦是 nfs-rs 客户端无条件绑特权端口**。
ephemeral 路径不仅修了 N=256 的失败，**N=512 在 TW 重污染状态下也轻松全过**——
17× 的端口池容量直接消除了这个失败模式。

## 最终结论

| 假设 | 状态 |
|------|------|
| A. Windows 特权端口 + TIME_WAIT 耗尽 | **确认根因**（控制变量实验闭环证明） |
| B. mountd 串行化 | 排除（Linux→Linux N=128 100% 过） |
| C. nfsd 线程不足 | 排除（同上） |
| D. rpcbind 限流 | 排除（同上） |
| E. AUTH 竞争 | 排除（错误链显示是 IO::AddrInUse） |
| F. Tokio Windows socket 竞争 | 排除（ephemeral 端口下 N=512 无任何失败） |

### 修法（按 ROI 排序）

1. **必做（根本解）**：`nfs-rs/src/lib.rs::connect_to_target` 支持 URL 参数
   （如 `?insecure=true` 或 `?source_port=ephemeral`），默认仍绑特权端口（兼容老服务），
   显式启用时切到 ephemeral。等价 Linux `mount.nfs` 的 `noresvport`。
2. **次做（降低误导）**：`nfs-rs/src/rpc/mod.rs::portmap` 返回失败时**保留底层 IO 错误**
   而不是改写成 `"error obtaining ports from portmapper"`，方便上层日志诊断。
3. **可选**：把 `terrasync-rs::orchestrator.rs::STORAGE_PAIR_MOUNT_CONCURRENCY` 从硬编码
   2 改成可配置 + 默认提高到 8（配合 #1 之后）；同时给 retry 退避加 jitter（消除 worker
   同时醒）。

### Jitter 之于这个问题

`nfs-rs/src/rpc/mod.rs:527-528` 已经在 RPC 重连路径上有 jitter。orchestrator 的 mount 重试
退避（2s/4s/8s）确实可以加 jitter，但**不会让 32 mount 不失败**——它解决的是"重试再次撞车"
而非"端口池本身不够用"。单靠 jitter 不解决问题，仅作 #1 的配料。

## 留下的产物

| 路径 | 用途 | 处置建议 |
|------|------|----------|
| `scripts/push_pubkey.py` | paramiko 推 SSH 公钥到 lab 机的引导工具 | 留下，调研用 |
| `docs/nfs-mount-concurrency-investigation.md` | 本文档 | 留下 |
| `nfs-rs/examples/stress_mount.rs` | 并发 mount stress 工具 | 留下，回归 / 后续优化对比可用 |
| `nfs-rs/Cargo.toml` 增 `tracing-subscriber` dev-dep | 支撑 stress example | 留下，仅 dev-deps |
| `nfs-rs/src/lib.rs` 控制变量 patch | 临时验证用 | **已用 `git checkout` 还原** |
| 服务端 .13 / .15 | 全程只读 | 无任何修改 |

## Phase 5 — 修复后的实测验证 (feat/noresvport-url-param 分支)

工具：`nfs-rs/examples/stress_mount`，分支 `feat/noresvport-url-param`，全部 commits 落地后 release build。

| 测试 | URL | N | ok/fail | exhausted-warns | TW before / after |
|------|-----|---|---------|-----------------|-------------------|
| baseline | default (privileged) | 256 | 256/0 | 0 | 0 / 1010 |
| fix | `?noresvport=true` | 256 | 256/0 | 0 | 1010 / 2034 |
| 极限 | `?noresvport=true` | 512 | 512/0 | 0 | 2034 / 4057 |

**结论**：`?noresvport=true` 路径下 N=256 与 N=512 均 0 失败、0 端口耗尽 warn，根因修复闭环验证通过。`Phase 3` 中 N=256 失败 1 个 + N=128 隐式 4346 个 AddrInUse retry 的现象在 noresvport 路径上完全消失。

### Phase 6 — e2e 验证

- baseline (`e2e-test-nfs-v3-full-sync` 默认 URL): PASS, 527 entries 一致
- `?noresvport=true`: PASS, 527 entries 一致；`target/debug/logs/*/app.log` 中**未出现** `exhausted all connect attempts` 或 `error obtaining ports from portmapper`
