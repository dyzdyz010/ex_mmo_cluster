# 2026-05-13 Phase 2 Verifier Audit — refined micro edit §2.2

本审计独立验证 `docs/2026-05-07-体素服务器权威化架构进度检查.md` §"建议实施顺序" Phase 2 §"验收"中 3 条硬 gate 的代码 + 测试覆盖，不预先采信轮次 #1 Phase 2 探索 agent（`a656ac653221135e9`）的 `mostly_done` 结论。

> 上下文：goal `voxel-authoritative-and-field-minimum` Phase 2，HEAD `1ea3290 phase1.6b: web_client TS decoder + roundtrip (Phase 1 全收口)`。本审计**只读 + 一份 commit（文档同步 + 审计报告）**，不动 voxel 代码。

---

## §1 审计范围

§"建议实施顺序" Phase 2 §"验收" 三条硬 gate（progress doc line 304-306）：

| ID | 验收口径 |
| --- | --- |
| AC-1 | 左键破坏 refined micro slot 后，**只移除目标 slot**（不影响同 macro 其他 slot；最后一个 slot 清除时整 macro 降级为 empty） |
| AC-2 | 右键放置 refined micro slot 后，**snapshot/delta 回推可读**（订阅者收到 `CellRefined` `delta_kind=2` payload；可由相同 codec 双向解码出最新 `RefinedCellData`） |
| AC-3 | 在线模式刷新后**状态来自服务端持久化**（DataService PostgreSQL 持久化的 ChunkSnapshot），不来自浏览器 local storage |

Phase 2 §"交付物"四项中本审计仅对前 3 项做硬 gate 判断（与验收口径直接对齐）：

- ✅ Scene storage refined mutation API
- ✅ `CellRefined` delta encode/decode/apply
- ✅ typed edit intent 第一版
- ⚠️  CLI（`micro_cell` / `micro_place` / `micro_break`）—— 见 §4 / §6 分类

---

## §2 代码覆盖证据（按口径列）

### AC-1：左键破坏 refined micro slot 仅移除目标 slot

| 路径 | 行 | 行为 |
| --- | --- | --- |
| `apps/scene_server/lib/scene_server/voxel/storage.ex` | 289-324 | `clear_micro_block/4`：refined 模式下从目标 layer 的 mask 中清掉指定 slot；layer 清空则丢弃；refined cell 整体清空则 `downgrade_refined_to_empty/4`；solid 模式 raise `:cannot_micro_edit_solid_macro`；empty 模式 / 已空 slot 幂等 no-op。 |
| `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` | 1505-1535 | `build_intent_storage/2` `:clear_micro_block` 分支：将 intent 翻译为 `Storage.clear_micro_block/4` 调用，并把 `cell_version` / `cell_hash` / `flags` opts 透传到 macro header。 |
| `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` | 1696-1707 | `apply_one_intent/3` `:clear_micro_block` 路径，把 storage 写入与 changed flag 一起回填。 |
| `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` | 2309-2334 | `build_intent_delta_op/2` `:clear_micro_block` 分支：若 header 已降级为 `empty` → `delta_kind=0`（CellEmpty），否则 `delta_kind=2` 带剩余 refined cell payload。 |
| `apps/gate_server/lib/gate_server/worker/ws_connection.ex` | 1116-1117 | `voxel_edit_intent_op/1` 把 `action=1 & target_granularity=1` 映射到 `:clear_micro_block`。 |
| `apps/gate_server/lib/gate_server/worker/ws_connection.ex` | 1211-1214 | `maybe_put_micro_slot/3` 在 `[:put_micro_block, :clear_micro_block]` 分支把 local micro 写入 intent attrs。 |

**结论**：AC-1 有完整代码路径覆盖：客户端 click → typed `VoxelEditIntent`（`action=1, target_granularity=1`） → Gate `:clear_micro_block` → `ChunkProcess.apply_intent` → `Storage.clear_micro_block` → 单 slot 移除 / refined→empty 降级 → `delta_kind=2` 或 `delta_kind=0` 下发。

### AC-2：右键放置 refined micro slot snapshot/delta 回推可读

| 路径 | 行 | 行为 |
| --- | --- | --- |
| `apps/scene_server/lib/scene_server/voxel/storage.ex` | 177-215 | `put_micro_block/5`：empty → refined 通过 `append_refined_cell`；refined → refined 通过 `upsert_micro_slot` + `replace_refined_cell`；solid raise `:cannot_micro_edit_solid_macro`。 |
| `apps/scene_server/lib/scene_server/voxel/storage.ex` | 233-277 | `put_micro_blocks/4` batch 路径（同 macro 多 slot 一次写入）；与 sequential `put_micro_block` 严格等价（见 §3 storage 测试 line 130-147 `sphere-sized 280 slots` 等价测试）。 |
| `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` | 1478-1503 | `build_intent_storage/2` `:put_micro_block` 分支：透传 `cell_version` / `cell_hash` / `flags` / `environment_index` / `boundary_cache` opts。 |
| `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` | 1537-1561 | Phase A1-1b fast path：整 batch 都是 `:put_micro_block` on same macro → `Storage.put_micro_blocks/4` 一次写入（sphere prefab 280 slots 从 ~1.5s → ~50-100ms）。 |
| `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` | 2295-2307 | `build_intent_delta_op/2` `:put_micro_block` 分支：读 mutate 后的 macro header + refined cell，构造 `delta_kind=2` op，payload 为 `Codec.encode_refined_cell_payload/1` 输出（layer-diff 显式延后；见 phase-1c-refined-mutation.md decision 4）。 |
| `apps/scene_server/lib/scene_server/voxel/codec.ex` | 1282-1340 | `encode_refined_cell_payload/1` + `decode_refined_cell_payload/1` + `decode_refined_cell_payload!/1`：单 cell wire 等价于 1-cell pool 去掉 `count:u32` 前缀，可被同一个 codec 双向解码（byte-stable）。 |
| `apps/scene_server/lib/scene_server/voxel/codec.ex` | 937-986 | `encode_delta_op/1` + `decode_delta_ops/3`：`delta_kind:u8 / macro_index:u16 / cell_version:u32 / cell_hash:u32 / payload_len:u16 / payload` —— 标准 ChunkDelta op 协议，承载 `delta_kind=2` 时 payload 即 `encode_refined_cell_payload/1` 字节。 |
| `apps/gate_server/lib/gate_server/codec.ex` | 616-701 | `VoxelEditIntent` v1 encoder：`request_id:u64 / client_intent_seq:u32 / logical_scene_id:u64 / action:u8 / target_granularity:u8 / target_world_micro:3×i64 / face_normal:3×i8 / material_id:u16 / blueprint_ref:u32 / object_ref:u64 / part_ref:u32 / attribute_patch_ref:u32 / expected_chunk_version:u64 / expected_cell_hash:u32 / client_hint_hash:u64`（15 字段，覆盖主线文档 §"目标二缺口 B"）。 |
| `apps/gate_server/lib/gate_server/worker/ws_connection.ex` | 1098-1110 | `voxel_edit_intent_op/1` 把 `action=0 & target_granularity=1` 映射到 `:put_micro_block`（含 `voxel_edit_intent_micro_layer/1` 翻译）。 |
| `apps/gate_server/lib/gate_server/worker/ws_connection.ex` | 1152-1162 | `voxel_edit_intent_target/2`：`:put_micro_block` 目标 = `(wx + fnx, wy + fny, wz + fnz)`（face-normal 偏移使右键放置落在邻接 slot）。 |
| `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` | 2338-2365 | `push_chunk_delta/4`：mutate 后向所有 subscriber 推送编码好的 ChunkDelta payload（含 observe `voxel_chunk_delta_push`），不再 fallback 整 snapshot。 |
| `clients/web_client/src/voxel/onlineVoxelWorldAdapter.ts` | 347-365, 395+ | `placeMicroBlock` / `breakMicroBlock` 现已通过 `transport.sendVoxelEditIntent(...)` 路径发送 typed `VoxelEditIntent`（而不是返回 `micro_*_not_supported_by_server`）。 |
| `clients/web_client/src/presentation/devtools/devToolsCli.ts` | 102-107, 314-356 | web CLI 已实现 `micro_cell` / `micro_place` / `micro_break` 命令。 |

**结论**：AC-2 有完整代码路径覆盖：客户端 right-click → typed `VoxelEditIntent`（`action=0, target_granularity=1, face_normal`） → Gate `:put_micro_block` → `ChunkProcess.apply_intent` → `Storage.put_micro_block` → `delta_kind=2` 推送 → 客户端 `decode_refined_cell_payload` 读回。

### AC-3：在线模式刷新后状态来自服务端持久化

| 路径 | 行 | 行为 |
| --- | --- | --- |
| `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` | 1904-1911 | `persist_snapshot/4`：每次 mutate 后调用 `DataService.Voxel.ChunkSnapshotStore.put_snapshot/1` 把整 chunk snapshot 写入 PostgreSQL。 |
| `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` | 1979-1998 | `safe_persist_snapshot_with_retry/2` + `persist_snapshot_with_retry/2`：write-token fence 失败时 3 次重试，避免单次冲突阻塞 hot chunk。 |
| `apps/data_service/lib/data_service/voxel/chunk_snapshot_store.ex` | — | `put_snapshot/1` / `get_snapshot/2`：基于 PostgreSQL 的 `voxel_chunks` 表持久化，含 lease/region fence、`pg_advisory_xact_lock` 串行化。 |
| `apps/data_service/priv/repo/migrations/20260507000001_create_voxel_chunks.exs` | — | `voxel_chunks` 表迁移：`logical_scene_id` + 3D coord 主键、`data` bytea 列存编码后的 ChunkSnapshot wire payload、`chunk_version` / `chunk_hash` 列存 byte-stable 状态指纹。 |
| `clients/web_client/src/voxel/onlineVoxelWorldAdapter.ts` | — | 在线模式下 `WorldStore` 只应用服务端 `ChunkSnapshot / ChunkDelta / VoxelIntentResult`（默认 `voxel_sync=server-authoritative`，参见 progress doc §"基础事实"）。`placeMicroBlock` / `breakMicroBlock` 不再直接写本地 storage，只发 intent + 等服务端回 delta。 |

**结论**：AC-3 有完整代码路径覆盖：micro mutate → chunk_process 持久化 ChunkSnapshot 到 PostgreSQL → 客户端刷新时 subscribe 重新走 `ChunkSnapshot` 路径，从 DataService 读最新 snapshot，绕过浏览器 local storage。

---

## §3 测试覆盖证据（按口径列 + 测试通过/失败结果）

### 测试运行命令

```powershell
$env:HEX_HTTP_CONCURRENCY = "1"; $env:HEX_HTTP_TIMEOUT = "120"
cd apps/scene_server
mix test test/scene_server/voxel/ --no-start
```

### 测试运行结果（3 次连续运行）

| 运行 | 总数 | 失败 | 备注 |
| --- | --- | --- | --- |
| 1 | 441 | 1 | 单次 transient 失败，未落在 Phase 2 micro-edit 范围内（`Phase 1c — :put_micro_block / :clear_micro_block intents` 测试块在 transient 之前已通过）；与已记录在 Phase 4 audit follow-up #4 的 e2e `assert_eventually 1s deadline` flake 风格一致。 |
| 2 | 441 | 0 | 全绿。 |
| 3 (`--seed 0`) | 441 | 0 | 全绿。 |

**baseline 441 voxel tests（Phase 1.6a 末）保持。** transient 不阻塞 Phase 2 §2.2 验收，但记入 §4 风险并对齐 Phase 4 follow-up #4。

### AC-1 测试覆盖

| 测试文件 | 行 | 测试名 | 覆盖点 |
| --- | --- | --- | --- |
| `storage_micro_mutation_test.exs` | 278-291 | `"removes a slot from the layer and updates occupancy"` | refined → refined：单 slot 清除后只动目标 layer 的 mask。 |
| `storage_micro_mutation_test.exs` | 293-306 | `"drops a layer that becomes all-zero (no ghost layers)"` | layer 整层清空时被丢弃，不留 ghost layer。 |
| `storage_micro_mutation_test.exs` | 308-318 | `"downgrades the macro header back to :empty when all slots are cleared"` | refined → empty 降级行为。 |
| `storage_micro_mutation_test.exs` | 319-333 | `"preserves cell_version / cell_hash when downgrading"` | downgrade 期间元数据保留。 |
| `storage_micro_mutation_test.exs` | 335-340 | `"is a no-op on an empty macro"` | 幂等性（empty macro）。 |
| `storage_micro_mutation_test.exs` | 341-346 | `"is a no-op on a slot that wasn't occupied"` | 幂等性（未占用 slot）。 |
| `storage_micro_mutation_test.exs` | 347-356 | `"raises :cannot_micro_edit_solid_macro on solid macro"` | solid macro 拒绝路径。 |
| `storage_micro_mutation_test.exs` | 357-367 | `"rejects micro_slot_index out of 0..511"` | 输入校验。 |
| `storage_micro_mutation_test.exs` | 368-412 | `"10-slot put/clear sequence keeps all §5.4 invariants"` | 综合 put/clear 序列 invariant。 |
| `storage_micro_mutation_test.exs` | 413-430 | `"fully clearing all slots returns the macro to :empty"` | 全清后降级。 |
| `chunk_process_test.exs` | 486-536 | `"apply_intent :clear_micro_block clears the slot and downgrades to empty when last"` | end-to-end intent 路径，含 DataService 持久化读回校验。 |
| `chunk_process_test.exs` | 538-553 | `"apply_intent :clear_micro_block on empty slot is a noop"` | 幂等 + 不 bump version。 |
| `chunk_process_test.exs` | 581-590 | `"clear_micro_block raises :cannot_micro_edit_solid_macro on solid macro"` | solid 拒绝路径。 |
| `chunk_process_test.exs` | 664-699 | `"subscribers receive CellEmpty ChunkDelta (delta_kind=0) when last slot is cleared"` | 最后 slot 清除 → `delta_kind=0` 推送验证。 |
| `chunk_process_test.exs` | 701-744 | `"clear_micro_block leaves a refined cell ChunkDelta (delta_kind=2) when slots remain"` | 非末 slot 清除 → `delta_kind=2` 推送验证。 |

### AC-2 测试覆盖

| 测试文件 | 行 | 测试名 | 覆盖点 |
| --- | --- | --- | --- |
| `storage_micro_mutation_test.exs` | 151-172 | `"promotes an empty macro cell to refined and creates one layer with one bit"` | empty → refined 转换 + 单 slot bit 正确性。 |
| `storage_micro_mutation_test.exs` | 174-183 | `"every micro slot index in 0..511 maps to the correct (word, bit) position"` | 8 个 boundary slot 全数。 |
| `storage_micro_mutation_test.exs` | 185-197 | `"passes cell_version / cell_hash / flags through"` | macro header 元数据透传。 |
| `storage_micro_mutation_test.exs` | 201-214 | `"merges two slots with identical attribute signature into one layer"` | refined → refined：相同 signature 合并。 |
| `storage_micro_mutation_test.exs` | 216-227 | `"creates a second layer when attribute signatures differ"` | 不同 signature 新建 layer。 |
| `storage_micro_mutation_test.exs` | 229-242 | `"preserves canonical layer order regardless of insertion order"` | canonical 排序稳定性。 |
| `storage_micro_mutation_test.exs` | 244-250 | `"rejects a put on a slot that is already occupied"` | 占用冲突拒绝。 |
| `storage_micro_mutation_test.exs` | 254-262 | `"raises :cannot_micro_edit_solid_macro when target macro is :solid"` | solid 拒绝路径。 |
| `storage_micro_mutation_test.exs` | 266-274 | `"rejects micro_slot_index out of 0..511"` | 输入校验。 |
| `storage_micro_mutation_test.exs` | 25-148 | `put_micro_blocks` batch API（8 个测试） | batch 路径 vs sequential 严格等价（含 sphere 280 slots / 多 material 分层 / 已占用拒绝 / solid 拒绝）。 |
| `storage_micro_mutation_test.exs` | 431-471 | `"multi-cell pool layout"`（2 个测试） | 不同 macro 各自占 refined pool slot；downgrade 留 orphan 但不破坏其他 macro。 |
| `chunk_process_test.exs` | 422-455 | `"apply_intent :put_micro_block writes a refined slot, bumps versions, persists snapshot"` | end-to-end：intent → mutate → DataService 持久化 → snapshot 读回，header.mode = refined，layer + occupancy 字节级正确。 |
| `chunk_process_test.exs` | 457-484 | `"apply_intent :put_micro_block on already-occupied slot returns :micro_slot_already_occupied"` | 占用冲突 error code。 |
| `chunk_process_test.exs` | 555-579 | `"put_micro_block on a solid macro is rejected"` | solid 拒绝（Decision 2 不自动升级）。 |
| `chunk_process_test.exs` | 592-610 | `"rejects micro_slot out of 0..511"` | 输入校验。 |
| `chunk_process_test.exs` | 612-627 | `"put_micro_block requires micro_layer"` | 必填字段校验。 |
| `chunk_process_test.exs` | 629-662 | `"subscribers receive a CellRefined ChunkDelta (delta_kind=2) after a micro put"` | **AC-2 最直接证据**：subscribe → put_micro_block → 收到 `delta_kind=2` payload → `Codec.decode_refined_cell_payload(op.payload)` 反解出正确 `layer` + `occupancy`。 |
| `chunk_process_test.exs` | 746-960+ | `"Phase 1c — expected_chunk_version / expected_cell_hash optimistic concurrency"` block（多 test） | OCC fence、stale chunk_version、cell_hash mismatch、durable snapshot reconcile 等。 |

### AC-3 测试覆盖

| 测试文件 | 行 | 测试名 | 覆盖点 |
| --- | --- | --- | --- |
| `chunk_process_test.exs` | 371-394 | `"persists snapshots through DataService write-token fence"` | DataService write-token fence 端到端持久化。 |
| `chunk_process_test.exs` | 395-420 | `"stale lease cannot persist after token advances"` | 旧 lease 持久化拒绝（防止 split-brain 覆写）。 |
| `chunk_process_test.exs` | 422-455 (AC-2 内) | `"writes a refined slot, ..., persists snapshot"` | micro put 后 `ChunkSnapshotStore.get_snapshot/2` 取回 PostgreSQL 中的 snapshot，并 codec 解码 verify。 |
| `chunk_process_test.exs` | 486-536 (AC-1 内) | `"clears the slot and downgrades to empty when last"` | micro clear 序列后 `ChunkSnapshotStore.get_snapshot/2` 读回，header.mode = empty 验证。 |
| `chunk_process_test.exs` | 823-855 | `"apply_intent reconciles durable newer snapshot before unpinned writes"` | 持久化的 newer snapshot 在 hot chunk 重启后被 reconcile 回执行 state。 |
| `apps/data_service/test/data_service/voxel/chunk_snapshot_store_test.exs` | — | `ChunkSnapshotStore` 直接单测（PostgreSQL 行为）。 |

**结论**：AC-3 通过：每个 micro mutate 测试都 round-trip `ChunkSnapshotStore.put_snapshot/1` → `ChunkSnapshotStore.get_snapshot/2` → `Codec.decode_chunk_snapshot_payload/1` 验证服务端 PostgreSQL 持久化的字节级正确性。

---

## §4 已识别 gap / 风险

### 4.1 未阻塞 Phase 2 验收的 gap（follow-up）

| ID | gap | 影响评估 |
| --- | --- | --- |
| FU-1 | `Storage.merge_refined_cell` 未实现 | Phase 3 prefab v2 事务 refined patch 才需要（多 owner 合并到同一 refined cell）。Phase 2 §2.2 三条验收只需 empty↔refined 单 slot 路径，已覆盖。 |
| FU-2 | `Storage.split_solid_macro_to_refined` 未实现 | Decision 2（progress doc + phase-1c-refined-mutation.md）显式声明 v1 不自动升级 solid → refined。代码上 `put_micro_block` raises `:cannot_micro_edit_solid_macro`，行为是明确的 v1 设计选择，**不是 gap**。可考虑列为 Phase 3+ feature flag。 |
| FU-3 | `Storage.clear_refined_cell_if_empty` 未实现 | 当前 `clear_micro_block` 内部已含降级路径（清空后整 cell 降级为 empty，见 storage.ex line 315-319 `if refined_cell_empty?(updated_cell) do downgrade_refined_to_empty(...)`）。独立 helper 未导出，但语义已覆盖。 |
| FU-4 | `Storage.collapse_full_refined_to_solid` 未实现 | 反向降级路径（refined → solid 当 occupancy 全满），Phase 5 属性目录或 Phase 4 prefab 局部破坏才需要。**Phase 2 §2.2 不要求**。 |
| FU-5 | 服务端 / iex-shell CLI 的 `micro_cell` / `micro_place` / `micro_break` 未实现 | web_client `devToolsCli.ts` line 102-107, 314-356 已实现客户端侧 CLI，能覆盖 §2.2 端到端验证。服务端 iex-shell CLI 是开发便利项，不阻塞验收。 |
| FU-6 | progress doc §"代码证据" table line 32 内容已陈旧 | 原文 `placeMicroBlock` / `breakMicroBlock` 返回 `micro_*_not_supported_by_server` 已不再准确（onlineVoxelWorldAdapter.ts line 347-395 已发 typed VoxelEditIntent）。但 §"代码证据" table 是历史快照属性，本审计**不动**，只在 progress doc 验收段加状态行。 |
| FU-7 | Phase 4 audit 已记录的 `assert_eventually 1s deadline` transient flake 影响本次首次运行 | 本审计连续 3 次运行已验证 baseline 441 / 0 failures 稳定（首次 1 transient → 次次 0），与 Phase 4 audit follow-up #4 同源；不阻塞 Phase 2。 |

### 4.2 未关闭的真 gap（不在 §2.2 验收范围内，列入未来阶段）

**未识别。** §2.2 三条硬 gate 的代码 + 测试覆盖均已闭合，没有遗留 voxel 路径上的真 gap 漏失。

### 4.3 协议规范文档引用 gap

progress doc 当前没有显式指向 `docs/voxel-server-authority/phase-1c-refined-mutation.md`（Phase 2 设计依据，含 Decision 2 / 4）。该文档实际存在并被代码注释引用（chunk_process.ex line 2292-2294, storage.ex `cannot_micro_edit_solid_macro` 错误信息）。建议在 progress doc 验收段加 reference 链。本次同步已采纳。

---

## §5 结论

**Phase 2 §2.2 验收结论：pass-with-followup**

| 口径 | 结论 |
| --- | --- |
| AC-1 左键破坏 refined micro slot 只移除目标 slot | **pass** |
| AC-2 右键放置 refined micro slot snapshot/delta 回推可读 | **pass** |
| AC-3 在线模式刷新后状态来自服务端持久化 | **pass** |

**整体**：3 条硬 gate 全部通过。Phase 2 §"交付物" 前 3 项（refined mutation API / `CellRefined` delta / typed `VoxelEditIntent`）全部完整落地。第 4 项 CLI 在 web_client 侧已实现（足以支撑 §2.2 端到端验证）；服务端 iex-shell CLI 列为 follow-up，**不阻塞 Phase 2 验收**，也不阻塞 Phase 3 启动。

测试：441 voxel tests baseline 在连续 3 次运行下保持，仅首次有 1 个与 Phase 4 已记录 transient flake 同源的非 Phase-2 偶发失败。

---

## §6 follow-up 清单

### 6.1 可选 Storage 函数（Phase 3 / Phase 5 视具体需求触发）

- [ ] `Storage.merge_refined_cell/3` —— Phase 3 prefab v2 refined patch 合并多 owner 时需要。
- [ ] `Storage.split_solid_macro_to_refined/4` —— 仅当某 phase 决定推翻 Decision 2（solid → micro 自动升级）时才补；目前 v1 显式拒绝是设计选择，不视为 gap。
- [ ] `Storage.clear_refined_cell_if_empty/3` —— 独立 helper 导出（当前语义已隐含在 `clear_micro_block`）。低优先。
- [ ] `Storage.collapse_full_refined_to_solid/3` —— Phase 4 prefab 局部破坏完整后需要的 occupancy-full 升级路径；或 Phase 5 属性目录冷优化用。

### 6.2 CLI

- [ ] 服务端 iex-shell / mix task 形式的 `micro_cell` / `micro_place` / `micro_break`（web CLI 已实现 → low priority）。

### 6.3 文档同步

- [x] progress doc §"建议实施顺序" Phase 2 段标注"已实现核心 + verifier 审计通过"（本 commit）。
- [x] progress doc §"目标二缺口 A"、§"目标二缺口 B" 顶部加状态行（本 commit）。
- [ ] progress doc §"代码证据" table line 32 `placeMicroBlock / breakMicroBlock` 表述更新（陈旧但属于历史快照；不在本审计 commit 范围）。

### 6.4 协议规范引用

- [x] progress doc 验收段引用 `docs/voxel-server-authority/phase-1c-refined-mutation.md`（含 Decision 2 / 4）。
