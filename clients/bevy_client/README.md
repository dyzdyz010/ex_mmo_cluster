# Bevy Debug Client

一个面向当前 `ex_mmo_cluster` 服务端状态的 **Bevy 2D 联调客户端**。

## 当前支持

- TCP 连接 gate
- token 认证
- 进入场景
- UDP fast-lane attach
- 2D AOI 可视化
- 移动同步（attach 成功后 movement uplink / `PlayerMove` downlink 优先走 UDP）
- 场景内聊天
- 简单技能（默认技能 ID `1`）
- HUD 展示 control / movement transport、fast-lane 状态、AOI peer 数
- 集成式 stdio 调试接口
- CLI/headless 调试模式（自动化 smoke 用）
- 结构化 observe 日志（客户端输入 + 网络收发）

## 推荐 demo 启动方式

在仓库根目录先启动本地 demo：

```bash
mix demo.run --smoke --exit-after 20 --bot-count 2
```

如果你想持续运行 demo，而不是做 smoke：

```bash
mix demo.run --bot-count 2
```

命令会：

- 启动本地服务端运行时
- 补齐 demo 账号/角色
- 生成多套人类客户端配置：
  - `.demo/human-client.ps1`
  - `.demo/human-client-2.ps1`
  - 以及对应的 `.json` / `.env.sh`
- 启动真实协议 demo bots（会移动、聊天、放技能）

然后在**另一个终端**导入生成的环境变量，再启动 Bevy 客户端。

### PowerShell

```powershell
. .\.demo\human-client.ps1
cd clients\bevy_client
cargo run
```

### Bash / Zsh

```bash
source ./.demo/human-client.env.sh
cd clients/bevy_client
cargo run
```

## 本机多开客户端

如果你想在同一台机器上打开多个客户端实例，**不要重复 source 同一个 `human-client.ps1`**，否则两个窗口会共享同一个 `username/cid/token`，场景里会被当作同一逻辑角色。

正确方式是给每个实例加载不同的配置文件，例如：

### 客户端 1

```powershell
. .\.demo\human-client.ps1
cd clients\bevy_client
cargo run
```

### 客户端 2

```powershell
. .\.demo\human-client-2.ps1
cd clients\bevy_client
cargo run
```

`mix demo.run` 现在会默认生成多套人类客户端配置，并在终端输出每个 slot 对应的 username/cid。

## 手动启动前准备

先准备 token，并设置环境变量：

```bash
export BEVY_CLIENT_GATE_ADDR=127.0.0.1:29000
export BEVY_CLIENT_USERNAME=tester
export BEVY_CLIENT_CID=42
export BEVY_CLIENT_TOKEN='<你的 token>'
```

> 最方便的方式仍然是直接使用 `mix demo.run` 生成的 `.demo/*` 配置文件。

`human-client.ps1` / `human-client-2.ps1` 当前会设置这些环境变量：

- `BEVY_CLIENT_GATE_ADDR`
- `BEVY_CLIENT_USERNAME`
- `BEVY_CLIENT_CID`
- `BEVY_CLIENT_TOKEN`
- `BEVY_CLIENT_OBSERVE_LOG`
- `DEMO_AUTH_URL`

## 运行

```bash
cd clients/bevy_client
cargo run
```

## 集成式 stdio 接口

正常 GUI 客户端也可以启用 stdio 命令接口，不需要切换到另一个 target。

```bash
cd clients/bevy_client
cargo run -- --stdio
```

或：

```bash
BEVY_CLIENT_STDIO=1 cargo run
```

启动后可以通过 stdin 给客户端发送命令：

- `help`
- `snapshot`
- `position`
- `transport`
- `players`
- `chat hello`
- `skill 1`
- `move w 600`
- `stop`
- `quit`

客户端会通过 stdout 输出 `client_stdio ...` 响应行，适合 agent 通过 stdio 驱动正在运行的正常客户端。

## CLI / headless 调试

如果你想不用图形界面，只用命令行验证连接、进场、移动、聊天和技能链路：

```bash
cd clients/bevy_client
cargo run -- --headless --observe-stdout --script "wait:500,move:w:600,chat:hello,skill:1,wait:1500"
```

支持的脚本片段：

- `wait:<ms>`
- `move:<w|a|s|d|up|down|left|right>:<ms>`
- `chat:<text>`
- `skill:<id>`
- `snapshot`

如果已经 source 了 `mix demo.run` 生成的 `human-client*.ps1/.env.sh`，headless 模式会复用同一套 gate/token/cid 配置。

> headless 主要用于自动化 smoke；长期可复用的在线调试入口优先是上面的 **集成式 stdio 接口**。

## Observe 日志

客户端会把结构化 observe 日志写到：

- `BEVY_CLIENT_OBSERVE_LOG`

而 `mix demo.run` 默认会额外生成服务端日志：

- `.demo/observe/server-gate.log`
- `.demo/observe/server-scene.log`

可直接查看：

```bash
mix demo.observe --lines 40
```

这样就可以从命令行交叉对照：

- 客户端输入意图
- 客户端发出的 auth / enter-scene / movement / chat / skill
- 服务端 gate / scene 的处理结果
- 权威坐标与 UDP fast-lane attach / fallback

如果当前环境访问 crates.io 很慢，可以临时改用 sparse 镜像：

```bash
CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse \
CARGO_REGISTRIES_CRATES_IO_INDEX='sparse+https://rsproxy.cn/index/' \
cargo run
```

## 操作

- `W/A/S/D` 或方向键：移动
- `Enter`：切换聊天输入 / 发送聊天
- `Esc`：取消聊天输入
- `1`：施放简单技能

## 说明

- 当前实现已经接入 **TCP control plane + UDP fast-lane movement path**。
- auth / enter-scene / chat / skill / heartbeat / time-sync 仍走 TCP。
- movement uplink 与 `PlayerMove` AOI downlink 在 fast-lane attach 成功后优先走 UDP。
- 聊天和技能是本次实现补入的最小 server-backed slice，不代表完整 MMO 玩法系统已经成熟。
- `mix demo.run` 中的 bots 通过真实 auth/gate/scene 路径接入，用来直观展示服务端权威 AOI 广播与 transport split。
