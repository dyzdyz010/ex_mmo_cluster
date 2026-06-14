# 涌现反应层设计(Reaction Layer · 功能完善阶段起点)

> 上层背景:架构对齐迁移(梯队 0–4)主体完成后转入**功能完善**(用户目标:"按涌现思路,先把现有代码里
> 的功能做到位")。本稿是功能完善第一块——闭合断裂的涌现回路。
> 纪律沿用:决策稿先行 → 逐 step commit(`mix format` + 回归)→ 进度日志 → 不 push → 不留兼容。
> 规范关联:RULE-11/AUTH-11(派生→权威经 system_actor)、RULE-15/16(锁存+幂等)、EMG-1/3/7(模型卡)。

## 1. 问题:涌现回路断在最后一步

源码精读(2026-06-14)确认:**物理量、材料阈值、tag 三块拼图都在,就差"反应层"把它们接起来。**

```
kernel 算场(温度/电流/电离)→ SystemActor 锁存 → ChunkProcess 写温度进 voxel truth → 【断】
                                                            ↓ 没有任何东西读已提交 truth 触发世界变化
```

- 5 个 field kernel 只算数;只有 conduction/discharge 把热量写回 `:temperature` truth,其余产空 effect。
- `MaterialCatalog` 已定义 `ignition_temperature`/`melting_point`/`freezing_point`/`boiling_point`(冰
  melting=0℃、木 ignition=300℃、铁 melting=1538℃…)却是**死元数据**——无代码拿温度比对触发转变。
- tag(`flammable/burning/wet/frozen`)是死的;电流不驱动任何东西;README 自标"还没有 Phase 8
  damage/ignite/breakdown 结算"。

## 2. 用户拍板(2026-06-14)

- **先后**:先搭**行为无关的反应层骨架**(立 ReactionRuntime/Engine + 规则引擎 + SystemActor 接线 +
  模型卡 + 一条最小 demo 规则把回路立住),再逐一填 燃烧 / 相变 / 电→世界 三类行为。
- **规则表征**:**两者结合**——材料相变走 `MaterialCatalog` 阈值表驱动(数据化,材料 X@温度 T → 材料 Y);
  tag 反应走声明式规则;coded reaction kernel 只承载复杂时序/级联。

## 3. 设计:反应层 = 引擎(纯)+ 驱动(field 复用)+ 效果(经 SystemActor)

**关键洞察:刚搭的架构就是为这块准备的。** 反应是典型的 derived→authoritative 写(由温度物理派生,写材料
truth),正是 `SystemActor`(AUTH-11 唯一桥)的目标消费者;复用 `SimRuntime` tick、模型卡(EMG-1/3/7)、
candidate_effect 锁存(RULE-15/16)。**不新建并行权威路径,不破坏任何承重契约。**

### 3.1 新模块

| 模块 | 职责 | 形态 |
|---|---|---|
| `SceneServer.Voxel.Reaction.Rule` | 反应规则结构:`:phase_transition`(阈值驱动,from_material + 条件{attr,op,阈值名} + to_material)/ `:tag_reaction`(when_tags + 条件 → add/remove tag,骨架先定形不全接) | 纯数据 struct |
| `SceneServer.Voxel.Reaction.Rules` | 规范规则表 `all/0` + `for_material/1`;seed ice→water demo + 结构留位 | 纯数据 |
| `SceneServer.Voxel.Reaction.Engine` | **纯**:`evaluate(cells, rules) → [reaction_effect]`;cell=`%{macro_index, material_id, temperature_celsius, tags}`;产 `{:transform_material, %{macro_index, from_material_id, to_material_id, rule_id}}` | 纯函数,驱动无关 |
| `SceneServer.Voxel.Field.Kernels.ReactionKernel` | 骨架驱动:field-kernel adapter,读 `context.storage` 已提交 truth(材料 + `effective_attribute_at "temperature"`)over region aabb → 建 cell 列表 → 调 Engine → 返 reaction effects;带 `model_card`(EMG-1/3/7) | field kernel |

**反应读"已提交 truth"而非 field 层**:reaction 消费权威态(`Storage.normal_block_at` 材料 +
`effective_attribute_at` 温度),field 层是产生 truth 温度的物理(conduction/discharge 写回 / set_temperature
正式路径)。truth-based 反应对齐审计建议("daemon reads abnormal attributes from storage")。

### 3.2 效果通路(复用 SystemActor + ChunkProcess)

- **SystemActor**:加 `gate({:transform_material, attrs})` 子句。**复用 bucket 锁存**:`latch_key =
  {cell, kernel_id, macro_index, :material}`,`bucket = to_material_id`(离散材料 id 即桶,无需量化)。
  同 {cell,macro,目标材料} 已提交 → latched 幂等跳过(防同 tick 重复转);目标变(水→蒸汽)→ 新桶提交。
  candidate_effect_id 稳定(RULE-16)。
- **ChunkProcess**:`apply_field_effect` 加 `:transform_material` 分支 → `apply_transform_material_effect`:
  读 `normal_block_at(macro)` 现材料,**校验 == from_material_id**(防过期转,显式 reject 不静默),
  `put_solid_block` 换 to_material(保留/重置属性),bump chunk_version,push snapshot,emit
  `voxel_material_transformed`。

### 3.3 catalog 补料

- 加 `water` 材料(id 8):demo 转变目标。属性 density≈1000、thermal_conductivity≈0.6、freezing_point=0
  (可逆冻回)、boiling_point=100、flammable 否、electric_conductivity 低。后续燃烧补 `ash`/`steam`/`lava`。

### 3.4 模型卡(EMG-1/3/7)

ReactionKernel 模型卡:`fidelity_class: :qualitative`(阈值锁存式相变,非严格热力学/潜热);
`safety_valve: %{type: :reaction_budget, max_transforms_per_tick: N}`(防失控级联);assumptions
("阈值瞬时相变无潜热延迟"、"chunk-local"、"truth 温度驱动")。

## 4. 子步(逐步 commit + 回归闸门,仿梯队做法)

- **R1**:`Reaction.Rule` + `Reaction.Rules` + `Reaction.Engine` 纯核 + 全量单测(数据化阈值 eval、
  ice→water demo 规则、行为无关结构)。`MaterialCatalog` 加 water。**新模块,构造上 0 回归。**
- **R2**:`:transform_material` 端到端——SystemActor `gate` 子句(transform 锁存幂等)+ ChunkProcess
  `apply_transform_material_effect`(put_solid_block + from 校验 + 版本 bump + snapshot + observe)。
  单测:transform 锁存幂等、from 不匹配 reject、应用后材料变 + 版本 +1 + 快照。
- **R3**:`ReactionKernel`(field adapter,读 truth,模型卡)+ 接 field tick 链。端到端 demo 测试:
  置冰格 → set_temperature ≥ 0℃ → tick → 冰变水(storage + snapshot)。回归 scene 全量 0 净回归。

> 排序理由:R1 纯核独立可测;R2 把效果通路打通(回路的"写"端);R3 接驱动闭环。三步后:**温度物理 →
> 读 truth → 阈值规则 → 材料转变 → 快照下行 → 客户端可见**,涌现回路闭合,且骨架行为无关——燃烧/电→世界
> 只是往 `Rules` 加规则 + 必要 coded kernel。

## 5. 验收

- 回路闭合:加热冰格 → 冰在 truth 中变水 → snapshot 反映 → web_client 可见(主线端)。
- 反应经 SystemActor(RULE-11/AUTH-11)+ 锁存幂等(RULE-15/16);ChunkProcess from 校验显式 reject。
- 反应层骨架**行为无关**:规则数据化 + coded 留口;模型卡(EMG-1/3/7)+ 安全阀预算。
- scene 全量 0 净回归。

## 进度日志(时间倒序)

- 2026-06-14:决策稿落定。用户拍板"先搭行为无关骨架 + 规则两者结合"。拆 R1(纯核)/R2(效果通路)/
  R3(驱动闭环)。先执行 R1。
