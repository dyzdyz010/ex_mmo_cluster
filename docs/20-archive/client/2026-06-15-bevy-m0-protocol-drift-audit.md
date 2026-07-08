# M0 协议 drift 审计 — bevy_client vs 当前服务器 codec（2026-06-15）

- **状态**：完成（地基优先路径 M0 产出，驱动 M1）
- **方法**：3 路只读 Explore agent 并行盘点（服务器控制面 codec / 服务器体素 codec / bevy 覆盖），关键 drift 由我**直接读码核验**（不轻信 agent 单方结论）。
- **审计对象**：`apps/gate_server/lib/gate_server/codec.ex`、`apps/scene_server/lib/scene_server/voxel/codec.ex`、`apps/scene_server/lib/scene_server/voxel/field/field_codec.ex`、`apps/scene_server/lib/scene_server/voxel/catalog_patch.ex`、`docs/2026-04-10-线协议规范.md` vs `clients/bevy_client/src/protocol.rs`、`movement_codec.rs`、`net/runtime.rs`。
- 上游决策稿：`docs/2026-06-15-bevy-client-mainline-architecture.md`。

---

## 0. 摘要

- **框架/编码**：4 字节大端长度前缀（TCP `{packet,4}`）+ 1 字节 msg_type + 载荷；整数大端、f64 大端、string=`u16 len + UTF-8`。**一个端序例外**见 §3.4。
- **控制面（C→S 0x01–0x09 / S→C 0x80–0x8F）**：bevy **覆盖完整**，且 `expected_seq`（B-S1）、`fixed_dt_ms`（B-M2）已对齐。**唯一 drift = `MovementAck(0x8B)` 缺 `ground_z`**——经核验是**字段被静默丢弃**（非帧错位/掉线，见 §1），低危但应修。
- **体素面（0x60–0x75）**：bevy **覆盖 0**——整族未实现。这是 M1 的主体（决策稿 §2 已预期）。
- **golden fixtures 齐备**（`apps/scene_server/priv/fixtures/voxel/*.golden`）：snapshot/delta/invalidate/object-state-delta/catalog-patch 全覆盖 → 直接喂 bevy 跨语言 round-trip parity 测试。

---

## 1. 控制面 drift（小、先修）

### MovementAck(0x8B) 缺 `ground_z`
- **服务器**（`gate_server/codec.ex:449–458`）：`MovementAck` body 现为 **103 字节**，尾部新增 `ground_z::float-64-big`（在 `fixed_dt_ms::16-big` 之后）。
- **bevy**（`protocol.rs:219–232`）：`require_body_len(body, 95)` 后读到 `server_fixed_dt_ms`（offset 93）为止，**不读 `ground_z`**。
- **核验结论（纠正 agent 夸大说法）**：`require_body_len` 是**最小长度检查**（`protocol.rs:523`：`body.len() < expected_min`），且 `{packet,4}` 帧长自带——故 103B body **通过** `>=95` 检查，bevy 正常解出 MovementAck，**只是静默忽略尾部 8 字节 `ground_z`**。**不会**帧错位/掉线。
- **真实影响**：bevy 拿不到服务器权威 ground 接触高度 → **跳跃/落地校验（A1 D5 jump ground_z）降级**；移动 reconcile 核心不受影响。
- **修法**（M1 step 1，独立小 commit）：bevy `MovementAck` 加 `ground_z: f64`，offset 95 读 f64，`require_body_len` 95→103；接 `sim`/jump 逻辑。

> 其余控制面：`EnterSceneResult.expected_seq`（0x84，B-S1）、`MovementAck.fixed_dt_ms`（B-M2）bevy 均已对齐（`protocol.rs:260–282 / 219–232`，runtime 已消费）。`PlayerMove(0x83)` priority 扩展为可选尾部，bevy 读 85B 最小帧——需复核服务器是否发扩展段（次要）。

---

## 2. 体素面 gap（M1 主体）：bevy 覆盖 = 0

| opcode | 方向 | 名称 | bevy | M1 优先级 | 服务器编码位置 |
|---|---|---|---|---|---|
| 0x60 | C→S | ChunkSubscribe | ✗ | **P0**（摄入前提） | `gate codec.ex:225` |
| 0x61 | C→S | ChunkUnsubscribe | ✗ | P1 | `gate codec.ex:251` |
| 0x62 | S→C | **ChunkSnapshot** | ✗ | **P0** | `voxel/codec.ex:54`（TLV 段） |
| 0x63 | S→C | **ChunkDelta** | ✗ | **P0** | `voxel/codec.ex:141` |
| 0x68 | S→C | VoxelIntentResult | ✗ | P0（编辑回执） | `gate codec.ex:609` |
| 0x69 | S→C | ChunkInvalidate | ✗ | **P0** | `voxel/codec.ex:229` |
| 0x6C | S→C | ObjectStateDelta | ✗ | P1（debris/part） | `voxel/codec.ex:302` |
| 0x71 | S→C | CatalogPatch | ✗ | P1（forward-compat） | `catalog_patch.ex:160`（⚠ gate 未转发，见 §4） |
| 0x72 | S→C | EnvironmentUpdated | ✗ | P2 | `voxel/codec.ex:479`（⚠ gate 未转发） |
| 0x73 | S→C | **FieldRegionSnapshot** | ✗ | P1（电/热/电离渲染） | `field_codec.ex:45`（⚠ f32 小端，见 §3.4） |
| 0x74 | S→C | FieldRegionDestroyed | ✗ | P1 | `field_codec.ex:46` |
| 0x64 | C→S | VoxelImpactIntent（弃用） | ✗ | —（用 0x70） | `gate codec.ex:275` |
| 0x65 | C→S | BuildReservationIntent | ✗ | M4/M5 | scene 委托解码 |
| 0x67 | C→S | PrefabPlaceIntent | ✗ | M4 | scene 委托解码 |
| 0x6F | both | VoxelDebugProbe | ✗ | 调试用 | `gate codec.ex:314` |
| 0x70 | C→S | **VoxelEditIntent** | ✗ | M4（编辑） | `gate codec.ex:326`（92B） |
| 0x75 | C→S | FieldConductIntent | ✗ | M5（电/导通） | `gate codec.ex:357`（power_flags 变长） |

> **M1 解码必需（S→C）**：0x62 / 0x63 / 0x69（+ 0x68 回执）= 体素世界同步最小集。0x6C / 0x73 / 0x74 紧随（gameplay 渲染）。编辑类 C→S（0x70/0x67/0x75）推到 M4/M5。

---

## 3. 快照/增量字节布局（M1 decoder 蓝图，镜像 `voxel/codec.ex`）

### 3.1 ChunkSnapshot (0x62)
头 50B：`request_id u64 | logical_scene_id u64 | chunk_coord i32×3 | schema_version u16 | chunk_size_in_macro u8(=16) | micro_resolution u8(=8) | chunk_version u64 | chunk_hash u64 | section_count u16`；随后 `section_count` 个 **TLV 段**（`type u8 | len u32 | data`）：
- **0x01 MacroHeaders**：4096 × 19B = `mode u8(0空/1实/2精) | flags u16 | payload_index u32 | environment_index u32 | cell_version u32 | cell_hash u32`。
- **0x02 NormalBlocks**：`u32 count` + 每 20B = `material_id u16 | state_flags u32 | health u16 | temp_delta i16 | moist_delta i16 | attr_set_ref u32 | tag_set_ref u32`。
- **0x03 RefinedCells**：`u32 count` + 每 cell：`occupancy u64×8(64B) | boundary_cache u64 | layer_count u16 | layers[] | obj_ref_count u16 | object_refs[]`；layer=`mask u64×8 | material_id u16 | state_flags u32 | health u16 | attr_set_ref u32 | tag_set_ref u32 | owner_object_id u64 | owner_part_id u32`(140B)；object_ref=`owner_object_id u64 | owner_part_id u32 | mask u64×8`(104B)。**直接消费 wire form，勿抄 web lossy 桥。**
- **0x04 AttributeSets** / **0x05 TagSets**：`u32 count` + 每 set 变长（空池 = `<<0::u32>>`）。
- **0x06 EnvironmentSummaries**：`u32 count` + 每 14B。
- **0x07 ObjectRefs**：`u32 count` + 每 30B。
- **chunk_hash**：对规范化 truth 载荷的哈希；decoder 应校验（`voxel/codec.ex:1019`）。

### 3.2 ChunkDelta (0x63)
头 39B：`logical_scene_id u64 | chunk_coord i32×3 | base_chunk_version u64 | new_chunk_version u64 | op_count u16`；每 op：`delta_kind u8 | macro_index u16 | cell_version u32 | cell_hash u32 | payload_len u16 | payload`。`delta_kind`：0=CellEmpty(len 0)、1=CellSolid(20B NormalBlock)、2=CellRefined(变长)、≥3 opaque 跳过（forward-compat）。**版本链**：`base==client 当前 chunk_version` 否则请求 invalidate/resync。

### 3.3 ChunkInvalidate (0x69)
21B：`logical_scene_id u64 | chunk_coord i32×3 | reason u8`（0 未指定 / 1 迁移切换 / 2 region 移除 / 3 catalog 变；≥4 数字 round-trip）。

### 3.4 端序例外 ⚠ FieldRegionSnapshot (0x73)
整协议大端，**唯一例外**：`field_codec.ex` 的 field 值数组用 **little-endian f32**。布局（opcode 在载荷内）：`0x73 | logical_scene_id u64 | chunk_coord i32×3 | region_id u64 | tick_count u32 | field_mask u8 | cell_count u16 | macro_indices u16×n(升序) | temperature f32×n(LE, iff 0x01) | electric_potential f32×n(LE, iff 0x02) | electric_current f32×n(LE, iff 0x08) | ionization u8×n(iff 0x04)`。**bevy decoder 必须对这段特判小端**——这正是 R1–R8 服务器侧产出的电/热/电离场数据，是 bevy 渲染 fields 的来源。0x74 FieldRegionDestroyed 26B 同样 opcode-in-payload。

---

## 4. 目录同步现状（M1 需知）
- **0x71 CatalogPatch**（attribute/tag 增量，versioned op list，未知 op_kind/payload 存 opaque）：scene 有 producer（`catalog_patch.ex`），但 **gate codec 尚未转发**（Phase 5 pending）。**0x72 EnvironmentUpdated** 同样 scene 有、gate 未转发。→ M1 decoder 应写好（forward-compat），但**运行时可能暂不到达**；material id 暂硬编码 1–10（dirt/stone/wood/ice/iron/power_block/electric_load/water/steam/ash）。
- **0x6D TagCatalogSnapshot / 0x6E AttributeCatalogSnapshot**：spec 有、未实现——cold-start 全量目录，后续 Phase。

---

## 5. golden fixtures（parity 测试，已存在）
`apps/scene_server/priv/fixtures/voxel/`（每个 `.golden` + `.yaml` sidecar）：
- snapshot：`snapshot_{empty,macro_only,attribute_pool,tag_pool,environment,object_refs,refined,full}`
- delta：`delta_{cell_empty,cell_solid,cell_refined,multi_op}`
- invalidate：`chunk_invalidate_{unspecified,migration_cutover,region_removed,catalog_changed}`
- object-state-delta：`object_state_delta_{damaged,destroyed,part_destroyed}`
- catalog-patch：`catalog_patch_{attribute_add,tag_remove,forward_compat_skip}`

→ bevy `tests/` 加 Rust integration 测试：读 `.golden` → decode → 断言结构字段（对 `.yaml`）→ re-encode → 断言字节相等。**最高杠杆借鉴**，使 bevy 成一等 parity target。

---

## 6. M1 拆分（commit 粒度，地基优先；渲染先沿用现 naive 验证端到端）
1. **修 MovementAck `ground_z`**（控制面 drift，独立小 commit，解 jump/ground 降级）。
2. **voxel opcode 表 + framing dispatch**（net 加体素消息路由，0x62/0x63/0x69/0x68 进 `ServerMessage`）。
3. **ChunkSnapshot decoder + golden parity**（TLV 段 0x01–0x07，refined wire form 直消费；`snapshot_*` fixtures）。
4. **ChunkDelta decoder + golden parity**（delta_kind 0/1/2 + 版本链；`delta_*`）。
5. **ChunkInvalidate + VoxelIntentResult decoder**（+ `chunk_invalidate_*`）。
6. **CatalogPatch + EnvironmentUpdated decoder**（forward-compat opaque；+ `catalog_patch_*`；运行时可能暂不到达）。
7. **FieldRegionSnapshot/Destroyed decoder**（**小端 f32 特判**）。
8. **ChunkSubscribe 编码 + `VoxelAuthorityPlugin` 摄入**：VoxelWorld 从空起、version-gated delta、编辑=intent；渲染暂用现 naive `sync_voxel_visuals` 验证端到端（看到服务器体素出现/更新）。

→ 完成后进 **M2**（chunk meshing 重写：exposed-face + 索引 quad + texture array + 异步 dirty remesh）。

---

## 7. 关键提醒
- 体素消息**经 gate 转发**：`gate codec.ex` 对 0x62 全编码，对 0x63/0x69/0x6C 二进制透传（opcode 前缀）；0x73/0x74 **opcode 在载荷内**经 `send_frame/2` 直发。bevy decoder 须按各自方式 dispatch。
- 协议纪律：只追加字段、不破 wire layout；bevy 新增 decoder 须过 golden 字节序验收（CLAUDE.md 客户端策略已改为 bevy 口径）。
- 本审计**未改任何代码**；M1 step 1（MovementAck）起进入实现。
