# =============================================================================
# 本地开发环境配置 - 单点修改入口（macOS / Linux / WSL）
# =============================================================================
# 想改端口 / 用户名 / 数据库地址，只改本文件，两个 start-*.sh 都会继承。
#
# 手动加载进当前 shell（所有变量立即生效）：
#   source scripts/dev-env.sh
#
# 或直接被 scripts/start-server.sh / start-client.sh 调用，无需手动 source。
#
# 这是 .sh 文件，bash / zsh 都可 source。
# Windows 同名 .ps1 在 scripts/dev-env.ps1，两边的字段一一对应。
# =============================================================================

# ---- 1. 服务端端口 -----------------------------------------------------------
export AUTH_PORT="${AUTH_PORT:-20000}"          # Phoenix HTTP（auth_server）
export VISUALIZE_PORT="${VISUALIZE_PORT:-20001}" # Phoenix HTTP（visualize_server）
export GATE_TCP_PORT="${GATE_TCP_PORT:-20002}" # gate_server TCP（packet:4 分帧）
export GATE_UDP_PORT="${GATE_UDP_PORT:-20003}" # gate_server UDP（movement 快车道）

# ---- 2. 服务端开关 -----------------------------------------------------------
export PHX_SERVER="${PHX_SERVER:-true}"           # 让 Phoenix 真的启 HTTP listener
export DEV_AUTO_LOGIN="${DEV_AUTO_LOGIN:-true}"   # 开放 /ingame/auto_login（生产环境务必关掉）

# ---- 3. 数据库 ---------------------------------------------------------------
# 默认 = macOS 上 brew 装的本机 postgres（postgres@:5432，无密码）。
# 想换库（远程 / Docker / 容器名等），把下行注释取消并改成你自己的：
# export DATABASE_URL="ecto://postgres:postgres@127.0.0.1:5432/mmo_dev"

# ---- 4. Erlang 节点 ----------------------------------------------------------
export ERLANG_COOKIE="${ERLANG_COOKIE:-mmo}"
export NODE_NAME="${NODE_NAME:-cluster@127.0.0.1}"

# ---- 5. 客户端指向服务端（从上面端口派生，一般不用改） ----------------------
export GAME_AUTH_BASE_URL="${GAME_AUTH_BASE_URL:-http://127.0.0.1:${AUTH_PORT}}"
export GAME_WS_URL="${GAME_WS_URL:-ws://127.0.0.1:${AUTH_PORT}/ingame/ws}"

# ---- 6. 客户端默认用户名 ----------------------------------------------------
# web_client 进游戏时用这个名字走 /ingame/auto_login；不显式覆盖 = "alice"。
export GAME_CLIENT_USERNAME="${GAME_CLIENT_USERNAME:-alice}"

# ---- 7. web_client 默认运行模式（demo 用，跑 vite 时直接被 import.meta.env 读）
# 这些 VITE_* 名字是 web_client/src/app/bootstrap.ts 直接读的，不要随便改。
# 想退回到纯本地（不连服务器）演示，覆盖 VITE_MOVEMENT_TRANSPORT=simulated
# 或 VITE_VOXEL_SYNC=offline 即可。
export VITE_MOVEMENT_TRANSPORT="${VITE_MOVEMENT_TRANSPORT:-server}"            # server | simulated
export VITE_INGAME_PROXY_TARGET="${VITE_INGAME_PROXY_TARGET:-${GAME_AUTH_BASE_URL}}"
export VITE_GAME_WS_URL="${VITE_GAME_WS_URL:-${GAME_WS_URL}}"
export VITE_GAME_CLIENT_USERNAME="${VITE_GAME_CLIENT_USERNAME:-${GAME_CLIENT_USERNAME}}"
export VITE_VOXEL_SYNC="${VITE_VOXEL_SYNC:-online}"                            # online | offline
export VITE_VOXEL_LOGICAL_SCENE_ID="${VITE_VOXEL_LOGICAL_SCENE_ID:-1}"         # 与 DevSeed 创建的场景一致
export VITE_VOXEL_SUBSCRIBE_RADIUS="${VITE_VOXEL_SUBSCRIBE_RADIUS:-1}"         # ChunkSubscribe 半径（L_inf）
export VITE_VOXEL_DEV_SEED="${VITE_VOXEL_DEV_SEED:-1}"                         # 1 = 启动时调 /ingame/voxel/dev_seed
export VITE_VOXEL_PRIME_DEMO_BLOCK="${VITE_VOXEL_PRIME_DEMO_BLOCK:-0}"         # 1 = 首份空 chunk 到达后自动放一颗 demo 方块（默认 0：服务端 DevSeed 已经种好平台）

# ---- 8. 打印已生效的配置 -----------------------------------------------------
if [ -t 1 ]; then
  CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  CYAN=""; RESET=""
fi

echo "${CYAN}[dev-env] Config loaded:${RESET}"
echo "  AUTH_PORT                     = ${AUTH_PORT}"
echo "  VISUALIZE_PORT                = ${VISUALIZE_PORT}"
echo "  GATE_TCP_PORT                 = ${GATE_TCP_PORT}"
echo "  GATE_UDP_PORT                 = ${GATE_UDP_PORT}"
echo "  PHX_SERVER                    = ${PHX_SERVER}"
echo "  DEV_AUTO_LOGIN                = ${DEV_AUTO_LOGIN}"
echo "  NODE_NAME                     = ${NODE_NAME}"
echo "  GAME_AUTH_BASE_URL            = ${GAME_AUTH_BASE_URL}"
echo "  GAME_WS_URL                   = ${GAME_WS_URL}"
echo "  GAME_CLIENT_USERNAME          = ${GAME_CLIENT_USERNAME}"
echo "  VITE_MOVEMENT_TRANSPORT       = ${VITE_MOVEMENT_TRANSPORT}"
echo "  VITE_INGAME_PROXY_TARGET      = ${VITE_INGAME_PROXY_TARGET}"
echo "  VITE_GAME_WS_URL              = ${VITE_GAME_WS_URL}"
echo "  VITE_GAME_CLIENT_USERNAME     = ${VITE_GAME_CLIENT_USERNAME}"
echo "  VITE_VOXEL_SYNC               = ${VITE_VOXEL_SYNC}"
echo "  VITE_VOXEL_LOGICAL_SCENE_ID   = ${VITE_VOXEL_LOGICAL_SCENE_ID}"
echo "  VITE_VOXEL_SUBSCRIBE_RADIUS   = ${VITE_VOXEL_SUBSCRIBE_RADIUS}"
echo "  VITE_VOXEL_DEV_SEED           = ${VITE_VOXEL_DEV_SEED}"
echo "  VITE_VOXEL_PRIME_DEMO_BLOCK   = ${VITE_VOXEL_PRIME_DEMO_BLOCK}"
echo ""
