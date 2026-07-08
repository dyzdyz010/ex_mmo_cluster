# Phase 1.6: snapshot / delta golden fixtures + web_client TS decoder — 设计草案

状态：设计稿，等 Phase 1.4 落地后开 commit
日期：2026-05-13
归属：goal `voxel-authoritative-and-field-minimum` Phase 1.6
真相源：
- Phase 1.2 commit `251b5b4`（AttributeSet typed domain + section 0x04）
- Phase 1.3 commit `af376fd`（TagSet typed domain + section 0x05）
- Phase 1.4（CatalogPatch envelope, opcode 0x71 — 进行中）
- `clients/web_client/src/infrastructure/net/voxelProtocol.ts`（snapshot decoder 现状）
- `clients/web_client/src/voxel/wireToRefinedCell.ts`（lossy adapter，目前 drop attributeSetRef/tagSetRef）
- `clients/web_client/src/infrastructure/net/refinedCellWire.ts`（refined cell wire shape）

跨仓决策：2026-05-13 web_client 解冻（commit `678a028` + `2d754b3`）

---

## 1. 目标

完成 Phase 1 验收口径的**最后两条**：

1. **服务端 golden binary fixtures**：覆盖 macro / refined / environment / attribute / tag refs 的完整 snapshot 与 delta，作为客户端解码 + 跨语言互操作的字节级真相源。
2. **web_client TS decoder + roundtrip 与服务端 hash 等值**：当前 voxelProtocol.ts 已经能解 macro / refined / environment / object_refs，但 AttributeSets / TagSets 走 `ensureEmptyPool`（与 Phase 1.2/1.3 服务端 wire 不匹配），且 wireToRefinedCell.ts 显式 drop attributeSetRef / tagSetRef。

---

## 2. 范围

### 2.1 服务端 golden fixtures（ex_mmo_cluster）

新建 `apps/scene_server/test/scene_server/voxel/fixtures/`（若已存在则补 attribute/tag pool 覆盖）：

- `snapshot_empty.golden` —— 空 chunk 的完整 wire payload
- `snapshot_macro_only.golden` —— 含 macro solid blocks
- `snapshot_refined.golden` —— 含 refined cells（含 owner_object_id / owner_part_id）
- `snapshot_environment.golden` —— 含 macro_environment_summaries（non-default temperature / moisture）
- `snapshot_attribute_pool.golden` —— 含非空 attribute_sets pool（5 类 value_type 各一个）
- `snapshot_tag_pool.golden` —— 含非空 tag_sets pool
- `snapshot_full.golden` —— 全 section 满载
- `delta_cell_solid.golden` —— delta_kind=1
- `delta_cell_empty.golden` —— delta_kind=0
- `delta_cell_refined.golden` —— delta_kind=2
- `catalog_patch_attribute_add.golden` —— Phase 1.4 envelope
- `catalog_patch_tag_remove.golden` —— Phase 1.4 envelope
- `catalog_patch_forward_compat_skip.golden` —— 含 unknown op_kind 的 op

每份 fixture 配 `chunk_hash` / `wire_size` / `description` 元数据（YAML/JSON 旁注），让客户端 fixture loader 能验证 hash 等值。

### 2.2 web_client TS decoder（clients/web_client/）

修改 `clients/web_client/src/infrastructure/net/voxelProtocol.ts`：
- **替换** `ensureEmptyPool(SnapshotSection.AttributeSets, ...)` 为 `decodeAttributeSetPool(...)`（line 581-582）
- **替换** `ensureEmptyPool(SnapshotSection.TagSets, ...)` 为 `decodeTagSetPool(...)`（line 581-582）
- 新增 `decodeAttributeSetPool` 函数：按 Phase 1.2 wire layout 解 `set_count: u32 / sets[].entry_count: u16 / entries[].(key_id: u32, value_type: u8, value: tagged_union)`，输出 `AttributeSet[]`
- 新增 `decodeTagSetPool` 函数：按 Phase 1.3 wire layout 解 `set_count: u32 / sets[].tag_count: u16 / tag_ids[]: u32`，输出 `TagSet[]`
- 新增 CatalogPatch decoder（opcode 0x71）：按 Phase 1.4 envelope 解，op payload 保持 `Uint8Array`

新建 `clients/web_client/src/voxel/attributeSet.ts` / `tagSet.ts` / `catalogPatch.ts`（typed shape + decoder）

修改 `clients/web_client/src/voxel/wireToRefinedCell.ts`：
- **不再 drop** attributeSetRef / tagSetRef / ownerObjectId（line 10-13 注释更新）
- `FRefinedCellData` 新增 `attributeSetRefsBySlot: Uint32Array` / `tagSetRefsBySlot: Uint32Array` / `ownerObjectIdsBySlot: BigUint64Array`（与 microPartIds 同款 slot-level 数组）
- 修改 `clients/web_client/src/voxel/storage/types.ts` 中 `FRefinedCellData` 类型

新建测试：
- `clients/web_client/src/voxel/attributeSet.test.ts`
- `clients/web_client/src/voxel/tagSet.test.ts`
- `clients/web_client/src/voxel/catalogPatch.test.ts`
- `clients/web_client/src/voxel/wireToRefinedCell.test.ts` 更新（不再 drop refs）
- `clients/web_client/src/infrastructure/net/voxelProtocol.test.ts` 更新（attribute / tag pool roundtrip + chunk_hash 等值）

测试加载服务端生成的 golden binary fixtures，验证：
- decode 后结构与服务端 `Storage` 等值
- 重新 encode（如需）byte 等值
- chunk_hash 与服务端 `chunk_hash` 字段相等

### 2.3 不做（保留为 Phase 6 / Phase 2.5 工作）

- 不实现 web_client 端 attribute / tag pool 的写入路径（catalog 写入是 Phase 5 工作）
- 不接 web_client UI 显示 attribute / tag 值（Phase 6 debug overlay）
- 不接 wireToRefinedCell.ts 之后的 renderer / mesher 路径消费 attributeSetRef（Phase 6 客户端 wire-form-as-truth）

---

## 3. 实施顺序

依赖：Phase 1.4 落地（CatalogPatch envelope 必须存在才能写 catalog_patch_*.golden fixture）。

1. ex_mmo_cluster 端：写 `fixtures/` 生成脚本（参考已有 `apps/gate_server/priv/scripts/gen_voxel_edit_intent_fixture.exs`）
2. 生成 12+ 个 golden binary fixtures（参考 §2.1 清单）
3. ExUnit 加载 fixture 做 roundtrip 校验（服务端测试，与 Phase 1.2/1.3 现有 codec_test.exs 整合）
4. **commit `phase1.6a: snapshot/delta golden fixtures (server-side)`**（ex_mmo_cluster）
5. web_client 端：参照 fixture 写 TS decoder
6. web_client jest 测试加载同一份 fixture roundtrip
7. **commit `phase1.6b: web_client TS decoder + roundtrip (per 2026-05-13 web_client thaw)`**（ex_mmo_cluster；clients/web_client 是 ex_mmo_cluster 仓内目录）

两个 commit 在同一 Phase 子项（1.6）下，但 a/b 分仓口径（服务端 vs 客户端）独立。也可合并单 commit，按 executor 子代理实际工作量决定。

---

## 4. 客户端 Phase 1.6 测试 baseline

当前 `clients/web_client/src/infrastructure/net/voxelProtocol.test.ts` 是否还能跑？2026-04-26 后冻结期间是否 drift？

下轮起手 Phase 1.6 前应先：
- `cd ex_mmo_cluster/clients/web_client && npm test` 看现有测试通过率
- 如果有 drift（很可能有），先做 "phase1.6 pre: web_client test baseline restore" 单 commit 修通现有测试，再开 1.6 实质

这条 baseline check 是 Phase 1.6 实质开工前的必做步骤。

---

## 5. 决策点

> **决策点 G-1**：fixture 文件格式
> - (a) **`.golden` 纯 binary**（推荐，最紧凑，按字节比对）+ 旁路 `.yaml` 元数据（hash / size / description）
> - (b) `.golden.hex` ASCII hex + 内嵌元数据注释（更易读，但需要 hex → binary 反解步骤）

> **决策点 G-2**：fixture 数量
> - (a) **12+ fixtures（推荐）**：每个主要 section + delta_kind + 组合用例
> - (b) 6 fixtures（最小集）：仅 empty / macro / refined / attribute / tag / full
> - (c) 24+ fixtures：覆盖所有边界

> **决策点 G-3**：web_client `FRefinedCellData` 是否一并扩展 attributeSetRefsBySlot / tagSetRefsBySlot
> - (a) **是（推荐）**：与 microPartIds 同款 slot-level 数组，下游 renderer / mesher 后续按需消费
> - (b) 只解 wire 不存 FRefinedCellData：仅保证 Phase 1.6 验收（decoder roundtrip），不暴露给 renderer 上层 — 推到 Phase 6 再做

---

## 6. 风险

- **web_client 协议漂移**：2026-04-26 冻结至 2026-05-13 期间，服务端协议演进（Phase A1 / 4-bis / A4 等）web_client 未跟上。Phase 1.6 实质开工前必须先做 npm test baseline restore。
- **fixture 生成不确定性**：fixture 中 chunk_hash 依赖排序、定点数精度等多个细节。生成脚本必须 deterministic。
- **value tagged union TS 端类型**：Phase 1.2 D-3 的 5 类 value_type 在 TS 端如何表达（discriminated union？bigint vs number？fixed32 是否在 TS 端做 Q16.16 ↔ float 自动转换？）。Phase 1.6a commit 前应在 attributeSet.ts 草案中决定。
- **commit 拆分**：1.6a 服务端 + 1.6b 客户端是两个独立 commit 还是一个？建议两个，便于 verifier 分别审。
