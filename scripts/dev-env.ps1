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
$env:AUTH_PORT     = "4000"     # Phoenix HTTP (auth_server)
$env:GATE_TCP_PORT = "29000"    # gate_server TCP (packet:4 分帧)
$env:GATE_UDP_PORT = "29001"    # gate_server UDP (movement 快车道)

# ---- 2. 服务端开关 -----------------------------------------------------------
$env:PHX_SERVER     = "true"    # 让 Phoenix 真的启 HTTP listener
$env:DEV_AUTO_LOGIN = "true"    # 开放 /ingame/auto_login (生产环境务必关掉)

# ---- 3. 数据库 ---------------------------------------------------------------
# 默认指向 Docker 容器 yggdrasil-postgres-1 (本机 5432).
# 指向其他库时取消下面注释:
# $env:DATABASE_URL = "ecto://postgres:postgres@127.0.0.1:5432/mmo_dev"

# ---- 4. Erlang 节点 ----------------------------------------------------------
$env:ERLANG_COOKIE = "mmo"
$env:NODE_NAME     = "cluster@127.0.0.1"

# ---- 5. 客户端指向服务端 (从上面端口派生, 一般不用改) ------------------------
$env:BEVY_CLIENT_GATE_ADDR = "127.0.0.1:$($env:GATE_TCP_PORT)"
$env:BEVY_CLIENT_AUTH_ADDR = "http://127.0.0.1:$($env:AUTH_PORT)"

# ---- 6. 客户端默认用户名 (基础名, 自动生成会拼成 <name>_<4hex>) --------------
# 显式 -Username bob    → 直接用 "bob"
# 不带 -Username         → 自动生成 "alice_4f2a" 之类, 多开零碰撞
$env:BEVY_CLIENT_USERNAME = "alice"

# ---- 7. Hex/Mix 在 Windows 上的稳定性调参 ------------------------------------
$env:HEX_HTTP_CONCURRENCY = "1"
$env:HEX_HTTP_TIMEOUT     = "120"

# ---- 8. 打印已生效的配置 -----------------------------------------------------
Write-Host "[dev-env] Config loaded:" -ForegroundColor Cyan
Write-Host "  AUTH_PORT             = $env:AUTH_PORT"
Write-Host "  GATE_TCP_PORT         = $env:GATE_TCP_PORT"
Write-Host "  GATE_UDP_PORT         = $env:GATE_UDP_PORT"
Write-Host "  PHX_SERVER            = $env:PHX_SERVER"
Write-Host "  DEV_AUTO_LOGIN        = $env:DEV_AUTO_LOGIN"
Write-Host "  NODE_NAME             = $env:NODE_NAME"
Write-Host "  BEVY_CLIENT_GATE_ADDR = $env:BEVY_CLIENT_GATE_ADDR"
Write-Host "  BEVY_CLIENT_AUTH_ADDR = $env:BEVY_CLIENT_AUTH_ADDR"
Write-Host "  BEVY_CLIENT_USERNAME  = $env:BEVY_CLIENT_USERNAME"
Write-Host ""
