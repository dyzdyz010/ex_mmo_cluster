# Phase 1.2: AttributeSet typed domain — 设计草案

状态：设计稿，等用户复核 §5 wire layout 决策点
日期：2026-05-13
归属：goal `voxel-authoritative-and-field-minimum` Phase 1.2
真相源：
- `docs/2026-05-07-体素服务器权威化架构进度检查.md` §"目标一缺口 A" / §"目标三缺口 A"
- `apps/scene_server/lib/scene_server/voxel/storage.ex`（`attribute_sets: [term()]`）
- `apps/scene_server/lib/scene_server/voxel/codec.ex`（`@section_attribute_sets 0x04`，当前空池）
- `apps/scene_server/lib/scene_server/voxel/normal_block_data.ex`（`attribute_set_ref: u32`）
- `apps/scene_server/lib/scene_server/voxel/micro_layer.ex`（`attribute_set_ref: u32`）

跨仓决策：
- 2026-05-13 web_client 解冻 → 本子项 TS decoder roundtrip 落在 `clients/web_client`

---

## 1. 目标（严格遵守 Phase 1 子项范围）

把 `Storage.attribute_sets` 字段从 `[term()]` 升级为 `[AttributeSet.t()]`，并在 wire codec 上提供真实 encode / decode。

**不做**（Phase 5 工作）：
- AttributeDefinition catalog（id / name / unit / value_type / merge_rule / dynamic? 元数据）
- merge_rule 语义（override / add_delta / max / min / material_default）
- 任何属性"模拟"（扩散、衰减、动态规则帧）
- attribute key_id 全局命名空间分配机制

用户决策（2026-05-13）：Phase 1.2 AttributeSet 只做「value bag」——每个 chunk 内 attribute_sets 池就是「这个 chunk 用到的 attribute 集合表」。NormalBlockData / MicroLayer 通过 `attribute_set_ref: u32` 引用该池中的一个 entry。

---

## 2. 概念模型

### 2.1 AttributeSet 是 chunk 内"指纹"

AttributeSet 在 chunk 内的作用类似 string interning：很多 cell / micro layer 共享同一组 (k, v) attribute 时，只在 pool 里存一份，cell 端只放 u32 index。

引用语义（与现有 NormalBlockData / MicroLayer 一致）：
- `attribute_set_ref = 0` → "无 attribute set 引用"（empty / 无属性覆盖）
- `attribute_set_ref ≥ 1` → 引用 `storage.attribute_sets[ref - 1]`（pool 一索引化，与 Codec wire 0-based count 解耦）

> **决策点 D-1（用户确认）**：是否采用 1-indexed `attribute_set_ref`（0 = null）？候选：
> - (a) 1-indexed，0 = null（推荐，与 ObjectCoverRef 行为一致，明显语义）
> - (b) 0-indexed，attribute_set_ref 无 null 概念，每个 NormalBlockData 都必须引用某个 entry（甚至空 entry）
> - (c) 0-indexed + 维度第一个 entry 强制为 "empty AttributeSet"，作为默认 null

### 2.2 AttributeSet 结构

```text
AttributeSet {
  entries: AttributeEntry[]      // canonical: key_id 升序，无重复
}

AttributeEntry {
  key_id: u32                    // chunk 内局部 ID（与 Phase 5 catalog 解耦）
  value_type: u8                 // tagged union 标签（见 §3）
  value: tagged_union            // 4-16 bytes，按 value_type 决定
}
```

### 2.3 与 Phase 5 AttributeCatalog 的边界

Phase 5 会引入跨 chunk 的 `AttributeCatalogSnapshot`：
- 把 `key_id` 从 "chunk 内局部 ID" 升级到 "全局命名空间"（绑定 name / unit / value_type / merge_rule / dynamic?）
- 引入 `CatalogPatch` 增删改 catalog
- 引入 `EnvironmentUpdated` delta 把 attribute 状态推到客户端

Phase 1.2 不做：
- key_id 在 Phase 1.2 阶段含义是「这个 chunk 自己约定的 attribute 键」，wire 层不解释其语义；
- value_type 在 Phase 1.2 阶段是 wire 层 tagged union 标签，不绑定 catalog；
- 不同 chunk 的 attribute_sets 池**互相独立**（一个 chunk 的 key_id=42 ≠ 另一个 chunk 的 key_id=42 同语义）；Phase 5 catalog 落地后 key_id 才升级为全局含义。

> **决策点 D-2（用户确认）**：Phase 1.2 的 key_id 是「chunk 内局部 ID」还是「即使 catalog 不存在也按某种约定的全局 ID」？候选：
> - (a) chunk 内局部 ID（推荐，最小耦合）
> - (b) 全局 ID，但 catalog 未落地前由调用方自治、无 catalog 校验

---

## 3. AttributeValue tagged union（v1）

主线进度文档 §"目标三缺口 A" 列出 value_type ∈ `{i16, u16, fixed32, enum, bitset}`。Phase 1.2 wire 层 v1 实现：

| value_type | wire 标签 (u8) | wire payload size | 语义 |
|---|---|---|---|
| `i16` | 0x01 | 2 bytes (signed big-endian) | 有符号 16-bit 整数（如 temperature_delta 类型） |
| `u16` | 0x02 | 2 bytes (unsigned big-endian) | 无符号 16-bit 整数 |
| `fixed32` | 0x03 | 4 bytes (signed big-endian, Q16.16 定点) | 定点小数（density / thermal_conductivity 类型） |
| `enum8` | 0x04 | 1 byte (u8) | 枚举（< 256 个值） |
| `bitset32` | 0x05 | 4 bytes (u32) | 位标志集合（≤ 32 个标志） |
| (reserved) | 0x06 - 0xFF | — | 未定义。decoder 拒绝。后续 Phase 追加 |

> **决策点 D-3（用户确认）**：v1 是否够用？候选：
> - (a) 这 5 个类型够用（推荐）
> - (b) 加 `f32`（IEEE 754 single）替代或补充 fixed32 —— 但浮点的 deterministic hash 是大坑（NaN / -0.0 / 平台差异）
> - (c) 加 `i32` —— 留给 Phase 5 再追加
> - (d) 加 `binary` (变长 blob) —— 留给 Phase 5 再追加

> **决策点 D-4（用户确认）**：fixed32 用 Q16.16 还是其他定点格式？Q16.16 = `value / 65536`，范围约 -32768.0 到 32767.999985。temperature 单位 °C 显然够用，moisture 0-100% 也够用，density g/cm³ 0-25 量级也够用。

---

## 4. canonical order（chunk_hash 稳定性关键）

为保证 chunk_hash 不依赖输入顺序，两层 canonical order：

### 4.1 AttributeEntry 在 AttributeSet 内
按 `key_id` 升序。同 `key_id` 重复 → `Storage.normalize!` raises（不允许同 key 多值）。

### 4.2 AttributeSet 在 chunk pool 内
按 AttributeSet 全字段 byte-wise 升序。即：先按 entries 数量、再按每个 entry 的 (key_id, value_type, value_bytes) 字典序。

> **决策点 D-5（用户确认）**：AttributeSet pool 是否要按 byte-wise canonical？候选：
> - (a) 按 byte-wise canonical（推荐，最稳）
> - (b) 按"插入顺序"（最简单，但 chunk_hash 会因 cell 写入顺序变化）
> - (c) 按"首次被引用的 cell index"（与 ObjectCoverRef 现有逻辑接近）

**注意**：canonical 重排意味着 `attribute_set_ref` 不能由 caller 自己挑 index — 必须由 `Storage.put_attribute_set/intern/2` 这类 API 决定 index。这与现有 `Storage.put_solid_block` 让 caller 拿 `length(normal_blocks)` 当 ref 的做法**不兼容**。需要新增 intern API。

> **决策点 D-5b**：与 normal_blocks 现有「caller 拿 ref」语义对齐吗？候选：
> - (a) 新增 `Storage.intern_attribute_set/2` API，调用方不能自挑 ref（更安全）
> - (b) 维持 normal_blocks 风格的"caller 拿 ref"，但 Storage.normalize! 在最后一步做 canonical 重排并返回 ref 映射表

---

## 5. wire layout（section 0x04，一旦发出即冻结）

```text
Section: AttributeSetPool (section_type = 0x04)
  set_count: u32                              # 0 = empty pool
  sets[set_count] {
    entry_count: u16                          # 0 不允许（empty set 直接 set_count-=1，由 ref=0 表示 null）
    entries[entry_count] {
      key_id: u32
      value_type: u8
      value_payload: bytes (size 由 value_type 决定，见 §3)
    }
  }
```

**Wire byte count per entry**（v1）：
- min entry: `4 + 1 + 1 = 6 bytes`（enum8）
- max entry: `4 + 1 + 4 = 9 bytes`（fixed32 / bitset32）

**Per-set overhead**：`2 bytes`（entry_count）

**典型 chunk 量级估算**：1 个 chunk 16³=4096 macro cells，假设 30% cell 有 attribute set，平均 3 entries/set，则 attribute_set pool entry 总数约 1200，假设 100 个唯一 set（高复用），pool 约 100 × (2 + 3 × 8) ≈ 2.6 KB。可接受。

> **决策点 D-6（用户确认）**：set_count 用 u32 还是 u16？候选：
> - (a) u32（推荐，与 normal_blocks / refined_cells / object_refs 一致）
> - (b) u16（pool 上限 65535）

> **决策点 D-7（用户确认）**：entry_count 用 u8 / u16 / u32？候选：
> - (a) u16（推荐，单 set 上限 65535 entries，足够 + 不浪费）
> - (b) u8（单 set ≤ 255 entries，量级足够）
> - (c) u32

---

## 6. Elixir 模块结构

```text
apps/scene_server/lib/scene_server/voxel/
├── attribute_set.ex            # %SceneServer.Voxel.AttributeSet{entries: [AttributeEntry.t()]}
└── attribute_entry.ex          # %SceneServer.Voxel.AttributeEntry{key_id, value_type, value}
```

或合并到单文件 `attribute_set.ex`（参考 RefinedCellData 把 MicroLayer / ObjectCoverRef 拆为独立文件的做法 → 推荐拆分）。

### 6.1 `AttributeSet.normalize!/1` 行为
- 校验 entries 列表非空（empty set 用 ref=0 表达，不在 pool 里）
- 校验 key_id 在 u32 范围
- 校验 value_type ∈ 已知枚举
- 校验 value 在该 value_type 的合法范围
- entries 按 key_id 升序去重排序

### 6.2 `AttributeSet.byte_canonical_key/1`
返回 `binary` 作为 pool 内排序键（D-5a 路径）；用于 `Storage.normalize!` 中的 attribute_sets 排序。

### 6.3 `AttributeSet.encode_for_wire/1` / `decode_for_wire/1`
等价于 RefinedCellData 现有 codec 模式。

---

## 7. Codec 改动

### 7.1 `Codec.encode_attribute_set_pool/1`（替换 `encode_empty_pool_for_wire`）
```elixir
defp encode_attribute_set_pool([]) , do: <<0::unsigned-big-integer-size(32)>>
defp encode_attribute_set_pool(sets) do
  count = length(sets)
  payload = Enum.map(sets, &AttributeSet.encode_for_wire/1) |> IO.iodata_to_binary()
  <<count::unsigned-big-integer-size(32), payload::binary>>
end
```

### 7.2 `Codec.decode_attribute_set_pool!/1`（替换 `decode_empty_pool!` for attribute_sets）

### 7.3 `Codec.chunk_hash/1`（§1.5 工作，但本 Phase 1.2 commit 一并做）
当前 line 805 `encode_empty_pool_for_truth(storage.attribute_sets, :attribute_sets)` → 改为 `encode_attribute_set_pool_for_truth(storage.attribute_sets)`，即用真实 pool 字节序列参与 chunk_hash。

> **决策点 D-8（用户确认）**：chunk_hash 改动后，老 snapshot 算出的 chunk_hash 与新算法不一致。迁移策略候选：
> - (a) bump `schema_version` 1 → 2，老 snapshot 走 v1 decoder（保留 empty pool 语义），新 snapshot 走 v2（推荐，最安全）
> - (b) 保持 `schema_version = 1`，但 attribute_sets 空池时新算法等价于旧算法（4 字节 `<<0::u32>>`）；只要老 snapshot attribute_sets 都是空就 hash 不变 — **当前情况确实如此**，所以可以不 bump
> - (c) 强制 DataService 全量重算 chunk_hash（运维风险）

参考：当前 `encode_empty_pool_for_truth` 实现是
```elixir
defp encode_empty_pool_for_truth([], _label), do: <<0::unsigned-big-integer-size(32)>>
defp encode_empty_pool_for_truth(values, label), do: raise(...)
```
即"空池字节 = `<<0::u32>>`，非空池 raise"。本 Phase 1.2 替换后，空池字节依然是 `<<0::u32>>`（set_count = 0），所以**只要现有 chunk 都没存非空 attribute_set，hash 完全不变**。`encode_empty_pool_for_truth` 的 raise 路径表明现状就是"从来没有 attribute_set 落到 pool"。

→ 推荐 D-8 (b)：不 bump schema_version。

---

## 8. Storage 改动

```elixir
# storage.ex
@type t :: %__MODULE__{
        ...
        attribute_sets: [AttributeSet.t()],    # was [term()]
        ...
      }

def normalize!(%__MODULE__{} = storage) do
  ...
  attribute_sets:
    storage.attribute_sets
    |> Enum.map(&AttributeSet.normalize!/1)
    |> Enum.sort_by(&AttributeSet.byte_canonical_key/1),
  ...
end

# 新增 intern API
def intern_attribute_set(%__MODULE__{} = storage, %AttributeSet{} = set) do
  # 查 pool 是否已含该 set；若已含返回现有 ref；否则 append + 返回新 ref（1-indexed, ref=0 reserved）
end
```

---

## 9. Test plan（TDD step 3）

新建 `apps/scene_server/test/scene_server/voxel/attribute_set_test.exs`：

1. **AttributeSet.normalize! 校验**
   - 拒绝 empty entries
   - 拒绝 key_id 重复
   - 拒绝未知 value_type
   - 拒绝 value 超出 value_type 范围
   - entries 按 key_id 升序排序

2. **AttributeSet.encode_for_wire / decode_for_wire roundtrip**
   - 每个 value_type 一个用例
   - 多 entry 一个用例
   - 字节级 golden（v1 wire 一旦冻结）

3. **Storage.intern_attribute_set**
   - 首次 intern 返回 ref=1，attribute_sets pool 长度 = 1
   - 二次 intern 同结构返回同 ref，pool 不变
   - 不同 set 返回递增 ref（在 normalize! 排序之前）
   - normalize! 后 ref 重映射（如果 D-5a）

4. **Codec.encode_chunk_snapshot_payload / decode_chunk_snapshot_payload roundtrip**
   - storage 含非空 attribute_sets pool
   - 服务端 hash 与 decode 后重算 hash 一致
   - decode → encode → byte 等值

5. **chunk_hash 稳定性**
   - 同一 AttributeSet 内 entries 不同顺序输入 → 同 chunk_hash
   - pool 内 AttributeSet 不同顺序输入 → 同 chunk_hash（D-5a 路径）

`apps/scene_server/test/scene_server/voxel/codec_test.exs` 追加：
6. **空池 chunk_hash 向后兼容**（验证 D-8b）：现有 empty attribute_set storage 用新代码算出 chunk_hash 与旧代码一致。

---

## 10. 客户端（web_client）回路（属于 Phase 1.6 子项，本草案仅留接口）

Phase 1.6 时在 `clients/web_client/src/voxel/` 新增：
- `attributeSet.ts` typed shape + decoder
- 服务端 wire payload roundtrip 测试
- `wireToRefinedCell.ts` 中 AttributeSet pool 解析

本 Phase 1.2 commit 不必动 web_client；先把服务端 wire layout 冻结到 §5 描述形态，再在 Phase 1.6 commit 落 TS decoder。

---

## 11. 实施顺序（用户确认后开工）

1. **D-1 / D-2 / D-3 / D-4 / D-5 / D-5b / D-6 / D-7 / D-8 决策**：用户复核（本草案 §3 / §4 / §5）
2. 新建 `attribute_entry.ex` + `attribute_set.ex` + `attribute_set_test.exs`（TDD red）
3. 实现 normalize / encode_for_wire / decode_for_wire（TDD green）
4. 修改 `storage.ex`：升级类型 + 新增 `intern_attribute_set`
5. 修改 `codec.ex`：替换 attribute_sets section 的 encode / decode + chunk_hash 改 attribute_sets 真值
6. 全套测试通过：`cd ex_mmo_cluster/apps/scene_server && mix test --no-start`
7. verifier agent 独立审计
8. `cd ex_mmo_cluster && git commit` —— commit message：`phase1.2: AttributeSet typed domain + section 0x04 wire codec`
9. 更新 `apps/scene_server/lib/scene_server/voxel/README.md` 增加 AttributeSet 段
10. 更新 `docs/2026-05-07-体素服务器权威化架构进度检查.md` §"目标一缺口 A" 标记"AttributeSet 已实现"指向 commit

Phase 1.3 TagSet 重复一遍上述步骤（独立 commit）。

---

## 12. 风险

- **wire layout 一旦发出即冻结**。本草案 §5 的 8 个决策点必须用户复核通过后再写 encode/decode。
- **chunk_hash 改动迁移**：依赖 D-8 决策。当前推荐 (b) 不 bump，因为现状就是空池。但 DataService 持久层若已存非空 attribute_set（按 `encode_empty_pool_for_truth` raise 路径推断**不可能**），就会破坏向后兼容。
- **`Storage.intern_attribute_set` 与 `normalize!` 顺序**：如果 caller 在 normalize 之前用了拿到的 ref，normalize 重排会让 ref 失效。需在 §11 step 4 严格设计 API 契约。
