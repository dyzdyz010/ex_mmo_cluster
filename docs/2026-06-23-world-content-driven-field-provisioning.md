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

## 6. 探测谓词(初始集)— 已拍板「任一活性材料即起」,但「活性」= 现在真在 source/反应

拍板「任一活性材料即起」。落到真 catalog 后有两个硬事实把「活性」的含义钉死:

- **所有反应都被能量/光 gate**:`iron_oxidation` 的 `gate_attr: "oxidation_temperature"`、熔化/燃烧的温度阈、obsidian/steam 需要(炽热的)lava、光合需要 `:light`。**没有任何常温自发反应**——一块冷铁/冷石/冷木是惰性的。
- **`FieldTickWorker` 每 tick 无条件 fanout 一个 0x73**(`field_tick_worker.ex:135/138`)。

所以「活性」**只能**取「现在真在向某个场 source、或真在反应」之义;若取「静态出现在某条 rule 里」(冷铁也算),则每个含铁 chunk 会**常驻一个空跑、空 stream 的 reaction region**——既费(每个铁/木 chunk 永远跑)、又给客户端灌空 0x73、还会翻掉「惰性块不分配场」的既有测试(如 `chunk_process_test` line 791 放冷铁断言 `field_region_count == 0`)。这显然不是「活性」的本意。

**死区免疫(dead-region-free)谓词**——`emergence` region(`[light_propagation, reaction]`)active 当且仅当 chunk 内:

- 任一 `light_emission > 0` cell(发光体),**或**
- 任一**热异常** cell(truth 温度 ≠ ambient——涵盖热致发光源 ≥Draper、以及一切温度 gate 的反应:熔化/燃烧/氧化/热致光),**或**
- 任一**进行中反应**(反应进度 attr `burn/oxidation/growth_progress > 0`,或瞬态反应 tag 如 `:rusting/:burning/:illuminated`)——保证反应跨 tick 连续不被 source 瞬时回落掐断。

> 关键洞见:因「无常温自发反应」,上述「真在 source / 真在反应」谓词**已覆盖每一个真实涌现**(放发光体→第一条;放热/通电产焦耳热→第二条;反应一旦起步→第三条续命)。无需「静态 rule 成员」式白名单,也就没有死区。冷惰性 chunk → 三条全否 → 无 region(`field_region_count == 0` 既有测试不变即过)。

- **electric_circuit**:沿用现有 `auto_circuit_source_points`/`role_count`/`closed_circuit_count`(power source + load + 闭合回路)。其焦耳热提交 truth → 下一 sweep 触发 emergence/thermal(能量驱动)。
- **thermal**(`[temperature_diffusion]`):chunk 有热异常即 active(复用 `build_temperature_anomaly` 异常检测)。与 emergence 共用「有热异常」触发,但各是独立 region(温度场层 vs 光+反应)。

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

## 10. 拍板结论(2026-06-23)

1. **emergence 探测积极程度** → **任一活性材料即起**。落地细化(见 §6):因「无常温自发反应 + 每 tick 无条件 fanout」,「活性」取「现在真在 source / 真在反应」的死区免疫谓词(发光体 / 热异常 / 进行中反应),既忠于「任一活性即起」,又不产生空跑空 stream 的死区,且既有「惰性块不分配场」测试不变即过。
2. **首切范围** → **一次 step1–5 全做**(光 + 热 + 反应全有机化)。
3. **thermal 与 dev 端点** → **本轮把 `DevFieldCreate` 收编为 thermal provisioner 的显式调用方**,去掉「只有 dev 端点才有温度流」的怪状态。
