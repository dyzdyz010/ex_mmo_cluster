# 对齐迁移 · 梯队 4:收尾清理

> 上层索引:[`2026-06-14-architecture-triage-and-alignment.md`](./2026-06-14-architecture-triage-and-alignment.md)
> 规范依据:§16/ANTI-8(遗留 Mnesia 退出)、ANTI-5(空壳 app)、MOD-3(NIF facade 收敛)、"全新系统不留兼容"。
> 纪律:决策稿先行 → 逐 step commit(`mix format` + 相关回归)→ 进度日志 → 不 push → 不留兼容。

## 现状(进入梯队 4 时)

梯队 0–3 全部落地(契约骨架 / 分布式正确性 / NIF 故障与数据归属 / 提交·复制·涌现契约)。已完成的梯队 4
部分:删 `agent_server`/`agent_manager`(ANTI-5)、`data_store`/`data_contact`(ANTI-8)、`coordinate_system`
crate(BND-1/NIF-12);残留死 atom 引用已清。**剩余清理三项**(本稿):

## 4.1 WriteTokenStore 兼容垫片移除(不留兼容)

**现状**:`DataService.Voxel.WriteTokenStore` 梯队1 已改 Postgres durable(`voxel_write_tokens` 表 +
`token_version` CAS + advisory lock),但保留**兼容垫片**(moduledoc 自述"过渡 tech-debt,移除列入梯队4"):
空 `GenServer`(`start_link`/`init`/`handle_call`)+ 4 个 API 函数的首参 `server` 被忽略。`MapLedger`
仍把 `write_token_store` 当**进程句柄**(`publish_write_token` 用 `Process.alive?`/`whereis` 守活),
`authority_observe` 仍 `start_link` 一个 token_store pid 当隔离实例。

**改造**(全新系统不留兼容):
- `write_token_store.ex`:删 `use GenServer` + `start_link`/`init`/`handle_call`;4 个函数(`upsert_token`/
  `validate_write`/`snapshot`/`reset`)删首参 `server`(DB 是唯一真相,模块级无状态调用)。
- `data_service/application.ex`:删 WriteTokenStore 子进程(不再有进程)。
- `map_ledger.ex`:`write_token_store` 配置语义从"进程句柄"降为**enable 标记**(非 nil = 发布);
  `publish_write_token` 删 pid/atom liveness 分支,直接 `WriteTokenStore.upsert_token(to_map(token))`。
  production `world_sup` 仍传 `write_token_store: DataService.Voxel.WriteTokenStore`(留作真值 enable 标记,
  最小 churn)。
- `authority_observe.ex`:`start_runtime` 不再 `start_link`/`stop` token_store pid,直接用模块 + truthy 标记;
  `validate_both`/`fetch_current_token` 删 token_store 句柄参,走模块 API。
- 测试:删 `start_supervised!(WriteTokenStore)`;`reset(WriteTokenStore)`→`reset()`、`upsert_token(store,..)`
  →`upsert_token(..)`、`validate_write(store,..)`→`validate_write(..)`。
- 回归闸门:data_service / world_server / scene / gate 相关全量。

## 4.2 data_init(遗留 Mnesia bootstrap)

**判定:已是非 live 迁移工具,完整删除推迟到 Mnesia 生产数据退役后。** `data_init` app **不启动任何
进程**(无 supervision tree,`extra_applications: [:logger]`),仅 `create_database/0`(一次性 Mnesia
bootstrap)+ `TableDef`(供 `mix migrate_to_pg` 读旧 Mnesia)。其 `data_service` 依赖是**编译期**(迁移
task 用),无运行时 `DataInit.*` 调用。**架构层面(ANTI-8/§16:live 路径无 Mnesia)已满足**——它已是"披着
app 外壳的迁移脚本"。在 Mnesia 生产数据完成迁移并退役前删除会破坏 `mix migrate_to_pg`(依赖 `TableDef`)。
故本梯队**不删 data_init**;标注为迁移工具,待数据退役后整体移除(届时 `TableDef` 随之删)。

## 4.3 cargo workspace + 单 NIF facade(MOD-3)

**判定:单 cdylib facade 受 Rustler 0.37.3 限制(单 `init!` 单模块),保留多 crate;尝试 workspace
Cargo.toml 收敛依赖/profile,失败则保留现状并记录。** `native/` 现为 5 个独立 crate(`movement_core`
rlib + `scene_ops`/`octree`/`field_kernel`/`movement_engine` 4 cdylib,各自 `rustler::init!` 一个 Elixir
模块),无顶层 workspace。MOD-3"单 facade"被 Rustler 0.37.3"一 init 一模块"挡住(需自定义 unsafe FFI 或
大版本升级)。**承重已满足**(BND-1 数据入 Rust / NIF-11/15 panic=unwind 各 crate 已配 / NIF-1 节点级
SimRuntime),MOD-4 [v2.0.2] 亦允许"stage 调度在 Elixir、Rust 仅算力单元"合规变体。可行的 MOD-3 步是加
`native/Cargo.toml` `[workspace]` 协调 member/Cargo.lock/profile——**但改 cargo 构建结构在 Windows NIF 工具链
有真实破坏风险**;尝试后若破坏编译即回退并记录(单 facade 显式记为 Rustler 版本受限的 future)。

## 进度日志(时间倒序)

- 2026-06-14:**4.1 WriteTokenStore 兼容垫片移除完成**。`write_token_store.ex` 删 `use GenServer` +
  `start_link`/`init`/`handle_call` + 4 个 API 函数首参 `server`(模块级无状态);`data_service/application.ex`
  删 WriteTokenStore 子进程;`map_ledger.ex` `publish_write_token` 改 enable 标记语义(删 pid/atom liveness
  分支,直发 `WriteTokenStore.upsert_token/1`);`chunk_snapshot_store.ex` `validate_write_token` 删 token_store
  句柄(忽略 `:write_token_store` opt);`authority_observe.ex` 不再 start_link/stop token_store pid;
  `voxel_smoke.ex` 删 WriteTokenStore named-process 启动(漏网生产调用方)。~15 测试文件去 `start_supervised!`
  /2-arg shim 调用(脚本批处理 + 手工收口 store 变量/stop_supervised/进程守卫)。**回归全绿:data_service 111
  / world_server 149 / gate_server 215 / scene_server 931,umbrella `--warnings-as-errors` 0 warning。**
  剩 4.2(data_init 判定保留)、4.3(cargo workspace 尝试)。
- 2026-06-14:决策稿落定。4.1 WriteTokenStore 垫片移除先行;4.2 data_init 判定保留(已非 live);
  4.3 cargo workspace 尝试 + 回退兜底。
