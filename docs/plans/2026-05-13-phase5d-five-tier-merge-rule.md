# Phase 5.D: 五层 merge_rule + effective_attribute_at — 设计草案

状态：设计稿，等用户复核 D-1..D-5 决策点
日期：2026-05-13
归属：goal `voxel-authoritative-and-field-minimum` Phase 5.D

姊妹草案：
- 5.A AttributeCatalogSnapshot（commit `8b61c60`）
- 5.B TagCatalogSnapshot（commit `e635196`）
- 5.C catalog seed + runtime（commit `25078a7`）

真相源：
- `docs/2026-05-07-体素服务器权威化架构进度检查.md` §"目标三缺口 B"（属性存储粒度优先级）
- Phase 5.A AttributeDefinition.merge_rule 5 个枚举值（override / add_delta / max / min / material_default）
- `apps/scene_server/lib/scene_server/voxel/normal_block_data.ex`（已预留 `temperature_delta` / `moisture_delta`）
- `apps/scene_server/lib/scene_server/voxel/macro_environment_summary.ex`（已预留 `current_temperature` / `current_moisture`）
- `apps/scene_server/lib/scene_server/voxel/part_state.ex`（Phase 4）

---

## 1. 目标

实现"按 cell 读取 effective attribute value"的解析路径：

```
effective_value(cell, attribute_name) = merge(
  material_default,
  normal_block_override,
  refined_micro_override,
  object_part_attribute,
  environment_summary,
  按 attribute.merge_rule
)
```

允许下游 simulator（Phase 5.F）/ FieldLayer（Phase 6）通过单一 API 读到"应用所有覆盖后"的最终值。

**Phase 5.D 不做**（Phase 5.E/F 工作）：
- simulator / 规则帧调度（Phase 5.E）
- temperature diffusion 算法（Phase 5.F）
- EnvironmentUpdated delta 下发（Phase 5.F）

---

## 2. 五层 attribute 来源

按主线 §"目标三缺口 B" 列出 5 层：

| 层级 | 来源 | 粒度 | 当前实现状态 |
|---|---|---|---|
| L1 material default | `AttributeDefinition.default_value` | catalog 全局 | ✅ Phase 5.C |
| L2 normal block override | `NormalBlockData.attribute_set_ref` 指向的 AttributeSet | macro cell | ✅ Phase 1.2 + 5.C `put_attribute_for_cell` |
| L3 refined micro override | `MicroLayer.attribute_set_ref` 指向的 AttributeSet | refined micro layer | ✅ Phase 1.2 |
| L4 object-part attribute | （Phase 4 PartState 扩展 / 独立 ObjectPartAttribute table）| object part | ❌ 待 D-4 决策 |
| L5 environment summary | `MacroEnvironmentSummary.current_temperature / current_moisture` | macro cell（粗粒度） | ✅ 既有结构，待 simulator 写入 |

---

## 3. merge_rule 语义

5 个 merge_rule（Phase 5.A 已定义）：

| merge_rule | 数学语义 | 五层应用方式 |
|---|---|---|
| `override` (0x01) | 高层覆盖低层 | L5 > L4 > L3 > L2 > L1（只取最高层有值的层） |
| `add_delta` (0x02) | 高层在低层基础上加 delta | L1 + L2.delta + L3.delta + L4.delta + L5.delta（**delta 累加**） |
| `max` (0x03) | 取所有层中最大值 | max(L1, L2, L3, L4, L5) |
| `min` (0x04) | 取所有层中最小值 | min(L1, L2, L3, L4, L5) |
| `material_default` (0x05) | 仅取 L1，忽略其他层 | L1 (read-only attribute，如 density / thermal_conductivity) |

> **决策点 D-1**：`override` 优先级顺序 L5 > L4 > L3 > L2 > L1 是否正确？
> - (a) **L5 > L4 > L3 > L2 > L1（推荐，"越具体越优先"反过来想：environment 最具体到 cell 当前状态，object 次之，refined 再次之，normal block 是 macro 粗粒度，material default 最 general）** —— 但这与"高粒度覆盖低粒度"语义相反
> - (b) L3 > L4 > L2 > L5 > L1（micro > part > macro override > environment current > material default）—— 与"实际物理位置越精细越优先"对齐
> - (c) L4 > L3 > L2 > L1 > L5（part > micro > macro override > material default > environment）—— environment 作为兜底
>
> **推荐 (b)**：refined micro override (L3) > object-part (L4) > normal block override (L2) > material default (L1) > environment summary (L5)。理由：
> - L3 最精细（micro slot 级）
> - L4 是 prefab 内部约束（"门把手的 temperature 应该高于墙体"）
> - L2 是 macro 级局部覆盖
> - L1 是材质本身的默认值（"金属的 density"）
> - L5 是粗粒度宏观背景（"这个 chunk 当前的环境温度"）—— 优先级**最低**，作为兜底/初始化值，被任何 override 替换。
>
> 实际选择：(a) / (b) / (c) / 其他自定义？

> **决策点 D-2**：`add_delta` 五层累加顺序与 base 选择？
> - (a) **L1 作为 base，L2/L3/L4/L5 是 delta 累加**（推荐，物理直观）
> - (b) L5 作为 base，L1-L4 是 modifier
> - (c) 无 base 概念，5 层每层都是绝对值，最终 = sum() —— 不推荐，违反物理常识
>
> 物理直观（推荐 a）：`effective_temperature = material_default + normal_block_delta + refined_micro_delta + object_part_delta + environment_delta`。例如 default=20°C + macro_delta=+5 (此 chunk 较热) + micro_delta=+10 (这个 slot 是火源) = 35°C。

> **决策点 D-3**：`temperature_delta` / `moisture_delta` 字段（已在 NormalBlockData / MicroLayer 预留）如何与 catalog 的 temperature / moisture attribute 协调？
> - (a) **`temperature_delta` 字段是 L2 normal block override / L3 refined micro override 的 delta**（推荐，直接复用既有字段，避免双写）—— 当 Phase 1.2 `attribute_set_ref` 也指向 temperature 时，**两者取 sum 还是其中之一**？
>   - (a1) `temperature_delta` 字段 + `attribute_set.temperature.delta` 两者都生效，sum 累加（向后兼容）
>   - (a2) `attribute_set.temperature` 优先（catalog typed 路径），`temperature_delta` 弃用（保留字段但生产路径不读）
> - (b) `temperature_delta` 是 wire 层兼容字段，逻辑上 = `attribute_set` 中 temperature delta，二者**保证一致**（双写）
> - (c) `temperature_delta` 独立含义（与 catalog temperature 解耦）
>
> 推荐 **(a1)**：两者都生效 sum 累加，向后兼容 + 让 Phase 5.D 实施在两条路径上都可见。

> **决策点 D-4**：L4 object-part attribute 数据来源？
> - (a) **Phase 5.D 暂不接 L4**（推荐，Phase 5.D 仅实现 L1/L2/L3/L5 四层 merge，L4 留到 Phase 5.D.2 或更晚）—— 理由：Phase 4 `PartState` 当前只含 health / state_flags，不含 attribute；接 L4 需要扩 PartState 或新建 ObjectPartAttribute 表，工作量大且与 Phase 4 验收边界耦合
> - (b) 扩展 `PartState` 增加 `attribute_set_ref: u32`，从 ObjectRegistry 拿 PartState → AttributeSet
> - (c) 独立 ObjectPartAttribute table，按 (object_id, part_id) → AttributeSet

> **决策点 D-5**：`effective_attribute_at` API 输入
> - (a) **`effective_attribute_at(storage, macro_index_or_coord, attr_name_or_id)` 返回 effective value**（推荐，对 macro cell 一级聚合，refined micro 路径返回该 macro 内 default）
> - (b) `effective_attribute_at(storage, macro_index, micro_slot_index, attr_name)` 接 micro 粒度（Phase 5.D.2）
> - (c) 两版 API 都做

> 推荐 **(a)**：Phase 5.D 先做 macro 粒度（5.F simulator 主要在 macro 级跑），micro 粒度推到 5.F 真正需要时再做。

---

## 4. `Storage.effective_attribute_at` 算法（macro 粒度）

```elixir
def effective_attribute_at(storage, macro_index_or_coord, attr_name_or_id) do
  # 1. AttributeCatalog.lookup → 拿 def (含 default_value / min / max / merge_rule)
  # 2. macro_index_or_coord → macro_index
  # 3. 读 macro_header / normal_block / refined_cell / env_summary
  # 4. 按层抽取 layered_values:
  #    L1 material_default = def.default_value
  #    L2 normal_block_override = 
  #      cond:
  #        attr is temperature/moisture → normal_block.temperature_delta/moisture_delta (D-3)
  #        normal_block.attribute_set_ref ≠ 0 → 从 storage.attribute_sets[ref-1] 中查 entry
  #        else → no value
  #    L3 refined_micro_override = 
  #      macro 当前是 refined mode →
  #        遍历 refined_cell.layers → 每个 layer 的 attribute_set_ref → 抽 attribute
  #        如果只有一个 layer 有 attribute → 用它的 value
  #        如果多个 layer 都有 attribute → 按 layer 在 mask 中的 dominance 取（或最简单：取 first layer）
  #        Phase 5.D 简化策略待定（D-6?）
  #    L4 object_part_attribute = ignored (D-4)
  #    L5 environment_summary = macro_env_summary.current_temperature / current_moisture (仅 temperature / moisture 适用)
  # 5. 按 merge_rule 合并 layered_values 得到 effective_value
  # 6. 校验 effective_value 在 [min_value, max_value]
end
```

---

## 5. Test plan

新建 `apps/scene_server/test/scene_server/voxel/effective_attribute_test.exs`：

1. **material_default merge_rule（L1 only）**
   - 空 storage / empty macro / no attribute_set_ref → effective = default_value
   - density attribute (material_default) 即使 cell 设置了 attribute_set → effective 仍 = L1 default

2. **override merge_rule**
   - 单层有值：L2 (normal_block.attribute_set 含 temperature override=25.0) → effective = 25.0
   - 多层有值：L3 + L2 + L1 → effective = 最高 priority 层值（按 D-1 决定）

3. **add_delta merge_rule（temperature / humidity / moisture）**
   - 单层：L1 default=20 + L2 delta=+5 → effective = 25
   - 多层累加：L1=20 + L2=+5 + L3=+10 + L5=+2 → effective = 37（按 D-2 选 (a)）
   - `temperature_delta` 字段 + attribute_set 同时存在：按 D-3 (a1) 累加

4. **max / min merge_rule**
   - max: L1=20 / L2=15 → effective = 20
   - min: L1=20 / L5=18 → effective = 18

5. **edge cases**
   - 超出 [min_value, max_value]：clip？raise？warning？—— D-6
   - 未知 attr_name → raise

---

## 6. 实施顺序

依赖：Phase 5.A + 5.B + 5.C 已落地。

1. **D-1..D-5 决策**：用户复核
2. 新建 `effective_attribute_test.exs`（TDD red）
3. 改 `storage.ex` 新增 `effective_attribute_at/3` API + 私有 merge helpers
4. 跑测试（560 voxel baseline 不回归）
5. 同步文档（README + 主线进度文档）
6. commit `phase5d: five-tier attribute merge_rule + effective_attribute_at API`

---

## 7. 风险

- **决策点 D-1 优先级**：错误的优先级会让后续 simulator 算错值。建议明确测试覆盖每条 priority chain。
- **`temperature_delta` 双写**（D-3 (a1)）：当 `temperature_delta` 字段非 0 且 `attribute_set` 也含 temperature 时，sum 累加可能造成"重复扣减"或"重复加成"。需要测试验证 NormalBlockData 创建路径（`Storage.put_solid_block` / `put_attribute_for_cell`）是否会双写。
- **MicroLayer 多层 attribute_set 取值**（L3 抽取策略）：未在 D-1..D-5 决策中，建议在实施时选"任一 layer 有 attribute 即返回（按 mask dominance）"，并加测试。如果发现是真两难，记为 D-6 后续。
- **environment summary 当前未被任何 simulator 写入**（探索 agent 报告）：Phase 5.D effective_attribute_at 会读 L5，但 L5 在 Phase 5.E/F 之前总是默认值，所以 5.D 测试中 L5 全为 default。
