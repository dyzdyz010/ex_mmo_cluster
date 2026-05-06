# =============================================================================
# 启动 Elixir umbrella 集群 (单节点)
# =============================================================================
# 用法:
#   .\scripts\start-server.ps1              # 前台 iex (交互式 shell, 默认)
#   .\scripts\start-server.ps1 -Detach      # 后台 elixir run --no-halt (无 shell,
#                                           #   适合 stdout/stderr 被重定向的场景)
#
# 所有环境变量从 scripts\dev-env.ps1 继承, 想改端口 / cookie / 节点名, 改那个
# 文件即可, 不需要动本脚本.
# =============================================================================

param(
    [switch]$Detach
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "dev-env.ps1")

Write-Host "[start-server] Booting node $env:NODE_NAME with cookie $env:ERLANG_COOKIE ..." -ForegroundColor Green
Write-Host "[start-server] AUTH=$env:AUTH_PORT  VISUALIZE=$env:VISUALIZE_PORT  GATE_TCP=$env:GATE_TCP_PORT  GATE_UDP=$env:GATE_UDP_PORT"

# PowerShell 有内建别名 iex = Invoke-Expression; 必须解析到 PATH 上的实际 iex.bat.
# Detach 模式改用 elixir.bat -S mix run --no-halt 以避开 Windows 下 iex 的
# ReadConsoleW 崩溃 (stdin 被重定向时 Erlang shell reader 会炸).
if ($Detach) {
    $exe = (Get-Command -CommandType Application -Name elixir -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $exe) { throw "elixir executable not found on PATH." }
    $exeArgs = @("--name", $env:NODE_NAME, "--cookie", $env:ERLANG_COOKIE, "-S", "mix", "run", "--no-halt")
    Write-Host "[start-server] Mode: detach (elixir --no-halt)"
} else {
    $exe = (Get-Command -CommandType Application -Name iex -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $exe) { throw "iex executable not found on PATH." }
    $exeArgs = @("--name", $env:NODE_NAME, "--cookie", $env:ERLANG_COOKIE, "-S", "mix")
    Write-Host "[start-server] Mode: foreground iex (Ctrl+C twice to stop)"
}
Write-Host ""

Push-Location $RepoRoot
try {
    & $exe @exeArgs
}
finally {
    Pop-Location
}
