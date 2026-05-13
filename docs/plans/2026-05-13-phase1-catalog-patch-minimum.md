# Phase 1.4: CatalogPatch 最小类型 — 设计草案

状态：设计稿，等 Phase 1.2 / 1.3 落地后细化 + 用户复核 §3 / §5 决策点
日期：2026-05-13
归属：goal `voxel-authoritative-and-field-minimum` Phase 1.4
姊妹草案：
- `2026-05-13-phase1-attribute-set-typed-domain.md`
- `2026-05-13-phase1-tag-set-typed-domain.md`

---

## 1. 目标（严格 Phase 1 范围）

为 attribute / tag catalog 提供**最小可演进的 patch 类型**，能表达 `{add / remove / update}` 三类 op。**不实现 catalog 自身**（catalog 即 `AttributeCatalogSnapshot` 是 Phase 5 工作）。

为什么 Phase 1 需要 CatalogPatch？
- Phase 1 验收口径要求 "snapshot / delta golden fixtures，覆盖 macro / refined / environment / attribute / tag refs"。
- delta 段 `CatalogPatch` 是 wire 上传播 catalog 变更的载体（Phase 5 才使用，但 wire 类型 v1 必须在 Phase 1 冻结）。
- 协议规范 line 243 已预留 opcode `0x6E = AttributeCatalogSnapshot` / `0x6D = TagCatalogSnapshot`，patch 应在同一编码族内追加。

---

## 2. 概念模型

CatalogPatch 是面向**未来 catalog 升级**的 wire 载体，**不要求 Phase 1.4 实施时绑定具体 catalog schema**。

```text
CatalogPatch {
  schema_kind: u8          // 0x01 = attribute, 0x02 = tag, 其他 reserved
  base_version: u64        // patch 适用的 catalog 基线版本
  new_version: u64         // patch 完成后的 catalog 新版本
  op_count: u16
  ops[op_count] {
    op_kind: u8            // 0x01 = add, 0x02 = remove, 0x03 = update, 其他 reserved
    entry_id: u32          // attribute_id / tag_id
    payload_len: u16       // forward-compat: 让 decoder skip unknown op_kind
    payload: bytes(payload_len)   // 由 op_kind + schema_kind 共同解释
  }
}
```

关键设计原则：
- **payload_len 在 op header**：与 `encode_chunk_delta_payload` 现有 `delta_kind` op 同款，让 decoder 在 Phase 1.4 不实现具体 payload 解码时仍能"forward-compat skip"
- Phase 1.4 v1 只要求 wire 框架立起来，**payload 内容**Phase 5 落地时再定（届时 `op_kind = 0x01 add` 的 payload 就是 `AttributeDefinition` 序列化）

---

## 3. Phase 1.4 范围 vs Phase 5 范围

| Phase 1.4 范围 | Phase 5 范围 |
|---|---|
| `CatalogPatch` envelope encode / decode | `AttributeDefinition` payload schema |
| op header 框架（op_kind / entry_id / payload_len） | op payload 内容（add 时的 AttributeDefinition、update 时的字段集） |
| forward-compat skip unknown op | catalog version monotonic 推进 |
| `apps/scene_server/lib/scene_server/voxel/catalog_patch.ex` envelope module | `apps/scene_server/lib/scene_server/voxel/attribute_catalog_snapshot.ex` |
| **不**新增 opcode（envelope 走 chunk_delta op 通道或独立 opcode 待定，见 §5） | opcode `0x6E` / `0x6D` 实现 |

---

## 4. wire layout（一旦发出即冻结）

### 4.1 CatalogPatch envelope

```text
CatalogPatch (envelope)
  schema_kind: u8
  base_version: u64
  new_version: u64
  op_count: u16
  ops[op_count] {
    op_kind: u8
    entry_id: u32
    payload_len: u16
    payload: bytes(payload_len)
  }
```

**Op header fixed size**：`1 + 4 + 2 = 7 bytes`。
**Envelope fixed size**：`1 + 8 + 8 + 2 = 19 bytes`。

### 4.2 Phase 1.4 v1 不解释 payload 字节

Phase 1.4 实现的 `CatalogPatch.decode_op/1` 返回：
```elixir
%{op_kind: 0x01, entry_id: 42, payload: <<...bytes...>>}
```
即 payload 保持 raw binary。**Phase 5 落地时**新增 `AttributeDefinition.decode_payload/1` 等模块来解释 raw payload。

---

## 5. 传输通道（Phase 1.4 需用户拍板）

> **决策点 P-1（用户确认）**：CatalogPatch 走哪种 wire 通道？候选：
> - (a) **新增独立 opcode**（推荐，与 ChunkDelta 解耦，Phase 5 `0x6E AttributeCatalogSnapshot` 是全量快照，patch 用新 opcode 如 `0x6F`）
> - (b) 复用 ChunkDelta op 通道（在 chunk_delta 协议里加新 `delta_kind = 6 CatalogPatch`）—— 缺点：catalog 不属于 chunk-local 状态，硬塞进 chunk delta 语义不清
> - (c) 完全推迟到 Phase 5（Phase 1.4 只实现 envelope 内存结构 + golden fixture，不发出 wire payload）—— 优点：把 wire 决策推到 Phase 5；缺点：Phase 1.6 golden fixture 不含 CatalogPatch

> **决策点 P-2（用户确认）**：CatalogPatch envelope 是否含 `transaction_id` / `actor_id` 等 provenance？候选：
> - (a) **不含**（推荐，Phase 1.4 envelope 最小化；catalog 变更由 World transaction 路径在 wire 之外携带 metadata）
> - (b) 含 `request_id: u64`（与 `BuildReservationIntent` 等其他协议一致）

---

## 6. Elixir 模块结构

```text
apps/scene_server/lib/scene_server/voxel/
└── catalog_patch.ex            # %SceneServer.Voxel.CatalogPatch{schema_kind, base_version, new_version, ops}
```

ops 在 v1 是 `[%{op_kind, entry_id, payload}]`（保持 map，等 Phase 5 落地后升级为 typed `CatalogPatchOp` struct）。

> **决策点 P-3（用户确认）**：op 是否在 Phase 1.4 就 typed？候选：
> - (a) **保持 map**（推荐，Phase 1.4 减少类型耦合）
> - (b) typed struct `CatalogPatchOp`（Phase 1.4 即引入，Phase 5 在其内部扩展 payload typing）

---

## 7. Test plan（TDD）

新建 `apps/scene_server/test/scene_server/voxel/catalog_patch_test.exs`：

1. envelope encode / decode roundtrip（含 0 op / 1 op / 多 op）
2. forward-compat skip：encode 含 unknown op_kind = 0xFE 的 op；decode 后该 op `op_kind = 0xFE`、`payload` 保留为 raw binary
3. forward-compat skip：encode 含 unknown schema_kind = 0xFE；decode 拒绝（schema_kind 是 envelope 级，未知值是硬错误）
4. base_version > new_version 校验（normalize! raises）
5. golden fixture：固定字节序列与 decoded 结构等值

---

## 8. 客户端（web_client）回路

Phase 1.6 时在 `clients/web_client/src/voxel/` 新增 `catalogPatch.ts`：
- envelope decoder
- raw payload 保持 `Uint8Array`
- 与服务端 wire roundtrip

---

## 9. 实施顺序

依赖：Phase 1.2 + 1.3 落地（验证 wire layout 设计模式可行，特别是 forward-compat skip 模式与 ChunkDelta 现有 `payload_len` 模式一致性）。

1. **P-1 / P-2 / P-3 决策**：用户复核
2. 新建 `catalog_patch.ex` + `catalog_patch_test.exs`（TDD red）
3. 实现 envelope encode / decode + forward-compat skip
4. `cd ex_mmo_cluster/apps/scene_server && mix test --no-start`
5. verifier 独立审计
6. `cd ex_mmo_cluster && git commit -m "phase1.4: CatalogPatch envelope + forward-compat op skip"`

---

## 10. 风险

- **wire layout 冻结但 payload 不冻结**：Phase 5 才解释 payload 字节。如果 Phase 1.4 commit 后 Phase 5 发现 envelope 不够（比如要加 `delta_chain_hash` 字段），就要 bump schema_kind 高位或新增 opcode。建议 Phase 1.4 commit 前让 Phase 5 设计者（如果不是同一个人）独立审一遍 envelope 是否预留够。
- **schema_kind = 0x01 attribute / 0x02 tag 二选一**：未来如果引入 `entity_class` / `material_definition` 等其他 catalog，schema_kind 直接扩展即可（u8 还有 254 个空位）。
- **op_kind = 0x03 update 是否够用**：未来可能需要 `replace / patch / merge` 细分；u8 op_kind 也有空间扩。
