# bootstrap.ps1 — Windows / PowerShell
# 用法：在 harness 根目录运行 `.\scripts\bootstrap.ps1`
# 作用：把 5 个子仓库 clone 成 harness 的兄弟目录下的子目录，git pull 更新已存在的

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$org = "JayTsu-sh"
$repos = @(
    "terrasync-rs",
    "data-mover-rs",
    "smb-rs",
    "nfs-rs",
    "scheduler-rs"
)

# 可通过环境变量 TERRASYNC_PROTO=ssh 切换到 SSH clone
$useSsh = $env:TERRASYNC_PROTO -eq "ssh"

foreach ($repo in $repos) {
    $path = Join-Path $root $repo
    if (Test-Path "$path\.git") {
        Write-Host "[pull] $repo" -ForegroundColor Yellow
        git -C $path pull --ff-only
    } else {
        if (Test-Path $path) {
            Write-Host "[clean] removing broken $repo" -ForegroundColor Red
            Remove-Item -Recurse -Force $path
        }
        $url = if ($useSsh) { "git@github.com:$org/$repo.git" } else { "https://github.com/$org/$repo.git" }
        Write-Host "[clone] $repo" -ForegroundColor Cyan
        git clone $url $path
    }

    # 子仓库本地强制 LF（写到该仓库的 .git/config，不影响 tracked 内容）。
    # 避免 Windows 上 cargo 在 Cargo.toml 等文本文件出现 CRLF 伪修改。
    git -C $path config core.autocrlf false
    git -C $path config core.eol lf
}

Write-Host "`nDone. Verify with:" -ForegroundColor Green
Write-Host "  cargo build --workspace" -ForegroundColor Cyan
Write-Host "  cargo test  --workspace" -ForegroundColor Cyan
