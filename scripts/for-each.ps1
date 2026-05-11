# 在 5 个子仓库里依次跑同一条命令，任何一个失败即停。
# 用法：.\scripts\for-each.ps1 cargo build --all-targets

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$repos = @("terrasync-rs", "data-mover-rs", "smb-rs", "nfs-rs", "scheduler-rs")

if ($args.Count -eq 0) {
    Write-Error "usage: for-each.ps1 <command> [args...]"
    exit 2
}

$cmd = $args[0]
$cmdArgs = @()
if ($args.Count -gt 1) { $cmdArgs = $args[1..($args.Count - 1)] }

foreach ($d in $repos) {
    Write-Host "`n=== $d : $cmd $cmdArgs ===" -ForegroundColor Cyan
    $path = Join-Path $root $d
    if (-not (Test-Path $path)) {
        Write-Warning "  (跳过：目录不存在，先跑 .\scripts\bootstrap.ps1)"
        continue
    }
    Push-Location $path
    try {
        & $cmd @cmdArgs
        if ($LASTEXITCODE -ne 0) {
            Pop-Location
            exit $LASTEXITCODE
        }
    } finally {
        if ((Get-Location).Path -eq $path) { Pop-Location }
    }
}
