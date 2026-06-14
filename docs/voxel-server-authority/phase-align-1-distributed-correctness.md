# 对齐迁移 · 梯队 1:分布式正确性地基(D-3 高优)

> 上层索引:[`2026-06-14-architecture-triage-and-alignment.md`](./2026-06-14-architecture-triage-and-alignment.md)
> 规范依据:CELL-18/19/20/23/24、CELL-9~15、TIME-1~6、AUTH-2/3/4/7/10、PERS-12;v2.0.2 CELL-19/AUTH-3 chunk 聚合等价。
> 拍板:D-3(分布式 HA 地基必须尽快补)、D-4(prefab 也须 durable-before-ack)。
> 纪律:决策稿先行 → 逐 step commit(`mix format` + 全量相关回归)→ 进度日志 → 不 push → 不留兼容。

## 目标

把 fencing / epoch / 时间 / 提交 / 跨界交接从"单进程内存 + 墙钟 + 部分异步确认"提升到规范的
**线性化 epoch + DB 条件写 + 单调时钟自检 + durable-before-ack + 幂等 + entity_handoff 幂等协议**。
这是后续梯队(NIF 数据归属、复制 watermark、涌现提交)正确性赖以成立的地基。

## 现状锚点(2026-06-14 审计 + 源码精读)

- `WorldServer.Voxel.MapLedger`:节点本地单 GenServer,`issue_lease` 用 `next_owner_epoch` 内存自增,
  整库 `term_to_binary` 单行 blob 持久化(`MapLedgerStore`)。**ANTI-32 风险**:多 world 节点/failover 下
  epoch 单调仅靠内存单主(违 CELL-23)。
- `DataService.Voxel.WriteTokenStore`:**in-memory GenServer**,`{logical_scene_id, region_id}` 键,
  `token_version` CAS,`validate_write` 校验 lease_id/owner_scene_instance_ref/owner_epoch/bounds/expiry。
  **重启即空**(fencing 失效窗口);`expires_at_ms` 用 `System.system_time`(墙钟,违 CELL-24)。
  被 34 处引用,仍挂 data_service 监督树,大量测试用 `reset/1`。
- `DataService.Voxel.ChunkSnapshotStore`:已是 stateless + `pg_advisory_xact_lock + FOR UPDATE +
  chunk_version` CAS(**留用**,v2.0.2 承认 chunk_version 作 cell_seq 聚合等价)。
- `SceneLease` / `ChunkProcess.lease_stale?`:用 `expires_at_ms` 墙钟自检。
- prefab/事务 commit:`ChunkProcess.enqueue_snapshot_persist`(`Task.start_link` 异步落库)→ `:queued`
  入队即 ack(违 AUTH-2,D-4 判缺陷)。单方块编辑已 durable-before-ack(留用)。
- `command_id` 幂等:**无**;只到 `(transaction_id, decision_version)` + chunk_version CAS。
- `entity_handoff`:**完全缺失**;现有 `MigrationPlan` 是 region ownership 迁移(方向=cell_migration)。
- `cell_tick`/`sim_time`:**无**;`SimulationTick.tick_seq` 进程内自增、重启归零(违 TIME-1)。

## 关键决策(每项给推荐值)

- **D1-1 epoch 线性化基础**:用 **Postgres 作为 epoch 分配与 lease 签发的线性化点**(CELL-23 列举的
  "数据库事务锁/条件写"路径,与既有 `ChunkSnapshotStore` 同构),而非引入 Raft/etcd。
  **推荐**:新增 `voxel_region_ownership` 表(每 region 一行:region_id/logical_scene_id/owner_epoch/
  current_lease_id/owner_scene_instance_ref/bounds/...),epoch 递增与 lease 翻转走**单事务条件 UPDATE**
  (`WHERE owner_epoch = $expected`),并发失败即重试/拒绝。MapLedger 退化为该表的**缓存 + 编排**,
  权威单调性由 DB 行级条件写保证。理由:与现有持久化栈同构、最小新依赖、满足 CELL-23/v2.0.2。
- **D1-2 WriteTokenStore 落库**:改为 **stateless + Postgres**(对齐 `ChunkSnapshotStore` 风格),
  新增 `voxel_write_tokens` 表(`(logical_scene_id, region_id)` 主键 + token_version CAS)。
  `validate_write` 走单行 SELECT;`upsert_token` 走 `token_version` 条件 upsert。`reset/1` 改 `delete_all`
  (test hatch 保留)。从监督树移除 GenServer。**推荐**:与 D1-1 的 `voxel_region_ownership` **合一**——
  token 即 ownership 行的投影,避免两份 epoch 真相。待 step 1.2 评估是否单表。
- **D1-3 单调时钟(CELL-24)**:**安全靠 owner_epoch fencing(已有),expiry 仅作 liveness backstop**。
  owner 侧(ChunkProcess / SceneLease 持有者)用 `System.monotonic_time` 自检"是否该停写并续租";
  **禁止**把跨节点墙钟差作为权威顺序来源。DataService 侧 expiry 校验保留但降级为"宽限 backstop",
  正确性不依赖它。**推荐**:owner 自检改单调时钟 + 显式续租;DB token 存 `lease_deadline`(由 owner 单调
  时钟换算的保守 TTL)仅作过期清理,不作 fencing 唯一依据。
- **D1-4 prefab durable-before-ack(D-4)**:prefab/事务 commit 在**落库成功后**才向客户端 ack;
  失败则返回可恢复错误。**推荐**:把 `enqueue_snapshot_persist` 异步路径改为**同步 persist**(commit 阶段
  本就持 fence,落库失败可 abort/重试);保留批量 persist 的批处理性能(一次事务多 chunk),但**确认晚于
  事务提交**。不引入 speculative ack(D-4 已否决 AUTH-14 路线)。
- **D1-5 command_id 幂等(AUTH-4)**:权威命令(放置/破坏/prefab/damage)携带 `command_id`,服务端
  维护**幂等去重**(durable replay-protection)。**推荐**:`voxel_command_log` 表(command_id 唯一键 +
  结果摘要),提交事务内"插入 command_id 或命中已存→返回既有结果",与世界写入**同事务**保证 exactly-once。
  wire 侧 `VoxelEditIntent` 已有 `request_id`/`client_intent_seq`,梯队按"只追加"补 `command_id`(或以
  `(actor_id, client_intent_seq)` 派生稳定 command_id)。
- **D1-6 cell_tick/sim_time(TIME-1)**:每个权威单位(ChunkProcess/region owner)维护**不随进程重启/
  迁移重置**的 `cell_tick` 与 `sim_time`,持久化到 ownership 行/快照。**推荐**:`cell_tick` 随权威命令
  单调推进并随 chunk snapshot 持久化,重启从持久化值恢复;复制消息携带 `snapshot_tick`。
- **D1-7 entity_handoff(CELL-9~15)**:实现实体跨 region 的**幂等两阶段 transfer 协议**
  (`prepare/accept/commit/abort/timeout`,信封用 `MmoContracts.Envelope.EntityHandoff`),**不递增 owner_epoch**;
  `MigrationPlan` 正名为 `cell_migration` 语义(递增 owner_epoch,补 `migration_tick`/`commit_watermark`)。
  **推荐**:entity_handoff 作为独立协议,复用 transaction coordinator 的幂等/恢复经验;ghost 预热复用
  现有 `migration_prewarm`。此为梯队 1 最大子项,排在最后(依赖前述 epoch/时间/幂等地基)。

## Step 列表(逐步、每步全绿可回归)

- **1.1** `cell_tick`/`sim_time` 时间模型(TIME-1):在 ChunkProcess/SimulationTick 引入持久化、
  不随重启重置的 `cell_tick`+`sim_time`;chunk snapshot 持久化字段;`use StateClassed` 顺带补 scene 持有者。
- **1.2** WriteTokenStore → Postgres(D1-2):新表 + migration + stateless 重写 + `reset` delete_all +
  从监督树移除;迁移所有调用方/测试。回归 data_service + 引用方。
- **1.3** epoch 线性化(D1-1):`voxel_region_ownership` 表条件写 epoch/lease;MapLedger 退化为缓存+编排;
  与 1.2 token 合一评估。回归 world_server + scene_server + gate。
- **1.4** 单调时钟自检(CELL-24,D1-3):owner 侧 lease_stale?/续租改单调时钟;DataService expiry 降级 backstop。
- **1.5** prefab durable-before-ack(D-4) + command_id 幂等(AUTH-4):commit 同步落库后 ack;`voxel_command_log`
  同事务幂等。回归 gate + scene + world(prefab/damage 路径)。
- **1.6** entity_handoff 幂等协议(CELL-9~15) + cell_migration 正名 + migration_tick/commit_watermark。

> 排序理由:1.1 时间模型与 1.2 token 落库是低耦合地基;1.3 epoch 线性化是 D-3 头部;1.4 时钟;1.5 提交正确性;
> 1.6 entity_handoff 最复杂、依赖前述,放最后。每步独立 commit + 全量相关回归,任何一步不绿不进下一步。

## 测试矩阵(每步)

- `mix format` + `mix compile`(0 warning)。
- 受影响 app 全量回归:data_service(82+)、world_server(72)、scene_server(378)、gate_server(191)按步选择。
- 新增:epoch 单调性 property/并发条件写测试、token 重启存活测试、durable-before-ack 时序测试、
  command_id 幂等重放测试、entity_handoff 幂等(重复 prepare/commit 不复制/丢失)测试。
- 已知预存失败 `world_server/.../authority_observe_test.exs:35`(Windows path 大小写)不动。

## 验收

- epoch 单调性由 DB 条件写保证、跨重启/并发不回退(CELL-18/23);旧 epoch 写入必失败(CELL-19)。
- 安全不依赖墙钟;owner 单调时钟自检停写(CELL-24)。
- 所有 durable_authoritative 命令 ack 晚于 durable commit(AUTH-2,含 prefab);重复 command_id 不重复副作用(AUTH-4)。
- cell_tick/sim_time 单调且不因所有权/重启重置(TIME-1)。
- entity_handoff 与 cell_migration 语义/术语分离;entity_handoff 不递增 owner_epoch、幂等(CELL-9~15)。
- 全量回归 0 净回归。

## 进度日志(时间倒序)

- 2026-06-14:决策稿落定。下一步 step 1.1(cell_tick/sim_time)或 step 1.2(WriteTokenStore 落库),
  二者低耦合,按实现便利择一先行。
