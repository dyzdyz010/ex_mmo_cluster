# 项目工程参考（技术栈 / 结构 / 命令 / 约定）

> 本文件是 `ex_mmo_cluster` 的**工程背景与参考资料**，从 `CLAUDE.md` / `AGENTS.md` 迁出。
> - 约束性铁律与工程纪律见 [`AGENTS.md`](../../../AGENTS.md)（跨工具工程准则单一来源）。
> - 当前“此刻为真”的状态见 [`docs/00-current-truth/README.md`](../../00-current-truth/README.md)。
> - 本文件只提供长期相对稳定的项目概览、技术栈、结构、命令、编码约定，不记录易变的运行时状态。
> - 2026-10-31 按仓库实际结构重写；此前版本描述的 12 个 app、TCP 自定义协议、beacon/libcluster/Horde 与 Mnesia 路径均已不存在。

## 项目概览

基于 Elixir/OTP 的 MMORPG 服务端，Mix umbrella 结构，`apps/` 下 8 个应用。唯一客户端是同级仓库 `../Voxim`（UE5.8）。
服务端以单个 `voxim_server` release 部署（`deploy/`）；多个 Scene 由拓扑文件在本机用 `:peer` 另起 BEAM 节点承载，
体素世界的唯一写者 `VoxelRegion.World` 留在主节点。客户端经 QUIC 连接，可靠消息走 QUIC 流，移动输入与快照走 DATAGRAM。

## 技术栈

- **语言**：本地开发 Erlang 28.3.1 / Elixir 1.19.5（`.tool-versions`）；release 镜像构建用 Elixir 1.18.5 / OTP 27.2.4（`deploy/` 的 Dockerfile）
- **传输**：QUIC，经 `quicer` 0.4.3（只在 Linux 构建，见 `apps/gate_server/mix.exs` 的 `quic_deps/0`）
- **协议**：`mmo_contracts` 里的声明式二进制 codec（session / movement / voxel），见下文“客户端协议”
- **Web**：Phoenix 1.8 + Bandit（`auth_server`：账号、邀请与 HTTP 体素载荷入口）
- **数据库**：PostgreSQL via Ecto（`data_service` 的账号与角色；`voxel_region` 的 overlay 日志与页表）
- **原生扩展**：Rust via Rustler 0.37.3，见下文“Rust 原生扩展”

## 仓库结构

```text
ex_mmo_cluster/
├── config/                 # 全局与运行时配置（runtime.exs 读部署环境变量）
├── deploy/                 # 镜像构建、compose、青岚内存守卫
├── docs/                   # 00-current-truth 当前事实 / 10-active 进行中 / 20-archive 归档 / 30-reference 参考
└── apps/
    ├── gate_server/        # QUIC 连接：解码、鉴权、转发；不持有玩法规则
    ├── scene_server/       # Scene：移动、碰撞历史、AOI、角色身体；移动 NIF
    ├── world_server/       # 会话认领与跨 Scene 移交、Scene 路由、多 Scene 拓扑
    ├── voxel_region/       # 体素世界唯一真值 VoxelRegion.World、授权、物理与分页；热与世界生成 NIF
    ├── npc_server/         # NPC 身体与大脑（走与玩家相同的角色路径）
    ├── auth_server/        # 账号、令牌、邀请（Phoenix）
    ├── data_service/       # 账号与角色持久化（PostgreSQL / Ecto）
    └── mmo_contracts/      # 跨 app 与客户端的协议契约（纯 codec，无进程）
```

各应用目录下的 README 描述其当前结构，例如 [`apps/voxel_region/README.md`](../../../apps/voxel_region/README.md)。

## 架构分层

```text
Voxim 客户端
  ↓ QUIC（可靠流 + DATAGRAM），codec 在 mmo_contracts
连接层：      gate_server（鉴权经 auth_server）
  ↓
会话与路由：  world_server（认领、移交、拓扑）
  ↓
模拟层：      scene_server（移动 / AOI / 身体）、npc_server（NPC）
  ↓
世界真值：    voxel_region（VoxelRegion.World 唯一写者）
  ↓
持久化：      PostgreSQL（data_service 账号角色；voxel_region 日志与页）
```

跨 app 只调用公共 API 与 `WorldServer.Movement` 路由，不硬编码节点名或 PID（AGENTS 铁律）。

## 常用命令

```bash
mix deps.get                          # 安装依赖
mix compile                           # 编译全部应用
mix format                            # 代码格式化

# 单 app 测试（通常不需要完整集群）
cd apps/voxel_region && mix test --no-start
cd apps/scene_server && mix test --no-start
cd apps/mmo_contracts && mix test

# auth_server 提交前检查
cd apps/auth_server && mix precommit

# 数据库迁移
mix ecto.migrate -r DataService.Repo
```

- 含 PostgreSQL 的测试读 `MMO_DB_PORT` 等环境变量连本地测试库。
- Gate 的真实 QUIC 用例只能在 Linux 跑：生成临时证书后 `VOXIM_TEST_CERTS=<dir> mix test --no-start --only quic_transport`
  （证书生成见 `.github/prepare-test-fixtures.py`）。Windows 上 `quicer` 不参与构建，这些用例被排除。

### Windows 运行补充

在 Windows 上建议通过 **VS Dev Command Prompt** 运行 Mix：

- 先调用 `VsDevCmd.bat`，确保 `nmake` / `cl` 可用于编译 NIF 或 C 依赖（如 `bcrypt_elixir`）
- 运行 Hex/Mix 前设置 `HEX_HTTP_CONCURRENCY=1`、`HEX_HTTP_TIMEOUT=120`
- 若 PowerShell 因 `mix.ps1` 签名策略拦截，改用 `cmd /c mix ...`

```bat
call "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat" -arch=x64
set HEX_HTTP_CONCURRENCY=1
set HEX_HTTP_TIMEOUT=120
mix deps.get
mix compile
```

## 代码组织约定

### OTP 设计模式

- **监督策略**：统一优先使用 `:one_for_one`；`npc_server` 等需要按依赖顺序重建时用 `:rest_for_one`，并在注释里写明原因
- **DynamicSupervisor**：用于动态生成连接、玩家、NPC 身体等进程
- **GenServer 回调**：使用 `@impl true` 明确标注
- **唯一写者**：一份权威状态只由一个进程写（例如体素世界只由 `VoxelRegion.World` 写）；其他进程拿快照或增量
- **一次性重活**：放在生命周期与之相当的短命进程里跑（如启动时的 Bake），不要留在常驻但空闲的进程堆上

### 命名约定

- 模块：`PascalCase`，遵循 `{AppName}.{Feature}.{Type}`，如 `SceneServer.Movement.Player`
- 文件：`snake_case.ex`
- 结构化日志事件名：`snake_case`，带领域前缀，如 `mmo_session_closed`、`voxel_page_retire_blocked`、`world_access_denied`

### 代码风格

- 记录日志使用 `require Logger`；警告使用 `Logger.warning/2`；日志不写凭据与载荷
- 优先在函数头做模式匹配，而不是在函数体里大量分支
- 数据变换优先使用 `|>` 管道
- 魔法数与协议码给名字（例如断连原因在 `MmoContracts.Session.Codec.end_reasons/0`）
- 代码注释统一用中文，写“为什么”，不写阶段代号（见 AGENTS.md）

## 数据层

- **账号与角色**：`data_service`，配置位于 `:data_service, DataService.Repo`，schema 在 `apps/data_service/lib/data_service/schema/`，
  迁移在 `apps/data_service/priv/repo/migrations/`。
- **体素世界**：`voxel_region` 的 overlay 日志与页表同样存 PostgreSQL（`VoxelRegion.OverlayLog`、`World.PageWriter`）；
  基底由世界生成规则在线生成或读离线烘焙文件，不进数据库。

## Rust 原生扩展

| Crate | 位置 | 用途 |
|-------|------|------|
| `voxim_movement_nif` | `apps/scene_server/native/` | 与客户端逐位一致的角色移动积分 |
| `voxim_m0` | `apps/scene_server/native/` | 独立 Rust 可执行实验：复用 UE 同一移动 crate 离线跑场景，不接 BEAM、不是 NIF |
| `voxim_thermal` | `apps/voxel_region/native/` | 热模拟内核（批量 DirtyCpu） |
| `voxim_worldgen` | `apps/voxel_region/native/` | 世界生成 kernel 与列边界 |

空间常量（宏格分块、微格分辨率）编译时从 `../Voxim/Source/Voxim/Voxel/VoxelSpatialConstants.h` 读取（`VoxelRegion.Spatial`），
构建 release 时需要把 Voxim 的这部分文件一并放进构建上下文。

**Rustler 0.37.3 API 提示**：

- 资源类型使用 `#[rustler::resource_impl] impl Resource for T {}`
- NIF 函数使用 `#[rustler::nif]`
- 模块初始化使用 `rustler::init!("Elixir.Module.Name")`

## 客户端协议

- 真值源是 `apps/mmo_contracts/lib/mmo_contracts/{session,movement,voxel}/`：每种消息用一张声明式字段表描述，编码与解码共用。
- 帧头 `<<255, 1::16, domain, kind, size::32, body>>`；session 与 voxel 消息走 QUIC 可靠流，移动输入与快照走 DATAGRAM。
- 断连原因码（`SessionEnd` 与未鉴权时的 application close）见 `MmoContracts.Session.Codec.end_reasons/0`，
  对应 Voxim `Docs/M1/plan.md` §2.7。
- [`docs/30-reference/protocol/2026-04-10-线协议规范.md`](../protocol/2026-04-10-线协议规范.md) 描述的是已退役的 TCP 协议，仅作历史参考。

## 部署与多 Scene

- `deploy/` 构建单个 `voxim_server` release 镜像，compose 只起一个 app 容器；内存守卫见 `deploy/qinglan-memory-guard.py`。
- `WorldServer.Topology` 读拓扑文件：`"node": "peer"` 的 Scene 用 `:peer` 在本机另起 BEAM 节点（只运行该 Scene 及其 `VoxelRegion.Replica`），
  World 仍在主节点；peer 节点随主进程退出。

## 关键依赖

| 包 | 版本 | 用途 |
|----|------|------|
| `quicer` | 0.4.3（仅 Linux） | QUIC 传输 |
| `phoenix` / `bandit` | 1.8 / ~> 1.5 | `auth_server` Web 入口 |
| `ecto_sql` / `postgrex` | ~> 3.12 | PostgreSQL 数据访问 |
| `rustler` | ~> 0.37.3 | Elixir ↔ Rust NIF 桥接 |
| `poolboy` | 1.5 | `data_service` worker pool |
| `bcrypt_elixir` | 3.x | 密码哈希（`auth_server`） |
| `jason` | 1.4 | JSON 编解码 |
