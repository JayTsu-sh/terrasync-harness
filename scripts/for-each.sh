#!/usr/bin/env bash
# 在 5 个子仓库里依次跑同一条命令，任何一个失败即停。
# 用法：./scripts/for-each.sh cargo build --all-targets

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOS=(terrasync-rs data-mover-rs smb-rs nfs-rs scheduler-rs)

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <command> [args...]" >&2
    exit 2
fi

for d in "${REPOS[@]}"; do
    printf '\n=== %s: %s ===\n' "$d" "$*"
    if [ ! -d "$ROOT/$d" ]; then
        echo "  (跳过：目录不存在，先跑 ./scripts/bootstrap.sh)" >&2
        continue
    fi
    (cd "$ROOT/$d" && "$@")
done
