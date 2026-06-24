# Non-interactive umbrella server boot for automated e2e (no console handoff).
# Mirrors dev-server.ps1 env but uses `mix run --no-halt` so it can run in the
# background and be driven by the headless bevy client harness.
[CmdletBinding()]
param(
  [string]$NodeName = "dev",
  [string]$Cookie = "mmo",
  [int]$GateTcpPort = 20002,
  [int]$GateUdpPort = 20003,
  [int]$AuthPort = 20000,
  [int]$VisualizePort = 20001
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$env:HEX_HTTP_CONCURRENCY = "1"
$env:HEX_HTTP_TIMEOUT = "120"
$env:PHX_SERVER = "true"
$env:DEV_AUTO_LOGIN = "true"
# Match the compiled code_reloader value (build was compiled with this =0 → the
# Phoenix endpoints baked code_reloader:false). Also keeps the headless server
# light: no esbuild/tailwind/live-reload watchers.
$env:EX_MMO_DEV_RELOAD = "0"
if (-not $env:ERL_EPMD_PORT) { $env:ERL_EPMD_PORT = "43690" }
$env:GATE_TCP_PORT = "$GateTcpPort"
$env:GATE_UDP_PORT = "$GateUdpPort"
$env:AUTH_PORT = "$AuthPort"
$env:VISUALIZE_PORT = "$VisualizePort"

Write-Host "==> boot elixir --sname $NodeName --cookie $Cookie -S mix run --no-halt (headless)"
# Let `mix run` compile the full umbrella in dev first — this resyncs the Phoenix
# compile-env (visualize_server code_reloader) that a partial per-app compile
# left stale. Nothing NIF changed, so no Rust/bcrypt rebuild is triggered.
cmd /c "elixir --sname $NodeName --cookie $Cookie -S mix run --no-halt"
