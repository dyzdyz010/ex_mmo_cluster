# Drives the headless bevy_client in --stdio mode with timed command writes, so
# async server responses (snapshots/deltas) land before the next probe. Reads a
# script file whose lines are either stdio commands or `#sleep <ms>` directives.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/va-stdio.ps1 `
#     -ScriptFile path\to\cmds.txt -Username e2e_surface [-WaitForSceneMs 30000]
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ScriptFile,
  [string]$Username = "e2e_va",
  [string]$GateAddr = "127.0.0.1:20002",
  [string]$AuthAddr = "http://127.0.0.1:20000",
  [int]$WaitForSceneMs = 30000
)

$ErrorActionPreference = "Stop"
$crateRoot = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $crateRoot "target\debug\bevy_client.exe"
if (-not (Test-Path $exe)) { throw "client binary not found: $exe (cargo build --bin bevy_client)" }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = "--headless --stdio --username $Username --wait-for-scene-ms $WaitForSceneMs"
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.EnvironmentVariables["BEVY_CLIENT_GATE_ADDR"] = $GateAddr
$psi.EnvironmentVariables["BEVY_CLIENT_AUTH_ADDR"] = $AuthAddr

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi

# Async stdout/stderr accumulation.
$sb = New-Object System.Text.StringBuilder
$onOut = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
  if ($EventArgs.Data) { [void]$Event.MessageData.AppendLine("OUT " + $EventArgs.Data) }
} -MessageData $sb
$onErr = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
  if ($EventArgs.Data) { [void]$Event.MessageData.AppendLine("ERR " + $EventArgs.Data) }
} -MessageData $sb

[void]$proc.Start()
$proc.BeginOutputReadLine()
$proc.BeginErrorReadLine()

foreach ($raw in Get-Content $ScriptFile) {
  $line = $raw.Trim()
  if ($line -eq "" -or $line.StartsWith("##")) { continue }
  if ($line -match "^#sleep\s+(\d+)") {
    Start-Sleep -Milliseconds ([int]$Matches[1])
    continue
  }
  $proc.StandardInput.WriteLine($line)
  $proc.StandardInput.Flush()
  Start-Sleep -Milliseconds 150
}

# Ensure the client exits even if the script forgot `stop`.
try { $proc.StandardInput.WriteLine("stop"); $proc.StandardInput.Flush() } catch {}
if (-not $proc.WaitForExit(15000)) { $proc.Kill() }
Start-Sleep -Milliseconds 200

Unregister-Event -SourceIdentifier $onOut.Name -ErrorAction SilentlyContinue
Unregister-Event -SourceIdentifier $onErr.Name -ErrorAction SilentlyContinue

Write-Output $sb.ToString()
