param(
  [string]$ObserveDir = ".demo/e2e-stdio",
  [int]$BotCount = 1,
  [int]$ServerExitAfter = 24
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$observeDirAbs = Join-Path $repoRoot $ObserveDir
New-Item -ItemType Directory -Force -Path $observeDirAbs | Out-Null

$serverOut = Join-Path $observeDirAbs "server-stdio.out.log"
$serverErr = Join-Path $observeDirAbs "server-stdio.err.log"
$clientOut = Join-Path $observeDirAbs "client-stdio.out.log"
$clientErr = Join-Path $observeDirAbs "client-stdio.err.log"
$clientObserve = Join-Path $observeDirAbs "client-observe.log"
$serverGateObserve = Join-Path $observeDirAbs "server-gate.log"
Remove-Item $serverOut,$serverErr,$clientOut,$clientErr,$clientObserve -ErrorAction SilentlyContinue

function Wait-Until {
  param(
    [scriptblock]$Condition,
    [int]$TimeoutSeconds,
    [string]$Description
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (& $Condition) { return }
    Start-Sleep -Milliseconds 500
  }

  throw "timed out waiting for $Description"
}

Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object { $_.LocalPort -in 29000,29001 } |
  Select-Object -ExpandProperty OwningProcess -Unique |
  ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

Push-Location $repoRoot
try {
  cmd /c "cd clients\bevy_client && cargo build"

  $serverPsi = New-Object System.Diagnostics.ProcessStartInfo
  $serverPsi.FileName = "cmd.exe"
  $serverPsi.WorkingDirectory = $repoRoot
  $serverPsi.Arguments = "/c set HEX_HTTP_CONCURRENCY=1&& set HEX_HTTP_TIMEOUT=120&& mix demo.run --stdio --bot-count $BotCount --exit-after $ServerExitAfter --output_dir $ObserveDir --observe_dir $ObserveDir 1> ""$serverOut"" 2> ""$serverErr"""
  $serverPsi.RedirectStandardInput = $true
  $serverPsi.UseShellExecute = $false
  $serverPsi.CreateNoWindow = $true

  $server = New-Object System.Diagnostics.Process
  $server.StartInfo = $serverPsi
  $server.Start() | Out-Null

  $configPath = Join-Path $observeDirAbs "human-client.json"
  Wait-Until -TimeoutSeconds 90 -Description "generated client config" -Condition {
    Test-Path $configPath
  }

  if ($BotCount -gt 0) {
    Wait-Until -TimeoutSeconds 90 -Description "demo bot auth in gate observe log" -Condition {
      (Test-Path $serverGateObserve) -and ((Get-Content $serverGateObserve -Raw) -match 'demo_bot_')
    }
  }

  $config = Get-Content $configPath | ConvertFrom-Json

  $clientPsi = New-Object System.Diagnostics.ProcessStartInfo
  $clientExe = Join-Path $repoRoot "clients\bevy_client\target\debug\bevy_client.exe"
  $clientPsi.FileName = $clientExe
  $clientPsi.WorkingDirectory = Join-Path $repoRoot "clients\bevy_client"
  $clientPsi.Arguments = "--stdio"
  $clientPsi.RedirectStandardInput = $true
  $clientPsi.RedirectStandardOutput = $true
  $clientPsi.RedirectStandardError = $true
  $clientPsi.UseShellExecute = $false
  $clientPsi.CreateNoWindow = $true
  $clientPsi.Environment["BEVY_CLIENT_GATE_ADDR"] = $config.gate_addr
  $clientPsi.Environment["BEVY_CLIENT_USERNAME"] = $config.username
  $clientPsi.Environment["BEVY_CLIENT_CID"] = [string]$config.cid
  $clientPsi.Environment["BEVY_CLIENT_TOKEN"] = $config.token
  $clientPsi.Environment["BEVY_CLIENT_OBSERVE_LOG"] = $clientObserve

  $client = New-Object System.Diagnostics.Process
  $client.StartInfo = $clientPsi
  $client.Start() | Out-Null

  Wait-Until -TimeoutSeconds 60 -Description "client entered scene" -Condition {
    (Test-Path $clientObserve) -and ((Get-Content $clientObserve -Raw) -match 'event="entered_scene"')
  }

  if ($BotCount -gt 0) {
    Wait-Until -TimeoutSeconds 90 -Description "remote AOI traffic visible to client" -Condition {
      (Test-Path $clientObserve) -and ((Get-Content $clientObserve -Raw) -match 'event="player_(enter|move)"')
    }
  }

  $client.StandardInput.WriteLine("snapshot")
  $client.StandardInput.WriteLine("transport")
  $client.StandardInput.WriteLine("move w 600")
  $client.StandardInput.Flush()
  Start-Sleep -Seconds 1
  $client.StandardInput.WriteLine("move d 600")
  $client.StandardInput.Flush()
  Start-Sleep -Seconds 1
  $client.StandardInput.WriteLine("chat e2e-stdio")
  $client.StandardInput.Flush()
  Start-Sleep -Milliseconds 500
  $client.StandardInput.WriteLine("skill 1")
  $client.StandardInput.Flush()
  Start-Sleep -Seconds 2
  $server.StandardInput.WriteLine("players")
  $server.StandardInput.WriteLine("connections")
  $server.StandardInput.WriteLine("fastlane")
  $server.StandardInput.WriteLine("player $($config.cid)")
  $server.StandardInput.Flush()
  Start-Sleep -Seconds 3
  $client.StandardInput.WriteLine("players")
  $client.StandardInput.WriteLine("position")
  $client.StandardInput.WriteLine("snapshot")
  $client.StandardInput.WriteLine("quit")
  $client.StandardInput.Flush()
  $client.StandardInput.Close()

  $client.WaitForExit(30000) | Out-Null

  Start-Sleep -Seconds 2
  if (-not $server.HasExited) { $server.StandardInput.Close() }

  $server.WaitForExit(40000) | Out-Null

  Start-Sleep -Milliseconds 500
  $serverStdout = if (Test-Path $serverOut) { Get-Content $serverOut -Raw } else { "" }
  $serverStderr = if (Test-Path $serverErr) { Get-Content $serverErr -Raw } else { "" }
  $clientStdout = $client.StandardOutput.ReadToEnd()
  $clientStderr = $client.StandardError.ReadToEnd()
  Set-Content $clientOut $clientStdout
  Set-Content $clientErr $clientStderr

  $requiredClientPatterns = @(
    'client_stdio event="snapshot".*scene_joined="true"',
    'client_stdio event="snapshot".*remote_player_count="[1-9]',
    'client_stdio event="transport".*movement_transport=',
    'client_stdio event="move_queued".*direction="w"',
    'client_stdio event="move_queued".*direction="d"',
    'client_stdio event="chat_sent".*e2e-stdio',
    'client_stdio event="skill_sent".*skill_id="1"',
    'client_stdio event="position".*local_position=',
    'client_stdio event="quit".*final_status='
  )

  foreach ($pattern in $requiredClientPatterns) {
    if ($clientStdout -notmatch $pattern) {
      throw "client stdio missing expected pattern: $pattern"
    }
  }

  if ($BotCount -gt 0 -and $clientStdout -match 'client_stdio event="players".*players="\[\]"') {
    throw "client stdio players output was empty despite demo bots being enabled"
  }

  $requiredServerPatterns = @(
    ('server_stdio event="players".*' + [string]$config.cid),
    'server_stdio event="connections"',
    'server_stdio event="fastlane"',
    'server_stdio event="player"'
  )

  foreach ($pattern in $requiredServerPatterns) {
    if ($serverStdout -notmatch $pattern) {
      throw "server stdio missing expected pattern: $pattern"
    }
  }

  if ($serverStdout -match 'server_stdio event="connections".*connections: \[\]') {
    throw "server stdio reported no active connections during E2E"
  }

  if ($serverStdout -match 'server_stdio event="fastlane".*session_count: 0') {
    throw "server stdio reported no fast-lane sessions during E2E"
  }

  if ($serverStdout -match 'server_stdio event="player".*player: nil') {
    throw "server stdio player query returned nil during E2E"
  }

  if ($BotCount -gt 0 -and -not ((Get-Content $clientObserve -Raw) -match 'event="player_(enter|move)"')) {
    throw "client observe log did not record remote AOI movement/enter events"
  }

  Write-Host "E2E stdio passed."
  Write-Host "Artifacts: $observeDirAbs"
  Write-Host ""
  Write-Host "--- SERVER STDIO ---"
  ($serverStdout -split "`r?`n" | Select-String 'server_stdio' | ForEach-Object { $_.Line })
  Write-Host ""
  Write-Host "--- CLIENT STDIO ---"
  ($clientStdout -split "`r?`n" | Select-String 'client_stdio' | ForEach-Object { $_.Line })
}
finally {
  Pop-Location
}
