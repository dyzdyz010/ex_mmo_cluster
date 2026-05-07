# Phase 3 — Prefab v2 事务化(World/Scene transaction coordinator 落地)

## 目标

把 `0x67 PrefabPlaceIntent` 从"Gate 端 cell-by-cell 单 chunk apply_intent 循环"改造为
真正经过 World 协调的两阶段提交:

- Gate 解析 prefab、按 chunk 分组 intents、构造 participants,委托给 `WorldServer.Voxel.TransactionCoordinator` + `TransactionExecutor`
- Scene 端 `BuildTransactionApplier` + `ChunkProcess.{prepare,commit,abort}_transaction` 已经具备的三相能力被真正驱动
- 任意一个 chunk prepare 失败 → 全部已 prepared 的 chunk 自动 abort,不留半提交
- TransactionCoordinator 用 Postgres 持久化(单一路径,删 file 路径)
- Coordinator 重启后,`:preparing` / `:aborting` 状态的事务被 RecoveryWatcher 自动 abort;`:prepared` 状态的事务"挂着"等下一次显式 `commit_decision`(本阶段不实现 auto-resume)

完成后,Phase 3 的客户端可见行为是:**部分失败的 prefab 不再产生半提交**。

## 不在范围内(显式归属)

- **prefab v3 高级特性**(rotation 全自由度、scale、anchor 多形态):留 Phase 5+。Phase 3 沿用现有 `PrefabRaster.rasterize/4` 的能力。
- **跨 region 跨 lease 事务**:participants list 只放单个 `{region_id, lease_id}`。BuildTransaction struct 已支持多 participant,但 0x67 dispatch 不构造跨 region 场景。语义(prefab 跨 region 边界路由?多 lease 协调?)需独立设计文档,留 Phase 3-bis。
- **Scene `pending_fence` 持久化**(D4):本阶段 fence 仍 in-memory,Scene 重启 fence 丢。
- **`:prepared` 事务 auto-resume commit**(D3):需要 intents_by_participant 也持久化,工作量大,留 Phase 3-bis。
- **跨进程 e2e harness**:Phase 2 决策稿已 park 到测试基建 backlog。
- **per-region coordinator / coordinator HA**:Phase 3 单全局 coordinator,多 region 跨 coordinator 协调留 Phase 6。

## 决策项(已定稿)

> 用户已确认 D1-D7 推荐值,直接按"未上线第一版"路径落定。后续偏离须在进度日志显式记录 RFC。

### D1:**0x67 PrefabPlaceIntent dispatch 切到走 World 事务**

Gate 收到 0x67 后:

1. 通过 `PrefabRaster.rasterize/4` 产出 cells
2. 按 chunk 分组 cells → `intents_by_chunk = %{ {x,y,z} => intent_attrs }`
3. 通过 `BeaconServer.Client.lookup/1` 找到 `WorldServer.Voxel.TransactionCoordinator`
4. 构造 single-participant `BuildTransaction`(D6 决定单 region 单 lease 多 chunk)
5. 调 `TransactionCoordinator.begin_transaction/2` + `TransactionExecutor.execute/4`
6. 根据返回 `decision`(`:commit` / `:abort`)+ 各 chunk 应用结果,回包 `voxel_prefab_result_ok` / `voxel_prefab_result_error`

替代被否:Gate 直接调 `BuildTransactionApplier` 不经 World coordinator。理由:违反"World 拥有事务账本"边界,跨 region 永远做不了。

### D2:**TransactionCoordinator 删除文件持久化路径,只保留 Postgres**

按"全新未上线不留兼容"纪律,删 `transaction_coordinator.ex` 中的:

- `:persistence_path` 启动选项
- `file_persist_fn/1`、`file_load_fn/1`、`validate_persisted_payload/1`(file 路径专用部分)

`WorldSup` 启动 Coordinator 时直接注入:

```elixir
{WorldServer.Voxel.TransactionCoordinator,
 name: WorldServer.Voxel.TransactionCoordinator,
 persist_fn: DataService.Voxel.TransactionCoordinatorStore.persist_fn(DataService.Repo),
 load_fn: DataService.Voxel.TransactionCoordinatorStore.load_fn(DataService.Repo)}
```

替代被否:保留双路径 opt 切换。理由:违反纪律,且 file 路径不再有真实使用场景。

### D3:**节点重启 in-flight 事务恢复策略**

Coordinator init 完成 load 后,扫描 `transactions` map:

- `:prepared` 状态(prepare 完了但还没 commit) → **不自动 dispatch commit**,只 emit `voxel_transaction_recovery_pending_commit` observe 事件提示运维 / Gate 重发。理由:执行 commit 需要 `intents_by_participant` payload,而该字段当前不在 coordinator state 里(只在 executor call args 里)。要 auto-dispatch 必须把 intents 也持久化,成本高,留 Phase 3-bis。
- `:preparing` / `:aborting` 状态 → 启动 `WorldServer.Voxel.TransactionRecoveryWatcher` GenServer,扫描这些事务,基于 `timeout_at_ms` 自动调 `TransactionCoordinator.abort_decision/3`,然后给所有 participants 发 abort(idempotent;Scene 端 fence 找不到就 no-op)。

替代被否:实现 auto-resume commit。推到 Phase 3-bis。

**接受的代价**:重启后 `:prepared` 事务会"挂着"直到运维介入或客户端重发触发 idempotent commit。可接受,因为重启是罕见事件。

### D4:**Scene `pending_fence` 不持久化**

`ChunkProcess.pending_fence` 仍是 in-memory state。理由:

- ChunkProcess hot truth(storage)本身也是 in-memory,重启后从 ChunkSnapshotStore reload,fence 一起丢是合理状态。
- 与 D3 配合:重启后 coordinator 收到的 `:prepared` 事务发 commit 时,如果 Scene fence 已无,ChunkProcess 返回 `:transaction_not_prepared`,coordinator 走部分失败路径(commit 失败 chunk + 已 commit chunk 混合,Phase 3 视为整体失败)。
- 进一步语义("如果 fence 丢就基于 staged intent 重 prepare + 立即 commit")推到 Phase 3-bis。

替代被否:fence 走 Postgres 新表 `voxel_chunk_pending_transactions`。推到 Phase 3-bis。

### D5:**Gate ↔ World 服务发现路径**

`WorldServer.Voxel.TransactionCoordinator` 启动时通过 `BeaconServer.Client.register/1` 注册自己(资源名 `:voxel_transaction_coordinator`)。Gate `ws_connection.ex` / `tcp_connection.ex` 在 dispatch 0x67 时通过 `BeaconServer.Client.lookup(:voxel_transaction_coordinator)` 拿到 pid,然后 `GenServer.call`(`begin_transaction`)+ 调 `TransactionExecutor.execute/4`。

接入模式与现有 `MapLedger` 走同一条 BeaconServer interface 路径。Phase 3 单全局 coordinator,per-region coordinator 留 Phase 6。

### D6:**Phase 3 第一刀只支持单 region 单 lease 多 chunk**

Gate 拼 participants 只放一个 entry:

```elixir
participants = [
  %{
    region_id: <从 lease 取>,
    lease_id: <从 lease 取>,
    owner_scene_instance_ref: <从 lease 取>,
    owner_epoch: <从 lease 取>,
    affected_chunks: <prefab 跨过的所有 chunk_coord 列表>
  }
]
```

跨 region 多 participant:BuildTransaction struct 已支持,但 0x67 dispatch 阶段不构造该场景。

替代被否:第一刀就支持跨 region。理由:跨 region prefab 的语义(prefab 跨 region 边界?MapLedger 怎么 route?多 lease 协调?)需独立设计文档。

### D7:**测试矩阵**

新增/扩展的 ExUnit 测试:

- `apps/gate_server/test/gate_server/worker/ws_connection_voxel_test.exs`(以及 tcp 对应):
  - 0x67 prefab two-phase commit 全成功 → ok 回包,所有 chunks 应用
  - 0x67 prefab 中某个 chunk prepare 失败 → 全 abort,无 chunk 应用,error 回包
  - 0x67 prefab 中某个 chunk fence 已被另一事务占用 → reject,error 回包
  - Coordinator 不可达(BeaconServer 没找到) → reject
  - executor 整体超时 → abort + error 回包
- `apps/world_server/test/world_server/voxel/transaction_coordinator_persistence_test.exs`:
  - 改成打 Postgres(从 file fixture 改 setup `Repo.delete_all(VoxelTransactionCoordinatorSnapshot)`)
  - 重启 reload + `:preparing` 状态被 RecoveryWatcher 自动 abort 用例
  - 重启 reload + `:prepared` 状态保留并 emit pending_commit observe 事件
- `apps/scene_server/test/scene_server/voxel/chunk_process_*_test.exs`:
  - `commit_transaction` 在 fence 已被释放时返回 `:transaction_not_prepared`
- 不补跨进程 e2e harness(Phase 2 决策稿已 park 到 backlog)。

## 高层步骤

| Step | 范围 | 验收信号 |
| --- | --- | --- |
| 3-1 | 删 TransactionCoordinator file persistence;接入 TransactionCoordinatorStore;`WorldSup` 注入 persist/load fn;`world_server` test_helper 启动 Repo + migrations | world_server / data_service / scene_server / gate_server 全绿;coordinator 重启 reload 来自 Postgres |
| 3-2 | TransactionRecoveryWatcher GenServer + 集成测试:重启后 `:preparing` / `:aborting` 自动 abort,`:prepared` emit pending_commit observe | 新建 transaction_recovery_watcher_test.exs;persistence test 加重启场景 |
| 3-3 | TransactionCoordinator interface(BeaconServer.Client register);Gate 0x67 dispatch 切到 TransactionExecutor;0x67 result codec 不变,只换内部链路 | gate ws/tcp 加 D7 全套用例;旧 partial-write 测试改写为"全 commit 或全 abort" |
| 3-4 | ChunkProcess.commit_transaction 在 fence 已被释放时返回 `:transaction_not_prepared`(强化现有行为 + 测试用例) | scene_server 加 commit-fence-already-released 用例 |
| 3-5 | docs 同步:`apps/scene_server/lib/scene_server/voxel/README.md`、`apps/world_server/lib/world_server/voxel/README.md`、协议设计文档(2026-04-29)对齐 v2 路径 | 文档与代码一致;README.md 阶段表 Phase 3 = 已完成 |

每个 Step 单独 commit。Elixir 改前 `mix format`。本阶段不动 web client(Gate 内部链路替换,wire 协议不变,客户端零感知)。

## 验收

- mix test 全 umbrella 全绿
- 0x67 prefab 部分失败时 chunks 状态全部回到 prepare 前,客户端收到 error 回包
- 0x67 prefab 全成功时所有 chunks 应用 + 客户端收到 ok 回包 + 后续 snapshot/delta 推送一致
- Coordinator 重启后 Postgres 中持久化的 transactions / decisions 被正确 load
- 重启后 `:preparing` / `:aborting` 事务被 RecoveryWatcher 自动 abort
- 重启后 `:prepared` 事务保留并 emit pending_commit observe 事件(运维可见)

## 风险

- **D3 的"不自动 resume commit" → 生产场景靠运维 / 客户端重发触发**。后续要在 ops runbook 加"Phase 3 后跑一次 prefab + Coordinator 重启演练"。
- **D4 的"fence 不持久化" → Scene 重启会让所有 pending transaction 报 commit 失败**。可接受,因为 Scene 重启意味着所有客户端要重订阅 / reload。
- **D5 的"全局单 coordinator"是潜在 SPOF**。Phase 3-bis 或 Phase 6 引入 per-region coordinator 时再处理。
- **3-3 涉及 Gate ↔ World 跨进程调用**,Windows 环境可能要确认 BeaconServer.Client lookup + GenServer.call 在测试环境正常工作(参考 1d test_helper 启动 Repo 模式)。
- **TransactionCoordinator GenServer 单点串行化** → 高 prefab QPS 下可能成为瓶颈。本阶段不优化,Phase 3-bis 视实测决定是否分片或异步化。

## 进度日志

- 2026-05-07: D1-D7 推荐值用户全部同意。决策稿入仓,准备开始 Step 3-1。
