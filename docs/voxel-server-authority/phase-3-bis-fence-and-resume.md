# Phase 3-bis — Fence persistence + auto-resume commit(crash safety 闭环)

## 背景

Phase 3 决策稿显式 park 了两条 backlog:

- **D3**:`:prepared` 事务 auto-resume commit。当时未做的根因是 commit dispatch 需要 `intents_by_participant` payload,而该字段当前不在 coordinator state 里(只在 executor call args 里),要 auto-dispatch 必须把 intents 也持久化。
- **D4**:Scene `pending_fence` 持久化。当时未做的根因是 fence 走 Postgres 新表代价大,Phase 3 验证可观察行为已经够用。

两条单独做都意义有限,合在一起才能闭环 crash safety:

| 场景 | Phase 3 当前行为 | Phase 3-bis 目标行为 |
| --- | --- | --- |
| coordinator 重启,Scene 没重启 | `:prepared` 事务挂起,emit observe,等运维重发 commit | RecoveryWatcher 自动 resume commit,客户端不感知 |
| Scene 重启,coordinator 没重启 | ChunkProcess fence 丢,后续 commit 返回 `:transaction_not_prepared` → 整体失败 | ChunkProcess init 从表 load fence,后续 commit 走通 |
| 双方都重启 | 同上两个 fail mode 叠加 | 两边 reload + Watcher resume 双管齐下,事务自动完成 |

本阶段把 Phase 3 留下的两条对偶 backlog 一次落定。

## 目标

- ChunkProcess `pending_fence` 写入新表 `voxel_chunk_pending_transactions`,prepare 同步写、commit/abort 同步删、init 时从表 load。
- `BuildTransaction` 加 `intents_by_participant` 字段,coordinator snapshot 持久化扩展承载它。
- `TransactionExecutor.execute/4` 加 `:prepared` fast-path,跳过 prepare 阶段直接进 commit dispatch。
- `TransactionRecoveryWatcher` 对 `:prepared` 事务从 coordinator snapshot 取出 intents,调 executor 重发 commit dispatch。
- 完成后,任意 crash 组合下 prefab 事务都能自然推进到终态(commit 或 abort),不再依赖运维介入或客户端重发。

## 不在范围内(显式归属)

- **跨 region 多 participant 事务**(Phase 3 D6 已 park):本阶段 `intents_by_participant` 在 wire 上仍只构造 single-participant 形态。多 participant 持久化形态本身已支持,但 Gate 的 prefab dispatch 不构造跨 region 场景。
- **per-region coordinator / coordinator HA**(Phase 6):本阶段仍单全局 coordinator。
- **紧凑 ChunkDelta**(Phase 3 backlog):resume commit 后仍走整 chunk snapshot fan-out,不在本阶段优化。
- **跨进程 e2e harness**(Phase 2 决策稿已 park):本阶段不补端到端 harness,继续靠 Postgres-backed unit/integration test。
- **fence 超时 sweeper**:`fenced_at_ms` 字段写入,但本阶段不实现"卡住超过 X 分钟的 fence 自动清理"。运维仍可手工 abort。
- **客户端任何改动**:wire 协议不变,bevy/web 零感知。

## 决策项(已定稿)

> 用户已确认 D1–D8 推荐值,直接按"未上线第一版"路径落定。后续偏离须在进度日志显式记录 RFC。

### D1:ChunkProcess pending_fence 持久化形态 — 新表 `voxel_chunk_pending_transactions`

新表 schema(列名/类型/约束风格对齐既有 `voxel_chunks`):

```sql
CREATE TABLE voxel_chunk_pending_transactions (
  logical_scene_id          BIGINT      NOT NULL,
  coord_x                   INTEGER     NOT NULL,
  coord_y                   INTEGER     NOT NULL,
  coord_z                   INTEGER     NOT NULL,
  transaction_id            BYTEA       NOT NULL,
  decision_version          INTEGER     NOT NULL,
  owner_region_id           BIGINT      NOT NULL,
  owner_lease_id            BIGINT      NOT NULL,
  owner_scene_instance_ref  BIGINT      NOT NULL,
  owner_epoch               BIGINT      NOT NULL,
  fence_payload             BYTEA       NOT NULL,
  fenced_at_ms              BIGINT      NOT NULL,
  inserted_at               TIMESTAMPTZ NOT NULL,
  updated_at                TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (logical_scene_id, coord_x, coord_y, coord_z)
)
```

- 复合主键 `(logical_scene_id, coord_x, coord_y, coord_z)` 沿用全系统现有 chunk 自然主键风格(wire 协议、`voxel_chunks` 表、ChunkDirectory 注册都用这个 4 元组)。**不引入** `chunk_id` 代理键 —— wire 协议无法用 id,引入只会带来"内部 id ↔ 外部 coord"两套定位的维护负担,无收益。
- `transaction_id BYTEA`:对齐 ChunkProcess 现有 binary transaction id 形态(`commit_transaction(server, transaction_id) when is_binary(transaction_id)` 已有 guard)。
- `decision_version`:coordinator 端 `BuildTransaction.decision_version`,重启 load 时帮助诊断 fence 属于哪个版本的事务。
- `owner_region_id` / `owner_lease_id` / `owner_scene_instance_ref` / `owner_epoch`:fence 创建时挂的 lease 信息全留。Scene 重启后 lease 可能换 epoch,load 时用这四个字段对一遍当前 ChunkProcess 的 lease,不一致就丢弃 + emit observe(D4)。
- `fence_payload`:序列化后的 intent batch,见 D8。
- `fenced_at_ms`:fence 创建时间(`System.system_time(:millisecond)`),给运维诊断 + 未来超时 sweeper hook。
- `inserted_at` / `updated_at`:Ecto 默认 `timestamps()`。

替代被否:
- **复用 `voxel_chunks` 表加列**(`pending_transaction_id` 等可空列)。否决:写入频率/语义不同(`voxel_chunks` 写 = 已 commit truth,fence 写 = in-flight intent),合表违反 SRP;commit 路径单行被双重写入语义"骑墙";`SELECT * FROM voxel_chunk_pending_transactions` 直接看到所有 in-flight fence,合表则要 `WHERE pending_transaction_id IS NOT NULL`,运维可读性下降。
- **引入 `chunk_id BIGSERIAL` 代理键**。否决:理由如上。

### D2:`intents_by_participant` 持久化位置 — coordinator 单行 snapshot 内嵌

`BuildTransaction` struct 加新字段:

```elixir
defstruct [
  :transaction_id,
  ...,
  :state,
  intents_by_participant: %{}  # 新字段
]
```

形态对齐 `TransactionExecutor.execute/4` 第三参数:

```elixir
%{
  {region_id, lease_id} => %{
    chunk_coord => [intent_attrs, ...]
  }
}
```

写入路径:`begin_transaction` attrs 接收 `intents_by_participant`(必传),写入 `BuildTransaction.intents_by_participant`,跟其它 transaction 字段一起进既有 `voxel_transaction_coordinator_snapshots` 单行 snapshot。`TransactionCoordinator.validate_persisted_payload/1` 的 `expected_keys` 不变(intents 内嵌在 transactions 内,不是顶层 key)。

`begin_fingerprint` **不**把 intents_by_participant 算进去。fingerprint 是"是否同一笔事务"的语义判定,与 intents 内容无关。同一 transaction_id + participants + decision_version 就是同笔事务;intents 重放冲突由 ChunkProcess 内部的 idempotent 路径处理。

替代被否:
- **独立表 `voxel_transaction_intents`**。否决:intents 与 transaction 1:1,共生命周期没必要拆表,加一张表只是多 schema/store/test 一遍。

### D3:fence 写入语义 — 必须成功

`ChunkProcess.prepare_transaction/3` 内部:

1. 现有 `validate_batch_scope` + `validate_batch_preconditions` 通过
2. **新增**:同步 INSERT row 到 `voxel_chunk_pending_transactions`
3. INSERT 成功 → 把 fence 装进 `state.pending_fence`,reply `{:ok, summary}`
4. INSERT 失败(连接断、唯一键冲突等)→ reply `{:error, :fence_persist_failed}`,**不**进 `state.pending_fence`

这样保证"DB 中 fence 行 == 进程内 pending_fence",不发散。

`commit_transaction` / `abort_transaction` 同理:同步 DELETE,失败 emit observe,但 in-memory fence 已释放(若 DB 残留 row,下次 init load 时会触发 D4 的"对不上当前 lease 就丢"路径,自然清理)。

替代被否:
- **best-effort 写入**(写失败仍 in-memory 接受)。否决:重启后 fence 状态发散。

### D4:fence load 时机与一致性

`ChunkProcess.init/1` 流程扩展:

1. 现有 storage load(从 `ChunkSnapshotStore`,Phase 1d)
2. **新增**:`SELECT * FROM voxel_chunk_pending_transactions WHERE (logical_scene_id, coord_x, coord_y, coord_z) = ?`
3. 有结果 → 校验 lease 一致性:
   - 如果 init opts 中带 lease,且 lease 的 `(region_id, lease_id, owner_scene_instance_ref, owner_epoch)` 与 row 的 owner_* 字段全部相等 → 把 fence 装进 `state.pending_fence`
   - 不一致(lease 已换 epoch / 已转给别的 Scene)→ 丢弃 + DELETE 该行 + emit `voxel_chunk_pending_transaction_orphaned` observe
   - init opts 中无 lease → 装进 `state.pending_fence` 但 `state.lease = nil`(等 `apply_lease/2` 注入,届时再做一次 lease 一致性校验,不一致就 abort fence)
4. 无结果 → `state.pending_fence = nil`,正常路径

**不**做 chunk_version 一致性校验。intents 内 `expected_chunk_version` / `expected_cell_hash` 在 commit 时自然走 `validate_batch_preconditions`,失败回 `:stale_*`,coordinator 端 D6 处理后续。

替代被否:
- **load 时校验 chunk_version 与 fence 内 expected 一致**。否决:重复校验,且 storage 在 fence 之后被另一 transaction 改动是 D6 接受的 edge case(commit 时 stale 失败 → 整体走 partial-commit 路径)。

### D5:`TransactionExecutor.execute/4` 加 `:prepared` fast-path

当前 executor 已经处理 `:committed` / `:aborted` 短路。加一个 `:prepared` 分支:

```elixir
case transaction.state do
  already_decided when already_decided in [:committed, :aborted] ->
    # 现有 replay 短路
    ...

  :prepared ->
    # 新增 fast-path:跳过 prepare phase,直接进 run_commit
    # prepare_results 从 transaction.participants 推导(prepare_status == :prepared 的视为成功)
    prepare_results = derive_prepare_results_from_prepared_state(transaction)
    run_commit(coordinator, transaction, prepare_results, scene_caller, scene_opts, commit_timeout, deadline)

  _ ->
    # 现有正常路径(:preparing / :aborting):跑 prepare phase
    ...
end
```

`derive_prepare_results_from_prepared_state/1` 把每个 `prepare_status == :prepared` 的 participant 包成 `{participant, {:ok, %{resumed?: true}}}`,`run_commit` 现有路径直接消费。

`intents_by_participant` 在 fast-path 不消费(commit phase 用不到 intents,fence 已持有),但仍然要传入,保持 API 形态一致。

替代被否:
- **Watcher 自写简化版 commit dispatch,不复用 executor**。否决:重复实现 + scene_caller 协议会漂移;executor 已是稳定的"一处" prepare/commit/abort 派发逻辑,加一个状态分支比再写一份小。

### D6:`TransactionRecoveryWatcher` 对 `:prepared` 的新行为

当前 Watcher 对 `:prepared` 只 emit `voxel_transaction_recovery_pending_commit`。本阶段改:

1. 从 coordinator snapshot 取出 transaction(含新字段 `intents_by_participant`)
2. 调 `TransactionExecutor.execute(coordinator, transaction, intents_by_participant, scene_opts: scene_opts)`
3. executor 走 D5 fast-path → run_commit → coordinator commit_decision → 终态 `:committed`
4. emit `voxel_transaction_recovery_resumed_commit`
5. 如果 commit dispatch 中某 ChunkProcess 返回 `:transaction_not_prepared` (fence 在 Scene 重启时丢且未持久化的 edge,正常路径下不该发生但保留兜底)→ executor 现有路径会在 `run_commit` 内将该 participant 标 `:error`,但 commit_decision 仍记 `:commit`(coordinator 已 prepared 不能反悔);Watcher emit `voxel_transaction_recovery_resume_partial` 给运维诊断
6. Watcher 处理完 `:prepared` 后行为不变(idle 等下次 sweep)

`scene_opts` 拼装:Watcher 需要拿到 `chunk_directory: {ChunkDirectory, scene_node}`。最直白做法是在 Watcher init opts 里接收 `:scene_opts_resolver`(0-arity fn,跑时返回 scene_opts),`WorldSup` 注入实际 resolver(从 BeaconServer 解析当前 scene_node)。

替代被否:
- **不传 scene_opts,让 Watcher 内部自己解析**。否决:与 `WorldServer.Voxel.MapLedger` 的 BeaconServer 注入风格不一致;且 resolver 注入更 testable。

### D7:测试矩阵

新增 / 扩展的 ExUnit 测试:

- `apps/data_service/test/data_service/voxel/chunk_pending_transaction_store_test.exs`(新建):
  - put / get / delete by `(logical_scene_id, coord_x, coord_y, coord_z)`
  - 唯一键冲突时 INSERT 报错
  - 跨 chunk 多行隔离

- `apps/scene_server/test/scene_server/voxel/chunk_process_persistence_test.exs`(新建):
  - prepare → DB 中有行 + state.pending_fence 已设
  - commit → DB 行删除 + state.pending_fence 清空
  - abort → DB 行删除 + state.pending_fence 清空
  - 模拟"prepare 后进程重启"(创建新 ChunkProcess + 加上既有 lease)→ init load fence + 后续 commit 走通
  - "prepare 后 lease 换 epoch"→ load 时丢弃孤儿 fence + emit observe
  - "DB INSERT 失败"(注入 fault)→ prepare 返回 `:fence_persist_failed`,state.pending_fence 仍为 nil

- `apps/world_server/test/world_server/voxel/transaction_coordinator_persistence_test.exs`(扩展):
  - `BuildTransaction.intents_by_participant` 写入 + reload 后字段保留
  - `:prepared` 状态 + intents_by_participant 持久化往返完整

- `apps/world_server/test/world_server/voxel/transaction_executor_test.exs`(扩展):
  - `:prepared` fast-path:跳过 prepare phase 直接 commit,participant_results 标记 `resumed?: true`
  - fast-path 中某 chunk commit dispatch 失败,coordinator 仍记 `:commit`(已 prepared 不可反悔),participant_results 显示部分失败

- `apps/world_server/test/world_server/voxel/transaction_recovery_watcher_test.exs`(扩展):
  - 重启后 `:prepared` 事务自动 resume commit + emit `voxel_transaction_recovery_resumed_commit`
  - resume commit 中部分 chunk 失败 → emit `voxel_transaction_recovery_resume_partial`
  - resume commit 调用前 `intents_by_participant` 从 snapshot 取出(用 Mock 验证 executor 收到的参数)

- 端到端 Postgres(扩展 `transaction_coordinator_persistence_test`):
  - prepare 完成 → 模拟 coordinator 重启(stop + start) → Watcher init 自动 resume → 所有 chunk 应用 + 终态 `:committed`

不补跨进程 e2e harness。

### D8:`fence_payload` 编码 — `:erlang.term_to_binary/1`

intents list 内含 lease map / atom operation key / micro_layer map 等,自定义二进制 codec 写一遍跟 wire 协议没共用价值,**用 `:erlang.term_to_binary/1`** 落地 + `:erlang.binary_to_term/1` 反序列化。这只是 server-side blob,不上 wire,不跨语言。

读出后用 `binary_to_term(blob, [:safe])` 防止反序列化出未知 atom 导致 atom 表膨胀(intents 内的 atom 都是已知集合 `[:put_solid_block, :break_block, :put_micro_block, :clear_micro_block]` 等,Scene 启动时已 load,`:safe` 模式下从已知 atom 解析 OK)。

替代被否:
- **写自定义 codec**。否决:见上。
- **JSON 编码**。否决:atom 序列化要转字符串再转回,容易出错;且 lease 等结构有 keyword 性质,JSON 表达不直观。

## 高层步骤

每个 Step 单独 commit。Elixir 改前 `mix format`。本阶段不动 web client / bevy client。

| Step | 范围 | 验收信号 |
| --- | --- | --- |
| 3-bis-1 | 新 schema `DataService.Schema.VoxelChunkPendingTransaction` + migration `voxel_chunk_pending_transactions` + `DataService.Voxel.ChunkPendingTransactionStore`(stateless module:`put_fence/1`、`get_fence/2`、`delete_fence/2`、`reset/0` test hatch)+ `chunk_pending_transaction_store_test` | data_service 全绿;新表迁移幂等(up/down 跑一遍) |
| 3-bis-2 | ChunkProcess 接入 store:prepare 写、commit/abort 删、init load + lease 一致性校验。`fence_payload` 用 `term_to_binary` 编码 intent batch。新建 `chunk_process_persistence_test`(含 lease orphan / DB fault 场景) | scene_server 268 → 280+ tests;原有 `chunk_process_*_test` 不退化 |
| 3-bis-3 | `BuildTransaction` 加 `intents_by_participant` 字段;`TransactionCoordinator.begin_transaction` attrs 收下 intents 写入 transaction;`TransactionCoordinator.snapshot` 经路径已含字段;persistence reload 验证 | world_server `transaction_coordinator_persistence_test` 扩展用例全绿 |
| 3-bis-4 | `TransactionExecutor.execute/4` 加 `:prepared` fast-path;`derive_prepare_results_from_prepared_state/1`;commit 失败时仍记 `:commit` | `transaction_executor_test` 扩展用例全绿 |
| 3-bis-5 | `TransactionRecoveryWatcher` 对 `:prepared` 改走 executor resume;`scene_opts_resolver` 注入;`WorldSup` 注入实际 resolver | `transaction_recovery_watcher_test` 扩展用例全绿;端到端"coordinator 重启后 :prepared 自动 commit" Postgres 用例全绿 |
| 3-bis-6 | docs 同步:`apps/scene_server/lib/scene_server/voxel/README.md`、`apps/world_server/lib/world_server/voxel/README.md`、`docs/voxel-server-authority/README.md`、协议设计文档 §11(若涉及新表)。决策稿进度日志补每 step 实施期 RFC | 文档与代码一致;`docs/voxel-server-authority/README.md` 阶段表 Phase 3-bis = 已完成 |

## 验收

- mix test 全 umbrella 全绿(预存失败 `authority_observe_test.exs:35` Windows 大小写不算回归)
- prepare 后任意时刻杀掉 coordinator → Watcher 自动 resume commit → 所有 chunks 应用 + coordinator 终态 `:committed`
- prepare 后任意时刻杀掉 ChunkProcess → 重建后 init load fence → 后续 commit 走通
- prepare 后 lease 换 epoch → ChunkProcess init 丢弃孤儿 fence + emit observe
- DB INSERT 失败时 prepare 返回 `:fence_persist_failed`,in-memory 状态干净
- `intents_by_participant` 在 coordinator snapshot reload 后字段完整保留

## 风险

- **`fence_payload` 用 `term_to_binary` 是 server-side blob,但仍受 BEAM term 大小限制**。一个 chunk 内最大 intent batch 估算:64×64×64 macro = 262144 个,假设每个 intent attrs ~200 bytes,极端情况 ~50MB。实际 prefab 单 chunk batch 远小于此(典型 10–100 intent),不会撞墙;但极端用例需要监控。Phase 5+ 若引入大体量 prefab 再评估编码方案。
- **`binary_to_term(blob, [:safe])` 可能因 atom 表未热而 reject**。Scene 启动到 ChunkProcess.init 之间所有 atom 应已被加载(intents 模块、storage 模块都先于 ChunkProcess 启动)。本阶段加单元测试覆盖 `:safe` 反序列化路径,如反复出问题再考虑切 `:unsafe` + 显式 atom 白名单。
- **`scene_opts_resolver` 在 Watcher init 时调用,如果 BeaconServer 还没就绪会 reject**。Watcher 已经在 `WorldSup` children 列表 coordinator 之后,但 BeaconServer 在另一个 supervision tree;启动顺序若有 race,resume 会失败。本阶段 resolver 实现要带"BeaconServer 暂未就绪 → 推迟到第一次 sweep,emit observe"的兜底,后续 sweep 会自然补救。
- **`:prepared` fast-path 中 commit dispatch 部分失败时仍记 `:commit`,这与 Phase 3 D6 推荐路径一致**(已 prepared 不能反悔)。运维需要意识到"事务终态 `:committed` 不代表所有 chunks 都应用了",partial 信号要看 `voxel_transaction_recovery_resume_partial` observe。
- **`fenced_at_ms` 没有超时 sweeper**,极端情况(coordinator 持续不可达 + Scene 持续不重启)fence 可能"卡住"。本阶段不加,运维仍可手工 abort。

## 进度日志

- 2026-05-08: 决策稿入仓(本 commit)。D1–D8 推荐值用户已确认,准备开始 Step 3-bis-1。
