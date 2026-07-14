# =============================================================================
# 本地开发环境配置 - 单点修改入口
# =============================================================================
# 想改端口 / 用户名 / 数据库地址, 只改本文件, 两个 start-*.ps1 脚本会自动继承.
#
# 手动加载进当前 shell (所有变量立即生效):
#   . .\scripts\dev-env.ps1    # dot-source
#
# 或直接被 scripts\start-server.ps1 / start-client.ps1 调用, 无需手动 source.
# =============================================================================

# ---- 1. 服务端端口 -----------------------------------------------------------
$env:AUTH_PORT     = "20000"     # Phoenix HTTP (auth_server)
$env:VISUALIZE_PORT = "20001"    # Phoenix HTTP (visualize_server)
$env:GATE_TCP_PORT = "20002"    # gate_server TCP (packet:4 分帧)
$env:GATE_UDP_PORT = "20003"    # gate_server UDP (movement 快车道)

# ---- 2. 服务端开关 -----------------------------------------------------------
$env:PHX_SERVER     = "true"    # 让 Phoenix 真的启 HTTP listener
$env:DEV_AUTO_LOGIN = "true"    # 开放 /ingame/auto_login (生产环境务必关掉)
$env:VOXEL_DEV_REGION_BOOTSTRAP = "true"  # 服务端启动后准备默认体素区域, 浏览器只读取/订阅

# ---- 3. 数据库 ---------------------------------------------------------------
# 默认指向 Docker 容器 yggdrasil-postgres-1 (本机 5432).
# 指向其他库时取消下面注释:
# $env:DATABASE_URL = "ecto://postgres:postgres@127.0.0.1:5432/mmo_dev"

# ---- 4. Erlang 节点 ----------------------------------------------------------
$env:ERLANG_COOKIE = "mmo"
# Windows can reserve TCP 4369 in an excluded port range. Keep all local
# Erlang nodes on the same non-reserved EPMD port.
$env:ERL_EPMD_PORT = "43690"

# Default to a short node name. It avoids Erlang parsing the Windows hosts
# file during local startup, which can print inet_parse warnings when the
# hosts file has a UTF-8 BOM. Use "cluster@127.0.0.1" only when long names
# are explicitly needed; start-server.ps1 will switch to --name.
$env:NODE_NAME     = "cluster"

# ---- 5. 归档客户端兼容变量 ---------------------------------------------------
# 以下 BEVY / GAME / VITE 变量只供用户显式运行归档客户端专用工具时兼容读取；
# 它们不是默认客户端配置面，也不会把 Web / Bevy 恢复为现役客户端。
$env:BEVY_CLIENT_GATE_ADDR = "127.0.0.1:$($env:GATE_TCP_PORT)"
$env:BEVY_CLIENT_AUTH_ADDR = "http://127.0.0.1:$($env:AUTH_PORT)"
$env:GAME_AUTH_BASE_URL = "http://127.0.0.1:$($env:AUTH_PORT)"
$env:GAME_WS_URL        = "ws://127.0.0.1:$($env:AUTH_PORT)/ingame/ws"

# ---- 6. 归档客户端兼容用户名 -------------------------------------------------
# 显式 -Username bob    → 直接用 "bob"
# 不带 -Username         → 自动生成 "alice_4f2a" 之类, 多开零碰撞
$env:BEVY_CLIENT_USERNAME = "alice"
$env:GAME_CLIENT_USERNAME = "alice"

# ---- 7. Hex/Mix 在 Windows 上的稳定性调参 ------------------------------------
$env:HEX_HTTP_CONCURRENCY = "1"
$env:HEX_HTTP_TIMEOUT     = "120"

# ---- 8. 归档 web_client 兼容运行模式（仅显式专用工具） ----------------------
# 名字与 web_client/src/app/bootstrap.ts 对齐, 不要随便改.
# 想退回到纯本地演示, 把 VITE_MOVEMENT_TRANSPORT 改成 "simulated"
# 或 VITE_VOXEL_SYNC 改成 "offline".
$env:VITE_MOVEMENT_TRANSPORT      = "server"     # server | simulated
$env:VITE_INGAME_PROXY_TARGET     = $env:GAME_AUTH_BASE_URL
$env:VITE_GAME_WS_URL             = $env:GAME_WS_URL
$env:VITE_GAME_CLIENT_USERNAME    = $env:GAME_CLIENT_USERNAME
$env:VITE_VOXEL_SYNC              = "online"     # online | offline
$env:VITE_VOXEL_LOGICAL_SCENE_ID  = "1"          # 与 DevSeed 创建的场景一致
$env:VITE_VOXEL_DIAGNOSTIC_PARTIAL_WINDOW = "0"  # 仅自动化专项可设 1；生产固定完整 XYZ 窗口
$env:VITE_VOXEL_DEV_SEED          = "0"          # 1 = 旧调试模式: 浏览器启动时主动请求准备默认区域
$env:VITE_VOXEL_PRIME_DEMO_BLOCK  = "0"          # 1 = 首份空 chunk 到达后自动放一颗 demo 方块 (默认 0: 服务端 DevSeed 已经种好平台)

# ---- 9. 打印已生效的配置 -----------------------------------------------------
Write-Host "[dev-env] Config loaded:" -ForegroundColor Cyan
Write-Host "  AUTH_PORT                    = $env:AUTH_PORT"
Write-Host "  VISUALIZE_PORT               = $env:VISUALIZE_PORT"
Write-Host "  GATE_TCP_PORT                = $env:GATE_TCP_PORT"
Write-Host "  GATE_UDP_PORT                = $env:GATE_UDP_PORT"
Write-Host "  PHX_SERVER                   = $env:PHX_SERVER"
Write-Host "  DEV_AUTO_LOGIN               = $env:DEV_AUTO_LOGIN"
Write-Host "  VOXEL_DEV_REGION_BOOTSTRAP   = $env:VOXEL_DEV_REGION_BOOTSTRAP"
Write-Host "  NODE_NAME                    = $env:NODE_NAME"
Write-Host "  ERL_EPMD_PORT                = $env:ERL_EPMD_PORT"
Write-Host "  BEVY_CLIENT_GATE_ADDR        = $env:BEVY_CLIENT_GATE_ADDR"
Write-Host "  BEVY_CLIENT_AUTH_ADDR        = $env:BEVY_CLIENT_AUTH_ADDR"
Write-Host "  BEVY_CLIENT_USERNAME         = $env:BEVY_CLIENT_USERNAME"
Write-Host "  GAME_AUTH_BASE_URL           = $env:GAME_AUTH_BASE_URL"
Write-Host "  GAME_WS_URL                  = $env:GAME_WS_URL"
Write-Host "  GAME_CLIENT_USERNAME         = $env:GAME_CLIENT_USERNAME"
Write-Host "  VITE_MOVEMENT_TRANSPORT      = $env:VITE_MOVEMENT_TRANSPORT"
Write-Host "  VITE_INGAME_PROXY_TARGET     = $env:VITE_INGAME_PROXY_TARGET"
Write-Host "  VITE_GAME_WS_URL             = $env:VITE_GAME_WS_URL"
Write-Host "  VITE_GAME_CLIENT_USERNAME    = $env:VITE_GAME_CLIENT_USERNAME"
Write-Host "  VITE_VOXEL_SYNC              = $env:VITE_VOXEL_SYNC"
Write-Host "  VITE_VOXEL_LOGICAL_SCENE_ID  = $env:VITE_VOXEL_LOGICAL_SCENE_ID"
Write-Host "  VITE_VOXEL_DIAGNOSTIC_PARTIAL_WINDOW = $env:VITE_VOXEL_DIAGNOSTIC_PARTIAL_WINDOW"
Write-Host "  VITE_VOXEL_DEV_SEED          = $env:VITE_VOXEL_DEV_SEED"
Write-Host "  VITE_VOXEL_PRIME_DEMO_BLOCK  = $env:VITE_VOXEL_PRIME_DEMO_BLOCK"
Write-Host ""
