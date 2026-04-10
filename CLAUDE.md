# CLAUDE.md

## 项目概览

这是一个基于 Elixir/OTP 构建的 MMORPG 游戏服务集群。仓库采用 Mix umbrella 结构，在 `apps/` 下包含 12 个职责分离的微服务应用。系统当前使用分布式 Erlang 集群、`libcluster` 自动发现、PostgreSQL（通过 Ecto）作为主持久化路径、自定义二进制协议作为客户端通信格式（见 `docs/2026-04-10-线协议规范.md`），并通过 Rust NIF（Rustler）承载性能敏感的物理与空间计算逻辑。

## 技术栈

- **语言**：Elixir 1.18.x，Erlang/OTP 28
- **运行时版本**：见 `.tool-versions`（Erlang 28.3.1，Elixir 1.18.4-otp-28）
- **Web 框架**：Phoenix 1.6（`auth_server`、`visualize_server`）
- **数据库**：PostgreSQL via Ecto（主路径），Mnesia via Memento（遗留、迁移中）
- **序列化**：自定义二进制 codec（`GateServer.Codec`，见 `docs/2026-04-10-线协议规范.md`），以及 JSON（Jason）
- **原生扩展**：Rust via Rustler 0.36（物理使用 `rapier3d-f64`，空间索引使用 octree）
- **集群组件**：`libcluster`（节点发现）、`Horde`（分布式注册与 supervisor）
- **前端**：Phoenix LiveView、esbuild、Tailwind CSS

## 仓库结构

```text
ex_mmo_cluster/                    # Umbrella 根目录
├── config/config.exs             # 全局配置
├── mix.exs                       # 根项目定义
├── .tool-versions                # asdf 运行时版本固定
├── docs/2026-04-10-线协议规范.md      # 线协议规范
├── docs/2026-04-07-增量迁移计划.md    # 架构迁移路线图
└── apps/
    ├── gate_server/              # TCP 网关与自定义二进制协议入口
    ├── agent_server/             # 玩家/agent 行为逻辑
    ├── agent_manager/            # agent_server 协调层
    ├── scene_server/             # 场景逻辑、物理、AOI、Rust NIF
    ├── world_server/             # 世界层协调逻辑
    ├── beacon_server/            # 集群服务发现（libcluster + Horde）
    ├── auth_server/              # 用户认证（Phoenix Web 应用）
    ├── visualize_server/         # 游戏状态可视化（Phoenix LiveView）
    ├── data_init/                # 数据初始化与旧 Mnesia 表定义
    ├── data_service/             # 数据服务（PostgreSQL / Ecto）
    ├── data_store/               # 旧 Mnesia 存储节点
    └── data_contact/             # 旧数据集群协调节点
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
# 安装依赖
mix deps.get

# 编译全部应用
mix compile

# 代码格式化
mix format

# 运行全部测试（部分应用会依赖分布式节点）
mix test

# 运行单个应用测试（通常不需要完整集群）
cd apps/gate_server && mix test --no-start
cd apps/data_service && mix test --no-start
cd apps/beacon_server && mix test --no-start

# 初始化遗留 Mnesia 数据库
mix db_initialize

# 运行 PostgreSQL 迁移
mix ecto.migrate -r DataService.Repo

# 将数据从 Mnesia 迁移到 PostgreSQL
mix migrate_to_pg

# 启动一个集群节点（交互式）
iex --name <node_name> --cookie mmo -S mix

# 示例：启动一个 scene 节点
iex --name scene1 --cookie mmo -S mix
```

## 代码组织约定

### 模块结构

每个 app 通常遵循如下结构：

```text
app_name/lib/
├── app_name.ex              # 主模块
└── app_name/
    ├── application.ex       # OTP Application（监督树根）
    ├── sup/                 # Supervisor 模块
    │   ├── interface_sup.ex # 接口/路由 supervisor
    │   └── {domain}_sup.ex  # 领域专用 supervisor
    ├── worker/              # GenServer worker
    │   ├── interface.ex     # 集群接口（通过 BeaconServer.Client 注册）
    │   └── {domain}.ex      # 领域逻辑 worker
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

- 模块：`PascalCase`，遵循 `{AppName}.{Feature}.{Type}`，例如 `SceneServer.AoiManager`
- 文件：`snake_case.ex`
- app 名：`snake_case`，并通过后缀体现职责，如 `_server`、`_manager`、`_service`、`_store`

### 代码风格

- 记录日志使用 `require Logger`；警告使用 `Logger.warning/2`
- 优先在函数头做模式匹配，而不是在函数体里大量分支
- 数据变换优先使用 `|>` 管道
- GenServer state 优先使用 map：`%{key: value}`
- 仓库中允许出现中文注释

## 数据层

### PostgreSQL（主路径，基于 Ecto）

配置位于 `config/config.exs` 的 `:data_service, DataService.Repo`。

Schema 位于 `apps/data_service/lib/data_service/schema/`：

- `DataService.Schema.Account` —— 用户账户（id、username、password、salt、email、phone）
- `DataService.Schema.Character` —— 玩家角色（id、account、name、title、attrs、position、hp/sp/mp）

Migration 位于 `apps/data_service/priv/repo/migrations/`。

### Mnesia（遗留路径，正在退出）

旧表定义仍保留在 `apps/data_init/lib/table_def.ex` 中，主要用于 `mix migrate_to_pg`。`data_store` 与 `data_contact` 仍依赖 Mnesia，但当前 `data_service` 的主要 worker 路径已经切到 PostgreSQL。

## Rust 原生扩展

位于 `apps/scene_server/native/`：

| Crate | Rustler | 用途 |
|-------|---------|------|
| `scene_ops` | 0.36.1 | 物理模拟（rapier3d-f64 0.16）、角色移动 |
| `octree` | 0.36.1 | 空间索引与邻近查询 |
| `coordinate_system` | 0.36.1 | 旧坐标系统实现（已逐步被 octree 替代） |

关键 NIF 模块：`SceneServer.Native.SceneOps`

典型函数包括：`new_character_data/5`、`movement_tick/2`、`update_character_movement/5`、`get_character_location/2`、`new_physics_system/0`

**Rustler 0.36 API 提示**：

- 资源类型使用 `#[rustler::resource_impl] impl Resource for T {}`
- NIF 函数使用 `#[rustler::nif]`
- 模块初始化使用 `rustler::init!("Elixir.Module.Name")`

编译 Rust NIF 需要可用 Rust toolchain（当前环境测试过 rustc 1.94）。

## 客户端协议

完整协议说明见 `docs/2026-04-10-线协议规范.md`。

- **分帧**：4 字节大端长度前缀（TCP socket 配置为 `{packet, 4}`）
- **消息格式**：`<<msg_type::8, payload::binary>>`
- **codec**：`GateServer.Codec`
- **热点消息**：Movement（89 字节）、PlayerMove 广播（33 字节）

## 集群服务发现

`beacon_server` 当前提供分布式服务发现：

- **libcluster**：自动发现节点
- **Horde**：分布式 registry，保证 `BeaconServer.Beacon` 在集群中可见
- **BeaconServer.Client**：所有 Interface 模块统一使用的 API
- **去单点**：不再依赖固定单节点 beacon

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
| `phoenix` | 1.6 | Web 框架（auth、visualization） |
| `phoenix_live_view` | 0.17 | `visualize_server` 实时 UI |
| `ecto_sql` | ~> 3.12 | PostgreSQL 数据访问 |
| `postgrex` | latest | PostgreSQL 驱动 |
| `memento` | 0.3.2 | Mnesia 包装层（遗留） |
| `rustler` | ~> 0.36 | Elixir ↔ Rust NIF 桥接 |
| `libcluster` | ~> 3.4 | 集群自动发现 |
| `horde` | ~> 0.9 | 分布式 registry / supervisor |
| `poolboy` | 1.5 | worker pool 管理（data_service） |
| `bcrypt_elixir` | 3.x | 密码哈希（auth_server） |
| `jason` | 1.4 | JSON 编解码 |

## 给 AI 助手的附加说明

- 这是一个 umbrella 项目，修改前必须先判断影响的是哪个 app
- 跨 app 通信主要通过 Interface 模块和稳定公共 API，尽量不要绕过这些边界
- `scene_server` 带 Rust NIF，修改原生代码时要考虑 Rustler 0.36 API 与 Rust 编译链
- **数据层现状**：`data_service` 主路径已经是 PostgreSQL / Ecto；`data_init` / `data_store` / `data_contact` 主要是遗留兼容
- **服务发现现状**：所有 Interface 模块都应通过 `BeaconServer.Client` 做发现，不要硬编码节点名
- 项目使用分布式 Erlang，涉及多节点行为时要考虑 node name 与 cookie
- 客户端协议已经切到自定义二进制 codec（`GateServer.Codec`），线格式见 `docs/2026-04-10-线协议规范.md`
- 遗留 `.proto` 文件仍保存在 `mmo_protos` 子模块中，仅作参考，不再是当前运行时主路径
- **CI**：当前应至少验证 `mix compile`、`mix test`，以及必要的单 app 测试
- 完整迁移路线图见 `docs/2026-04-07-增量迁移计划.md`
