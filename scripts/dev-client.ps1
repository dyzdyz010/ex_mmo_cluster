[CmdletBinding()]
param(
  [string]$Username = "dev_user",
  [switch]$Stdio,
  [switch]$Release,
  [switch]$SkipBuild,
  [string]$GateAddr = "127.0.0.1:20002",
  [string]$AuthAddr = "http://127.0.0.1:20000",
  [string]$ObserveLog,
  [string]$Script,
  [double]$MovementSpeed,
  [int]$MoveIntervalMs
)

$ErrorActionPreference = "Stop"
throw 'archived_client_default_disabled: web_client and bevy_client are archived and disabled from the default client entry. Active Voxia entry: node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "...". Explicit archived-client work must use its own README.'
