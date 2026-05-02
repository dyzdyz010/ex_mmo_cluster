# 2026-04-12 CLI 可观测联调方案

## 目标

以后在联调 `ex_mmo_cluster` 的客户端与服务端时，尽量不依赖截图或视觉判断，而是通过：

1. **CLI 控制入口**
2. **结构化运行日志**
3. **可回放 / 可比对的 headless 调试流程**

来确认：

- 是否连上 gate
- auth / enter-scene 是否成功
- UDP fast-lane 是否 attach
- movement / chat / skill 是否正确收发
- 服务端权威位置、AOI 扇出、错误回复是否符合预期

## 方案

### 1. 服务端结构化 observe 日志

为 `gate_server` 与 `scene_server` 增加 CLI observe 文件输出：

- `gate_server`：记录 TCP/UDP 接入、auth、enter-scene、movement、fast-lane attach/detach、错误回复
- `scene_server`：记录角色加载、位置更新、movement tick、chat、skill、退出

本地 smoke runner 或显式环境变量会把它们写到可复现目录。推荐路径：

- `.demo/observe/server-gate.log`
- `.demo/observe/server-scene.log`

对应环境变量：

- `GATE_SERVER_OBSERVE_LOG=.demo/observe/server-gate.log`
- `SCENE_SERVER_OBSERVE_LOG=.demo/observe/server-scene.log`

### 2. 集成式 stdio 接口

CLI 调试不是单独做一套“替代程序”，而是作为正常程序的附加接口：

- **服务端**：`gate_server` 可选启用 stdio interface，在运行中的真实服务端进程内接受 stdin 命令并通过 stdout 回应
- **客户端**：Bevy 正常客户端可选启用 stdio interface，在 GUI 正常运行时额外接受 stdin 命令

这意味着：

- 正常程序逻辑不需要切换 target
- GUI / 网络 / 场景仍然照常运行
- agent 可以通过 stdio 与运行中的程序交换状态和控制命令

当前约定：

- 服务端命令：`help` / `snapshot` / `connections` / `sessions` / `fastlane` / `players` / `player <cid>` / `player_state <cid>`
- 客户端命令：`help` / `snapshot` / `position` / `transport` / `players` / `chat <text>` / `skill <id>` / `move <dir> <ms>` / `stop` / `quit`

### 3. 客户端结构化 observe 日志

Bevy 客户端增加：

- 网络线程 outbound / inbound 结构化日志
- GUI 输入意图日志（移动方向变化、聊天开关、技能触发）
- 可选 stdout 输出
- 可选文件输出

默认人类客户端配置会注入：

- `BEVY_CLIENT_OBSERVE_LOG`

## 4. Headless CLI 客户端

客户端还保留 headless 模式，用同一套真实协议接入 gate / scene，不打开图形窗口，只做：

- 连接
- 认证
- 进入场景
- 按脚本发送 movement / chat / skill
- 输出结构化日志

它主要用于自动化 smoke / CI 风格验证，不替代上面的集成式 stdio 接口。

## CLI 使用方式

### 启动带 observe 的完整运行时 smoke

```bash
node scripts/run_ws_dual_smoke_supervised.js
```

该 runner 会启动本地 auth / gate / scene / data 等真实运行路径，自动准备
PostgreSQL smoke 数据，并把 boot / probe / summary 产物写到 `.demo/observe/`。

### 启动带服务端 stdio 的本地 smoke runtime

```bash
mix run --no-start scripts/ws_smoke_db_setup.exs
GATE_SERVER_STDIO=1 \
GATE_SERVER_OBSERVE_LOG=.demo/observe/server-gate.log \
SCENE_SERVER_OBSERVE_LOG=.demo/observe/server-scene.log \
mix run --no-start scripts/ws_smoke_boot.exs
```

PowerShell 等价写法：

```powershell
$env:GATE_SERVER_STDIO = "1"
$env:GATE_SERVER_OBSERVE_LOG = ".demo/observe/server-gate.log"
$env:SCENE_SERVER_OBSERVE_LOG = ".demo/observe/server-scene.log"
mix run --no-start scripts/ws_smoke_db_setup.exs
mix run --no-start scripts/ws_smoke_boot.exs
```

启动后可直接在服务端 stdin 输入：

- `snapshot`
- `sessions`
- `players`
- `player 42001`

### 启动正常客户端并开启 stdio

```bash
cargo run -- --stdio
```

### 启动同一二进制的 headless + stdio

```bash
clients/bevy_client/target/debug/bevy_client.exe --headless --stdio
```

### 查看最新 observe 日志

```bash
tail -n 40 .demo/observe/server-gate.log .demo/observe/server-scene.log
```

PowerShell：

```powershell
Get-Content .demo/observe/server-gate.log -Tail 40
Get-Content .demo/observe/server-scene.log -Tail 40
```

### 启动 headless 客户端

```bash
cargo run -- --headless --observe-stdout --script "wait:500,move:w:600,chat:hello,skill:1,wait:1500"
```

### Headless 脚本语法

- `wait:<ms>`
- `move:<w|a|s|d|up|down|left|right>:<ms>`
- `chat:<text>`
- `skill:<id>`
- `snapshot`

## 调试原则

- 优先使用**集成式 stdio 接口 + observe 日志**看真实运行中的程序。
- 需要批量自动化验证时，再使用 headless 客户端。
- 先看客户端/服务端 stdio 响应，再对照 gate / scene observe 日志。
- 优先根据“连接状态 + 协议收发 + 坐标变化 + 错误码”判断问题。
- 图形界面只作为补充，不再作为唯一验收面。

## 5. 可复用 E2E harness

仓库当前保留三个无截图回归入口：

1. 完整运行时 WebSocket 双客户端 smoke：

```bash
node scripts/run_ws_dual_smoke_supervised.js
```

它会自动启动 runtime、运行 probe、写 `.demo/observe/ws-dual-*` 与
`.demo/observe/ws-dual-smoke-summary.json`，是当前 CI 使用的完整运行时 smoke。

2. Bevy movement stdio 单元代理：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\e2e-stdio-movement.ps1
```

POSIX：

```bash
scripts/e2e-stdio-movement.sh
```

它通过 `cargo test --lib` 验证 reconcile / smoothing / hard-snap 不变式。

3. 已有本地服务上的 Bevy headless 真实链路：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\e2e-live-movement.ps1
```

它要求 `auth/gate/scene` 已经在默认端口或参数指定端口运行，然后用同一
Bevy 二进制的 `--headless --stdio` 入口发 movement 命令并校验 drift。

旧入口 `scripts/e2e-stdio.ps1` 现在只是兼容包装器，不再调用已归档的
`mix demo.run`。默认 `-Mode movement-proxy` 会转到
`scripts/e2e-stdio-movement.ps1`；需要完整 runtime smoke 时使用
`-Mode ws-dual`；需要连接已有服务时使用 `-Mode live-movement`。
