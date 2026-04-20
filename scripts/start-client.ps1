# =============================================================================
# 启动 bevy_client
# =============================================================================
# 用法 (默认 GUI 模式, 自动生成用户名 = 基础名_<4位hex>, 多开零碰撞):
#   .\scripts\start-client.ps1
#
# 指定固定用户名 (想让某个角色持久化):
#   .\scripts\start-client.ps1 -Username bob
#
# Headless + stdio 调试模式 (自己敲 snapshot / move / reconcile_stats):
#   .\scripts\start-client.ps1 -Headless -Stdio
#
# GUI + 同时接受 stdio 命令:
#   .\scripts\start-client.ps1 -Stdio
#
# 所有环境变量从 scripts\dev-env.ps1 继承, 改那个文件即可, 不用动本脚本.
# BEVY_CLIENT_USERNAME 是"基础名", 自动生成会在后面拼 _<4位hex>.
# =============================================================================

param(
    [string]$Username,
    [switch]$Headless,
    [switch]$Stdio,
    [string]$ExtraArgs
)

$ErrorActionPreference = "Stop"

$RepoRoot  = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "dev-env.ps1")

if (-not $Username) {
    # 没传 -Username 就自动生成, 避免多开同名冲突. 4 位 hex = 65536 种,
    # 同时开几十个客户端碰撞概率也 <0.1%.
    $suffix = '{0:x4}' -f (Get-Random -Minimum 0 -Maximum 65536)
    $Username = "$($env:BEVY_CLIENT_USERNAME)_$suffix"
    Write-Host "[start-client] Auto-generated username: $Username" -ForegroundColor Yellow
}

$cargoArgs = @("run", "--")
if ($Headless) { $cargoArgs += "--headless" }
if ($Stdio)    { $cargoArgs += "--stdio" }
$cargoArgs += "--username"
$cargoArgs += $Username
if ($ExtraArgs) {
    $cargoArgs += ($ExtraArgs -split '\s+')
}

$clientDir = Join-Path $RepoRoot "clients\bevy_client"
Write-Host "[start-client] Launching bevy_client (username=$Username, headless=$Headless, stdio=$Stdio)" -ForegroundColor Green
Write-Host "[start-client] Gate=$env:BEVY_CLIENT_GATE_ADDR  Auth=$env:BEVY_CLIENT_AUTH_ADDR"
Write-Host "[start-client] cargo $($cargoArgs -join ' ')"
Write-Host ""

Push-Location $clientDir
try {
    & cargo @cargoArgs
}
finally {
    Pop-Location
}
