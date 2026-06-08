# Phase 8: 物理现象系统架构目标

状态：设计目标稿；等待 Phase 7.D2 / 7.D3 局部场运行时补完后进入实现  
日期：2026-05-16  
归属：goal `voxel-authoritative-and-field-minimum` Phase 8  

关联文档：

- `docs/plans/2026-05-16-phase7-local-field-runtime-roadmap.md`
- `docs/plans/2026-05-14-phase7-field-kernel-architecture.md`
- `docs/2026-05-13-体素局部场最小目标-索引.md`
- `docs/voxel-server-authority/README.md`

本文档定义 Phase 8 的“物理现象系统”边界。它不是替代 `FieldRuntime`，而是在
局部场运行时补完后，承接燃烧、结冰、结构完整度、碳化、腐蚀、相变等条件触发和
持久状态转换。

---

## 1. 背景

Phase 7 的局部场解决的是“连续量异常如何在局部空间传播”：

- 温度异常扩散；
- 电势 / 电离传播；
- 后续可能的湿度、压力、烟尘、腐蚀介质浓度等 field；
- source 生命周期；
- effect 写回边界。

燃烧、结冰、相变、腐蚀、碳化、结构破坏不是单纯 field。它们是：

```text
voxel / object truth
+ local field state
+ material physical properties
+ environment constraints
+ time / exposure
=> phenomenon state transition
=> structured effects
```

因此 Phase 8 应新增一个独立的 `PhenomenonSystem`，负责判断“某个物理现象是否启动、
持续、结束，以及它向 FieldRuntime / voxel truth / object truth 产出什么 effect”。

---

## 2. 分层边界

推荐分层：

```text
Voxel / Object Truth
  material_id, attributes, object state, structural state

Material Physical Catalog
  density, specific_heat_capacity, ignition_temperature,
  melting_point, corrosion_resistance, strength, etc.

Local Field Runtime
  temperature, moisture, electric_potential, ionization,
  pressure, smoke_density, chemical_concentration

Physical Phenomenon System
  combustion, freezing, melting, boiling, carbonization,
  corrosion, structural_failure

Gameplay / Magic / Weather
  fireball, ice spell, acid cloud, lightning, storm, device
```

边界规则：

1. UI / Combat / Magic / Weather 不直接创建 `FieldRegion`，只提交 source 或 phenomenon
   request。
2. `FieldKernel` 只演化 field，并产出结构化 `FieldEffect`；它不直接决定“木头变成炭”。
3. `PhenomenonSystem` 读取 truth + field + material，输出 `PhenomenonEffect`。
4. 所有持久写回仍通过权威 dispatcher / `ChunkProcess` / object owner 边界执行。
5. phenomenon 可以创建或续租 `FieldSource`，但不能绕过 `FieldRuntime` 手动造 field。

---

## 3. 核心模型

### 3.1 PhenomenonDefinition

定义某类现象的条件、状态机和 effect 输出。

```text
PhenomenonDefinition
  id: :combustion | :freezing | :corrosion | ...
  required_truth: [attribute | material_property | object_state]
  required_fields: [field_type]
  activation_conditions
  sustain_conditions
  termination_conditions
  state_schema
  tick_policy
  effect_rules
```

### 3.2 PhenomenonInstance

某个 voxel、object part 或局部区域上的活跃现象实例。

```text
PhenomenonInstance
  instance_id
  definition_id
  owner_ref: voxel | object_part | region | gameplay_effect
  location: world_macro | aabb | object_part_ref
  state
  created_tick
  updated_tick
  exposure_budget
  source_refs
  version / lease_token
```

`PhenomenonInstance` 是运行时事实，不一定长期持久化。长期结果应写回 voxel / object truth，
例如 `material_state: :charred`、`moisture: 0`、`structural_integrity: 0.42`。

### 3.3 PhenomenonEffect

现象系统输出的结构化副作用。

```text
PhenomenonEffect
  :write_voxel_attribute
  :write_voxel_material_state
  :write_object_attribute
  :spawn_field_source
  :update_field_source
  :destroy_field_source
  :spawn_visual_cue
  :emit_observe
```

第一版不要直接接 Combat HP。先把 voxel / object physical state 闭合，再把 gameplay damage
作为后续 bridge。

---

## 4. 与 FieldSource / FieldEffect 的关系

Phase 7.D2 / D3 是 Phase 8 的前置条件。

```text
FieldSource
  描述“为什么这里有一个连续量异常需要运行 field”

FieldKernel
  演化 field layer

FieldEffect
  把 field 变化提交给权威 dispatcher

PhenomenonSystem
  判断 field + truth 是否触发现象，并产生持久状态转换或新的 source
```

例子：燃烧不是温度 field 自己“变成火”。更合理的链路是：

```text
temperature field raises wood voxel above ignition_temperature
+ oxygen > threshold
+ moisture below threshold
=> PhenomenonSystem starts CombustionInstance
=> CombustionInstance emits:
     spawn_field_source(:temperature, power_watts)
     write_voxel_attribute(:fuel_mass, -delta)
     write_voxel_attribute(:oxygen, -delta)
     write_voxel_material_state(:charred) when fuel depleted
```

这样 field 负责传播热，phenomenon 负责燃烧状态机。

---

## 5. 第一批现象

### 5.1 Combustion

输入：

- `temperature`
- `oxygen`
- `moisture`
- `fuel_mass`
- material `ignition_temperature`
- material `combustion_heat_j_per_kg`
- material `flammability`

状态：

```text
preheat -> burning -> smoldering -> extinguished
```

effect：

- 产生持续 `temperature` source；
- 消耗 fuel / oxygen；
- 增加 smoke / soot / carbonization；
- 降低 structural_integrity；
- 可能生成 ember / fire visual cue。

### 5.2 Freezing / Melting / Boiling

输入：

- `temperature`
- `moisture` 或 water content；
- material `freezing_point` / `melting_point` / `boiling_point`；
- optional `latent_heat_j_per_kg`。

状态：

```text
liquid -> freezing -> solid
solid -> melting -> liquid
liquid -> boiling -> vapor
```

effect：

- 改写 material_state 或 phase_state；
- 改变 thermal_conductivity / density / permeability 派生结果；
- 对 structure 施加 expansion stress；
- 产生 cold / steam / ice cue。

### 5.3 Structural Integrity

输入：

- object / voxel `structural_integrity`；
- temperature gradient；
- freezing expansion；
- impact / pressure；
- corrosion / burning damage；
- material `compressive_strength` / `tensile_strength`。

状态：

```text
intact -> stressed -> cracked -> failed
```

effect：

- 降低 integrity；
- 生成 crack / collapse candidate；
- 对 prefab / object part 触发结构重算；
- 后续接 object damage，不在第一版直接接 HP。

### 5.4 Carbonization

输入：

- combustion exposure；
- oxygen-limited high temperature；
- material organic tag；
- remaining fuel / moisture。

状态：

```text
raw -> dried -> charred -> ash
```

effect：

- 改写 material_state；
- 降低 fuel_mass；
- 改变 density / thermal_conductivity 派生值；
- 影响后续燃烧和结构强度。

### 5.5 Corrosion

输入：

- moisture；
- chemical_concentration / acidity；
- oxygen；
- material `corrosion_resistance`；
- exposure time。

状态：

```text
clean -> exposed -> corroding -> weakened
```

effect：

- 降低 structural_integrity；
- 改写 surface_state；
- 可能释放 chemical source 或 particle cue；
- 改变 electric_conductivity。

---

## 6. 材料属性需求

Phase 8 不应一次性把所有属性塞进 voxel 动态 truth。默认：

- 稳定物性在 material catalog；
- 动态状态在 voxel/object attributes；
- 派生属性由 material + state 计算。

建议新增或补齐：

```text
ignition_temperature_celsius
combustion_heat_j_per_kg
fuel_mass_kg_per_m3
oxygen_requirement
smoke_yield
freezing_point_celsius
melting_point_celsius
boiling_point_celsius
latent_heat_j_per_kg
corrosion_resistance
compressive_strength_pa
tensile_strength_pa
thermal_expansion_coefficient
```

每个属性必须有单位、范围、默认值、fixture/hash 测试和文档说明。

---

## 7. 实施路线

### Phase 8.A：PhenomenonSystem skeleton

目标：先建立现象定义、实例、effect 数据结构和 dispatcher 边界。

验收：

- 有 `PhenomenonDefinition` / `PhenomenonInstance` / `PhenomenonEffect`；
- 有只读 evaluation context；
- 有 effect dispatcher stub；
- 不接具体燃烧规则也能单测 instance lifecycle。

### Phase 8.B：Combustion minimum

目标：用木材高温点燃证明 field -> phenomenon -> field source / truth writeback。

验收：

- 高温 + 木材 + 氧气满足阈值时创建 `CombustionInstance`；
- 燃烧产生持续 heat source；
- 燃料耗尽后 material_state 进入 charred / ash；
- observe 可见 ignition / burning / extinguished。

2026-06-06 首片进展：

- 已落 `SceneServer.Voxel.Phenomenon` 边界：燃烧规则读取 voxel truth、temperature
  field 和 `MaterialCatalog`，只输出结构化 effect；
- attribute catalog v3 已追加 `fuel_mass`、`oxygen`、`combustion_stage`、
  `combustion_progress`、`smoke_density`、`carbonization`、`structural_integrity`；
- material catalog 已追加 ash / charcoal，并定义 wood -> charcoal -> ash 的默认燃烧链；
- material catalog 已追加 dry grass / cloth 两类可燃材料，分别覆盖烧光消失和燃尽成灰；
- material combustion profile 已开始使用 `combustion_heat_j_per_kg` /
  `heat_release_efficiency`：燃烧 heat source 不再只是固定温度，而是按本 tick
  fuel 消耗释放的焦耳热除以 voxel 热容换算，再受材料明火/阴燃热源上限约束；
- 默认 temperature `FieldSource` 会同时运行 temperature diffusion 与 combustion kernel；
- `/ingame/voxel/set_temperature` / `dev_heat_voxel` 已改为先经 World
  `MapLedger.route_chunk_with_lease` 路由 source chunk，再把 lease 透传给 Scene
  `FieldRuntime`，避免高温燃烧入口在 region / 多 scene 下写到非 owner chunk；
- `ChunkProcess` 已支持普通属性写回、材料转化和烧尽清空三类 phenomenon writeback。
- 同一地块内已验证燃烧产生的持续 heat source 可经 temperature diffusion 在后续 tick
  点燃邻近可燃材料。
- 燃烧已补最小自持生命周期：burning / smoldering 会创建或刷新稳定
  `{:combustion_instance, logical_scene_id, chunk_coord, macro_index}` FieldSource，
  触发它的外部 heat impulse 到期后仍可继续消耗 fuel / oxygen 并产热；这复用现有
  FieldRegion source lifecycle，不另起平行 GenServer。
- 烟雾已进入一等场层：燃烧仍写回 voxel `smoke_density` 作为本地真值，但同时输出
  `:smoke_density` field source；`SmokeDiffusionKernel` 负责烟雾扩散/衰减，
  `FieldCodec` 与 web client 0x73 协议使用 mask bit `0x10` 发布 f32 smoke density
  数组。烟雾表现因此进入 FieldRuntime，而不是只停在单格属性上。
- 氧气也已进入一等场层：燃烧仍写回 voxel `oxygen` 作为本地权威历史，同时输出
  `:oxygen` field source；`OxygenDiffusionKernel` 负责氧气缺口扩散和向 100% ambient
  恢复，`FieldCodec` 与 web client 0x73 协议使用 mask bit `0x20` 发布 f32 oxygen
  数组。燃烧判定在目标格有 active oxygen field deficit 时会优先使用场值，因此低氧热环境
  会走 carbonization 而不是普通 ignition。
- 湿度也已进入一等场层：湿材料受热时仍通过 `moisture` 写回保留材料真值，但被蒸发/带走的
  水分会输出 `:moisture` field source；`MoistureDiffusionKernel` 负责水汽扩散和衰减，
  `FieldCodec` 与 web client 0x73 协议使用 mask bit `0x40` 发布 f32 moisture 数组。
  燃烧判定在目标格有 active moisture field 时会优先使用场值，因此潮湿/水汽环境会先延迟点燃。
- 跨 chunk face 的火势传播已接入：边界燃烧源输出 `ensure_field_region` effect，
  源 chunk 只负责队列化交接，目标 chunk 经自己的 authority 启动 temperature/combustion
  region 并决定目标材料是否点燃；remote handoff 已避免把 source lease 带入 target
  FieldRegion，目标 region 会捕获目标 chunk 当前 lease。跨节点 lease boundary 事件仍是后续项。
- 湿材料不会在高温下被阈值式直接点燃；combustion kernel 会先输出 moisture
  写回、水汽 field source 和 `voxel_combustion_dried` observe，后续 tick 读取 Chunk 权威湿度
  或 active moisture field 低于材料阈值后才能进入 ignition / burning。
- 低剩余燃料会从 burning 进入 smoldering，并输出 `voxel_combustion_smoldering`
  observe；smoldering 使用材料 profile 中更低的 heat-source cap 与释放比例，而不是继续按
  明火热源表现。
- 氧气低于材料维持阈值时，高温不会启动自持燃烧；木材会走 oxygen-limited
  carbonization，写回 `carbonization` / `structural_integrity`，碳化越过材料阈值后
  通过 Chunk authority 转为 charcoal。
- 已补只读燃烧真值查询入口：`/ingame/voxel/combustion_probe` 与浏览器 CLI
  `voxel_combustion <x> <y> <z>` 会回读目标 chunk authority 中的材料、阶段、
  fuel / oxygen、smoke、carbonization、structural_integrity 和残留策略，避免只能通过
  overlay 间接判断燃烧状态。
- HTTP 端到端验收已覆盖 `set_temperature -> field tick combustion -> combustion_probe`：
  授权 chunk 中的木材被高温入口点燃后，probe 能读到 burning、fuel/oxygen/progress
  变化以及材料热值 profile。
- 已补 chunk-local `PhenomenonInstance` 最小账本：燃烧规则输出
  `upsert_phenomenon_instance` / `complete_phenomenon_instance` effect，
  `ChunkProcess` 作为 authority 维护活动实例，`combustion_probe` 可直接返回活动火焰的
  instance id、stage、更新时间和 field source 引用，不再只能从 voxel attribute 推断
  “火是否还活着”。
- Phase 8.D 的结构损伤已从燃烧专属逻辑收口到共享
  `SceneServer.Voxel.Phenomenon.StructuralIntegrity` effect 边界：燃烧、低氧碳化和
  冻结都会经同一规则写回 `structural_integrity`，并只在跨过阈值时产生一次
  `voxel_structural_collapse_candidate` observe，作为 object / prefab 坍塌结算的
  前置入口；同时会产出 `apply_structural_damage` effect，由 `ChunkProcess` 读取
  owner micro-slot 覆盖并转交既有 `ObjectRegistry.accumulate_damage`，field kernel
  和 phenomenon 仍不直接修改 object truth。
- 当前实例账本仍是 chunk-local in-memory；烟雾、氧气和湿度也还只是 chunk-local 标量扩散，
  已补含水冻结/沸腾的最小状态机，但尚未实现凝结、材料本体熔化/凝固、真实气流/压力、
  烟雾/氧气/水汽跨 chunk handoff、snapshot 持久化、跨节点边界事件或 object / prefab 生命周期，
  不能把本片误读为完整现象实例系统已经完成。

### Phase 8.C：Freezing / phase change minimum

目标：用水分和低温证明降温链路不是 heat-only。

验收：

- `temperature < freezing_point` + moisture 触发 freezing；
- 写回 frozen / ice state；
- 结构膨胀压力作为 effect 暂存或写入 structural stress；
- web overlay 能看到 cold field + frozen state。

2026-06-08 首片进展：

- attribute catalog v4 追加 `phase_state`，用 0 stable / 1 frozen / 2 boiling /
  3 vapor 保存单格含水相态；
- 已落 `SceneServer.Voxel.Phenomenon.PhaseChange` 纯规则：低温含水格写回 frozen
  state 并降低 `structural_integrity`；高温含水格降低 `moisture`，写回 boiling /
  vapor state，并释放 `:moisture` field source；
- 已落 `ThermalKernelSpecs` 共享内核 bundle：默认 `set_temperature` 温度源、燃烧
  owner heat region 和 combustion boundary heat region 都通过同一套
  temperature/combustion/phase-change/smoke/oxygen/moisture 链路运行；
- 已补只读相变真值查询入口：`/ingame/voxel/phase_change_probe` 与浏览器 CLI
  `voxel_phase <x> <y> <z>` 会回读目标 chunk authority 中的材料、`phase_state`、
  温度、含水量、结构完整度、contained-water 阈值和 active `phase_change` instance；
- 当前只覆盖“材料中水分”的冻结和沸腾，不覆盖铁/石/泥等材料本体熔化、凝固、潜热守恒或
  可视化冰层模型。

### Phase 8.D：Structural integrity

目标：把燃烧、冻结、腐蚀等现象对结构的影响统一到一个 integrity 账本。

验收：

- integrity 可被多种 phenomenon effect 修改；
- 低于阈值时产出 collapse candidate；
- object / prefab 边界不被 field kernel 直接修改。

2026-06-08 首片进展：

- 已落共享 `StructuralIntegrity` effect 边界，负责百分比裁剪、`structural_integrity`
  truth 写回，以及阈值穿越时的 `voxel_structural_collapse_candidate` observe；
- 燃烧、低氧碳化和冻结已接入同一结构损伤边界，避免每个现象各自维护坍塌候选语义；
- `ChunkProcess` 已能处理 `apply_structural_damage` effect：它从失败 macro 的
  owner refs 聚合 `(object_id, part_id) => micro-slot count`，再复用
  `ObjectRegistry.accumulate_damage` 进入现有 part-health / part-destroy cascade；
- 当前仍不做结构稳定性重算、裂纹传播、debris 生成或玩家战斗伤害结算。

### Phase 8.E：Corrosion / carbonization expansion

目标：增加化学/表面状态类现象，证明 system 不局限于热。

验收：

- corrosion 可由 moisture + chemical source 触发；
- carbonization 可由 oxygen-limited combustion 触发；
- material/state 派生属性影响后续 field 和 phenomenon 判断。

---

## 8. 非目标

Phase 8 第一版不做：

1. 工程级 CFD、燃烧化学或有限元结构模拟；
2. 每 micro voxel 独立完整物理账本；
3. 玩家 HP / Combat damage 的最终接入；
4. Sevara 直接执行物理法则；
5. 把所有物理属性动态写入每个 voxel；
6. 用一个巨大 field 表示核爆级大范围灾变。

目标是游戏服务器可承受、机制可组合、调试可观测的物理现象层。

---

## 9. 进入 Phase 8 前置检查

必须先完成：

1. Phase 7.D2 / 7.F 前置：`FieldSource` registry + 生命周期（温度最小闭环已完成，electric owner/ttl/budget 第一片已完成，generic owner 存活探测、budget 消耗与跨 chunk lifecycle 留后续）；
2. Phase 7.D3：`FieldEffect` dispatcher + truth 写回（温度写回最小闭环已完成，candidate phenomenon / object effect 留后续）；
3. Phase 7.E：材料与环境模型最小扩展；
4. CLI / observe / overlay 对 field source、field effect、voxel state writeback 可见；
5. browser smoke 能从用户入口触发 hot / cold 并看到 field 与 truth 的变化。

满足这些后再开始 Phase 8.A。
