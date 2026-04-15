param(
  [string]$ObserveDir = ".demo/e2e-stdio",
  [int]$BotCount = 1,
  [int]$ServerExitAfter = 24,
  [double]$FinalPositionTolerance = 5.0
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

function Parse-Vector3 {
  param([string]$Value)
  $parts = $Value -split ','
  if ($parts.Length -ne 3) { return $null }
  return [pscustomobject]@{
    X = [double]$parts[0]
    Y = [double]$parts[1]
    Z = [double]$parts[2]
  }
}

function Stop-DemoPorts {
  Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in 29000,29001 } |
    Select-Object -ExpandProperty OwningProcess -Unique |
    ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }

  Wait-Until -TimeoutSeconds 20 -Description "ports 29000/29001 to be free" -Condition {
    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
      Where-Object { $_.LocalPort -in 29000,29001 }
    $null -eq $listeners -or @($listeners).Count -eq 0
  }
}

Stop-DemoPorts

Push-Location $repoRoot
try {
  cmd /c "cd clients\bevy_client && cargo build"

  $configPath = Join-Path $observeDirAbs "human-client.json"
  $server = $null

  for ($attempt = 1; $attempt -le 2; $attempt++) {
    Remove-Item $serverOut,$serverErr,$serverGateObserve -ErrorAction SilentlyContinue

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

    try {
      Wait-Until -TimeoutSeconds 90 -Description "generated client config" -Condition {
        Test-Path $configPath
      }

      if ($BotCount -gt 0) {
        Wait-Until -TimeoutSeconds 90 -Description "demo bot auth in gate observe log" -Condition {
          (Test-Path $serverGateObserve) -and ((Get-Content $serverGateObserve -Raw) -match 'demo_bot_')
        }
      }

      break
    }
    catch {
      if ($server -and -not $server.HasExited) {
        try { $server.Kill() } catch {}
        $server.WaitForExit(5000) | Out-Null
      }

      if ($attempt -eq 2) { throw }

      Start-Sleep -Seconds 2
      Stop-DemoPorts
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

  Wait-Until -TimeoutSeconds 90 -Description "npc actor identity visible to client" -Condition {
    (Test-Path $clientObserve) -and ((Get-Content $clientObserve -Raw) -match 'event="actor_identity".*cid="90001"')
  }

  $client.StandardInput.WriteLine("snapshot")
  $client.StandardInput.WriteLine("transport")
  $client.StandardInput.WriteLine("npcs")
  $client.StandardInput.Flush()
  Start-Sleep -Seconds 2
  $server.StandardInput.WriteLine("npcs")
  $server.StandardInput.WriteLine("npc 90001")
  $server.StandardInput.WriteLine("npc_state 90001")
  if ($BotCount -gt 0) { $server.StandardInput.WriteLine("player_state 42101") }
  $server.StandardInput.Flush()
  Start-Sleep -Milliseconds 750

  $client.StandardInput.WriteLine("skill 1 42101")
  $client.StandardInput.Flush()
  Start-Sleep -Milliseconds 900

  $client.StandardInput.WriteLine("skill 2 90001")
  $client.StandardInput.Flush()
  Start-Sleep -Milliseconds 1200

  $client.StandardInput.WriteLine("target_point 1083 1001 90")
  $client.StandardInput.Flush()
  Start-Sleep -Milliseconds 300

  $client.StandardInput.WriteLine("skill 3")
  $client.StandardInput.Flush()
  Start-Sleep -Milliseconds 1200

  $client.StandardInput.WriteLine("clear_target_point")
  $client.StandardInput.Flush()
  Start-Sleep -Milliseconds 200

  $server.StandardInput.WriteLine("npc_state 90001")
  $server.StandardInput.Flush()
  Start-Sleep -Seconds 3

  $client.StandardInput.WriteLine("skill 4 42101")
  $client.StandardInput.Flush()
  Start-Sleep -Milliseconds 1800
  $client.StandardInput.WriteLine("chat e2e-stdio")
  $client.StandardInput.Flush()
  Start-Sleep -Milliseconds 500
  $client.StandardInput.WriteLine("players")
  $client.StandardInput.WriteLine("npcs")
  $client.StandardInput.WriteLine("position")
  $client.StandardInput.WriteLine("snapshot")
  $client.StandardInput.Flush()
  Start-Sleep -Milliseconds 500
  $server.StandardInput.WriteLine("players")
  $server.StandardInput.WriteLine("connections")
  $server.StandardInput.WriteLine("fastlane")
  $server.StandardInput.WriteLine("player $($config.cid)")
  if ($BotCount -gt 0) { $server.StandardInput.WriteLine("player_state 42101") }
  $server.StandardInput.WriteLine("npcs")
  $server.StandardInput.WriteLine("npc 90001")
  $server.StandardInput.WriteLine("npc_state 90001")
  $server.StandardInput.Flush()
  Start-Sleep -Milliseconds 500
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
    'client_stdio event="snapshot".*remote_npc_count="[1-9]',
    'client_stdio event="transport".*movement_transport=',
    'client_stdio event="npcs".*90001',
    'client_stdio event="chat_sent".*e2e-stdio',
    'client_stdio event="skill_sent".*skill_id="1"',
    'client_stdio event="skill_sent".*skill_id="2"',
    'client_stdio event="target_point".*1083.0,1001.0,90.0',
    'client_stdio event="skill_sent".*skill_id="3".*target_point="1083.0,1001.0,90.0"',
    'client_stdio event="skill_sent".*skill_id="4"',
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
    'server_stdio event="player"',
    'server_stdio event="npcs".*90001',
    'server_stdio event="npc"',
    'server_stdio event="npc_state"'
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

  $npcStateLines = [regex]::Matches($serverStdout, 'server_stdio event="npc_state".*')
  if ($npcStateLines.Count -lt 2) {
    throw "expected multiple npc_state outputs for death/respawn validation"
  }

  $sawDeadNpc = $false
  foreach ($match in $npcStateLines) {
    $line = $match.Value
    $hpMatch = [regex]::Match($line, 'hp: (?<hp>\d+)')
    $aliveMatch = [regex]::Match($line, 'alive: (?<alive>true|false)')
    if ($hpMatch.Success -and $aliveMatch.Success) {
      $hp = [int]$hpMatch.Groups["hp"].Value
      $alive = $aliveMatch.Groups["alive"].Value -eq "true"
      if (-not $alive -and $hp -eq 0) {
        $sawDeadNpc = $true
        break
      }
    }
  }

  if (-not $sawDeadNpc) {
    $clientObserveRaw = Get-Content $clientObserve -Raw
    if ($clientObserveRaw -match 'event="player_state".*cid="90001".*hp="0".*alive="false"') {
      $sawDeadNpc = $true
    }
  }

  if (-not $sawDeadNpc) {
    throw "npc death was never observed via stdio or client observe logs"
  }

  $finalNpcLine = $npcStateLines[$npcStateLines.Count - 1].Value
  $finalNpcHp = [regex]::Match($finalNpcLine, 'hp: (?<hp>\d+)')
  $finalNpcMax = [regex]::Match($finalNpcLine, 'max_hp: (?<max>\d+)')
  $finalNpcAlive = [regex]::Match($finalNpcLine, 'alive: (?<alive>true|false)')
  $finalNpcDeaths = [regex]::Match($finalNpcLine, 'deaths: (?<deaths>\d+)')
  if (-not $finalNpcHp.Success -or -not $finalNpcMax.Success -or -not $finalNpcAlive.Success) {
    throw "final npc_state output missing hp/max_hp/alive"
  }

  if ($finalNpcAlive.Groups["alive"].Value -ne "true") {
    throw "final npc_state output did not show a living respawned NPC"
  }

  if (-not $finalNpcDeaths.Success -or [int]$finalNpcDeaths.Groups["deaths"].Value -lt 1) {
    throw "final npc_state output did not show any npc death before respawn"
  }

  if ($BotCount -gt 0 -and -not ((Get-Content $clientObserve -Raw) -match 'event="player_(enter|move)"')) {
    throw "client observe log did not record remote AOI movement/enter events"
  }

  if ($BotCount -gt 0 -and -not ((Get-Content $clientObserve -Raw) -match 'event="combat_hit"')) {
    throw "client observe log did not record combat_hit after skill cast"
  }

  if (-not ((Get-Content $clientObserve -Raw) -match 'event="combat_hit".*source_cid="90001"')) {
    throw "client observe log did not record NPC-origin combat_hit"
  }

  $observeRaw = Get-Content $clientObserve -Raw
  $requiredEffectPatterns = @(
    'event="effect_event".*skill_id="1".*cue_kind="MeleeArc"',
    'event="effect_event".*skill_id="2".*cue_kind="Projectile"',
    'event="effect_event".*skill_id="3".*cue_kind="AoeRing"',
    'event="effect_event".*skill_id="4".*cue_kind="ChainArc"'
  )

  foreach ($pattern in $requiredEffectPatterns) {
    if ($observeRaw -notmatch $pattern) {
      throw "client observe log missing expected effect pattern: $pattern"
    }
  }

  $clientMatches = [regex]::Matches($clientStdout, 'client_stdio event="position" local_position="(?<pos>[-0-9\.,]+)"')
  $serverMatches = [regex]::Matches($serverStdout, 'server_stdio event="player" payload=%\{player: %\{.*location: \{(?<pos>[-0-9\.]+), (?<posy>[-0-9\.]+), (?<posz>[-0-9\.]+)\}')
  if ($clientMatches.Count -eq 0 -or $serverMatches.Count -eq 0) {
    throw "unable to parse final client/server positions from stdio output"
  }

  $clientMatch = $clientMatches[$clientMatches.Count - 1]
  $serverMatch = $serverMatches[$serverMatches.Count - 1]

  $clientPos = Parse-Vector3 $clientMatch.Groups["pos"].Value
  $serverPos = [pscustomobject]@{
    X = [double]$serverMatch.Groups["pos"].Value
    Y = [double]$serverMatch.Groups["posy"].Value
    Z = [double]$serverMatch.Groups["posz"].Value
  }

  $dx = $clientPos.X - $serverPos.X
  $dy = $clientPos.Y - $serverPos.Y
  $dz = $clientPos.Z - $serverPos.Z
  $distance = [Math]::Sqrt(($dx * $dx) + ($dy * $dy) + ($dz * $dz))
  if ($distance -gt $FinalPositionTolerance) {
    throw "final client/server position drift too large: $distance > $FinalPositionTolerance"
  }

  Write-Host "E2E stdio passed."
  Write-Host "Artifacts: $observeDirAbs"
  Write-Host "Final position drift: $distance"
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
