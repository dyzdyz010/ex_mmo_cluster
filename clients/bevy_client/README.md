# Bevy Debug Client

一个面向当前 `ex_mmo_cluster` 服务端状态的 **Bevy 3D 联调客户端**。

## 当前支持

- TCP 连接 gate
- 内置登录面板（egui）通过 `POST /ingame/auto_login` 拿 token
- 进入场景
- UDP fast-lane attach
- 3D AOI / actor 可视化
- 移动同步（attach 成功后 movement uplink / `PlayerMove` downlink 优先走 UDP）
- Space 跳跃输入会进入 movement frame flag `0x04`，并通过 stdio / observe 可见
- 本地离线 voxel 世界：宏格放置 / 破坏、`8x8x8` refined microgrid、hotbar、内置 prefab、boundary snap、snapshot save/load
- Bevy 3D 视图会渲染完整 voxel 宏格和 refined `8x8x8` micro occupancy
- 中心射线选择 voxel 面；命中面高亮，材质放置到相邻 macro，prefab 优先走 boundary snap
- prefab hotbar 项会显示 boundary snap micro-wire 预览，无法精确吸附时按网页端规则退回 macro 预览/放置
- 场景内聊天
- 简单技能（默认技能 ID `1`）
- HUD 展示 control / movement transport、fast-lane 状态、AOI peer 数
- 集成式 stdio 调试接口
- CLI/headless 调试模式（自动化 smoke 用）
- 结构化 observe 日志（客户端输入 + 网络收发）

## 启动前提

服务端需要开启 dev 登录端点：`.env` 里置 `DEV_AUTO_LOGIN=true`，否则 `/ingame/auto_login` 会返回 403。

## 运行（GUI）

如果 gate / auth 服务都跑在本机默认端口，客户端不需要设置环境变量：

```bash
cd clients/bevy_client
cargo run
```

启动后会出现登录面板，输入用户名回车（或点 Enter 按钮）即可进入场景。服务端会按需 upsert 账号 + 角色并返回 token。

只有服务地址不是默认值时，才需要覆盖：

```bash
export BEVY_CLIENT_GATE_ADDR=127.0.0.1:29000
export BEVY_CLIENT_AUTH_ADDR=http://127.0.0.1:4000
cargo run
```

想跳过登录面板，可以直接传 `--username`：

```bash
cargo run -- --username alice
```

## Headless / 自动化

Headless 模式必须通过 `--username` 传入用户名（没有登录 UI）：

```bash
cargo run -- --headless --username alice --observe-stdout \
    --script "wait:500,move:w:600,chat:hello,wait:1500"
```

支持的脚本片段：

- `wait:<ms>`
- `move:<w|a|s|d|up|down|left|right>:<ms>`
- `chat:<text>`
- `skill:<id>`
- `jump`
- `snapshot`

`skill:<id>` 只有在附近存在可命中的 actor 时才会成功；单客户端 smoke
通常更适合只验证登录 / 进场 / 移动 / 聊天。要验证技能命中，请至少再启动一个客户端。

Voxel 本地离线 headless 不需要服务端 / 登录，可直接跑网页端风格 CLI 命令：

```bash
cargo run -- --voxel-headless --observe-log ..\..\.demo\observe\bevy-voxel-headless-smoke.log \
    --script "voxel_snapshot; hotbar_select 5; prefab_place builtin_sphere 8 5 8; micro_cell 8 5 8 4 4 4; world_export"
```

脚本用分号分隔命令，输出同样是 `client_stdio ...` 结构化行。

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
- `jump`
- `move w 600`
- `stop`
- `voxel_snapshot`
- `place 1 2 3 wood`
- `break 1 2 3`
- `hotbar` / `hotbar_select 5`
- `micro_cell 8 5 8 4 4 4`
- `prefabs`
- `prefab_boundary builtin_sphere`
- `prefab_place builtin_sphere 8 5 8 [rot0|rot90|rot180|rot270]`
- `prefab_snap_preview builtin_sphere 8 5 8 1 0 0`
- `prefab_place_snap builtin_sphere 8 5 8 1 0 0`
- `world_export`
- `world_import <json>`
- `world_save default`
- `world_load default`
- `quit`

客户端会通过 stdout 输出 `client_stdio ...` 响应行，适合 agent 通过 stdio 驱动正在运行的正常客户端。
除命令回执外，stdio 还会镜像关键运行时事件，例如 `status`、`log`、
`player_enter`、`chat_message`、`skill_event`、`combat_hit`、`player_state`，
便于直接从命令行排查“为什么这次施法失败/成功”。
若要验证 `skill <id>`，请先确保场景里有另一个玩家/NPC，或者先通过 target/point 相关命令选中目标。
当目标条件明显不满足时，stdio 会直接返回：

- `client_stdio event="skill_blocked" ...`

典型排查顺序：

1. `players` / `npcs` 查看附近 actor
2. `target <cid>` 或 `target_point <x> <y> [z]`
3. 再执行 `skill <id> [target_cid]`

Voxel 典型排查顺序：

1. `voxel_snapshot` 查看 `voxel_sync=offline-local`、hotbar 和 edit stats
2. `prefabs` / `prefab_boundary <name>` 查看内置 prefab 的 micro resolution 与 occupied slots
3. `prefab_place ...` 或 `prefab_place_snap ...` 执行放置
4. `micro_cell <x> <y> <z> <mx> <my> <mz>` 验证 refined micro 内部数据
5. `world_export` / `world_save` / `world_load` 验证本地持久化

## Observe 日志

客户端会把结构化 observe 日志写到：

- `BEVY_CLIENT_OBSERVE_LOG`
- `--voxel-headless --observe-log ..\..\.demo\observe\<name>.log`

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

- `W/A/S/D` 或方向键：移动；`Space`：跳跃
- `Enter`：切换聊天输入 / 发送聊天
- `Esc`：取消聊天输入
- 按住左键或中键拖动：旋转 3D 视角
- `Ctrl + 鼠标滚轮`：缩放 3D 视角
- 左键 / `G`：破坏屏幕中心射线命中的 voxel 宏格
- 右键 / `F`：放置当前 hotbar 项；材质放到命中面相邻 macro，prefab 优先使用 boundary snap
- 鼠标滚轮 / `1..7`：切换 hotbar（`1..4` 材质，`5..7` 内置 prefab）；按住 `Ctrl` 时滚轮只缩放视角
- `Shift + 1..4`：施放简单技能
- `Shift + 右键`：设置技能目标点

## 说明

- 当前实现已经接入 **TCP control plane + UDP fast-lane movement path**。
- auth / enter-scene / chat / skill / heartbeat / time-sync 仍走 TCP。
- movement uplink 与 `PlayerMove` AOI downlink 在 fast-lane attach 成功后优先走 UDP。
- voxel 与网页端当前一致，仍是 **offline-local**；本地 CLI / GUI 操作不走服务端同步。
- Bevy 端 microgrid 使用 `MicroPerMacro=8`，与网页端当前实现一致；接入服务端 refined 同步前仍需协议协商。
- 聊天和技能是本次实现补入的最小 server-backed slice，不代表完整 MMO 玩法系统已经成熟。
- 登录面板当前是 dev-only 流程；生产环境里 `/ingame/auto_login` 会被 `DEV_AUTO_LOGIN` 开关拦截。

## 相关文档

- `docs/2026-04-25-bevy-client-web-parity-voxel-migration.md` — 网页端 voxel / prefab / jump 功能迁回 Bevy 的实现记录
