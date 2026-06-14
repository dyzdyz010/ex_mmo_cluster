# 对齐迁移 · 梯队 1 · step 1.5b:command_id 跨层线程化(AUTH-4 / SEC-4)

> 上层:[`phase-align-1-distributed-correctness.md`](./phase-align-1-distributed-correctness.md)(D1-5)
> 规范依据:AUTH-4(命令幂等)、SEC-4(replay protection)、AUTH-2(durable-before-ack)。
> 前置:step 1.5a `voxel_command_log` 表 + `CommandLog.record_once/3`(单条原子 INSERT...ON CONFLICT)已落地,
> 但**仅被测试调用,未接真实写入路径**。本步把它接进权威命令写入。
> 纪律:逐子步 commit(`mix format` + 相关回归)→ 进度日志 → 不 push → 不留兼容。

## 目标

把 `command_id` 沿 **gate → scene → store** 线程化,在权威命令的 **durable 写入事务内** 调用 `record_once`,
关闭 AUTH-4 的"客户端重放产生重复 durable 副作用(重复方块/重复 prefab 重资产)"的洞。

## 现状锚点(2026-06-14 三路源码审计)

- **wire 字段**:`VoxelEditIntent`(0x70)/`PrefabPlaceIntent`(0x67) 均携带 `request_id`(u64)+
  `client_intent_seq`(u32)+`logical_scene_id`(u64),**无 command_id、无 actor_id**。
- **actor_id**:`cid`,在 `EnterScene` 后绑定到 gate 连接 `state.cid`,wire 不携带(连接隐式)。
- **单方块编辑 durable 写**:`ChunkProcess.apply_normalized_intent` → `persist_snapshot` →
  `ChunkSnapshotStore.put_snapshot` → `run_put_transaction` → **`Repo.transaction(fn -> do_put end)`**
  (advisory_lock + FOR UPDATE + chunk_version CAS)。**这是一个可注入额外 SQL 的显式事务。**
- **prefab durable 写**:`object_id` 在 **gate 预分配**(`SceneObjectStore.next_object_id`),
  `transaction_id` 由 `unique_prefab_transaction_id` 用 `System.unique_integer` 生成(**非确定性**)。
  三条路径:(a) single-chunk fast-path、(b) same-owner fast-path、(c) 全 World 事务。
  World 协调器 `begin_transaction` 已有 `transaction_id` replay 保护(replay 跳过 object 分配、
  scene_objects 不入 fingerprint),**但只对"同 transaction_id 重投"有效**(恢复 watcher 用),
  对"客户端重试(新 transaction_id)"无效;**fast-path 完全无重放保护**。
  → prefab 客户端重试 = 新 transaction_id + 新 object_id = **重复 scene_object 行**(SceneObjectStore
  以 object_id 为 conflict_target,新 object_id 即新行)。**这是 AUTH-4 真正的洞。**
- **单方块 vs prefab 的关键不对称**:单方块只 toggle 体素(chunk_version CAS 天然幂等,
  重复写同内容 → `:unchanged`,无重资产);prefab 分配 object_id(序列),重放产真重复资产。

## 关键决策(每项给推荐值)

### D1.5b-1 command_id 派生(不改 wire)
**推荐**:gate 侧派生稳定字符串 `command_id = "<kind>:<logical_scene_id>:<cid>:<client_intent_seq>"`,
`kind ∈ {"edit","prefab"}`。理由:满足 D1-5 "以 (actor_id, client_intent_seq) 派生",零 wire 改动,
满足"字段只追加"纪律。**客户端契约**:同一逻辑意图的重试必须复用同 `client_intent_seq`(这是 seq 的
本义);若现客户端在重试时自增 seq,则去重不触发——属客户端跟进项,服务端机制按 command_id 去重不变。

### D1.5b-2 单方块编辑:do_put 同事务 record_once(exactly-once)
**推荐**:`put_snapshot` 接受可选 `command_id`;`do_put` 内(advisory_lock 之后)若 `command_id` 非空
则 `CommandLog.record_once(command_id, scene, repo: repo)`(**同一 Repo.transaction**)。
体素 truth 由 chunk_version CAS 天然幂等,故 `:duplicate` 时 CAS 写仍安全(同内容 → `:unchanged`);
`record_once` 提供 durable AUTH-4 登记 + 审计。`command_id` **仅** 从单方块 apply_intent 路径透传;
**prefab 的 commit_transaction 逐 chunk 写不传 command_id**(否则多 chunk 同 command_id 撞 duplicate),
prefab 幂等由 D1.5b-3 在 gate 边界单独处理。两机制清晰分离。

### D1.5b-3 prefab:幂等键(idempotency key)pending→committed + 结果映射
**推荐**:在 gate **分配 object_id 之前**用 command_id 做幂等键,覆盖全部三条 prefab 路径:
- `CommandLog` 扩展为幂等键语义(加 `status` ∈ {pending,committed} + `result` 结果摘要列):
  1. `claim/2`:`INSERT (command_id, status='pending') ON CONFLICT DO NOTHING RETURNING`。
     - 插入成功 → `:fresh`,继续(分配 object_id、跑 prefab)。
     - 冲突 → `SELECT`:`committed` → `{:duplicate, result}`(返回缓存 object_id/outcome,幂等 ack);
       `pending` → `{:in_flight}`(同连接顺序处理通常不会撞;视为崩溃残留,返回可重试错误/超时回收)。
  2. 成功 commit 后 `confirm/3`:`UPDATE status='committed', result=<object_id+摘要>`。
  3. 失败 `release/2`:`DELETE`(失败命令不堵塞真实重试 → exactly-once,非 at-most-once)。
- `result` 存 owner_object_id + cell/chunk 计数摘要,供 duplicate 返回等价成功响应。

> 为何不用"确定性 transaction_id + 协调器 replay":fast-path 绕过协调器、object_id 在 gate 预分配,
> 仅靠协调器 replay 无法覆盖;idempotency-key 与路由无关、是教科书正确形态,符合"不留兼容/不补丁"。

### D1.5b-4 damage / combat 命令幂等
**不在本步范围**。damage 经 `VoxelDamageRouter` 由 combat cast 派生,非客户端直接体素命令;
combat cast 的 command_id 归 **梯队3 "cast 带 command_id"** 处理。本步只覆盖客户端发起的
体素写命令(edit + prefab)。

## Step 列表(逐子步、每步全绿可回归)

- **1.5b-1** 单方块编辑 command_id 端到端:gate 派生 → apply_intent attrs → ChunkProcess →
  persist_snapshot → put_snapshot → `do_put` 同事务 `record_once`。新增重放幂等测试。
  回归 data_service + scene + gate。
- **1.5b-2** prefab 幂等键:`voxel_command_log` 加 `status`/`result` 列(migration);`CommandLog`
  加 `claim/confirm/release`;gate 三条 prefab 路径在分配 object_id 前 claim、成功后 confirm、
  失败 release;duplicate 返回缓存成功。新增 prefab 重放不产重复 object 测试。回归 gate + scene + world。

## 测试矩阵

- `mix format` + `mix compile`(0 warning)。
- data_service:`record_once`/`claim`/`confirm`/`release` 并发与重放(已有 16 并发 fresh 测试基础上加状态机)。
- scene/gate:单方块重复 command_id 不二次副作用、ack 晚于 durable;prefab 重试不产重复 scene_object。
- 已知预存失败 `world_server/.../authority_observe_test.exs:35`(Windows path)不动。

## 验收

- 客户端发起的体素写命令(edit/prefab)重复 command_id 不产生重复 durable 副作用(AUTH-4)。
- 幂等登记与世界写入同事务(单方块)或 pending→committed-with-result(prefab),失败可重试(exactly-once)。
- ack 晚于 durable commit(AUTH-2 不回退)。
- 全量相关回归 0 净回归。

## 进度日志(时间倒序)

- 2026-06-14:**step 1.5b-1(单方块编辑 command_id 端到端)完成**。链路:gate
  `GateServer.VoxelCommandId.edit(scene, cid, client_intent_seq)` 派生(新模块,不改 wire)→
  `build_voxel_edit_intent_attrs` 注入(ws+tcp)→ ChunkProcess `normalize_apply_intent` 提取进
  intent → `apply_normalized_intent` 透传 `persist_snapshot/5` → `build_snapshot_attrs/5` 写入
  attrs → `ChunkSnapshotStore.do_put` **仅在写入成功(insert/update/unchanged)后于同一
  Repo.transaction 内** `CommandLog.record_once`(失败不登记 → exactly-once)。事务逐 chunk 写、
  手动 :persist、refresh 等内部写 command_id=nil 跳过登记。新增 4 测试(成功登记/重复只一行/
  stale 不登记/缺省跳过)。回归 data_service 99+1doctest、gate 196、scene 隔离 ChunkProcessTest
  46 全绿;scene 全量 918 的 7~8 个 observe-log flaky 经 stash 同 seed 基线对比确认为预存(基线 8、
  本步 7),0 净回归。**剩余 1.5b-2 prefab 幂等键。**

- 2026-06-14:决策稿落定。三路源码审计确认:单方块走 `ChunkSnapshotStore.do_put` 显式事务可同事务
  record_once;prefab object_id gate 预分配 + 非确定性 transaction_id + fast-path 绕协调器 = AUTH-4 真洞,
  用 idempotency-key(pending→committed)闭合。拆 1.5b-1(单方块)/1.5b-2(prefab)两子步。
