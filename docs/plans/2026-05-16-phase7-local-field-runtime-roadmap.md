# Phase 7+ 局部场运行时架构路线图

状态：后续推进基准文档；Phase 7.D1 / 7.D2 / 7.D3 已落地，Phase 7.E 第一批已落地，Phase 7.B core + runtime/web 入口已落地，Phase 7.F 前置 electric source lifecycle、physical power block、电热写回与 GUI 热烟可视化第一片已落地（2026-05-19）。当前暂停继续扩展底层物理实现，下一轮聚焦 web client 的 UI 与指示优化；UI 验收后恢复 Phase 7.F / Phase 8 前置主线深挖。
日期：2026-05-16  
适用范围：`ex_mmo_cluster` 的 voxel local field / FieldRuntime / material-driven field effects  
关联文档：

- `docs/plans/2026-05-14-phase7-field-kernel-architecture.md`
- `docs/plans/2026-05-16-phase8-physical-phenomenon-system-architecture.md`
- `docs/plans/2026-05-19-prefab-field-participant-projection.md`
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
   FieldRegion；browser Heat / `F` 默认使用 `:impulse`，一次注入后通过扩散、AABB
   边界和 `ambient_loss_per_second` 消散，`source_mode: :persistent` 保留给火把/设备等持续源。
   目标温度回到环境阈值内时会走 0x74 销毁路径并清理 source。
8. Phase 7.E 第一批 material/default 物性已落地：
   `ignition_temperature`、`melting_point`、`freezing_point`、`boiling_point`、
   `electric_conductivity`、`dielectric_strength` 已能通过
   `Storage.effective_attribute_at/3` / `_normalized/3` 读取。
9. Phase 7.B 已落地：`ConductionPathKernel` 可在 chunk-local AABB 内按
   `electric_conductivity` / `dielectric_strength` 做 deterministic channel 搜索，
   并只刷新 `electric_potential` / `ionization` layer，不直接写 voxel/object truth；
   `FieldRuntime.ensure_conduction_path/1`、`POST /ingame/voxel/conduct` 和 web CLI
   `voxel_conduct` 已提供可操作入口，成功请求会自动打开 Field overlay。
10. Phase 7.F 前置第一片已落地：electric conduction 也会正规化为 `FieldSource`，
    source key 纳入 owner identity，HTTP/runtime 可携带 `owner_ref`、`source_mode`、
    `ttl_ticks` 与 `energy_budget_joules`；`ttl_ticks` 会约束当前 FieldRegion 的
    runtime lifetime，但 budget 消耗、owner 存活探测和跨 chunk lifecycle 仍留后续。
11. Physical power block 第一片已落地：`material_id=6` 的 `power_block` 是默认物理电源；
    未显式传入 device/object/magic owner 或 power 参数时，普通 iron 只做导线，不再能
    凭空生成电场。`power_block` 默认声明 DC 120V、20A、20_000J supply policy。
12. Electric-to-thermal 第一片已落地：导电路径会按 `PowerSource` 的 voltage/load current
    生成焦耳热 `FieldEffect`，由 `ChunkProcess` 写回 voxel 温度 truth；HTTP/Web CLI 可传
    `load_current_amps` 与 `energy_budget_joules`，过载负载会在创建 FieldRegion 前以
    `current_limit_exceeded` 拒绝。
13. 相邻双 chunk 电场第一切片已落地：`FieldRuntime.ensure_conduction_path/1`
    对直接相邻、边界接触已导通的 source/target，会协调创建两个 shard region。
    source chunk 仍保持 `field_source_count=1`，target chunk 只创建稳定复用的 region，
    不注册新的 source；`ConductionPathKernel` 和 `FieldRegion` 本身仍严格 chunk-local。
14. Field 层 native backend boundary 已建立：导电路径搜索的 chunk-local bounded
    Dijkstra、温度场 sparse 7-stencil 扩散、material-aware electric potential 传播都先接入
    `SceneServer.Voxel.Field.NativeBackend`；业务 kernel 只提交 Field 事实、AABB、
    candidate cells / electric projection 和 fallback，native ABI/DTO 编码集中在
    `NativeBackend.ConductionPathInput` / `NativeBackend.TemperatureDiffusionInput` /
    `NativeBackend.ElectricPotentialInput`。`SceneServer.Native.FieldKernel` 只是薄 Rustler
    binding，Rust crate 内按 `conduction_path` / `temperature_diffusion` /
    `electric_potential` / `grid` 分模块隔离职责。Elixir 仍保留 `path_backend: :elixir` /
    `temperature_backend: :elixir` / `electric_backend: :elixir` 参考实现，且 authority、
    FieldLayer 写入、热效应和 observe 不进入 native。后续纯计算 kernel 应复用
    `NativeBackend`，不要各自扩散成独立 native ownership。
15. Field native DTO 编码已按 region AABB 裁剪 `ParticipantProjection`：导电路径和
    material-aware electric potential 传播只把本次 field tick 需要的导电条目送进 Rust，
    避免局部区域计算携带整块 chunk 的投影图。
16. 跨 chunk conduction shard 的生命周期清理已覆盖 source release 和 source lease revoke：
    source chunk 在清空本地 `FieldTickWorker` 前会先执行 linked target shard cleanup，避免
    lease 变更时留下悬挂 target region。

仍未完成：

1. `FieldSource` 目前闭合了 temperature 与 electric conduction 的最小 owner/ttl/budget
   入口；object / magic / weather / device 等 generic persistent source owner 存活探测、
   budget 持续消耗和跨 chunk 生命周期仍未实现。
2. 未完成从持久 voxel truth 扫描或订阅异常属性。
3. 只完成了“set-temperature 回到环境阈值内”时的主动销毁；基于 active cells、
   source owner、预算、region 扩张/收缩和分片的完整 lifecycle 仍未完成。
4. kernel effect 已有温度 `write_voxel_attribute(:temperature)` dispatcher，导电可通过它写回
   焦耳热；永久烧毁、冻结、融化、点燃、伤害、object 写回和 source effect 仍未接入。
5. 跨 chunk field 目前只开放“两个直接相邻 chunk、一次边界跨越、双 shard 协调创建”
   的最小切片；真正的全地图搜索、merged snapshot、AOI 降频、网络预算和大范围
   事件 LOD 仍未实现。
6. 电场仍未接入 Phase 8 伤害、击穿破坏、object/combat 结算或更广义的跨 chunk
   field orchestration；这些仍是后续阶段，不应塞进当前导电入口。
7. prefab/object 尚未通过统一 field participant projection 进入所有局部场；后续不应让每个 kernel 分别特判 prefab。推进基准见
   `docs/plans/2026-05-19-prefab-field-participant-projection.md`，电场只作为首条验证路径。
8. `FieldEffect` dispatcher 仍是逐 effect 写回和逐次 snapshot fan-out；下一步需要改为
   chunk 内 batched mutation，单 tick 只做一次 version bump、一次 fan-out、一次 persist enqueue。
9. `ChunkProcess` 与 `FieldTickWorker` 仍有同步调用环；后续应把 field tick phase 收回
   chunk-owned coordinator，或至少改成只读 snapshot/async refresh，避免 tick 与 region refresh
   互相等待。
10. Field kernel 缺少 reads/writes/phase/conflict 合同；后续新增 phenomenon/damage/ignite
    kernel 前，需要先约束同一 region 内的 layer 写入顺序和冲突策略。

结论：当前不是“温度按钮 demo”，而是一个可验证的局部场内核起点。底层电源、电热、热烟，以及相邻双 chunk 的一次跨越导电第一片已经够支撑可玩验证；短期不继续扩展成全地图跨 chunk 搜索、持续能量扣减或 Phase 8 effect，而是先把 web client 的玩家 UI、状态指示和操作反馈打磨清楚。这个 UI 阶段只是主线的可操作性闸门，不是路线改道；UI 验收后继续回到 FieldRuntime / source lifecycle / phenomenon effect 的主线深挖。

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

状态：进行中（2026-05-16）。本阶段先扩展 material_default attribute catalog
和 material-specific fallback，再让后续 kernel / phenomenon 通过通用属性读取阈值；
不在本阶段直接实现燃烧、结冰、腐蚀或完整相变状态机。

目标：把 field 结算依赖的物理属性补齐，但避免 schema 膨胀。

实施要点：

1. `MaterialDef` / attribute catalog 扩展：`ignition_temperature`、`melting_point`、`freezing_point`、`boiling_point`、`electric_conductivity`、`dielectric_strength`。
   `latent_heat` 暂不进入第一批 seed，等 phase transition energy sink 有明确读写链路后再追加。
2. runtime voxel state 只保存动态状态：current temperature、moisture、oxygen、ionization、structural integrity、material/state transition result。
3. 不把“晶体性”“魔法性”等语义直接塞进每个 voxel。优先作为 material/template 派生属性或 source/kernel 参数。

验收：

- 材料 fixture / hash 稳定。
- 每个新增属性有单位、范围、默认值和 fallback。
- 温度 field 使用材料阈值产出 effect，而不是硬编码 wood/ice 等特殊分支。

### Phase 7.B：ConductionPathKernel v1

目标：证明局部场架构不只支持扩散，还支持路径搜索和通道形成。

排序说明：原 Phase 7 文档把它列为下一步。已在 7.E 第一批之后补上 core kernel；
后续 electric dev/runtime 入口仍必须遵守 `FieldSource` 与 `FieldEffect` 边界。

实施要点：

1. 新增 `ConductionPathKernel`。（core 已完成）
2. 使用 `electric_potential` + `ionization` 表达 v1 channel，不扩展主 wire。
3. 输入使用 Phase 7.E 已落地的 `electric_conductivity` / `dielectric_strength`，
   不再用 wood/ice/iron 硬编码分支，也不把 density fallback 固化为正式路径。
4. 搜索必须有 AABB 上限、frontier 上限、tick 时间上限和 deterministic seed。
5. 增加 electric dev/demo runtime 入口，区别于 temperature demo。（已完成：
   `voxel_conduct` -> `/ingame/voxel/conduct` -> `FieldRuntime.ensure_conduction_path/1`）

验收：

- 同一输入和 seed 产生确定性 channel。（core 已覆盖）
- 搜索超预算时截断或延期，不阻塞 worker。
- channel 通过现有 `0x73` 下发并被 web overlay 显示；web 请求成功后自动打开
  `FieldDebugOverlay`。

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
Web client field UX polish: 电源/导电/发热状态 UI、操作指示与反馈
```

最小交付：

1. 把现有 Heat/Cool/Conduct/Field Overlay 操作整理成玩家能看懂的面板状态，而不是只靠 CLI 文本。
2. 给电源块、导电路径和热烟增加明确指示：当前选中材料、导电端点、请求是否 accepted、region id、
   电源模式、电压/负载电流、热烟强度。
3. 保持非 GUI 验证面：所有 UI 新指示都必须能从 `field_overlay`、observe log 或现有 debug snapshot
   读到同一业务状态。
4. 不在这一轮继续做跨 chunk 电场、tick-by-tick 能量扣减、材料熔断、伤害或 Phase 8 phenomenon。
5. 验收以浏览器可操作为主：打开客户端后能不用记 CLI 参数完成电源块/导线/导电/发热观察流程。

UI 验收后的主线恢复任务：

```text
Phase 7.F / Phase 8 前置深挖: electric source lifecycle、预算消耗、跨 chunk/AOI 与玩法 effect 边界
```

恢复顺序：

1. **持续能源与跳闸状态**：`PowerSource.energy_budget_joules` 从首 tick 预算门槛升级为
   tick-by-tick 消耗；source budget 耗尽后进入 trip/offline 状态，并通过 observe / HTTP / UI 暴露。
2. **source owner 存活探测**：`power_block` 被挖掉、device/object owner 消失、magic/weather source
   结束时，runtime 必须释放对应 FieldRegion，不能残留电场或热烟。
3. **跨 chunk field 分片与 AOI 预算**：导电搜索、field snapshot 和网络推送要按 chunk/region 分片；
   不把大范围电击塞进单个 chunk-local region，也不让客户端一次收到不可控的大量 field cell。
4. **Phase 8 effect 边界**：材料熔断、击穿破坏、燃烧、伤害、object/combat 结算进入
   phenomenon/effect 层；`ConductionPathKernel` 仍只产 field/effect 意图，不直接写 gameplay truth。
5. **验收方式**：每个深挖 slice 都必须同时提供服务端 focused tests、web CLI/observe 证据和浏览器可操作入口。

---

## 10. 进度日志

### 2026-05-19：UI polish 后的主线恢复约定

决策：

1. 当前 UI/指示优化是为了让电源块、导电、电热、热烟这条业务链路可操作、可观察、可验收；
   它不是 Phase 7 主线改道。
2. UI 验收后恢复主线深挖，优先顺序固定为：持续能源与跳闸、source owner 存活探测、
   跨 chunk/AOI 预算、Phase 8 phenomenon/effect 边界。
3. 后续不得因为 UI 已经能展示烟雾，就跳过能源消耗、断电、熔断/击穿和 gameplay effect 的架构边界。

### 2026-05-18：Phase 7.F 前置 physical power block 第一片

已完成：

1. `SceneServer.Voxel.MaterialCatalog` 新增 append-only `material_id=6` 的 `power_block`，
   该材料具有导电物性，并声明默认供电策略：DC 120V、20A、20_000J。
2. `FieldRuntime.ensure_conduction_path/1` 会在 source chunk 的 authoritative
   `Storage` 中读取源点材料。未显式传入 owner/power 参数时，source 必须是
   `power_block`；普通 iron 虽然可导电，但会以 `source_not_powered` 拒绝。
3. 物理电源块的 electric source key 使用
   `{:electric, {:power_block, source_index}, source_index, target_index}`。如果电源块被挖掉，
   刷新请求会用同一 source key 释放旧 region，避免残留电场。
4. web client material catalog / hotbar / CLI material parser 已可选择和放置
   `power_block`；数字键范围扩到第 9 格，保证新增材料后 prefab 热栏仍可键盘选择。

验证证据：

```powershell
mix.bat test apps/scene_server/test/scene_server/voxel/material_catalog_test.exs apps/scene_server/test/scene_server/voxel/field/field_runtime_test.exs apps/auth_server/test/auth_server_web/controllers/ingame_controller_test.exs
npm test -- src/material/catalog.test.ts src/app/controllers/worldEditController.test.ts src/app/controllers/inputController.test.ts
```

遗留：

1. `power_block` 的 energy budget 已作为首 tick 预算门槛进入 runtime，但仍未随 tick 持续扣减。
2. 短路、材料熔断破坏、变压器、AC 相位仍属于后续 gameplay/effect slice。

### 2026-05-18：Phase 7.F electric-to-thermal / power fuse 第一片

已完成：

1. `PowerSource` 新增 `load_current_amps`，并提供有效负载电流、过载判断和单 tick 能量估算。
2. `FieldRuntime.ensure_conduction_path/1` 在通过材料导通预检后、创建 FieldRegion 前检查电源策略：
   负载电流超过 `current_limit_amps` 会拒绝为 `current_limit_exceeded`，首 tick 估算能量超过
   `energy_budget_joules` 会拒绝为 `energy_budget_exhausted`。
3. `ConductionPathKernel` 保持 chunk-local path kernel 边界：它只刷新 electric/ionization layer，
   并把导电路径上的焦耳热作为 `write_voxel_attribute(:temperature, heat_energy_joules)` effect
   交给 chunk authority。
4. `ChunkProcess.apply_field_effects/3` 扩展了温度 effect：同一个
   `write_voxel_attribute(:temperature)` action 既可设置目标温度，也可按焦耳热增量写回温度 truth。
5. Web CLI / HTTP 可操作入口扩展到
   `voxel_conduct ... [current_limit_amps] [frequency_hz] [load_current_amps] [energy_budget_joules]`，
   浏览器请求会把负载电流和 energy budget 透传到服务端。

验证证据：

```powershell
mix.bat test apps/scene_server/test/scene_server/voxel/chunk_process_test.exs apps/scene_server/test/scene_server/voxel/field/conduction_path_kernel_test.exs apps/scene_server/test/scene_server/voxel/field/field_tick_worker_kernel_test.exs apps/scene_server/test/scene_server/voxel/field/field_runtime_test.exs apps/scene_server/test/scene_server/voxel/field/field_source_test.exs apps/auth_server/test/auth_server_web/controllers/ingame_controller_test.exs
npm test -- src/presentation/devtools/devToolsCli.test.ts src/voxel/onlineVoxelWorldAdapter.test.ts
```

遗留：

1. energy budget 仍未做 tick-by-tick 持续扣减，也没有持久化 source trip 状态。
2. 材料过热后的融化、断线、掉落、damage/object 结算仍必须经 Phase 8 phenomenon/effect 边界实现。
3. 当前 AC 仍只作为 source policy 透传，不模拟相位和频率对热/场的影响。

### 2026-05-19：Phase 7.F 电热 GUI 热烟可视化第一片

已完成：

1. Web 客户端新增 `field/heatSmokeEffect.ts` 与 `field/heatSmokeRenderer.ts`：
   导电路径的 `power_draw.estimated_tick_energy_joules` 不再表现为方块染色，而是转成
   Field Overlay 内的灰色上升烟粒子。
2. `FieldDebugOverlay` 新增 `setRegionHeatSmokeSource/2` 与 `updateSmoke/1`，
   electric snapshot 到达时按活跃电场单元和焦耳热强度生成烟；`field_overlay` CLI
   snapshot 会返回每个 region 的 `smokeParticles`，文本输出为 `smoke=N`。
3. `OnlineVoxelWorldAdapter` 会把 `/ingame/voxel/conduct` 响应里的 `power_draw`
   归一化到 `world:voxel-conduction-accepted.powerDraw`；bootstrap 在请求 accepted
   后把 region 热量注册到渲染层，因此后续 field snapshot 才冒烟。

验证证据：

```powershell
npm test -- src/voxel/field/fieldDebugOverlay.test.ts src/voxel/onlineVoxelWorldAdapter.test.ts src/presentation/devtools/devToolsCli.test.ts
```

业务边界：

1. 热烟是客户端可视层，不是 voxel truth；温度 truth 仍由服务端 `write_voxel_attribute(:temperature)`
   写回。
2. 方块材质颜色不表达这条电热链路，避免把“发热效果”误认为“方块本体状态变色”。

### 2026-05-18：Phase 7.F 前置 electric source lifecycle 第一片

已完成：

1. `FieldSource.normalize/1` 新增 `:electric` 专用路径：根据 source/target world-macro
   派生 chunk/local/index、`ConductionPathKernel` spec、owner-aware source id/key，以及
   `field_radius`、`max_ticks`、`ttl_ticks`、`max_frontier`、`energy_budget_joules`
   decay policy。
2. `FieldRuntime.ensure_conduction_path/1` 改为从 normalized electric `FieldSource`
   创建/复用 region；默认 voxel owner 的 source key 变为
   `{:electric, {:voxel, source_index}, source_index, target_index}`，显式 owner 则纳入
   owner identity，例如 `{:electric, {:device, "coil-7"}, source_index, target_index}`。
3. `ttl_ticks` 会覆盖当前 conduction FieldRegion 的 `max_ticks`，用于第一版 source
   lifetime；worker 自然到期后会释放 active source，并写出 `source_action: :expired`
   的 `voxel_field_source_lifecycle` observe 事件；客户端仍通过 0x74 destroy payload
   看到 field 消失。
4. `POST /ingame/voxel/conduct` 可透传 `source_mode`、`source_owner_kind` /
   `source_owner_id`、`ttl_ticks` 与 `energy_budget_joules`；JSON 响应包含 `source`
   summary，便于 browser/CLI 观察。
5. 导电预检失败现在会写 `voxel_conduction_path_rejected` observe 事件：例如
   `max_frontier` 预算耗尽时，HTTP/runtime 仍对外返回兼容的 `:no_conductive_path`，
   但日志会保留 `raw_reason: :frontier_exhausted` 和
   `reject_reason: :search_budget_exhausted`，并携带 scene/chunk/source/target 定位字段。
6. `SceneServer.Voxel.Field.PowerSource` v1 已落地：electric `FieldSource` 会记录
   `output_mode: :dc | :ac | :pulse`、`voltage`、`current_limit_amps`、`frequency_hz` 与
   `energy_budget_joules`；未显式指定时，persistent source 默认按 DC，impulse source 默认按
   pulse。`/ingame/voxel/conduct` 与 web CLI `voxel_conduct ... [dc|ac|pulse] [voltage]
   [current_limit_amps] [frequency_hz]` 可透传这些字段，响应 summary 会回显 `power_source`。

验证证据：

```powershell
mix.bat test apps/scene_server/test/scene_server/voxel/field/field_source_test.exs apps/scene_server/test/scene_server/voxel/field/field_runtime_test.exs apps/auth_server/test/auth_server_web/controllers/ingame_controller_test.exs
```

遗留：

1. owner 存活探测、budget 消耗、source 自动续租和 source effect 仍未实现；当前
   `PowerSource` 只描述电源输出，不消耗能量、不结算负载，也不模拟完整 AC 相位。
2. 跨 chunk conduction、AOI 降频和大范围事件 LOD 仍未实现。
3. Phase 8 damage/ignite/breakdown 结算仍必须经 phenomenon/effect 层，不能放进
   `ConductionPathKernel`。

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
3. Phase 7.E 已开始，下一步先扩 material_default attribute catalog 和 material-specific fallback。

### 2026-05-16：Phase 7.E 材料与环境模型启动

本轮目标：

1. 把材料阈值与电属性作为正式 catalog 属性，而不是硬编码到未来现象系统。
2. `density` / `thermal_conductivity` / `specific_heat_capacity` 之外，补齐
   `ignition_temperature`、`melting_point`、`freezing_point`、`boiling_point`、
   `electric_conductivity`、`dielectric_strength`。
3. 仅扩 material/default 层，不给每个 voxel 增加“晶体性”“燃烧性”等泛化运行时字段。
4. 保留 Phase 8 现象系统边界：本阶段只提供可读物性和阈值，不直接执行燃烧、结冰、
   碳化、腐蚀或完整相变状态机。

### 2026-05-17：Phase 7.B ConductionPathKernel core

已完成：

1. 新增 `SceneServer.Voxel.Field.Kernels.ConductionPathKernel`，声明
   `:electric_potential` / `:ionization` layer，并保持 `FieldKernel.tick/3`
   side-effect-free。
2. channel 搜索使用 chunk-local AABB + bounded frontier + deterministic
   Dijkstra；同成本路径按 macro index 稳定排序。
3. 路径代价读取 `electric_conductivity` / `dielectric_strength`，并允许既有
   ionization 降低后续通道成本；测试证明铁路径优先于直接穿过木材的短路径。
4. channel 只刷新 `electric_potential` / `ionization` layer，不扩展 0x73/0x74 wire，
   不直接写 voxel/object truth。

验证证据：

```powershell
mix.bat test apps/scene_server/test/scene_server/voxel/field/conduction_path_kernel_test.exs
```

### 2026-05-17：Phase 7.B electric runtime/web 入口

已完成：

1. `SceneServer.Voxel.Field.FieldRuntime.ensure_conduction_path/1` 成为导电路径 runtime
   入口：按 source/target world-macro 计算同 chunk local AABB，创建或复用
   `ConductionPathKernel` FieldRegion。2026-05-18 后 source key 已改为 owner-aware
   electric `FieldSource` key。
2. `WorldServer.Voxel.DevFieldSeed.ensure_conduction_path/1` 负责跨节点 dispatch，
   `AuthServerWeb.IngameController.voxel_conduct/2` 暴露
   `POST /ingame/voxel/conduct`，JSON 响应保持 tuple/atom 安全编码。
3. web client 新增 `voxel_conduct <sx> <sy> <sz> <tx> <ty> <tz> [source_potential] [max_ticks]`，
   通过 `OnlineVoxelWorldAdapter.requestVoxelConductionPath` 调用 HTTP 入口。
4. `WorldEditController.conductBetween/5` 先 emit
   `world:voxel-conduction-requested` 记录提交；HTTP 200 后由 adapter emit
   `world:voxel-conduction-accepted`，bootstrap 再自动打开 `FieldDebugOverlay`，
   避免把后端拒绝误报成可见 field。

验证证据：

```powershell
mix.bat test apps/scene_server/test/scene_server/voxel/field/field_runtime_test.exs apps/auth_server/test/auth_server_web/controllers/ingame_controller_test.exs
npm test -- src/presentation/devtools/devToolsCli.test.ts src/app/controllers/worldEditController.test.ts src/voxel/onlineVoxelWorldAdapter.test.ts
```

遗留：

1. multi-owner electric source key、ttl 和 budget 摘要已 generic 化；owner 存活探测、
   budget 消耗和自动续租/过期仍未实现。
2. 跨 chunk conduction 目前只完成相邻双 chunk 的一次边界跨越：runtime 会在
   source/target 两侧创建协调 shard，但 `ConductionPathKernel` 仍不跨 chunk 搜索，
   也没有 merged snapshot、AOI 降频和大范围事件 LOD。
3. 还没有 Phase 8 damage/ignite/breakdown 结算；这些必须后续经 FieldEffect / gameplay
   dispatcher，而不是放进 kernel。

### 2026-05-19：prefab 电场相邻双 chunk 导电第一切片

已完成：

1. `FieldRuntime.ensure_conduction_path/1` 对直接相邻的跨 chunk source/target
   增加边界预检：source 必须位于 source chunk 边界，target 必须位于目标 chunk
   的相对边界。
2. 预检读取 source chunk 和已 hot 的 target chunk，分别构建
   `ParticipantProjection`，并复用 `electric_contact_transfer/8` 判断共享面
   micro 接触是否重叠。
3. 预检与 chunk-local channel 验证都通过时，runtime 会协调创建两个 shard：
   source chunk 创建带 `source_key` 的 source shard，target chunk 创建仅按稳定
   `region_id` 复用的 target shard。两侧重复请求会复用各自 shard。
4. source chunk 保持 `field_region_count=1 field_source_count=1`；target chunk
   保持 `field_region_count=1 field_source_count=0`，不会因为跨 chunk 投影而产生
   第二个 source。
5. 失败时返回更贴近业务的原因，例如 `target_not_conductive` 或
   `no_conductive_path`；只有非直接相邻跨 chunk 仍返回
   `cross_chunk_conduction_not_supported`。target shard 创建失败时会回滚本次新建的
   source shard，避免留下悬挂 source。

验证证据：

```powershell
cmd /c mix.bat test apps/scene_server/test/scene_server/voxel/field/field_runtime_test.exs apps/auth_server/test/auth_server_web/controllers/ingame_controller_test.exs --seed 0
```

遗留：

1. 真正跨 chunk path search、跨多 chunk 扩散、field region 分片调度、AOI 预算和
   snapshot 合流仍未开放。
2. target chunk 当前只 lookup 已启动 chunk；这条路径不会为了单次跨 chunk 请求去主动
   启动远端 chunk。
