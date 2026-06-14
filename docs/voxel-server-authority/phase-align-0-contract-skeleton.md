# 对齐迁移 · 梯队 0:契约骨架前置(FROZEN-5 信封 + PERS-5 state_class + watermark)

> 上层索引:[`2026-06-14-architecture-triage-and-alignment.md`](./2026-06-14-architecture-triage-and-alignment.md)
> 规范依据:ROADMAP-1(契约骨架先行)、FROZEN-1~5、PERS-5、AUTH-1/3/8、TIME-1~6、EVENT-2。
> 纪律:决策稿先行 → 逐 step commit(`mix format` + 测试)→ 进度日志 → 不 push → 不留兼容。

## 目标

把规范的**承重信封与状态分类**作为**显式、可测试、单一来源**的契约引入,为后续梯队(epoch fencing、durable-commit、watermark、Replicator、system_actor)提供统一锚点。本梯队**只建骨架与分类,不改运行时 wire layout**(wire 演进留各梯队按"只追加不破坏"推进)。

## 关键决策

- **D0-1 契约的家**:新建 umbrella app `apps/mmo_contracts`(纯库,无 application 监督树),作为 FROZEN-* 信封与 PERS-5 分类的单一来源。依据 v2.0.2 MOD-1(逻辑层职责清单,不强制 app 数量,但允许独立 contracts 库)。**推荐**:独立 app 而非塞进 data_service/beacon_server,因为契约被 gate/scene/world/data 多方共享,放进任一现有 app 都会制造错误的依赖方向。
- **D0-2 state_class 形态**:`MmoContracts.StateClass` 提供四个原子 `:durable_authoritative | :runtime_authoritative | :derived | :ephemeral` + `valid?/1` + `classify_*` 校验 + 文档化语义。**推荐**:原子 + 编译期可引用常量,而非字符串。
- **D0-3 分类登记机制**:状态持有者(Ecto schema / GenServer state 模块 / 场层)通过 `use MmoContracts.StateClassed, class: :xxx` 或模块属性 `@state_class :xxx` 声明;提供 `MmoContracts.StateRegistry` 在编译期/测试期枚举并校验"未分类禁入生产"(PERS-5)。**推荐**:先用模块属性 + 一份集中 registry 清单(`priv` 或模块常量),测试断言覆盖所有已知状态持有者;不强求宏魔法。
- **D0-4 信封骨架范围**:本梯队落地 FROZEN-5 的 **typed struct 骨架 + version 字段 + 校验**,不接 wire/codec(wire 集成在各对应梯队做):
  - `MmoContracts.Envelope.AuthCommand`(AUTH-1/FROZEN-5):command_id/actor_id/cell_id/owner_epoch/client_seq/target_tick|server_received_tick/precondition/payload_type/payload_version/payload。
  - `MmoContracts.Envelope.SystemCommand`(AUTH-11):在 AuthCommand 基础上 + system_actor/rule_version/candidate_effect_id/idempotency_key/causation_id。
  - `MmoContracts.Envelope.AuthEvent`(EVENT-2):event_id/event_type/schema_version/cell_id/owner_epoch/cell_seq/tick_id/causation_id/correlation_id/actor_id/delivery_class/created_at/payload。
  - `MmoContracts.Envelope.CellTime`(TIME/FROZEN-5):cell_tick/sim_time/dilation_ratio/snapshot_tick/snapshot_seq。
  - `MmoContracts.Envelope.ReplicationOut`(REPL/FROZEN-5):observer_id/cell_id/snapshot_seq/delta_base/budget_class/priority_score/reliability_class/visibility_watermark/payload。
  - `MmoContracts.Envelope.PersistenceMeta`(PERS/FROZEN-5):state_class/schema_version/commit_watermark/visibility_watermark/replay_source/rebuild_algorithm_version。
  - `MmoContracts.Envelope.CandidateEffect`、`EntityHandoff`、`CellMigration`、`BoundaryEvent`(FROZEN-5 subtypes)——骨架占位,字段按规范 §18。
- **D0-5 cell_id 编码**:`MmoContracts.CellId` 同时容纳规范 `(level, morton)` 与 v2.0.2 的 `region_id` 聚合等价,并提供二者映射占位(D-2)。**推荐**:`%CellId{kind: :region | :morton, ...}` 统一类型,region↔morton 映射函数先留 `@doc` + 占位实现。
- **D0-6 不在范围**:不改任何现有 wire/codec;不改 ChunkProcess/MapLedger 运行时行为;不接 watermark 闸门(梯队3);不强制所有历史模块立即声明 state_class(先覆盖核心状态持有者,其余在各梯队迁移时补)。

## Step 列表

- **0.1** 新建 `apps/mmo_contracts` 纯库 app(mix.exs + 空 lib + test_helper)+ `MmoContracts.StateClass`(四分类 + valid?/classify)+ 单测。
- **0.2** `MmoContracts.Envelope.*` typed struct 骨架(AuthCommand/SystemCommand/AuthEvent/CellTime/ReplicationOut/PersistenceMeta + 4 个 subtype 占位)+ `new/1` 校验 + 单测。
- **0.3** `MmoContracts.CellId`(region/morton 统一类型 + 映射占位)+ 单测。
- **0.4** `MmoContracts.StateClassed` 声明机制(模块属性 + 校验 helper)+ `MmoContracts.StateRegistry` 集中清单 + 单测(PERS-5 "未分类禁入生产" 用一条 registry 完备性测试守护)。
- **0.5** 把 data_service voxel schema(durable)、scene_server movement/combat(runtime)、field(derived)、粒子/cue(ephemeral)登记进 StateRegistry(只加声明,不改行为)。加 `mmo_contracts` 到相应 app deps。

## 测试矩阵

- `cd` umbrella 根 `mix test apps/mmo_contracts/test`(纯库,无需 Postgres)。
- 每 step:`mix format` + `mix compile`(确认无 warning 升 error)+ 新增单测全绿。
- 0.5 后:回归 `mix test apps/data_service/test`(需 Postgres)确认依赖加入不破坏现有。

## 验收

- 四分类是单一来源、可校验;FROZEN-5 六个核心信封 + 四个 subtype 有 typed struct + version 字段 + 构造校验。
- StateRegistry 能枚举核心状态持有者并断言其 state_class 已声明(PERS-5)。
- 现有测试 0 回归;不引入 wire 变更。

## 进度日志(时间倒序)

- 2026-06-14:**梯队 0 契约骨架收口**。
  - step 0.1 ✓ `apps/mmo_contracts` + `StateClass`(7 测试)。
  - step 0.2 ✓ `Envelope` helper + 6 核心信封 + 4 subtype 信封(共 32 测试)。
  - step 0.3 ✓ `CellId`(morton + region 聚合等价,9 测试)。
  - step 0.4 ✓ `StateClassed` 宏 + `StateRegistry` 清单(6 测试)。mmo_contracts 共 **47 测试全绿**。
  - step 0.5 ✓ 跨 app 机制打通:data_service 接 mmo_contracts dep + 5 持有者 `use StateClassed` 自声明
    + 一致性测试;**data_service 82 tests + 1 doctest 全绿 0 回归**。建库 `mmo_dev` + migrate 完成。
  - 基线:umbrella 全量编译(含 5 Rust crate)EXIT=0。
  - **遗留(增量收尾)**:scene_server / world_server 的清单持有者(PlayerCharacter/Combat.State/MapLedger/
    TransactionCoordinator/ObjectRegistry/Field*/SimulationTick)的 `use StateClassed` 自声明,
    在各自梯队(1/2/3)首次触及对应模块时按 data_service 同模式接入并补一致性测试。
    StateRegistry 清单已是 PERS-5 单一来源;自声明是编译期强化,增量铺开不阻塞后续梯队。
- 2026-06-14:决策稿落定,基线编译确认后进入 step 0.1。
