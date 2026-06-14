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
- **跨节点耦合(执行 1.2/1.3 必读)**:`WriteTokenStore` 的 GenServer 形态被**跨节点**使用——
  `MapLedger`(world 节点)经 `upsert_token(server, ...)` 远程 publish token 到 DataService 节点的命名进程;
  `token_store` server ref 在 `MapLedger`/`ChunkSnapshotStore`/`AuthorityObserve` 多处穿线(arity-2 注入式),
  `chunk_process`/`dev_seed` 用 arity-1 默认 server。调用方:`map_ledger.ex:1071`(upsert)、
  `chunk_snapshot_store.ex:265` / `chunk_process.ex:2932`(validate)、`authority_observe.ex:328/355/397`、
  `dev_seed.ex:274`。**含义**:改 stateless+DB 必须同时决定"epoch/token 的 DB 写在哪个节点发生"
  (World 直写共享 DB,还是经 DataService 入口),并保留可注入 server ref 供测试。**这把 1.2 与 1.3
  绑成一个跨节点 fencing 重设计**,而非纯 data_service 局部改。
- `entity_handoff`:**完全缺失**;现有 `MigrationPlan` 是 region ownership 迁移(方向=cell_migration)。
- `cell_tick`/`sim_time`:**无**;`SimulationTick.tick_seq` 进程内自增、重启归零(违 TIME-1)。

## 关键决策(每项给推荐值)

- **D1-1 epoch 线性化基础**【架构已核实可行,2026-06-14】:用 **Postgres 作为 epoch 分配与 lease 签发的
  线性化点**(CELL-23 列举的"数据库事务锁/条件写"路径,与既有 `ChunkSnapshotStore` 同构),而非 Raft/etcd。
  **核实证据**:`world_sup.ex:30` 的 `TransactionCoordinator` 已用注入式 `persist_fn(DataService.Repo)`
  让 world 节点**直接写 DataService.Repo**(MVP 单 release 全 app 共置一 BEAM,Repo 可达;A4-bis-cluster
  "每 app 独立 BEAM"时经同一注入 seam 换 repo/fn 即可)。故 MapLedger 的 epoch/lease 可走同款注入式
  DB 条件写,MapLedger 退化为 DB 行的缓存 + 编排。**实施前置**:`voxel_region_ownership` 表条件 UPDATE
  (`WHERE owner_epoch = $expected`)。
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

- 2026-06-14:**step 1.5b(command_id 跨层线程化,AUTH-4)完成**。详见
  [`phase-align-1-step1.5b-command-id-threading.md`](./phase-align-1-step1.5b-command-id-threading.md)。
  1.5b-1 单方块编辑 command_id 同事务 record_once(gate→scene→store);1.5b-2 prefab idempotency-key
  (claim/confirm/release)关闭重试产重复 object 洞。回归 data 104 / gate 197 全绿。
  **梯队1 仅剩 1.6 entity_handoff。**

- 2026-06-14:**step 1.1(cell_tick/sim_time,TIME-1)完成 + test_helper 陈旧事务快照清理**。
  ChunkProcess init 恢复 cell_tick + restart gap;run_simulation_tick 推进 + 每 50 tick touch_cell_time
  单调落库(与 put_snapshot 解耦)。scene/world/gate test_helper 启动前清陈旧事务表。
  回归 scene 918 / data 95 / world 126 / gate 196 全绿。梯队1 已覆盖 AUTH-2/PERS-5/CELL-19-21/
  CELL-18-23/AUTH-4 原语/TIME-1;剩余 1.5b command_id 线程化、1.6 entity_handoff。
- 2026-06-14:**step 1.5a 命令幂等日志 CommandLog 完成(AUTH-4/SEC-4)**。新增 `voxel_command_log`
  表 + `CommandLog.record_once`(单条原子 INSERT...ON CONFLICT(command_id) DO NOTHING RETURNING →
  fresh/duplicate;写入事务内调用得 exactly-once;含 16 并发只 1 fresh 测试)。并入 PERS-5 清单。
  **至此分布式正确性三大 DB 线性化原语齐备**:durable fencing(WriteTokenStore)+ 线性化 epoch
  (RegionEpochStore)+ 命令幂等(CommandLog)。**剩余 1.5b**:把 record_once 接进权威命令写入事务
  (gate→scene→store 线程化 command_id),wire 后即关闭 AUTH-4 重复 prefab/编辑产重资产的洞。
- 2026-06-14:**step 1.3 epoch 线性化完成(CELL-18/23,消除 ANTI-32)**。新增 `voxel_region_epochs`
  表 + `RegionEpochStore.allocate_next`(单条原子 INSERT...ON CONFLICT...RETURNING,Postgres 行级
  序列化 = epoch 唯一线性化点;含 20 并发不重复测试)。MapLedger 的 issue_lease/begin_migration 改用
  该分配器(opts 显式 epoch 仍尊重 + set_floor 保单调)。**并发/重启的多 MapLedger 不再能分配冲突/
  回退的 owner_epoch**。两 fencing 持有者并入 PERS-5 清单。回归 world 126 / gate 196 / data 90 /
  scene 918 全绿。**D-3 头部(防双主 fencing + epoch 线性化)地基完成。** 剩余 1.5 command_id 幂等、
  1.6 entity_handoff、1.1 cell_tick。
- 2026-06-14:**step 1.2 WriteTokenStore → Postgres durable fencing 完成(CELL-19/21)**。
  token fence 从进程内存改 `voxel_write_tokens` 表(token_version CAS + advisory lock 线性化每
  region),消除"节点重启即空 → fencing 失效窗口"。保留空 GenServer 兼容垫片(零调用方/测试改动,
  仅 5 个 token-touching 测试改 async:false + 清表)。新增 durable fencing(重启存活)测试。
  回归 data 82 / scene 918 / world 126 / gate 196 全绿。**剩余 1.3 epoch 线性化(MapLedger DB 条件写,
  架构已核实可走注入式 Repo)、1.5 后半 command_id 幂等、1.6 entity_handoff、1.1 cell_tick。**
- 2026-06-14:**已落地(全绿)**:
  - **D-4 prefab/事务 commit durable-before-ack**(step 1.5 前半):`enqueue_snapshot_persist`
    改同步落库,成功才更新内存 + 真实 persist_result,失败 `{:error}` 内存不前进(消除内存/DB
    背离)。回归 scene 909 / world 123 / gate 196。
  - **异步 persist 子系统清理**:移除不可达的 async_persists/persist_waiters/相关 handler。
  - **PERS-5 scene_server 自声明**(梯队0 step0.5 续):8 持有者 `use StateClassed` + 一致性测试;
    PERS-5 跨 data+scene 覆盖完成。scene 918 / mmo_contracts 47 全绿。
  - **CELL-24 决策**:`lease_stale?` 用墙钟仅作 **liveness backstop**,安全已由 owner_epoch fencing
    保证(WriteTokenStore.validate_identity 校 owner_epoch,非时间)。过期自检单调化**并入 1.2/1.3
    lease/token 重设计**(lease 在 ChunkProcess 有 10+ 赋值点,集中在 token 重设计处理避免两次改
    lease 生命周期),不单独打补丁。
  - **待办**:1.1 cell_tick/sim_time(暂判惰性,待 handoff/snapshot 消费者就绪再做);
    1.2+1.3 跨节点 fencing 重设计(WriteTokenStore→Postgres + epoch 线性化,需先定 world 是否直写 Repo);
    1.5 后半 command_id 幂等;1.6 entity_handoff。
- 2026-06-14:决策稿落定 + 跨节点耦合发现补入。**修订排序**:step 1.2(WriteTokenStore 落库)与
  step 1.3(epoch 线性化)经核实为**跨节点 fencing 重设计**(token publish 走跨节点 GenServer,
  改 DB 需先定"DB 写在哪个节点发生"),应合并为一个谨慎设计单元。因此**首个代码步改为 step 1.1
  cell_tick/sim_time**(局部于 scene 权威单位、与跨节点 fencing 解耦、为 handoff_tick/migration_tick/
  snapshot_tick 打底)。1.2+1.3 合并设计稿待 step 1.1 后单独细化(需先确认 world_server 是否持
  DataService.Repo 直写权,还是经 DataService 入口做条件写)。
