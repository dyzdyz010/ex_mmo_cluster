# Phase 5.A: AttributeCatalogSnapshot typed module + opcode 0x6E — 设计草案

状态：设计稿，等用户复核 A-1..A-5 决策点
日期：2026-05-13
归属：goal `voxel-authoritative-and-field-minimum` Phase 5.A
姊妹草案：`2026-05-13-phase5-backlog-and-subphase-decomposition.md`

真相源：
- `docs/2026-05-07-体素服务器权威化架构进度检查.md` §"目标三缺口 A"
- `docs/2026-04-10-线协议规范.md` line 243 预留 `0x6E AttributeCatalogSnapshot` 但无 wire payload 定义
- Phase 1.2 `attribute_set.ex` / `attribute_entry.ex`（chunk-local AttributeSet wire 已冻结，section 0x04）
- Phase 1.4 `catalog_patch.ex`（opcode 0x71 envelope，schema_kind=0x01 attribute / 0x02 tag）

---

## 1. 目标

实现 AttributeCatalogSnapshot：全局 catalog 全量快照 wire 类型，作为客户端冷启动 / 重连 / catalog 大幅变更时的"基线"通道。增量更新走 Phase 1.4 已落地的 `CatalogPatch envelope (opcode 0x71)`。

把 chunk-local AttributeSet 中的 `key_id: u32`（Phase 1.2 是 "chunk-local convention"）升级为**全局 catalog id**，绑定 name / unit / value_type / default_value / merge_rule 等元数据。

**不做**（Phase 5.B-F 工作）：
- TagCatalogSnapshot（5.B 工作）
- 第一批 typed attribute 注入 catalog（5.C 工作）
- 五层 merge_rule 实施（5.D 工作）
- simulator / 规则帧（5.E/F 工作）

---

## 2. 概念模型

### 2.1 AttributeCatalogSnapshot 的角色

- **全局**：跨所有 chunks 共享。一个 catalog id 含义一致（不再是 "chunk-local convention"）。
- **monotonic version**：每次 catalog 变更（CatalogPatch envelope）累加 `catalog_version`。Snapshot 包含 `catalog_version` 字段。
- **wire 通道**：opcode `0x6E AttributeCatalogSnapshot`（协议规范预留）。

### 2.2 AttributeDefinition v1 schema

```text
AttributeDefinition {
  id: u32                    // 全局 attribute_id，与 Phase 1.2 AttributeEntry.key_id 等同
  name: string               // UTF-8，u16 length-prefixed
  unit: string               // UTF-8，u16 length-prefixed（"°C" / "%" / "kg/m³" / "W/(m·K)" 等）
  value_type: u8             // 与 Phase 1.2 D-3 一致：0x01 i16 / 0x02 u16 / 0x03 fixed32 / 0x04 enum8 / 0x05 bitset32
  default_value: bytes       // 按 value_type 字节长度（2/2/4/1/4 bytes）
  min_value: bytes           // 按 value_type 字节长度（用于 normalize 校验）
  max_value: bytes
  merge_rule: u8             // 0x01 override / 0x02 add_delta / 0x03 max / 0x04 min / 0x05 material_default
  dynamic: bool              // u8 0/1，是否运行时可变（影响 catalog 自身不动，仅运行时 hint）
}
```

> **决策点 A-1**（用户确认）：catalog scope 全局 vs logical_scene_id？
> - (a) **全局**（推荐）：catalog 跨 scene 共享，client 只在登录 / 重连时拉一次
> - (b) per logical_scene_id：每个场景独立 catalog —— 增加 wire 复杂度但允许场景级实验性 attribute

> **决策点 A-2**（用户确认）：name / unit 字符串编码？
> - (a) **UTF-8 + u16 length prefix**（推荐）
> - (b) ASCII only + u8 length prefix（紧凑但限制）
> - (c) null-terminated UTF-8

> **决策点 A-3**（用户确认）：merge_rule 枚举值
> - (a) **5 个值**：0x01 override / 0x02 add_delta / 0x03 max / 0x04 min / 0x05 material_default（推荐，与主线 §"目标三缺口 A" 字段集一致）
> - (b) 6+ 值：再加 0x06 weighted_average（未来 simulator 用？）—— Phase 5.D 决定时再追加
> - (c) 3 个值简化：override / add_delta / material_default

> **决策点 A-4**（用户确认）：dynamic 字段
> - (a) **u8 boolean**（推荐，最小）
> - (b) u8 enum：0=static, 1=dynamic_low_freq, 2=dynamic_high_freq（Phase 6 FieldLayer 区分用）—— 不推荐 Phase 5.A 先做，留 Phase 6 spec 真发现需要时再 bump

> **决策点 A-5**（用户确认）：default_value / min_value / max_value 字段长度
> - (a) **按 value_type 字节长度**（推荐，紧凑）：value_type 0x01 i16 → 2B；0x03 fixed32 → 4B
> - (b) 统一 u32（4B）填充 + 高位 0：客户端简化但 i16 等浪费 2B

---

## 3. wire layout (opcode 0x6E，一旦发出即冻结)

```text
AttributeCatalogSnapshot (opcode 0x6E)
  catalog_version: u64
  definition_count: u32
  definitions[definition_count] {
    id: u32
    name_len: u16
    name: bytes(name_len)        // UTF-8
    unit_len: u16
    unit: bytes(unit_len)        // UTF-8
    value_type: u8               // 0x01..0x05
    default_value: bytes(N)      // N = value_type 字节长度
    min_value: bytes(N)
    max_value: bytes(N)
    merge_rule: u8               // 0x01..0x05
    dynamic: u8                  // 0 / 1
  }
```

**字节量估算**：单 AttributeDefinition 假设 name="temperature"(11B) + unit="°C"(3B UTF-8):
`4 + 2+11 + 2+3 + 1 + 4+4+4 + 1 + 1 = 37 B`

5 个内置 attribute：约 200B catalog snapshot。可接受。

> **决策点 A-6**（用户确认）：definition_count 用 u32 还是 u16？
> - (a) **u32**（推荐，与 attribute_set_pool set_count 一致 + 未来扩展空间）
> - (b) u16（catalog 上限 65535 个 definition，足够实用）

---

## 4. Elixir 模块结构

```text
apps/scene_server/lib/scene_server/voxel/
├── attribute_catalog_snapshot.ex   # %SceneServer.Voxel.AttributeCatalogSnapshot{catalog_version, definitions: [AttributeDefinition.t()]}
└── attribute_definition.ex          # %SceneServer.Voxel.AttributeDefinition{id, name, unit, value_type, default_value, min_value, max_value, merge_rule, dynamic}
```

### 4.1 `AttributeDefinition.normalize!/1`
- 校验 name / unit 非空且合法 UTF-8
- 校验 value_type ∈ {0x01..0x05}
- 校验 default_value / min_value / max_value 字节长度与 value_type 匹配
- 校验 default 在 [min, max] 之间
- 校验 merge_rule ∈ {0x01..0x05}
- 校验 dynamic ∈ {0, 1}

### 4.2 `AttributeCatalogSnapshot.normalize!/1`
- definitions 按 id 升序去重
- catalog_version u64 范围

### 4.3 `AttributeCatalogSnapshot.encode_for_wire/1` / `decode_for_wire/1`

按 §3 wire layout。

---

## 5. 协议规范 + Codec 改动

### 5.1 协议规范文档
- `docs/2026-04-10-线协议规范.md`：line 243 `0x6E AttributeCatalogSnapshot` 原本只是预留，补 wire payload 字段定义。

### 5.2 `apps/scene_server/lib/scene_server/voxel/codec.ex`（或独立 catalog_codec.ex）
- 新增 `encode_attribute_catalog_snapshot_payload/1` / `decode_attribute_catalog_snapshot_payload/1`
- 不影响现有 chunk_snapshot / chunk_delta / catalog_patch codec

### 5.3 gate 端
- Phase 5.A 仅服务端 envelope。gate 端 outbound dispatch 在 Phase 5.D 或 5.E（当真正发送 catalog 给客户端时）落地，**本 commit 不动 gate codec**

---

## 6. Test plan（TDD）

新建 `apps/scene_server/test/scene_server/voxel/attribute_catalog_snapshot_test.exs`：

1. `AttributeDefinition.normalize!` 校验
   - 拒绝 name 空
   - 拒绝未知 value_type
   - 拒绝 default 超出 [min, max]
   - 拒绝未知 merge_rule
   - 拒绝 dynamic ∉ {0, 1}

2. `AttributeCatalogSnapshot.normalize!` 校验
   - definitions 按 id 升序去重
   - catalog_version u64 范围

3. `encode_for_wire / decode_for_wire` roundtrip
   - 空 catalog（version=0, definition_count=0）
   - 单个 definition
   - 5 类 value_type 各一个 definition（模拟 Phase 5.C 第一批）
   - 字节级 golden（pin 一段 hex 序列保 wire 稳定）

4. UTF-8 字符串处理
   - 含中文 unit（如 "°C" 是 3 字节 UTF-8）roundtrip
   - 含 emoji（罕见但 forward-compat 校验）

5. catalog_version monotonic
   - normalize! 接收负值时 raise（u64 类型校验）

---

## 7. 实施顺序

依赖：Phase 1 已 done，Phase 5.A 是 Phase 5 第一个 sub-phase。

1. **A-1..A-6 决策**：用户复核
2. 新建 `attribute_definition.ex` + `attribute_catalog_snapshot.ex` + `attribute_catalog_snapshot_test.exs`（TDD red）
3. 实现 normalize / encode / decode（TDD green）
4. 跑 `cd ex_mmo_cluster/apps/scene_server && mix test --no-start`
5. 跑 codec_test.exs 3 个 pinned chunk_hash baseline 字节稳定（本 commit 不动 chunk_hash 但顺手验证）
6. verifier 独立审计
7. 同步 `docs/2026-04-10-线协议规范.md` opcode 0x6E wire 字段定义
8. 同步 voxel README + 主线进度文档
9. `cd ex_mmo_cluster && git commit -m "phase5a: AttributeCatalogSnapshot typed module + opcode 0x6E wire codec"`

---

## 8. 风险

- **catalog wire layout 一旦发出即冻结**：A-1..A-6 决策必须用户先复核。
- **AttributeDefinition.id 与 Phase 1.2 AttributeEntry.key_id 的语义升级**：Phase 1.2 chunk-local key_id 在 Phase 5.A 后升级为 catalog 全局 id。这是**语义升级而非 wire 升级**（wire 字段不变，仍 u32），但服务端 / 客户端代码需要在 Phase 5.C 真正注入 catalog 之前确认双方一致：「key_id == catalog AttributeDefinition.id」。
- **catalog 持久化**：Phase 5.A 不实现 catalog 持久化（DataService schema）。Phase 5.C 真正注入第一批 attribute 时再考虑持久化。Phase 5.A 仅 wire 类型 + Elixir typed module。
- **客户端 catalog 消费**：Phase 5.A 不实现 web_client TS decoder for 0x6E。客户端 decoder 可在 Phase 5.C/5.D（真正下发 catalog 给客户端时）一并做，或归到一个独立 Phase 5.x web_client commit。
