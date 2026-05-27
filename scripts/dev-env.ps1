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

# ---- 5. 客户端指向服务端 (从上面端口派生, 一般不用改) ------------------------
$env:BEVY_CLIENT_GATE_ADDR = "127.0.0.1:$($env:GATE_TCP_PORT)"
$env:BEVY_CLIENT_AUTH_ADDR = "http://127.0.0.1:$($env:AUTH_PORT)"
$env:GAME_AUTH_BASE_URL = "http://127.0.0.1:$($env:AUTH_PORT)"
$env:GAME_WS_URL        = "ws://127.0.0.1:$($env:AUTH_PORT)/ingame/ws"

# ---- 6. 非网页客户端默认用户名 (基础名, 自动生成会拼成 <name>_<4hex>) --------
# 显式 -Username bob    → 直接用 "bob"
# 不带 -Username         → 自动生成 "alice_4f2a" 之类, 多开零碰撞
$env:BEVY_CLIENT_USERNAME = "alice"
$env:GAME_CLIENT_USERNAME = "alice"

# ---- 7. Hex/Mix 在 Windows 上的稳定性调参 ------------------------------------
$env:HEX_HTTP_CONCURRENCY = "1"
$env:HEX_HTTP_TIMEOUT     = "120"

# ---- 8. web_client 默认运行模式 (demo 用; vite 直接读 import.meta.env) -------
# 名字与 web_client/src/app/bootstrap.ts 对齐, 不要随便改.
# 想退回到纯本地演示, 把 VITE_MOVEMENT_TRANSPORT 改成 "simulated"
# 或 VITE_VOXEL_SYNC 改成 "offline".
$env:VITE_MOVEMENT_TRANSPORT      = "server"     # server | simulated
$env:VITE_INGAME_PROXY_TARGET     = $env:GAME_AUTH_BASE_URL
$env:VITE_GAME_WS_URL             = $env:GAME_WS_URL
# Do not set VITE_GAME_CLIENT_USERNAME by default. The web client generates a
# fresh dev username per page load so multiple tabs do not fight over one cid.
# Set VITE_GAME_CLIENT_USERNAME manually after loading this file only when a
# fixed web identity is required.
Remove-Item Env:\VITE_GAME_CLIENT_USERNAME -ErrorAction SilentlyContinue
$env:VITE_VOXEL_SYNC              = "online"     # online | offline
$env:VITE_VOXEL_LOGICAL_SCENE_ID  = "1"          # 与 DevSeed 创建的场景一致
$env:VITE_VOXEL_SUBSCRIBE_RADIUS  = "1"          # ChunkSubscribe 半径 (L_inf)
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
Write-Host "  VITE_GAME_CLIENT_USERNAME    = <auto per web page load>"
Write-Host "  VITE_VOXEL_SYNC              = $env:VITE_VOXEL_SYNC"
Write-Host "  VITE_VOXEL_LOGICAL_SCENE_ID  = $env:VITE_VOXEL_LOGICAL_SCENE_ID"
Write-Host "  VITE_VOXEL_SUBSCRIBE_RADIUS  = $env:VITE_VOXEL_SUBSCRIBE_RADIUS"
Write-Host "  VITE_VOXEL_DEV_SEED          = $env:VITE_VOXEL_DEV_SEED"
Write-Host "  VITE_VOXEL_PRIME_DEMO_BLOCK  = $env:VITE_VOXEL_PRIME_DEMO_BLOCK"
Write-Host ""
