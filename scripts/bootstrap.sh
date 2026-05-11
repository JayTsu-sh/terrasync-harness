#!/usr/bin/env bash
# bootstrap.sh — macOS / Linux / WSL
# 用法：在 harness 根目录运行 `./scripts/bootstrap.sh`
# 作用：把 5 个子仓库 clone 到 harness 内，已存在的 git pull 更新

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ORG="JayTsu-sh"
REPOS=(terrasync-rs data-mover-rs smb-rs nfs-rs scheduler-rs)

# 可通过环境变量 TERRASYNC_PROTO=ssh 切换到 SSH clone
USE_SSH="${TERRASYNC_PROTO:-https}"

for repo in "${REPOS[@]}"; do
    if [ -d "$ROOT/$repo/.git" ]; then
        echo "[pull]  $repo"
        git -C "$ROOT/$repo" pull --ff-only
    else
        if [ -e "$ROOT/$repo" ]; then
            echo "[clean] removing broken $repo"
            rm -rf "$ROOT/$repo"
        fi
        if [ "$USE_SSH" = "ssh" ]; then
            url="git@github.com:$ORG/$repo.git"
        else
            url="https://github.com/$ORG/$repo.git"
        fi
        echo "[clone] $repo"
        git clone "$url" "$ROOT/$repo"
    fi

    # 子仓库本地强制 LF（写到该仓库的 .git/config，不影响 tracked 内容）。
    # 避免 Windows 上 cargo 在 Cargo.toml 等文本文件出现 CRLF 伪修改。
    git -C "$ROOT/$repo" config core.autocrlf false
    git -C "$ROOT/$repo" config core.eol lf
done

echo
echo "Done. Verify with:"
echo "  cargo build --workspace"
echo "  cargo test  --workspace"
