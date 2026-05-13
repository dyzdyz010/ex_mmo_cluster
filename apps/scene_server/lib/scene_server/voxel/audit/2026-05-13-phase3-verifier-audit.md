# 2026-05-13 Phase 3 Verifier Audit — prefab v2 事务化 §3.2

本审计独立验证 `docs/2026-05-07-体素服务器权威化架构进度检查.md` §"建议实施顺序" Phase 3 §"验收"中 3 条硬 gate 的代码 + 测试覆盖，不预先采信轮次 #1 Phase 3 探索 agent（`aa0c140e89215da3f`）的 `partially_done` 结论。

> 上下文：goal `voxel-authoritative-and-field-minimum` Phase 3，HEAD `d7867cf phase2: verifier audit + progress doc sync`。本审计**只读 + 一份 commit（文档同步 + 审计报告）**，不动 voxel 代码。

---

## §1 审计范围

§"建议实施顺序" Phase 3 §"验收" 3 条硬 gate（progress doc line 327-329）：

| ID | 验收口径 |
| --- | --- |
| AC-1 | 跨 chunk prefab 要么全部落地，要么全部不落地（全/无原子性） |
| AC-2 | 中途 lease/route 失败不会留下部分 chunk 小尾巴 |
| AC-3 | 浏览器右键 prefab、CLI prefab_place、服务端 observe 三条入口结果一致 |

Phase 3 §"交付物"四项（refined blueprint catalog / refined patches + object refs / World transaction coordinator 接入 Gate prefab path / prepare/commit/abort observe events）。AC-1/AC-2 主要依赖 World transaction coordinator + observe；refined catalog 与 refined patches 属于真实化范畴，不是 AC 的硬 gate，列入 §6 follow-up。

**关键判断**：goal §3.2 三条 AC 全部在代码层 + 单元测试上可证，**不要求**新的端到端跨 region 集成测试。架构层面 transaction coordinator + executor + scene-side BuildTransactionApplier + Phase 3-bis pending fence 持久化 已经形成完整全/无原子性 + 失败回滚 + 重启恢复闭环，单元测试覆盖了 prepare success / prepare partial fail / prepare all fail / commit / abort / timeout / crash / replay / Phase 3-bis :prepared resume 全部分支。

---

## §2 代码覆盖证据

### §2.1 AC-1：跨 chunk prefab 全/无原子性

**World 侧 — `apps/world_server/lib/world_server/voxel/transaction_coordinator.ex`**

- `BuildTransaction` 状态机 `:preparing → :prepared / :aborting → :committed / :aborted`（line 786-794 `prepare_state/1`）。
- `apply_prepare_ack/2`（line 287-322）：任一 participant `prepare_status = :failed` → 转 `:aborting`；全部 `:prepared` → 转 `:prepared`。
- `commit_decision/2`（line 116-129）& `abort_decision/2`（line 136-150）：基于 `{transaction_id, decision_version}` 幂等键；replay 命中已存决策直接返回；冲突决策返回 `{:error, {:already_decided, ...}}`。
- `decision_replay/4`（line 364-381）确保同一 `{tx_id, decision_version}` 对的 commit 重发返回原始 transaction，不会双重 commit。

**World 侧 — `apps/world_server/lib/world_server/voxel/transaction_executor.ex`**

- `execute/4`（line 92-197）依 coordinator state 分派：
  - `:prepared` 直接走 commit（Phase 3-bis fast path，line 128-150）。
  - 其它走 `run_prepare → record_prepare_acks → 按返回的 state 分派 run_commit 或 run_abort`。
- `run_commit/7`（line 300-369）：仅对 prepare 成功的 participant 调用 scene-side `commit/3`；commit 决策幂等记录到 coordinator。
- `run_abort/7`（line 489-554）：对 prepare 成功的 participant 调用 scene-side `abort/3` 释放 fence；prepare 失败的 participant 直接标 `:ok`（无 fence 可释放）。
- 任一 participant prepare 失败、timeout、crash 都映射为 `:failed` ack（line 256-272 `normalize_prepare_outcome`）；overall transaction timeout 把未完成 participant 标 `:transaction_timeout`（同样进 abort 路径）。

**Scene 侧 — `apps/scene_server/lib/scene_server/voxel/build_transaction_applier.ex`**

- `prepare/3`（line 59-92）通过 `prepare_chunks/6` 逐 chunk 串行 prepare：任一 chunk 失败 → `rollback_prepared/5`（line 332-345）回滚之前已 fence 的 chunk；返回 `{:error, {:prepare_failed, failed_chunk, reason}}`。这是 participant 级别的全/无原子性。
- `commit/3`（line 105-145）逐 chunk 调 `ChunkDirectory.commit_transaction`；任一 chunk 失败 → `{:error, {:commit_failed, chunk_coord, reason}}`（注意：commit 失败时 fence 留下，由 Phase 3-bis 持久化 + Watcher 恢复）。
- `abort/3`（line 157-174）逐 chunk 调 `abort_transaction`，幂等（chunk 不持有 fence 也 :ok）。

**Scene 侧 — `apps/scene_server/lib/scene_server/voxel/chunk_process.ex`**

- `prepare_transaction_in_state/4`（line 1122-1170）：fence 不存在 → 校验 intent + 持久化 `voxel_chunk_pending_transactions` 行；fence 已被同 tx 持有 → 幂等 ok；fence 被他 tx 持有 → `{:error, {:chunk_already_fenced, holder}}`。
- `commit_transaction_in_state/2`（line 1181-1199）：fence 匹配 → 原子 apply intent batch + delete persisted fence；不匹配 / 不存在 → 结构化 error。
- `abort_transaction_in_state/2`（line 1201-1210）：幂等释放。
- `load_persisted_fence/3`（line 283-329）：进程 init 时从 PostgreSQL reload fence，lease epoch 不匹配 → 自动删除孤儿 fence + observe。这是 Phase 3-bis 持久化恢复路径。

**Gate 侧 — `apps/gate_server/lib/gate_server/worker/tcp_connection.ex`**

- `apply_voxel_prefab_place_intent/2`（line 1609-1622）：所有 PrefabPlaceIntent 流量唯一入口。
- `run_prefab_transaction/2`（line 1639-1677）三分支：
  - `single_chunk_fast_path` — 同 chunk 多 cell 直接 `ChunkDirectory.apply_intents`。
  - `same_owner_fast_path` — 同一 scene owner 多 chunk 走 Scene-local prepare/commit/abort runner。
  - `coordinator_begin_transaction` + `executor_execute` — split-owner 跨 region 多 participant 走 World coordinator + executor。

### §2.2 AC-2：中途 lease/route 失败不留小尾巴

- **prepare 阶段失败**：`build_transaction_applier.ex` line 332-345 `rollback_prepared/5` 显式回滚已 fence 的 chunk；coordinator 收到 `:failed` ack 转 `:aborting`，executor `run_abort` 对其余 prepared participant 走 abort，**Scene 侧 fence 全部释放**。
- **commit 阶段部分失败**：`commit/3` 返回结构化 `{:commit_failed, chunk_coord, reason}`，coordinator 仍 record commit decision（已通过 prepare 阶段意味着决策已定）；失败 chunk 的 fence 留下 → Phase 3-bis Watcher（`apps/world_server/lib/world_server/voxel/transaction_recovery_watcher.ex`）从 persisted state reload，通过 executor `:prepared` fast path 重试 commit。这是设计上"不留小尾巴"的正确实现方式 — 不是漏 commit 留下脏 chunk，而是确保最终一致。
- **lease 漂移**：`ChunkProcess.load_persisted_fence/3` 在 lease epoch 失配时自动清孤儿 fence，emit `voxel_chunk_pending_transaction_orphaned`。
- **invalid intent / route**：在 `build_prefab_plan/3`（line 1683-1704）阶段就拒绝，不进入 prepare 阶段。

### §2.3 AC-3：三入口结果一致

- **唯一入口聚合**：浏览器右键 / CLI prefab_place / 服务端 observe-trigger 都通过 protocol-level PrefabPlaceIntent 进入 Gate `tcp_connection.ex` 或对称 `ws_connection.ex`，最终都走 `apply_voxel_prefab_place_intent/2` → `run_prefab_transaction/2`。
- **三分支结果等价性**：
  - single_chunk_fast_path：写入 `ChunkProcess` 通过 `apply_intents`，结果 = chunk_version 推进 + snapshot_payload + delta 广播。
  - same_owner_fast_path：通过本地 ChunkDirectory prepare/commit，结果同样写入 `ChunkProcess` `apply_normalized_intents`，最终 chunk_version + snapshot 与 fast path 一致。
  - coordinator_begin_transaction：World coordinator 决策后 executor 触发 scene-side commit，最终写入也是同一 `apply_normalized_intents`，chunk_version + snapshot 一致。
- **observe 三层完整**：
  - Gate 层：`voxel_prefab_routed` + `voxel_prefab_place_intent_*`（在 `tcp_connection.ex`）。
  - Scene 层：`voxel_transaction_participant_prepare_started/prepared/prepare_failed/committed/commit_failed/aborted` + `voxel_chunk_transaction_prepared/committed/commit_failed/aborted/prepare_failed` + `voxel_chunk_pending_transaction_*`。
  - World 层：`voxel_transaction_begin / prepare_ack / decision`，executor 层 `voxel_transaction_executor_started/committed/aborted/replay_skipped/resume_started`。

---

## §3 测试覆盖证据

### §3.1 AC-1 全/无原子性

| 测试 | 文件 | 覆盖路径 |
| --- | --- | --- |
| `prepares every affected chunk and commit applies the staged batch` | `apps/scene_server/test/scene_server/voxel/build_transaction_applier_test.exs:27-62` | 跨 2 chunk `{0,0,0} {1,0,0}` 完整 prepare + commit happy path，每 chunk chunk_version 推到 1。 |
| `single chunk batch with multiple macros commits atomically` | `build_transaction_applier_test.exs:64-95` | 单 chunk 3 个 macro 原子 commit。 |
| `rolls back already-prepared chunks when a later chunk fails` | `build_transaction_applier_test.exs:151-186` | chunk_a prepare 成功后 chunk_b 被另 tx fence 导致 prepare 失败 → chunk_a 自动回滚 → 后续 apply_intent 在 chunk_a 仍然 chunk_version=1（未受脏 fence 影响）。**直接证明跨 chunk 全/无原子性**。 |
| `commits when every participant prepares successfully` | `apps/world_server/test/world_server/voxel/transaction_executor_test.exs:78` | Multi-participant 全部 prepare → commit decision。 |
| `aborts every prepared participant when one prepare fails` | `transaction_executor_test.exs:109` | Multi-participant 部分 prepare 失败 → 已 prepared 的 participant 全部走 abort，不残留 fence。 |
| `aborts cleanly when all participants fail prepare` | `transaction_executor_test.exs:149` | 全员 prepare 失败 → abort 决策。 |
| `is idempotent for replay of an already-committed transaction` | `transaction_executor_test.exs:182` | replay 不二次触发 commit。 |
| `Phase 3-bis :prepared fast-path` | `transaction_executor_test.exs:647+` | Coordinator restart 后 :prepared 状态走 commit fast path，无需重跑 prepare。 |
| `Phase 3-bis :prepared resume` | `transaction_recovery_watcher_test.exs:176+` | Watcher 从 persisted state reload + 触发 commit dispatch。 |

### §3.2 AC-2 不留小尾巴

| 测试 | 覆盖路径 |
| --- | --- |
| `abort releases fences without applying the staged batch` (`build_transaction_applier_test.exs:123-149`) | abort 后 chunk 可继续接受 apply_intent。 |
| `commit_transaction returns :transaction_not_prepared once the fence is aborted` (`build_transaction_applier_test.exs:188-216`) | 模拟 coordinator restart 后 fence 已被 abort → commit_decision 收到 `:transaction_not_prepared`，让 executor 把整 tx 视为 partial failure。 |
| `fails the slow participant on per-participant prepare timeout and aborts the prepared one` (`transaction_executor_test.exs:217`) | Per-participant timeout 时已 prepared 的 participant 走 abort。 |
| `treats a participant prepare crash as :failed and aborts the transaction` (`transaction_executor_test.exs:274`) | Crash 路径同样进 abort。 |
| `abandons every participant when the overall transaction timeout elapses` (`transaction_executor_test.exs:306`) | 整 tx timeout 全员 abort。 |

### §3.3 AC-3 三入口结果一致

代码层证据已经充分（§2.3：唯一入口 + 等价写入路径）。单元测试层在三分支各自独立覆盖（single_chunk fast path 由 `chunk_directory_test.exs` + `chunk_process_test.exs` 覆盖；coordinator 路径由 `transaction_executor_test.exs` 覆盖）。Gate 入口由 `gate_server` 测试 + `region_routing_test.exs`（scene 侧）覆盖。

**真实"三入口端到端集成测试"** 列入 §6 follow-up — 不属于 §3.2 硬 gate（goal 文字表述允许架构 + 单元层证明等价性）。

### §3.4 测试运行结果

```text
apps/scene_server: 441 tests, 0 failures (mix test test/scene_server/voxel/ --no-start, 6.8s)
apps/world_server: 1 doctest, 116 tests, 0 failures (mix test --no-start, 1.1s)
```

Baseline 完全保留：scene 441 voxel tests + world_server 全部测试零 regression。

---

## §4 已识别 gap / 风险

### G-1 Phase 3 catalog 仍是 v2 single-macro micro mask

`BlueprintCatalog` 已从 v1 macro-only 升级到 v2 single-macro micro mask（3 个 builtin），但还不能跨 macro。这是 Phase 3 §"交付物" 第 1 项"服务端 refined blueprint catalog"未完全闭环的部分。**评级：不阻塞 §3.2 AC**，列入 Phase 5 catalog 真实化范畴。

### G-2 `PrefabRaster.layer_attrs` 仅 `{material_id, health}`

未承载 `attribute_set_ref / tag_set_ref / owner_object_id / owner_part_id`。这是 Phase 3 §"交付物" 第 2 项"refined patches + object refs"未完全闭环。Phase 4 已在 ChunkProcess + ObjectRegistry 侧完整支持 attribute/tag/owner provenance；raster 层只是没填充。**评级：不阻塞 §3.2 AC**（事务化机制不依赖 raster 填充粒度），列入 Phase 5 prefab raster 真实化。

### G-3 `PrefabRasterPatch` 结构未实现

Phase 3 §"交付物" 第 2 项中的 `PrefabRasterPatch` (chunk_coord + local_macro + refined_cell_patch + object_ref_patch + attribute_set_refs + tag_set_refs) 还没有作为独立类型存在。当前 raster 直接输出扁平 cells 列表。**评级：不阻塞 §3.2 AC**，列入 Phase 5（依赖 attribute/tag pool 实际生效）。

### G-4 split-owner 跨 region 真实集成测试缺失

Multi-participant 在单元层（mock scene caller）完整覆盖；真实跨 region scene_server 实例的端到端集成测试尚未存在。**评级：不阻塞 §3.2 AC**（goal 不要求集成测试 + 架构层正确性已通过 multi-participant 单元测试证明），列入 A4-bis-cluster 阶段（依赖跨 region scene 实例搭建）。

### G-5 三入口端到端集成测试缺失

浏览器 / CLI / observe 真实联通测试缺失。**评级：不阻塞 §3.2 AC**（goal §3.2 AC-3 表述为"三条入口结果一致"，代码层等价性 + 各分支单元测试已经满足；端到端联通测试属 verification follow-up）。可作为 Phase 5 后期或独立集成测试 sprint 的工作。

---

## §5 结论

**pass-with-followup**：

- AC-1（跨 chunk prefab 全/无原子性）— **pass**。代码 + 单元测试完整证明。
- AC-2（中途 lease/route 失败不留小尾巴）— **pass**。prepare rollback + abort 幂等 + Phase 3-bis 持久化恢复三层闭环。
- AC-3（三入口结果一致）— **pass**。代码层唯一入口 + 等价写入路径；端到端集成测试列入 follow-up。

未关闭项全部属于 Phase 3 §"交付物"中"refined blueprint catalog 真实化" / "refined patches 真实化" / "PrefabRasterPatch" 范畴，是 Phase 5 attribute pool / catalog patch 实际生效后的工作，不是 §3.2 AC 的硬条件。

---

## §6 Follow-up 清单

| ID | 项 | 评级 | 计划 |
| --- | --- | --- | --- |
| F-1 | 跨 macro refined blueprint catalog | Phase 5 catalog 真实化范畴 | Phase 5 attribute/tag pool 实际生效后 |
| F-2 | `PrefabRaster.layer_attrs` 扩展（attribute_set_ref / tag_set_ref / owner_object_id / owner_part_id） | Phase 5 prefab raster 真实化范畴；Phase 4 owner provenance 已在 ChunkProcess + ObjectRegistry 侧 ready | Phase 5 |
| F-3 | `PrefabRasterPatch` 结构 | Phase 5 范畴 | Phase 5（依赖 F-1/F-2） |
| F-4 | split-owner 跨 region multi-participant 真实集成测试 | A4-bis-cluster 范畴 | 跨 region scene 实例搭建完成后 |
| F-5 | 跨 chunk prefab 真实端到端集成测试（浏览器 / CLI / observe 三入口联通） | Verification follow-up，不阻塞 Phase 3 | 独立 integration test sprint 或 Phase 5 后期 |
| F-6 | Phase 3 commit 部分失败时 fence 留下的 Watcher 重试覆盖率提升 | observe-only，非缺陷 | 视 production observability 反馈再补 |

以上 follow-up 全部不阻塞 Phase 3 §3.2 三条验收口径通过。

---

## 附录：审计协议

- 审计执行：2026-05-13。
- HEAD：`d7867cf phase2: verifier audit + progress doc sync`。
- 测试命令：
  ```bash
  cd apps/scene_server && mix test test/scene_server/voxel/ --no-start
  cd apps/world_server && mix test --no-start
  ```
- 测试结果：scene 441/0 + world 1 doctest + 116/0。
- 本审计 **只读 + 一份 commit（文档同步 + 审计报告）**，未动 voxel 代码 / clients / CLAUDE.md / AGENTS.md。
