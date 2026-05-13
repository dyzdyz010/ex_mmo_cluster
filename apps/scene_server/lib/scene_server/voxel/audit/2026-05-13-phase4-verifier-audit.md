# Phase 4 Verifier Audit — Object Provenance 与局部破坏

- 审计日期：2026-05-13
- 审计者：verifier（独立审计 lane，未触碰 voxel 代码）
- 审计对象：ex_mmo_cluster `apps/scene_server/lib/scene_server/voxel/` Phase 4 / 4-bis / A4 / A4-4 落地
- 上游基线：
  - 验收口径来源：`.omc/goals/voxel-authoritative-and-field-minimum.md` §4.2
  - 实现自述：`apps/scene_server/lib/scene_server/voxel/README.md` §Phase 4 / 4-bis / A4 / A4-4
  - 主线进度文档：`docs/2026-05-07-体素服务器权威化架构进度检查.md`

## §1 审计范围

Phase 4 §4.2 三条验收口径：

1. **口径 A**：命中同一 macro 内不同 prefab part 能得到不同 owner object / part。
2. **口径 B**：局部破坏只影响目标 object/part 的 slots。
3. **口径 C**：delta 中包含 geometry 变化和 object state 变化。

本审计同时回答主线进度文档「§目标二缺口 D」中列出的 provenance 子项是否落地：owner object id、part id、part tags、runtime state。

## §2 代码覆盖证据

### 口径 A — 同 macro 内不同 owner / part

- `apps/scene_server/lib/scene_server/voxel/micro_layer.ex`
  - `defstruct ... owner_object_id: 0, owner_part_id: 0`（L18–L25）：layer 直接持 owner pair，每个 mask 内的 micro slots 共享 layer 的 owner，不同 owner 自然拆成不同 layer（`attribute_signature/1` L80–L83 把 owner 纳入 grouping fingerprint，protocol §5.4.4 的「同 material + 同 owner 合并」语义被强制）。
  - `owner_object_id` 取值域 `0..2^63-1`（`@u63_max` L15、`owner_object_id!/1` L106–L114），terrain layer 用 `owner=0` 与 placed object 自然区分。
- `apps/scene_server/lib/scene_server/voxel/storage.ex`
  - `lookup_owner_at/3`（L375–L389）：反向查 `(macro_idx_or_coord, micro_slot_index) → {object_id, part_id} | nil`，是 damage attribution 的底层 truth；
  - `refresh_chunk_object_refs/1`（L413–L489）：整 chunk 重算策略，从 layer truth 推 cell 级 `ObjectCoverRef[]` + chunk 级 `ChunkObjectRef[]`（含 AABB + `cover_hash` xxHash64）。L433 显式 reject `owner_object_id == 0`，避免 terrain 污染 ChunkObjectRef[]。
- `apps/scene_server/lib/scene_server/voxel/chunk_process.ex`
  - `apply_normalized_intent` / `apply_normalized_intents` 路径在 commit 后调 `Storage.refresh_chunk_object_refs/1`（见 `destroy_part_in_state/2` L1782–L1828 的 L1800–L1802；apply path 走同一个 refresh hook）。

**结论**：✅ 代码层面对「同 macro 内不同 owner / part」的真相源建模完整，且 reverse index（cell 级 / chunk 级）从 layer truth 单向推导，无 dual write 风险。

### 口径 B — 局部破坏只影响目标 object/part 的 slots

- `apps/scene_server/lib/scene_server/voxel/chunk_process.ex`
  - `destroy_part/2` 公开 API（L193–L195） + `handle_call({:destroy_part, attrs}, ...)`（L555 起） + `destroy_part_in_state/2`（L1782–L1828）：
    - `collect_part_target_slots/3`（L1830–L1850）只挑 `layer.owner_object_id == object_id and layer.owner_part_id == part_id` 的 layer，逐 mask bit 拆出 `{macro_idx, slot}` 列表；
    - `Enum.reduce(targets, ..., Storage.clear_micro_block(...))`（L1796–L1798）只对那些 slot 调 `clear_micro_block`，**不**触碰其它 owner 的 layer；
    - 然后 `Storage.refresh_chunk_object_refs/1` + `bump_chunk_version` + `persist_snapshot`，保证 reverse index 和 chunk_version 严格跟着 geometry 变化前进。
  - `cleanup_object_refs/2`（L204、handle_call L581）：destroy_object 路径的兜底清理，drop stale `ChunkObjectRef[]` 入口；属于 belt-and-suspenders（`refresh_chunk_object_refs` 已经会自然清掉），不会误伤其它对象。
- `apps/scene_server/lib/scene_server/voxel/object_registry.ex`
  - `do_destroy_part/6`（L467–L540）：先对每个 `instance.covered_chunks` 逐 chunk 调 `ChunkDirectory.destroy_part`（L473–L480），再 mark PartState destroyed + persist。若全部 part destroyed，cascade 到 `run_destroy_object/4` 同步 evict owner cache（L561）+ DELETE row。
  - `accumulate_damage` → 同步 cascade（L376–L386）：health <= 0 → `run_destroy_part`，保证 damage 终态收敛到 destroy_part。
- `apps/scene_server/lib/scene_server/voxel/chunk_process.ex`
  - damage attribution（L1026–L1080）：apply batch 之前用 `Storage.lookup_owner_at` 收集 `{(oid, pid) => damage_count}`，commit 后 `Task.start` 异步 dispatch 到 `ObjectRegistry.accumulate_damage`，**打破** ChunkProcess → ObjectRegistry → ChunkDirectory → ChunkProcess.destroy_part 的同步 deadlock。Task.start 失败（registry 未启）catch :exit 静默丢弃，不阻塞热路径。

**结论**：✅ 代码层面局部破坏严格限定在 `{owner_object_id, owner_part_id}` 匹配的 slot，且 attribution 路径用 lookup_owner_at 在 storage truth 上 resolve owner（不依赖客户端 hint）。异步 dispatch 设计绕开了循环 deadlock，是结构性而非补丁式。

### 口径 C — delta 中包含 geometry 变化和 object state 变化

**Geometry 变化**：

- `ChunkProcess.destroy_part_in_state/2`（L1782–L1828）`bump_chunk_version` + `encode_snapshot_payload` + `persist_snapshot`，apply path 同样走 chunk delta / snapshot fan-out（`apply_normalized_intents` 走 ChunkDelta，destroy_part 兜底走 snapshot fallback）。
- `apply_intents` 的 batch fan-out 在 README L26–L29 描述：「向订阅者 fan-out 一条按最终 macro 合并后的 `ChunkDelta`」。

**Object state 变化**：

- `apps/scene_server/lib/scene_server/voxel/codec.ex` 第 301–425 行：
  - `encode_voxel_object_state_delta_payload/1`（L325–L397）→ 0x6C opcode payload；
  - `decode_voxel_object_state_delta_payload/1`（L399–L424）→ wire-form round-trip 解析（含 forward-compat `attribute_patch_count` / `tag_patch_count` 透传）。
- `ObjectRegistry.dispatch_object_state_delta/3`（L635–L667）：在 `emit_damage` / `emit_part_destroyed` / `emit_object_destroyed` 后**同步**调，encode 一次 binary → 按 `covered_chunks_by_region` 分桶 → 对每 chunk lookup_chunk_pid → cast push（`ChunkProcess.push_object_state_delta_payload/2`）。
- `state_flags` 语义（D5）：每条 0x6C 表达「这次事件」触发的 flag（damaged / part_destroyed / destroyed 三选一），客户端按 `object_version` 单调递增去重。`run_destroy_object/4` L578 显式 `bump object_version` 保证 cascade 路径两条 0x6C 版本号严格单调。

**结论**：✅ 两条 delta 通道都齐全：geometry 走 `ChunkDelta` / snapshot fallback，object state 走 0x6C 独立 wire frame，两者由不同 fan-out 路径独立分发，避免了「geometry 和 object state 必须共载一帧」的耦合。

## §3 测试覆盖证据

测试运行命令：`cd apps/scene_server && mix test test/scene_server/voxel/ --no-start`

**运行结果**：**317 tests, 0 failures**（连续 ≥10 次稳定运行；一次早期 run 出现 1 个 transient 失败，后续 15+ 次重跑均通过，按异步 Task.start 时序 flake 处理，不阻塞 audit 结论；ObjectLifecycleIntegrationTest 中已用 `assert_eventually` deadline 1s 防御该时序问题，未观察到稳定可复现的 fail）。

按口径列：

### 口径 A 测试覆盖

- `apps/scene_server/test/scene_server/voxel/storage_object_refs_test.exs`
  - `lookup_owner_at/3` describe block（L8–L81）：empty / solid / 同 macro 多 owner 共存 / clear 后回退 / 越界 raise，5 个 case 全覆盖反向查询语义；尤其 L40–L59「returns the right layer when multiple owners coexist in one macro」直接覆盖口径 A。
  - `refresh_chunk_object_refs/1` describe block（L83 起）：覆盖 ObjectCoverRef[] / ChunkObjectRef[] 重建。
- `apps/scene_server/test/scene_server/voxel/chunk_process_object_provenance_test.exs`
  - 「apply_intent / apply_intents — owner provenance refresh」describe block（L28–L166）：
    - L29「put_micro_block with owner_object_id refreshes ChunkObjectRef[]」
    - L72「apply_intents with multiple owner_object_ids produces sorted ChunkObjectRef[]」
    - L105「break_micro_block prunes cell.object_refs and shrinks ChunkObjectRef[]」
- `apps/scene_server/test/scene_server/voxel/object_cover_ref_test.exs`（102 行，结构性 ref 测试）

### 口径 B 测试覆盖

- `apps/scene_server/test/scene_server/voxel/chunk_process_object_provenance_test.exs`
  - 「ChunkProcess.destroy_part/2 (Phase 4 D8)」describe block（L168–L263）：
    - L169「wipes every micro slot owned by (object_id, part_id)」直接覆盖口径 B 的核心断言：destroy_part(42, 3) 后 slot 0/1 清空，但 (42, 4) part 仍在 slot 2，(99, 1) 仍在 slot 3。
    - L227「is a no-op when no matching slots exist」
    - L239「fully drains the only object → ChunkObjectRef[] becomes empty」
  - 「ChunkProcess.cleanup_object_refs/2 (Phase 4 D9)」describe block（L265–L302）
- `apps/scene_server/test/scene_server/voxel/object_lifecycle_integration_test.exs`
  - L34「single-part object lifecycle: place → damage → part_destroyed → object_destroyed full chain」
  - L94「multi-part object lifecycle: destroying one part leaves the object alive, second part destroys it」直接覆盖 multi-part 局部破坏的隔离性。
- `apps/scene_server/test/scene_server/voxel/object_registry_test.exs`（517 行）：accumulate_damage / destroy_part / destroy_object 全 API + cascade 行为。

### 口径 C 测试覆盖

- `apps/scene_server/test/scene_server/voxel/codec_object_state_delta_test.exs`（188 行）：encode/decode round-trip、empty list、negative coords、固定 header 大小、out-of-range raise。
- `apps/scene_server/test/scene_server/voxel/chunk_process_object_state_delta_push_test.exs`（128 行）：ChunkProcess.push_object_state_delta_payload/2 fan-out 到 subscribers。
- `apps/scene_server/test/scene_server/voxel/object_state_delta_e2e_test.exs`（230 行，async: false）：
  - L39「destroy_object emits one 0x6C wire frame to chunk subscribers」
  - L78「non-destroying damage emits flag_damaged 0x6C wire frame」
  - L112「cascade(damage 致命)emits two 0x6C frames in version-monotone order」
  - 全链路 ObjectRegistry → encode 0x6C → ChunkDirectory.lookup_chunk_pid → ChunkProcess.cast → subscriber send。
- `apps/scene_server/test/scene_server/voxel/object_registry_broadcast_test.exs`（228 行）
- `apps/scene_server/test/scene_server/voxel/object_registry_cross_region_test.exs`（297 行）：cross-region 路由 + 多 region bucket fan-out（Phase A4-4 增量）。
- `apps/scene_server/test/scene_server/voxel/object_owner_lookup_test.exs`（202 行）：owner cache hot path / miss-resolve / register / evict。

### 结构性结论

- 三条口径每条都有 ≥3 个独立测试文件覆盖（unit + integration + e2e）。
- e2e test (`object_state_delta_e2e_test.exs`、`object_lifecycle_integration_test.exs`) 覆盖完整闭环，且都用 real ObjectRegistry + real ChunkDirectory + real ChunkProcess，不靠 fake/mock。
- Phase A4 cross-region 路由有专门的 `object_registry_cross_region_test.exs` 覆盖（虽然不属于 §4.2 三口径，但与 owner_object_id 链路同源）。

## §4 已识别 gap / 风险

下列 gap **不阻塞 Phase 4 验收**，但作为继续推进 Phase 5 / A4-bis-cluster 时需要回填的清单：

1. **Damage dispatch 用 `Task.start` 异步**（chunk_process.ex L1059）：
   - 在 ObjectRegistry crash / not started 时 damage 累计会 `catch :exit` 静默丢弃（L1071–L1074）。这是设计取舍（best-effort，下次 apply 会重算 attribution），但缺少 dropped-damage observe counter，生产观测不到「丢了多少 damage」。
   - 建议：补 `voxel_damage_dispatch_dropped` observe key，给 Phase 5 体感调优留观测面。
2. **Cold-start owner-lookup 退化** (`object_owner_lookup.ex` L26–L33)：
   - server 重启后若 `register/3` 未及时回放，cache miss 走 store 解析时把 `covered_chunks_by_region` 退化为 `%{owner_key => obj.covered_chunks}`（所有 chunks 归 owner region）；A4-bis-cluster 真正多 region 部署前可能产生跨 region 的 0x6C 错误 fan-out。
   - README 已显式记入「A4-bis-cluster 加 `MapLedger.region_for_chunk` 后退役该兜底」，属于 Phase A4-bis-cluster 计划项，**不属于** Phase 4 §4.2 验收范围。
3. **Phase 5 deferral（README 第 217–223 行已记录）**：客户端 `onlineVoxelWorldAdapter.applyDelta` 之前的 ClearedSlotCache hook 未接，production debris 走 affected_chunks_fallback。属 Phase 5 客户端工作，与服务端 Phase 4 §4.2 验收无关。
4. **PartState health 初始值默认 ratio = 1.0**（`part_state.ex` moduledoc L10–L12）：未引入 `PartDefinition.default_health_ratio` 协议字段，所有 part 用同一 ratio。README 标注 Phase 5 落地，属预期内 deferral。
5. **测试时序 flake**：早期 16 次重跑中观察到 1 次 transient 失败，后续 15+ 次连续通过。`object_lifecycle_integration_test.exs` 已用 `assert_eventually` 1s deadline 防御，但 e2e/lifecycle 测试在 CI 上若慢机器可能偶发 timeout。
   - 建议：把 `assert_eventually` 默认 timeout 提到 2s 或加 backoff（非阻塞项）。

## §5 结论

**pass-with-followup**。

- 口径 A：✅ pass
- 口径 B：✅ pass
- 口径 C：✅ pass
- 测试：✅ 317/317 pass（稳定，单次 transient flake 不可复现）

Phase 4 object provenance + part-health 破坏闭环 + 4-bis 0x6C 推送 + A4 / A4-4 cross-region 路由全部落地，代码层面机制结构清晰（layer-as-truth + reverse index 单向推导 + 异步 Task.start 解 deadlock + owner-driven 多 region fan-out），测试覆盖既有 unit 又有 e2e，且 e2e 用真实子系统（无 mock）。已识别 5 项 followup，全部属于 Phase 5 / A4-bis-cluster 范畴或观测面优化，**不阻塞** Phase 4 验收。

## §6 推荐 progress doc 改动文本

### §「建议实施顺序」Phase 4 段落顶部插入

```
**状态：已实现（2026-05-13 verifier 审计通过）**。详见 `apps/scene_server/lib/scene_server/voxel/audit/2026-05-13-phase4-verifier-audit.md`。已落地能力以 `apps/scene_server/lib/scene_server/voxel/README.md` Phase 4 / 4-bis / A4 / A4-4 段为权威记录。
```

### §「目标二缺口 D」段落顶部插入

```
**状态：已实现（2026-05-13 verifier 审计通过）**。本段保留作为历史背景，实际落地能力见 README Phase 4 / 4-bis / A4 / A4-4 段。
```

### 未关闭的 gap（追加段）

```
**Phase 4 未关闭的 gap（不阻塞验收，列入 Phase 5 / A4-bis-cluster 跟踪）**：

1. damage dispatch `Task.start` 丢弃路径缺少 dropped-damage observe counter。
2. owner-lookup cold-start 退化 `%{owner_key => covered_chunks}`，A4-bis-cluster 加 `MapLedger.region_for_chunk` 后退役。
3. PartState health 初始值统一用 ratio=1.0，Phase 5 引入 `PartDefinition.default_health_ratio` 后改 per-part。
4. e2e 测试用 `assert_eventually` 1s deadline，偶发 CI 慢机器 transient flake（15+ 次连续通过未复现）。
```
