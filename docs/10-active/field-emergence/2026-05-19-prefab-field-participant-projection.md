# Prefab Field Participant Projection 架构设计

状态：设计基准稿，作为 Phase 7 / Phase 8 之间把 prefab 接入所有局部场的推进依据。
日期：2026-05-19
适用范围：`ex_mmo_cluster` 的 voxel truth、prefab/object provenance、FieldRuntime、FieldKernel、FieldEffect。
首条验证路径：电场。电场只是测试点，不是本设计的专用目标。

关联文档：

- `docs/docs/10-active/field-emergence/2026-05-16-phase7-local-field-runtime-roadmap.md`
- `docs/docs/10-active/field-emergence/2026-05-16-phase8-physical-phenomenon-system-architecture.md`
- `docs/docs/20-archive/voxel-authority/phase-4-object-provenance.md`
- `docs/2026-04-24-web-client-prefab-microgrid-jump-implementation.md`

---

## 1. 业务目标

prefab 不能只接入电源设备，也不能让每一种场分别写一套 prefab 特判。

目标是把已经放进世界的 prefab 变成所有局部场的通用参与者：

- 电场能把 prefab 当作导体、绝缘体、电源端口、负载或击穿目标。
- 热场能把 prefab 当作热容量、热导介质、燃烧/融化/冒烟目标。
- 烟尘和气体场能把 prefab 当作阻挡、孔隙、通风面或释放源。
- 压力和冲击场能把 prefab 当作结构阻力、破裂目标或传递介质。
- 魔法和异常场能把 prefab 当作标签载体、锚点、共鸣体、抗性体或转化目标。

电场是第一条验收路线，因为当前已经有 `ConductionPathKernel`、物性目录、电热写回和热烟 UI，可以用较小范围证明通用架构可行。

---

## 2. 非目标

本设计不把 prefab 绑定成“电源设备系统”。电源、导线、墙体、楼梯、魔法阵、门、机器外壳都应走同一套 field participant 投影。

本设计不要求每个 field tick 都以 micro 分辨率运行。宏格仍是默认场模拟网格，micro 只在几何、部件、连通、局部破坏和精确投影时参与。

本设计不在第一片完成所有场类型。第一片只让电场通过通用投影层读取 prefab，后续热、烟尘、压力、魔法复用同一边界。

本设计不绕过现有 object provenance。prefab 在场系统里的身份必须来自已放置对象、部件和 micro owner，而不是 field 子系统单独维护一份对象真相。

---

## 3. 当前基线

已有底座：

1. 世界使用 `chunk -> macro -> micro` 三层结构。一个 chunk 是 `16x16x16` 个 macro，一个 macro 是 `8x8x8` 个 micro。
2. 服务端已有 refined micro truth：普通 solid macro 可以压缩表示，refined macro 可以保存 micro occupancy。
3. prefab 放置已经可以把蓝图 rasterize 到 chunk/micro truth。
4. object provenance 已经存在：micro layer 可以记录 `owner_object_id` 和 `owner_part_id`，并可反向查询对象/部件。
5. `FieldRuntime` 已经负责 source/region lifecycle，`FieldKernel` 演化 field，`FieldEffect` 是写回 voxel/object truth 的边界。
6. 电场已有 chunk-local conduction path，热场已有温度扩散和电热写回的最小闭环。

缺口：

1. field kernel 目前主要从 voxel/material 属性读值，不具备“prefab/object 作为通用 field participant”的统一投影。
2. refined micro 和 macro field 网格之间没有一层明确的采样/聚合契约。
3. 电场连通可以读材料电导率，但还不能表达 prefab 内部的 micro 连通、部件状态、端口和破坏后投影失效。
4. 后续热、烟尘、压力、魔法如果各自读取 prefab，会快速形成重复逻辑和特判。

---

## 4. 核心决策

新增概念：`FieldParticipantProjection`。

它不是新的世界真相层，而是 `FieldRuntime` 面向 field kernel 构建的只读投影。它把 voxel、material、prefab、object、environment 的常态 truth 转成“某个 field 在某个区域需要看到的参与者摘要”。

```text
voxel / material / prefab / object / environment truth
  -> FieldParticipantProjection
  -> FieldKernel
  -> FieldEffect
  -> versioned voxel/object mutation
```

关键边界：

- `FieldKernel` 不直接查询 prefab、ObjectRegistry 或 ChunkStorage 细节。
- `FieldKernel` 只读取 `FieldParticipantProjection` 和 field layer。
- `FieldRuntime` 负责在创建/刷新 field region 时构建 projection snapshot。
- `FieldEffect` 负责把 field 结果回写到 macro、micro 或 object part。
- projection 是派生数据，可以缓存、重算和丢弃；真实状态仍在 voxel/object/material。

---

## 5. 宏格和微格的和解规则

### 5.1 统一地址

底层地址使用 `world_micro`。宏格地址由 micro 地址派生：

```text
world_macro = floor(world_micro / 8)
local_micro = world_micro mod 8
```

负坐标必须沿用现有 floor division 规则，保证 `local_micro` 始终落在 `0..7`。

### 5.2 macro 是默认模拟格，micro 是精细几何和身份格

macro 的职责：

- chunk 存储和订阅的主索引。
- FieldRegion 的默认采样网格。
- 大多数 field kernel 的默认 tick 单元。
- overlay、AOI 和网络预算的默认聚合单元。

micro 的职责：

- prefab 几何精度。
- 局部破坏精度。
- object/part provenance。
- refined 介质连通、孔隙、接触面、端口位置。
- field effect 精确回写时的分摊目标。

### 5.3 三种 macro 表达

```text
empty macro
  512 个 micro 都空。

solid macro
  512 个 micro 被同一普通材料占满。
  存储上压缩为一个 solid block。
  projection 时可虚拟展开成同质 micro。

refined macro
  512 个 micro 中部分占用，或存在多材料、多部件、多对象。
  存储 micro mask、material、state、owner_object_id、owner_part_id。
```

任何 field 不得把 refined macro 简化成“整格都导电”或“整格都阻挡”。它必须通过 projection 的场类型摘要读取。

### 5.4 聚合不是简单平均

不同场对同一个 refined macro 的读取方式不同：

- 电场关注导电 micro 是否形成面到面的连通。
- 热场关注材料占比、热容量、接触面积和温度写回对象。
- 烟尘/气体场关注空隙率、阻挡率和通风方向。
- 压力场关注结构强度、受力面和破裂阈值。
- 魔法场关注标签、锚点、共鸣、抗性和转化规则。

因此 projection 必须按 field family 生成摘要，而不是输出一个全场通用的“平均材料”。

---

## 6. FieldParticipantProjection 数据形态

建议把 projection 分成通用头和 field-specific sections。

```text
FieldParticipantProjection
  projection_id
  chunk_coord
  region_aabb_world_micro
  chunk_version
  object_versions
  material_catalog_version
  generated_at_tick
  macro_entries[]
```

每个 `macro_entry`：

```text
MacroProjection
  world_macro
  cell_mode: empty | solid | refined
  occupancy_ratio
  dominant_material_id
  material_mix[]
  object_refs[]
  part_refs[]
  boundary_flags
  electric
  thermal
  gas
  pressure
  magic
```

通用字段的业务含义：

- `occupancy_ratio`：该 macro 内有多少 micro 被占用。
- `material_mix`：按材料、占用比例、表面积或质量估算的材料组成。
- `object_refs`：该 macro 内涉及哪些 object。
- `part_refs`：该 macro 内涉及哪些 object part。
- `boundary_flags`：是否跨 chunk、是否需要邻居采样、是否有不完整投影。

field-specific section 只放该场会读取的内容。电场不需要读取魔法共鸣，烟尘场不需要读取电压端口。

---

## 7. 各类场的 prefab 投影

### 7.1 电场投影

电场投影关注电源、导体、绝缘体、击穿、连通和负载。

```text
ElectricProjection
  conductive_face_graph
  conductive_face_contacts
  conductivity_by_face
  dielectric_strength_by_face
  source_ports[]
  load_ports[]
  object_part_conductors[]
  breaker_flags
```

`conductive_face_graph` 表示该 macro 六个面之间是否通过内部导电 micro 连通。它不等价于“该 macro 有导电材料”。

`conductive_face_contacts` 表示某个面上具体哪些 micro 槽位暴露为导电接点。两个相邻
macro 只有在共享面上的接点坐标重叠时才算真正接触；仅仅都碰到同一个宏观面不算连通。

例子：

- 一个铁丝 prefab 只穿过 x- 到 x+，则只允许 x 方向导通。
- 一个被打断的导线 prefab 即使仍有铁材料，也不能跨断点导通。
- 一个绝缘外壳包住导体时，外部面不应被误判为可导通。
- 两段 prefab 导线都贴在同一个共享面，但一段在上角、一段在下角时，不应被误接成一条电路。

### 7.2 热场投影

热场投影关注热容量、热导率、接触面积、燃点、融点和受热对象。

```text
ThermalProjection
  effective_heat_capacity
  effective_thermal_conductivity
  exposed_surface_ratio_by_face
  ignition_candidates[]
  melt_candidates[]
  smoke_emitters[]
  object_part_heat_targets[]
```

热 kernel 可以继续按 macro 跑；当 FieldEffect 写回时，再按 material/object/part 分摊热量。

### 7.3 烟尘和气体投影

烟尘/气体投影关注空间可通行性。

```text
GasProjection
  porosity
  blockage_by_face
  ventilation_face_graph
  absorber_materials[]
  emitter_parts[]
```

一个窗户 prefab 可能对电场是绝缘体，对烟尘场却是通风孔。

### 7.4 压力和冲击投影

压力场投影关注受力、结构强度和破坏阈值。

```text
PressureProjection
  structural_resistance
  fracture_threshold
  load_bearing_parts[]
  impulse_transfer_by_face
```

这为后续爆炸、冲击波、坍塌、门板破裂预留同一条边界。

### 7.5 魔法和异常场投影

魔法场投影关注标签、锚点、共鸣和抗性。

```text
MagicProjection
  tags[]
  anchors[]
  resonance_channels[]
  resistance_profile
  transformation_targets[]
```

魔法场不能直接理解 prefab 蓝图结构。它只能通过 projection 读取“这个对象/部件对该类异常场暴露了什么”。

---

## 8. 投影生成流程

```text
FieldRuntime requests projection
  -> read chunk storage snapshot
  -> read object/part snapshot from ObjectRegistry
  -> read material attributes from catalog
  -> normalize macro/micro coverage
  -> build common MacroProjection
  -> build field-specific sections requested by kernel
  -> cache projection with chunk_version/object_versions/catalog_version
```

缓存失效条件：

- chunk storage version 变化。
- refined micro mask 变化。
- object part state 变化。
- object destroyed 或 part destroyed。
- material catalog version 变化。
- field source 的 owner/port 状态变化。

缓存粒度建议：

- 第一片按 chunk 或 region AABB 重算，优先正确性。
- 后续按 changed macro/object refs 做增量失效。
- projection 可以比 FieldLayer 生命周期短，不需要持久化。

---

## 9. FieldEffect 回写规则

FieldEffect 不应只写 macro attribute。对于 refined prefab，必须能按策略回写到 object part 或 micro。

建议支持四类分摊策略：

```text
whole_macro
  整个 macro 作为普通块处理。

material_weighted
  按 material_mix 分摊效果。

surface_contact
  按与 field 方向、接触面或暴露面积分摊。

part_ownership
  按 owner_object_id / owner_part_id 聚合到对象部件。
```

例子：

- 电热写回：可先按导电路径的 conductor parts 分摊，再写温度属性或 object heat state。
- 冒烟：按 overheated object part 生成 smoke emitter，而不是给整格染色。
- 击穿：对 dielectric_strength 不足的 part 产生 damage candidate。
- 融化：写到 material/micro 或 object part，而不是无条件销毁整个 prefab。

---

## 10. 第一条验证路径：电场

第一片实现目标不是“电源 prefab”，而是：

```text
Prefab participates in electric fields through FieldParticipantProjection.
```

推荐验收场景：

1. 世界中放置真实 `power_block` 作为电源源头。
2. 在电源和目标之间放置一个 conductive prefab bridge。
3. prefab bridge 内部用 refined micro 表示导体和绝缘体。
4. `FieldRuntime` 构建 electric projection。
5. `ConductionPathKernel` 只读取 projection，不直接读取 prefab。
6. 导电路径通过 prefab bridge 成功连通。
7. 打断 prefab 某个 conductive part 或 micro。
8. projection 缓存失效并重算。
9. 同一导电请求返回 `no_conductive_path` 或等价 reject。
10. 如果连通时有负载，电热写回和热烟效果仍然按现有 FieldEffect/UI 链路生效。

该测试证明三件事：

- prefab 可以作为任意场的参与者进入 kernel。
- 宏格场模拟可以正确读取 refined micro 的场类型摘要。
- FieldEffect 可以保留 object/part provenance 回写。

---

## 11. 用户和调试可观测性

每个实现阶段都必须有 CLI/日志验收面，不能只看浏览器画面。

建议新增或扩展调试入口：

```text
field_projection <x> <y> <z> [field_type]
  查看某个 macro 的 projection 摘要。

voxel_conduct ...
  返回是否使用 projection、source、path、rejected reason。

object_probe <object_id>
  查看 object parts、covered chunks、field-relevant tags/state。
```

observe 日志建议：

```text
field_projection_built
field_projection_cache_hit
field_projection_invalidated
field_projection_rejected
field_effect_object_writeback
```

浏览器端可视化：

- Field overlay 继续显示电势/热烟。
- prefab 本体不因 field debug 直接染色。
- 可在调试面板或 CLI 中展示“当前选中 macro 的 field projection 摘要”。

---

## 12. 分阶段推进

### 12.1 Projection 纯领域层

目标：只读地把 chunk storage + object provenance + material catalog 转为 projection。

交付：

- projection 数据结构。
- solid/refined/empty macro 聚合。
- object/part refs 聚合。
- 缓存版本键。
- 单元测试覆盖 macro/micro 转换、solid 虚拟展开、refined 聚合、object part refs。

### 12.2 ElectricProjection 第一片

目标：让电场通过 projection 读 prefab。

交付：

- conductive face graph。
- 绝缘/击穿属性读取。
- prefab bridge 连通测试。
- 打断 conductive part 后 projection 失效测试。
- `ConductionPathKernel` 改为读取 projection 或通过 adapter 读取等价接口。

### 12.3 FieldEffect object/micro 回写

目标：保留 object/part 身份，把电热/破坏候选写回正确目标。

交付：

- 电热按 conductor part 或 material weighted 分摊。
- object part heat target。
- observe 日志显示 effect 落点。
- 浏览器热烟来自 object-backed field effect。

### 12.4 其他场复用

目标：不用新增 prefab 特判，把热、烟尘、压力、魔法逐步接入。

交付顺序建议：

1. 热场读取 `ThermalProjection`。
2. 烟尘/气体读取 `GasProjection`。
3. 压力/冲击读取 `PressureProjection`。
4. 魔法异常读取 `MagicProjection`。

---

## 13. 验收标准

架构验收：

- Field kernel 不直接依赖 prefab 模块或 ObjectRegistry。
- prefab/object 的参与能力通过 projection 暴露。
- solid/refined/empty macro 都能生成一致的 projection。
- projection 缓存可由 chunk/object/material 版本失效。
- FieldEffect 回写保留 object/part provenance。

电场验收：

- conductive prefab bridge 能让 power block 到目标连通。
- 绝缘 prefab 或断开的 conductive part 会阻断连通。
- 打断 prefab 后，不重启服务也能实时改变导电结果。
- CLI 和 observe 日志能看到 projection build/cache/invalidated/reject。
- 浏览器能通过现有 overlay/烟雾看到电热结果。

回归验收：

- 普通 solid iron 导线行为不退化。
- 普通 `power_block` 源头仍然是物理电源，不恢复虚空电源。
- 不破坏现有 prefab placement / object provenance / chunk delta。
- 不把 micro edit 暴露成新的玩家直接编辑单位。

---

## 14. 风险和约束

性能风险：refined projection 可能比普通 macro 采样贵。第一片优先正确性，用版本缓存控制重复计算；后续再做 changed-macro 增量。

边界风险：如果 FieldKernel 直接读取 prefab，就会产生每种场一套特判。实现时必须把 prefab 读取收敛在 projection builder 或 adapter。

语义风险：solid macro 的虚拟 micro 展开只能用于同质普通块。只要出现多材料、多对象、多部件或局部破坏，就必须进入 refined projection。

跨 chunk 风险：prefab 已可能跨 chunk。projection 必须能标记边界不完整，电场等需要邻居连通的场不能只看单 chunk 内部摘要。
当前已经补上跨 projection 的电接触 transfer API，并在 `FieldRuntime` 落地相邻
双 chunk 的第一条 runtime handoff：当 source/target 正好位于两个 chunk 的相邻
边界宏格且物理接触成立时，runtime 会读取两侧 hot chunk 的 projection，先做
共享面 micro 接触校验，再分别在两侧 chunk 内创建 shard region。source shard
保留 `source_key`，target shard 只按稳定 `region_id` 复用，因此 target chunk
不会平白多出一个 field source。`ConductionPathKernel` 仍保持 chunk-local；当前
只支持一次边界跨越，不支持全地图搜索、merged snapshot 或改线 wire 协议。

UI 风险：浏览器视觉只能证明现象存在，不能证明权威路径正确。验收必须同时依赖 CLI 和 observe 日志。

---

## 15. 设计结论

Prefab 接入所有局部场的正确方式不是“把 prefab 逻辑塞进每个 kernel”，而是建立 `FieldParticipantProjection`：

```text
Prefab is not a special case inside field kernels.
Prefab is a world-object provider for field participant projections.
Electric conduction is the first verification path.
```

这条边界同时保留：

- 蓝图层级：方便创作、组合、部件语义。
- 场景几何摊平：方便 chunk 存储、渲染、碰撞、订阅。
- micro provenance：方便局部破坏、object/part 回写。
- field kernel 纯度：方便后续热、烟尘、压力、魔法复用。

---

## 16. 进度日志

- 2026-05-19：第一条电场验证切片开始落地。新增 `Field.ParticipantProjection`
  作为只读投影层，电场可通过它读取 solid/refined macro 的电导面连通。
  `ConductionPathKernel` 的搜索状态改为携带 entry face，断开的 prefab/refined
  导体不会再被当作整宏格导体；连通的 refined conductor bridge 仍能导电。
- 2026-05-19：第二条电场验证切片落地。`ParticipantProjection` 公开
  `electric_object_refs/2`，电热 `FieldEffect` 在经过 object-backed refined
  conductor 时携带 `object_part_targets`。这一步只保留回写落点元数据，
  不提前实现 object part 受热、血条或破坏结算。
- 2026-05-19：第三条电场验证切片落地。电场投影新增共享面的 micro
  接触坐标，`ConductionPathKernel` 的搜索状态从 entry face 进一步扩展为
  entry face + entry contacts。相邻 refined prefab 导线必须在共享面同一
  micro 坐标重叠才会连通，错位接触不会再产生虚假的电路。
- 2026-05-19：第四条电场验证切片落地。`ParticipantProjection` 新增
  `electric_contact_transfer/8`，同一 chunk 内核和未来跨 chunk 搜索可以复用
  同一条“当前组件可达接点 ∩ 邻居入面接点”的边界判定。该切片只建立跨
  projection 接触契约，不解除 runtime 当前的跨 chunk 导电拒绝。
- 2026-05-19：第五条电场验证切片升级为可运行的相邻双 chunk runtime handoff。
  `FieldRuntime.ensure_conduction_path/1` 对相邻 chunk 的边界 source/target 增加
  双侧导通校验：两侧边界宏格必须都导电，共享面 micro 接触必须重叠，且 target
  chunk 内部仍要能从入面边界走到 target 宏格。校验通过后 runtime 会创建两个
  shard region：source 侧保留 `source_key`，target 侧只保留稳定 `region_id`，
  因此 source chunk 仍是 `1 region / 1 source`，target chunk 仍是
  `1 region / 0 source`。重复同一 source/target 请求会复用两个 shard；非直接
  相邻跨 chunk 仍返回 `cross_chunk_conduction_not_supported`。
