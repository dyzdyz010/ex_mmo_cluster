# =============================================================================
# Seed a mixed electric-circuit playground into a running dev server.
# =============================================================================

param(
    [string]$TargetNode,
    [int]$LogicalSceneId = 1,
    [int]$LeaseTtlMs = 21600000
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "dev-env.ps1")

if (-not $TargetNode) {
    $TargetNode = "cluster@$env:COMPUTERNAME"
}

$seedName = "circuitseed$PID"
$seedScript = Join-Path $PSScriptRoot "seed-circuit-playground.exs"
if (-not (Test-Path -LiteralPath $seedScript)) {
    throw "seed script not found: $seedScript"
}

Push-Location $RepoRoot
try {
    & elixir.bat --sname $seedName --cookie $env:ERLANG_COOKIE $seedScript --target-node $TargetNode --logical-scene-id $LogicalSceneId --lease-ttl-ms $LeaseTtlMs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
