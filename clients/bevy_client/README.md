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
- 生成 `.demo/human-client.ps1` / `.demo/human-client.env.sh`
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

## 手动启动前准备

先准备 token，并设置环境变量：

```bash
export BEVY_CLIENT_GATE_ADDR=127.0.0.1:29000
export BEVY_CLIENT_USERNAME=tester
export BEVY_CLIENT_CID=42
export BEVY_CLIENT_TOKEN='<你的 token>'
```

> 最方便的方式仍然是直接使用 `mix demo.run` 生成的 `.demo/*` 配置文件。

## 运行

```bash
cd clients/bevy_client
cargo run
```

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
