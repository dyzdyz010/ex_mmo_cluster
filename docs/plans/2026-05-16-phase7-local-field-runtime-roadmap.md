# Phase 7+ 局部场运行时架构路线图

状态：后续推进基准文档；Phase 7.D1 已落地（2026-05-16）  
日期：2026-05-16  
适用范围：`ex_mmo_cluster` 的 voxel local field / FieldRuntime / material-driven field effects  
关联文档：

- `docs/plans/2026-05-14-phase7-field-kernel-architecture.md`
- `docs/plans/2026-05-16-phase8-physical-phenomenon-system-architecture.md`
- `docs/2026-05-13-体素局部场最小目标-索引.md`
- `docs/voxel-server-authority/README.md`

本文档是 Phase 7 后续推进的执行基准。已有 Phase 7 文档仍保留底层 kernel 设计、协议约束和实现细节；后续排期、优先级和验收以本文档为准。

---

## 1. 当前基线

已经完成：

1. Phase 6 局部场最小目标已经落地：`FieldLayer`、`FieldRegion`、`FieldTickWorker`、`FieldCodec` opcode `0x73` / `0x74`、web client `FieldDebugOverlay`。
2. Phase 7.A kernel-first 架构已经落地：`FieldKernel`、`KernelContext`、`TemperatureDiffusionKernel`、`ElectricPotentialKernel`、kernel 失败隔离、`field_types` 从 kernel `required_layers/1` 派生。
3. 温度异常入口已经验证架构可用：`Heat` / `F` 先写 selected voxel 的 `temperature` attribute，再由 `FieldRuntime` 从 voxel truth 读取有效温度，超过环境阈值后创建或复用 `TemperatureDiffusionKernel` region。
4. 温度层保存相对环境温度的 signed delta，升温和降温在核心扩散方程上是同一套机制。
5. 温度扩散系数已经切换为材料属性驱动：`thermal_diffusivity = thermal_conductivity / (density * specific_heat_capacity)`。
6. Phase 7.D1 已把 Heat demo 收敛为正式 `SetTemperature/Cool` 能力：服务端新增
   `/ingame/voxel/set_temperature`，web CLI 新增 `voxel_temp`，`voxel_heat` /
   `voxel_cool` 保留为别名，HUD 暴露 Heat / Cool 入口。
7. Phase 7.D2 温度 source 最小闭环已落地：`FieldSource` 成为 set-temperature
   的 runtime source 事实，`ChunkProcess` 可按 `source_key` 复用或释放活跃
   FieldRegion；目标温度回到环境阈值内时会走 0x74 销毁路径并清理 source。

仍未完成：

1. `FieldSource` 目前只闭合温度 set-temperature 路径；object / magic / weather /
   device 等 generic owner、ttl、budget、persistent source 生命周期仍未实现。
2. 未完成从持久 voxel truth 扫描或订阅异常属性。
3. 只完成了“set-temperature 回到环境阈值内”时的主动销毁；基于 active cells、
   source owner、预算、region 扩张/收缩和分片的完整 lifecycle 仍未完成。
4. kernel effect 还没有统一的结构化结算边界；永久烧毁、冻结、融化、点燃、伤害、属性写回等还没有统一 dispatcher。
5. 跨 chunk field、AOI 降频、网络预算和大范围事件 LOD 仍是设计约束，不是完整实现。

结论：当前不是“温度按钮 demo”，而是一个可验证的局部场内核起点；下一步应补 FieldRuntime 的运行时能力，而不是继续堆单点演示。

---

## 2. 设计原则

### 2.1 常态在 truth，异常在 field

常态属性属于 voxel / object / material / environment truth：

- `temperature`
- `moisture`
- `density`
- `thermal_conductivity`
- `specific_heat_capacity`
- `electric_conductivity`
- `dielectric_strength`
- `oxygen`
- `structural_integrity`

局部高温、低温、电势差、电离通道、压力波、烟尘、魔法扰动等异常才创建 `FieldRegion`。

### 2.2 signed field 是正式能力

温度场不是“热场”，而是相对环境温度的 signed delta。

- 正 delta 表示升温异常。
- 负 delta 表示降温异常。
- 同一套扩散、阈值、生命周期和 overlay 机制必须覆盖升温与降温。
- `heat_energy_joules` 可以继续表示非负加热能量；降温应走 target temperature，而不是负 energy。

### 2.3 源生命周期优先于更多效果

新增火焰、电击、冰冻、天气、魔法之前，必须先把 source 抽象稳定下来。否则每个入口都会自行创建、续租、合并和销毁 region，最终把 `ChunkProcess`、HTTP handler、Combat、Magic 和 web client 都耦在一起。

### 2.4 kernel 只演化 field，不直接拥有世界结算

kernel 可以读 storage、更新 `FieldLayer`、产出结构化 effects，但不应直接绕过事务/版本/fence 去修改 voxel 或 object truth。

推荐边界：

```text
FieldKernel.tick
  -> next FieldRegion
  -> [FieldEffect]

FieldRuntime / ChunkProcess / gameplay dispatcher
  -> validates effect
  -> applies versioned voxel/object mutation
  -> fans out deltas / snapshots
```

### 2.5 无异常零成本

没有活跃 source 或梯度时，不应有 field worker、field tick、field snapshot、overlay 数据或 AOI 带宽。

### 2.6 单 region 有硬上限

FieldRegion 不应无限扩张。大范围事件必须拆成近场精细 FieldRegions、中远场稀疏 effect / source、持久 attribute 或 object state 写回，以及远场视觉、声音、震动和天空 cue。

### 2.7 每个能力必须可操作、可观测、可测试

每个阶段至少要同时提供真实用户入口、CLI 或 browser `window.__voxelCli` 入口、结构化 observe 日志或 snapshot、服务端测试、客户端协议/overlay 测试。

---

## 3. 目标架构

### 3.1 FieldSource

后续引入显式 `FieldSource`，作为 field 创建、续租、合并和销毁的事实来源。

建议结构：

```text
FieldSource
  source_id
  source_key
  source_kind: :temperature | :electric | :combustion | :weather | :magic | :device
  source_mode: :impulse | :persistent
  owner_ref: voxel | object | combat_effect | weather_event | magic_effect
  location: world_macro | aabb
  target_value | source_value | energy_budget
  kernel_specs
  decay_policy
  lease_token
  created_tick
  updated_tick
```

`FieldSource` 不是新的世界真值层。它是 `FieldRuntime` 对“哪些异常需要活跃 field worker”这件事的运行时索引。

### 3.2 FieldRuntime

`FieldRuntime` 后续职责：

1. 从 voxel / object / gameplay / weather / magic truth 创建或更新 `FieldSource`。
2. 根据 source、能量预算、传播模式和最大精度范围估算初始 AABB。
3. 创建、复用、合并或拆分 `FieldRegion`。
4. 根据 active cells、source 是否还存在、阈值和预算销毁 region。
5. 接收 kernel effects 并交给权威 dispatcher。
6. 维护性能预算、tick 频率、AOI 降级和可观测指标。

`FieldRuntime` 不应成为“所有玩法逻辑”的大杂烩。它只负责异常场运行时，不负责判定技能命中、物品规则或 UI 表现。

### 3.3 FieldRegion / FieldLayer / FieldKernel

保持现有边界：

- `FieldRegion`：生命周期、AABB、tick count、source points、active layers、kernel specs。
- `FieldLayer`：单一 field type 的稀疏值存储。
- `FieldKernel`：某种传播模式的确定性演化。
- `FieldTickWorker`：per-region 调度、隔离、snapshot 推送、destroy 通知。

### 3.4 FieldEffect

kernel effect 应结构化，不能只用日志或 ad hoc map。

建议第一批 effect：

```text
FieldEffect
  :write_voxel_attribute
  :write_object_attribute
  :ignite_candidate
  :freeze_candidate
  :melt_candidate
  :damage_object
  :spawn_field_source
  :destroy_field_source
```

effect dispatcher 必须处理 version / fence、chunk authority、object owner lookup、idempotency、retry / reject reason、delta fan-out。

---

## 4. 推进路线

### Phase 7.D1：SetTemperature / Cool 正式化

状态：已落地（2026-05-16）。

目标：把当前 `Heat` demo 收敛成正式的温度设置能力。

实施要点：

1. 服务端增加正式语义入口：`set_temperature`、`target_temperature_celsius`、`restore_ambient`。保留 `dev_heat_voxel` 兼容路径，但文档上降级为 legacy demo alias。
2. web client 增加正式 CLI：`voxel_temp <x> <y> <z> <target_temperature_celsius> [max_ticks]`。
3. `voxel_heat` 作为 `voxel_temp ... 800` alias；`voxel_cool` 作为 `voxel_temp ... 0` 或用户指定温度 alias。
4. HUD 保留快捷按钮，但语义改为 Heat selected / Cool selected / Set temperature。
5. 明确：降温必须走 target temperature，不走负 `heat_energy_joules`。
6. 测试升温和降温都能创建同类 `TemperatureDiffusionKernel` region。

验收：

- 服务端测试覆盖 `800C` 与 `0C/-20C`。
- web CLI 测试覆盖 `voxel_temp`、`voxel_heat`、`voxel_cool`。
- overlay 测试覆盖 hot red 与 cold purple。
- browser smoke 能用 `window.__voxelCli` 触发、读取 overlay 状态、看到 field snapshot。

完成证据：

- 服务端：`FieldRuntime.ensure_set_temperature/1` 走 `target_temperature_celsius`，
  会丢弃 legacy `heat_energy_joules` 参数；`dev_heat_voxel` 保留 legacy alias。
- HTTP：`POST /ingame/voxel/set_temperature` 是正式入口，`restore_ambient=true`
  表达回到环境温度。
- web：`voxel_temp <x> <y> <z> <target_temperature_celsius> [max_ticks]`
  是基准 CLI；`voxel_heat`、`voxel_cool` 为别名；HUD 暴露 Heat / Cool。
- 验证：服务端测试覆盖 800C、0C、-20C；web 测试覆盖 CLI、请求 payload、
  HUD Heat/Cool、hot/cold overlay。

### Phase 7.D2：FieldSource registry + 生命周期

状态：温度 source 最小闭环已落地（2026-05-16）；generic multi-owner source
registry / ttl / budget / persistent source 仍留给后续扩展。

目标：让 source 成为 FieldRuntime 的一等运行时事实。

实施要点：

1. 新增 `FieldSource` 数据结构。
2. `FieldRuntime.ensure_temperature_anomaly/1` 改为创建或更新 source，再由 source 派生 region。
3. `ChunkProcess.ensure_field_region/2` 的 `source_key` 复用逻辑保留，但职责从“入口去重”收敛为“runtime source to region lease”。
4. 引入生命周期策略：impulse source 注入后消耗；persistent source 在 owner 存在且条件成立时续租；ttl source 超时销毁；budget source 能量耗尽销毁。
5. 自动销毁条件：所有 active cells 低于 field threshold、source 不再存在、region 超出预算或 tick limit。
6. 增加 observe 日志：source created / updated / expired、region reused / split / destroyed、active cell count、snapshot bytes。

验收：

- 重复对同一 voxel 设置温度不会堆叠多个 region。
- source 消失或异常低于阈值后 region 自动销毁，并发 `0x74`。
- 无 source 时没有 field tick 和 overlay 数据。

完成证据：

- `SceneServer.Voxel.Field.FieldSource` 提供 source 结构、normalizer、summary 和
  temperature runtime attrs。
- `FieldRuntime.ensure_set_temperature/1` 先规范化 temperature `FieldSource`，
  再从 source 派生 `ensure_temperature_anomaly/1` 所需 attrs。
- `ChunkProcess.ensure_field_region/2` 返回并记录 `region_action` 和
  `source_points_action`，可区分 created / reused / appended / rejected。
- `ChunkProcess.release_field_region_source/3` 可按 `source_key` 释放活跃 region，
  复用既有 worker stop + 0x74 destroy fanout。
- `target_temperature_celsius=20` 或 `restore_ambient=true` 让 anomaly 回到环境阈值内时，
  `FieldRuntime` 会释放同一 source 对应的活跃 region；服务端测试断言
  `field_region_count == 0` 且 `field_source_count == 0`。

### Phase 7.D3：FieldEffect dispatcher + truth 写回

状态：温度 writeback 最小闭环已落地；candidate phenomenon / object effect 仍留后续。

目标：让 field 能产生持久世界结果，但不破坏权威事务边界。

实施要点：

1. 定义 `FieldEffect` 结构。
2. `FieldTickWorker` 收集 kernel effects，但不直接写 object/voxel truth。
3. `ChunkProcess` 或专门 dispatcher 负责应用 effect。
4. 第一批只做温度相关结果：`write_voxel_attribute(:temperature)`、`ignite_candidate`、`freeze_candidate`、`melt_candidate`。
5. 暂不接 HP / combat damage，先证明 attribute writeback 边界。

验收：

- 温度 `write_voxel_attribute(:temperature)` effect 可由 `FieldTickWorker` 交给
  `ChunkProcess.apply_field_effects/3`，并通过 chunk authority 写入 voxel truth。
- unsupported action / unsupported attribute 必须明确 reject，不允许静默丢弃。
- applied / rejected lifecycle 进入结构化日志：
  `voxel_field_effect_applied` / `voxel_field_effect_rejected`。
- 客户端/CLI 后续可从 chunk snapshot 看到持久 attribute 变化，而不只看到 overlay。

已完成最小证据：

- `apps/scene_server/test/scene_server/voxel/chunk_process_test.exs` 覆盖 dispatcher
  应用温度 effect、触发 snapshot fallback、写入 `temperature` truth，以及 unsupported
  effect 不变更 chunk_version。
- `apps/scene_server/test/scene_server/voxel/field/field_tick_worker_kernel_test.exs`
  覆盖 worker 收到 non-observe effect 后交给 chunk authority；unsupported effect
  产出 reject observe。

### Phase 7.E：材料与环境模型扩展

目标：把 field 结算依赖的物理属性补齐，但避免 schema 膨胀。

实施要点：

1. `MaterialDef` / attribute catalog 扩展：`ignition_temperature`、`melting_point`、`freezing_point`、`boiling_point`、`electric_conductivity`、`dielectric_strength`，可选 `latent_heat`。
2. runtime voxel state 只保存动态状态：current temperature、moisture、oxygen、ionization、structural integrity、material/state transition result。
3. 不把“晶体性”“魔法性”等语义直接塞进每个 voxel。优先作为 material/template 派生属性或 source/kernel 参数。

验收：

- 材料 fixture / hash 稳定。
- 每个新增属性有单位、范围、默认值和 fallback。
- 温度 field 使用材料阈值产出 effect，而不是硬编码 wood/ice 等特殊分支。

### Phase 7.B：ConductionPathKernel v1

目标：证明局部场架构不只支持扩散，还支持路径搜索和通道形成。

排序说明：原 Phase 7 文档把它列为下一步。现在建议在 7.D1/7.D2 之后推进；如果要并行，也必须遵守 `FieldSource` 与 `FieldEffect` 边界。

实施要点：

1. 新增 `ConductionPathKernel`。
2. 使用 `electric_potential` + `ionization` 表达 v1 channel，不扩展主 wire。
3. 输入先用 material tags / density fallback，等 Phase 7.C 后切换正式电属性。
4. 搜索必须有 AABB 上限、frontier 上限、tick 时间上限和 deterministic seed。
5. 增加 electric dev demo 入口，区别于 temperature demo。

验收：

- 同一输入和 seed 产生确定性 channel。
- 搜索超预算时截断或延期，不阻塞 worker。
- channel 通过现有 `0x73` 下发并被 web overlay 显示。

### Phase 7.C：电属性 catalog 扩展

目标：让电场和导通路径从 tag fallback 过渡到材料属性驱动。

实施要点：

1. 新增 `electric_conductivity`。
2. 新增 `dielectric_strength`。
3. 可选新增 `charge_capacity`。
4. density/tag fallback 标记为 legacy fallback。
5. 补 catalog patch、golden fixture 和 chunk hash 验证。

验收：

- `ConductionPathKernel` 优先读取正式电属性。
- fixture 和 wire roundtrip 稳定。
- 文档明确单位、范围和默认值。

### Phase 7.F：跨 chunk、AOI 与性能预算

目标：让局部场能服务多人和大世界，不因为局部事件打爆 tick、内存或带宽。

实施要点：

1. 单 region 继续限制为 chunk-local 或少量 chunk-local region。
2. 跨 chunk 扩散使用 region 分片 + halo/boundary 交换。
3. `FieldRuntime` 负责按 chunk、AOI、影响层级拆分大范围事件。
4. 网络推送策略：只推 AOI 内 region；只推变化超过阈值的 sparse cells；远场降频或降级为 cue。
5. 增加性能指标：active region count、active cell count、tick p50/p95/p99、mailbox length、snapshot bytes per second、per-client field bandwidth。

验收：

- 压测能声明具体预算，例如 N 个 region / M 个客户端 / 10 Hz 下 p95 tick 和带宽。
- 远场不会创建高频 FieldRegion。
- 单个大范围事件被拆成近场 region、中远场稀疏 effect 和持久 truth 写回。

### Phase 8：Gameplay / Magic / Weather 接入

目标：让 Combat、Sevara/magic、weather 通过统一 source/effect 机制接入，不绕过 FieldRuntime。

实施要点：

1. Combat skill 只提交 source/effect request，不直接造 `FieldRegion`。
2. Sevara 输出 `SpellPlan` / mechanism graph，再映射成 field sources 和 material/effect constraints。
3. Weather 作为 persistent source 或 high-level event。
4. Object/device 作为 persistent source owner，例如火把、炉子、电机、魔法锚点。

验收：

- 同一套 source registry 能同时承载 heat/cool、electric、magic、weather。
- magic 不拥有世界法则执行权，只是请求/编译/约束层。
- gameplay effect 全部经过 dispatcher 的版本和 authority 校验。

### Phase 8.P：Physical Phenomenon System 设计承接

状态：设计文档已落地，等待 Phase 7.D2 / 7.D3 / 7.E 完成后进入实现。

设计文档：`docs/plans/2026-05-16-phase8-physical-phenomenon-system-architecture.md`

目标：在局部场运行时补完后，用独立 `PhenomenonSystem` 承接燃烧、结冰、结构完整度、
碳化、腐蚀、相变等条件触发和持久状态转换。

边界：

1. `FieldRuntime` 负责连续量异常和 source/region 生命周期。
2. `FieldKernel` 只演化 field 并产出结构化 effect。
3. `PhenomenonSystem` 读取 truth + field + material，判断现象状态机，并输出
   `PhenomenonEffect`。
4. 持久写回仍走权威 dispatcher / `ChunkProcess` / object owner 边界。

Phase 8 第一版不直接做完整 Combat HP、不做工程级 CFD、不让 Sevara 直接执行物理法则。

---

## 5. 推荐执行顺序

严格推荐顺序：

```text
7.D1 SetTemperature/Cool 正式化
-> 7.D2 FieldSource registry + 生命周期
-> 7.D3 FieldEffect dispatcher + truth 写回
-> 7.E 材料与环境模型扩展
-> 7.B ConductionPathKernel v1
-> 7.C 电属性 catalog 扩展
-> 7.F 跨 chunk / AOI / 性能预算
-> 8 Gameplay / Magic / Weather 接入
```

如果需要更快看到新视觉效果，可以把 `7.B ConductionPathKernel v1` 提前为并行 spike，但 spike 不能绕过 `FieldSource` / `FieldEffect` 边界，也不能把临时代码固化成正式入口。

---

## 6. 验证约定

每个阶段完成前至少运行：

```powershell
mix.bat test
mix.bat precommit
```

涉及 web client 时再运行：

```powershell
npm test
npm run build
```

涉及用户交互时必须补充 browser smoke，优先使用：

```js
window.__voxelCli.run("transport")
window.__voxelCli.run("voxel_sync")
window.__voxelCli.run("snapshot")
window.__voxelCli.run("field_overlay")
```

温度能力 smoke 至少覆盖：

```js
window.__voxelCli.run("voxel_temp 8 0 8 800 300")
window.__voxelCli.run("voxel_temp 8 0 8 0 300")
```

后续可以保留 `voxel_heat` / `voxel_cool` alias，但基准验证应使用正式 `voxel_temp`。

---

## 7. 非目标

Phase 7+ 不直接承诺：

1. 全世界连续热力学模拟。
2. 微观级每 micro slot 热扩散。
3. 核爆级事件用一个巨大 FieldRegion 表示。
4. field 状态长期持久化。
5. 一次性接入完整 Sevara / Combat / Weather。
6. 真实工程级 CFD、燃烧化学或相变全物理精度。

本阶段目标是游戏服务器可承受、玩家可观察、玩法可组合的局部异常场架构。

---

## 8. 后续文档维护规则

1. 每完成一个阶段，在本文档对应阶段下更新状态和完成证据。
2. `docs/voxel-server-authority/README.md` 只维护高层索引；细节以本文档为准。
3. `docs/plans/2026-05-14-phase7-field-kernel-architecture.md` 继续作为 kernel 设计和协议背景，不再作为后续优先级来源。
4. 若后续实现发现本文档路线错误，应先更新本文档的 ADR/决策段，再改代码。
5. 所有交互能力必须同步维护 CLI / observe / test path，不能只交付 UI 或底层核心。

---

## 9. 下一步可执行任务

下一轮建议直接启动：

```text
Phase 7.D3: FieldEffect dispatcher + truth 写回
```

最小交付：

1. `FieldEffect` 结构与 dispatcher 边界。
2. `FieldTickWorker` 不直接写 truth，只把 non-observe effects 交给 dispatcher 或明确 reject。
3. 第一批只做温度相关 `write_voxel_attribute(:temperature)` / candidate effect 的传递路径。
4. effect 应用必须经过 version / authority / reject reason 记录，不复用 ad hoc 直写作为通用面。
5. 服务端测试证明 effect 被应用或明确 reject；observe 能看到 effect lifecycle。

完成 D3 后再扩材料物理属性；不要跳到 `ConductionPathKernel` 或燃烧/结冰具体现象实现。

---

## 10. 进度日志

### 2026-05-16：Phase 7.D1 / 7.D2 提交前收口

已完成：

1. Phase 7.D1 `SetTemperature/Cool` 正式入口：`/ingame/voxel/set_temperature`、web CLI
   `voxel_temp`、`voxel_heat` / `voxel_cool` alias、HUD Heat/Cool、hot/cold overlay。
2. Phase 7.D2 温度 source 最小闭环：`FieldSource` runtime 事实、source lifecycle observe、
   同源 region 复用、ambient/threshold cleanup 通过 0x74 销毁并释放 source。
3. Phase 8 物理现象系统设计稿已落地，但实现仍等待 D3 / E。
4. HTTP JSON 响应已覆盖 source / cleanup 摘要安全编码，避免 tuple / module 泄露到 Jason。

验证证据：

```powershell
mix.bat test
mix.bat compile --warnings-as-errors
npm test -- src/presentation/devtools/devToolsCli.test.ts src/presentation/hud/hudView.test.ts src/presentation/hud/voxelDebugPanelView.test.ts src/voxel/field/fieldDebugOverlay.test.ts src/voxel/onlineVoxelWorldAdapter.test.ts src/app/controllers/worldEditController.test.ts src/app/controllers/inputController.test.ts
npm run build
mix.bat format --check-formatted <changed elixir files>
git diff --check
```

遗留：

1. `FieldSource` 仍是温度 source 最小闭环，不是 generic multi-owner source registry。
2. `FieldEffect` dispatcher 与 truth 写回未完成，是下一步主线。
3. Phase 8 只进入设计，不实现燃烧、结冰、结构完整度、碳化、腐蚀、相变。

### 2026-05-16：Phase 7.D3 温度 FieldEffect 最小闭环

已完成：

1. `FieldTickWorker` 对 non-observe kernel effects 不再静默丢弃，而是交给
   `ChunkProcess.apply_field_effects/3`。
2. `ChunkProcess` 作为 chunk truth owner 应用第一批 effect：
   `write_voxel_attribute(:temperature)`。
3. unsupported action / unsupported attribute 明确 reject，并写入
   `voxel_field_effect_rejected`。
4. applied path 写入 voxel `temperature` truth，触发 chunk snapshot fallback，并写入
   `voxel_field_effect_applied`。

验证证据：

```powershell
mix.bat test apps/scene_server/test/scene_server/voxel/chunk_process_test.exs apps/scene_server/test/scene_server/voxel/field/field_tick_worker_kernel_test.exs
```

遗留：

1. `ignite_candidate` / `freeze_candidate` / `melt_candidate` 只保留为后续结构化 candidate，
   目前仍应 reject/defer，不能抢跑 Phase 8。
2. object/combat/source lifecycle effect 尚未接入。
3. 仍需补 full umbrella / compile / diff hygiene 后才能提交本 D3 切片。
