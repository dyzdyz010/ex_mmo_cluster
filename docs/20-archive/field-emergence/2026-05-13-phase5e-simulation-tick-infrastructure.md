# Phase 5.E: Scene 低频规则帧基础设施 — 设计草案

状态：设计稿，等用户复核 E-1..E-6 决策点
日期：2026-05-13
归属：goal `voxel-authoritative-and-field-minimum` Phase 5.E

姊妹草案：
- 5.A-5.D（已 commit 8b61c60 / e635196 / 25078a7 / 107d125）

真相源：
- `docs/2026-05-07-体素服务器权威化架构进度检查.md` §"目标三缺口 C"
- `apps/scene_server/lib/scene_server/voxel/dirty_macro_bounds.ex`（字段结构已存在，未被消费）
- `apps/scene_server/lib/scene_server/voxel/chunk_process.ex`（pending_fence + Phase 3-bis 持久化路径，可作 boundary fence 参照）
- TheWorldBook/docs/2026-05-13-体素局部场最小目标.md（Phase 6 FieldLayer spec，§5.2 提到 "字段 tick 由 FieldTickSupervisor 独立调度，不走事务路径"）

---

## 1. 目标

实现 Scene 低频规则帧基础设施，为 Phase 5.F 温湿度 simulator + Phase 6 FieldLayer tick 提供调度地基：

1. **SimulationTick GenServer**：per-chunk tick 调度器，按固定频率（v1: 100ms = 10 Hz）触发"规则帧"
2. **dirty cell / dirty bounds 标记**：cell 修改时记录变化范围，simulator 只处理 dirty 区域
3. **cross-chunk boundary 事件**：跨 chunk 状态传播（lease/owner_epoch fence，与 Phase 3-bis pending_fence 对齐）
4. **deterministic hash**：tick 输入 + 输出可重放（集群多节点一致性）
5. **simulator 注册框架**：Phase 5.F 可挂温湿度 simulator，Phase 6 可挂 FieldLayer

**Phase 5.E 不做**（Phase 5.F / 6 工作）：
- 任何 simulator 算法（5.F: temperature/moisture diffusion；6: 电场/温度场 stencil）
- EnvironmentUpdated delta 下发（5.F）
- 跨 region scheduler（A4-bis-cluster 范畴）

---

## 2. 架构

### 2.1 Scheduler 拓扑

> **决策点 E-1**：tick scheduler 拓扑
> - (a) **per-chunk**（推荐）：每个 ChunkProcess 内部持 SimulationTick 状态，自驱动 100ms 定时器；优点：本地化、与 chunk lease 生命周期对齐、随 chunk 启停自然管理；缺点：每个 chunk 都跑 Process.send_after，开销 = chunk_count
> - (b) per-region：单一 RegionSimulationTick GenServer 调度所属 chunks；优点：定时器开销 = region_count；缺点：调度路径多一跳，与 chunk lease 解耦
> - (c) per-scene-node：单一 SceneSimulationTick GenServer 调度本节点全 chunks；优点：定时器单点；缺点：与 chunk lease 高度解耦，scaling 风险

> 推荐 **(a) per-chunk**：与 chunk lease 生命周期天然一致，启停简单。如果未来发现 Process.send_after 开销过大，可演化到 (b)。

### 2.2 tick 频率

> **决策点 E-2**：tick frequency
> - (a) **10 Hz (100ms)**（推荐，与 Phase 6 spec §5.2 一致）
> - (b) 5 Hz (200ms)：保守，减少开销
> - (c) 1 Hz (1000ms)：仅适合温湿度（5.F），不适合 Phase 6 FieldLayer

### 2.3 dirty tracking

`DirtyMacroBounds` 字段（已存在）：

```elixir
defstruct macro_min: nil, macro_max: nil, reason_flags: 0
```

> **决策点 E-3**：dirty marking 粒度
> - (a) **macro cell 粒度**（推荐，与 DirtyMacroBounds 现有字段一致）
> - (b) micro slot 粒度：精确但 dirty mask 内存大（每 chunk 512 bit × 4096 macros = 2MB）
> - (c) chunk 粒度：粗放，simulator 必须扫全 chunk

dirty reason_flags 提议（含义由 Phase 5.E/F 共同定义）：
- `0x01 attribute_write`（put_attribute_for_cell / put_solid_block 触发）
- `0x02 chunk_subscription_change`（订阅状态变化 → 强制 refresh）
- `0x04 cross_chunk_boundary_event_received`（邻 chunk 传播 → 本 chunk 需要重新评估边界）
- `0x08 catalog_changed`（CatalogPatch 后所有 cell effective value 可能变化）
- `0x10..0x80` 预留

### 2.4 cross-chunk boundary 事件

simulator 需要跨 chunk 传播（如温度从 chunk A 蔓延到邻 chunk B）。

> **决策点 E-4**：boundary 事件机制
> - (a) **拉模式**（推荐）：simulator 在 tick 时主动读邻 chunk 的边界 macro cell（通过 ChunkDirectory.lookup_chunk_pid + GenServer.call）—— 缺点：实时性弱（最多 1 tick 滞后），优点：无新 wire 类型 / 无 cascade tick 风险
> - (b) 推模式：cell 变化时主动 cast 到邻 chunk 的 SimulationTick；优点：实时；缺点：cascade tick 风险 + 跨 region 路由复杂
> - (c) 混合：常规读拉模式，特殊事件（catalog 改 / lease 变更）推

### 2.5 lease/owner_epoch fence

Phase 3-bis pending_fence 持久化对齐：tick 开头校验 `lease_token`，不匹配立即跳过本帧 + emit observe。

### 2.6 deterministic hash

> **决策点 E-5**：tick 输出 hash
> - (a) **hash(input_chunk_hash, dirty_bounds, tick_seq, simulator_id)**（推荐，简单可重放）
> - (b) 完整 hash 输出 chunk_hash post-tick
> - (c) 不做 deterministic hash（v1 简化，Phase 5.F 真正发现需要时再加）

推荐 (a) 作为 simulation observe 字段，并不强制 simulator 完全 deterministic（temperature diffusion 算法本身 deterministic 即足够）。

### 2.7 simulator 注册框架

> **决策点 E-6**：simulator 注册方式
> - (a) **配置文件硬编码**（推荐 Phase 5.E）：在 `config/config.exs` 注册 simulators，启动时一次性加载
> - (b) runtime 动态注册：GenServer API `register_simulator(module, opts)`
> - (c) 不注册，硬编码 simulator 列表在 SimulationTick 模块中

推荐 (a) Phase 5.E 简化：

```elixir
# config/config.exs
config :scene_server, :voxel_simulators, [
  # Phase 5.F 接 SceneServer.Voxel.TemperatureDiffusionSimulator
]
```

Phase 5.E 不要求注册任何具体 simulator，框架就绪即可。

---

## 3. Elixir 模块结构

```text
apps/scene_server/lib/scene_server/voxel/
├── simulation_tick.ex          # 在 ChunkProcess 内部状态或独立 GenServer (E-1)
├── simulator.ex                # behaviour: c:simulator_id/0, c:tick(state, dirty_bounds, env) :: state
└── dirty_macro_bounds.ex       # 既有字段结构，加 helpers
```

### 3.1 `SimulationTick`
- per-chunk tick state（在 ChunkProcess state 中嵌入）
- tick_seq: u64 计数
- last_tick_hash: u64

### 3.2 `Simulator` behaviour
```elixir
@callback simulator_id() :: atom()
@callback tick(state :: term(), dirty_bounds :: DirtyMacroBounds.t(), env :: map()) :: 
            {:ok, new_state :: term(), %{cells_updated: u32, env_delta: term()}} | 
            {:error, atom()}
```

`tick/3` 是 simulator 单帧 API，Phase 5.F 实现 TemperatureDiffusionSimulator 即遵循此 behaviour。

### 3.3 `ChunkProcess` 扩展
- 启动时 schedule first tick (E-1 (a))
- handle_info(:simulation_tick, state):
  - 校验 lease_token
  - 校验 dirty_bounds 非空
  - 遍历 registered simulators，对每个调 `tick/3`
  - 应用 new_state（更新 attribute_sets / environment_summaries）
  - 清 dirty_bounds
  - emit observe events
  - schedule next tick

---

## 4. observe events

新增：
- `voxel_simulation_tick_started` (chunk_coord, tick_seq, dirty_size)
- `voxel_simulation_tick_completed` (chunk_coord, tick_seq, cells_updated, duration_us, output_hash)
- `voxel_simulation_tick_skipped` (chunk_coord, reason :: :lease_stale | :no_dirty | :no_simulators)
- `voxel_simulation_simulator_failed` (chunk_coord, simulator_id, reason)
- `voxel_simulation_boundary_read` (chunk_coord, neighbor_coord, simulator_id)

---

## 5. Test plan

新建 `apps/scene_server/test/scene_server/voxel/simulation_tick_test.exs`：

1. **scheduler 启动 / 停止**
   - ChunkProcess 启动 → SimulationTick 内部状态初始化 → first tick 在 100ms 内触发
   - ChunkProcess 终止 → SimulationTick 状态随之清理（无残留定时器）

2. **dirty tracking**
   - `apply_intent` 写入 → dirty_bounds 更新
   - tick 后 dirty_bounds 清空
   - reason_flags 按写入类型正确设置

3. **lease fence**
   - lease 失效 → tick 跳过 + emit `voxel_simulation_tick_skipped` (reason: :lease_stale)
   - lease 匹配 → tick 正常执行

4. **no simulators / no dirty**
   - 无 registered simulator → tick 跳过 (reason: :no_simulators)
   - dirty_bounds 空 → tick 跳过 (reason: :no_dirty)

5. **mock simulator behaviour**
   - 注入 mock simulator → tick 调用 → mock state 改变 → cells_updated 正确

6. **deterministic output_hash**
   - 同 input dirty_bounds + chunk_hash → 同 output_hash

7. **cross-chunk boundary read**（拉模式）
   - mock simulator 读邻 chunk → emit observe + 邻 chunk 数据正确

---

## 6. 实施顺序

依赖：Phase 5.A/B/C/D 已 commit；ChunkProcess 既有。

1. **E-1..E-6 决策**：用户复核
2. 新建 `simulator.ex` behaviour（TDD red）
3. 新建 `simulation_tick.ex` 模块（state struct + helpers）
4. 改 `chunk_process.ex` 接入 simulation tick 路径（init/handle_info）
5. 改 `dirty_macro_bounds.ex` 加 helpers
6. 改 `storage.ex`：`put_attribute_for_cell` / `apply_intent` 路径在 cell 修改时设置 dirty_bounds + reason_flags
7. 跑测试（584 voxel baseline 不回归）
8. 同步文档（README + 主线进度文档）
9. commit `phase5e: scene low-frequency simulation tick + dirty tracking + boundary fence`

---

## 7. 风险

- **Process.send_after 开销 (E-1 (a))**：1 个 chunk 100ms 一次 send_after，假设 1000 chunks 同时 in-memory，每秒 10000 个 send_after。Erlang 默认能扛，但需要 benchmark。如果不行，演化到 (b) per-region。
- **dirty_bounds 不清空 bug**：simulator 必须显式清 dirty_bounds。漏清 → 每 tick 重复处理 → 性能问题但不影响正确性。测试需覆盖 clearing。
- **lease 失效 timing race**：tick 在 send_after 阶段 → 接到 lease 撤销 → tick 触发后才发现。需要 tick handle 第一行就校验 lease。
- **跨 chunk boundary 读 timing**：拉模式（E-4 (a)）邻 chunk 数据 1 tick 滞后。simulator 必须能容忍此滞后（temperature diffusion 一阶差分对此天然容忍）。
- **catalog_changed dirty 信号**：CatalogPatch 后所有 cell effective_value 可能变化。dirty_bounds 设置必须覆盖整 chunk。Phase 5.F 实施时需要决定是否每 catalog change 都触发全 chunk re-simulate（开销大）还是 lazy 评估。
