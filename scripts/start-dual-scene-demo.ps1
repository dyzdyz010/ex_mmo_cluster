# =============================================================================
# 启动浏览器 dual-scene-owner prefab demo。
# =============================================================================
# 用法：
#   .\scripts\start-dual-scene-demo.ps1 -AllowArchivedWebClient
#   .\scripts\start-dual-scene-demo.ps1 -AllowArchivedWebClient -OpenBrowser
#   .\scripts\start-dual-scene-demo.ps1 -AllowArchivedWebClient -ReuseServer -ReuseWeb
# =============================================================================

param(
    [switch]$AllowArchivedWebClient,
    [switch]$OpenBrowser,
    [switch]$ReuseServer,
    [switch]$ReuseWeb,
    [string]$ObserveDir = ".demo\observe"
)

$ErrorActionPreference = "Stop"

if (-not $AllowArchivedWebClient) {
    throw 'archived_web_client_explicit_opt_in_required: 本脚本驱动已归档 web_client；只有用户显式要求时才可传 -AllowArchivedWebClient 运行。当前 Voxia 入口：node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "..."'
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "dev-env.ps1")

$observePath = Join-Path $RepoRoot $ObserveDir
$observeParent = Split-Path -Parent $observePath
if (-not (Test-Path -LiteralPath $observeParent)) {
    New-Item -ItemType Directory -Path $observeParent -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $observePath)) {
    New-Item -ItemType Directory -Path $observePath -Force | Out-Null
}

function Test-HttpReady {
    param([string]$Uri, [string]$Method = "GET")
    if ($Method -eq "POST") {
        & curl.exe --silent --fail --max-time 5 -X POST -H "Content-Type: application/json" --data '{"username":"dual_scene_probe"}' $Uri | Out-Null
    } else {
        & curl.exe --silent --fail --max-time 5 $Uri | Out-Null
    }

    return $LASTEXITCODE -eq 0
}

function Wait-HttpReady {
    param([string]$Uri, [string]$Method = "GET", [int]$TimeoutSeconds = 120)
    for ($i = 1; $i -le $TimeoutSeconds; $i++) {
        if (Test-HttpReady -Uri $Uri -Method $Method) { return }
        Start-Sleep -Seconds 1
        if (($i % 10) -eq 0) { Write-Host "[dual-scene-demo] waiting for $Uri ... ${i}s" }
    }
    throw "timeout waiting for $Uri after ${TimeoutSeconds}s"
}

function Save-SetupJson {
    param([string[]]$Lines, [string]$Path)

    $jsonLine = $Lines | Where-Object { $_ -like 'dual_scene_demo_json=*' } | Select-Object -Last 1
    if (-not $jsonLine) {
        throw "dual scene setup did not emit dual_scene_demo_json"
    }

    $json = $jsonLine.Substring('dual_scene_demo_json='.Length)
    $json | Out-File -LiteralPath $Path -Encoding utf8
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

Push-Location $RepoRoot
try {
    $serverReadyUrl = "http://127.0.0.1:$env:AUTH_PORT/"
    if ($ReuseServer) {
        Wait-HttpReady -Uri $serverReadyUrl -TimeoutSeconds 60
        Write-Host "[dual-scene-demo] Reusing server on AUTH_PORT=$env:AUTH_PORT" -ForegroundColor Yellow
    } elseif (Test-HttpReady -Uri $serverReadyUrl) {
        Write-Host "[dual-scene-demo] Reusing server on AUTH_PORT=$env:AUTH_PORT" -ForegroundColor Yellow
    } else {
        $serverOut = Join-Path $observePath "dual-scene-server-$stamp.out.log"
        $serverErr = Join-Path $observePath "dual-scene-server-$stamp.err.log"
        $serverScript = Join-Path $PSScriptRoot "start-server.ps1"
        Write-Host "[dual-scene-demo] Starting server; logs: $serverOut / $serverErr" -ForegroundColor Green
        Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $serverScript, "-Detach") -WorkingDirectory $RepoRoot -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr -WindowStyle Hidden | Out-Null
        Wait-HttpReady -Uri $serverReadyUrl -TimeoutSeconds 180
    }

    Write-Host "[dual-scene-demo] Configuring scene1/scene2 owners..." -ForegroundColor Green
    $setupLog = Join-Path $observePath "dual-scene-setup-$stamp.log"
    $setupJson = Join-Path $observePath "dual-scene-setup-$stamp.json"
    $setupOutput = & (Join-Path $PSScriptRoot "setup-dual-scene-demo.ps1") 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dual scene setup failed with exit code $LASTEXITCODE" }
    $setupOutput | Tee-Object -FilePath $setupLog
    Save-SetupJson -Lines $setupOutput -Path $setupJson
    Write-Host "[dual-scene-demo] Setup evidence: $setupLog / $setupJson" -ForegroundColor Green

    $webUrl = "http://127.0.0.1:5173/"
    if ($ReuseWeb) {
        Wait-HttpReady -Uri $webUrl -TimeoutSeconds 60
        Write-Host "[dual-scene-demo] Reusing web client on $webUrl" -ForegroundColor Yellow
    } elseif (Test-HttpReady -Uri $webUrl) {
        Write-Host "[dual-scene-demo] Reusing web client on $webUrl" -ForegroundColor Yellow
    } else {
        $clientDir = Join-Path $RepoRoot "clients\web_client"
        $viteOut = Join-Path $observePath "dual-scene-vite-$stamp.out.log"
        $viteErr = Join-Path $observePath "dual-scene-vite-$stamp.err.log"
        $viteBin = Join-Path $clientDir "node_modules\vite\bin\vite.js"
        if (-not (Test-Path -LiteralPath $viteBin)) { throw "vite binary not found: $viteBin; run npm install in clients/web_client" }
        $env:VITE_VOXEL_DEV_SEED = "0"
        $env:VITE_VOXEL_DIAGNOSTIC_PARTIAL_WINDOW = "1"
        Write-Host "[dual-scene-demo] Starting explicit partial-window diagnostic; logs: $viteOut / $viteErr" -ForegroundColor Green
        Start-Process -FilePath "node.exe" -ArgumentList @($viteBin, "--host", "127.0.0.1", "--port", "5173") -WorkingDirectory $clientDir -RedirectStandardOutput $viteOut -RedirectStandardError $viteErr -WindowStyle Hidden | Out-Null
        Wait-HttpReady -Uri $webUrl -TimeoutSeconds 60
    }

    if ($OpenBrowser) {
        Start-Process $webUrl
    }

    Write-Host "[dual-scene-demo] Ready: $webUrl" -ForegroundColor Green
    Write-Host '[dual-scene-demo] Browser CLI: window.__voxelCli.run("scene_regions")'
    Write-Host '[dual-scene-demo] Subscribe scene1: window.__voxelCli.run("voxel_subscribe 0 0 0 0")'
    Write-Host '[dual-scene-demo] Subscribe scene2: window.__voxelCli.run("voxel_subscribe 1 0 0 0")'
    Write-Host '[dual-scene-demo] Cross-owner prefab: window.__voxelCli.run("prefab_place_snap builtin_sphere 16 0 8 0 1 0 128 8 68")'
}
finally {
    Pop-Location
}
