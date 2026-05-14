# NFS-RS `noresvport` URL 参数实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 nfs-rs 客户端在 `?noresvport=true` URL 参数下绑临时端口而非特权端口，解除 Windows 上 32+ 并发 mount 的特权端口池耗尽（已在 `docs/nfs-mount-concurrency-investigation.md` 确认根因）。

**Architecture:**
- 加 `MountArgs.noresvport: bool`（URL 解析），默认 `false`（兼容老 server）
- `StreamMux` 持有 `noresvport`，`connect_to_target(addr, noresvport)` 分支：true 时 `set_port(0)` 走 ephemeral pool（~16K 端口），false 时维持当前 1-1023 + 200 次重试逻辑
- `portmap()` 的最终错误透出底层 IO 错误，不再改写成 `"error obtaining ports from portmapper"`

**Tech Stack:** Rust 1.95.0，tokio，url，thiserror；nfs-rs 0.2.0 单 crate；e2e 通过 terrasync-rs 的 `e2e-test-nfs-v3-full-sync` skill 验证。

**Out-of-scope（独立后续 PR）：**
- terrasync-rs orchestrator 的 `STORAGE_PAIR_MOUNT_CONCURRENCY` 提升 + retry jitter（要等 nfs-rs 发版后升 git 依赖）
- nfs-rs `connect_to_target` 失败端口短期黑名单（边角料）

---

## File Structure

**修改 (nfs-rs):**
- `src/lib.rs` — `MountArgs.noresvport` 字段、URL 解析、`connect_to_target` 签名 + 分支、test 模块新增 3 个测试
- `src/rpc/mod.rs` — `StreamMux` 持有 `noresvport`、`connect/reconnect` 透传、`portmap()` 错误聚合

**修改 (nfs-rs callers):**
- `src/nfs3/mount.rs` — 把 `MountArgs.noresvport` 透传给 `StreamMux::connect`（具体行号 Task 4 中定位）
- `src/nfs41/mount.rs` — 同上

**修改（验证产物）:**
- `examples/stress_mount.rs` — 透传 URL，无需改 stress 内部逻辑（URL 已带参数）

**新增 (临时联调，最后撤销):**
- `terrasync-rs/Cargo.toml` 末尾 `[patch."https://github.com/JayTsu-sh/nfs-rs.git"]` 指向 `../nfs-rs`

**新增 (文档):**
- `docs/superpowers/plans/2026-05-14-nfs-rs-noresvport.md`（本文件）
- 调研记录追加 Phase 5 验证结果

---

## Verification Plan (执行时自检清单)

1. `cargo test --all-features` 在 `nfs-rs/` 内全过，新增 3 个测试出现在结果里
2. `cargo clippy --all-targets -- -D warnings` 在 `nfs-rs/` 内零 warning
3. `stress_mount` 在 Windows N=256 不带 `?noresvport`：仍可能出 1 个 fail（保持旧行为）
4. `stress_mount` 在 Windows N=512 带 `?noresvport=true`：**0 fail，0 个 `exhausted all connect attempts` warn**
5. e2e `e2e-test-nfs-v3-full-sync` 跑两遍：一遍 default URL（无 regression），一遍 URL 加 `?noresvport=true`（仍 pass，527 条数据一致）
6. 所有产物清理：`[patch]` 撤、CH 表 drop、kubectl port-forward 杀、`jobs/` 清

---

## Task 1: URL parameter parsing for `noresvport`

**Files:**
- Modify: `nfs-rs/src/lib.rs` (struct MountArgs at line 248-261; parse_url at 320-404)
- Test: `nfs-rs/src/lib.rs` (#[cfg(test)] mod tests at 546+)

- [ ] **Step 1: Write failing tests for URL parsing**

在 `nfs-rs/src/lib.rs` 的 `#[cfg(test)] mod tests` 块末尾追加（紧贴现有 `parse_url_*` 测试同级）：

```rust
    #[test]
    fn parse_url_noresvport_true() {
        let args = parse_url("nfs://127.0.0.1/some/export?noresvport=true").unwrap();
        assert!(args.noresvport, "noresvport=true should parse to true");
    }

    #[test]
    fn parse_url_noresvport_default_false() {
        let args = parse_url("nfs://127.0.0.1/some/export").unwrap();
        assert!(!args.noresvport, "default should be false (preserve legacy privileged-port behavior)");
    }

    #[test]
    fn parse_url_noresvport_explicit_false() {
        let args = parse_url("nfs://127.0.0.1/some/export?noresvport=false").unwrap();
        assert!(!args.noresvport);
    }
```

- [ ] **Step 2: Run tests, confirm they fail with compile error**

```bash
cd nfs-rs
cargo test --lib parse_url_noresvport 2>&1 | tail -20
```

Expected: `error[E0609]: no field 'noresvport' on type 'MountArgs'` × 3，编译不过。

- [ ] **Step 3: Add `noresvport` field to MountArgs**

在 `nfs-rs/src/lib.rs:248-261` 的 `struct MountArgs` 内（在 `wsize: u32,` 之后、闭合大括号之前）加：

```rust
    noresvport: bool,
```

- [ ] **Step 4: Add URL parsing for `noresvport` in parse_url()**

在 `parse_url()` 函数内（`nfs-rs/src/lib.rs:389` 紧跟 wsize 解析之后、`let host = ...` 之前）加：

```rust
    let noresvport = get_url_query_param(
        &parsed_url,
        "noresvport",
        false,
        "specified URL contains bad noresvport value (expected true/false)",
    )?;
```

并把 `Ok(MountArgs { ... })` 构造（行 391-403）末尾加 `noresvport,`：

```rust
    Ok(MountArgs {
        versions,
        host,
        mountport,
        nfsport,
        dirpath: parsed_url.path().to_string(),
        uid,
        gid,
        dircount,
        maxcount,
        rsize,
        wsize,
        noresvport,
    })
```

- [ ] **Step 5: Run tests, confirm they pass**

```bash
cd nfs-rs
cargo test --lib parse_url_noresvport 2>&1 | tail -10
```

Expected: `3 passed; 0 failed`。

- [ ] **Step 6: Run full nfs-rs unit-test suite, confirm zero regression**

```bash
cd nfs-rs
cargo test --lib 2>&1 | tail -5
```

Expected: all tests pass，包含原有 `parse_url_*` 测试 + 新增 3 个。

- [ ] **Step 7: Commit**

```bash
cd nfs-rs
git add src/lib.rs
git commit -m "feat(url): parse noresvport=true|false query param (default false)"
```

---

## Task 2: `connect_to_target` ephemeral-port branch

**Files:**
- Modify: `nfs-rs/src/lib.rs:47-186` (`connect_to_target`)
- Test: `nfs-rs/src/lib.rs` tests 模块

- [ ] **Step 1: Write failing test for noresvport=true (ephemeral) branch**

在 `nfs-rs/src/lib.rs` 的 `#[cfg(test)] mod tests` 末尾追加：

```rust
    #[tokio::test]
    async fn connect_to_target_ephemeral_when_noresvport_true() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let listen_addr = listener.local_addr().unwrap();
        let accept_handle = tokio::spawn(async move {
            let (stream, peer) = listener.accept().await.unwrap();
            (stream, peer)
        });
        let stream = connect_to_target(&listen_addr, true).await.unwrap();
        let local_port = stream.local_addr().unwrap().port();
        assert!(
            local_port >= 1024,
            "with noresvport=true, source port {} must be ephemeral (>=1024)",
            local_port
        );
        let _ = accept_handle.await.unwrap();
    }

    #[tokio::test]
    async fn connect_to_target_privileged_when_noresvport_false() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let listen_addr = listener.local_addr().unwrap();
        let accept_handle = tokio::spawn(async move { listener.accept().await.unwrap() });
        let stream = connect_to_target(&listen_addr, false).await.unwrap();
        let local_port = stream.local_addr().unwrap().port();
        assert!(
            (1..1024).contains(&local_port),
            "with noresvport=false, source port {} must be privileged (1-1023)",
            local_port
        );
        let _ = accept_handle.await.unwrap();
    }
```

- [ ] **Step 2: Run tests, confirm they fail (wrong arity)**

```bash
cd nfs-rs
cargo test --lib connect_to_target 2>&1 | tail -20
```

Expected: `error[E0061]: this function takes 1 argument but 2 arguments were supplied`。

- [ ] **Step 3: Update `connect_to_target` signature and add ephemeral branch**

在 `nfs-rs/src/lib.rs:47` 把签名改成：

```rust
pub(crate) async fn connect_to_target(addr: &SocketAddr, noresvport: bool) -> Result<TcpStream> {
```

然后在原 `const MAX_CONNECT_ATTEMPTS: usize = 200;`（约 line 125）**之前**插入 ephemeral 快路径：

```rust
    // noresvport=true: 让 OS 选临时端口（Windows ~49152-65535, Linux ~32768-60999）。
    // 避开 ~960 个特权端口的耗尽问题，要求 server 端启用 insecure（NFSv3 export 选项）。
    if noresvport {
        let socket = if addr.is_ipv4() {
            TcpSocket::new_v4()?
        } else {
            TcpSocket::new_v6()?
        };
        socket.set_reuseaddr(true)?;
        socket.bind(local_addr_base)?;
        let stream = socket.connect(*addr).await?;
        stream.set_nodelay(true)?;
        const KEEPALIVE_TIME_SECS: u64 = 30;
        const KEEPALIVE_INTERVAL_SECS: u64 = 5;
        #[cfg(target_os = "linux")]
        const KEEPALIVE_RETRIES: u32 = 3;
        let sock_ref = socket2::SockRef::from(&stream);
        let keepalive = socket2::TcpKeepalive::new()
            .with_time(std::time::Duration::from_secs(KEEPALIVE_TIME_SECS))
            .with_interval(std::time::Duration::from_secs(KEEPALIVE_INTERVAL_SECS));
        #[cfg(target_os = "linux")]
        let keepalive = keepalive.with_retries(KEEPALIVE_RETRIES);
        sock_ref.set_tcp_keepalive(&keepalive)?;
        info!(addr = %addr, local_port = stream.local_addr().map(|a| a.port()).unwrap_or(0), "TCP connection established (ephemeral source port, noresvport)");
        return Ok(stream);
    }
```

> **重构纪律**：保留下面的 `for attempt in 0..MAX_CONNECT_ATTEMPTS` 循环和现有的特权端口逻辑完全不动，只在前面加 `if noresvport` 分支。`available_ports` 的 lazy 构造仍跑——可接受的微量浪费（plan 不做提前 return 重构，单独 PR）。

- [ ] **Step 4: Compile-check first (callers will break, expected)**

```bash
cd nfs-rs
cargo build --lib 2>&1 | tail -10
```

Expected: callers in `src/rpc/mod.rs` fail with arity mismatch—这是预期，Task 3 解决。

- [ ] **Step 5: 暂不跑测试（等 Task 3 callers 修好统一跑）**

(skipped)

- [ ] **Step 6: Commit (incomplete, callers next)**

```bash
cd nfs-rs
git add src/lib.rs
git commit -m "feat(connect): connect_to_target accepts noresvport (callers updated next)"
```

---

## Task 3: Thread `noresvport` through `StreamMux` and callers

**Files:**
- Modify: `nfs-rs/src/rpc/mod.rs` — `StreamMux::connect`, `StreamMux::reconnect`, `portmap_on_addr`, `portmap`
- Modify: `nfs-rs/src/nfs3/mount.rs` and `nfs-rs/src/nfs41/mount.rs` — 透传 `args.noresvport`
- Modify: `nfs-rs/src/lib.rs:443 mount()` — 不改，args 已 carry

- [ ] **Step 1: Grep all StreamMux::connect call sites**

```bash
cd nfs-rs
find src -name '*.rs' -print0 | xargs -0 grep -nE "StreamMux::connect|connect_to_target"
```

Expected: 2 处 `connect_to_target` 调用（rpc/mod.rs:175, :255）+ N 处 `StreamMux::connect` 调用（在 nfs3/、nfs41/ 模块）。**记录所有结果**，作为本任务后续步骤的覆盖清单。

- [ ] **Step 2: Add `noresvport` field to StreamMux and thread it through connect/reconnect**

在 `nfs-rs/src/rpc/mod.rs` `pub(crate) struct StreamMux { ... }` 结构体内加：

```rust
    noresvport: bool,
```

把 `pub(crate) async fn connect(addr: SocketAddr) -> Result<Arc<Self>>` 改成：

```rust
pub(crate) async fn connect(addr: SocketAddr, noresvport: bool) -> Result<Arc<Self>> {
```

函数体内 `let stream = crate::connect_to_target(&addr).await?;` 改成：

```rust
let stream = crate::connect_to_target(&addr, noresvport).await?;
```

`Arc::new(Self { ... })` 构造里加 `noresvport,` 字段。

在 `reconnect()` 函数内（`nfs-rs/src/rpc/mod.rs:255`）把：

```rust
let stream = crate::connect_to_target(&self.addr).await?;
```

改成：

```rust
let stream = crate::connect_to_target(&self.addr, self.noresvport).await?;
```

`new_dummy()` 测试辅助函数里的 `StreamMux` 构造也加 `noresvport: false,`。

- [ ] **Step 3: Update `portmap`/`portmap_on_addr` signatures**

`nfs-rs/src/rpc/mod.rs::portmap()` 签名加 `noresvport: bool`：

```rust
pub(crate) async fn portmap(
    addrs: &Vec<SocketAddr>,
    prog: u32,
    vers: u32,
    auth: &Auth,
    max_retries: usize,
    noresvport: bool,
) -> Result<u16> {
```

把 `portmap_on_addr(addr, prog, vers, auth, max_retries)` 调用改成 `portmap_on_addr(addr, prog, vers, auth, max_retries, noresvport)`。

`portmap_on_addr` 签名同样加 `noresvport: bool`，调用 `StreamMux::connect(*addr, noresvport)`。

- [ ] **Step 4: Update all StreamMux::connect callers in nfs3/ and nfs41/**

按 Step 1 grep 结果，把每个 `StreamMux::connect(addr).await` 改成 `StreamMux::connect(addr, args.noresvport).await`，并把上游函数签名加 `noresvport: bool` 参数。

mount entry 点（`nfs3::mount(&args)` 和 `nfs41::mount::mount(&args)`）已经有 `args: &MountArgs`，所以 `args.noresvport` 直接可用。

> **如果 grep 出超过 5 处调用**：用 AskUserQuestion 提示 blast radius，确认继续。

- [ ] **Step 5: cargo build --lib until clean**

```bash
cd nfs-rs
cargo build --lib 2>&1 | tail -10
```

Expected: `Finished` 无错误，0 warning 优先。

- [ ] **Step 6: Run full test suite**

```bash
cd nfs-rs
cargo test --lib 2>&1 | tail -10
```

Expected: 所有原测试 + 新增 5 个（3 个 Task 1 + 2 个 Task 2）全过。

- [ ] **Step 7: Commit**

```bash
cd nfs-rs
git add src/
git commit -m "feat(rpc): thread noresvport through StreamMux and mount callers"
```

---

## Task 4: Error transparency — surface underlying error in `portmap()`

**Files:**
- Modify: `nfs-rs/src/rpc/mod.rs::portmap` (around line 55-78)

- [ ] **Step 1: Read current portmap() error path**

```bash
cd nfs-rs
sed -n '55,80p' src/rpc/mod.rs
```

确认现状：返回固定 `NfsError::Rpc("error obtaining ports from portmapper".to_string())`，底层错误只在 warn 日志里。

- [ ] **Step 2: Write failing test that asserts error message contains underlying detail**

在 `nfs-rs/src/rpc/mod.rs` `#[cfg(test)] mod tests` 块内（如果没有则新增）追加：

```rust
#[tokio::test]
async fn portmap_error_includes_underlying_detail() {
    // Connect to a localhost port nobody listens on → ConnectionRefused
    let dead_addr: SocketAddr = "127.0.0.1:1".parse().unwrap();
    let auth = Auth::new_null();
    let res = portmap(&vec![dead_addr], NFS_PROG, NFS3_VERSION, &auth, 2, false).await;
    let err = res.expect_err("dead port should fail");
    let msg = err.to_string();
    assert!(
        msg.contains("127.0.0.1:1") || msg.to_lowercase().contains("refused") || msg.to_lowercase().contains("connect"),
        "portmap error should expose underlying detail, got: {}",
        msg
    );
}
```

- [ ] **Step 3: Run test, confirm it fails**

```bash
cd nfs-rs
cargo test --lib portmap_error_includes 2>&1 | tail -15
```

Expected: assert 失败，因为当前消息固定为 `"error obtaining ports from portmapper"`。

- [ ] **Step 4: Change portmap() to collect underlying errors**

把 `nfs-rs/src/rpc/mod.rs::portmap` 改成：

```rust
pub(crate) async fn portmap(
    addrs: &Vec<SocketAddr>,
    prog: u32,
    vers: u32,
    auth: &Auth,
    max_retries: usize,
    noresvport: bool,
) -> Result<u16> {
    let mut last_err: Option<NfsError> = None;
    for addr in addrs {
        debug!(addr = %addr, prog, vers, "attempting portmapper lookup");
        match portmap_on_addr(addr, prog, vers, auth, max_retries, noresvport).await {
            Ok(port) => {
                info!(addr = %addr, prog, vers, port, "portmapper resolved port");
                return Ok(port);
            }
            Err(e) => {
                warn!(addr = %addr, prog, vers, error = %e, "portmapper lookup failed on address");
                last_err = Some(e);
            }
        }
    }
    Err(NfsError::Rpc(format!(
        "portmapper lookup failed for prog={} vers={}: {}",
        prog,
        vers,
        last_err
            .map(|e| e.to_string())
            .unwrap_or_else(|| "no addresses tried".to_string()),
    )))
}
```

- [ ] **Step 5: Run test, confirm it passes**

```bash
cd nfs-rs
cargo test --lib portmap_error_includes 2>&1 | tail -10
```

Expected: 1 passed。

- [ ] **Step 6: Run full suite, confirm zero regression**

```bash
cd nfs-rs
cargo test --lib 2>&1 | tail -5
```

Expected: all pass。

- [ ] **Step 7: Commit**

```bash
cd nfs-rs
git add src/rpc/mod.rs
git commit -m "fix(rpc): include underlying error in portmap() failure message"
```

---

## Task 5: cargo clippy & cargo fmt clean

**Files:** 所有上面动过的

- [ ] **Step 1: Format**

```bash
cd nfs-rs
cargo fmt
```

- [ ] **Step 2: Clippy at deny-warnings**

```bash
cd nfs-rs
cargo clippy --all-targets -- -D warnings 2>&1 | tail -20
```

Expected: `Finished` 无 warning。如果有，按 CLAUDE.md 规范修。

- [ ] **Step 3: Commit only if fmt produced changes**

```bash
cd nfs-rs
git status --short
# 如果有改动:
git add -u && git commit -m "style: cargo fmt"
```

---

## Task 6: Stress test empirical validation (Windows local)

**Files:**
- Use existing: `nfs-rs/examples/stress_mount.rs`（不改，URL 已能透传参数）
- Document: `docs/nfs-mount-concurrency-investigation.md`（追加 Phase 5）

- [ ] **Step 1: Wait for TIME_WAIT to drain to <100**

```bash
cd nfs-rs
while [ "$(netstat -an | grep '10.131.9.13' | grep -c TIME_WAIT)" -gt 100 ]; do
  sleep 20; echo "TW=$(netstat -an | grep '10.131.9.13' | grep -c TIME_WAIT)"
done
echo "TW now $(netstat -an | grep '10.131.9.13' | grep -c TIME_WAIT)"
```

Expected: 最终输出 `TW now <某个 <100 数字>`。

- [ ] **Step 2: Rebuild stress_mount with new nfs-rs**

```bash
cd nfs-rs
cargo build --release --example stress_mount 2>&1 | tail -3
```

Expected: `Finished release [optimized]`。

- [ ] **Step 3: Baseline (legacy privileged), N=256**

```bash
cd nfs-rs
./target/release/examples/stress_mount.exe nfs://10.131.9.13/export/nfs 256 2>err_baseline.log | tail -3
echo "exhausted-warns=$(grep -c 'exhausted all connect attempts' err_baseline.log)"
```

Expected: 跟之前 Phase 3 一致 — 可能 0-3 个 fail，可能 1+ 个 `exhausted` warn。

- [ ] **Step 4: With noresvport, N=256**

```bash
cd nfs-rs
./target/release/examples/stress_mount.exe "nfs://10.131.9.13/export/nfs?noresvport=true" 256 2>err_noresvport.log | tail -3
echo "exhausted-warns=$(grep -c 'exhausted all connect attempts' err_noresvport.log)"
```

Expected: **0 fail，0 exhausted-warn**（确认 fix 生效）。

- [ ] **Step 5: Push concurrency: N=512 with noresvport**

```bash
cd nfs-rs
./target/release/examples/stress_mount.exe "nfs://10.131.9.13/export/nfs?noresvport=true" 512 2>err_512.log | tail -3
echo "exhausted-warns=$(grep -c 'exhausted all connect attempts' err_512.log)"
```

Expected: **0 fail，0 exhausted-warn**。

- [ ] **Step 6: Append Phase 5 results to investigation doc**

Edit `docs/nfs-mount-concurrency-investigation.md`，在文件末尾追加：

```markdown
## Phase 5 — 修复后的实测验证

| 测试 | 默认（特权） | `?noresvport=true` |
|---|---|---|
| N=256 | <Step 3 实际值> | <Step 4 实际值> |
| N=512 | (未测) | <Step 5 实际值> |

修复确认：`?noresvport=true` 路径下 256/256 与 512/512 均 0 失败、0 端口耗尽 warn。
```

把 `<...>` 替换为实际数据。

- [ ] **Step 7: Clean stress logs, commit doc**

```bash
cd nfs-rs && rm -f err_baseline.log err_noresvport.log err_512.log
cd ..
git add docs/nfs-mount-concurrency-investigation.md
git commit -m "docs(investigation): record phase-5 noresvport stress results"
```

---

## Task 7: End-to-end via `e2e-test-nfs-v3-full-sync` (with `[patch]` to local nfs-rs)

**Files:**
- Modify (temporary): `terrasync-rs/Cargo.toml` — `[patch]` 末尾
- Run: `terrasync-rs/.claude/skills/e2e-test-nfs-v3-full-sync/scripts/run.py`

- [ ] **Step 1: Confirm kubectl port-forward still alive**

```bash
ssh root@10.131.6.181 'ps -p $(cat /tmp/ch-port-forward.pid 2>/dev/null) >/dev/null 2>&1 && echo ALIVE || echo DEAD'
```

Expected: `ALIVE`。如果 DEAD，按调查文档 "ClickHouse pinned-shard" 步骤重启。

- [ ] **Step 2: Add `[patch]` to terrasync-rs Cargo.toml**

确认目前没有 `[patch]` 段：

```bash
grep -n "\[patch" terrasync-rs/Cargo.toml || echo "no patch section yet"
```

向 `terrasync-rs/Cargo.toml` 末尾追加：

```toml

# === TEMPORARY: local nfs-rs for noresvport validation; remove before commit ===
[patch."https://github.com/JayTsu-sh/nfs-rs.git"]
nfs-rs = { path = "../nfs-rs" }
```

- [ ] **Step 3: Rebuild terrasync against local nfs-rs**

```bash
cd terrasync-rs
cargo build 2>&1 | tail -5
```

Expected: `Finished dev [unoptimized + debuginfo]`，编译到本地 nfs-rs（看 build 输出里有 `Compiling nfs-rs v0.2.0 (path:...)` 字样）。

- [ ] **Step 4: Baseline e2e — default URL (legacy privileged ports)**

```bash
cd terrasync-rs
python .claude/skills/e2e-test-nfs-v3-full-sync/scripts/run.py 2>&1 | tail -30
```

Expected: 最终行包含 `PASS`，527 entries 全过。若 fail，**停止**，按 SKILL.md 排查指南分析。

> 此步骤是回归校验：在低并发（527 entries × concurrency=8 在 StoragePair 限流到 2 下）默认 URL 应该照样跑过。

- [ ] **Step 5: Modify e2e URL to include `?noresvport=true`**

e2e skill 的 URL 在 `terrasync-rs/.claude/skills/harness-run/scripts/protocol_constants.py` 的 `NfsV3` 类构造。**临时**改成 noresvport 变体：

```bash
cd terrasync-rs
grep -n "SOURCE_URL\|DEST_URL" .claude/skills/harness-run/scripts/protocol_constants.py | head
```

找到 `NfsV3.SOURCE_URL`/`DEST_URL` 构造，**在内存里** override 为加 `?noresvport=true`——优先在 `.env` 加一个临时变量并改 protocol_constants.py 读取它。

> **如果 protocol_constants.py 用硬编码 URL 模板**：
> 1. 备份原文件 `cp .claude/skills/harness-run/scripts/protocol_constants.py /tmp/protocol_constants.py.bak`
> 2. `sed -i 's|nfs://{SOURCE_IP}{NFS_EXPORT}|nfs://{SOURCE_IP}{NFS_EXPORT}?noresvport=true|g; s|nfs://{DEST_IP}{NFS_EXPORT}|nfs://{DEST_IP}{NFS_EXPORT}?noresvport=true|g' .claude/skills/harness-run/scripts/protocol_constants.py`
> 3. Step 7 还原

- [ ] **Step 6: Re-run e2e with noresvport URL**

```bash
cd terrasync-rs
python .claude/skills/e2e-test-nfs-v3-full-sync/scripts/run.py 2>&1 | tail -30
```

Expected: `PASS`，527 entries 全过，且 log 里**不应该**出现 `exhausted all connect attempts` 或 `error obtaining ports from portmapper`。

```bash
grep -E "exhausted|error obtaining ports" target/debug/logs/*/app.log | head
```

Expected: 无输出。

- [ ] **Step 7: Restore protocol_constants.py**

```bash
cd terrasync-rs
cp /tmp/protocol_constants.py.bak .claude/skills/harness-run/scripts/protocol_constants.py
git diff --stat .claude/skills/harness-run/scripts/protocol_constants.py
```

Expected: `git diff` 显示无改动。

- [ ] **Step 8: Document e2e results**

把 Task 6 Phase 5 章节补完：

```markdown
### Phase 5 — e2e 验证

- baseline (`e2e-test-nfs-v3-full-sync` 默认 URL): PASS，527 entries 一致
- 改 URL 加 `?noresvport=true`：PASS，527 entries 一致；log 里无 `exhausted` 或 `error obtaining ports from portmapper`
```

```bash
cd ..
git add docs/nfs-mount-concurrency-investigation.md
git commit -m "docs(investigation): record e2e PASS with noresvport"
```

---

## Task 8: Cleanup — remove [patch], port-forward, CH tables

**Files:** 所有临时产物

> **依赖顺序**：必须先 drop CH 表（需要 port-forward 还活着），再杀 port-forward；`[patch]` 移除独立。

- [ ] **Step 1: Remove [patch] section from terrasync-rs/Cargo.toml**

```bash
cd terrasync-rs
# 删除 [patch] 段（含其前一行的注释）
sed -i '/# === TEMPORARY: local nfs-rs/,/^nfs-rs = { path/d' Cargo.toml
# 校验
grep -n "\[patch" Cargo.toml || echo "patch section removed ✓"
git diff --stat Cargo.toml
```

Expected: `patch section removed ✓`，diff 无 `[patch]` 残留。

- [ ] **Step 2: Drop any remaining test CH tables (port-forward 还活着的时候做)**

```bash
for t in base_nfs_v3_full_sync state_nfs_v3_full_sync tar_manifest_nfs_v3_full_sync \
         base_nfs_v3_full_sync_verify_src state_nfs_v3_full_sync_verify_src \
         base_nfs_v3_full_sync_verify_dst state_nfs_v3_full_sync_verify_dst; do
  curl -s --user 'default:NAS_PASS' -X POST "http://10.131.6.181:18123/" --data "DROP TABLE IF EXISTS default.$t"
done
echo "=== verify clean ==="
curl -s --user 'default:NAS_PASS' "http://10.131.6.181:18123/?query=SELECT+name+FROM+system.tables+WHERE+name+LIKE+%27%25nfs_v3_full_sync%25%27+FORMAT+TabSeparated"
```

Expected: 最终 SELECT 无输出。

- [ ] **Step 3: Stop kubectl port-forward**

```bash
ssh root@10.131.6.181 'PID=$(cat /tmp/ch-port-forward.pid 2>/dev/null); if [ -n "$PID" ]; then kill $PID 2>/dev/null && echo "killed $PID" || echo "not running"; rm -f /tmp/ch-port-forward.pid /tmp/ch-port-forward.log; fi'
```

Expected: `killed <PID>` 或 `not running`。

- [ ] **Step 4: Final harness git status**

```bash
cd terrasync-harness  # harness root
echo "=== harness root ==="
git status --short
echo "=== nfs-rs ==="
cd nfs-rs && git status --short
echo "=== terrasync-rs ==="
cd ../terrasync-rs && git status --short
```

Expected:
- harness 根：`?? docs/...`, `?? scripts/push_pubkey.py`（调研产物）
- nfs-rs：本次 commits 已推到 local branch
- terrasync-rs：`?? examples/config.lab.toml`, `?? .claude/skills/harness-run/.env`（lab 配置，不入 git）。**Cargo.toml 必须显示 unchanged**。

- [ ] **Step 5: Final commit cluster review**

```bash
cd nfs-rs && git log --oneline -10
```

Expected: 4 个新 commit：
1. `feat(url): parse noresvport=true|false query param`
2. `feat(connect): connect_to_target accepts noresvport`
3. `feat(rpc): thread noresvport through StreamMux and mount callers`
4. `fix(rpc): include underlying error in portmap() failure message`
（+ optional `style: cargo fmt` if Task 5 produced changes）

---

## Self-Review checklist (执行人填写)

- [ ] 所有 Task 步骤都跑过且按预期输出
- [ ] `cargo test --lib` 在 nfs-rs 内 0 失败
- [ ] `cargo clippy --all-targets -- -D warnings` 0 warning
- [ ] stress_mount 在 N=256/512 with noresvport 0 fail
- [ ] e2e baseline + e2e with noresvport 均 PASS
- [ ] `terrasync-rs/Cargo.toml` 无 `[patch]` 残留
- [ ] kubectl port-forward 已杀
- [ ] 所有 CH 测试表 dropped
- [ ] 调研文档 Phase 5 已补
