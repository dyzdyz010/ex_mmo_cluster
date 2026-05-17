# Phase 7: 局部场传播 Kernel 架构目标

状态：设计目标稿；Phase 7.A kernel-first 迁移已落地；Phase 7.D 温度异常入口已落地；Phase 7.E 第一批与 Phase 7.B core 已落地
日期：2026-05-14
归属：goal `voxel-authoritative-and-field-minimum` Phase 7

> 2026-05-16 更新：本文继续作为 FieldKernel / FieldRegion / wire 协议的架构背景与实现细节记录。
> Phase 7 后续推进顺序、阶段验收和运行时能力边界以
> `docs/plans/2026-05-16-phase7-local-field-runtime-roadmap.md` 为准。

真相源：
- `docs/plans/2026-05-13-phase6-field-layer-minimum.md`
- `docs/2026-05-13-体素局部场最小目标-索引.md`
- `apps/scene_server/lib/scene_server/voxel/field/`
- `apps/scene_server/lib/scene_server/voxel/field/kernel.ex`
- `apps/scene_server/lib/scene_server/voxel/field/kernel_context.ex`
- `apps/scene_server/lib/scene_server/voxel/field/field_runtime.ex`
- `apps/scene_server/lib/scene_server/voxel/field/kernels/`
- `TheWorldBook/docs/2026-05-13-体素局部场最小目标.md`
- `TheWorldBook/docs/2026-05-13-三仓联合魔法系统落地可行性分析.md`

---

## 1. 背景

Phase 6 已经提供了局部场的第一层地基：

- `FieldRegion` 管生命周期、AABB、source points、tick 计数和 active layers；
- `FieldLayer` 管单一场值的稀疏存储；
- `FieldTickWorker` 管 per-region 10 Hz tick；
- `FieldCodec` 管 `0x73 FieldRegionSnapshot` 和 `0x74 FieldRegionDestroyed`；
- web_client 只消费服务端快照并显示 `FieldDebugOverlay`。

当前 `TemperatureField` 和 `ElectricField` 已能证明架构可用，但传播算法仍由
`FieldTickWorker` 按 field type 硬编码调度。继续这样做会让后续新增烟雾、冲击波、
闪电、信息波、魔法锚点传导时反复改同一批核心文件。

Phase 7 的目标是把"场如何演化"抽象为独立 kernel，让 `FieldRegion` 继续只管
活动区域和生命周期，`FieldLayer` 继续只管值，传播模式由可插拔 kernel 负责。

---

## 2. 设计原则

1. **常态属性在 voxel 里，场只表示异常扰动。**
   温度、湿度、密度、导热性、电导率、击穿强度等常态属性属于 typed
   attribute / environment summary。局部高温、电势差、电离、压力波等异常才
   创建 `FieldRegion`。

2. **无异常时零成本。**
   没有活跃 source 或梯度时，不应有 field worker、tick、带宽或 overlay 数据。

3. **传播模式与存储解耦。**
   扩散、导通路径、波前、流体都共用 `FieldRegion` / `FieldLayer` / 0x73 下发，
   但算法作为独立 kernel 存在。

4. **kernel 输出结构化 effects，不直接乱改世界。**
   kernel 可以提出 damage、attribute writeback、spawn field、observe 等效果，
   但实际应用由统一 dispatcher / ChunkProcess 边界执行。

5. **新增模式不应修改大量核心文件。**
   增加一个传播模式时，理想改动是新增 kernel 模块、测试、注册配置和必要的
   field layer 定义；不应修改 `ChunkProcess`、Gate forward 和客户端协议主干。

---

## 3. 核心模型

```text
voxel 常态属性
  temperature / moisture / density / thermal_conductivity / specific_heat_capacity / ...

+ FieldRegion 临时异常扰动
  source_points + layers + kernels + tick_count + max_ticks

= 当前有效物理状态
```

建议把 field 子系统拆成四类对象：

```text
FieldRegion
  生命周期、AABB、source_points、layers、tick_count、max_ticks、lease_token

FieldLayer
  某个标量或离散场值的存储，例如 temperature / electric_potential / ionization

FieldKernel
  这个 region 内的异常如何演化，例如扩散、导通路径、波前、流动

FieldEffect
  kernel 产生的结构化副作用，例如写回属性、造成伤害、产生新场、emit observe
```

---

## 4. Kernel 类型

### 4.1 `DiffusionKernel`

适用：

- temperature
- moisture / humidity anomaly
- smoke_density
- poison_gas_density

特征：

- stencil / neighbor average；
- 连续扩散；
- 与环境基线耗散；
- 适合 sparse anomaly 计算，不需要扫完整 chunk；
- 温度可由 `thermal_conductivity / (density * specific_heat_capacity)` 调制；
- kernel opts 必须显式区分 **物性读取** 和 **传播 profile**：物性仍来自 voxel
  truth，`diffusion_time_scale` / `ambient_loss_per_second` 只描述这个局部异常在游戏可观测时间内的演化；
- 湿度 / 气体可由 `permeability` / material tag 调制。

Phase 6 的 `TemperatureField` 应迁移成 `DiffusionKernel` 的一个配置实例。

### 4.2 `ConductionPathKernel`

适用：

- lightning
- electric discharge
- mana arc / arcane conduction
- 短路、接地、电击链

特征：

- 图搜索，不是均匀扩散；
- 从 source 到 sink / ground / target 寻找低成本导通路径；
- 空气或绝缘体需要满足击穿阈值；
- 已电离路径降低后续成本；
- 找到 channel 后进入放电阶段，并产生热、电离、伤害等 effects。

Phase 6 的 `ElectricField` 已被收编为 `ElectricPotentialKernel`；闪电正式路线应由
后续 `ConductionPathKernel` 承担。

### 4.3 `WavefrontKernel`

适用：

- shockwave
- sound wave
- pressure pulse
- InfoWave 的低层传播实验

特征：

- 有传播前沿和速度；
- 可反射、衰减、穿透或阻挡；
- 更接近事件波，不是稳定 diffusion。

### 4.4 `FlowKernel`

适用：

- smoke flow
- gas / liquid seepage
- wind-carried effect

特征：

- 有方向、压力差、阻塞和流量；
- 可读取几何空隙、密度、风向、开放/封闭状态；
- 后续可作为 `DiffusionKernel` 与流向项的组合。

---

## 5. 建议模块结构

```text
apps/scene_server/lib/scene_server/voxel/field/
├── field_layer.ex
├── field_region.ex
├── field_tick_worker.ex
├── field_tick_supervisor.ex
├── field_codec.ex
├── kernel.ex                 # behaviour
├── kernel_context.ex         # 统一读取 voxel / object / rng / tick 环境
├── kernel_effect.ex          # 结构化 effect 类型与 helpers
└── kernels/
    ├── diffusion_kernel.ex
    ├── conduction_path_kernel.ex
    ├── wavefront_kernel.ex
    └── flow_kernel.ex
```

Phase 7.A 先只实现 `kernel.ex`、`kernel_context.ex` 和 kernel-first 调度：

- `TemperatureDiffusionKernel` 承担温度扩散；
- `ElectricPotentialKernel` 承担电势传播，并声明 `:ionization` 输出层；
- `FieldRegion.kernels` 是创建 region 的必填事实；
- `FieldRegion.field_types` 只从 kernel `required_layers/1` 派生，用作 layer / `0x73` wire cache；
- 调用方不得再通过 `field_types` 触发算法，也不得省略 `kernels`。

`kernel_effect.ex` 和完整 effect dispatcher 留到 Phase 7.B+，避免在 7.A 把副作用边界做宽。

---

## 6. `FieldKernel` 行为

概念接口：

```elixir
@callback kernel_id() :: atom()

@callback required_layers(opts :: map()) :: [FieldRegion.field_type()]

@callback tick(
            region :: FieldRegion.t(),
            context :: FieldKernel.Context.t(),
            opts :: map()
          ) ::
            {:cont, FieldRegion.t(), [FieldKernel.Effect.t()]}
            | {:done, FieldRegion.t(), [FieldKernel.Effect.t()]}
```

返回语义：

- `:cont`：region 继续存活，下一 tick 继续运行；
- `:done`：kernel 判断异常已耗散，region 可以进入销毁或等待其它 kernel；
- 7.A 不把 `:done` 自动解释为销毁 region；region 生命周期仍由 `max_ticks`、显式销毁、
  lease 变更和后续 FieldRuntime 决定；
- kernel 抛异常或返回非法值时，由 `FieldTickWorker` 逐 kernel 捕获，emit
  `voxel_field_tick_failed`，保留原 region 并继续运行后续 kernel。

`FieldTickWorker` 不再按 field type 写死：

```elixir
Enum.reduce(region.kernels, {region, []}, fn kernel_spec, {acc_region, effects} ->
  run_kernel(kernel_spec, acc_region, context, effects)
end)
```

---

## 7. Kernel Context

kernel 不应直接知道 `ObjectRegistry`、`ChunkProcess` 的内部结构。Phase 7.A 的
`KernelContext` 故意很小，只包含：

```text
storage
dt_ms
tick_count
logical_scene_id
chunk_coord
```

`storage` 是每个 field tick 开始时从 chunk truth 取到并规范化一次的只读快照。kernel
热路径必须通过 context 传入的已规范化 storage 或后续 context API 读取属性，不能在每个
cell/attribute 上重新调用整块 `Storage.normalize!/1`；否则 100ms field tick 会被属性读取拖成
近 1Hz，前端表现为热点只偶发加深而不是连续扩散。

也就是说，7.A 只做 chunk-local、read-only、deterministic 的 kernel-first 迁移。更宽的统一读取面
是 Phase 7.B+ 的目标：

```text
effective_attribute_at(cell, attr_name)
has_tag?(cell, tag_name)
neighbors(cell, mode: :six | :twenty_six)
cell_material(cell)
objects_in_aabb(aabb)
object_part_at(cell)
environment_value(name)
deterministic_noise(cell, tick_count, salt)
```

这样算法只依赖 context API，底层 attribute merge、object provenance、邻区读取可以继续演化。

---

## 8. Kernel Effects

长期目标是 kernel 输出 effect，不直接执行副作用：

```text
{:write_attribute_delta, cell, attr_name, value, reason}
{:damage_object_part, object_id, part_id, damage_kind, amount}
{:spawn_field_region, attrs}
{:emit_visual_cue, cue}
{:emit_observe, event, fields}
{:mark_kernel_done, kernel_id}
```

Phase 7.A 只允许 region 更新和可选的 `{:emit_observe, event, fields}`；damage /
writeback / spawn field 不执行，也不接 `ChunkProcess`。关键是先把算法调度从 worker
里剥离出来，结构化副作用等 Phase 7.B+ 再单独闭合。

---

## 9. 闪电导通路径设计

### 9.1 不是扩散

温度 / 湿度适合 `DiffusionKernel`，因为它们趋向连续平滑。闪电不是把电势均匀
扩散到整个区域，而是在电势差足够大时寻找一条导通或击穿路径，然后沿通道释放能量。

### 9.2 常态属性

正式导通路径需要以下 voxel 属性或 tag：

| 名称 | 类型 | 用途 |
|---|---|---|
| `electric_conductivity` | typed attribute | 材料电导率，路径电阻基础 |
| `dielectric_strength` | typed attribute | 击穿强度，决定空气/绝缘体是否能被击穿 |
| `charge_capacity` | typed attribute，可选 | 可蓄电程度，决定局部电荷积累 |
| `conductive` | tag | 快速标记金属/导体 |
| `grounded` | tag | 放电 sink / 接地吸收点 |
| `wet` | tag 或 moisture 派生 | 降低路径成本 |
| `ionized` | field layer 派生 | 已电离路径降低击穿成本 |

当前电势路径用 `density` 近似路径代价，只能视作临时物理近似。Phase 7 正式设计应把
`electric_conductivity` / `dielectric_strength` 列为后续 attribute catalog 扩展。

### 9.3 Field layers

v1 建议保留现有 layers：

- `electric_potential`
- `ionization`
- `temperature`

后续如需要更精确地可视化通道，可追加：

- `discharge_channel`：u8，表示本 tick 或短期内的放电通道强度；
- `current`：f32，表示通道电流强度。

如果只用现有 `0x73` 标量数组，v1 可把通道编码为高 `ionization` + 高
`electric_potential` 路径，不急着扩 wire。

### 9.4 路径成本

把 AABB 内 macro cell 视为图节点，6-neighbor 或 26-neighbor 为边。

```text
edge_cost =
  resistance_cost(electric_conductivity)
+ breakdown_cost(dielectric_strength, potential_difference)
+ distance_cost
- ionization_bonus
- wetness_bonus
- conductive_tag_bonus
+ deterministic_noise
```

约束：

- 导体成本低，优先走；
- 湿路径降低成本；
- 空气默认高成本，只有电势差超过击穿阈值才允许通过；
- 已电离路径短期内更容易再次导通；
- 绝缘材料高成本，除非能量预算很高，否则绕行；
- `grounded` / target / enemy / conductive object 可作为 sink。

### 9.5 Tick 阶段

`ConductionPathKernel` 可维护简单状态机：

```text
build_up
  源点积累 electric_potential，未达到阈值时只更新局部潜势。

leader_search
  用 Dijkstra / A* / priority frontier 搜索最低成本路径。
  能量预算不足时只生长一段 leader，不一定命中目标。

return_stroke
  路径连通后沿 channel 释放能量：
    - ionization 增加
    - temperature 异常增加
    - 输出 damage / ignite / short_circuit effects
    - electric_potential 快速归零

decay
  ionization 和 temperature 交给对应 kernel 或自身衰减。
  所有异常低于阈值后 region 销毁。
```

---

## 10. FieldRegion 与 Kernel 的关系

建议下一版 `FieldRegion` 增加：

```elixir
kernels: [
  %{
    id: :temperature_diffusion,
    module: SceneServer.Voxel.Field.Kernels.DiffusionKernel,
    opts: %{
      field_type: :temperature,
      conductivity_attr: "thermal_conductivity",
      density_attr: "density",
      specific_heat_attr: "specific_heat_capacity"
    }
  },
  %{
    id: :lightning_conduction,
    module: SceneServer.Voxel.Field.Kernels.ConductionPathKernel,
    opts: %{source_layer: :electric_potential, ionization_layer: :ionization}
  }
]
```

`kernels` 是 7.A 创建 `FieldRegion` 的唯一事实输入；`field_types` 继续作为结构体字段保留，
但它只由 `required_layers/1` 派生，用于 layer 初始化、`field_mask` 和客户端 overlay。
调用方直接传 `field_types` 会被拒绝，避免服务端 layer、`field_mask` 和 tick 调度出现两套真相源。

创建规则：

- `kernels` 必填且非空；
- `field_types` 禁止作为输入；
- `:temperature` 由 `TemperatureDiffusionKernel.required_layers/1` 派生；
- `:electric_potential` 和 `:ionization` 由 `ElectricPotentialKernel.required_layers/1` 派生；
- `:ionization` 是电势 kernel 的输出层，不单独建 kernel；
- source point 的 `field_type` 必须属于派生出的 `field_types`；
- kernel module 必须实现 `required_layers/1` 和 `tick/3`。

---

## 11. 自动场源

UI 不应依赖 `+Field` 手工创建。2026-05-14 起，web_client 的原 `+Field` 已改为
`Heat`：瞄准一个 occupied voxel 后按 `F` 或点击 `Heat`，客户端只提交“向该 world-macro
voxel 注入一定热量”的意图；服务端按 voxel 的 `density × specific_heat_capacity × volume`
计算温升，先写成 authoritative `temperature` 属性，再由 `FieldRuntime` 从 voxel effective
attribute 中判断是否创建局部场。

正式架构引入 `FieldRuntime`，后续可继续扩展成显式 `FieldSource` 记录：

```text
FieldSource
  source_id
  source_kind: :heat | :electric | :magic | :weather | :device
  location / aabb
  source_value / energy_budget
  kernel_specs
  decay_policy
```

触发方式：

- voxel 属性异常超过阈值；
- object / device 持续产生热源或电源；
- Combat / magic effect 产生瞬时源；
- 天气或环境事件在局部创建 source。

已落地的温度切片：

- HTTP：正式入口 `POST /ingame/voxel/set_temperature`；legacy alias
  `POST /ingame/voxel/dev_heat_voxel` 仍保留；
- WorldServer：`WorldServer.Voxel.DevFieldSeed.ensure_set_temperature/1` 跨节点转发；
  `ensure_heat_voxel/1` 为 legacy heat alias；
- SceneServer：`ChunkProcess.write_temperature_attribute/2` 先把默认 800°C 目标温度写入
  选中 solid voxel 的 `temperature` attribute，再按
  `density × specific_heat_capacity × volume` 在 summary 中回算所需热量；
- SceneServer：`SceneServer.Voxel.Field.FieldRuntime.build_temperature_anomaly/1` 从
  `Storage.effective_attribute_at/3` 读取 voxel 当前有效温度，负责 world macro ->
  chunk/local macro、阈值判断、AABB 估算和 kernel-first attrs；当前 Heat profile 使用
  `diffusion_time_scale=1.0`、`ambient_loss_per_second=0.0`、`cell_size_meters=1.0`，
  让 1m macro voxel 按材质热扩散率真实演化，不再把局部异常压缩到调试/玩法时间尺度；
- SceneServer：`ensure_temperature_anomaly/1` 通过 `ChunkProcess.ensure_field_region/2`
  创建或复用 `TemperatureDiffusionKernel` region；同一 chunk 内同一 `{temperature, macro_index}`
  活跃 region 会接收新的 `source_mode: :impulse` source，不会重复堆叠 region；
- web_client：`F`、HUD `Heat` / `Cool`、CLI
  `voxel_temp <x> <y> <z> <target_temperature_celsius> [max_ticks]`
  走同一条 set-temperature action；`voxel_heat` / `voxel_cool` 保留为 alias。
  set-temperature 成功后自动打开 Field overlay，并可用
  `window.__voxelCli.run("field_overlay")` 读取当前 overlay 状态。

当前温度切片已经不再用请求参数直接作为场源；请求参数只表达目标温度，服务端写 voxel 属性并从属性异常创建
一次性 impulse 场源。该 impulse 不是持久热源；可见扩散和耗散由 `TemperatureDiffusionKernel`
的传播 profile 负责。已完成最小 active source 去重和客户端可见闭环。后续需要补完整自动源管理：
扫描/订阅 voxel truth 中的异常属性、异常消退后自动销毁 region、以及 kernel effect 写回 truth。

---

## 12. FieldRegion 尺寸与大范围事件

`FieldRegion` 的大小不应由法术名或效果名直接决定，而应由异常扰动的活动边界决定。
创建 region 时需要根据 source、能量预算、传播模式和最大精度范围估算初始 AABB；
运行时再按异常是否继续扩散、是否低于阈值来扩张、收缩或销毁。

### 12.1 普通局部效果

火球、篝火、电击、冰冻、短路等效果范围通常可预估：

```text
source position
+ energy_budget
+ propagation kernel
+ max_radius / max_ticks
=> initial FieldRegion AABB
```

例如火球术可以把爆心附近的高温异常放进一个局部 `FieldRegion`：

- `DiffusionKernel` 负责高温向外扩散和耗散；
- `FieldRuntime` 监控 active cells 是否低于阈值；
- 低于阈值后销毁 region；
- 需要留下烧焦、融化、点燃等持久结果时，由 kernel effect 写回 voxel/object 属性。

这种效果可以使用单个 region，或在靠近 chunk 边界时拆成少量 chunk-local region。

### 12.2 超大规模效果

核弹级爆炸、陨石撞击、大规模魔法灾变等不能用一个巨型 `FieldRegion` 包住全部影响范围。
单个 region 无限放大会同时打爆 tick、内存、带宽、AOI 和客户端 overlay。

这类效果应由更高层事件管理：

```text
ExplosionEvent / CatastropheEvent
  全局事件 id、爆心、能量预算、时间线、LOD 策略

Near FieldRegions
  近场高温、冲击波、电离、强破坏，精细 tick

Mid/Far Sparse Effects
  中远场热辐射、压力波、烟尘、火灾源点，低频或稀疏 tick

Persistent Attribute Changes
  烧焦、融化、辐射污染、结构损坏、地形变形，写回 voxel/object truth

Visual / Audio / Camera Cues
  远距离只发视觉、声音、震动和天空盒/光照 cue，不创建可交互 FieldRegion
```

换句话说，核爆不是一个超大的 field，而是一个高层事件派生多个局部 field，并把远场降级为
低频事件、稀疏源点或持久属性变化。

### 12.3 尺寸规则

Phase 7 应保留以下约束：

1. **单个 FieldRegion 有硬上限。**
   v1 继续倾向单 chunk 或少量 chunk-local region；跨 chunk region 必须作为后续独立目标评估。

2. **大范围效果分片。**
   超过单 region 上限时，由 `FieldRuntime` / 高层事件按 chunk、AOI 或影响层级拆成多个 region。

3. **远场降级。**
   超出玩家 AOI、低于交互精度或只剩表现意义时，不再创建高频 field tick。

4. **持久结果写回 truth。**
   场是异常扰动，不负责永久存在。永久烧毁、污染、破坏、相变等结果应写回 voxel typed
   attributes、object state 或 terrain truth。

5. **异常边界驱动生命周期。**
   region 的扩张、收缩和销毁由 active anomaly cells、energy budget、kernel state 和阈值决定，
   而不是由 UI 或固定计时器单独决定。

---

## 13. 与 Sevara / TheWorldBook 的关系

本设计仍不要求 sevara 改代码。

后续魔法链路应是：

```text
TheWorldBook 机制法则
  -> Sevara SpellPlan
  -> MechanismGraph
  -> FieldSource / FieldKernel specs
  -> ex_mmo_cluster FieldRegion runtime
```

也就是说，Sevara 和 MechanismGraph 未来只描述"创建什么异常源、使用什么传播模式、
预算和约束是什么"，不直接参与 tick 计算。tick 仍由 ex_mmo_cluster 服务端权威执行。

---

## 14. 实施切片建议

### Phase 7.A：kernel behaviour + kernel-first 迁移

状态：已落地（2026-05-14）。

- 新增 `FieldKernel` behaviour；
- 新增 `KernelContext`；
- 把温度扩散收编为 `TemperatureDiffusionKernel`；
- 把电势传播收编为 `ElectricPotentialKernel`；
- `FieldTickWorker` 从 hardcoded field type case 改为 kernel specs；
- `kernels` 必填且非空；
- `field_types` 从 kernel required layers 派生；
- 单个 kernel 失败 emit `voxel_field_tick_failed`，不拖垮 worker；
- 现有 0x73 / 0x74 wire 不变；
- 现有测试全部保持通过。

实现文件：

- `apps/scene_server/lib/scene_server/voxel/field/kernel.ex`
- `apps/scene_server/lib/scene_server/voxel/field/kernel_context.ex`
- `apps/scene_server/lib/scene_server/voxel/field/kernels/temperature_diffusion_kernel.ex`
- `apps/scene_server/lib/scene_server/voxel/field/kernels/electric_potential_kernel.ex`
- `apps/scene_server/lib/scene_server/voxel/field/field_region.ex`
- `apps/scene_server/lib/scene_server/voxel/field/field_tick_worker.ex`

### Phase 7.B：ConductionPathKernel v1

- 已新增 `ConductionPathKernel` core；
- 使用 `electric_conductivity` / `dielectric_strength` 计算路径代价，不再把
  `density` fallback 或 material tag 当成正式路线；
- 输出 deterministic channel；
- channel 写入 `ionization` / `electric_potential`，不扩 wire；
- electric dev/runtime 入口仍未完成，后续要区别于 temperature demo。

### Phase 7.C：电属性 catalog 扩展

- `electric_conductivity` 已在 Phase 7.E 第一批落地；
- `dielectric_strength` 已在 Phase 7.E 第一批落地；
- 可选新增 `charge_capacity`；
- 将 `density` fallback 降级为 legacy fallback；
- 补 golden fixture / chunk hash 验证。

### Phase 7.D：FieldRuntime 自动源管理

状态：温度异常入口已部分落地（2026-05-14），完整源管理未完成。

- 已完成：heat action 默认传 `target_temperature_celsius=800`，SceneServer 写 selected voxel 的
  `temperature` attribute，并按材质 `density × specific_heat_capacity` 回算热量预算，再从 effective
  voxel 属性检测异常并自动创建 `TemperatureDiffusionKernel` FieldRegion；
- 已完成：`material_id=1..5` dirt / stone / wood / ice / iron 接入真实世界近似物性；
- 已完成：TemperatureField 扩散系数从调试归一化参数改为
  `thermal_diffusivity × dt / cell_size²`，并移除固定 `β=0.01` 回冷；
- 已完成：`ChunkProcess.ensure_field_region/2` 以 `source_key` 复用活跃 FieldRegion，并把后续热量输入追加成
  `source_mode: :impulse`；
- 已完成：`+Field` UI 改成 `Heat`，不再由按钮直接造任意 FieldRegion；
- 已完成：`F` 键向当前选中 voxel 设置默认 800°C 目标温度，Heat 成功后自动打开 Field overlay；
- 已完成：web CLI 增加 `field_overlay [on|off]` 用于读取/切换当前 Field overlay 状态；
- 未完成：从持久 voxel truth 扫描/订阅异常属性；
- 未完成：异常低于阈值后的自动销毁策略；
- 未完成：object / magic / weather source 的持续源生命周期；
- 未完成：kernel effect 写回 voxel/object truth。

---

## 15. 验收标准

1. 新增一个传播模式时，不需要修改 `ChunkProcess`、Gate forward、0x73/0x74 主协议。
2. `FieldTickWorker` 不再按 field type 硬编码调用算法。
3. 现有 temperature field 行为回归稳定。
4. `ConductionPathKernel` 对同一输入和 seed 产生确定性 channel。
5. kernel 错误会 emit `voxel_field_tick_failed`，不会拖垮 chunk。
6. 无活跃 region 时，仍保持零 tick、零带宽、零 overlay 数据。
7. UI 不再暴露 `+Field` 直造场；当前 `Heat` trigger 只提交目标温度，温升、热量预算和场由服务端 runtime 创建。
8. 大范围事件不会创建无限放大的单个 `FieldRegion`，而是拆成高层事件、局部 region、
   远场 cue 和持久属性写回。

---

## 16. 非目标

- 不在 Phase 7.A 直接接 Sevara；
- 不在 Phase 7.A 接 Combat / HP 伤害；
- 不在 Phase 7.A 引入跨 chunk FieldRegion；
- 不把 field 状态持久化；
- 不冻结最终物理常数；
- 不要求玩家可见 UX 抛光。

---

## 17. 风险与待决策

1. **通道 wire 表达。**
   v1 可用 `ionization` / `electric_potential` 表示 channel；如果后续需要边级路径或
   闪电折线，可能要追加新 field type 或视觉 cue payload。

2. **effect dispatcher 边界。**
   kernel effect 应由哪里应用需要单独定：FieldTickWorker 内部只适合 region-local 更新；
   object damage / attribute writeback 更适合 ChunkProcess 或上层 gameplay dispatcher。

3. **属性 catalog 扩展顺序。**
   正式电场需要 `electric_conductivity` / `dielectric_strength`。在它们落地前，导通
   kernel 只能使用 density/tag fallback，不能宣称物理模型完成。

4. **性能预算。**
   导通路径搜索应限制 AABB、能量预算、frontier 上限和 tick 时间。搜索超预算时应
   暂停或截断 leader，而不是阻塞整帧。

5. **多 kernel 协作。**
   闪电会同时产生 ionization 与 temperature 异常。Phase 7 需要明确同一 region
   多 kernel 写同一 layer 的合并顺序和冲突策略。

6. **大范围事件 LOD。**
   核爆级事件需要独立的事件层、AOI 策略和 LOD 策略。Phase 7 只定义 FieldRegion 不应无限放大；
   具体 `ExplosionEvent` / `CatastropheEvent` 结构应作为后续设计单独展开。
