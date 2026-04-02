# AGENTS

## 项目概览

这个仓库是一个 Elixir umbrella 项目，用来实验 MMORPG 服务器集群的拆分方式。
代码并不是单一形态，而是混合了几类运行时：

- OTP 服务应用：负责 auth、gate、agent、world、data、beacon 等集群角色
- Phoenix 应用：负责浏览器侧登录和可视化
- Rustler Rust NIF：负责场景、AOI、坐标和物理等偏计算密集的逻辑

顶层 [`README.md`](D:\dev\hemifuture\ex_mmo_cluster\README.md) 主要描述了目标集群拓扑，但不少 app 还处在早期阶段或模板阶段。开始改代码前，先读目标 app 的实现，不要把 README 里的职责当成“已经完整落地”。

## 工具链与环境

仓库在 [`.tool-versions`](D:\dev\hemifuture\ex_mmo_cluster\.tool-versions) 里声明的版本是：

- Erlang `25.2.2`
- Elixir `1.14.3-otp-25`

当前仓库里能看出的实际环境要求：

- `scene_server` 依赖 Rust 工具链，源码位于 `apps/scene_server/native/*`
- `gate_server` 如果要重新生成协议代码，需要本机安装 `protoc`
- `auth_server` 和 `visualize_server` 如果改前端资源，通常需要 Node/npm

## 仓库结构

顶层关键目录：

- [`mix.exs`](D:\dev\hemifuture\ex_mmo_cluster\mix.exs)：umbrella 根项目
- [`config/config.exs`](D:\dev\hemifuture\ex_mmo_cluster\config\config.exs)：umbrella 共享配置
- [`apps/`](D:\dev\hemifuture\ex_mmo_cluster\apps)：所有子应用

重点 app：

- `apps/auth_server`：Phoenix 登录/认证页面
- `apps/visualize_server`：Phoenix LiveView 场景可视化
- `apps/gate_server`：TCP 网关、协议消息、Protox
- `apps/scene_server`：场景逻辑、AOI、玩家移动、Rust NIF 桥接
- `apps/data_service`：基于 Mnesia/Memento 的内存数据服务
- `apps/data_store`：存储初始化与落盘相关工具
- `apps/data_init`：数据表定义
- `apps/world_server`：世界级协调逻辑
- `apps/agent_server` / `apps/agent_manager`：玩家角色逻辑与管理层
- `apps/data_contact`：数据集群协调
- `apps/beacon_server`：集群级资源交换

## 子应用说明

### Phoenix 应用

`auth_server` 和 `visualize_server` 是两个独立 Phoenix 应用，它们在开发环境里都默认监听 `127.0.0.1:4000`：

- [`apps/auth_server/config/dev.exs`](D:\dev\hemifuture\ex_mmo_cluster\apps\auth_server\config\dev.exs)
- [`apps/visualize_server/config/dev.exs`](D:\dev\hemifuture\ex_mmo_cluster\apps\visualize_server\config\dev.exs)

如果要本机同时启动两个服务，先改掉其中一个端口。

### Gate 协议来源

[`apps/gate_server/priv/proto`](D:\dev\hemifuture\ex_mmo_cluster\apps\gate_server\priv\proto) 不是普通目录，而是 [`.gitmodules`](D:\dev\hemifuture\ex_mmo_cluster\.gitmodules) 里声明的 git submodule，来源是 `mmo_protos`。

如果你发现 proto 文件缺失、过旧，先检查 submodule 状态，再决定是否动生成代码。

### Scene 原生层

`scene_server` 绑定了 3 个 Rust crate：

- [`apps/scene_server/native/coordinate_system`](D:\dev\hemifuture\ex_mmo_cluster\apps\scene_server\native\coordinate_system)
- [`apps/scene_server/native/octree`](D:\dev\hemifuture\ex_mmo_cluster\apps\scene_server\native\octree)
- [`apps/scene_server/native/scene_ops`](D:\dev\hemifuture\ex_mmo_cluster\apps\scene_server\native\scene_ops)

另外，[`apps/scene_server/priv/native`](D:\dev\hemifuture\ex_mmo_cluster\apps\scene_server\priv\native) 里已经提交了预编译产物，而且当前是 `.so` 文件。这更像是 Linux 产物；在 Windows 下不要默认它们能直接工作。

### 配置路径并不统一

不是所有 app 都读取 umbrella 根配置。有些子应用在自己的 `mix.exs` 里指向本地 `config/config.exs`，有些则直接指向仓库根配置。
动配置前，先看目标 app 的 `mix.exs` 里的 `config_path`。

## 常用命令

在仓库根目录：

```powershell
mix deps.get
mix compile
mix test
```

按 app 定位问题时，优先进入对应子目录执行：

```powershell
cd apps\auth_server
mix phx.server

cd apps\visualize_server
mix phx.server

cd apps\scene_server
iex -S mix

cd apps\gate_server
iex -S mix
```

自定义任务：

```powershell
cd apps\gate_server
mix proto_gen

cd apps\data_store
mix db.initialize
```

## 当前编译排查结论

这台机器当前实际运行的是 `Elixir 1.19.5 + OTP 28`，和仓库声明版本并不一致。

在这个更高版本工具链下，仓库原始依赖会遇到两类问题：

- `ssl_verify_fun 1.1.6` 在当前环境下无法稳定编译，已升级到 `1.1.7`
- 旧版 Cowboy/Plug 依赖栈对 OTP 28 兼容性较差，需要使用更新后的锁文件

另外，原仓库依赖 `bcrypt_elixir`，它在 Windows 下要求 `nmake + cl` 这套 MSVC 编译链；当前环境只有 `mingw32-make + gcc`，因此会卡在原生 NIF 编译。仓库现在已改为使用 OTP 自带 `:crypto.pbkdf2_hmac/5` 做密码哈希，避免把本地 C 编译工具作为必需条件。

## 建议工作流

改行为时，先定位归属 app：

- 登录/账号流：`auth_server`，涉及持久化时再看 `data_service` / `data_store`
- Socket / 协议流：`gate_server`，必要时连同 proto submodule 一起看
- 移动 / AOI / 物理：`scene_server`，跨边界问题要同时看 Elixir 包装层和 Rust crate
- 浏览器场景调试：`visualize_server`

改 `scene_server` 时，通常要同时检查：

- `lib/scene_server/native/*` 下的 Elixir 包装层
- `native/*/src` 下对应的 Rust 实现

改 Phoenix 应用时，通常要同时关注：

- `assets/`
- `lib/..._web/`

## 协作约定

- 开始改某个 app 前，先看它自己的 `mix.exs`、`application.ex` 和 supervisor 结构。
- 环境不稳定时，优先做 app 级验证，不要一上来就跑全 umbrella。
- 先确认文件是不是生成物、submodule 内容，或者原生编译产物，再决定是否直接编辑。
- 这个仓库“目标架构一致”，但“实现成熟度不一致”，跨 app 推断要保守。
- 如果需要同时起两个 Phoenix 服务，请显式改端口，并在变更说明里写清楚。
