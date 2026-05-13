# Phase 1.3: TagSet typed domain — 设计草案

状态：设计稿，等用户复核 §3 / §4 / §5 决策点
日期：2026-05-13
归属：goal `voxel-authoritative-and-field-minimum` Phase 1.3
姊妹草案：`2026-05-13-phase1-attribute-set-typed-domain.md`

真相源：
- `docs/2026-05-07-体素服务器权威化架构进度检查.md` §"目标一缺口 A"
- `apps/scene_server/lib/scene_server/voxel/storage.ex`（`tag_sets: [term()]`）
- `apps/scene_server/lib/scene_server/voxel/codec.ex`（`@section_tag_sets 0x05`，当前空池）
- `apps/scene_server/lib/scene_server/voxel/normal_block_data.ex`（`tag_set_ref: u32`）
- `apps/scene_server/lib/scene_server/voxel/micro_layer.ex`（`tag_set_ref: u32`）

---

## 1. 目标

把 `Storage.tag_sets` 字段从 `[term()]` 升级为 `[TagSet.t()]`，并在 wire codec 上提供真实 encode / decode。

**与 AttributeSet 的对称**：本草案的几乎所有设计原则（1-indexed ref、chunk-local id、canonical order、intern API、chunk_hash 不 bump、wire layout 一旦发出即冻结的风险）都与 AttributeSet 草案完全一致。本草案只描述差异点 + TagSet 特有结构。

**不做**（Phase 5 工作）：
- TagDefinition catalog（id / name / namespace / merge_rule 元数据）
- tag 语义解释（"flammable" / "conductive" 等业务含义）

---

## 2. 概念模型

### 2.1 TagSet 是 chunk 内"指纹"

与 AttributeSet 完全对称：很多 cell / micro layer 共享同一组 tag 时只在 pool 里存一份，cell 端只放 u32 index。

引用语义（与 AttributeSet 1-indexed 决策一致）：
- `tag_set_ref = 0` → "无 tag set 引用"（无 tag 覆盖）
- `tag_set_ref ≥ 1` → 引用 `storage.tag_sets[ref - 1]`

### 2.2 TagSet 结构

```text
TagSet {
  tag_ids: u32[]                  // canonical: 升序，无重复
}
```

**与 AttributeSet 的最大差异**：TagSet 没有 value 字段。每个 tag 就是一个 u32 id。语义类似 "set membership"。

> **决策点 T-1（用户确认）**：tag 是否需要 namespace？候选：
> - (a) **无 namespace，扁平 u32 id**（推荐，最简单，且 4B id 空间够大）—— tag 的 namespace 区分推迟到 Phase 5 catalog
> - (b) `{namespace_id: u8, tag_id: u24}` —— wire 也是 u32 但语义分两段
> - (c) `{namespace_id: u16, tag_id: u32}` —— 6 bytes per tag

> **决策点 T-2（用户确认）**：tag 是否携带 value（即 `(tag_id, value)`）？候选：
> - (a) **不携带 value**（推荐）—— 如需 value 走 attribute_set
> - (b) 携带可选 u32 value —— 增加 wire 复杂度

如果选 (a)，TagSet 与 AttributeSet 的语义边界清晰：tag 是"集合成员资格"，attribute 是"键值对"。

---

## 3. canonical order

### 3.1 tag_ids 在 TagSet 内
按 u32 升序。重复 → `Storage.normalize!` raises。

### 3.2 TagSet 在 chunk pool 内
按 byte-wise canonical 升序（与 AttributeSet 决策 D-5 一致）。

`Storage.intern_tag_set/2` API 与 AttributeSet 决策 D-5b 一致。

---

## 4. wire layout（section 0x05，一旦发出即冻结）

```text
Section: TagSetPool (section_type = 0x05)
  set_count: u32                     # 0 = empty pool
  sets[set_count] {
    tag_count: u16                   # 0 不允许（empty set 用 ref=0 表达）
    tag_ids[tag_count]: u32          # 升序
  }
```

**Wire byte count per set**：`2 + 4 × tag_count`，量级远小于 AttributeSet。

**典型 chunk 量级估算**：1 chunk 16³=4096 macro cells，30% cell 有 tag set，平均 2 tags/set，假设 50 个唯一 set，pool 约 50 × (2 + 2×4) ≈ 0.5 KB。可忽略。

> **决策点 T-3（用户确认）**：tag_count 用 u8 / u16 / u32？候选：
> - (a) **u16**（推荐，单 set 上限 65535 tags，与 AttributeSet D-7 对齐）
> - (b) u8（单 set ≤ 255 tags）
> - (c) u32

> **决策点 T-4（用户确认）**：set_count 用 u32？默认 (a) u32，与 AttributeSet D-6 一致。

---

## 5. Elixir 模块结构

```text
apps/scene_server/lib/scene_server/voxel/
└── tag_set.ex            # %SceneServer.Voxel.TagSet{tag_ids: [u32]}
```

不需要独立 `tag_entry.ex`（tag_id 是 u32，没有内部结构）。

### 5.1 `TagSet.normalize!/1`
- 校验 tag_ids 非空
- 校验每个 tag_id 在 u32 范围
- 校验无重复
- tag_ids 升序排序

### 5.2 `TagSet.byte_canonical_key/1`
返回 `binary` 作为 pool 内排序键。

### 5.3 `TagSet.encode_for_wire/1` / `decode_for_wire/1`
等价于 AttributeSet codec 模式。

---

## 6. Codec 改动（section 0x05）

完全对称 AttributeSet section 0x04 改动：
- `Codec.encode_tag_set_pool/1` 替换 `encode_empty_pool_for_wire(..., :tag_sets)`
- `Codec.decode_tag_set_pool!/1` 替换 `decode_empty_pool!(..., :tag_sets)`
- `Codec.chunk_hash/1` 中 line 806 改 tag_sets 真值（依据 D-8 决策，**预计**不 bump schema_version——空池字节等价）

---

## 7. Storage 改动

```elixir
@type t :: %__MODULE__{
        ...
        tag_sets: [TagSet.t()],    # was [term()]
        ...
      }

def normalize!(%__MODULE__{} = storage) do
  ...
  tag_sets:
    storage.tag_sets
    |> Enum.map(&TagSet.normalize!/1)
    |> Enum.sort_by(&TagSet.byte_canonical_key/1),
  ...
end

def intern_tag_set(%__MODULE__{} = storage, %TagSet{} = set) do
  # 1-indexed
end
```

---

## 8. Test plan（TDD）

新建 `apps/scene_server/test/scene_server/voxel/tag_set_test.exs`：

1. `TagSet.normalize!` 校验（空集 / 重复 / u32 范围 / 升序）
2. `encode_for_wire / decode_for_wire` roundtrip + 字节级 golden
3. `Storage.intern_tag_set` 行为（首次返回 ref=1 / 二次同结构返回同 ref）
4. `Codec.encode_chunk_snapshot_payload / decode_chunk_snapshot_payload` roundtrip 含非空 tag_sets pool
5. chunk_hash 稳定性（不同输入顺序 → 同 hash）
6. 空池 chunk_hash 向后兼容（与 AttributeSet 1.2 §9 测试用例 6 一致）

---

## 9. 客户端（web_client）回路

Phase 1.6 时在 `clients/web_client/src/voxel/` 新增 `tagSet.ts`，与 AttributeSet 共用一致的 decoder 模板。

---

## 10. 实施顺序

依赖：Phase 1.2 AttributeSet 落地（不强依赖代码，但**强依赖** D-5b intern API 设计模式定型 + chunk_hash 迁移决策 D-8 落地）。

1. **T-1 / T-2 / T-3 / T-4 决策**：用户复核
2. 新建 `tag_set.ex` + `tag_set_test.exs`（TDD red）
3. 实现 normalize / encode_for_wire / decode_for_wire（TDD green）
4. 修改 `storage.ex`：升级类型 + 新增 `intern_tag_set`
5. 修改 `codec.ex`：替换 tag_sets section 的 encode / decode + chunk_hash 真值
6. 测试通过：`cd ex_mmo_cluster/apps/scene_server && mix test --no-start`
7. verifier 独立审计
8. `cd ex_mmo_cluster && git commit -m "phase1.3: TagSet typed domain + section 0x05 wire codec"`
9. 更新 voxel README + 主线进度文档

---

## 11. 风险

- **wire layout 冻结**：T-1 / T-2 / T-3 / T-4 决策必须先于 commit 实质代码。
- **与 AttributeSet 设计漂移**：Phase 1.3 应在 Phase 1.2 决策定型后才开 commit（保持 intern API / canonical order / chunk_hash 处理一致），否则后续维护两套不同设计的 pool 模块成本翻倍。
- **AttributeSet 选 D-1 (b) 0-indexed 时 TagSet 也得跟着改**：本草案默认 1-indexed，依赖 AttributeSet 推荐方案 (a)。
