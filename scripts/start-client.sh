#!/usr/bin/env bash
set -euo pipefail

cat >&2 <<'EOF'
archived_client_default_disabled: Web / Bevy 已逻辑归档，通用客户端入口不再启动它们。
现役 Voxia 入口：node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "..."
如用户显式要求归档客户端，请直接进入对应 clients 目录按 README 运行。
EOF
exit 64
