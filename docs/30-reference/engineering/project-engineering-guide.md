# 项目工程参考（技术栈 / 结构 / 命令 / 约定）

> 本文件是 `ex_mmo_cluster` 的**工程背景与参考资料**，从 `CLAUDE.md` / `AGENTS.md` 迁出。
> - 约束性铁律与工程纪律见 [`AGENTS.md`](../../../AGENTS.md)（跨工具工程准则单一来源）。
> - 当前“此刻为真”的状态见 [`docs/00-current-truth/README.md`](../../00-current-truth/README.md)。
> - 本文件只提供长期相对稳定的项目概览、技术栈、结构、命令、编码约定，不记录易变的运行时状态。

## 项目概览

基于 Elixir/OTP 构建的 MMORPG 游戏服务集群。Mix umbrella 结构，在 `apps/` 下包含 12 个职责分离的微服务应用。系统使用分布式 Erlang 集群、`libcluster` 自动发现、PostgreSQL（通过 Ecto）作为主持久化路径、自定义二进制协议作为客户端通信格式（见 [`docs/30-reference/protocol/2026-04-10-线协议规范.md`](../protocol/2026-04-10-线协议规范.md)），并通过 Rust NIF（Rustler）承载性能敏感的物理与空间计算逻辑。

## 技术栈

- **语言**：Elixir 1.19.x，Erlang/OTP 28（运行时版本见 `.tool-versions`：Erlang 28.3.1，Elixir 1.19.5-otp-28）
- **Web 框架**：Phoenix 1.8（`auth_server`、`visualize_server`，由 `mix phx.new` 1.8 模板生成后迁移业务逻辑）
- **HTTP 适配器**：Bandit 1.5（Phoenix 1.8 默认）
- **数据库**：PostgreSQL via Ecto（主路径），Mnesia via Memento（遗留、迁移中）
- **序列化**：自定义二进制 codec（`GateServer.Codec`），以及 JSON（Jason）
- **原生扩展**：Rust via Rustler 0.37.3（物理使用 `rapier3d-f64`，空间索引使用 octree）
- **集群组件**：`libcluster`（节点发现）、`Horde`（分布式注册与 supervisor）、`DNSCluster`（Phoenix 1.8 默认 DNS 基础集群，与 libcluster 并存）
- **前端**：Phoenix LiveView 1.1、esbuild 0.25、Tailwind CSS 4.1、heroicons

## 仓库结构

```text
ex_mmo_cluster/                    # Umbrella 根目录
├── config/config.exs             # 全局配置
├── mix.exs                       # 根项目定义
├── .tool-versions                # asdf 运行时版本固定
├── docs/                         # 设计文档（current_status=当前事实, original=原始证据, plans/voxel-server-authority=阶段稿）
└── apps/
    ├── gate_server/              # TCP 网关与自定义二进制协议入口
    ├── agent_server/             # 玩家/agent 行为逻辑
    ├── agent_manager/            # agent_server 协调层
    ├── scene_server/             # 场景逻辑、物理、AOI、体素、局部场、Rust NIF
    ├── world_server/             # 世界层协调、region/scene 路由、体素事务
    ├── beacon_server/            # 集群服务发现（libcluster + Horde）
    ├── auth_server/              # 用户认证（Phoenix Web 应用）
    ├── visualize_server/         # 游戏状态可视化（Phoenix LiveView）
    ├── data_init/               # 数据初始化与旧 Mnesia 表定义
    ├── data_service/             # 数据服务（PostgreSQL / Ecto）
    ├── data_store/               # 旧 Mnesia 存储节点
    ├── data_contact/             # 旧数据集群协调节点
    └── mmo_contracts/            # 跨 app 契约（world pack index/shard 等）
```

## 架构分层

```text
客户端
  ↓（自定义二进制协议 over TCP，使用 packet:4 分帧）
连接层：        auth_server, gate_server
  ↓
游戏逻辑层：    agent_server / agent_manager, scene_server / world_server
  ↓
数据层：        data_service（PostgreSQL via Ecto）
  ↓
基础设施层：    beacon_server（libcluster + Horde，分布式）
```

## 常用命令

```bash
mix deps.get                              # 安装依赖
mix compile                               # 编译全部应用
mix format                                # 代码格式化
mix test                                  # 运行全部测试（部分应用依赖分布式节点）

# 单 app 测试（通常不需要完整集群）
cd apps/gate_server && mix test --no-start
cd apps/data_service && mix test --no-start
cd apps/beacon_server && mix test --no-start

mix db_initialize                         # 初始化遗留 Mnesia 数据库
mix ecto.migrate -r DataService.Repo      # 运行 PostgreSQL 迁移
mix migrate_to_pg                         # 将数据从 Mnesia 迁移到 PostgreSQL

# 启动一个集群节点（交互式）
iex --name <node_name> --cookie mmo -S mix
iex --name scene1 --cookie mmo -S mix     # 示例：启动一个 scene 节点
```

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
mix test
```

补充：这是**本地 Windows 运行约束**，不是仓库代码层面的依赖变更；umbrella test 环境已禁用 `libcluster` gossip topology，避免 Windows 下固定 UDP 端口导致 `:eaddrinuse`。

## 代码组织约定

### 模块结构

每个 app 通常遵循如下结构：

```text
app_name/lib/
├── app_name.ex              # 主模块
└── app_name/
    ├── application.ex       # OTP Application（监督树根）
    ├── sup/                 # Supervisor 模块（interface_sup.ex / {domain}_sup.ex）
    ├── worker/              # GenServer worker（interface.ex 集群接口 / {domain}.ex 领域逻辑）
    ├── native/              # Rust NIF 绑定（仅 scene_server）
    ├── schema/              # Ecto schema（仅 data_service）
    ├── db_ops/              # 数据操作模块
    └── codec.ex             # 二进制协议 codec（仅 gate_server）
```

### OTP 设计模式

- **监督策略**：统一优先使用 `:one_for_one`
- **DynamicSupervisor**：用于动态生成连接、玩家、worker pool 等进程
- **GenServer 回调**：应使用 `@impl true` 明确标注
- **进程组**：使用 `:pg` 做集群内 pub/sub 广播
- **Interface 模式**：每个 app 都有 `worker/interface.ex`，负责 beacon 注册、资源声明、依赖解析
- **服务发现**：通过 `BeaconServer.Client.join_cluster/0`、`.register/1`、`.lookup/1`、`.await/2`

### 命名约定

- 模块：`PascalCase`，遵循 `{AppName}.{Feature}.{Type}`，如 `SceneServer.AoiManager`
- 文件：`snake_case.ex`
- app 名：`snake_case`，并通过后缀体现职责，如 `_server`、`_manager`、`_service`、`_store`

### 代码风格

- 记录日志使用 `require Logger`；警告使用 `Logger.warning/2`
- 优先在函数头做模式匹配，而不是在函数体里大量分支
- 数据变换优先使用 `|>` 管道
- GenServer state 优先使用 map：`%{key: value}`
- 仓库中允许中文注释（约束：代码注释统一用中文，见 AGENTS.md §4.13）

## 数据层

### PostgreSQL（主路径，基于 Ecto）

配置位于 `config/config.exs` 的 `:data_service, DataService.Repo`。Schema 位于 `apps/data_service/lib/data_service/schema/`：

- `DataService.Schema.Account` —— 用户账户（id、username、password、salt、email、phone）
- `DataService.Schema.Character` —— 玩家角色（id、account、name、title、attrs、position、hp/sp/mp）

Migration 位于 `apps/data_service/priv/repo/migrations/`。体素相关 canonical 存储见 `apps/data_service/lib/data_service/voxel/`。

### Mnesia（遗留路径，正在退出）

旧表定义保留在 `apps/data_init/lib/table_def.ex`，主要用于 `mix migrate_to_pg`。`data_store` 与 `data_contact` 仍依赖 Mnesia，但 `data_service` 主 worker 路径已切到 PostgreSQL。

## Rust 原生扩展

位于 `apps/scene_server/native/`：

| Crate | Rustler | 用途 |
|-------|---------|------|
| `scene_ops` | 0.37.3 | 物理模拟（rapier3d-f64 0.16）、角色移动 |
| `movement_engine` | 0.37.3 | 服务端权威移动积分与回放校正 |
| `octree` | 0.37.3 | 空间索引与邻近查询 |
| `coordinate_system` | 0.37.3 | 旧坐标系统实现（已逐步被 octree 替代） |
| `world_gen_noise` | 0.37.3 | WorldGen 地形噪声（两层分形值噪声；待升级跨端 bit-exact） |

关键 NIF 模块：`SceneServer.Native.SceneOps`。典型函数：`new_character_data/5`、`movement_tick/2`、`update_character_movement/5`、`get_character_location/2`、`new_physics_system/0`。

**Rustler 0.37.3 API 提示**：

- 资源类型使用 `#[rustler::resource_impl] impl Resource for T {}`
- NIF 函数使用 `#[rustler::nif]`
- 模块初始化使用 `rustler::init!("Elixir.Module.Name")`

编译 Rust NIF 需要可用 Rust toolchain（当前环境测试过 rustc 1.94）。

## 客户端协议

完整协议说明见 [`docs/30-reference/protocol/2026-04-10-线协议规范.md`](../protocol/2026-04-10-线协议规范.md)。真值源以 `apps/gate_server/lib/gate_server/codec.ex` 为准（规范文档部分已 stale）。

- **分帧**：4 字节大端长度前缀（TCP socket 配置为 `{packet, 4}`）
- **消息格式**：`<<msg_type::8, payload::binary>>`
- **codec**：`GateServer.Codec`
- **热点消息**：Movement（89 字节）、PlayerMove 广播（33 字节）

## 集群服务发现

`beacon_server` 当前提供分布式服务发现：

- **libcluster**：自动发现节点
- **Horde**：分布式 registry，保证 `BeaconServer.Beacon` 在集群中可见
- **BeaconServer.Client**：所有 Interface 模块统一使用的 API（不要硬编码节点名）

## 测试说明

- 测试框架：ExUnit
- 单 app 测试通常使用 `cd apps/<app> && mix test --no-start`
- 含数据库测试的应用（如 `data_service`）需要 PostgreSQL
- 涉及集群的应用（如 `data_contact`、`data_store`）需要分布式 Erlang 环境
- CI 配置位于 `.github/workflows/ci.yml`

| App | 测试数 | 说明 |
|-----|--------|------|
| gate_server | 46+ | codec、TCP 分帧、dispatch |
| data_service | 10+ | Ecto schema、重复校验 |
| beacon_server | 7+ | Client API、注册、依赖解析 |
| scene_server | 4+ | NIF 调用（需 Rust） |
| agent_server | 2 | smoke test |
| world_server | 2 | smoke test |

## 关键依赖

| 包 | 版本 | 用途 |
|----|------|------|
| `phoenix` | 1.8 | Web 框架（auth、visualization） |
| `phoenix_live_view` | 1.1 | `visualize_server` 实时 UI |
| `bandit` | ~> 1.5 | Phoenix 1.8 默认 HTTP 适配器 |
| `dns_cluster` | ~> 0.2 | Phoenix 1.8 默认 DNS 集群 |
| `ecto_sql` | ~> 3.12 | PostgreSQL 数据访问 |
| `postgrex` | 锁定 0.22.0 | PostgreSQL 驱动 |
| `memento` | 0.3.2 | Mnesia 包装层（遗留） |
| `rustler` | ~> 0.37.3 | Elixir ↔ Rust NIF 桥接 |
| `libcluster` | ~> 3.4 | 集群自动发现 |
| `horde` | ~> 0.9 | 分布式 registry / supervisor |
| `poolboy` | 1.5 | worker pool 管理（data_service） |
| `bcrypt_elixir` | 3.x | 密码哈希（auth_server） |
| `jason` | 1.4 | JSON 编解码 |

## 数据层与服务发现现状提醒

- `data_service` 主路径已经是 PostgreSQL / Ecto；`data_init` / `data_store` / `data_contact` 主要是遗留兼容。
- 所有 Interface 模块都应通过 `BeaconServer.Client` 做发现，不要硬编码节点名。
- 项目使用分布式 Erlang，涉及多节点行为时要考虑 node name 与 cookie。
- 遗留 `.proto` 文件仍保存在 `mmo_protos` 子模块中，仅作参考，不再是运行时主路径。
