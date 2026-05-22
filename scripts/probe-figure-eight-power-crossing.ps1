# =============================================================================
# Probe a figure-eight circuit with the power block as the crossing point.
# =============================================================================

param(
    [string]$TargetNode
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "dev-env.ps1")

if (-not $TargetNode) {
    $TargetNode = "cluster@$env:COMPUTERNAME"
}

$probeName = "fig8probe$PID"
$probeScript = Join-Path $PSScriptRoot "probe-figure-eight-power-crossing.exs"
if (-not (Test-Path -LiteralPath $probeScript)) {
    throw "probe script not found: $probeScript"
}

Push-Location $RepoRoot
try {
    & elixir.bat --sname $probeName --cookie $env:ERLANG_COOKIE $probeScript --target-node $TargetNode
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
