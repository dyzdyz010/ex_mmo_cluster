# Bevy Debug Client

一个面向当前 `ex_mmo_cluster` 服务端状态的 **Bevy 2D 联调客户端**。

## 当前支持

- TCP 连接 gate
- 内置登录面板（egui）通过 `POST /ingame/auto_login` 拿 token
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

## 启动前提

服务端需要开启 dev 登录端点：`.env` 里置 `DEV_AUTO_LOGIN=true`，否则 `/ingame/auto_login` 会返回 403。

## 运行（GUI）

```bash
export BEVY_CLIENT_GATE_ADDR=127.0.0.1:29000
export BEVY_CLIENT_AUTH_ADDR=http://127.0.0.1:4000
cd clients/bevy_client
cargo run
```

启动后会出现登录面板，输入用户名回车（或点 Enter 按钮）即可进入场景。服务端会按需 upsert 账号 + 角色并返回 token。

想跳过登录面板，可以直接传 `--username`：

```bash
cargo run -- --username alice
```

## Headless / 自动化

Headless 模式必须通过 `--username` 传入用户名（没有登录 UI）：

```bash
cargo run -- --headless --username alice --observe-stdout \
    --script "wait:500,move:w:600,chat:hello,skill:1,wait:1500"
```

支持的脚本片段：

- `wait:<ms>`
- `move:<w|a|s|d|up|down|left|right>:<ms>`
- `chat:<text>`
- `skill:<id>`
- `snapshot`

## 本机多开客户端

每个进程用不同的 `--username` 即可得到不同的 cid / token：

```bash
cargo run -- --username alice
cargo run -- --username bob
```

或者让两个窗口各自在登录面板里输入不同的用户名。

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
- 登录面板当前是 dev-only 流程；生产环境里 `/ingame/auto_login` 会被 `DEV_AUTO_LOGIN` 开关拦截。
