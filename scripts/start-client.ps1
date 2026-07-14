param(
    [string]$Username,
    [switch]$Headless,
    [switch]$Stdio,
    [string]$ExtraArgs
)

$ErrorActionPreference = "Stop"
throw 'archived_client_default_disabled: web_client and bevy_client are archived and disabled from the default client entry. Active Voxia entry: node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "...". Explicit archived-client work must use its own README.'
