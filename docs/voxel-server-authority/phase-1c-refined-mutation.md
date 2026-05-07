# Phase 1c — Scene refined mutation + CellRefined delta + 客户端解锁

## 目标

把 1a/1b 钉好的 wire 形真正接到运行时:Scene 端实现 micro slot 级 mutation API、`CellRefined` delta 路径、`VoxelEditIntent (0x70)` 端到端贯通,网页端解锁 `placeMicroBlock` / `breakMicroBlock`。

完成后:

- 客户端右键命中 prefab 微格能只移除目标 slot,而不是整个 macro。
- snapshot/delta 回推 refined truth,客户端刷新后状态来自服务端持久化。
- `voxel_sync=server-authoritative` 真正覆盖 micro 编辑链路(在线模式)。

## 不在范围内

- prefab v2 事务化(留 Phase 3:跨 chunk transaction coordinator)。
- object provenance 端到端(留 Phase 4:对 prefab/part 的 owner 反查与局部破坏)。
- attribute / tag 目录(留 Phase 5)。
- DataService schema 拆分(留 1d):1c 仍用 single-blob 持久化路径,refined cells 由整 storage 序列化覆盖。
- `solid → refined` 状态转换(在 solid macro 上"挖一个 micro"):1c v1 只支持 `empty ↔ refined`。solid 上挖洞需要先把 macro 拆成所有 occupied micro slots,语义复杂,留 1c-bis 或 Phase 3。

## 决策项(已定稿)

> 与 1a/1b 一致,决策按推荐值落定。后续偏离须在进度日志显式记录 RFC。

### 决策 1:**Scene 操作命名 `:put_micro_block` / `:clear_micro_block`**

风格与 `:put_solid_block` / `:break_block` 对齐,新增者:

- `:put_micro_block` — 在指定 macro 内的某个 micro slot 放置(material_id + state_flags + owner)
- `:clear_micro_block` — 清一个 micro slot,如果 cell 变空则降级 macro 为 empty

不引入 `:put_refined_slot` 等协议风格命名,降低认知成本。

### 决策 2:**v1 状态转换矩阵**

| 起始 macro mode | 操作 | 终止 mode | 注释 |
| --- | --- | --- | --- |
| empty | put_micro_block | refined | 新建 RefinedCellData,加一个 layer + 一个 mask bit |
| refined | put_micro_block | refined | 现有 cell 加 slot:layer 已存在 → mask 加 bit;否则新建 layer |
| refined | clear_micro_block | refined / empty | 移除 slot;若全部 layer mask 全空 → cell 删除 → header 改 empty |
| solid | put_micro_block | **rejected** (`:cannot_micro_edit_solid_macro`) | 1c v1 不支持 solid → refined 转换;留给 1c-bis |
| solid | clear_micro_block | **rejected** (同上) | |
| empty | clear_micro_block | empty (no-op) | 幂等 |

### 决策 3:**VoxelEditIntent (0x70) 到 Scene 操作映射**

| action | target_granularity | Scene 操作 |
| --- | --- | --- |
| Place (0) | Macro (0) | `:put_solid_block`(沿用 macro path) |
| Place (0) | Micro (1) | `:put_micro_block` |
| Break (1) | Macro (0) | `:break_block`(沿用 macro path) |
| Break (1) | Micro (1) | `:clear_micro_block` |
| Place (0) | ObjectPart (2) | rejected `:granularity_object_part_not_implemented` |
| Damage (2) / Replace (3) / AttributePatch (4) | * | rejected `:action_not_implemented` |

`expected_chunk_version` / `expected_cell_hash` 在 1c 实现 optimistic concurrency 拒绝路径(返 `Stale` result_code)。`face_normal` 用于 Place 时计算邻接位偏移(由 Gate 在 dispatch 时根据 face_normal 调整 target world micro,不在 Scene 内推断)。

### 决策 4:**CellRefined delta (delta_kind = 2) 用整 cell 重发,不做 layer-diff**

`ChunkDelta.ops[].payload` 在 `delta_kind = 2` 时承载完整 `RefinedCellData` 字节序列(reuse `Codec.encode_refined_cell_pool/1` 但只编一个 cell + 去掉 count u32 前缀的"单 cell" 形式;具体形式见 wire 设计 §5)。

理由:layer-diff 复杂度高,1c v1 不需要;一个 macro cell 满 layer + object_refs wire 也只有几百字节,网络代价可接受。1c 之后视性能再加 layer-diff opcode。

### 决策 5:**客户端 storage 类型分叉(在线 wire vs 离线 FRefinedCellData)**

在线模式:`OnlineVoxelWorldAdapter.placeMicroBlock` / `breakMicroBlock` 改为发 `VoxelEditIntent (0x70)`,然后从服务端接收 `CellRefined` delta 应用到 `WorldStore` 的"在线 truth 视图"(直接 keep `RefinedCellWireData[]`,**不**转回 `FRefinedCellData`)。

离线模式:`FRefinedCellData` 不动,本地写 confirmed truth 路径保持。

理由:wire 形是 layered occupancy(协议 §5.4),离线浏览器是 dense bitmap + parallel arrays;两者不可逆等价转换。在线模式下不经过离线 storage 是"server-authoritative 边界硬隔离"纪律的延续。

### 决策 6:**ChunkProcess.put_micro_block 的 face_normal 处理**

`face_normal` 由 **Gate dispatch 阶段**消费,而不是 Scene。Gate 收到 `(target_world_micro + face_normal, action=Place)` 后:

```
adjusted_target_world_micro = target_world_micro + face_normal  # 单个 micro slot 偏移
```

然后用 `adjusted_target_world_micro` 调用 ChunkDirectory.apply_intent。Scene 不知道 face_normal 存在,只接受最终 target。

理由:face_normal 是渲染坐标空间的"客户端命中面",物理含义在客户端 raycast 出结果时才完整;Scene 只关心 truth 坐标。这与 Minecraft / Source engine 等业界做法一致(client-side face hit → server-side resolved target)。

## 高层步骤

| Step | 范围 | 验收信号 |
| --- | --- | --- |
| 1c-1 | Scene `Storage.put_micro_block/clear_micro_block` + 单元测试 | Storage 单元测试通过,所有不变量(occupancy = OR(layer masks)、layer 合并、object_refs 不变)守住 |
| 1c-2 | ChunkProcess `:put_micro_block` / `:clear_micro_block` 操作 + intent 路由 + persist + delta emit | 现有 macro 路径不破回归;新 intent 写入后 chunk_hash 反映 refined truth |
| 1c-3 | `CellRefined` delta (delta_kind=2) wire encode/decode + ExUnit + Vitest | 双端 byte 一致,delta op payload 解码出 RefinedCellData |
| 1c-4 | Gate ws/tcp 把 typed VoxelEditIntent 路由到 ChunkDirectory + face_normal 偏移 | dispatch 集成测试覆盖 macro/micro 两条路径 |
| 1c-5 | Web client `OnlineVoxelWorldAdapter.placeMicroBlock/breakMicroBlock` 改发 0x70 + 接收 CellRefined delta | 在线模式真编辑可见;HUD `voxel_sync=server-authoritative` 反映 micro 路径 |
| 1c-6 | 加固:边界条件 + observe + 自查测试 | 与 1a/1b 加固一致的高标准(全字段越界 / 状态转换矩阵 / face_normal 偏移 / face_normal=(0,0,0) 退回原点等) |

## 验收

- mix test 全 umbrella 全绿(scene_server / gate_server / world_server 端到端 smoke 测试覆盖 micro 编辑)
- web_client tsc + vitest 全绿
- 共享 fixture(已有 refined_512_cell_v1.bin + 新增 cell_refined_delta_v1.bin)双端 byte 一致
- 在线 web_client 浏览器手测:左键命中 prefab 微格 → 只该 slot 消失;右键放 micro 块 → 只目标 slot 出现;F5 刷新后状态从服务端持久化恢复

## 风险

- **风险:web_client 在线 storage 类型分叉**会让 mesher / collision / debug 视图(目前都依赖 `FRefinedCellData` 形)在在线模式下不能直接复用。缓解:1c-5 加一个适配层 `RefinedCellWireData → FRefinedCellData` (lossy adapter,仅用于渲染消费,不写回 truth)。
- **风险:expected_chunk_version 处理与 lease/owner_epoch 保护交叉**。Scene 现有 `apply_intent` 已经做 lease 验证。1c 加 expected_chunk_version 检查需要在 lease 验证之后、storage 写入之前插入,需要确保两套 fence 顺序合理。
- **风险:CellRefined delta payload 大小**。一个 macro 满 layer 时 payload 可达几百字节;一帧多个 cell 同时改时 ChunkDelta 字节量大。1c v1 不优化(每 frame 不超 1-2 个 micro 编辑是常见场景);后续视实测决定是否引入 layer-diff。

## 进度日志

- 2026-05-07: **1c-6 加固落地**,scene_server 247 tests 不变(强化已有 solid → micro 用例),gate_server 176 → 181 tests, 0 failures。
  - **ChunkProcess 错误归一**:`build_intent_storage(:put_micro_block / :clear_micro_block)` 在 `Storage` 调用前先 `solid_cell?` 预检,直接返回 `:cannot_micro_edit_solid_macro`,不再被 `rescue ArgumentError` 吞成笼统的 `:invalid_voxel_intent`。客户端 UI 现在可以解释为什么右键命中 prefab(solid macro)的 micro 操作没生效。同步把 chunk_process 旧测试改为期望具体 reason,并补 clear_micro_block 路径的对称用例。
  - **Gate 加固测试**:`Phase 1c-6 hardening` describe 块覆盖:未知 `action` 码 → `:invalid_voxel_edit_intent`;未知 `target_granularity` 码 → `:invalid_voxel_edit_intent`;Place + Micro 时 `object_ref > u63 max` → `:invalid_object_ref`;Break 操作忽略 `face_normal`(决策 6:Break 不偏移),验证 clicked macro 被清空、+1 邻居仍空;Place + Micro 在 solid macro 上 → `:cannot_micro_edit_solid_macro` 端到端贯通。
- 2026-05-07: **1c-5 落地**(web client 解锁 micro 编辑 + 消费 CellRefined delta),web_client 206 → 210 tests, 0 failures;tsc clean;Elixir 测试不动。
  - **网络层**:`ServerVoxelTransportPort.sendVoxelEditIntent` + `ServerMovementTransport.sendVoxelEditIntent` 实现,落 `voxel.edit_intent_sent` observe。`OnlineVoxelWorldAdapter.placeMicroBlock` / `breakMicroBlock` 改用 typed 0x70(action=Place/Break,granularity=Micro,face_normal=(0,0,0))。 micro_slot 从 `(macro × 8 + micro)` world-micro 计算,服务端用 face_normal=0 直接 floor 命中目标 slot(决策 6)。
  - **Delta 消费**:`VoxelChunkDeltaOp.refinedCell?: RefinedCellWireData` 字段在 `decodeChunkDelta` 中按 `delta_kind=2` 预解码。`OnlineVoxelWorldAdapter.applyDelta` 加 `delta_kind=2` 分支:wire → FRefinedCellData(经 `wireToRefinedCell` lossy adapter)→ `ChunkStorage.applyRefinedCellFromWire`,正确处理 Empty/SolidBlock/Refined 三态转换。`applySnapshot` 同样把 `refinedCellsWire` materialize 进 `storage.refinedCells`,使 reload 后 refined macro 渲染一致。
  - **决策 5 RFC**:1c-5 暂时偏离"wire-form 唯一 truth"。`ChunkStorage.refinedCells` 仍持 `FRefinedCellData`,wire form 在 snapshot/delta 应用时 lossy 转入。理由:mesher / collision / 调试视图全依赖 `FRefinedCellData`,纯 wire-form storage 是更大的重构,留给 1d 或 Phase 3。lossy 损失:`tagSetRef` / `attributeSetRef` / `ownerObjectId` / `objectRefs` / 完整 `boundaryCache` u64 全被 narrow 或 drop;不影响渲染,影响 provenance(Phase 4 主题)。
  - **HUD / CLI**:`OnlineVoxelWorldAdapter.debugSnapshot` 加 `totalSolidBlocks` / `totalRefinedCells`(由 `ChunkStorage.countRefinedCells` + `WorldStore.totalRefinedCells` 支撑),`voxelDebugPanelView` 加 `cells: solid=N refined=M` 行。CLI `micro_place` / `micro_break` 命令新接 `WorldEditController.placeMicroAt` / `breakMicroAt`(发 `world:micro-placed` / `world:micro-broken` bus 事件)。
  - **测试**:`OnlineVoxelWorldAdapter#placeMicroBlock / #breakMicroBlock` 3 例(action × granularity 字段、target_world_micro 计算、transport 不可用回退);`wireToRefinedCell` 4 例(空 cell、occupancyWords 拼接、layered mask 解出 per-slot material/state/partId、boundaryCache narrowing);`devToolsCli` 原 `unknown_command` 用例改为 micro_place / micro_break 真接 edit controller。
- 2026-05-07: **1c-4 落地**(Gate dispatch typed VoxelEditIntent → ChunkDirectory),scene_server 241 → 247 tests, 0 failures;gate_server 170 → 176 tests, 0 failures;web_client 不动 203 tests。
  - **ChunkProcess optimistic concurrency**:`normalize_apply_intent` 提取 `expected_chunk_version` / `expected_cell_hash`,wire sentinel(`0xFF...FF` / `0xFFFF_FFFF`)在 ChunkProcess 内归一为 `nil = skip`;`apply_normalized_intent` 在 `validate_intent_scope` 之后、`build_intent_storage` 之前插入 `validate_intent_preconditions`,不匹配返 `:stale_chunk_version` / `:stale_cell_hash`。+6 ExUnit。
  - **Gate dispatch (ws + tcp)**:`:voxel_edit_intent` 从 1b observe-only 改为真路由。`(action × target_granularity) → operation` 按 [决策 3] 映射;Place + ObjectPart → reject `:granularity_object_part_not_implemented`;Damage / Replace / AttributePatch (任意 granularity) → reject `:action_not_implemented`。Place 时 `face_normal` 在 Gate 阶段消费(决策 6):`adjusted_target_world_micro = target_world_micro + face_normal × 1`,Scene 不知 `face_normal`。Break 忽略 `face_normal`。`expected_chunk_version` / `expected_cell_hash` 透传给 ChunkDirectory.apply_intent。`VoxelIntentResult (0x68)` 不再静默:成功回 Accepted (0,result_ref=chunk_version),`:stale_*` 映 Stale (3),其他映 Rejected (2)。observe payload 保留 1b 全部字段 + `client_hint_hash`。
  - **测试**:gate_server `ws_connection_voxel_test` 删除 1b 三条 observe-only 用例,新增 `Phase 1c — VoxelEditIntent (0x70) routing` describe 块覆盖:invalid_state(out-of-scene reject + observe)、world_unavailable、Place+Macro 端到端持久化 + observe routed/applied、Place+Micro 写 refined cell、face_normal 偏移真实改变 macro 命中、Place+ObjectPart 拒绝、Damage 拒绝、Stale chunk_version、Break+Micro 清除目标 slot 保留兄弟 slot。
- 2026-05-07: **1c-1 + 1c-2 + 1c-3 落地**(server-side vertical slice),scene_server 202 → 241 tests, 0 failures;web_client 197 → 203 tests, 0 failures;gate_server 不动 170 tests。
  - **1c-1**:`Storage.put_micro_block/4` + `clear_micro_block/3` + `refined_cell_at/2`。empty ↔ refined 状态转换;layer 自动按 attribute_signature 合并;ghost layer 自动移除;orphan 池保留(与 macro `clear_macro_cell/3` 一致 compaction 策略);solid macro 拒绝 `:cannot_micro_edit_solid_macro`;重复 put 拒绝 `:micro_slot_already_occupied`;0..511 边界完整覆盖。+21 ExUnit。
  - **1c-2**:`ChunkProcess.normalize_operation` 接受 `:put_micro_block` / `:clear_micro_block`;intent map 加 `micro_slot` / `micro_layer` 字段;`build_intent_storage` 单 intent + batch 两条路径;batch 路径在已占用 slot 上幂等 skip(与 `:put_solid_block` batch 一致),单 intent 路径 surface error;`micro_slot_occupied?` helper。+8 ExUnit(集成测试,真 ChunkProcess + ChunkSnapshotStore)。
  - **1c-3**:`Codec.encode_refined_cell_payload/1` + `decode_refined_cell_payload(_!)/1`(标准 dual-form),wire 是单 cell payload 形式(无 count u32 前缀),与 `encode_refined_cell_pool([cell])` 去掉前 4 字节字节级一致。`build_intent_delta_op/2` 签名改接 state_after,新增:
    - `:put_micro_block` → ChunkDelta op `delta_kind = 2 (CellRefined)`,payload 是单 cell。
    - `:clear_micro_block` 在最后 slot 后下沉为 `:empty` macro 时 emit `delta_kind = 0 (CellEmpty)`(与 break_block 同形);否则 emit `delta_kind = 2`(残余 cell)。
    - 现有 `:put_solid_block` / `:break_block` 行为通过签名重构(state_after 替代 new_chunk_version),不变。
    - TS `refinedCellWire.ts` 加 `decodeRefinedCellPayload` / `encodeRefinedCellPayload`;Vitest +6 用例。
    - 共享 fixture `cell_refined_delta_v1.bin`(336 bytes,双层 + 一个 ObjectCoverRef),Elixir + TS 双端 decode 字段一致 + encode 回写 byte-for-byte 等于 fixture。Codec 测试 +8 用例(roundtrip / pool-vs-payload byte 等价 / trailing reject / truncated reject / fixture decode / fixture stale 兜底)。
  - 客户端**还**没有解锁(留 1c-5);Gate 仍 observe-only(留 1c-4)。但服务端 vertical slice 已闭环:从 typed `apply_intent` 到 chunk_hash 持久化到 ChunkDelta wire 全部在测试中端到端验证。
- 2026-05-07: 计划稿成稿。决策 1-6 按推荐值定稿。
