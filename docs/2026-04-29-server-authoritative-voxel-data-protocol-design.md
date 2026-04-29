# 服务端权威体素世界第一版规范 (2026-04-29)

## 1. 目标

第一版体素世界按 MMO 建设类玩法设计：玩家不能像沙盒游戏一样任意改写方块布局；玩家先获得地块或施工权限，再以排他事务放置 prefab / blueprint。体素数据本身是世界规则真相，由服务器先计算，客户端只消费权威结果并驱动表现。

核心目标：

1. `SceneServer.Voxel.*` 持有场景内 chunk、地块、建筑对象、状态和破坏结果的权威真相。
2. `WorldServer` 负责 scene 目录、scene 生命周期、跨 scene 迁移和全局目录协调。
3. `GateServer` 负责连接状态、鉴权状态、opcode 路由和 frame 封装，不持有体素真相。
4. `DataService` 负责 chunk snapshot、对象、地块、blueprint、属性和 tag 的持久化，不参与热路径裁决。
5. 客户端负责渲染、选址预览、玩家动作/技能表现预演、CLI/observe 诊断；客户端不预测体素数据真相。

## 2. 同步原则

第一版采用两条同步通道：

```text
Actor lane
  player movement, aiming, cast windup, animation, skill particles, audio
  -> client may predict or preplay for responsiveness
  -> server later confirms/corrects authoritative actor state

Voxel lane
  chunk occupancy, temperature, moisture, burning, freezing,
  structure integrity, object/part state, terrain destruction
  -> server computes first
  -> client updates data only from authoritative snapshot/delta/result
  -> effects are driven by authoritative voxel data
```

这条边界是硬规则：**玩家相关表现可以本地先动，体素相关数据必须服务器权威先行。**

### 2.1 允许本地先发生的内容

| 内容 | 本地行为 | 服务器关系 |
| --- | --- | --- |
| 移动输入 | 本地预测、ack 后纠偏 | movement authority 校正 |
| 镜头、准星、选区 | 本地即时更新 | 不进入世界真相 |
| 施法前摇 / 技能粒子 / 音效 | 本地预演 | 服务器确认命中、资源、冷却和结果 |
| prefab 选址线框 | 本地预览 | 服务器做权限、地块、占用和资源裁决 |
| 施工 UI / 等待状态 | 本地显示 intent in-flight | 服务器返回结果后转状态 |

### 2.2 必须等待服务器的内容

| 内容 | 权威来源 | 客户端行为 |
| --- | --- | --- |
| chunk occupancy | `ChunkSnapshot / ChunkDelta` | 更新 confirmed voxel store |
| prefab/object 落地 | `ObjectStateDelta / ChunkDelta / VoxelIntentResult` | 创建或更新对象表现 |
| 温度、湿度、燃烧、冻结 | `ChunkDelta / ObjectStateDelta` | 进入体素效果管线 |
| 结构完整度、裂解、倒塌 | `ObjectStateDelta / ChunkDelta` | 更新 mesh/collision/effects |
| 爆炸或魔法导致的地形消失 | `ChunkDelta` | 更新 geometry 后播放数据驱动后效 |
| 掉落、资源、伤害、冷却 | skill/combat authoritative result | 更新 UI/数值 |

客户端可以在技能发出时播放火球、爆炸光、冲击波；但木头是否点燃、石头是否破裂、哪些 micro 被移除，只能等服务器根据 `temperature / moisture / material / tag / attribute / structure_integrity` 计算后下发。

## 3. 运行时边界

```text
WorldServer
  scene directory
  scene lifecycle
  cross-scene transfer
  global blueprint/catalog coordination

SceneServer.Voxel
  parcel/claim authority
  chunk truth
  build transaction arbitration
  object/part state
  voxel rule simulation
  destruction and terrain impact results
  voxel AOI and chunk subscriptions

GateServer
  auth/session state
  in-scene route checks
  websocket/tcp frame handling
  opcode dispatch

DataService
  chunk snapshots
  object records
  parcel records
  blueprint records
  attribute/tag catalogs
  journals/audit

Client
  actor prediction and presentation
  build preview
  confirmed voxel rendering
  data-driven voxel effects
  CLI/observe diagnostics
```

## 4. 空间与量化

### 4.1 固定参数

| 名称 | 类型 | v1 值 | 说明 |
| --- | --- | --- | --- |
| `chunk_size_in_macro` | `u8` | `16` | 每 chunk `16 x 16 x 16 = 4096` macro |
| `micro_resolution` | `u8` | `8` | 每 macro `8 x 8 x 8 = 512` micro |
| `macro_index` | `u16` | `0..4095` | `x + y * 16 + z * 16 * 16` |
| `micro_index` | `u16` | `0..511` | `x + y * 8 + z * 8 * 8` |
| `cell_version` | `u32` | monotonic | macro 级版本，用于拒绝过期 intent |
| `chunk_version` | `u64` | monotonic | chunk snapshot/delta 顺序 |

`micro_resolution` 必须出现在 chunk snapshot、blueprint definition 和相关 fixture 中。第一版只允许权威 scene 使用 `8`，避免同一 scene 内混跑多个精度。

### 4.2 坐标

```text
SceneId          u64
ParcelId         u64
ChunkCoord       i32 cx, i32 cy, i32 cz
LocalMacroCoord  u8  mx, u8  my, u8  mz
LocalMicroCoord  u8  ux, u8  uy, u8  uz
WorldMacroCoord  i64 x,  i64 y,  i64 z
WorldMicroCoord  i64 x,  i64 y,  i64 z
```

负坐标使用 floor division / Euclidean remainder。不同语言实现必须通过 golden fixture 对齐。

## 5. Chunk 真相结构

### 5.1 CellMode

```text
enum CellMode : u8 {
  Empty      = 0,
  SolidBlock = 1,
  Refined    = 2
}
```

### 5.2 MacroCellHeader

每个 chunk 固定 4096 个 header，重负载放池中。

```text
MacroCellHeader {
  mode              u8
  flags             u16
  payload_index     u32   // normal_blocks or refined_cells; 0xFFFF_FFFF = none
  environment_index u32   // environment_summaries; 0xFFFF_FFFF = none
  cell_version      u32
  cell_hash         u32
}
```

`flags` 位义：

| bit | 名称 | 含义 |
| --- | --- | --- |
| `0x0001` | `DirtyStorage` | 需要落盘 |
| `0x0002` | `DirtyMesh` | 需要 mesh/collision rebuild |
| `0x0004` | `DirtyRules` | 需要规则 tick |
| `0x0008` | `BoundaryTouched` | 影响邻 chunk 边界 |
| `0x0010` | `HasObjectProvenance` | cell/micro 可回溯到 object/part |
| `0x0020` | `HasAttributeOverride` | 存在属性覆盖 |
| `0x0040` | `HasTagOverride` | 存在 tag 覆盖 |

### 5.3 NormalBlockData

普通块占满一个 macro。固定头只保存高频真相；扩展属性和魔法标签走 interned pool。

```text
NormalBlockData {
  material_id       u16
  state_flags       u32
  health            u16
  temperature_delta i16
  moisture_delta    i16
  attribute_set_ref u32   // 0 = material/default
  tag_set_ref       u32   // 0 = material/default
}
```

固定线格式为 20 bytes。`attribute_set_ref` 和 `tag_set_ref` 是后续自身属性、魔法标签、特殊材质响应的稳定扩展点。

### 5.4 RefinedCellData

refined cell 表示一个 macro 内 512 个 micro slot。wire v1 使用“层 + mask”压缩。

```text
RefinedCellData {
  occupancy_words   u64[8]
  layers            MicroLayer[]
  object_refs       ObjectCoverRef[]
  boundary_cache    u64
  local_version     u32
}

MicroLayer {
  mask_words        u64[8]
  material_id       u16
  state_flags       u32
  health            u16
  attribute_set_ref u32
  tag_set_ref       u32
  owner_object_id   u64  // 0 = terrain/no object
  owner_part_id     u32  // 0 = no part
}

ObjectCoverRef {
  owner_object_id   u64
  owner_part_id     u32
  mask_words        u64[8]
}
```

规则：

1. `occupancy_words` 是所有 `layers.mask_words` 的 OR。
2. 同一个 micro slot 在同一个 cell 内只能归属一个有效 layer。
3. prefab / assembly 写入 chunk truth 时必须保留 `owner_object_id / owner_part_id`。
4. 多个 micro slot 共享同一材料、状态、属性、tag 和 owner 时应合并成一个 layer。

### 5.5 MacroEnvironmentSummary

```text
MacroEnvironmentSummary {
  default_temperature i16
  default_moisture    i16
  current_temperature i16
  current_moisture    i16
  field_mask          u16
  source_hash         u32
}
```

体素效果管线读取权威环境/状态数据：温度足够高才进入点燃态，湿度/材质/标签会影响燃烧或冻结结果。

### 5.6 ChunkStorage

```text
ChunkStorage {
  schema_version        u16
  scene_id              u64
  chunk_coord           ChunkCoord
  chunk_size_in_macro   u8
  micro_resolution      u8
  chunk_version         u64
  flags                 u32
  macro_headers         MacroCellHeader[4096]
  normal_blocks         NormalBlockData[]
  refined_cells         RefinedCellData[]
  environment_summaries MacroEnvironmentSummary[]
  object_refs           ChunkObjectRef[]
  attribute_sets        VoxelAttributeSet[]
  tag_sets              VoxelTagSet[]
  dirty_bounds          DirtyMacroBounds
}
```

Snapshot 可以内联本次用到的 attribute/tag set，避免客户端收到 cell 后缺少解释数据。

## 6. 属性与标签

### 6.1 VoxelAttributeSet

属性集合是 interned、版本化、可复用的数据。它表达方块自身属性、object 覆盖、魔法响应参数和结构参数。

```text
VoxelAttributeSet {
  attribute_set_id  u32
  schema_version    u16
  base_material_id  u16
  scalar_count      u16
  scalar_entries    AttributeScalar[]
  resource_count    u16
  resource_entries  AttributeResource[]
  resistance_mask   u64
}

AttributeScalar {
  attribute_id      u16
  value_q16         i32
}

AttributeResource {
  resource_id       u16
  current_q16       i32
  max_q16           i32
}
```

首批 `attribute_id`：

| id | 名称 | 用途 |
| --- | --- | --- |
| `1` | `max_health` | 耐久上限 |
| `2` | `hardness` | 破坏速度/工具需求 |
| `3` | `mass` | 结构/坠落/物理 |
| `4` | `thermal_conductivity` | 热传播 |
| `5` | `moisture_capacity` | 湿度响应 |
| `6` | `flammability` | 点燃概率/燃烧规则 |
| `7` | `magic_conductivity` | 魔法能量传播 |
| `8` | `mana_capacity` | 可储魔容量 |
| `9` | `element_affinity` | 元素倾向 bitset/枚举 |
| `10` | `structural_support` | 支撑/承重规则 |
| `11` | `structure_integrity` | 当前结构完整度 |

新增属性时扩展 catalog，不改 `NormalBlockData` 和 `MicroLayer` 固定头。

### 6.2 VoxelTagSet

魔法标签和玩法标签必须 intern，不能在 chunk 内重复写字符串。

```text
VoxelTagSet {
  tag_set_id        u32
  schema_version    u16
  tag_count         u16
  tag_ids           u32[tag_count]
}

VoxelTagCatalogEntry {
  tag_id            u32
  namespace_id      u16
  name              string
  flags             u32
}
```

示例 tag：

```text
magic.fire_conductive
magic.ice_resonant
magic.mana_storage
terrain.natural
structure.player_built
prefab.stairs
part.step_mid
```

建造合法性第一版由地块权限、排他占用、几何占用、资源和规则决定；tag 用于玩法语义、技能响应、过滤、UI、审计和配方。

## 7. 地块与建设模型

MMO 建设不直接暴露任意 `set block`。玩家先拥有或获得地块授权，再提交建设 intent。

```text
ParcelClaim {
  parcel_id           u64
  scene_id            u64
  owner_account_id    u64
  bounds_chunk_min    ChunkCoord
  bounds_chunk_max    ChunkCoord
  permission_mask     u64
  build_epoch         u64
  version             u64
}

BuildReservation {
  reservation_id      u64
  parcel_id           u64
  actor_id            u64
  bounds_world_micro  AabbI64
  expires_at_ms       u64
  intent_hash         u64
}
```

放置 prefab/object 的服务器流程：

1. 校验连接已进入 scene，actor 有 parcel 权限。
2. 校验 blueprint 可用、版本匹配、资源/冷却/建设队列满足。
3. 根据 `anchor_world_micro + rotation` 计算 covered chunks 和 micro occupancy。
4. 校验排他占用、碰撞、地块边界、构造规则。
5. 生成 `object_id`，写入 `SceneObjectInstance`，拍扁占用到 chunk truth 并保留 provenance。
6. 广播 `ObjectStateDelta / ChunkDelta / VoxelIntentResult`。

客户端在第 1 步前可以显示选址线框，但不能把对象写入 confirmed voxel store。

## 8. Blueprint / Object / Provenance

```text
BlueprintDefinition
  reusable template: occupancy, parts, sockets, material channels, default attributes, default tags.

SceneObjectInstance
  one placed object/assembly: object_id, blueprint_id, anchor, rotation, owner, state, version.

ChunkTruth
  flattened occupancy used for authority, collision, meshing, rules, and persistence.
  It retains owner_object_id + owner_part_id per micro layer.
```

### 8.1 BlueprintDefinition

```text
BlueprintDefinition {
  blueprint_id          u64
  version               u32
  source_kind           u8
  owner_account_id      u64
  bounds_macro          u16 x, u16 y, u16 z
  micro_resolution      u8
  allowed_rotations     u16
  default_tag_set_ref   u32
  part_definitions      PartDefinition[]
  occupancy_layers      BlueprintLayer[]
  sockets               BlueprintSocket[]
  boundary_signature    u64[]
}

PartDefinition {
  part_id               u32
  parent_part_id        u32
  name                  string
  default_attribute_ref u32
  default_tag_set_ref   u32
  flags                 u32
}

BlueprintLayer {
  part_id               u32
  local_macro_offset    i16 x, i16 y, i16 z
  mask_words            u64[8]
  material_channel      u16
  default_state_flags   u32
  default_attribute_ref u32
  default_tag_set_ref   u32
}

BlueprintSocket {
  socket_id             u32
  part_id               u32
  local_micro_coord     i32 x, i32 y, i32 z
  normal                i8 x, i8 y, i8 z
  compatible_tag_ref    u32
  priority              u16
}
```

### 8.2 SceneObjectInstance

```text
SceneObjectInstance {
  object_id             u64
  blueprint_id          u64
  blueprint_version     u32
  scene_id              u64
  parcel_id             u64
  anchor_world_micro    i64 x, i64 y, i64 z
  rotation              u8
  owner_actor_id        u64
  state_flags           u32
  object_attribute_ref  u32
  object_tag_set_ref    u32
  covered_chunk_count   u16
  covered_chunks        ChunkCoord[]
  version               u64
}
```

后续门、机关、魔法阵、玩家建筑都挂在 object/part 语义上，而不是降级成匿名材料格。

## 9. 状态与破坏模型

体素状态变化由服务器规则系统计算。客户端只播放 actor 侧技能表现，等待服务器下发世界结果。

```text
SkillCast / CombatEvent
  -> server validates actor resource, cooldown, hit, area
  -> SceneServer.Voxel computes heat/moisture/impact/structure changes
  -> server emits VoxelStateDelta / ObjectStateDelta / ChunkDelta
  -> client updates confirmed voxel data
  -> renderer/effect system derives burning/freezing/crack/destruction visuals
```

建议事件：

```text
VoxelStateDelta {
  scene_id            u64
  chunk_coord         ChunkCoord
  chunk_version       u64
  macro_index         u16
  state_flags         u32
  environment_summary MacroEnvironmentSummary
  attribute_patch     AttributePatch[]
  tag_patch           TagPatch[]
}

DestructionEvent {
  event_id            u64
  scene_id            u64
  source_actor_id     u64
  source_skill_id     u32
  affected_chunks     ChunkCoord[]
  result_hash         u64
}
```

`DestructionEvent` 是表现和审计事件；真正 geometry 改变仍在 `ChunkDelta` 中。

## 10. 服务端运行时

### 10.1 SceneServer.Voxel.ChunkProcess

```elixir
%SceneServer.Voxel.ChunkProcess.State{
  scene_id: scene_id,
  coord: {cx, cy, cz},
  storage: %SceneServer.Voxel.Storage{},
  version: non_neg_integer(),
  subscribers: %{client_ref => subscription_meta},
  dirty_since_ms: integer | nil,
  pending_journal: :queue.queue()
}
```

职责：

1. 惰性加载 / 初始化 chunk。
2. 应用 build transaction、state tick、impact result、object state mutation。
3. 拒绝过期 intent、无权限 intent、非法占用 intent。
4. 生成 `ChunkSnapshot / ChunkDelta / VoxelIntentResult`。
5. 给 movement、combat、NPC、技能系统提供 occupancy/collision/raycast query。
6. 批量落盘到 DataService。

### 10.2 跨 chunk 事务

Prefab/object 放置和爆炸破坏都可能覆盖多个 chunk。第一版使用确定性事务：

1. 按 `{scene_id, chunk_coord}` 排序锁定相关 authority。
2. 所有 chunk 在同一 `transaction_id` 下 validate。
3. 任一失败则全体 abort。
4. 全部成功后按同样顺序 commit，广播 delta。

不允许 prefab 半落地，也不允许爆炸只改掉一半 chunk。

## 11. 持久化

```text
voxel_chunks
  scene_id              bigint
  coord_x/y/z           int
  schema_version        smallint
  chunk_size_in_macro   smallint
  micro_resolution      smallint
  chunk_version         bigint
  data                  bytea
  updated_at            timestamptz
  unique(scene_id, coord_x, coord_y, coord_z)

voxel_parcels
  parcel_id             bigint
  scene_id              bigint
  owner_account_id      bigint
  bounds_data           bytea
  permission_mask       bigint
  build_epoch           bigint
  updated_at            timestamptz

voxel_scene_objects
  scene_id              bigint
  object_id             bigint
  parcel_id             bigint
  blueprint_id          bigint
  blueprint_version     int
  anchor_world_micro    bigint[3]
  data                  bytea
  updated_at            timestamptz

voxel_blueprints
  blueprint_id          bigint
  version               int
  owner_account_id      bigint
  visibility            smallint
  micro_resolution      smallint
  data                  bytea
  created_at/updated_at timestamptz

voxel_chunk_journal
  scene_id              bigint
  chunk_coord           int[3]
  chunk_version         bigint
  actor_id              bigint
  request_id            bigint
  op_kind               smallint
  result_code           smallint
  payload               bytea
  applied_at            timestamptz

voxel_attribute_sets
  scope_kind            smallint
  scope_id              bigint
  attribute_set_id      int
  schema_version        smallint
  data                  bytea

voxel_tag_sets
  scope_kind            smallint
  scope_id              bigint
  tag_set_id            int
  schema_version        smallint
  data                  bytea
```

Chunk snapshot 是恢复真相；journal 是审计、排障和回滚辅助。

## 12. 协议通用规则

### 12.1 字节序

所有多字节字段统一 **big-endian / network byte order**：

```text
u16/u32/u64/i16/i32/i64/f32/f64 => big-endian
string => u16 byte length + UTF-8 bytes
bytes  => u32 byte length + raw bytes
```

### 12.2 消息头

Frame 仍由 `{packet, 4}` / WebSocket body 承载：

```text
body = msg_type:u8 + payload
```

Voxel payload 内部的可变结构使用 section：

```text
section_type u8
section_len  u32
section_data bytes[section_len]
```

### 12.3 Voxel opcode

| opcode | 方向 | 名称 | 用途 |
| --- | --- | --- | --- |
| `0x60` | C->S | `ChunkSubscribe` | 订阅 scene 内 chunk AOI |
| `0x61` | C->S | `ChunkUnsubscribe` | 取消订阅 |
| `0x62` | S->C | `ChunkSnapshot` | 下发 canonical chunk truth |
| `0x63` | S->C | `ChunkDelta` | 下发 chunk 增量 |
| `0x64` | C->S | `VoxelImpactIntent` | 可选：技能/工具请求地形影响，通常由技能系统内部触发 |
| `0x65` | C->S | `BuildReservationIntent` | 请求地块/区域内施工保留 |
| `0x66` | C->S | `BlueprintCreate` | 创建 prefab/blueprint 定义 |
| `0x67` | C->S | `PrefabPlaceIntent` | 提交 blueprint_id + anchor intent |
| `0x68` | S->C | `VoxelIntentResult` | 返回 accepted/deferred/rejected/stale |
| `0x69` | S->C | `ChunkInvalidate` | 服务端要求客户端丢弃/重订阅 |
| `0x6A` | C->S | `ParcelQuery` | 查询地块/权限/建设状态 |
| `0x6B` | C->S | `ObjectAction` | object/part 级交互 |
| `0x6C` | S->C | `ObjectStateDelta` | object 状态更新 |
| `0x6D` | S->C | `TagCatalogSnapshot` | tag catalog 下发 |
| `0x6E` | S->C | `AttributeCatalogSnapshot` | 属性 catalog 下发 |
| `0x6F` | both | `VoxelDebugProbe` | 本地/dev 调试保留 |

## 13. 关键消息

### 13.1 ChunkSubscribe `0x60`

```text
request_id        u64
scene_id          u64
center_chunk      i32 cx, i32 cy, i32 cz
radius_l_inf      u8
want_snapshot     u8
known_count       u16
known[] {
  chunk_coord      i32 cx, i32 cy, i32 cz
  chunk_version    u64
}
```

### 13.2 ChunkSnapshot `0x62`

```text
request_id          u64
scene_id            u64
chunk_coord         i32 cx, i32 cy, i32 cz
schema_version      u16
chunk_size_in_macro u8
micro_resolution    u8
chunk_version       u64
chunk_hash          u64
section_count       u16
sections[]          section
```

必备 section：

| section | 内容 |
| --- | --- |
| `0x01 MacroHeaders` | 4096 个 packed header |
| `0x02 NormalBlocks` | normal block pool |
| `0x03 RefinedCells` | refined cell pool |
| `0x04 AttributeSets` | 本 snapshot 用到的属性集合 |
| `0x05 TagSets` | 本 snapshot 用到的 tag 集合 |
| `0x06 EnvironmentSummaries` | macro environment summary pool |
| `0x07 ObjectRefs` | chunk 覆盖到的 object/part 摘要 |

### 13.3 ChunkDelta `0x63`

```text
scene_id            u64
chunk_coord         i32 cx, i32 cy, i32 cz
base_chunk_version  u64
new_chunk_version   u64
op_count            u16
ops[] {
  delta_kind         u8
  macro_index        u16
  cell_version       u32
  cell_hash          u32
  payload            bytes
}
```

`delta_kind`：

| 值 | 名称 | payload |
| --- | --- | --- |
| `0` | `CellEmpty` | none |
| `1` | `CellSolid` | `NormalBlockData` |
| `2` | `CellRefined` | `RefinedCellData` packed |
| `3` | `EnvironmentUpdated` | `MacroEnvironmentSummary` |
| `4` | `ObjectRefUpdated` | `ChunkObjectRef` |
| `5` | `CatalogPatch` | attribute/tag catalog patch |

客户端若 `base_chunk_version` 不匹配本地 confirmed store，必须请求 snapshot，不做乱序合并。

### 13.4 BuildReservationIntent `0x65`

```text
request_id          u64
client_intent_seq   u32
scene_id            u64
parcel_id           u64
bounds_world_micro  AabbI64
intent_hash         u64
ttl_ms              u32
```

用于施工排他保留。服务器可以返回 accepted/deferred/rejected/stale。

### 13.5 PrefabPlaceIntent `0x67`

```text
request_id          u64
client_intent_seq   u32
scene_id            u64
parcel_id           u64
blueprint_id        u64
blueprint_version   u32
anchor_world_micro  i64 x, i64 y, i64 z
rotation            u8
known_ref_count     u16
known_refs[] {
  chunk_coord        i32 cx, i32 cy, i32 cz
  chunk_version      u64
}
placement_flags     u32
```

客户端提交 intent，不提交 rasterized truth。服务端用 blueprint registry 重算 covered chunks / macro / micro masks。

### 13.6 VoxelImpactIntent `0x64`

技能系统通常在服务端内部直接触发体素影响；此消息只给工具、特殊交互或需要客户端显式指定地形目标的技能使用。

```text
request_id          u64
client_intent_seq   u32
scene_id            u64
source_actor_id     u64
source_skill_id     u32
target_world_micro  i64 x, i64 y, i64 z
impact_kind         u16
client_hint_hash    u64
```

服务器可以忽略 `client_hint_hash`，它只用于排障或快速拒绝明显过期的客户端目标。

### 13.7 VoxelIntentResult `0x68`

```text
request_id          u64
client_intent_seq   u32
scene_id            u64
result_code         u8
result_ref          u64
authoritative_count u16
authoritative[] {
  chunk_coord        i32 cx, i32 cy, i32 cz
  chunk_version      u64
  macro_index        u16
  cell_version       u32
  cell_hash          u32
  cell_payload       bytes
}
reason              string
```

`result_code`：

| 值 | 名称 | 含义 |
| --- | --- | --- |
| `0` | `Accepted` | 已接受并已提交或即将由 delta 表达 |
| `1` | `Deferred` | 已入队或等待建设/规则 tick |
| `2` | `Rejected` | 权限、资源、几何、规则不满足 |
| `3` | `Stale` | 客户端基于过期 chunk/object/parcel 状态发起 |

## 14. 客户端状态模型

客户端分三层，但没有体素真相预测层：

```text
actor-predicted state
  movement, cast animation, local particles, audio, camera, crosshair.

voxel-preview state
  build wireframe, parcel overlay, validity hints, in-flight intent marker.
  It never mutates confirmed voxel geometry or voxel attributes.

confirmed voxel store
  only changed by ChunkSnapshot, ChunkDelta, ObjectStateDelta,
  TagCatalogSnapshot, AttributeCatalogSnapshot, VoxelIntentResult payloads.
```

CLI/HUD 必须暴露：

```text
voxel_sync = server-authoritative | offline-local-dev
voxel_truth_source = server
subscribed_chunks
confirmed_chunk_versions
inflight_intent_count
last_intent_result
last_reject_reason
snapshot_rx_count
delta_rx_count
object_delta_rx_count
voxel_codec_endian = big
micro_resolution = 8
```

`offline-local-dev` 只允许作为开发模式，不能冒充 MMO 权威链路。

## 15. 编码结构与 golden fixtures

先落 codec、结构和 fixture，再落 gameplay：

```text
apps/scene_server/lib/scene_server/voxel/
  README.md
  storage.ex
  codec.ex
  wire_types.ex
  parcel_process.ex
  chunk_process.ex
  object_process.ex
  rule_simulator.ex

clients/web_client/src/infrastructure/net/voxelCodec.ts
clients/web_client/src/domain/voxel/serverTypes.ts

fixtures/voxel_wire/
  empty_chunk_v1.bin
  solid_cell_v1.bin
  refined_512_cell_v1.bin
  parcel_query_v1.bin
  prefab_place_intent_v1.bin
  voxel_intent_rejected_v1.bin
  object_state_delta_v1.bin
```

Elixir 和 TypeScript 必须对同一 fixture round-trip；Rust/UE 接入时读同一组 fixture。

## 16. 实施顺序

1. **S0 数据结构 + big-endian codec + fixtures**：Storage、wire types、attribute/tag/object 基础结构。
2. **S1 read-only chunk authority**：`ChunkSubscribe / ChunkSnapshot`，两个客户端 hash 一致。
3. **S2 parcel + build reservation**：地块查询、权限、排他保留、CLI/observe。
4. **S3 prefab placement transaction**：服务器重算 raster，跨 chunk 原子 commit，广播 object/chunk delta。
5. **S4 voxel state simulation**：温度、湿度、燃烧、冻结、结构完整度，由服务器 tick 后下发数据。
6. **S5 destruction/impact**：技能/爆炸导致的 micro/object 破坏，服务端结算，客户端数据驱动表现。
7. **S6 world coordination**：scene directory、transfer、global blueprint catalog。

## 17. 验收口径

S0：

- Elixir/TypeScript 对 `empty_chunk / solid_cell / refined_512_cell / prefab_place_intent / object_state_delta` fixture hash 一致。
- 活跃协议文档和 codec 注释只声明 big-endian。
- `window.__voxelCli.run("voxel_transport")` 能显示 truth source、endian、micro resolution。

S1：

- 两个浏览器订阅同一 scene/chunk，`snapshot.chunk_hash` 一致。
- 客户端 confirmed voxel store 只由 snapshot/delta 更新。

S2/S3：

- 未授权地块的 prefab 放置被拒绝。
- 同一地块/区域并发放置只允许一个事务成功。
- 跨 chunk prefab 不会部分落地。
- 客户端没有把 rejected intent 写进 confirmed geometry。

S4/S5：

- 客户端先播放技能粒子，但燃烧/冻结/破坏只在服务器 delta 后进入体素效果管线。
- 相同输入 fixture 在服务端重复计算得到相同 `ChunkDelta / ObjectStateDelta` hash。

## 18. 设计警戒线

1. 不要把体素数据做客户端预测真相。
2. 不要让技能特效结果直接改 voxel store。
3. 不要让客户端上传最终 prefab raster 当权威结果。
4. 不要绕过 parcel/claim 权限直接写 chunk。
5. 不要丢掉 object/part provenance。
6. 不要把所有 chunk 默认展开成 micro 数组。
7. 不要只做 GUI；必须同步 CLI/observe/golden fixture。
