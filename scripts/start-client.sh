#!/usr/bin/env bash
# =============================================================================
# 启动 web_client（Vite dev server，macOS / Linux / WSL）
# =============================================================================
# 用法（默认前台跑 vite，浏览器手动开 http://localhost:5173）：
#   ./scripts/start-client.sh
#
# 自定义端口（默认 5173）：
#   PORT=5174 ./scripts/start-client.sh
#
# 跳过依赖检查（npm install 已经跑过了）：
#   SKIP_INSTALL=1 ./scripts/start-client.sh
#
# 所有环境变量从 scripts/dev-env.sh 继承（GAME_AUTH_BASE_URL / GAME_WS_URL
# 默认指向 dev-env.sh 里的 ${AUTH_PORT}）。
#
# 注意：bevy_client 已冻结，不在本脚本支持范围内；CLAUDE.md 写的客户端策略
# 是所有新功能只动 web_client。
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLIENT_DIR="${REPO_ROOT}/clients/web_client"

# shellcheck source=./dev-env.sh
. "${SCRIPT_DIR}/dev-env.sh"

if [ ! -d "${CLIENT_DIR}" ]; then
  echo "[start-client] FATAL: ${CLIENT_DIR} 不存在" >&2
  exit 1
fi

if [ -t 1 ]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; RESET=""
fi

cd "${CLIENT_DIR}"

if [ "${SKIP_INSTALL:-0}" != "1" ]; then
  if [ ! -d node_modules ] || [ "package.json" -nt "node_modules/.package-lock.json" ]; then
    echo "${YELLOW}[start-client] node_modules 缺失或过期，跑 npm install ...${RESET}"
    npm install
  fi
fi

# 透传给 vite，使其知道 server 地址。web_client 自己读 import.meta.env 时
# 用的是 VITE_GAME_*，但 dev-env.sh 给的是 GAME_*；这里映射一遍。
export VITE_GAME_AUTH_BASE_URL="${GAME_AUTH_BASE_URL}"
export VITE_GAME_WS_URL="${GAME_WS_URL}"
export VITE_GAME_CLIENT_USERNAME="${GAME_CLIENT_USERNAME}"

PORT="${PORT:-5173}"

echo "${GREEN}[start-client] Launching web_client (port=${PORT})${RESET}"
echo "[start-client] Auth=${VITE_GAME_AUTH_BASE_URL}  WS=${VITE_GAME_WS_URL}  Username=${VITE_GAME_CLIENT_USERNAME}"
echo "[start-client] Vite will hot-reload on src changes; Ctrl+C to stop."
echo ""

exec npm run dev -- --port "${PORT}" --host
