# Terrasync harness orchestrator.
# 跨平台：Windows (PowerShell) 和 Linux/WSL Rocky (bash) 都支持。
# 在 harness 根目录运行 `just <target>`。

set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

# 默认目标：列出所有命令
default:
    @just --list

# ---------- bootstrap：拉/更新 5 个子仓库 ----------
[unix]
bootstrap:
    ./scripts/bootstrap.sh

[windows]
bootstrap:
    powershell -NoLogo -ExecutionPolicy Bypass -File .\scripts\bootstrap.ps1

# ---------- build ----------
[unix]
build:
    ./scripts/for-each.sh cargo build --all-targets

[windows]
build:
    powershell -NoLogo -ExecutionPolicy Bypass -File .\scripts\for-each.ps1 cargo build --all-targets

# ---------- test ----------
[unix]
test:
    ./scripts/for-each.sh cargo test --all-features

[windows]
test:
    powershell -NoLogo -ExecutionPolicy Bypass -File .\scripts\for-each.ps1 cargo test --all-features

# ---------- check（提交前必跑：fmt --check + clippy）----------
[unix]
check:
    ./scripts/for-each.sh sh -c 'cargo fmt --all -- --check && cargo clippy --all-targets --all-features -- -D warnings'

[windows]
check:
    powershell -NoLogo -ExecutionPolicy Bypass -File .\scripts\for-each.ps1 cargo fmt --all -- --check
    powershell -NoLogo -ExecutionPolicy Bypass -File .\scripts\for-each.ps1 cargo clippy --all-targets --all-features -- -D warnings

# ---------- fmt ----------
[unix]
fmt:
    ./scripts/for-each.sh cargo fmt --all

[windows]
fmt:
    powershell -NoLogo -ExecutionPolicy Bypass -File .\scripts\for-each.ps1 cargo fmt --all

# ---------- clean ----------
[unix]
clean:
    ./scripts/for-each.sh cargo clean

[windows]
clean:
    powershell -NoLogo -ExecutionPolicy Bypass -File .\scripts\for-each.ps1 cargo clean

# ---------- status（每个子仓库的 git status）----------
[unix]
status:
    ./scripts/for-each.sh git status -sb

[windows]
status:
    powershell -NoLogo -ExecutionPolicy Bypass -File .\scripts\for-each.ps1 git status -sb

# ---------- in：在指定子仓库跑任意命令 ----------
# 例：just in nfs-rs cargo build
[unix]
in repo +cmd:
    cd {{repo}} && {{cmd}}

[windows]
in repo +cmd:
    $ErrorActionPreference='Stop'; Set-Location {{repo}}; {{cmd}}

# ---------- pull（等价 bootstrap）----------
pull: bootstrap
