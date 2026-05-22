# =============================================================================
# Probe macro/refined prefab circuit consistency against the running server.
# =============================================================================

param(
    [string]$TargetNode,
    [string]$LeaveScenario
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "dev-env.ps1")

if (-not $TargetNode) {
    $TargetNode = "cluster@$env:COMPUTERNAME"
}

$probeName = "prefabcircuit$PID"
$probeScript = Join-Path $PSScriptRoot "probe-prefab-circuit-consistency.exs"
if (-not (Test-Path -LiteralPath $probeScript)) {
    throw "probe script not found: $probeScript"
}

Push-Location $RepoRoot
try {
    $probeArgs = @("--target-node", $TargetNode)
    if ($LeaveScenario) {
        $probeArgs += @("--leave-scenario", $LeaveScenario)
    }

    & elixir.bat --sname $probeName --cookie $env:ERLANG_COOKIE $probeScript @probeArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
