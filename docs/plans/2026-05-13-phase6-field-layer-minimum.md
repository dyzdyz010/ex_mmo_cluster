# Phase 6: 局部场最小目标（FieldLayer + 电场 + 温度场 + FieldDebugOverlay）— 设计草案

> 2026-05-14 更新：温度层已从本草案的 dense f32 array 调整为"环境基线
> 20°C + 整数异常 delta"的稀疏层。0x73 wire 仍保持 f32 绝对值数组，但只下发
> active/anomaly cell；详见 `apps/scene_server/lib/scene_server/voxel/README.md`
> 的 Phase 6 段和 `docs/2026-04-10-线协议规范.md` 的 0x73 语义。

状态：G-1..G-8 决策已采用推荐方案，进入 TDD 实现阶段
日期：2026-05-13
归属：goal `voxel-authoritative-and-field-minimum` Phase 6

真相源：
- `TheWorldBook/docs/2026-05-13-体素局部场最小目标.md`（Phase 6 spec §2-§7）
- Phase 5.D `Storage.effective_attribute_at/3`（API 已就绪）
- Phase 5.E `Simulator` behaviour + `SimulationTick`（框架参考）
- Phase 5.F `DiffusionSimulator`（stencil 算法参考）
- `apps/scene_server/lib/scene_server/voxel/chunk_process.ex`（subscribe / push_object_state_delta_payload 模式）
- `docs/2026-04-10-线协议规范.md`（0x60..0x7F voxel 段，当前 0x70-0x72 已分配）

---

## 1. 决策摘要（G-1..G-8 全部采用推荐方案）

| 决策 | 选定方案 |
|---|---|
| G-1 FieldTickWorker 拓扑 | per-region GenServer，由 FieldTickSupervisor (DynamicSupervisor) 管理 |
| G-2 FieldLayer 存储 | 密集 f32 binary array (4096 × 4 bytes = 16 KB/field) |
| G-3 快照下发 | FieldTickWorker cast to ChunkProcess.push_field_snapshot_payload/2 |
| G-4 wire opcode | 0x73 FieldRegionSnapshot (S→C)，0x74 FieldRegionDestroyed (S→C) |
| G-5 快照格式 | 全量快照（稀疏：只写非零 cell），每 tick 一次 |
| G-6 电场路径代价 | 1.0 / max(density, 0.001)，density 来自 effective_attribute_at |
| G-7 温度衰减 | β = 0.01 固定，每 tick 向 current_temperature 拉近 |
| G-8 生命周期 | ChunkProcess 持 field_regions map，lease 失效时 GenServer.stop 所有 worker |

---

## 2. 新增模块结构

```text
apps/scene_server/lib/scene_server/voxel/field/
├── field_layer.ex          # 密集 f32 binary array per field type
├── field_region.ex         # FieldRegion struct（AABB + layers + tick_count + source_points）
├── field_tick_worker.ex    # per-region GenServer（持 region 状态 + 调度 tick）
├── field_tick_supervisor.ex # DynamicSupervisor，管理 FieldTickWorker 进程池
├── field_codec.ex          # opcode 0x73 / 0x74 encode/decode
├── electric_field.ex       # BFS 电场 tick（density 路径代价 + ionization）
└── temperature_field.ex    # 7-stencil 温度场 tick（thermal_conductivity 调制 + 衰减）
```

**修改已有文件：**

```
apps/scene_server/lib/scene_server/voxel/chunk_process.ex
  + field_regions: %{region_id => worker_pid}（init state）
  + create_field_region/2（GenServer.call，启动 FieldTickWorker）
  + destroy_field_region/2（GenServer.call，停止 worker）
  + push_field_snapshot_payload/2（GenServer.cast，扇出 0x73 payload）
  + push_field_region_destroyed_payload/2（GenServer.cast，扇出 0x74 payload）
  + lease 失效路径：对每个 worker_pid GenServer.stop
  + handle_info({:DOWN, ...}) for worker monitors

apps/scene_server/lib/scene_server/application.ex
  + FieldTickSupervisor 加入 VoxelSup children

apps/gate_server/lib/gate_server/tcp_connection.ex
  + {:voxel_field_region_snapshot_payload, payload} → send_frame
  + {:voxel_field_region_destroyed_payload, payload} → send_frame

docs/2026-04-10-线协议规范.md
  + 0x73 FieldRegionSnapshot payload 定义
  + 0x74 FieldRegionDestroyed payload 定义
```

---

## 3. FieldLayer（密集 f32 array）

```elixir
defstruct data: <<>>  # 4096 × 4 bytes，索引 = macro_index

# API:
# new() → %FieldLayer{data: <<0::float-32-little>> × 4096}
# get(layer, macro_index) → float
# put(layer, macro_index, value) → %FieldLayer{}
# to_list(layer, aabb) → [{macro_index, value}]，只含 AABB 内非零值
```

---

## 4. FieldRegion

```elixir
defstruct [
  :region_id,      # u64，唯一标识
  :chunk_coord,    # {cx, cy, cz}
  :aabb,           # {min_coord, max_coord}，两端均包含，macro coord 粒度
  :field_types,    # [:temperature | :electric | :ionization]（subset）
  :source_points,  # [%{macro_index: u16, field_type: atom, value: float}]
  tick_count: 0,
  max_ticks: nil,  # nil = 无限
  :lease_token,    # 来自 ChunkProcess lease
  layers: %{}      # %{field_type_atom => %FieldLayer{}}
]
```

---

## 5. FieldTickWorker

```elixir
use GenServer

# state: %{region: FieldRegion.t(), chunk_pid: pid(), storage_fn: fn -> Storage.t(), interval_ms: 100}

# init/1: Process.monitor(chunk_pid); schedule_tick()
# handle_info(:tick):
#   1. storage = storage_fn.()（ChunkProcess 提供 fn）
#   2. 对每个 field_type 运行对应算法
#   3. encode FieldRegionSnapshot payload (0x73)
#   4. ChunkProcess.push_field_snapshot_payload(chunk_pid, payload)  [cast]
#   5. emit voxel_field_tick_completed
#   6. tick_count + 1；达到 max_ticks → stop :normal + push destroyed payload
#   7. schedule next tick
# handle_info({:DOWN, ref, :process, chunk_pid, _reason}):
#   → stop :normal（chunk 死亡 = region 自动失效）
```

---

## 6. 电场算法（BFS + density 路径代价）

```
输入：source_points（势源点 + 初始电位），AABB 内所有 cell
算法：
  1. 初始化 electric_potential 全 0.0
  2. 势源点入 Erlang :gb_sets 最小堆（按 cost 排序）
  3. BFS：每次取 cost 最小的 cell
     a. 读 density = effective_attribute_at(storage, macro_index, "density")
     b. step_cost = 1.0 / max(density / 65536.0, 0.001)（Q16.16 → float）
     c. neighbor_potential = current_potential - step_cost × decay_factor
     d. 若 neighbor_potential > 0 && > 已有值 → 更新，入堆
  4. ionization：|electric_potential| > threshold(=50.0) 的 cell，每 tick ionization += 5（u8 cap 255）
  5. 所有 cell 每 tick ionization 衰减 1（最小 0）
  6. 返回更新后的 layers
```

---

## 7. 温度场算法（7-stencil + thermal_conductivity 调制）

```
输入：source_points（热源点），AABB 内所有 cell，storage（读 thermal_conductivity）
算法：
  1. 为每个 AABB cell 计算新温度
     a. 读 6 邻居 temperature（AABB 边界外的 cell 视为 source_points 初始值或 env_temp）
     b. tc = effective_attribute_at(storage, macro_index, "thermal_conductivity")（Q16.16）
     c. α = base_alpha × (tc / 65536.0) / 0.5（归一到 thermal_conductivity default=0.1 为 base_alpha）
     d. T' = T + α × (neighbor_avg - T)
     e. env_temp（float，来自 MacroEnvironmentSummary 或默认 20.0）
     f. T' = T' + 0.01 × (env_temp - T')（衰减向环境温度）
  2. source_points 每 tick 强制重置（热源不扩散）
  3. 返回更新后的 layers
```

---

## 8. Wire 格式

### 0x73 FieldRegionSnapshot

```
opcode: u8 = 0x73
logical_scene_id: u64
cx: i32, cy: i32, cz: i32
region_id: u64
tick_count: u32
field_mask: u8          # 0x01=temperature 0x02=electric_potential 0x04=ionization
cell_count: u16         # 非零 cell 数量（≤ 4096）
macro_indices: u16[cell_count]
temperature: f32[cell_count]        # 仅 field_mask & 0x01
electric_potential: f32[cell_count] # 仅 field_mask & 0x02
ionization: u8[cell_count]          # 仅 field_mask & 0x04
```

### 0x74 FieldRegionDestroyed

```
opcode: u8 = 0x74
logical_scene_id: u64
cx: i32, cy: i32, cz: i32
region_id: u64
destroy_reason: u8      # 0x00=expired 0x01=lease_revoked 0x02=explicit_destroy 0x03=chunk_crash
```

---

## 9. observe events（6 个）

- `voxel_field_region_created`（region_id, chunk_coord, field_types, aabb）
- `voxel_field_region_destroyed`（region_id, chunk_coord, destroy_reason）
- `voxel_field_tick_completed`（field_id=region_id, tick_count, cells_updated, tick_duration_us）
- `voxel_field_snapshot_dispatched`（region_id, chunk_coord, cell_count）
- `voxel_field_snapshot_push`（region_id, subscriber_pid）
- `voxel_field_tick_failed`（region_id, reason）

---

## 10. 测试计划

新建 `apps/scene_server/test/scene_server/voxel/field/`：

1. `field_layer_test.exs`：new/get/put；binary 格式；边界（0 / 4095 / out）
2. `field_region_test.exs`：创建；AABB 内 cell 枚举；source_points 应用
3. `electric_field_test.exs`：BFS 传播；势源→邻 cell 得到非零 potential；远离 cell 衰减；ionization 阈值
4. `temperature_field_test.exs`：热源→扩散；thermal_conductivity 调制（高 tc cell 扩散快）；衰减向 env_temp；source_points 重置
5. `field_codec_test.exs`：encode/decode roundtrip 0x73 / 0x74；golden byte；field_mask 组合
6. `field_tick_worker_test.exs`：tick 调度；lease 失效（chunk 死亡）→ worker 终止；max_ticks 到期；observe events
7. `field_integration_test.exs`（spec §7.1）：
   - 创建空 chunk + lease
   - 创建 FieldRegion（8×8×8=512 cells）
   - 注入热源点
   - 跑 10 步 tick
   - 断言热源附近 temperature > env_temp + δ
   - lease 撤销 → region 销毁
   - observe 事件顺序

---

## 11. 实施顺序

依赖：Phase 1-5 全 done（620 voxel tests baseline）。

1. 写 Phase 6 设计草案（本文件）✓
2. TDD：新建全部测试（red）
3. 实现 field_layer.ex + field_region.ex
4. 实现 electric_field.ex + temperature_field.ex
5. 实现 field_tick_worker.ex + field_tick_supervisor.ex
6. 实现 field_codec.ex
7. 改 chunk_process.ex
8. 改 application.ex（加 FieldTickSupervisor）
9. 改 gate_server tcp_connection.ex
10. 协议规范文档更新 0x73/0x74
11. 跑测试（620 baseline 不回归）
12. web_client FieldDebugOverlay（fieldProtocol.ts + fieldDebugOverlay.ts）
13. commit: `phase6: FieldLayer + FieldRegion + electric/temperature field tick + FieldDebugOverlay (opcode 0x73/0x74)`

---

## 12. 风险

- **BFS 性能**：AABB 4096 cells × BFS depth = 可接受（每 tick ≤ 10ms 目标）；若超预算削 region 体积
- **二进制 binary mutation 开销**：FieldLayer.put 每次重构整个 16KB binary。v1 接受（tick 10Hz，少量 cells）；v2 可改用 :array 或 ETS
- **ChunkProcess push 竞态**：FieldTickWorker tick 完成时 chunk 可能已终止；cast 本身是 fire-and-forget，chunk 进程死亡时 cast 静默失败（Erlang 保证），安全
- **lease token 校验**：G-8 决定由 FieldTickWorker monitor ChunkProcess pid，chunk 死亡时 worker 自动退出；lease token 值不做二次校验（simplification v1）
- **0x73/0x74 wire 冻结**：一旦实现即冻结格式，后续只能追加字段
