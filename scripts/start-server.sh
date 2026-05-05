#!/usr/bin/env bash
# =============================================================================
# 启动 Elixir umbrella 集群（单节点，macOS / Linux / WSL）
# =============================================================================
# 用法：
#   ./scripts/start-server.sh              # 前台 iex（交互式 shell，默认）
#   ./scripts/start-server.sh --detach     # 后台 elixir run --no-halt（无交互
#                                          #   shell；适合 stdout/stderr 被外
#                                          #   层重定向 / nohup / launchd）
#
# 所有环境变量从 scripts/dev-env.sh 继承，想改端口 / cookie / 节点名 / DB url，
# 改那个文件即可，不用动本脚本。
#
# 双 Ctrl+C 退出 iex；后台模式发 SIGTERM 即可优雅停。
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./dev-env.sh
. "${SCRIPT_DIR}/dev-env.sh"

DETACH=0
EXTRA_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --detach|-d)
      DETACH=1
      ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      EXTRA_ARGS+=("$arg")
      ;;
  esac
done

if [ -t 1 ]; then
  GREEN=$'\033[32m'; RESET=$'\033[0m'
else
  GREEN=""; RESET=""
fi

echo "${GREEN}[start-server] Booting node ${NODE_NAME} with cookie ${ERLANG_COOKIE} ...${RESET}"
echo "[start-server] AUTH=${AUTH_PORT}  GATE_TCP=${GATE_TCP_PORT}  GATE_UDP=${GATE_UDP_PORT}"

cd "${REPO_ROOT}"

if [ "${DETACH}" -eq 1 ]; then
  echo "[start-server] Mode: detach (elixir --no-halt)"
  echo ""
  exec elixir --name "${NODE_NAME}" --cookie "${ERLANG_COOKIE}" \
    -S mix run --no-halt "${EXTRA_ARGS[@]}"
else
  echo "[start-server] Mode: foreground iex (Ctrl+C twice to stop)"
  echo ""
  exec iex --name "${NODE_NAME}" --cookie "${ERLANG_COOKIE}" \
    -S mix "${EXTRA_ARGS[@]}"
fi
