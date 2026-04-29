# 服务端权威体素世界第一版规范 (2026-04-29)

## 1. 目标

第一版体素世界按 MMO 建设类玩法设计：玩家不能像沙盒游戏一样任意改写方块布局；玩家先获得地块或施工权限，再以排他事务放置 prefab / blueprint。体素数据本身是世界规则真相，由服务器先计算，客户端只消费权威结果并驱动表现。

核心目标：

1. `WorldServer` 持有全局地图账本、地块权威、scene 分配表、租约、迁移和跨 scene 事务协调。
2. `SceneServer.Voxel.*` 持有被租约授权区域内的热 chunk、建筑对象、状态和破坏结果的执行权威。
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
  global map ledger
  parcel/claim authority
  region assignment table
  scene leases and owner epochs
  scene directory
  scene lifecycle
  cross-scene transfer
  cross-scene build/destruction transaction coordination
  global blueprint/catalog coordination

SceneServer.Voxel
  leased hot chunk truth
  lease token and owner_epoch checks
  local build transaction execution
  object/part state
  voxel rule simulation
  destruction and terrain impact results
  voxel AOI and chunk subscriptions
  boundary halo / neighbor summaries

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

### 3.1 全局账本与热所有权

体素系统需要两层“持有”：

```text
World ownership
  global and durable control-plane ownership.
  It knows the full map layout, parcels, assignment, leases, versions, hashes,
  and which scene is allowed to hot-run each region.

Scene ownership
  leased hot execution ownership.
  It owns full chunk data only for the regions currently leased to it,
  runs local rules, serves subscriptions, and writes deltas under owner_epoch.
```

World 不应该参与每次燃烧 tick、碰撞查询或局部 AOI 广播；Scene 不应该私自决定自己长期负责哪片区域。两者通过租约连接：

```text
MapRegionAssignment {
  region_id           u64
  scene_id            u64
  bounds_chunk_min    ChunkCoord
  bounds_chunk_max    ChunkCoord
  owner_scene_ref     u64
  owner_epoch         u64
  state               u8   // active, migrating, draining, inactive
  summary_hash        u64
  version             u64
}

SceneLease {
  lease_id            u64
  region_id           u64
  owner_scene_ref     u64
  owner_epoch         u64
  expires_at_ms       u64
  bounds_chunk_min    ChunkCoord
  bounds_chunk_max    ChunkCoord
}

ChunkSummary {
  scene_id            u64
  chunk_coord         ChunkCoord
  owner_epoch         u64
  chunk_version       u64
  chunk_hash          u64
  parcel_id           u64
  dirty_state         u8
  last_persisted_ms   u64
}
```

所有 Scene 写入 DataService 或向 World 上报 delta 时都必须携带 `owner_epoch`。World / DataService 只接受当前 epoch 的写入，防止迁移期间旧 Scene 和新 Scene 同时写同一 chunk。

### 3.2 全量地图与局部热数据

World 应运行时常驻“全局地图账本”，但不常驻全量 micro chunk。建议常驻：

1. region / chunk 到 owning scene 的 assignment。
2. parcel/claim 权限、build epoch、租约状态。
3. chunk version/hash/dirty summary。
4. object/blueprint/catalog 版本目录。
5. 全局系统需要的低精度派生层，例如气候、资源、道路、势力、远景 LOD。

Scene 常驻：

1. 当前 lease 范围内的完整 chunk data。
2. 当前 lease 范围内 active object / part state。
3. 建设事务、规则 tick、碰撞/AOI/raycast 索引。
4. 边界 halo：相邻区域的只读摘要，用于碰撞、视野、火焰/冻结传播边缘判断。

DataService 存完整快照和 journal。冷区域只需要 World summary + DataService snapshot，不需要任何 Scene 常驻。

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
  region_id           u64
  owner_scene_ref     u64
  owner_epoch         u64
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

1. Gate / Scene 收到 intent 后按 `scene_ref` 交给 `WorldServer.ParcelAuthority`。
2. World 校验 actor 已进入 scene，且对 parcel 有权限。
3. World 校验 blueprint 可用、版本匹配、资源/冷却/建设队列满足。
4. World 根据 `anchor_world_micro + rotation` 计算 affected chunks，并从 assignment table 找到涉及的 Scene。
5. World 创建 `reservation_id + transaction_id + owner_epoch`，向相关 Scene 发 `PrepareBuild`。
6. Scene 本地校验几何占用、碰撞、chunk version、object state、边界 halo。
7. 全部 `prepare_ok` 后 World 发 `CommitBuild`；任一失败则 `AbortBuild`。
8. Scene 提交自己负责的 chunk delta，写入 object provenance，并回 ack。
9. World 更新 parcel `build_epoch`、chunk summary 和全局账本。
10. 客户端收到 `ObjectStateDelta / ChunkDelta / VoxelIntentResult` 后更新 confirmed voxel store。

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

### 10.2 跨 chunk / 跨 Scene 事务

Prefab/object 放置和爆炸破坏都可能覆盖多个 chunk，甚至跨多个 Scene lease。第一版使用 World 协调的确定性事务：

1. World 根据 assignment table 找到所有 affected Scene。
2. World 创建 `transaction_id`，按 `{scene_id, chunk_coord}` 排序要求相关 Scene `Prepare`。
3. 每个 Scene 只校验自己当前 lease 内的 chunk，并检查 `owner_epoch`。
4. 任一 Scene 返回失败、过期或 epoch 不匹配，World 全体 `Abort`。
5. 全部成功后，World 按同样顺序发 `Commit`。
6. Scene 各自提交 chunk delta / object delta，并向 World 回报 chunk summary。
7. World 更新 parcel/build epoch、assignment summary 和事务 journal。

不允许 prefab 半落地，也不允许爆炸只改掉一半 chunk。

### 10.3 WorldServer.MapLedger / LeaseManager

World 侧需要一个明确的地图账本与租约管理边界：

```elixir
%WorldServer.Voxel.MapLedger.State{
  scene_id: scene_id,
  assignments: %{region_id => %MapRegionAssignment{}},
  parcels: %{parcel_id => %ParcelClaim{}},
  chunk_summaries: %{chunk_key => %ChunkSummary{}},
  leases: %{region_id => %SceneLease{}},
  migrations: %{migration_id => %MigrationPlan{}}
}
```

职责：

1. 决定 region / chunk 当前由哪个 Scene 热运行。
2. 发放、续租、吊销 SceneLease。
3. 校验 parcel/claim 权限和 build_epoch。
4. 协调跨 Scene 的建设和破坏事务。
5. 驱动 region 转移、分裂、合并。
6. 维护 chunk summary，供全局地图、远景、负载均衡和冷区恢复使用。

Scene 可以缓存 World 账本的一部分，但缓存不能成为长期权威。Scene 收到过期 `owner_epoch` 或 lease 被吊销后，必须停止写入并进入 drain/release。

### 10.4 迁移流程

迁移只改变“某片区域由哪个 Scene 负责热运行”，不改变 DataService 中的持久化 truth。常见三类：转移、分裂、合并。

#### 通用步骤

```text
World marks migration
  -> old Scene write fence
  -> old Scene drains in-flight transactions
  -> old Scene flushes dirty chunks and reports versions/hashes
  -> World creates new owner_epoch and target lease
  -> target Scene loads snapshots and warms halo
  -> target Scene validates chunk hashes/versions
  -> World flips assignment table
  -> Gate/client/AOI resubscribe or reroute
  -> old Scene releases lease
```

关键规则：

1. 路由翻转前，旧 Scene 仍是该区域唯一写入者。
2. 路由翻转后，只有新 `owner_epoch` 的 Scene 能写。
3. 迁移区域进入 `migrating` 后不接受新的建设事务；已有事务要么完成，要么 abort。
4. DataService / World 拒绝旧 epoch 写入，防止 split-brain。
5. 新 Scene 必须先 warmup halo、object index、collision 和 AOI，再对外开放订阅。

#### 转移

转移是一整块 region 从 Scene A 移到 Scene B。

适用场景：

1. Scene A 负载过高。
2. 玩家或建筑热点需要挪到更空的节点。
3. 机器维护、缩容或故障隔离。

流程：

1. World 选择 region 和目标 Scene B。
2. World 将 region 状态改为 `migrating`，生成 `migration_id`。
3. Scene A 对 region 加 write fence，停止新建设/破坏/状态写入。
4. Scene A drain 在途事务并 flush dirty chunks。
5. World 给 Scene B 发新 lease 和 `owner_epoch + 1`。
6. Scene B 从 DataService 加载 chunk/object/parcel，构建 halo 和 runtime index。
7. Scene B 上报 hash/version 校验通过。
8. World 翻转 assignment：region owner 从 A 改为 B。
9. Gate 和客户端重订阅到 B；Scene A 释放旧 lease。

#### 分裂

分裂是一个 Scene 负责的大 region 被拆成多个 region，分给多个 Scene。

示例：

```text
Scene A owns R
split into:
  R1 -> Scene A
  R2 -> Scene B
  R3 -> Scene C
```

适用场景：

1. 大区域热点过多，单 Scene tick 或 AOI 压力过高。
2. 建筑/燃烧/破坏模拟集中在不同子区域。
3. 希望按 chunk band、parcel group 或热点包围盒拆负载。

流程：

1. World 根据负载、玩家密度、parcel 边界和 chunk 边界生成 split plan。
2. split 边界优先贴合 parcel 或 region 边界，不切穿正在建设的 parcel。
3. World 标记 R 为 `migrating`，并创建 R1/R2/R3 的新 assignment。
4. Scene A 对将迁出的 R2/R3 加 write fence；保留 R1 的正常热运行。
5. Scene A flush R2/R3 dirty chunks 并上报 summaries。
6. Scene B/C 加载各自 region，warm halo；A/B/C 互相持有边界只读摘要。
7. 全部校验通过后，World flip assignment。
8. 跨边界建设、爆炸和状态传播之后走 World 协调事务；边界本地规则只读 halo，不私自写邻区。

#### 合并

合并是多个 Scene 负责的相邻 region 收回到一个 Scene。

示例：

```text
Scene A owns R1
Scene B owns R2
Scene C owns R3
merge into:
  Scene A owns R1 + R2 + R3
```

适用场景：

1. 在线人数下降，热点消失，需要节省资源。
2. 多个 region 之间跨边界事务过多。
3. 世界事件或大型建设需要更强局部一致性。

流程：

1. World 选择目标 Scene 和参与合并的 region。
2. 所有源 Scene 对各自 region 加 write fence。
3. 源 Scene drain/flush，提交 chunk summaries。
4. 目标 Scene 加载完整合并区域，构建 object index、collision、AOI 和 halo。
5. World 用新的 `owner_epoch` 翻转所有 assignment 到目标 Scene。
6. 客户端和 Gate 统一重订阅目标 Scene。
7. 源 Scene 释放 lease，World 合并或归档旧 region 记录。

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
  region_id             bigint
  owner_scene_ref       bigint
  owner_epoch           bigint
  owner_account_id      bigint
  bounds_data           bytea
  permission_mask       bigint
  build_epoch           bigint
  updated_at            timestamptz

voxel_region_assignments
  region_id             bigint
  scene_id              bigint
  owner_scene_ref       bigint
  owner_epoch           bigint
  state                 smallint
  bounds_data           bytea
  summary_hash          bigint
  version               bigint
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
  chunk_process.ex
  object_process.ex
  rule_simulator.ex

apps/world_server/lib/world_server/voxel/
  README.md
  map_ledger.ex
  lease_manager.ex
  parcel_authority.ex
  migration_coordinator.ex
  transaction_coordinator.ex

clients/web_client/src/infrastructure/net/voxelCodec.ts
clients/web_client/src/domain/voxel/serverTypes.ts

fixtures/voxel_wire/
  empty_chunk_v1.bin
  solid_cell_v1.bin
  refined_512_cell_v1.bin
  parcel_query_v1.bin
  scene_lease_v1.bin
  migration_plan_v1.bin
  prefab_place_intent_v1.bin
  voxel_intent_rejected_v1.bin
  object_state_delta_v1.bin
```

Elixir 和 TypeScript 必须对同一 fixture round-trip；Rust/UE 接入时读同一组 fixture。

## 16. 实施顺序

1. **S0 数据结构 + big-endian codec + fixtures**：Storage、wire types、attribute/tag/object 基础结构。
2. **S1 read-only chunk authority**：`ChunkSubscribe / ChunkSnapshot`，两个客户端 hash 一致。
3. **S2 World map ledger + lease manager**：region assignment、owner_epoch、chunk summary、SceneLease。
4. **S3 parcel + build reservation**：地块查询、权限、排他保留、CLI/observe。
5. **S4 prefab placement transaction**：World 协调跨 Scene prepare/commit；Scene 重算 raster 并提交 chunk/object delta。
6. **S5 migration coordinator**：转移、分裂、合并三种迁移流程和路由翻转。
7. **S6 voxel state simulation**：温度、湿度、燃烧、冻结、结构完整度，由服务器 tick 后下发数据。
8. **S7 destruction/impact**：技能/爆炸导致的 micro/object 破坏，服务端结算，客户端数据驱动表现。

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
- 跨 chunk / 跨 Scene prefab 不会部分落地。
- 客户端没有把 rejected intent 写进 confirmed geometry。

S5：

- 转移：旧 Scene fence/flush，新 Scene load/warmup/hash 校验后，World 才翻转 assignment。
- 分裂：新 region 边界贴合 chunk/parcel，迁出区域使用新 owner_epoch，边界只读 halo 可用。
- 合并：源 Scene flush 后目标 Scene 加载完整区域，旧 lease 被释放且旧 epoch 写入被拒绝。

S6/S7：

- 客户端先播放技能粒子，但燃烧/冻结/破坏只在服务器 delta 后进入体素效果管线。
- 相同输入 fixture 在服务端重复计算得到相同 `ChunkDelta / ObjectStateDelta` hash。

## 18. 设计警戒线

1. 不要把体素数据做客户端预测真相。
2. 不要让技能特效结果直接改 voxel store。
3. 不要让客户端上传最终 prefab raster 当权威结果。
4. 不要绕过 parcel/claim 权限直接写 chunk。
5. 不要丢掉 object/part provenance。
6. 不要把所有 chunk 默认展开成 micro 数组。
7. 不要让 Scene 私自扩张或持久占有 region；region ownership 必须来自 World lease。
8. 不要在迁移时允许两个 owner_epoch 同时写同一 chunk。
9. 不要只做 GUI；必须同步 CLI/observe/golden fixture。
