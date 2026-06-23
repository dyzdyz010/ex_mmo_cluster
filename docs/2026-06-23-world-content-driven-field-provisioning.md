# 世界内容驱动场 provisioning 框架(决策稿)

- 日期:2026-06-23
- 状态:**待拍板**(决策稿先行;拍板后逐 step 实现)
- 关联:`docs/2026-06-23-light-as-orthogonal-system.md`(光正交系统)、`apps/scene_server/lib/scene_server/voxel/README.md`(场 / FieldRegion / FieldRuntime)
- 触发:端到端调查发现「涌现真流到客户端」唯一真缺口——**生产侧只有电路场会被自动 provisioning,光 / 化学 / 热致涌现在活集群里从不真流**。

## 1. 问题(精确)

把「涌现真流到客户端」逐层走通后,结论分两半:

- **客户端 / wire / kernel / truth 全闭环且已测**:
  - `FieldTickWorker → ChunkProcess.fan_out_field_snapshot_payload` → gate `tcp_connection` 转发 0x73/0x74 → bevy 订阅(`EnteredScene` 自动)→ 解码 → `field_store` → 渲染,零阻断缺口。
  - 已补端到端测试 `server_golden_light_color_flows_to_rendered_overlay`:服务端 golden 光字节 → `decode → VoxelAuthority → field_store → light_overlay_mesh`,断言暖橙/冷蓝各烘焙正确 packed 颜色。把「字节级 parity」延伸成「字节→落库→渲染几何」闭环。

- **生产侧 provisioning 只覆盖电路**:
  - 运行集群里 `ChunkProcess` 块变更只自动起**电路场**(`refresh_auto_circuit_after_mutation` → `auto_circuit_kernel_spec` = `CircuitCurrentKernel`)→ 0x73 电流流,真到客户端 ✓。
  - **温度场**:只有 `DevFieldCreate`(模块自标 "Dev-only",走 auth HTTP `voxel_set_temperature` 调试端点)经 `FieldRuntime.ensure_temperature_anomaly` 起温度 region。组织玩法里不会自发。
  - **权威光场(`:light` + `:light_color`)/ 独立化学反应**:**生产代码无任何 provisioning**。`field_source.ex` 定义了 `:light` 源形状(`[light_propagation, reaction]`),但**无任何生产调用方创建它**;`FieldRuntime` 连 `ensure_light` 都没有。

**后果**:玩家在活集群里放下 ember/glowstone(`light_emission`)、或熔岩遇水,**不会点亮客户端光场、不会自发跑光合/光门/化学**——不是客户端不行、不是 wire/kernel 不行(全测过),而是**服务端从不从世界内容里起那个场 region**。客户端早就 ready,流却没人产。

## 2. 原则

> **世界内容统一驱动场 provisioning。** 一个 chunk 该跑哪些场 region,完全由它当前 truth 里的内容决定(有发光体 → 起光场;有热异常 → 起温度场;有闭合电路 → 起电路场;有可反应材料 → 起反应)。没有 per-field 散落的硬编码触发;电路 `auto_circuit` 是这套统一机制的**第一个特例**,而非唯一特例。

这与本仓既有正交系统纪律一致:行为来自**属性派生的激活 + 组合涌现**,不靠 id 白名单。provisioning 层照此延伸——区域的存在与否,从内容属性涌现。

## 3. 关键发现:泛化代价很小

`ChunkProcess` 的场 region 核心机制**已经是通用的**,只接受任意 `attrs`(含任意 `kernels`):

- `ensure_field_source_region_in_state(state, attrs, source_key)`:按 `source_key` 复用(refresh)或新建 region。
- `start_field_region/3` → `FieldTickSupervisor.start_worker` → `FieldTickWorker`(每 tick fan out 0x73)。
- `release_field_region_source_entry(state, source_key, reason)`:内容消失即拆。
- 去抖刷新:`maybe_schedule_auto_circuit_refresh` → 50ms debounce → `:refresh_auto_circuit_after_mutation`。

**唯一电路硬编码的是「触发 + 探测 + region 规格」层**:`refresh_auto_circuit_after_mutation` 写死了 `ParticipantProjection` 电学角色、`auto_circuit_kernel_spec`、`auto_circuit_source_key`。把这一层抽成一组声明式 **provisioner**,核心机制原样复用。

## 4. 设计:`FieldProvisioner` 契约 + 统一 sweep

### 4.1 provisioner 契约

每个 provisioner 是一个声明式规格(behaviour 或 spec map),回答三件事:

```text
detect(projection, storage, aabb, state) -> :active | :inactive
  # 这个 chunk 当前内容是否需要本场?(纯读 truth/projection,无副作用)

source_key(state) -> term()
  # 本 chunk 内本场的稳定键(如 {:auto_light, scene, coord});同键幂等复用。

region_attrs(projection, storage, aabb, state) -> map()
  # active 时的 region 规格:kernels(有序)、可选 source_points、max_ticks 等。
```

### 4.2 统一 sweep

块变更去抖后,**一次** sweep 遍历所有注册 provisioner:

```text
refresh_fields_after_mutation(state):
  projection = ParticipantProjection.build(storage)   # 复用,一次构建
  for p in @provisioners:
    case p.detect(projection, storage, aabb, state):
      :active   -> ensure_field_source_region_in_state(state, p.region_attrs(...), p.source_key(state))
      :inactive -> release_field_region_source_entry(state, p.source_key(state), :explicit)
```

电路 `auto_circuit` 重构为 `@provisioners` 里的**第一个 provisioner**,行为逐字节保持(现有 `chunk_process_test` 电路断言不变即回归通过)。

## 5. region 组合:由代码约束确定(非自由选择)

读 `ReactionKernel.cell_state/3` 确认了耦合方式,这把「分场多 region vs 统一大 region」的争论**收敛成约束**:

| 场 → 反应的耦合 | 读取来源 | 是否必须同 region |
|---|---|---|
| **光 → 反应** | 同 region 的 `:light` 场层(`FieldLayer.get(light_layer, …)`,同 tick) | **必须同 region**(光 kernel 排反应前) |
| 温度 → 反应 | **已提交 truth** 温度(`scaled_attribute(storage, …)`) | 不必;温度 region 独立,反应读其提交结果 |
| 电 → 反应 | 电 kernel 提交的 truth(焦耳热/电离) | 不必;电路 region 独立,反应读 truth |

**结论**:`ReactionKernel` 只需在**每 chunk 唯一一个**「涌现 region」里跑一次(读 truth 温度/电=上 tick 提交值,1-tick 延迟,本来就如此),无双重触发风险。光因同 tick 层耦合,**必须**和反应同 region。

由此 provisioner 初始集自然落位:

1. **`electric_circuit`(重构现有)**:闭合电路拓扑 → region `[circuit_current]`,带 source_points。
2. **`emergence`(新增,核心)**:chunk 含可反应/发光/光敏内容 → region `[light_propagation, reaction]`(`LightPropagationKernel` 自行从 region storage 发现 `light_emission` + 热致 ≥Draper 源,无需显式 source_points)。**这是让光/化学/光门/光合在有机玩法里真跑、并 stream `:light`/`:light_color` 0x73 的那一个。**
3. **`thermal`(新增,泛化 dev 端点)**:chunk 有热异常(cell ≠ ambient)或进行中放热反应 → region `[temperature_diffusion]`。让热扩散 + 热致 incandescence 有机 stream(`DevFieldCreate` 调试端点变成此 provisioner 的一个显式调用方,而非唯一来源)。

## 6. 探测谓词(初始集)

- **electric_circuit**:沿用现有 `auto_circuit_source_points`/`role_count`/`closed_circuit_count`(power source + load + 闭合回路)。
- **emergence**:chunk 内**存在任一「光学/反应活性」材料**即 active。活性谓词从 catalog/rules 派生(不写 id 白名单):
  - `light_emission > 0`(发光体),或
  - 光敏(可被 `:light` gate,如 `photo_sensor`/`sprout`),或
  - 任一反应 recipe 的反应物(如 lava/water/可燃/可氧化),或
  - cell 温度 ≥ Draper(热致发光源)。
  - 谓词建议实现为 `MaterialCatalog`/`Rules` 派生的一个 `reactive_or_optical_material?/1`(集合预computed)。
- **thermal**:chunk 内任一 cell 的 truth 温度偏离 ambient 超阈(复用 `build_temperature_anomaly` 的异常检测),或 emergence region 报告了放热。

> **开放选项(待拍板,见 §10)**:emergence 探测的「积极程度」——是「任一活性材料即起」(最完整,但近乎只要 chunk 非空且有内容就常驻一个 reaction region),还是「仅发光体/光敏/进行中反应才起」(更省,但放下两块惰性反应物要等某种扰动才起)。推荐前者(完整优先,成本由 §7 调度预算兜底),但需你确认。

## 7. 性能 / 生命周期

- **去抖**:沿用 50ms debounce,一次 sweep 跑全部 provisioner,共享一次 `ParticipantProjection.build`。
- **门控空 chunk**:`detect` 为 `:inactive` 的场不起 region;惰性/空 chunk 零开销。
- **节点级预算**:已有 `VoxelSimScheduler`(`voxel_sup.ex`:节点级场仿真调度器,统一 clock + CPU 预算驱动所有 `FieldTickWorker`)给所有 region 的 tick 成本封顶——新增 region 自动纳入预算,不会无界膨胀。
- **生命周期**:内容驱动 region `max_ticks: nil`(内容在则常驻),内容消失 sweep 即 `release`(同电路「无闭合回路→released」)。幂等:同 `source_key` 复用,不重复起。
- **lease**:沿用 `start_field_region` 注入 `state.lease`。

## 8. 不改动的部分(已完成,明确非目标)

- wire 0x73/0x74 格式 + field_mask(temperature/electric/ionization/**light/light_color**)——已锁,golden 双语 parity。
- 各 kernel(LightPropagation/TemperatureDiffusion/Reaction/Circuit…)实现——已测。
- 客户端解码/落库/渲染(含 incandescence/colored-light)——已测。
- gate 转发——已通。

本框架**只补「生产侧从世界内容起对的 region」这一层**,不动其余。

## 9. 逐 step 计划(拍板后)

1. **step1**:抽 `FieldProvisioner` 契约 + `@provisioners` 注册表;把电路重构为 provisioner #1;`refresh_auto_circuit_after_mutation` → 通用 `refresh_fields_after_mutation`。回归:现有电路 `chunk_process_test` 全绿(行为保持)。
2. **step2**:`reactive_or_optical_material?/1` 活性谓词(catalog/rules 派生)+ 单测。
3. **step3**:`emergence` provisioner(`[light_propagation, reaction]`)接入 sweep。
4. **step4**:生产 e2e(任务 #38):真 ChunkProcess 放 ember/glowstone + subscribe → 块变更触发 → `assert_receive {:voxel_field_region_snapshot_payload, _}` 且 `FieldCodec` 解出 light mask + 值>0(镜像电路 e2e)。
5. **step5**:`thermal` provisioner(`[temperature_diffusion]`)+ 把 `DevFieldCreate` 收成其显式调用方;热致 incandescence 有机 e2e。
6. 每 step 一个 commit(不 push;co-author `Claude Opus 4.8 (1M context)`)。

## 10. 待你拍板的开放点

1. **emergence 探测积极程度**:「任一活性材料即起 reaction region」(推荐,完整优先)vs「仅发光体/光敏/进行中反应才起」(省)。
2. **首切范围**:step1–4(电路重构 + 光/反应有机化,先把「光真流到客户端」闭合)先落地、thermal(step5)随后;还是 step1–5 一次做全(光+热+反应全有机化)。
3. **thermal 与 dev 端点**:本轮就把 `DevFieldCreate` 收编为 thermal provisioner 的调用方,还是先并存、后续单独收口。
