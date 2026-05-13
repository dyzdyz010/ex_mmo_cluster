# Phase 5.F: 温湿度 simulator + EnvironmentUpdated delta — 设计草案

状态：设计稿，等用户复核 F-1..F-7 决策点
日期：2026-05-13
归属：goal `voxel-authoritative-and-field-minimum` Phase 5.F（Phase 5 最后一站）

姊妹草案：5.A-5.E（全 done）

真相源：
- goal §Phase 5 §5.1 / §5.2 验收
- `apps/scene_server/lib/scene_server/voxel/macro_environment_summary.ex`（已建模 current_temperature / current_moisture）
- `apps/scene_server/lib/scene_server/voxel/simulator.ex`（Phase 5.E behaviour）
- `apps/scene_server/lib/scene_server/voxel/simulation_tick.ex`（Phase 5.E per-chunk tick）
- `docs/2026-04-10-线协议规范.md`（ChunkDelta opcode 0x63 + delta_kind 0/1/2 已分配）

---

## 1. 目标

Phase 5.F 是 Phase 5 最后一站，完成"能读 + 能算 + 能下发"闭环：

1. **temperature diffusion simulator**：标准 3D 7-stencil 扩散算法（Phase 6 spec §6.2 与本目标语义对齐）
2. **moisture diffusion simulator**：与 temperature 同算法（可共享 simulator 框架）
3. **MacroEnvironmentSummary 写入**：simulator tick 后写 `current_temperature` / `current_moisture`
4. **EnvironmentUpdated delta wire**：服务端 → 客户端推送 environment 变化（新 wire 类型）
5. **客户端 stub 消费**：web_client 收到 EnvironmentUpdated 后更新内存（不强制渲染，Phase 6 magic kernel UI 接入时再做）

**Phase 5.F 不做**（Phase 6 / 后续）：
- Phase 6 FieldLayer（瞬时高频局部场）
- temperature / moisture 触发的化学反应（燃烧 / 凝结）
- 客户端 UI 实时渲染（debug overlay 推到 Phase 6）

---

## 2. simulator 算法

### 2.1 temperature diffusion

3D 7-stencil 扩散（goal §Phase 6 §6.2 推荐，Phase 5 沿用）：

```
∂T/∂t = α × ∇²T

discretized:
T'(x,y,z) = T(x,y,z) + α × Δt × (
  T(x-1,y,z) + T(x+1,y,z) +
  T(x,y-1,z) + T(x,y+1,z) +
  T(x,y,z-1) + T(x,y,z+1) -
  6 × T(x,y,z)
)
```

`α` (thermal_conductivity) 从 catalog 取 default value（或从 cell effective_attribute 取）。

> **决策点 F-1**：simulator 粒度
> - (a) **macro 粒度**（推荐）：每个 macro cell 一个 temperature 值，stencil 在 macro 间扩散。16³=4096 cells/chunk
> - (b) micro 粒度：每个 micro slot 一个 temperature。扩散 micro 间 + macro 间。计算量 = 64×macro = 262144 cells/chunk × 7-stencil = 1.8M ops/tick/chunk
> - (c) 混合：macro 粒度跑大尺度扩散，micro 粒度仅 hot spot
>
> 推荐 (a)：macro 粒度，与 Phase 5.D `effective_attribute_at` macro 粒度对齐，性能预算可控（4096 × 7 × 10Hz = 287K ops/s/chunk，集群 1000 chunks = 287M ops/s 可接受）

### 2.2 moisture diffusion

与 temperature 同算法，独立 simulator。

> **决策点 F-2**：是否共享 simulator 模块
> - (a) **共享 `DiffusionSimulator` 模块**（推荐），通过 attribute name + α factor 参数化
> - (b) 独立 `TemperatureDiffusionSimulator` / `MoistureDiffusionSimulator` 模块

推荐 (a)：DRY，未来加更多 diffusion attribute 时零成本。

### 2.3 边界条件

> **决策点 F-3**：chunk 边界处理
> - (a) **拉模式邻 chunk 边界**（推荐，与 Phase 5.E E-4 一致）：tick 时通过 `neighbor_lookup_fn` 读邻 chunk 边界 macro 温度
> - (b) Neumann（绝热）边界：邻 chunk 视为同温（无扩散）
> - (c) Dirichlet（固定）边界：邻 chunk 视为 default 温度

推荐 (a) + (b) fallback：邻 chunk 不可读（lease 不可达）时退化为 (b) 绝热。

### 2.4 dt / α 参数

> **决策点 F-4**：固定参数 vs 可配置
> - (a) **固定（推荐）**：v1 dt=0.1s（与 tick 100ms 一致），α 从 catalog thermal_conductivity 取
> - (b) Application.get_env 配置：未来可调

推荐 (a)：减少配置复杂度。

---

## 3. EnvironmentUpdated delta wire

### 3.1 wire 通道选择

> **决策点 F-5**：delta wire 通道
> - (a) **新增独立 opcode `0x72 EnvironmentUpdated`**（推荐，与 ChunkDelta 解耦，environment 是 macro-level 而非 cell-level）—— 类似 Phase 1.4 CatalogPatch 用独立 opcode
> - (b) 扩展 `ChunkDelta` op `delta_kind=3 EnvironmentUpdated`（与 cell-level ops 同流）
> - (c) 复用现有 ChunkSnapshot 推送（每次环境变化推全量快照）—— 不推荐，浪费带宽

推荐 (a)：独立 opcode + per-chunk 推送，与 ChunkDelta 并行通道。

### 3.2 wire layout (opcode 0x72，一旦发出即冻结)

```
EnvironmentUpdated (opcode 0x72)
  logical_scene_id: u64
  chunk_coord: i32 cx, i32 cy, i32 cz
  base_chunk_version: u64
  new_chunk_version: u64
  update_count: u16
  updates[update_count] {
    macro_index: u16            // 0..4095
    field_mask: u8              // 0x01 temperature / 0x02 moisture / 其他预留
    temperature: i16            // 仅 field_mask 含 0x01 时存在
    moisture: i16               // 仅 field_mask 含 0x02 时存在
    source_hash: u32            // 输入 hash for replay
  }
```

> **决策点 F-6**：是否每 update 都带 source_hash
> - (a) **是，每 update 带 hash**（推荐，便于客户端去重/回放校验）
> - (b) 整个 EnvironmentUpdated 一个 hash（紧凑）
> - (c) 不带 hash

推荐 (a)，与 ChunkDelta 现有 op_level cell_hash 模式一致。

### 3.3 简化：本 commit 是否实现客户端 decoder?

> **决策点 F-7**：客户端实现范围
> - (a) **服务端 wire 编码 + Elixir test roundtrip 即可**（推荐，Phase 5.F 不动 web_client）
> - (b) 同时实现 web_client TS decoder（仿 Phase 1.6b 同款 fixtures + roundtrip）
> - (c) 服务端 + bevy_client decoder

推荐 (a)：保持 Phase 5.F 范围最小，web_client decoder 推到 Phase 5.F.client（或 Phase 6 magic kernel 真正消费 environment 数据时再做）。

---

## 4. Elixir 模块结构

```text
apps/scene_server/lib/scene_server/voxel/
├── diffusion_simulator.ex      # Simulator behaviour 实现，参数化 attribute + α
├── environment_updated.ex      # delta wire encode/decode
└── macro_environment_summary.ex  # 既有，加 write helpers if needed
```

### 4.1 DiffusionSimulator

```elixir
defmodule SceneServer.Voxel.DiffusionSimulator do
  @behaviour SceneServer.Voxel.Simulator
  
  defstruct attribute_name: "temperature", alpha_factor: 0.1, dt_seconds: 0.1
  
  # simulator_id/0 → :temperature_diffusion / :moisture_diffusion (按 attribute_name)
  # tick/3 →
  #   for each dirty macro:
  #     read effective temperature (Phase 5.D effective_attribute_at)
  #     read 6 邻居 macro 的 temperature (via neighbor_lookup or storage neighbor index)
  #     compute new_temperature (stencil)
  #     write to MacroEnvironmentSummary.current_temperature
  #     accumulate EnvironmentUpdated op
  #   return {:ok, new_state, %{cells_updated, env_delta: %{ops: [...]}}}
end
```

### 4.2 EnvironmentUpdated codec

新增 `codec.ex` 函数（或独立 `environment_updated.ex` 模块）：
- `encode_environment_updated_payload/1`
- `decode_environment_updated_payload!/1`

### 4.3 ChunkProcess fanout

ChunkProcess.handle_info(:simulation_tick) 在收到 simulator 返回的 env_delta 后，调用 `Codec.encode_environment_updated_payload` + push 到 subscribers（同 `push_chunk_delta_payload` 模式）。

---

## 5. config 注册 simulators

`config/config.exs`：

```elixir
config :scene_server, :voxel_simulators, [
  {SceneServer.Voxel.DiffusionSimulator, attribute_name: "temperature", alpha_factor: 0.05},
  {SceneServer.Voxel.DiffusionSimulator, attribute_name: "moisture", alpha_factor: 0.02}
]
```

---

## 6. Test plan

新建 `apps/scene_server/test/scene_server/voxel/diffusion_simulator_test.exs`：

1. **单 macro 热源** + **6 邻居**全 default temperature → 1 tick 后中心温度下降，邻居温度上升
2. **稳态**：所有 cell 同温 → tick 后温度不变（无 net 扩散）
3. **绝热边界**：邻 chunk 不可达 → 边界 macro 仅与同 chunk 内邻居扩散
4. **deterministic**：同 input → 同 output
5. **EnvironmentUpdated emit**：tick 后 env_delta 含 update ops，按 ChunkProcess 推送给 subscriber

新建 `apps/scene_server/test/scene_server/voxel/environment_updated_codec_test.exs`：
1. encode/decode roundtrip（空 updates / 1 update / 多 updates / 不同 field_mask 组合）
2. 字节级 golden（pin 一段 hex）
3. forward-compat field_mask 未知 bit 处理（保留数值或拒绝）

---

## 7. 实施顺序

依赖：5.A-5.E 已 commit。

1. **F-1..F-7 决策**：用户复核
2. 新建 `diffusion_simulator.ex` + 测试（TDD red）
3. 新建 `environment_updated.ex` codec + 测试
4. 改 `chunk_process.ex` 接 env_delta fanout
5. 改 `macro_environment_summary.ex` 加 write helpers（如需）
6. 改 `config/config.exs` 注册 2 个 simulator instance
7. 改 `dirty_macro_bounds.ex` 增加 reason_flag for environment / catalog change
8. 改 `codec.ex` 加 EnvironmentUpdated payload encode/decode
9. 改 `docs/2026-04-10-线协议规范.md` 追加 0x72 EnvironmentUpdated payload 定义（voxel 扩展段 0x70..0x7F 已含 0x71 CatalogPatch）
10. 跑测试（603 voxel baseline 不回归）
11. 同步 README + 主线进度文档（Phase 5 全收口 + §"目标三" 全部标已实现）
12. commit `phase5f: temperature/moisture diffusion simulator + EnvironmentUpdated delta (opcode 0x72)`

---

## 8. 风险

- **stencil 算法稳定性**：α × dt × 6 < 1 (Courant 条件)，否则 numerical instability。v1 α=0.05/0.02 × dt=0.1 × 6 = 0.03/0.012 远小于 1，稳定。
- **dirty_bounds 累积**：simulator 每 tick 都会"消费"dirty 但也可能生成新 dirty（cell 写温度→邻 chunk 边界 dirty）。需测试避免 infinite tick loop（dirty 永不清空）。简化：simulator 写 environment_summary 不增加 dirty_bounds（environment 是计算结果不是 source）；source 必须由外部 attribute_write 触发。
- **EnvironmentUpdated wire 一旦发出即冻结**：F-5 / F-6 决策必须用户复核。
- **per-chunk simulator state**：DiffusionSimulator 是无状态的（参数全在 simulator def 中），但 SimulationTick state 会持 simulator_states map。本 commit 测试 simulator_states 在 tick 间正确传递（默认 nil 即可，DiffusionSimulator 不需要持久状态）。
- **subscriber fanout**：ChunkProcess push EnvironmentUpdated 给所有 subscribers，与现有 push_chunk_delta_payload 模式一致。失败时 catch + observe，不阻塞 tick。
