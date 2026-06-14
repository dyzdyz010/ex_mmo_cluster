# 对齐迁移 · 梯队 1 · step 1.6:entity_handoff 幂等协议 + cell_migration 正名

> 上层:[`phase-align-1-distributed-correctness.md`](./phase-align-1-distributed-correctness.md)(D1-7)
> 规范依据:CELL-9~15(entity_handoff 与 cell_migration 分离)、CELL-10/11(owner_epoch 仅 cell_migration
> 递增)、CELL-20/TIME-6(migration_tick 后旧 owner 禁写)、FROZEN-5(信封)。
> 信封已在梯队0 建好:`MmoContracts.Envelope.EntityHandoff` / `MmoContracts.Envelope.CellMigration`。
> 纪律:逐子步 commit(`mix format` + 相关回归)→ 进度日志 → 不 push → 不留兼容。

## 目标

把规范要求"实体跨界(entity_handoff)与 Cell 所有权迁移(cell_migration)两个不同概念严格分离"在
**运行时**落地:
1. **cell_migration 正名**:现有 `WorldServer.Voxel.MigrationPlan`(region 所有权迁移,经 new_lease
   递增 owner_epoch)即 cell_migration 语义,补 `migration_tick`/`commit_watermark` 字段 + cutover 时
   发射 `CellMigration` 信封,formalize 正名。
2. **entity_handoff 幂等协议基元**:新建实体跨 Cell 的两阶段幂等 transfer 状态机
   (`prepare/accept/commit/abort/timeout`,信封 `EntityHandoff`),**不递增 owner_epoch**,source/target
   各自 owner_epoch 仅作 fencing。

## 现状锚点(2026-06-14 实体模型审计)

- **实体运行时单 scene_node 固定**:`SceneServer.PlayerCharacter`(per-player GenServer,持
  position/movement/combat/last_input_seq)由 `PlayerManager`(cid→pid map)管理;`logical_scene_id`
  硬编码 `1`;movement_tick **不检查 region 边界**;AOI 全局单 octree region-agnostic;**跨 region
  实体转移完全不存在**。NPC(`Npc.Actor`)同构。
- **MigrationPlan = cell_migration**:region 所有权迁移状态机(`:prewarming→:prewarmed→:cutover→
  :completed`),slice 预热 + final-catchup-ack,cutover 经 `new_lease`(线性化分配的 owner_epoch)
  翻转所有权。已被 MapLedger(begin/cutover/complete_migration)+ authority_observe 使用。
  **缺 migration_tick/commit_watermark**。
- **信封就位**:`EntityHandoff`(entity_transfer_id/source+target_cell_id/source+target_owner_epoch/
  handoff_tick/transfer_status/idempotency_key/deadline_tick/visibility_cutover_snapshot_seq...);
  `CellMigration`(cell_id/old+new_owner_epoch/migration_tick/snapshot_ref/commit_watermark,强制
  new_owner_epoch > old)。

## 范围裁剪(关键)

- **本步只交付控制面协议基元 + cell_migration 正名**,**不** wire 边界检测、不搬迁真实 PlayerCharacter、
  不跨 scene_node 转移实体。**理由**:实体运行时单节点固定、跨 region 实体移动尚不存在;规范要求的是
  "两概念分离 + 幂等协议存在",基元 + 信封 + 属性测试即满足 tier-1 "分布式正确性地基"。
- **明确推迟到多 scene_node tier(梯队2/3 或专门 phase)**:`EntityBoundaryMonitor`(每 tick 查
  PlayerCharacter 越界)、真实实体状态 snapshot/apply、连接重定向、跨节点 RPC。这些依赖多 scene_node
  实体部署,不在 tier-1 范围。本步基元为其打底(boundary monitor 落地时调本基元)。

## 关键决策(每项给推荐值)

- **D1.6-1 cell_migration 正名落点**:在 `MigrationPlan.cutover/2` 内计算 `migration_tick` /
  `commit_watermark`,**来源 = final_catchup_acks 的 max `max_chunk_version` 前沿**(v2.0.2 承认
  chunk_version 作 cell_seq 聚合等价 → 该前沿即"所有权切换的版本边界",旧 owner 禁写过此)。新增
  `MigrationPlan.cell_migration_envelope/1` 构 `CellMigration`(old=old_lease.owner_epoch || 0、
  new=new_lease.owner_epoch、cell_id=region_id、migration_tick/commit_watermark=前沿、
  snapshot_ref=migration_id)。MapLedger cutover 时 `CliObserve.emit("voxel_cell_migration_committed", ...)`
  发射。**理由**:不引 DataService 往返(前沿已在 plan.final_catchup_acks),与既有 cutover 同点。
  **注**:old_owner_epoch == new_owner_epoch 时(无真实 epoch 抬升的退化迁移)不发信封(envelope
  强制 new>old),仅发既有 observe;真实迁移(new>old)才发 CellMigration。

- **D1.6-2 entity_handoff 基元形态**:纯状态机模块(mirror MigrationPlan 的"纯 struct + 转移函数"风格,
  非 GenServer),`WorldServer.Entity.HandoffPlan`。`new/1`→`:prepare`;`accept/2`→`:accept`;
  `commit/2`→`:commit`;`abort/2`→`:abort`;`timeout/2`→`:timeout`。**幂等**:重复转移到当前 status
  返回 `{:ok, plan}` no-op;非法顺序(如 prepare 直接 commit、abort 后 commit)返回 `{:error, reason}`。
  **不递增 owner_epoch**;`source_owner_epoch`/`target_owner_epoch` 在 accept 时做 fencing 校验
  (与传入期望不符则 `{:error, :epoch_mismatch}`)。`idempotency_key` = `{entity_id, source_cell_id,
  target_cell_id, transfer_seq}`。**理由**:与 MigrationPlan 同构(可测、可恢复、控制面纯函数),
  落地 boundary monitor 时由其驱动。

- **D1.6-3 基元归属**:放 `apps/world_server/lib/world_server/entity/handoff_plan.ex`。**理由**:跨 Cell
  实体转移是 World 跨 region 编排职责(与 MigrationPlan/TransactionCoordinator 同层);实体 state
  本体在 Scene,但**协议状态机**是控制面纯函数,location-agnostic。

- **D1.6-4 状态字段**:基元 plan 持信封字段子集 + 转移所需:entity_transfer_id/entity_id/entity_kind/
  source_cell_id/target_cell_id/source_owner_epoch/target_owner_epoch/handoff_tick/transfer_seq/
  target_accept_seq/transfer_status/idempotency_key/deadline_tick/entity_state_ref+digest/
  visibility_cutover_snapshot_seq。`cell_migration_envelope`/`entity_handoff_envelope` 各自能从 plan
  构出对应信封(校验形态)。

## Step 列表(逐子步、每步全绿可回归)

- **1.6a** cell_migration 正名:MigrationPlan 加 `migration_tick`/`commit_watermark` 字段;`cutover/2`
  计算前沿并写入;新增 `cell_migration_envelope/1`;MapLedger cutover 发射 `CellMigration` observe
  (new>old 时)。moduledoc 标注 cell_migration 语义。回归 world_server。
- **1.6b** entity_handoff 基元:新建 `WorldServer.Entity.HandoffPlan` 纯状态机 +
  prepare/accept/commit/abort/timeout + 幂等 + epoch fencing + `entity_handoff_envelope/1`。
  property/幂等测试(重复 prepare/accept/commit 不复制不丢失、非法顺序拒绝、不递增 owner_epoch)。
  回归 world_server + mmo_contracts。

## 测试矩阵

- `mix format` + `mix compile`(0 warning)。
- world_server 全量回归(126)+ 新增:MigrationPlan migration_tick/commit_watermark/cell_migration_envelope
  测试;HandoffPlan 状态机 + 幂等 + epoch fencing 测试。
- mmo_contracts(EntityHandoff/CellMigration 信封已有测试,不回归)。
- 已知预存失败 `world_server/.../authority_observe_test.exs:35`(Windows path)不动。

## 验收

- cell_migration 与 entity_handoff 语义/术语/代码分离:owner_epoch 只在 cell_migration(MigrationPlan
  cutover)递增,entity_handoff 基元绝不碰 owner_epoch(CELL-10/11)。
- MigrationPlan cutover 产 `migration_tick`/`commit_watermark` 且发 `CellMigration` 信封(new>old)。
- entity_handoff 基元幂等:重复 prepare/accept/commit/abort 不复制/丢失;非法顺序拒绝;epoch fencing 生效。
- world 全量 0 净回归。
- **边界检测/真实实体搬迁/跨节点**明确不在本步,文档标注推迟落点。

## 进度日志(时间倒序)

- 2026-06-14:决策稿落定。实体模型审计确认实体单 scene_node 固定、跨 region 实体移动不存在,故 tier-1
  只交付控制面协议基元 + cell_migration 正名,boundary monitor / 真实搬迁 / 跨节点推迟多节点 tier。
  拆 1.6a(cell_migration 正名)/1.6b(entity_handoff 基元)。
