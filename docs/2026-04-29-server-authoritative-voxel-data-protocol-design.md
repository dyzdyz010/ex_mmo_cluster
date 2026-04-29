# 服务端权威体素世界数据结构与协议设计 (2026-04-29)

## 1. 最终目标

把体素世界从浏览器本地 `WorldStore` 收拢为**服务端权威、scene 内热路径、本地可预测、可持久化、可审计、可扩展属性/魔法标签**的世界真相系统。

本设计不受早期占位文档限制。当前仓库还没有服务端权威 voxel 代码，因此 v1 应从干净边界开始：

```text
WorldServer
  owns scene directory, scene lifecycle, cross-scene transfer, global catalog coordination.

SceneServer.Voxel
  owns concrete scene-local chunk truth, edit arbitration, voxel AOI, collision/occupancy queries.

GateServer
  owns connection state, auth/session checks, binary framing, opcode route by current scene_ref.

DataService
  owns persistence snapshots, journals, blueprint/catalog tables; it is not runtime authority.

Client
  owns render, preview, optimistic pending overlay, diagnostics; confirmed truth comes from server.
```

一句话结论：**world 协调 scene，scene 负责具体场景分块；voxel hot authority 放在 scene，不放在 world，也不新建默认热路径 `voxel_server`。**

## 2. 与旧文档冲突的定版决策

| 主题 | 旧口径 | 当前定版 |
| --- | --- | --- |
| authority 位置 | 新 app `voxel_server` 或 `world_server` | `SceneServer.Voxel.*` 持有热 chunk；`WorldServer` 只做 scene 协调 |
| 字节序 | voxel payload 小端，主协议大端 | 全协议统一 **big-endian / network byte order** |
| 微格分辨率 | UE `test1` 首版 `MicroPerMacro=4` | server v1 canonical 使用 `MicroPerMacro=8`，协议仍携带 `micro_resolution` |
| refined mask | `u64 micro_solid_bitmap` | 512 slots = 512 bits = 8 个 `u64` word 或 64 bytes |
| Normal block 线格式 | 10 bytes / 12 bytes 混用 | v1 定为 20 bytes 固定头，属性/标签走引用池 |
| prefab 真相 | 客户端 raster 可直接同步 | 客户端只提交 intent；服务端用 registry 重算 raster |
| tag 用途 | 放置合法性可能依赖 tag | v1 建造合法性由几何占用决定；tag 用于玩法语义 |

UE `D:\UnrealEngine\test1` 是数据模型参考，不是本仓库服务端 wire contract。它的关键思想应保留：chunk 是真相，宏格默认轻量，局部才 refined，prefab 是统一微格模板，材料/环境/状态在真相层。但服务端 v1 要按多人权威和现有 web/bevy 客户端的 8 微格精度重新定版。

## 3. 空间与 ID 约定

### 3.1 固定量化

| 名称 | 类型 | v1 值 | 说明 |
| --- | --- | --- | --- |
| `chunk_size_in_macro` | `u8` | `16` | 每 chunk `16 x 16 x 16 = 4096` macro |
| `micro_resolution` | `u8` | `8` | 每 macro `8 x 8 x 8 = 512` micro |
| `macro_index` | `u16` | `0..4095` | `x + y * 16 + z * 16 * 16` |
| `micro_index` | `u16` | `0..511` | `x + y * 8 + z * 8 * 8` |
| `cell_version` | `u32` | monotonic | macro-level optimistic conflict check |
| `chunk_version` | `u64` | monotonic | chunk snapshot/delta ordering |

`micro_resolution` 必须出现在 `ChunkSnapshot` 和 prefab/blueprint 定义中。v1 只允许值 `8` 进入权威 chunk；字段保留是为了未来迁移和工具链识别，不是为了同一 scene 混跑多种分辨率。

### 3.2 坐标

```text
SceneId          u64
ChunkCoord       i32 cx, i32 cy, i32 cz
LocalMacroCoord  u8  mx, u8  my, u8  mz
LocalMicroCoord  u8  ux, u8  uy, u8  uz
WorldMacroCoord  i64 x,  i64 y,  i64 z
WorldMicroCoord  i64 x,  i64 y,  i64 z
```

负坐标必须使用 floor division / Euclidean remainder，保持 UE `test1` 的负象限语义，不能用语言默认的 truncating division。

## 4. Chunk 真相结构

### 4.1 宏格模式

```text
enum CellMode : u8 {
  Empty      = 0,
  SolidBlock = 1,
  Refined    = 2
}
```

### 4.2 MacroCellHeader

每个 chunk 固定 4096 个 header；重负载放池中。

```text
MacroCellHeader {
  mode              u8
  flags             u16
  payload_index     u32   // index into normal_blocks or refined_cells; 0xFFFF_FFFF = none
  environment_index u32   // index into environment_summaries; 0xFFFF_FFFF = none
  cell_version      u32
  cell_hash         u32   // canonical packed cell hash, for fast conflict/probe
}
```

`flags` 建议位义：

| bit | 名称 | 含义 |
| --- | --- | --- |
| `0x0001` | `DirtyStorage` | 需要落盘 |
| `0x0002` | `DirtyMesh` | 需要 mesh/collision rebuild |
| `0x0004` | `DirtyRules` | 需要规则 tick |
| `0x0008` | `BoundaryTouched` | 影响邻 chunk 边界 |
| `0x0010` | `HasObjectProvenance` | cell/micro 能回溯到 object/part |
| `0x0020` | `HasAttributeOverride` | 存在属性覆盖 |
| `0x0040` | `HasTagOverride` | 存在 tag 覆盖 |

### 4.3 NormalBlockData

普通块占满一个 macro。固定头只保存高频真相；扩展属性和魔法标签走 interned pool。

```text
NormalBlockData {
  material_id       u16
  state_flags       u32
  health            u16
  temperature_delta i16
  moisture_delta    i16
  attribute_set_ref u32   // 0 = none/default material-derived attributes
  tag_set_ref       u32   // 0 = none/default material tags
}
```

固定线格式为 20 bytes。它吸收了 UE `test1` 的 `MaterialId / StateFlags / Health / TemperatureDelta / MoistureDelta`，并为后续自身属性、魔法标签留下稳定引用位置。不要把任意属性 JSON 直接塞进每个块；那会破坏 snapshot 和 delta 的局部性。

### 4.4 RefinedCellData

refined cell 表示一个 macro 内 512 个 micro slot。运行时结构可以稀疏，wire v1 使用“层 + mask”压缩，避免每次传 512 个全量属性。

```text
RefinedCellData {
  occupancy_words   u64[8]       // 512 bits, big-endian words in wire
  layers            MicroLayer[]
  object_refs       ObjectCoverRef[]
  boundary_cache    u64
  local_version     u32
}

MicroLayer {
  mask_words        u64[8]       // layer covers these occupied micro slots
  material_id       u16
  state_flags       u32
  health            u16
  attribute_set_ref u32
  tag_set_ref       u32
  owner_object_id   u64          // 0 = terrain/no object
  owner_part_id     u32          // 0 = no part
}

ObjectCoverRef {
  owner_object_id   u64
  owner_part_id     u32
  mask_words        u64[8]
}
```

层结构的规则：

1. `occupancy_words` 是所有 `layers.mask_words` 的 OR。
2. 同一个 micro slot 在同一个 cell 内只能归属一个有效 layer。
3. 当 prefab/assembly 被拍扁进 chunk truth 时，必须保留 `owner_object_id / owner_part_id`，否则后续无法做局部破坏、魔法标签命中、门窗交互、部件级燃烧。
4. 如果多个 micro slot 只有同一材料/状态/属性/tag/owner，可以合成一个 layer。

### 4.5 AttributeSet

属性集合是 interned、版本化、可复用的数据。它既能表达方块自身属性，也能表达实例覆盖。

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
  value_q16         i32   // fixed-point, deterministic across BEAM/TS/Rust/UE
}

AttributeResource {
  resource_id       u16
  current_q16       i32
  max_q16           i32
}
```

首批建议保留这些 `attribute_id`：

| id | 名称 | 用途 |
| --- | --- | --- |
| `1` | `max_health` | 耐久上限 |
| `2` | `hardness` | 破坏速度/工具需求 |
| `3` | `mass` | 后续结构/坠落/物理 |
| `4` | `thermal_conductivity` | 热传播 |
| `5` | `moisture_capacity` | 湿度响应 |
| `6` | `flammability` | 点燃概率/燃烧规则 |
| `7` | `magic_conductivity` | 魔法能量传播 |
| `8` | `mana_capacity` | 可储魔容量 |
| `9` | `element_affinity` | 元素倾向的压缩枚举或 bitset |
| `10` | `structural_support` | 支撑/承重规则 |

后续要加属性，只加 catalog 项，不改 `NormalBlockData` 和 `MicroLayer` 固定头。

### 4.6 TagSet

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
  namespace_id      u16   // system, magic, biome, player, mod...
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

v1 放置合法性只看几何占用，不看 tag。tag 的首要作用是命中解释、技能/魔法规则、过滤、UI、审计和未来配方。

### 4.7 EnvironmentSummary

保留 UE `test1` 的三层环境思想：气候基线、天气覆盖、局部场最终折叠成 macro summary。

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

普通规则默认只读 macro summary；refined/prefab 只有在局部确实需要时才下钻到 micro/part。

### 4.8 ChunkStorage

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
  attribute_sets        VoxelAttributeSet[]  // chunk-local intern table, optional
  tag_sets              VoxelTagSet[]        // chunk-local intern table, optional
  dirty_bounds          DirtyMacroBounds
}
```

`attribute_sets` / `tag_sets` 可以是 chunk-local snapshot 内联表，也可以只引用 scene/global catalog。推荐 wire snapshot 支持内联“本 snapshot 用到的集合”，避免客户端收到 cell 后还缺 catalog。

## 5. Prefab / Blueprint / Object Provenance

### 5.1 为什么要拆三层

test1 的 `FPrefabDefinitionData` 和 `FPrefabInstanceData` 已经验证了“定义/实例分离”。多人服务端还需要第三层：object/assembly provenance。

```text
BlueprintDefinition
  reusable template: occupancy, parts, sockets, default material channels, default tags.

SceneObjectInstance
  one placed object/assembly: object_id, blueprint_id, transform in quantized micro coords, owner, version.

ChunkTruth
  flattened occupancy used for authority, collision, meshing, conflict checks, and persistence.
  It retains owner_object_id + owner_part_id per micro layer.
```

服务端 commit 时可以把 prefab 拍扁到 chunk truth，但不能丢失“这个 micro 属于哪个 object/part”。

### 5.2 BlueprintDefinition

```text
BlueprintDefinition {
  blueprint_id          u64
  version               u32
  source_kind           u8    // builtin, player_runtime, imported, generated
  owner_account_id      u64   // 0 for system
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

### 5.3 SceneObjectInstance

```text
SceneObjectInstance {
  object_id             u64
  blueprint_id          u64
  blueprint_version     u32
  scene_id              u64
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

后续门、机关、魔法阵、玩家建筑都应挂在 object/part 语义上，而不是把所有 micro 都降级成匿名材料格。

## 6. 服务端运行时架构

### 6.1 SceneServer.Voxel.ChunkProcess

一个 scene-local chunk 一个权威进程：

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
2. 应用 `BlockBreak / BlockPlace / PrefabPlace / ObjectAction`。
3. 用 `base_chunk_version + base_cell_version + base_cell_hash` 做冲突判断。
4. 生成 `ChunkSnapshot / ChunkDelta / EditAck`。
5. 维护订阅者并广播 delta。
6. 提供 occupancy/collision/raycast query 给 movement、combat、NPC 和技能系统。
7. 批量落盘到 DataService。

### 6.2 跨 chunk 事务

Prefab/object 放置可能覆盖多个 chunk。v1 使用确定性两阶段：

1. 按 `{scene_id, chunk_coord}` 排序获取相关 chunk authority。
2. 所有 chunk 在同一 `transaction_id` 下 validate 几何占用、版本、权限。
3. 任一失败则全体 abort，并回 `EditAck(rejected/conflict)`。
4. 全部成功后按同样顺序 commit，广播 delta。

不要允许“半个 prefab 已落地”。

### 6.3 持久化

DataService 推荐表：

```text
voxel_chunks
  scene_id              bigint
  coord_x/y/z           int
  schema_version        smallint
  chunk_size_in_macro   smallint
  micro_resolution      smallint
  chunk_version         bigint
  data                  bytea      -- canonical ChunkStorage snapshot
  updated_at            timestamptz
  unique(scene_id, coord_x, coord_y, coord_z)

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

voxel_blueprints
  blueprint_id          bigint
  version               int
  owner_account_id      bigint
  visibility            smallint
  micro_resolution      smallint
  data                  bytea
  created_at/updated_at timestamptz

voxel_scene_objects
  scene_id              bigint
  object_id             bigint
  blueprint_id          bigint
  blueprint_version     int
  anchor_world_micro    bigint[3]
  data                  bytea
  updated_at            timestamptz

voxel_attribute_sets
  scope_kind            smallint   -- global, scene, blueprint, chunk
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

Chunk snapshot 是恢复真相；journal 是审计/回滚/调试，不作为每次冷启动的主重放路径。

## 7. 协议通用规则

### 7.1 字节序

所有多字节字段统一 **big-endian / network byte order**：

```text
u16/u32/u64/i16/i32/i64/f32/f64 => big-endian
string => u16 byte length + UTF-8 bytes
bytes  => u32 byte length + raw bytes
```

原因：

1. 现有 `GateServer.Codec` 和 `docs/2026-04-10-线协议规范.md` 已经是大端。
2. 网络协议按大端符合常见 network byte order。
3. TypeScript `DataView`、Elixir bit syntax、Rust/UE 都能显式写 BE，golden fixture 可锁死差异。
4. 同一 frame 内混用大小端最容易制造未来不可见的数据损坏。

### 7.2 消息头

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

这样可以字段追加，不需要重排旧字段。

### 7.3 Voxel opcode

| opcode | 方向 | 名称 | 状态 |
| --- | --- | --- | --- |
| `0x60` | C->S | `ChunkSubscribe` | v1 |
| `0x61` | C->S | `ChunkUnsubscribe` | v1 |
| `0x62` | S->C | `ChunkSnapshot` | v1 |
| `0x63` | S->C | `ChunkDelta` | v1 |
| `0x64` | C->S | `BlockBreak` | v1 |
| `0x65` | C->S | `BlockPlace` | v1 |
| `0x66` | C->S | `BlueprintCreate` | v1 reserved |
| `0x67` | C->S | `PrefabPlace` | v1 |
| `0x68` | S->C | `EditAck` | v1 |
| `0x69` | S->C | `ChunkInvalidate` | v1 |
| `0x6A` | C->S | `ChunkQuery` | v1 reserved |
| `0x6B` | C->S | `ObjectAction` | v1 reserved |
| `0x6C` | S->C | `ObjectStateDelta` | v1 reserved |
| `0x6D` | S->C | `TagCatalogSnapshot` | v1 reserved |
| `0x6E` | S->C | `AttributeCatalogSnapshot` | v1 reserved |
| `0x6F` | both | `VoxelDebugProbe` | local/dev reserved |

## 8. 具体消息

### 8.1 ChunkSubscribe `0x60`

```text
request_id        u64
scene_id          u64
center_chunk      i32 cx, i32 cy, i32 cz
radius_l_inf      u8
want_snapshot     u8   // 0/1
known_count       u16
known[] {
  chunk_coord      i32 cx, i32 cy, i32 cz
  chunk_version    u64
}
```

服务端根据连接的 `scene_ref` 校验 `scene_id`，不能信任客户端随便订阅其他 scene。

### 8.2 ChunkSnapshot `0x62`

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

### 8.3 ChunkDelta `0x63`

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

客户端若 `base_chunk_version` 不匹配本地确认态，必须请求 snapshot，不要尝试乱序合并。

### 8.4 BlockPlace `0x65`

```text
request_id          u64
client_edit_seq     u32
scene_id            u64
chunk_coord         i32 cx, i32 cy, i32 cz
macro_index         u16
base_chunk_version  u64
base_cell_version   u32
base_cell_hash      u32
placement_kind      u8   // 0 solid macro, 1 refined micro layer
payload             bytes
```

solid macro payload：

```text
normal_block        NormalBlockData
```

refined micro payload：

```text
mask_words          u64[8]
micro_layer         MicroLayer without owner fields if terrain
```

客户端可以做 preview，但权威写入必须等 `EditAck(applied)` 或 `ChunkDelta`。

### 8.5 BlockBreak `0x64`

```text
request_id          u64
client_edit_seq     u32
scene_id            u64
chunk_coord         i32 cx, i32 cy, i32 cz
macro_index         u16
base_chunk_version  u64
base_cell_version   u32
base_cell_hash      u32
break_kind          u8   // 0 whole macro/cell, 1 micro mask, 2 object part
payload             bytes
```

micro mask payload：

```text
mask_words          u64[8]
```

object part payload：

```text
owner_object_id     u64
owner_part_id       u32
```

### 8.6 PrefabPlace `0x67`

客户端提交 intent，不提交已 rasterized 的最终 truth。

```text
request_id          u64
client_edit_seq     u32
scene_id            u64
blueprint_id        u64
blueprint_version   u32
anchor_world_micro  i64 x, i64 y, i64 z
rotation            u8
base_ref_count      u16
base_refs[] {
  chunk_coord        i32 cx, i32 cy, i32 cz
  chunk_version      u64
}
placement_flags     u32
```

服务端流程：

1. 读取 server-side blueprint registry。
2. 按 `anchor_world_micro + rotation` 重算 covered chunks / macro / micro masks。
3. 对所有 chunk 做几何 overlap validate。
4. 写入 flattened chunk truth，生成 `object_id` 和 provenance。
5. 成功后向所有相关订阅者广播 delta。

### 8.7 EditAck `0x68`

```text
request_id          u64
client_edit_seq     u32
scene_id            u64
result_code         u8
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
| `0` | `Applied` | 已提交 |
| `1` | `Conflict` | base version/hash 不匹配 |
| `2` | `Rejected` | 权限、几何 overlap、非法 blueprint 等 |
| `3` | `Deferred` | 已入队，等待跨 chunk transaction |

`Conflict/Rejected` 必须尽量带 authoritative cell，方便客户端清 pending overlay。

## 9. 编码结构与 golden fixtures

实现前先落 codec 和 fixture，不先写 gameplay：

```text
apps/scene_server/lib/scene_server/voxel/
  README.md
  storage.ex
  codec.ex
  wire_types.ex
  chunk_process.ex

clients/web_client/src/infrastructure/net/voxelCodec.ts
clients/web_client/src/domain/voxel/serverTypes.ts

fixtures/voxel_wire/
  empty_chunk_v1.bin
  solid_cell_v1.bin
  refined_512_cell_v1.bin
  prefab_place_intent_v1.bin
  edit_ack_conflict_v1.bin
```

每个 fixture 至少由 Elixir 和 TypeScript 同时 round-trip；未来 Rust/UE 接入也必须先读同一组 fixture。

## 10. 客户端状态模型

客户端必须分层：

```text
confirmed WorldStore
  only changed by ChunkSnapshot / ChunkDelta / applied EditAck.

pending overlay
  local predicted edits keyed by client_edit_seq/request_id.

preview
  hover wireframe, placement candidate, invalid reason.
```

不允许把 optimistic edit 直接写成 confirmed truth 再等待服务端“拉回”。拉回频繁的根因通常就是本地双真值混在一起：预测态和确认态没有分层，服务端 delta 到来时只能重置。

CLI/HUD 必须暴露：

```text
voxel_sync
subscribed_chunks
confirmed_chunk_versions
pending_edit_count
last_edit_ack
last_conflict_reason
snapshot_rx_count
delta_rx_count
voxel_codec_endian = big
micro_resolution = 8
```

## 11. 首轮实现顺序

1. **S0 codec + storage fixtures**：只做数据结构、big-endian codec、fixture、文档 README。
2. **S1 read-only scene chunk authority**：`ChunkSubscribe / ChunkSnapshot`，两个客户端 hash 一致。
3. **S2 normal block edit authority**：`BlockPlace / BlockBreak / EditAck / ChunkDelta`，冲突拒绝。
4. **S3 refined + prefab authority**：服务端重算 prefab raster，支持 512-bit refined cell 和跨 chunk transaction。
5. **S4 object/part provenance**：`ObjectStateDelta / object_at` CLI，支持局部破坏、魔法标签命中。
6. **S5 world coordination**：scene directory、transfer、global blueprint catalog，不进入单 chunk edit 热路径。

## 12. 验收口径

S0 完成条件：

- Elixir/TypeScript 对同一 `empty_chunk / solid_cell / refined_512_cell / edit_ack_conflict` fixture hash 一致。
- `rg "小端|little-endian"` 只出现在历史/反例说明中，不得出现在活跃 codec 注释里作为当前规范。
- `MicroPerMacro=4` 只出现在 UE 参考或历史说明中，不作为本仓库 server v1 规范。

S1 完成条件：

- 两个浏览器订阅同一 scene/chunk，`snapshot.chunk_hash` 一致。
- `window.__voxelCli.run("voxel_transport")` 能显示 subscribed chunks、snapshot counters、codec endian。

S2 完成条件：

- A 放置普通块，B 收到 `ChunkDelta`。
- A/B 同时改同一 macro，只有一个 applied，另一个 conflict 并收到 authoritative cell。
- 服务端重启后 chunk 从 DataService 恢复。

S3 完成条件：

- stairs-on-stairs 细粒度 anchor preview 由客户端显示，服务端以同一 anchor 重算后 ack。
- 任意 occupied micro overlap 被拒绝。
- 跨 chunk prefab 不会部分落地。

## 13. 设计警戒线

1. 不要把 `WorldServer` 放进每次 voxel edit 的热路径。
2. 不要在同一 frame/payload 中混用大小端。
3. 不要让客户端上传最终 prefab raster 当权威结果。
4. 不要把所有 chunk 默认展开成 micro 数组。
5. 不要丢掉 object/part provenance；后续魔法标签和局部破坏会依赖它。
6. 不要把 tag 用作 v1 建造合法性的唯一依据；几何占用先行。
7. 不要只做 GUI；必须同步 CLI/observe/golden fixture。
