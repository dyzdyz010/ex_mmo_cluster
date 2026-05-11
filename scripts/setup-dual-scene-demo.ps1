# =============================================================================
# Configure dual scene-owner demo regions in a running dev server.
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

$setupName = "dualsetup$PID"
$setupScript = Join-Path $PSScriptRoot "setup-dual-scene-demo.exs"
if (-not (Test-Path -LiteralPath $setupScript)) {
    throw "setup script not found: $setupScript"
}

Push-Location $RepoRoot
try {
    & elixir.bat --sname $setupName --cookie $env:ERLANG_COOKIE $setupScript --target-node $TargetNode --logical-scene-id $LogicalSceneId --lease-ttl-ms $LeaseTtlMs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
