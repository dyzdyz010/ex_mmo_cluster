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
Remove-Item $serverOut,$serverErr,$clientOut,$clientErr,$clientObserve -ErrorAction SilentlyContinue

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
  $serverPsi.Arguments = "/c set HEX_HTTP_CONCURRENCY=1&& set HEX_HTTP_TIMEOUT=120&& mix demo.run --stdio --bot-count $BotCount --exit-after $ServerExitAfter --observe_dir $ObserveDir"
  $serverPsi.RedirectStandardInput = $true
  $serverPsi.RedirectStandardOutput = $true
  $serverPsi.RedirectStandardError = $true
  $serverPsi.UseShellExecute = $false
  $serverPsi.CreateNoWindow = $true

  $server = New-Object System.Diagnostics.Process
  $server.StartInfo = $serverPsi
  $server.Start() | Out-Null

  Start-Sleep -Seconds 10

  $configPath = Join-Path $repoRoot ".demo\human-client.json"
  if (-not (Test-Path $configPath)) {
    throw "missing generated client config at $configPath"
  }

  $config = Get-Content $configPath | ConvertFrom-Json

  $clientPsi = New-Object System.Diagnostics.ProcessStartInfo
  $clientPsi.FileName = Join-Path $repoRoot "clients\bevy_client\target\debug\bevy_client.exe"
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

  Start-Sleep -Seconds 6

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

  $serverStdout = $server.StandardOutput.ReadToEnd()
  $serverStderr = $server.StandardError.ReadToEnd()
  $clientStdout = $client.StandardOutput.ReadToEnd()
  $clientStderr = $client.StandardError.ReadToEnd()

  Set-Content $serverOut $serverStdout
  Set-Content $serverErr $serverStderr
  Set-Content $clientOut $clientStdout
  Set-Content $clientErr $clientStderr

  $requiredClientPatterns = @(
    'client_stdio event="snapshot".*scene_joined="true"',
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
