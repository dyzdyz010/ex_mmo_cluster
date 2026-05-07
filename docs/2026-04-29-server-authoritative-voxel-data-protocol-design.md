# 服务端权威体素世界第一版规范 (2026-04-29)

## 1. 目标

第一版体素世界按 MMO 建设类玩法设计：玩家不能像沙盒游戏一样任意改写方块布局；玩家先获得地块或施工权限，再以排他事务（同一范围同一时刻只允许一个写入事务）放置 prefab（预制件）/ blueprint（蓝图模板）。体素数据本身是世界规则真相，由服务器先计算，客户端只消费权威结果并驱动表现。

核心目标：

1. `WorldServer` 持有全局地图账本（区域、地块、租约和摘要的权威目录）、地块权威、场景分配表、租约（World 授权某个 Scene 在一段时间内写某区域的令牌）、迁移和跨场景事务协调。
2. `SceneServer.Voxel.*` 持有被租约授权区域内的热区块（当前常驻内存并参与规则帧/订阅的区块）、建筑对象、状态和破坏结果的执行权威。
3. `GateServer` 负责连接状态、鉴权状态、操作码路由和帧封装，不持有体素真相。
4. `DataService` 负责区块快照（完整状态）、对象、地块、蓝图、属性和标签的持久化，不参与热路径（高频或每帧可能触发的执行路径）裁决。
5. 客户端负责渲染、选址预览、玩家动作/技能表现预演、命令行/可观测诊断（通过 CLI 和结构化日志直接读状态、输入、输出和错误原因）；客户端不预测体素数据真相。

## 2. 同步原则

第一版采用两条同步通道：

```text
角色通道
  玩家移动、瞄准、施法前摇、动画、技能粒子、音频
  -> 客户端可为了响应性做预测或预播放
  -> 服务端随后确认/校正权威角色状态

体素通道
  区块占用、温度、湿度、燃烧、冻结、
  结构完整度、对象/部件状态、地形破坏
  -> 服务端先计算
  -> 客户端只根据权威快照（完整状态）/增量（只包含变化）/结果更新数据
  -> 效果由权威体素数据驱动
```

这条边界是硬规则：**玩家相关表现可以本地先动，体素相关数据必须服务器权威先行。**

### 2.1 允许本地先发生的内容

| 内容 | 本地行为 | 服务器关系 |
| --- | --- | --- |
| 移动输入 | 本地预测、确认后纠偏 | 移动权威校正 |
| 镜头、准星、选区 | 本地即时更新 | 不进入世界真相 |
| 施法前摇 / 技能粒子 / 音效 | 本地预演 | 服务器确认命中、资源、冷却和结果 |
| prefab 选址线框 | 本地预览 | 服务器做权限、地块、占用和资源裁决 |
| 施工 UI / 等待状态 | 本地显示在途意图 | 服务器返回结果后转状态 |

### 2.2 必须等待服务器的内容

| 内容 | 权威来源 | 客户端行为 |
| --- | --- | --- |
| 区块占用 | `ChunkSnapshot / ChunkDelta` | 更新已确认体素存储 |
| prefab/object 落地 | `ObjectStateDelta / ChunkDelta / VoxelIntentResult` | 创建或更新对象表现 |
| 温度、湿度、燃烧、冻结 | `ChunkDelta / ObjectStateDelta` | 进入体素效果管线 |
| 结构完整度、裂解、倒塌 | `ObjectStateDelta / ChunkDelta` | 更新网格/碰撞/效果 |
| 爆炸或魔法导致的地形消失 | `ChunkDelta` | 更新几何后播放数据驱动后效 |
| 掉落、资源、伤害、冷却 | 技能/战斗权威结果 | 更新 UI/数值 |

客户端可以在技能发出时播放火球、爆炸光、冲击波；但木头是否点燃、石头是否破裂、哪些微格被移除，只能等服务器根据 `temperature / moisture / material / tag / attribute / structure_integrity` 计算后下发。

## 3. 运行时边界

```text
WorldServer
  全局地图账本
  地块/归属权威
  区域分配表
  场景租约（写入授权令牌）与所有权世代（`owner_epoch`，单调递增的写入世代号）
  场景目录
  场景生命周期
  跨场景迁移
  跨场景建造/破坏事务协调
  全局蓝图/目录协调

SceneServer.Voxel
  租约内热区块真值（当前常驻并执行规则的区块数据）
  租约令牌与所有权世代校验（防止旧 Scene 继续写）
  本地建造事务执行
  对象/部件状态
  体素规则模拟
  破坏与地形影响结果
  体素关注区域（AOI，客户端当前需要接收更新的空间范围）与区块订阅
  边界缓冲带（邻区只读摘要）/相邻摘要

GateServer
  认证/会话状态
  场景内路由校验
  WebSocket/TCP 帧处理
  操作码分发

DataService
  区块快照
  对象记录
  地块记录
  蓝图记录
  属性/标签目录
  日志流水/审计

客户端
  角色预测与表现
  建造预览
  已确认体素渲染
  数据驱动体素效果
  命令行/可观测诊断（CLI 和结构化日志）
```

### 3.1 全局账本与热所有权

体素系统需要两层“持有”：

本文严格区分两个编号：`logical_scene_id` 是长期持久的逻辑场景 / 世界分区编号，用于协议、数据库和客户端路由；`owner_scene_instance_ref` 是一次热运行 Scene 进程/节点实例的引用，Scene 重启、迁移或接管后会变化。所有写入所有权判断都看 `owner_scene_instance_ref + owner_epoch`，不要只看 `logical_scene_id`。

```text
世界所有权
  全局且持久的控制面所有权。
  它持有完整地图布局、地块、分配、租约、版本、哈希（内容摘要，用于快速一致性校验），
  并决定哪个场景可以热运行（常驻内存并执行规则/订阅）每个区域。

场景所有权
  基于租约的热执行所有权（获得令牌的 Scene 才能写）。
  它只持有当前租约范围内区域的完整区块数据，
  执行本地规则、服务订阅，并在 owner_epoch 下写入增量。
```

World 不应该参与每次燃烧规则帧、碰撞查询或局部 AOI（关注区域）广播；Scene 不应该私自决定自己长期负责哪片区域。两者通过租约（写入授权令牌）连接：

```text
MapRegionAssignment {
  region_id           u64
  logical_scene_id            u64
  bounds_chunk_min    ChunkCoord
  bounds_chunk_max    ChunkCoord
  owner_scene_instance_ref     u64
  owner_epoch         u64
  state               u8   // active, migrating, draining, inactive
  summary_hash        u64
  version             u64
}

SceneLease {
  lease_id            u64
  region_id           u64
  owner_scene_instance_ref     u64
  owner_epoch         u64
  expires_at_ms       u64
  bounds_chunk_min    ChunkCoord
  bounds_chunk_max    ChunkCoord
}

ChunkSummary {
  logical_scene_id            u64
  chunk_coord         ChunkCoord
  lease_id            u64
  owner_scene_instance_ref     u64
  owner_epoch         u64
  chunk_version       u64
  chunk_hash          u64
  parcel_id           u64
  dirty_state         u8
  last_persisted_ms   u64
}
```

`MapRegionAssignment` 字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `region_id u64` | 区域是长期全局对象，`u64` 给足分片、迁移和历史归档空间。 | 标识一片可调度区域。 |
| `logical_scene_id u64` | 场景也是全局资源，使用同样宽度便于跨表关联。 | 当前逻辑场景编号。 |
| `bounds_chunk_min/max ChunkCoord` | 区块坐标可为负，复用 `ChunkCoord` 避免边界换算歧义。 | 描述该区域覆盖的半开区间 `[min, max)` 区块包围盒。 |
| `owner_scene_instance_ref u64` | 与 `logical_scene_id` 分离，允许同一场景重启后获得新引用。 | 当前热运行（常驻执行规则/订阅）所有者引用。 |
| `owner_epoch u64` | 单调递增世代号，`u64` 避免长期迁移后溢出。 | 写入栅栏（拒绝旧租约/旧世代继续写入的保护条件）；拒绝旧所有者写入。 |
| `state u8` | 状态枚举很小，`u8` 在线格式（网络/落盘二进制布局）和数据库中都紧凑。 | `active / migrating / draining / inactive` 等生命周期状态。 |
| `summary_hash u64` | 64 位哈希（内容摘要）足够做快速一致性检查，成本低。 | 概括区域摘要，用于迁移校验和冷区恢复。 |
| `version u64` | 账本记录是长期版本化对象，`u64` 支撑单调更新。 | 拒绝旧账本更新，辅助审计和缓存失效。 |

`SceneLease` 字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `lease_id u64` | 租约（World 发给 Scene 的区域写入授权令牌）是独立实体，`u64` 可全局唯一。 | 区分每次发放/续租。 |
| `region_id u64` | 与区域账本主键一致。 | 指明租约覆盖的区域。 |
| `owner_scene_instance_ref u64` | 与区域分配一致，支持场景重启后的写入栅栏（旧世代拒写条件）校验。 | 指明获得租约的场景实例。 |
| `owner_epoch u64` | 与写入世代共用类型。 | Scene 写入 DataService / World 时必须携带。 |
| `expires_at_ms u64` | 毫秒时间戳长期安全，跨语言易编码。 | 租约过期判断和续租。 |
| `bounds_chunk_min/max ChunkCoord` | 与区域边界同一坐标类型。 | Scene 本地加载/释放的半开区间 `[min, max)` 区块范围。 |

DataService 不参与热路径裁决，但它必须做写入令牌校验。World 在发放或翻转租约时同步给 DataService 一份只用于落盘校验的写入令牌：

```text
LeaseWriteToken {
  logical_scene_id          u64
  region_id                 u64
  lease_id                  u64
  owner_scene_instance_ref  u64
  owner_epoch               u64
  bounds_chunk_min          ChunkCoord
  bounds_chunk_max          ChunkCoord
  expires_at_ms             u64
  token_version             u64
}
```

`LeaseWriteToken` 字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `logical_scene_id u64` | 与持久化分区一致。 | 限定令牌所属逻辑场景。 |
| `region_id u64` | 与区域账本主键一致。 | 限定令牌覆盖区域。 |
| `lease_id u64` | 与 SceneLease 同类型。 | 区分每次租约发放。 |
| `owner_scene_instance_ref u64` | 与热运行实例引用同类型。 | 校验写入来自当前 Scene 实例。 |
| `owner_epoch u64` | 与写入世代同类型。 | 拒绝旧世代写入。 |
| `bounds_chunk_min/max ChunkCoord` | 与租约边界同类型。 | DataService 本地判断区块是否落在授权范围内。 |
| `expires_at_ms u64` | 与租约过期时间同类型。 | 拒绝明显过期写入；最终权威仍以 World 下发的新令牌为准。 |
| `token_version u64` | 令牌自身需要单调版本。 | 用 CAS 更新 DataService 本地令牌，避免旧令牌覆盖新令牌。 |

`ChunkSummary` 字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `logical_scene_id u64` | 与场景主键一致。 | 所属逻辑场景。 |
| `chunk_coord ChunkCoord` | 区块坐标可能为负且三维。 | 标识具体区块。 |
| `lease_id u64` | 与 SceneLease 同类型。 | 校验摘要来自当前租约。 |
| `owner_scene_instance_ref u64` | 与热运行实例引用一致。 | 校验摘要来自当前 Scene 实例。 |
| `owner_epoch u64` | 与租约/区域世代一致。 | 校验摘要来自当前所有者。 |
| `chunk_version u64` | 区块会长期变更，`u64` 保证单调版本空间。 | 客户端和服务端判断快照（完整状态）/增量（只含变化）顺序。 |
| `chunk_hash u64` | 快速一致性校验，不承载加密安全语义。 | 迁移、订阅、客户端校验使用。 |
| `parcel_id u64` | 地块是长期对象，使用全局编号。 | 快速关联权限与归属。 |
| `dirty_state u8` | 脏状态（内存已变化但落盘/派生重建尚未完成）是小枚举/位集（用二进制位表示多个布尔标记），`u8` 足够。 | 表示是否待落盘、待重建、待规则处理。 |
| `last_persisted_ms u64` | 毫秒时间戳跨语言稳定。 | 判断落盘滞后和恢复新旧。 |

所有 Scene 写入 DataService 或向 World 上报增量时都必须携带 `lease_id + owner_scene_instance_ref + owner_epoch`。World / DataService 只接受当前写入令牌匹配的写入，DataService 通过本地令牌表做 CAS 校验，不为每次落盘回查 World，防止迁移期间旧 Scene 和新 Scene 同时写同一区块。

### 3.2 全量地图与局部热数据

World 应运行时常驻“全局地图账本”（区域、地块、租约和摘要的权威目录），但不常驻全量微格区块。建议常驻：

1. 区域/区块到所属场景的分配关系。
2. 地块/归属权限、建造世代、租约状态。
3. 区块版本/哈希（内容摘要）/脏状态（已变化待处理）摘要。
4. 对象/蓝图/目录版本索引。
5. 全局系统需要的低精度派生层，例如气候、资源、道路、势力、远景细节层级（LOD）。

Scene 常驻：

1. 当前租约范围内的完整区块数据。
2. 当前租约范围内的活跃对象/部件状态。
3. 建设事务、规则帧、碰撞/AOI（关注区域）/射线检测索引。
4. 边界缓冲带（邻区只读摘要）：相邻区域的只读摘要，用于碰撞、视野、火焰/冻结传播边缘判断。

DataService 存完整快照（完整状态）和日志流水。冷区域（当前没有 Scene 热运行（常驻内存并执行规则/订阅）的区域）只需要 World 摘要 + DataService 快照，不需要任何 Scene 常驻。

## 4. 空间与量化

### 4.1 固定参数

| 名称 | 类型 | v1 值 | 说明 |
| --- | --- | --- | --- |
| `chunk_size_in_macro` | `u8` | `16` | 每区块 `16 x 16 x 16 = 4096` 个宏格 |
| `micro_resolution` | `u8` | `8` | 每宏格 `8 x 8 x 8 = 512` 个微格 |
| `macro_index` | `u16` | `0..4095` | `x + y * 16 + z * 16 * 16` |
| `micro_index` | `u16` | `0..511` | `x + y * 8 + z * 8 * 8` |
| `cell_version` | `u32` | 单调递增 | 宏格级版本，用于拒绝过期意图 |
| `chunk_version` | `u64` | 单调递增 | 区块快照（完整状态）/增量（只含变化）顺序 |

`micro_resolution` 必须出现在区块快照（完整状态）、蓝图定义和相关样例中。第一版只允许权威场景使用 `8`，避免同一场景内混跑多个精度。

### 4.2 坐标

```text
LogicalSceneId          u64
ParcelId         u64
ChunkCoord       i32 cx, i32 cy, i32 cz
LocalMacroCoord  u8  mx, u8  my, u8  mz
LocalMicroCoord  u8  ux, u8  uy, u8  uz
WorldMacroCoord  i64 x,  i64 y,  i64 z
WorldMicroCoord  i64 x,  i64 y,  i64 z
```

坐标类型说明：

| 类型 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `LogicalSceneId u64` | 场景是长期全局资源，`u64` 便于跨服务、跨表引用。 | 标识逻辑场景。 |
| `ParcelId u64` | 地块是长期持久对象。 | 标识地块。 |
| `ChunkCoord i32 cx/cy/cz` | 区块坐标可能为负，`i32` 支撑足够大的世界范围。 | 定位区块。 |
| `LocalMacroCoord u8 mx/my/mz` | 区块内宏格范围是 `0..15`。 | 定位区块内宏格。 |
| `LocalMicroCoord u8 ux/uy/uz` | 宏格内微格范围是 `0..7`。 | 定位宏格内微格。 |
| `WorldMacroCoord i64 x/y/z` | 世界坐标可为负且长期扩展，`i64` 留足空间。 | 定位世界宏格。 |
| `WorldMicroCoord i64 x/y/z` | 微格坐标比宏格更密，仍需全局可负。 | 精确定位建设、碰撞和影响目标。 |

```text
AabbI64 {
  min_world_micro i64 x, i64 y, i64 z
  max_world_micro i64 x, i64 y, i64 z
}
```

`AabbI64` 字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `min_world_micro i64 x/y/z` | 世界微格坐标可为负且范围大，`i64` 留足空间。 | 包围盒最小角，包含该点。 |
| `max_world_micro i64 x/y/z` | 与最小角同类型，避免混合坐标精度。 | 包围盒最大角，使用半开区间上界，不包含该点。 |

负坐标使用向下取整除法（结果向负无穷取整）/ 欧几里得余数（余数始终非负）。不同语言实现必须通过黄金样例（固定输入输出样例）对齐。

所有范围字段统一使用半开区间 `[min, max)`：包含 `min`，不包含 `max`。`bounds_chunk_min/max`、`AabbI64.min/max_world_micro`、`covered_macro_min/max`、`DirtyMacroBounds.min/max_macro` 都遵守这个规则。区域拆分或合并后必须满足无重叠；如果设计允许空洞，必须显式写出空洞区域，否则默认要求无空洞。

## 5. 区块真相结构

### 5.1 CellMode

```text
enum CellMode : u8 {
  Empty      = 0,
  SolidBlock = 1,
  Refined    = 2
}
```

字段说明：

| 值 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `Empty = 0` | `u8` 枚举紧凑，便于放入 4096 个宏格头。 | 宏格为空。 |
| `SolidBlock = 1` | 同上。 | 宏格是单一材质普通块。 |
| `Refined = 2` | 同上。 | 宏格使用 512 微格细分数据。 |

### 5.2 MacroCellHeader

每个区块固定 4096 个头，重负载数据放池中。

```text
MacroCellHeader {
  mode              u8
  flags             u16
  payload_index     u32   // normal_blocks 或 refined_cells；0xFFFF_FFFF = 无
  environment_index u32   // environment_summaries；0xFFFF_FFFF = 无
  cell_version      u32
  cell_hash         u32
}
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `mode u8` | 仅 3 种模式，`u8` 足够且紧凑。 | 决定该宏格读取哪个载荷池（同一类可变载荷数组）。 |
| `flags u16` | 16 位可容纳当前脏标记（已变化待处理）和后续扩展。 | 快速标记落盘、网格、规则、来源追踪（记录格子来自哪个对象/部件）等状态。 |
| `payload_index u32` | 池索引（指向可变载荷数组的下标）可能超过 65535，`u32` 保守且跨语言简单。 | 指向 `normal_blocks` 或 `refined_cells`；`0xFFFF_FFFF` 表示无。 |
| `environment_index u32` | 与载荷索引统一，支持稀疏环境摘要池。 | 指向 `environment_summaries`；`0xFFFF_FFFF` 表示无。 |
| `cell_version u32` | 单个宏格本地版本使用 `u32` 足够，区块级仍有 `u64`。 | 拒绝基于旧格子状态的意图。 |
| `cell_hash u32` | 宏格级快速校验不需要 64 位。 | 客户端已知引用、局部增量（只含变化）合并和排障。 |

`flags` 位义：

| bit | 名称 | 含义 |
| --- | --- | --- |
| `0x0001` | `DirtyStorage` | 需要落盘 |
| `0x0002` | `DirtyMesh` | 需要网格/碰撞重建 |
| `0x0004` | `DirtyRules` | 需要规则帧 |
| `0x0008` | `BoundaryTouched` | 影响相邻区块边界 |
| `0x0010` | `HasObjectProvenance` | 格子/微格可回溯到对象/部件 |
| `0x0020` | `HasAttributeOverride` | 存在属性覆盖 |
| `0x0040` | `HasTagOverride` | 存在标签覆盖 |

### 5.3 NormalBlockData

普通块占满一个宏格。固定头只保存高频真相；扩展属性和魔法标签走驻留池（本区块/快照里的共享目录，只存一份属性或标签集合，格子里只保存引用编号）。

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

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `material_id u16` | 第一版材质目录远小于 65535；`u16` 可显著压缩热路径（高频执行路径）。 | 指向材质目录。 |
| `state_flags u32` | 普通块状态需要位集（用二进制位表示多个布尔标记），`u32` 给燃烧、冻结、裂解等扩展位。 | 保存运行时状态标记。 |
| `health u16` | 方块耐久通常可量化到 `0..65535`。 | 破坏、修复、结构规则使用。 |
| `temperature_delta i16` | 温度偏移需要正负值，`i16` 足够表达量化变化。 | 相对默认温度的局部变化。 |
| `moisture_delta i16` | 湿度偏移同样需要正负量化。 | 相对默认湿度的局部变化。 |
| `attribute_set_ref u32` | 属性集合驻留池（共享目录）可能跨对象/材质复用，`u32` 足够且紧凑。 | 指向属性集合；0 表示材质默认。 |
| `tag_set_ref u32` | 标签集合驻留池（共享目录）与属性集合一致。 | 指向标签集合；0 表示材质默认。 |

固定线格式（网络/落盘二进制布局）为 20 字节。`attribute_set_ref` 和 `tag_set_ref` 是后续自身属性、魔法标签、特殊材质响应的稳定扩展点。

### 5.4 RefinedCellData

细分格表示一个宏格内 512 个微格槽。线格式（网络/落盘二进制布局）v1 使用“层 + mask（位掩码，每一位代表一个微格是否被覆盖）”压缩。

```text
RefinedCellData {
  occupancy_words   u64[8]
  layers            MicroLayer[]
  object_refs       ObjectCoverRef[]
  boundary_cache    u64
}

MicroLayer {
  mask_words        u64[8]
  material_id       u16
  state_flags       u32
  health            u16
  attribute_set_ref u32
  tag_set_ref       u32
  owner_object_id   u64  // 0 = 地形/无对象
  owner_part_id     u32  // 0 = 无部件
}

ObjectCoverRef {
  owner_object_id   u64
  owner_part_id     u32
  mask_words        u64[8]
}
```

`RefinedCellData` 是一个宏格内部的微格真相。一个宏格固定拆成 `8 x 8 x 8 = 512` 个微格，所以所有微格 mask（位掩码，每一位代表一个微格是否被覆盖）都用 `u64[8]` 表示：8 个 64 位字刚好覆盖 512 位，能用按位运算快速做占用、碰撞、重叠、边界和合并判断。

`RefinedCellData` 字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `occupancy_words u64[8]` | 512 个微格刚好对应 8 个 `u64`；比数组布尔值紧凑，也便于 CPU 按位运算。 | 该宏格的总占用 mask（位掩码），是所有层 `mask_words` 的并集。用于快速判断空/非空、碰撞、重叠和是否需要渲染。 |
| `layers MicroLayer[]` | 一个细分格可能包含不同材质/状态/来源的多个稀疏层，变长数组避免为每个微格重复写完整属性。 | 保存每组共享材质、状态、属性、标签、所有者的微格集合。 |
| `object_refs ObjectCoverRef[]` | 对象来源追踪是可选且稀疏的；变长数组只为有对象覆盖的部分付费。 | 快速查询一个对象/部件覆盖了哪些微格，支持删除对象、爆炸溯源、审计和 prefab 回滚。 |
| `boundary_cache u64` | 边界摘要可从层数据重建，但缓存成 `u64` 能降低吸附、邻区摘要、AOI（关注区域）过滤的热路径（高频执行路径）成本。 | 保存边界/接触相关摘要，用于快速判断是否可能与相邻格或 prefab 发生接触。 |

细分格不再单独维护 `local_version`；宏格级新旧判断统一使用 `MacroCellHeader.cell_version`，避免同一格子出现两个版本源造成漂移。

`MicroLayer` 字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `mask_words u64[8]` | 与 `occupancy_words` 同形，便于按位合并和比较。 | 该层覆盖的微格集合；每一位代表一个微格。 |
| `material_id u16` | 与普通块材质类型一致。 | 该层微格的材质。 |
| `state_flags u32` | 与普通块状态位一致，方便规则复用。 | 保存燃烧、冻结、裂解等状态。 |
| `health u16` | 与普通块耐久一致。 | 微格层耐久。 |
| `attribute_set_ref u32` | 与普通块属性集合引用一致。 | 指向该层的属性集合。 |
| `tag_set_ref u32` | 与普通块标签集合引用一致。 | 指向该层的标签集合。 |
| `owner_object_id u64` | 对象是长期全局实体，使用 `u64`。 | 表明该层来自哪个对象；0 表示地形或无对象。 |
| `owner_part_id u32` | 部件只在对象内部唯一，`u32` 足够。 | 表明该层来自对象的哪个部件；0 表示无部件。 |

`ObjectCoverRef` 字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `owner_object_id u64` | 与 `MicroLayer.owner_object_id` 一致。 | 被索引的对象。 |
| `owner_part_id u32` | 与 `MicroLayer.owner_part_id` 一致。 | 被索引的部件。 |
| `mask_words u64[8]` | 直接保存覆盖 mask（位掩码），避免扫描所有 layer。 | 该对象/部件在当前宏格内覆盖的微格集合。 |

规则：

1. `occupancy_words` 是所有 `layers.mask_words` 的按位 OR（逐位或）。
2. 同一个微格槽在同一个格子内只能归属一个有效层。
3. prefab / 组合体写入区块真相时必须保留 `owner_object_id / owner_part_id`。
4. 多个微格槽共享同一材料、状态、属性、标签和所有者时应合并成一个层。

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

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `default_temperature i16` | 环境基线需要正负量化，`i16` 足够。 | 宏格默认温度。 |
| `default_moisture i16` | 湿度也用同一量化宽度。 | 宏格默认湿度。 |
| `current_temperature i16` | 当前值与默认值同类型，便于差值计算。 | 规则系统当前温度。 |
| `current_moisture i16` | 当前湿度同上。 | 规则系统当前湿度。 |
| `field_mask u16` | 环境场数量有限，`u16` 作为有效位集合（用二进制位表示字段是否有效）。 | 标记哪些环境字段有效或被覆盖。 |
| `source_hash u32` | 环境来源摘要局部使用，`u32` 足够。 | 判断环境摘要是否变化。 |

体素效果管线读取权威环境/状态数据：温度足够高才进入点燃态，湿度/材质/标签会影响燃烧或冻结结果。

### 5.6 ChunkStorage

```text
ChunkStorage {
  schema_version        u16
  logical_scene_id              u64
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

ChunkObjectRef {
  object_id             u64
  object_version        u64
  covered_macro_min     u8 x, u8 y, u8 z
  covered_macro_max     u8 x, u8 y, u8 z
  cover_hash            u64
}

DirtyMacroBounds {
  min_macro             u8 x, u8 y, u8 z
  max_macro             u8 x, u8 y, u8 z
  reason_flags          u16
}
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `schema_version u16` | 存储格式版本数量有限。 | 控制解码和迁移。 |
| `logical_scene_id u64` | 与场景主键一致。 | 所属场景。 |
| `chunk_coord ChunkCoord` | 三维区块坐标。 | 标识区块位置。 |
| `chunk_size_in_macro u8` | 第一版固定 16，保留字段用于显式校验。 | 声明区块边长。 |
| `micro_resolution u8` | 第一版固定 8，保留字段用于协议协商。 | 声明每宏格微格精度。 |
| `chunk_version u64` | 区块长期更新，需单调大版本。 | 快照（完整状态）/增量（只含变化）排序和过期检测。 |
| `flags u32` | 区块级位集（用二进制位表示多个布尔标记）。 | 标记区块脏（已变化待处理）、锁定、迁移等状态。 |
| `macro_headers MacroCellHeader[4096]` | `16^3` 固定长度，随机访问稳定。 | 每个宏格的固定头。 |
| `normal_blocks NormalBlockData[]` | 普通块载荷稀疏池。 | 存普通块高频数据。 |
| `refined_cells RefinedCellData[]` | 细分格载荷稀疏池。 | 存微格真相。 |
| `environment_summaries MacroEnvironmentSummary[]` | 环境摘要稀疏池。 | 存规则环境数据。 |
| `object_refs ChunkObjectRef[]` | 对象覆盖是稀疏信息。 | 区块级对象/部件摘要。 |
| `attribute_sets VoxelAttributeSet[]` | 快照内联（随快照一起发送）所需属性集合。 | 客户端解释格子属性。 |
| `tag_sets VoxelTagSet[]` | 快照内联（随快照一起发送）所需标签集合。 | 客户端解释标签语义。 |
| `dirty_bounds DirtyMacroBounds` | 脏范围（已变化待重建/待落盘的范围）比全区块更小，独立记录可节省重建。 | 网格、碰撞、落盘、规则重算的最小范围。 |
| `ChunkObjectRef.object_id u64` | 对象是长期全局实体。 | 指明区块内引用的对象。 |
| `ChunkObjectRef.object_version u64` | 对象长期更新，需要单调大版本。 | 客户端判断对象摘要是否过期。 |
| `ChunkObjectRef.covered_macro_min/max u8 x/y/z` | 区块内宏格坐标范围是 `0..16` 的半开上界，`u8` 足够。 | 对象在当前区块覆盖的半开区间 `[min, max)` 宏格包围盒。 |
| `ChunkObjectRef.cover_hash u64` | 覆盖摘要用于快速一致性校验。 | 判断对象覆盖关系是否变化。 |
| `DirtyMacroBounds.min/max_macro u8 x/y/z` | 脏范围只在区块内部，`u8` 足够。 | 需要重建/落盘/规则重算的半开区间 `[min, max)` 宏格范围。 |
| `DirtyMacroBounds.reason_flags u16` | 原因是位集（用二进制位表示多个脏原因）。 | 区分网格、碰撞、规则、落盘等触发原因。 |

快照可以内联（随快照一起发送）本次用到的属性/标签集合，避免客户端收到格子后缺少解释数据。

## 6. 属性与标签

### 6.1 VoxelAttributeSet

属性集合是驻留化、版本化、可复用的数据。它表达方块自身属性、对象覆盖、魔法响应参数和结构参数。

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

VoxelAttributeCatalogEntry {
  attribute_id      u16
  name              string
  value_kind        u8
  flags             u32
}
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `attribute_set_id u32` | 属性集合是驻留池（共享目录）项，`u32` 足够。 | 属性集合编号。 |
| `schema_version u16` | 属性结构版本少。 | 控制兼容解码。 |
| `base_material_id u16` | 与材质 id 一致。 | 指明默认材质来源。 |
| `scalar_count u16` | 单集合标量属性数量有限。 | 后续 `scalar_entries` 长度。 |
| `scalar_entries AttributeScalar[]` | 变长数组只存实际存在的属性。 | 标量属性列表。 |
| `resource_count u16` | 资源属性数量有限。 | 后续 `resource_entries` 长度。 |
| `resource_entries AttributeResource[]` | 变长数组只存实际存在的资源。 | 耐久、能量、充能等资源型属性。 |
| `resistance_mask u64` | 抗性/免疫适合位集（用二进制位表示多个抗性标记）。 | 快速判断元素或规则抗性。 |
| `AttributeScalar.attribute_id u16` | 属性目录数量预计远小于 65535。 | 标量属性类型。 |
| `AttributeScalar.value_q16 i32` | Q16 定点数（用整数存小数，低 16 位表示小数部分）跨语言确定性强，`i32` 可表达正负。 | 标量属性值。 |
| `AttributeResource.resource_id u16` | 资源目录小。 | 资源类型。 |
| `AttributeResource.current_q16/max_q16 i32` | 与标量值同量化，便于规则计算。 | 当前值和上限。 |
| `VoxelAttributeCatalogEntry.attribute_id u16` | 与属性引用同类型。 | 唯一标识一个属性。 |
| `VoxelAttributeCatalogEntry.name string` | 人类可读名称必须可扩展。 | 调试、编辑器、CLI 和审计显示。 |
| `VoxelAttributeCatalogEntry.value_kind u8` | 属性值类型是小枚举。 | 区分 q16、枚举、位集、资源等解释方式。 |
| `VoxelAttributeCatalogEntry.flags u32` | 属性元信息适合位集。 | 标记是否客户端可见、是否可继承、是否参与规则等。 |

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
| `9` | `element_affinity` | 元素倾向位集（用二进制位表示多个倾向）/枚举 |
| `10` | `structural_support` | 支撑/承重规则 |
| `11` | `structure_integrity` | 当前结构完整度 |

新增属性时扩展目录，不改 `NormalBlockData` 和 `MicroLayer` 固定头。

### 6.2 VoxelTagSet

魔法标签和玩法标签必须驻留化，不能在区块内重复写字符串。

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

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `tag_set_id u32` | 标签集合驻留池（共享目录）编号。 | 引用一组标签。 |
| `schema_version u16` | 标签结构版本。 | 控制兼容解码。 |
| `tag_count u16` | 单组标签数量有限。 | 后续 `tag_ids` 长度。 |
| `tag_ids u32[]` | 标签目录可能跨命名空间增长，`u32` 保守。 | 标签 id 列表。 |
| `tag_id u32` | 全局标签编号。 | 唯一标识标签。 |
| `namespace_id u16` | 命名空间数量有限。 | 区分 magic / terrain / structure 等域。 |
| `name string` | 人类可读名称必须可扩展。 | 标签名称。 |
| `flags u32` | 标签元信息位集（用二进制位表示多个布尔标记）。 | 标记是否可继承、是否客户端可见等。 |

示例标签：

```text
magic.fire_conductive
magic.ice_resonant
magic.mana_storage
terrain.natural
structure.player_built
prefab.stairs
part.step_mid
```

建造合法性第一版由地块权限、排他占用（同一空间范围只允许一个事务占用）、几何占用、资源和规则决定；tag 用于玩法语义、技能响应、过滤、UI、审计和配方。

## 7. 地块与建设模型

MMO 建设不直接暴露任意 `set block`。玩家先拥有或获得地块授权，再提交建设意图。

```text
ParcelClaim {
  parcel_id           u64
  logical_scene_id            u64
  region_id           u64
  owner_scene_instance_ref     u64
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

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `parcel_id u64` | 地块是长期持久对象。 | 地块编号。 |
| `logical_scene_id u64` | 与场景主键一致。 | 所属场景。 |
| `region_id u64` | 与区域账本一致。 | 所属区域。 |
| `owner_scene_instance_ref u64` | 与租约写入栅栏（旧世代拒写条件）一致。 | 当前热所有者。 |
| `owner_epoch u64` | 与写入世代一致。 | 拒绝旧所有者修改地块。 |
| `owner_account_id u64` | 账号是长期全局对象。 | 玩家/公会/系统归属。 |
| `bounds_chunk_min/max ChunkCoord` | 地块按区块边界粗定位。 | 地块半开区间 `[min, max)` 范围。 |
| `permission_mask u64` | 权限天然是位集（用二进制位表示多个权限开关），`u64` 足够扩展。 | 建造、破坏、交互、管理权限。 |
| `build_epoch u64` | 建设队列需要长期单调世代。 | 拒绝基于旧建设状态的事务。 |
| `version u64` | 地块记录版本。 | 缓存失效和审计。 |
| `reservation_id u64` | 保留事务需要全局唯一。 | 排他施工保留（临时锁定建设范围）编号。 |
| `actor_id u64` | 角色/行为者全局编号。 | 谁发起保留。 |
| `bounds_world_micro AabbI64` | 建设范围按世界微格表达，可跨区块且支持负坐标。 | 排他占用范围（同一范围不能同时被多个建设事务占用）。 |
| `expires_at_ms u64` | 毫秒时间戳稳定。 | 保留超时释放。 |
| `intent_hash u64` | 快速比较请求内容。 | 幂等（重复提交同一请求不会产生重复效果）、排障和重复提交识别。 |

放置 prefab/object 的服务器流程：

1. Gate / Scene 收到意图后按 `scene_instance_ref` 交给 `WorldServer.ParcelAuthority`。
2. World 校验角色已进入场景，且对地块有权限。
3. World 校验蓝图可用、版本匹配、资源/冷却/建设队列满足。
4. World 根据 `anchor_world_micro + rotation` 计算受影响区块，并从分配表找到涉及的 Scene。
5. World 创建 `reservation_id + transaction_id`，并为每个参与租约绑定 `lease_id + owner_scene_instance_ref + owner_epoch`，向相关 Scene 发 `PrepareBuild`。
6. Scene 本地校验几何占用、碰撞、区块版本、对象状态、边界缓冲带（邻区只读摘要）。
7. 全部 `prepare_ok` 后 World 发 `CommitBuild`；任一失败则 `AbortBuild`。
8. Scene 提交自己负责的区块增量，写入对象来源追踪（记录格子来自哪个对象/部件），并返回确认。
9. World 更新地块 `build_epoch`、区块摘要和全局账本。
10. 客户端收到 `ObjectStateDelta / ChunkDelta / VoxelIntentResult` 后更新已确认体素存储。

客户端在第 1 步前可以显示选址线框，但不能把对象写入已确认体素存储。

## 8. 蓝图 / 对象 / 来源追踪

```text
BlueprintDefinition
  可复用模板：占用、部件、插槽、材质通道、默认属性、默认标签。

SceneObjectInstance
  一个已放置对象/组合体：object_id、blueprint_id、锚点、旋转、所有者、状态、对象版本。

ChunkTruth
  用于权威、碰撞、网格生成、规则和持久化的扁平占用。
  每个微格层保留 owner_object_id + owner_part_id。
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

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `blueprint_id u64` | 蓝图是长期可复用对象。 | 蓝图编号。 |
| `version u32` | 单蓝图版本局部增长，`u32` 足够。 | 拒绝旧蓝图放置。 |
| `source_kind u8` | 来源种类是小枚举。 | 区分内置、玩家创建、运营配置等。 |
| `owner_account_id u64` | 与账号 id 一致。 | 蓝图归属。 |
| `bounds_macro u16 x/y/z` | 蓝图尺寸通常远小于 65535 宏格。 | 蓝图宏格包围盒。 |
| `micro_resolution u8` | 与区块精度一致。 | 蓝图栅格精度。 |
| `allowed_rotations u16` | 旋转集合适合位集（用二进制位表示允许哪些旋转）。 | 可用旋转方向。 |
| `default_tag_set_ref u32` | 与标签集合引用一致。 | 蓝图默认标签。 |
| `part_definitions PartDefinition[]` | 部件数量可变。 | 蓝图部件树。 |
| `occupancy_layers BlueprintLayer[]` | 占用层可变。 | 蓝图实际体素占用。 |
| `sockets BlueprintSocket[]` | 插槽是可选语义。 | 语义连接点。 |
| `boundary_signature u64[]` | 边界摘要可按面/段拆分。 | 快速吸附和兼容性预判。 |
| `part_id u32` | 部件在蓝图内唯一，`u32` 足够。 | 部件编号。 |
| `parent_part_id u32` | 与 `part_id` 同类型。 | 部件层级。 |
| `name string` | 人类可读。 | 调试、编辑器和审计显示。 |
| `default_attribute_ref/tag_ref u32` | 与驻留池（共享目录）引用一致。 | 部件默认属性/标签。 |
| `flags u32` | 部件元信息位集（用二进制位表示多个布尔标记）。 | 是否可破坏、是否承重、是否可交互等。 |
| `local_macro_offset i16 x/y/z` | 蓝图局部偏移需要正负，通常小于 32767。 | 层所在宏格偏移。 |
| `mask_words u64[8]` | 与微格 mask（位掩码）统一。 | 该层局部微格占用。 |
| `material_channel u16` | 材质通道数量有限。 | 放置时映射实际材质。 |
| `socket_id u32` | 插槽在蓝图内唯一。 | 连接点编号。 |
| `local_micro_coord i32 x/y/z` | 插槽可位于蓝图局部微格空间，需正负。 | 插槽位置。 |
| `normal i8 x/y/z` | 法线只需 `-1/0/1`。 | 插槽朝向。 |
| `compatible_tag_ref u32` | 引用标签集合或标签目录。 | 兼容性过滤。 |
| `priority u16` | 小范围排序值。 | 多插槽匹配时排序。 |

### 8.2 SceneObjectInstance

```text
SceneObjectInstance {
  object_id             u64
  blueprint_id          u64
  blueprint_version     u32
  logical_scene_id              u64
  parcel_id             u64
  anchor_world_micro    i64 x, i64 y, i64 z
  rotation              u8
  owner_actor_id        u64
  state_flags           u32
  object_attribute_ref  u32
  object_tag_set_ref    u32
  covered_chunk_count   u16
  covered_chunks        ChunkCoord[]
  object_version        u64
}
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `object_id u64` | 场景对象长期持久。 | 对象编号。 |
| `blueprint_id u64` | 引用蓝图。 | 对象模板来源。 |
| `blueprint_version u32` | 与蓝图版本一致。 | 放置时模板版本。 |
| `logical_scene_id u64` | 所属场景。 | 路由和持久化分区。 |
| `parcel_id u64` | 所属地块。 | 权限和归属判断。 |
| `anchor_world_micro i64 x/y/z` | 世界微格坐标可为负且范围大。 | 对象锚点。 |
| `rotation u8` | 旋转枚举数量小。 | 对象旋转。 |
| `owner_actor_id u64` | 行为者全局编号。 | 创建者或当前操作者。 |
| `state_flags u32` | 对象状态位集（用二进制位表示多个状态开关）。 | 开关、破坏、激活、燃烧等状态。 |
| `object_attribute_ref/tag_ref u32` | 驻留池（共享目录）引用。 | 对象级属性/标签覆盖。 |
| `covered_chunk_count u16` | 单对象覆盖区块数量有限。 | 后续 `covered_chunks` 长度。 |
| `covered_chunks ChunkCoord[]` | 对象可跨区块。 | 快速订阅、删除、迁移和落盘。 |
| `object_version u64` | 对象长期更新。 | 对象状态增量顺序。 |

后续门、机关、魔法阵、玩家建筑都挂在对象/部件语义上，而不是降级成匿名材料格。

## 9. 状态与破坏模型

体素状态变化由服务器规则系统计算。客户端只播放角色侧技能表现，等待服务器下发世界结果。

```text
SkillCast / CombatEvent
  -> 服务端校验角色资源、冷却、命中、区域
  -> SceneServer.Voxel 计算热量/湿度/冲击/结构变化
  -> 服务端发出 VoxelStateDelta / ObjectStateDelta / ChunkDelta
  -> 客户端更新已确认体素数据
  -> 渲染/效果系统推导燃烧/冻结/裂纹/破坏表现
```

建议事件：

```text
VoxelStateDelta {
  logical_scene_id            u64
  chunk_coord         ChunkCoord
  chunk_version       u64
  macro_index         u16
  state_flags         u32
  environment_summary MacroEnvironmentSummary
  attribute_patch     AttributePatch[]
  tag_patch           TagPatch[]
}

ObjectStateDelta {
  logical_scene_id            u64
  object_id           u64
  object_version      u64
  state_flags         u32
  attribute_patch     AttributePatch[]
  tag_patch           TagPatch[]
  affected_chunks     ChunkCoord[]
}

DestructionEvent {
  event_id            u64
  logical_scene_id            u64
  source_actor_id     u64  // 服务端注入，客户端不得提交
  source_skill_id     u32
  affected_chunks     ChunkCoord[]
  result_hash         u64
}

AttributePatch {
  attribute_id        u16
  patch_kind          u8
  value_q16           i32
}

TagPatch {
  tag_id              u32
  patch_kind          u8
}
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `logical_scene_id u64` | 与场景主键一致。 | 路由到场景。 |
| `chunk_coord ChunkCoord` | 区块坐标。 | 定位变更区块。 |
| `chunk_version u64` | 与区块版本一致。 | 增量顺序。 |
| `macro_index u16` | 4096 宏格可由 `u16` 表示。 | 定位宏格。 |
| `state_flags u32` | 状态位集（用二进制位表示多个状态开关）。 | 表示燃烧、冻结、破坏等状态变化。 |
| `environment_summary MacroEnvironmentSummary` | 直接复用环境摘要结构。 | 下发规则环境变化。 |
| `attribute_patch/tag_patch []` | 补丁数量可变。 | 增量修改属性和标签。 |
| `object_id u64` | 场景对象长期持久。 | 指明被更新的对象。 |
| `object_version u64` | 对象长期更新，需要单调大版本。 | 客户端排序对象状态增量。 |
| `affected_chunks ChunkCoord[]` | 对象或破坏可能跨区块。 | 客户端更新和审计范围。 |
| `event_id u64` | 事件全局唯一。 | 审计和去重。 |
| `source_actor_id u64` | 行为者全局编号，只能由服务端会话/战斗系统注入。 | 追踪来源。 |
| `source_skill_id u32` | 技能目录局部编号。 | 追踪触发技能。 |
| `result_hash u64` | 快速校验结果确定性。 | 回放、审计和排障。 |
| `AttributePatch.attribute_id u16` | 属性目录数量预计远小于 65535。 | 指定要修改的属性。 |
| `AttributePatch.patch_kind u8` | 补丁种类是小枚举。 | 表示设置、增加、减少、清除等修改方式。 |
| `AttributePatch.value_q16 i32` | 与属性值使用同一 Q16 定点数（整数存小数）格式。 | 补丁值。 |
| `TagPatch.tag_id u32` | 标签目录可能跨命名空间增长。 | 指定要修改的标签。 |
| `TagPatch.patch_kind u8` | 补丁种类是小枚举。 | 表示添加或移除标签。 |

`DestructionEvent` 是表现和审计事件；真正几何改变仍在 `ChunkDelta` 中。

## 10. 服务端运行时

### 10.1 SceneServer.Voxel.ChunkProcess

```elixir
%SceneServer.Voxel.ChunkProcess.State{
  logical_scene_id: logical_scene_id,
  coord: {cx, cy, cz},
  storage: %SceneServer.Voxel.Storage{},
  version: non_neg_integer(),
  subscribers: %{client_ref => subscription_meta},
  dirty_since_ms: integer | nil,
  pending_journal: :queue.queue()
}
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `logical_scene_id` | Elixir 内部使用整数即可，外部编码仍按 `u64`。 | 所属场景。 |
| `coord {cx, cy, cz}` | Elixir 元组易读且匹配 `ChunkCoord`。 | 区块坐标。 |
| `storage %SceneServer.Voxel.Storage{}` | 结构化存储避免裸 map 漂移。 | 当前区块真相。 |
| `version non_neg_integer()` | BEAM 内部整数无固定宽度。 | 运行时版本。 |
| `subscribers %{client_ref => subscription_meta}` | map 适合动态订阅集合。 | 客户端订阅表。 |
| `dirty_since_ms integer | nil` | `nil` 表示干净，有值表示开始变脏（内存已变化但尚未落盘）时间。 | 落盘调度。 |
| `pending_journal :queue.queue()` | 队列适合顺序追加/批量刷写。 | 待写审计日志流水。 |

职责：

1. 惰性加载 / 初始化区块。
2. 应用建设事务、状态帧、影响结果、对象状态变更。
3. 拒绝过期意图、无权限意图、非法占用意图。
4. 生成 `ChunkSnapshot / ChunkDelta / VoxelIntentResult`。
5. 给移动、战斗、NPC、技能系统提供占用/碰撞/射线查询。
6. 批量落盘到 DataService。

### 10.2 跨区块 / 跨场景事务

Prefab/object 放置和爆炸破坏都可能覆盖多个区块，甚至跨多个 Scene 租约。第一版使用 World 协调的确定性事务：

```text
BuildTransaction {
  transaction_id            u64
  logical_scene_id          u64
  parcel_id                 u64
  reservation_id            u64
  state                     u8
  participant_count         u16
  participants              TransactionParticipant[]
  intent_hash               u64
  decision_version          u64
  timeout_at_ms             u64
}

TransactionParticipant {
  region_id                 u64
  lease_id                  u64
  owner_scene_instance_ref  u64
  owner_epoch               u64
  affected_chunks           ChunkCoord[]
  prepare_status            u8
  commit_status             u8
  last_ack_ms               u64
}
```

`BuildTransaction` 字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `transaction_id u64` | 跨 Scene 事务需要全局唯一编号。 | 幂等、日志恢复和参与方确认。 |
| `logical_scene_id u64` | 与目标逻辑场景一致。 | 事务所属场景分区。 |
| `parcel_id u64` | 与地块主键一致。 | 事务涉及的地块。 |
| `reservation_id u64` | 与施工保留一致。 | 关联排他保留。 |
| `state u8` | 事务状态是小枚举。 | `preparing / prepared / committing / committed / aborting / aborted / recovering`。 |
| `participant_count u16` | 参与租约数量有限；同一 Scene 拥有多个区域时按租约拆成多项。 | 后续 `participants` 长度。 |
| `participants TransactionParticipant[]` | 跨 Scene / 跨租约参与方数量可变。 | 记录每个参与租约的准备/提交状态。 |
| `intent_hash u64` | 与客户端或服务端意图摘要一致。 | 重试幂等和排障。 |
| `decision_version u64` | 事务决议需要单调版本。 | 崩溃恢复时识别最新 commit/abort 决议。 |
| `timeout_at_ms u64` | 毫秒时间戳跨语言稳定。 | 超时自动中止或进入恢复。 |
| `TransactionParticipant.region_id u64` | 与区域账本主键一致。 | 指明参与事务的区域。 |
| `TransactionParticipant.lease_id u64` | 与 SceneLease 同类型。 | 绑定参与方的当前写入授权。 |
| `TransactionParticipant.owner_scene_instance_ref u64` | 与租约所有者引用一致。 | 指定参与事务的热运行实例。 |
| `TransactionParticipant.owner_epoch u64` | 与写入世代一致。 | 确保该参与方只在当前租约世代提交。 |
| `TransactionParticipant.affected_chunks ChunkCoord[]` | 单参与方可能负责多个区块。 | 参与方本地 prepare/commit 的范围。 |
| `TransactionParticipant.prepare_status/commit_status u8` | 状态是小枚举。 | 记录未开始、成功、失败、过期、已重放等状态。 |
| `TransactionParticipant.last_ack_ms u64` | 毫秒时间戳跨语言稳定。 | 判断参与方是否卡住或需要重试。 |

World 必须先把 `BuildTransaction` 和最终 `Commit/Abort` 决议写入可恢复日志，再向 Scene 发命令。Scene 的 `PrepareBuild` 和 `CommitBuild` 都必须按 `transaction_id + decision_version` 幂等：重复收到相同命令只能重放同一结果，不能再次应用。World 或 Scene 崩溃后按事务日志恢复：已有 commit 决议则继续重放 commit，已有 abort 决议则继续重放 abort，只有还没有决议且超时的 prepared 事务才能转 abort。保留锁只在 committed 或 aborted 被所有存活参与方确认后释放；参与方不可用时由 World 标记恢复任务并阻止相关范围的新事务。

1. World 根据分配表找到所有受影响 Scene。
2. World 创建并持久化 `BuildTransaction`，按 `{logical_scene_id, region_id, chunk_coord}` 排序要求相关 Scene `Prepare`。
3. 每个 Scene 只校验自己当前租约内的区块，并检查参与方的 `lease_id + owner_scene_instance_ref + owner_epoch`。
4. 任一 Scene 返回失败、过期或世代不匹配，World 全体 `Abort`。
5. 全部成功后，World 先持久化 commit 决议，再按同样顺序发 `Commit`。
6. Scene 各自提交区块增量 / 对象增量（都只包含变化），并携带当前 `lease_id + owner_scene_instance_ref + owner_epoch` 向 World 回报区块摘要。
7. World 更新地块/建造世代、分配摘要和事务日志流水。

不允许 prefab 半落地，也不允许爆炸只改掉一半区块。

普通跨边界规则传播不走 World 事务，而走 Scene 间边界事件队列：

```text
BoundaryVoxelEvent {
  event_id                  u64
  logical_scene_id          u64
  source_region_id          u64
  target_region_id          u64
  source_lease_id           u64
  target_lease_id           u64
  source_scene_instance_ref u64
  target_scene_instance_ref u64
  source_owner_epoch        u64
  target_owner_epoch        u64
  boundary_chunks           ChunkCoord[]
  event_kind                u16
  payload_hash              u64
  payload                   bytes
}
```

`BoundaryVoxelEvent` 字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `event_id u64` | 边界事件需要幂等去重。 | 唯一标识一次跨边界传播。 |
| `logical_scene_id u64` | 与场景路由一致。 | 所属逻辑场景。 |
| `source_region_id/target_region_id u64` | 与区域账本主键一致。 | 指明边界两侧区域。 |
| `source_lease_id/target_lease_id u64` | 与 SceneLease 同类型。 | 绑定边界事件两侧的当前租约。 |
| `source_scene_instance_ref/target_scene_instance_ref u64` | 与租约所有者引用一致。 | 指明来源和目标 Scene 实例。 |
| `source_owner_epoch u64` | 与写入世代一致。 | 目标 Scene 拒绝旧世代边界事件。 |
| `target_owner_epoch u64` | 与目标写入世代一致。 | 目标 Scene 确认事件仍投递给当前目标租约。 |
| `boundary_chunks ChunkCoord[]` | 事件可能影响多个边界区块。 | 限定目标检查范围。 |
| `event_kind u16` | 规则事件种类有限。 | 区分燃烧、冻结、流体、结构应力等传播类型。 |
| `payload_hash u64` | 载荷摘要用于快速去重。 | 校验和排障。 |
| `payload bytes` | 不同规则载荷不同。 | 承载规则系统专用数据。 |

目标 Scene 必须按 `target_lease_id + target_scene_instance_ref + target_owner_epoch` 校验自己仍是目标区域当前所有者，并按缓存的 World 账本校验来源区域仍匹配 `source_lease_id + source_scene_instance_ref + source_owner_epoch`；任一不匹配都丢弃并记录 observe 事件。这样普通规则传播不进入 World 热路径，也不会把迁移前的边界事件写进迁移后的区域。

### 10.3 WorldServer.MapLedger / LeaseManager

World 侧需要一个明确的地图账本与租约管理边界：

```elixir
%WorldServer.Voxel.MapLedger.State{
  logical_scene_id: logical_scene_id,
  assignments: %{region_id => %MapRegionAssignment{}},
  parcels: %{parcel_id => %ParcelClaim{}},
  chunk_summaries: %{chunk_key => %ChunkSummary{}},
  leases: %{region_id => %SceneLease{}},
  migrations: %{migration_id => %MigrationPlan{}}
}
```

```text
MigrationPlan {
  migration_id         u64
  source_scene_instance_ref     u64
  target_scene_instance_ref     u64
  region_ids           u64[]
  target_owner_epoch   u64
  state                u8
  version              u64
}
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `logical_scene_id` | 运行时场景编号。 | 所属 World 账本上下文。 |
| `assignments %{region_id => %MapRegionAssignment{}}` | map 适合按区域快速查找。 | 区域分配表。 |
| `parcels %{parcel_id => %ParcelClaim{}}` | map 适合权限校验热路径（高频执行路径）。 | 地块账本。 |
| `chunk_summaries %{chunk_key => %ChunkSummary{}}` | map 适合区块摘要查询。 | 区块版本/哈希（内容摘要）/脏状态（已变化待处理）摘要。 |
| `leases %{region_id => %SceneLease{}}` | 与区域一一关联。 | 当前租约表。 |
| `migrations %{migration_id => %MigrationPlan{}}` | 迁移任务数量动态变化。 | 正在执行的迁移计划。 |
| `MigrationPlan.migration_id u64` | 迁移是长期可审计任务，`u64` 可全局唯一。 | 标识一次迁移。 |
| `MigrationPlan.source_scene_instance_ref/target_scene_instance_ref u64` | 与租约所有者引用同类型。 | 指明源 Scene 和目标 Scene。 |
| `MigrationPlan.region_ids u64[]` | 一次迁移可能包含多个区域。 | 要转移、分裂或合并的区域集合。 |
| `MigrationPlan.target_owner_epoch u64` | 与所有权世代同类型。 | 目标 Scene 获得的新写入世代。 |
| `MigrationPlan.state u8` | 迁移状态是小枚举。 | 表示准备、刷写、加载、校验、翻转、完成或失败。 |
| `MigrationPlan.version u64` | 迁移计划可能被重试/更新，需要大版本。 | 拒绝旧计划更新并支持审计。 |

职责：

1. 决定区域 / 区块当前由哪个 Scene 热运行（常驻内存并执行规则/订阅）。
2. 发放、续租、吊销 SceneLease。
3. 校验地块/归属权限和 `build_epoch`。
4. 协调跨 Scene 的建设和破坏事务。
5. 驱动区域转移、分裂、合并。
6. 维护区块摘要，供全局地图、远景、负载均衡和冷区恢复使用。

Scene 可以缓存 World 账本的一部分，但缓存不能成为长期权威。Scene 收到过期 `owner_epoch` 或租约被吊销后，必须停止写入并进入排空（等待在途事务完成或中止）/释放。

### 10.4 迁移流程

迁移只改变“某片区域由哪个 Scene 负责热运行（常驻内存并执行规则/订阅）”，不改变 DataService 中的持久化真相。常见三类：转移、分裂、合并。

#### 通用步骤

```text
World 标记迁移
  -> 旧 Scene 设置写入栅栏（拒绝旧世代继续写入的保护条件）
  -> 旧 Scene 排空（等待事务完成或中止）在途事务
  -> 旧 Scene 刷写脏区块（把已变化区块落盘）并上报版本/哈希（内容摘要）
  -> World 创建新的 owner_epoch 和目标租约
  -> 目标 Scene 加载快照并预热（先加载数据和索引再对外服务）边界缓冲带（邻区只读摘要）
  -> 目标 Scene 校验区块哈希（内容摘要）/版本
  -> World 翻转分配表
  -> Gate/客户端/AOI（关注区域）重订阅或重路由
  -> 旧 Scene 释放租约
```

关键规则：

1. 路由翻转前，旧 Scene 仍是该区域唯一写入者。
2. 路由翻转后，只有新 `owner_epoch` 的 Scene 能写。
3. 迁移区域进入 `migrating` 后不接受新的建设事务；已有事务要么完成，要么中止。
4. DataService / World 拒绝旧世代写入，防止双主写入。
5. 新 Scene 必须先预热（先加载数据和索引再对外服务）边界缓冲带（邻区只读摘要）、对象索引、碰撞和 AOI（关注区域），再对外开放订阅。

#### 转移

转移是一整块区域从 Scene A 移到 Scene B。

适用场景：

1. Scene A 负载过高。
2. 玩家或建筑热点需要挪到更空的节点。
3. 机器维护、缩容或故障隔离。

流程：

1. World 选择区域和目标 Scene B。
2. World 将区域状态改为 `migrating`，生成 `migration_id`。
3. Scene A 对区域加写入栅栏（旧世代拒写条件），停止新建设/破坏/状态写入。
4. Scene A 排空（等待事务完成或中止）在途事务并刷写脏区块（把已变化区块落盘）。
5. World 给 Scene B 发新租约和 `owner_epoch + 1`。
6. Scene B 从 DataService 加载区块/对象/地块，构建边界缓冲带（邻区只读摘要）和运行时索引。
7. Scene B 上报哈希（内容摘要）/版本校验通过。
8. World 翻转分配：区域所有者从 A 改为 B。
9. Gate 和客户端重订阅（重新订阅目标 Scene 的区块更新）到 B；Scene A 释放旧租约。

#### 分裂

分裂是一个 Scene 负责的大区域被拆成多个区域，分给多个 Scene。

示例：

```text
Scene A 拥有 R
拆分为：
  R1 -> Scene A
  R2 -> Scene B
  R3 -> Scene C
```

适用场景：

1. 大区域热点过多，单 Scene 规则帧或 AOI（关注区域）压力过高。
2. 建筑/燃烧/破坏模拟集中在不同子区域。
3. 希望按区块带、地块组或热点包围盒拆负载。

流程：

1. World 根据负载、玩家密度、地块边界和区块边界生成分裂计划。
2. 分裂边界优先贴合地块或区域边界，不切穿正在建设的地块。
3. World 标记 R 为 `migrating`，并创建 R1/R2/R3 的新分配。
4. Scene A 对将迁出的 R2/R3 加写入栅栏（旧世代拒写条件）；保留 R1 的正常热运行（常驻内存并执行规则/订阅）。
5. Scene A 刷写 R2/R3 脏区块（把已变化区块落盘）并上报摘要。
6. Scene B/C 加载各自区域，预热（先加载数据和索引再对外服务）边界缓冲带（邻区只读摘要）；A/B/C 互相持有边界只读摘要。
7. 全部校验通过后，World 翻转分配。
8. 跨边界建设和爆炸这类强一致写入走 World 协调事务；普通燃烧、冻结、流体等状态传播走 Scene 间边界事件队列，World 不进入规则帧热路径。边界本地规则只读边界缓冲带（邻区只读摘要），不私自写邻区。

#### 合并

合并是多个 Scene 负责的相邻区域收回到一个 Scene。

示例：

```text
Scene A 拥有 R1
Scene B 拥有 R2
Scene C 拥有 R3
合并为：
  Scene A 拥有 R1 + R2 + R3
```

适用场景：

1. 在线人数下降，热点消失，需要节省资源。
2. 多个区域之间跨边界事务过多。
3. 世界事件或大型建设需要更强局部一致性。

流程：

1. World 选择目标 Scene 和参与合并的区域。
2. 所有源 Scene 对各自区域加写入栅栏（旧世代拒写条件）。
3. 源 Scene 排空（等待在途事务完成或中止）/刷写，提交区块摘要。
4. 目标 Scene 加载完整合并区域，构建对象索引、碰撞、AOI（关注区域）和边界缓冲带（邻区只读摘要）。
5. World 用新的 `owner_epoch` 翻转所有分配到目标 Scene。
6. 客户端和 Gate 统一重订阅目标 Scene。
7. 源 Scene 释放租约，World 合并或归档旧区域记录。

## 11. 持久化

```text
voxel_chunks
  logical_scene_id              bigint
  coord_x/y/z           int
  schema_version        smallint
  chunk_size_in_macro   smallint
  micro_resolution      smallint
  lease_id              bigint
  owner_scene_instance_ref bigint
  owner_epoch           bigint
  chunk_version         bigint
  chunk_hash            bytea(8)
  data                  bytea
  updated_at            timestamptz
  unique(logical_scene_id, coord_x, coord_y, coord_z)

voxel_parcels
  parcel_id             bigint
  logical_scene_id              bigint
  region_id             bigint
  owner_scene_instance_ref       bigint
  owner_epoch           bigint
  owner_account_id      bigint
  bounds_data           bytea
  permission_mask       bigint
  build_epoch           bigint
  updated_at            timestamptz

voxel_region_assignments
  region_id             bigint
  logical_scene_id              bigint
  owner_scene_instance_ref       bigint
  owner_epoch           bigint
  state                 smallint
  bounds_data           bytea
  summary_hash          bytea(8)
  version               bigint
  updated_at            timestamptz

voxel_lease_write_tokens
  logical_scene_id              bigint
  region_id             bigint
  lease_id              bigint
  owner_scene_instance_ref bigint
  owner_epoch           bigint
  bounds_data           bytea
  expires_at            timestamptz
  token_version         bigint
  updated_at            timestamptz
  unique(logical_scene_id, region_id)

voxel_build_reservations
  reservation_id        bigint
  logical_scene_id              bigint
  parcel_id             bigint
  actor_id              bigint
  bounds_data           bytea
  expires_at            timestamptz
  intent_hash           bytea(8)
  state                 smallint
  updated_at            timestamptz
  unique(reservation_id)

voxel_build_transactions
  transaction_id        bigint
  logical_scene_id              bigint
  parcel_id             bigint
  reservation_id        bigint
  state                 smallint
  participant_count     smallint
  participants_data     bytea
  intent_hash           bytea(8)
  decision_version      bigint
  timeout_at            timestamptz
  updated_at            timestamptz
  unique(transaction_id)

voxel_scene_objects
  logical_scene_id              bigint
  object_id             bigint
  parcel_id             bigint
  blueprint_id          bigint
  blueprint_version     int
  object_version        bigint
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
  logical_scene_id              bigint
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

持久化字段说明：

线格式中的 `u64` 分两类处理：id / version / epoch 在 v1 必须限制为 `0..9_223_372_036_854_775_807`，可安全落到 PostgreSQL `bigint` 并加 `CHECK (field >= 0)`；需要查询的 `u64` 位集字段（如 `permission_mask`）第一版也限制使用低 63 位。哈希类 `u64` 是原始 64 位摘要，不做有符号数解释，持久化时使用 `bytea(8)`。

| 表 | 字段 | 类型选择理由 | 用途 |
| --- | --- | --- | --- |
| `voxel_chunks` | `logical_scene_id`, `coord_x/y/z`, `schema_version`, `chunk_size_in_macro`, `micro_resolution`, `lease_id`, `owner_scene_instance_ref`, `owner_epoch`, `chunk_version` | 可查询字段拆列，便于唯一索引、迁移筛选和写入令牌审计。 | 定位和版本化区块快照。 |
| `voxel_chunks` | `chunk_hash bytea(8)` | 哈希是原始 64 位摘要，不适合落 `bigint`。 | 保存区块内容摘要。 |
| `voxel_chunks` | `data bytea` | 完整区块结构二进制化，避免关系表拆到过细。 | 保存 `ChunkStorage`。 |
| `voxel_chunks` | `updated_at timestamptz` | 数据库原生时间类型。 | 运维和恢复判断。 |
| `voxel_parcels` | `parcel_id`, `logical_scene_id`, `region_id`, `owner_*`, `permission_mask`, `build_epoch` | 与地块结构一致，拆列便于权限查询。 | 持久化地块和权限。 |
| `voxel_parcels` | `bounds_data bytea` | 范围结构可能演进。 | 保存地块边界。 |
| `voxel_region_assignments` | `region_id`, `logical_scene_id`, `owner_*`, `state`, `version` | 账本热查询字段拆列。 | 持久化区域分配。 |
| `voxel_region_assignments` | `summary_hash bytea(8)` | 哈希是原始 64 位摘要，不适合落 `bigint`。 | 保存区域内容摘要。 |
| `voxel_region_assignments` | `bounds_data bytea` | 边界结构可演进。 | 保存区域范围。 |
| `voxel_lease_write_tokens` | `logical_scene_id`, `region_id`, `lease_id`, `owner_scene_instance_ref`, `owner_epoch`, `token_version` | DataService 落盘前需要本地 CAS 校验。 | 保存 World 下发的当前写入令牌。 |
| `voxel_lease_write_tokens` | `bounds_data bytea`, `expires_at timestamptz` | 范围结构可演进，过期时间用数据库原生时间。 | 限定令牌覆盖范围和有效期。 |
| `voxel_build_reservations` | `reservation_id`, `logical_scene_id`, `parcel_id`, `actor_id`, `state` | 施工保留需要在 World 重启后恢复或释放。 | 持久化排他保留锁。 |
| `voxel_build_reservations` | `bounds_data bytea`, `expires_at timestamptz`, `intent_hash bytea(8)` | 范围可演进，哈希按原始摘要保存。 | 恢复保留范围、过期判断和幂等识别。 |
| `voxel_build_transactions` | `transaction_id`, `logical_scene_id`, `parcel_id`, `reservation_id`, `state`, `decision_version` | 跨 Scene 事务必须可恢复。 | 持久化 prepare/commit/abort 状态。 |
| `voxel_build_transactions` | `participants_data bytea`, `intent_hash bytea(8)`, `timeout_at timestamptz` | 参与方结构会演进，哈希按原始摘要保存，超时用数据库原生时间。 | 恢复参与方确认、幂等重放和超时中止。 |
| `voxel_scene_objects` | `logical_scene_id`, `object_id`, `parcel_id`, `blueprint_id`, `blueprint_version`, `object_version` | 对象查询、权限过滤和增量排序需要拆列。 | 持久化已放置对象。 |
| `voxel_scene_objects` | `anchor_world_micro bigint[3]` | 三维锚点固定长度。 | 对象世界位置。 |
| `voxel_scene_objects` | `data bytea` | 对象结构复杂且会演进。 | 保存 `SceneObjectInstance` 扩展数据。 |
| `voxel_blueprints` | `blueprint_id`, `version`, `owner_account_id`, `visibility`, `micro_resolution` | 蓝图目录查询字段拆列。 | 持久化蓝图元信息。 |
| `voxel_blueprints` | `data bytea` | 蓝图体素层复杂。 | 保存 `BlueprintDefinition`。 |
| `voxel_chunk_journal` | `logical_scene_id`, `chunk_coord`, `chunk_version`, `actor_id`, `request_id`, `op_kind`, `result_code` | 审计/排障高频过滤字段拆列。 | 记录区块操作流水。 |
| `voxel_chunk_journal` | `payload bytea` | 不同操作载荷（消息或日志里的实际内容）不同。 | 保存原始操作或结果摘要。 |
| `voxel_attribute_sets` / `voxel_tag_sets` | `scope_kind`, `scope_id`, `attribute_set_id/tag_set_id`, `schema_version` | 目录项需要按作用域和版本查询。 | 持久化属性/标签集合。 |
| `voxel_attribute_sets` / `voxel_tag_sets` | `data bytea` | 集合内容可演进。 | 保存集合二进制。 |

区块快照（完整状态）是恢复真相；日志流水是审计、排障和回滚（按日志恢复或撤销辅助状态）辅助。

## 12. 协议通用规则

### 12.1 字节序

所有多字节字段统一 **大端序 / 网络字节序**：

```text
u16/u32/u64/i16/i32/i64/f32/f64 => 大端序
string => u16 字节长度 + UTF-8 字节
bytes  => u32 字节长度 + 原始字节
```

### 12.2 消息头

帧仍由 `{packet, 4}` / WebSocket 消息体承载：

```text
body = msg_type:u8 + payload
```

体素载荷（消息体里的实际内容）内部的可变结构使用 section（分段块，用来承载可选或可扩展内容）：

```text
section_type u8
section_len  u32
section_data bytes[section_len]
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `msg_type u8` | 当前消息类型少，`u8` 与既有协议一致。 | 区分顶层消息。 |
| `payload bytes` | 消息体变长。 | 承载具体协议结构；payload 指消息体里的实际内容。 |
| `section_type u8` | 段类型数量有限。 | 区分可变段类型；section 是快照内的分段块。 |
| `section_len u32` | 段可能较大，`u32` 足够且跨语言简单。 | 后续 `section_data` 长度。 |
| `section_data bytes[]` | 内容按段类型解释。 | 承载可选/可扩展数据。 |

### 12.3 规范编码与哈希

所有跨语言哈希统一使用 `xxHash64`、seed `0`，输出按大端序写入线格式。它只做快速一致性校验，不承担安全签名职责；需要防篡改时另加签名或 MAC。

哈希输入必须使用规范编码：

1. 字段顺序按本文结构定义顺序。
2. 整数统一大端序。
3. 变长数组先写 `u32` 元素数量，再按元素顺序写内容。
4. 字符串先写 `u16` 字节长度，再写 UTF-8 字节。
5. map 在哈希前必须按键的规范字节序排序。

`chunk_hash` 只覆盖区块真相字段：`schema_version`、`logical_scene_id`、`chunk_coord`、尺寸字段、宏格模式/载荷引用、普通块、细分格、环境摘要、对象引用、属性集合和标签集合。它不覆盖 `chunk_version`、脏标记、`dirty_bounds`、`last_persisted_ms`、传输分段顺序，也不覆盖可由真相重建的缓存字段。

`cell_hash` 覆盖单个宏格的真相字段：`mode`、规范化后的语义 flags、载荷内容、环境摘要引用内容和对象来源内容。它不覆盖 `cell_version` 和纯派生脏标记。因为线格式中 `cell_hash` 是 `u32`，它固定取同一规范编码 `xxHash64` 结果的低 32 位；完整 `u64` 摘要只用于 `chunk_hash / summary_hash / result_hash / cover_hash / catalog_hash` 等字段。

`result_hash`、`summary_hash`、`cover_hash`、`catalog_hash` 都按对应结构的规范编码计算。任何实现如果替换哈希库，必须先通过黄金样例；不能用语言内置、不稳定或进程相关的哈希函数。

### 12.4 体素操作码

| 操作码 | 方向 | 名称 | 用途 |
| --- | --- | --- | --- |
| `0x60` | C->S | `ChunkSubscribe` | 订阅场景内区块 AOI（关注区域） |
| `0x61` | C->S | `ChunkUnsubscribe` | 取消订阅 |
| `0x62` | S->C | `ChunkSnapshot` | 下发规范区块真相 |
| `0x63` | S->C | `ChunkDelta` | 下发区块增量（只含变化） |
| `0x64` | C->S | `VoxelImpactIntent` | 可选：技能/工具请求地形影响，通常由技能系统内部触发 |
| `0x65` | C->S | `BuildReservationIntent` | 请求地块/区域内施工保留 |
| `0x66` | C->S | `BlueprintCreate` | 创建 prefab/blueprint 定义 |
| `0x67` | C->S | `PrefabPlaceIntent` | 提交 blueprint_id + anchor 意图 |
| `0x68` | S->C | `VoxelIntentResult` | 返回接受/延迟/拒绝/过期结果 |
| `0x69` | S->C | `ChunkInvalidate` | 服务端要求客户端丢弃/重订阅 |
| `0x6A` | C->S | `ParcelQuery` | 查询地块/权限/建设状态 |
| `0x6B` | C->S | `ObjectAction` | 对象/部件级交互 |
| `0x6C` | S->C | `ObjectStateDelta` | 对象状态更新 |
| `0x6D` | S->C | `TagCatalogSnapshot` | 标签目录下发 |
| `0x6E` | S->C | `AttributeCatalogSnapshot` | 属性目录下发 |
| `0x6F` | 双向 | `VoxelDebugProbe` | 本地/开发调试保留 |
| `0x70` | C->S | `VoxelEditIntent` | 客户端编辑意图(macro / micro / object-part 通用入口) |

## 13. 关键消息

### 13.1 ChunkSubscribe `0x60`

```text
request_id        u64
logical_scene_id          u64
center_chunk      i32 cx, i32 cy, i32 cz
radius_l_inf      u8
want_snapshot     u8
known_count       u16
known[] {
  chunk_coord      i32 cx, i32 cy, i32 cz
  chunk_version    u64
}
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `request_id u64` | 请求全局去重和回包关联。 | 对齐响应/排障。 |
| `logical_scene_id u64` | 路由到场景。 | 指定订阅场景。 |
| `center_chunk ChunkCoord` | 三维中心。 | 订阅中心点。 |
| `radius_l_inf u8` | 半径通常很小，`u8` 足够。 | 立方体订阅半径。 |
| `want_snapshot u8` | 作为布尔但线格式（网络二进制布局）用 `u8`。 | 是否需要立即快照。 |
| `known_count u16` | 已知区块数量有限。 | 后续 `known[]` 长度。 |
| `known[]` | 变长数组。 | 客户端已知区块版本，用于避免重复下发。 |

### 13.2 ChunkSnapshot `0x62`

```text
request_id          u64
logical_scene_id            u64
chunk_coord         i32 cx, i32 cy, i32 cz
schema_version      u16
chunk_size_in_macro u8
micro_resolution    u8
chunk_version       u64
chunk_hash          u64
section_count       u16
sections[]          section
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `request_id u64` | 与请求关联。 | 匹配订阅或重拉请求。 |
| `logical_scene_id u64` | 场景路由。 | 所属场景。 |
| `chunk_coord ChunkCoord` | 三维区块坐标。 | 快照位置。 |
| `schema_version u16` | 快照格式版本。 | 兼容解码。 |
| `chunk_size_in_macro u8` | 与存储结构一致。 | 校验区块尺寸。 |
| `micro_resolution u8` | 与存储结构一致。 | 校验微格精度。 |
| `chunk_version u64` | 区块版本。 | 客户端顺序和缓存判断。 |
| `chunk_hash u64` | 快速一致性校验。 | 客户端/迁移校验。 |
| `section_count u16` | 段数量有限。 | 后续段数量。 |
| `sections[]` | 变长扩展段。 | 承载宏格头、普通块池、细分格池、目录等；section 是快照内的分段块。 |

必备 section（快照内的分段块）：

| section | 内容 |
| --- | --- |
| `0x01 MacroHeaders` | 4096 个压缩头 |
| `0x02 NormalBlocks` | 普通块池 |
| `0x03 RefinedCells` | 细分格池 |
| `0x04 AttributeSets` | 本快照用到的属性集合 |
| `0x05 TagSets` | 本快照用到的标签集合 |
| `0x06 EnvironmentSummaries` | 宏格环境摘要池 |
| `0x07 ObjectRefs` | 区块覆盖到的对象/部件摘要 |

### 13.3 ChunkDelta `0x63`

```text
logical_scene_id            u64
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

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `logical_scene_id u64` | 场景路由。 | 所属场景。 |
| `chunk_coord ChunkCoord` | 区块坐标。 | 目标区块。 |
| `base_chunk_version u64` | 与区块版本一致。 | 客户端校验本地基线。 |
| `new_chunk_version u64` | 与区块版本一致。 | 应用后的版本。 |
| `op_count u16` | 单包操作数有限。 | 后续 `ops[]` 长度。 |
| `delta_kind u8` | 增量种类是小枚举。 | 决定载荷解码方式。 |
| `macro_index u16` | 4096 宏格可用 `u16`。 | 定位变更宏格。 |
| `cell_version u32` | 与宏格版本一致。 | 拒绝过期格子变更。 |
| `cell_hash u32` | 与宏格哈希（内容摘要）一致。 | 局部一致性校验。 |
| `payload bytes` | 不同增量载荷（消息里的实际内容）不同。 | 承载具体格子/目录补丁。 |

`delta_kind`：

| 值 | 名称 | 载荷 |
| --- | --- | --- |
| `0` | `CellEmpty` | 无 |
| `1` | `CellSolid` | `NormalBlockData` |
| `2` | `CellRefined` | `RefinedCellData` 压缩编码 |
| `3` | `EnvironmentUpdated` | `MacroEnvironmentSummary` |
| `4` | `ObjectRefUpdated` | `ChunkObjectRef` |
| `5` | `CatalogPatch` | 属性/标签目录补丁 |

客户端若 `base_chunk_version` 不匹配本地已确认存储，必须请求快照，不做乱序合并。

### 13.4 BuildReservationIntent `0x65`

```text
request_id          u64
client_intent_seq   u32
logical_scene_id            u64
parcel_id           u64
known_parcel_build_epoch u64
bounds_world_micro  AabbI64
intent_hash         u64
ttl_ms              u32
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `request_id u64` | 请求去重和回包关联。 | 客户端匹配结果。 |
| `client_intent_seq u32` | 单客户端序列局部增长，`u32` 足够。 | 客户端意图顺序和幂等（重复提交同一请求不会产生重复效果）。 |
| `logical_scene_id u64` | 路由场景。 | 所属场景。 |
| `parcel_id u64` | 地块主键。 | 请求保留的地块。 |
| `known_parcel_build_epoch u64` | 与地块建设世代同类型。 | 服务器判断客户端是否基于过期地块状态请求保留。 |
| `bounds_world_micro AabbI64` | 建设范围需精确到世界微格。 | 排他保留（临时锁定建设范围）的范围。 |
| `intent_hash u64` | 快速识别重复或漂移请求。 | 幂等（重复提交同一请求不会产生重复效果）和排障。 |
| `ttl_ms u32` | 单次保留时长不需要 `u64`。 | 保留有效期。 |

用于施工排他保留（临时锁定建设范围）。客户端不能提交 actor；Gate 必须从已鉴权会话注入 actor。服务器可以返回接受/延迟/拒绝/过期结果。

### 13.5 PrefabPlaceIntent `0x67`

```text
request_id          u64
client_intent_seq   u32
logical_scene_id            u64
parcel_id           u64
known_parcel_build_epoch u64
blueprint_id        u64
blueprint_version   u32
anchor_world_micro  i64 x, i64 y, i64 z
rotation            u8
known_ref_count     u16
known_refs[] {
  chunk_coord        i32 cx, i32 cy, i32 cz
  chunk_version      u64
}
known_object_count  u16
known_objects[] {
  object_id          u64
  object_version     u64
}
known_cell_ref_count u16
known_cell_refs[] {
  chunk_coord        i32 cx, i32 cy, i32 cz
  macro_index        u16
  cell_version       u32
  cell_hash          u32
}
placement_flags     u32
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `request_id u64` | 请求关联。 | 匹配 `VoxelIntentResult`。 |
| `client_intent_seq u32` | 客户端局部序列。 | 幂等（重复提交同一请求不会产生重复效果）和顺序。 |
| `logical_scene_id u64` | 场景路由。 | 所属场景。 |
| `parcel_id u64` | 地块权限校验。 | 目标地块。 |
| `known_parcel_build_epoch u64` | 与地块建设世代同类型。 | 判断客户端是否基于过期地块状态放置。 |
| `blueprint_id u64` | 蓝图主键。 | 要放置的 prefab/blueprint。 |
| `blueprint_version u32` | 蓝图局部版本。 | 拒绝旧模板放置。 |
| `anchor_world_micro i64 x/y/z` | 世界微格坐标可为负。 | 放置锚点。 |
| `rotation u8` | 旋转枚举小。 | 放置旋转。 |
| `known_ref_count u16` | 客户端已知引用数量有限。 | 后续 `known_refs[]` 长度。 |
| `known_refs[]` | 变长数组。 | 客户端基于哪些区块版本发起意图。 |
| `known_object_count u16` | 相关对象数量有限。 | 后续 `known_objects[]` 长度。 |
| `known_objects[]` | 变长数组。 | 客户端基于哪些对象版本发起意图。 |
| `known_cell_ref_count u16` | 相关宏格数量有限。 | 后续 `known_cell_refs[]` 长度。 |
| `known_cell_refs[]` | 变长数组。 | 客户端基于哪些宏格版本和哈希发起意图。 |
| `placement_flags u32` | 放置选项位集（用二进制位表示多个开关）。 | 是否吸附、是否强制、是否预留等扩展。 |

客户端提交意图，不提交栅格化真相（把蓝图转换成具体格子占用后的结果），也不能提交 actor；Gate 必须从已鉴权会话注入 actor。服务端用蓝图注册表重算覆盖区块 / 宏格 / 微格 mask（位掩码）。

### 13.6 VoxelImpactIntent `0x64`

> **客户端直接编辑请使用 `VoxelEditIntent (0x70)`**(§13.6.1)。`VoxelImpactIntent` 自 Phase 1b 起被定位为"技能/工具系统专用通道":要么由服务端技能逻辑内部触发,要么用于需要客户端显式指定地形目标的特殊技能(例如远程爆破)。常规放置/破坏请走 typed `VoxelEditIntent`。

技能系统通常在服务端内部直接触发体素影响；此消息只给工具、特殊交互或需要客户端显式指定地形目标的技能使用。

```text
request_id          u64
client_intent_seq   u32
logical_scene_id            u64
source_skill_id     u32
target_world_micro  i64 x, i64 y, i64 z
impact_kind         u16
client_hint_hash    u64
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `request_id u64` | 请求关联。 | 匹配结果。 |
| `client_intent_seq u32` | 客户端局部序列。 | 幂等（重复提交同一请求不会产生重复效果）和顺序。 |
| `logical_scene_id u64` | 场景路由。 | 所属场景。 |
| `source_skill_id u32` | 技能目录局部编号。 | 触发技能。 |
| `target_world_micro i64 x/y/z` | 世界微格目标可为负。 | 地形目标点。 |
| `impact_kind u16` | 影响类型数量有限。 | 工具/技能/爆炸等类别。 |
| `client_hint_hash u64` | 非权威快速提示。 | 排障或快速拒绝明显过期目标。 |

客户端不能提交 `source_actor_id`；Gate 必须从已鉴权会话注入 actor，并把注入后的服务端内部事件交给 Scene。服务器可以忽略 `client_hint_hash`，它只用于排障或快速拒绝明显过期的客户端目标。

### 13.6.1 VoxelEditIntent `0x70`

客户端编辑体素的 typed 入口。统一表达 macro / micro / object-part 三种粒度上的 place / break / damage / replace / attribute_patch 操作。固定线格式 91 字节(不含 1 字节 opcode);未指定字段使用 sentinel,wire 偏移恒定。

```text
request_id              u64
client_intent_seq       u32
logical_scene_id        u64
action                  u8
target_granularity      u8
target_world_micro      i64 x, i64 y, i64 z
face_normal             i8 nx, i8 ny, i8 nz
material_id             u16
blueprint_ref           u32
object_ref              u64
part_ref                u32
attribute_patch_ref     u32
expected_chunk_version  u64
expected_cell_hash      u32
client_hint_hash        u64
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `request_id u64` | 与其他意图一致。 | 匹配 `VoxelIntentResult`。 |
| `client_intent_seq u32` | 客户端局部序列。 | 幂等(重复提交不重复生效)和顺序。 |
| `logical_scene_id u64` | 场景路由。 | 所属场景。 |
| `action u8` | 操作类型小枚举。 | 见下表 `action`。 |
| `target_granularity u8` | 粒度小枚举。 | 见下表 `target_granularity`。 |
| `target_world_micro i64 x/y/z` | 世界微格目标可为负;复用 `VoxelImpactIntent` 同字段。 | 命中 / 锚点位置。`Macro` 粒度时由服务端 floor 到 macro。 |
| `face_normal i8 nx/ny/nz` | 命中面法线只取 ±1 / 0,`i8` 足够。 | `Place` 时与目标位形成相邻偏移;其他 action 可为 (0,0,0)。 |
| `material_id u16` | 与 `NormalBlockData.material_id` 一致。 | `Place` / `Replace` 时表示新材质;其他 action 取 0(unspecified)。 |
| `blueprint_ref u32` | 蓝图目录索引;0 = unspecified。 | `Place` 大粒度蓝图时引用 prefab/blueprint;`PrefabPlaceIntent (0x67)` 仍保留作为蓝图主路径。 |
| `object_ref u64` | 对象长期 id;0 = unspecified。 | `ObjectPart` 粒度时定位 owner object。 |
| `part_ref u32` | 部件局部 id;0 = unspecified。 | `ObjectPart` 粒度时定位 part。 |
| `attribute_patch_ref u32` | 属性补丁池索引;0 = unspecified。 | `AttributePatch` action 时引用补丁;其他 action 取 0。 |
| `expected_chunk_version u64` | 客户端基准 chunk_version;`0xFFFF_FFFF_FFFF_FFFF` = unspecified。 | optimistic concurrency:服务端版本超过此值则拒绝(Stale)。真实版本范围 0..2^63-1,sentinel 不与合法值冲突。 |
| `expected_cell_hash u32` | 客户端基准 cell_hash;`0xFFFF_FFFF` = unspecified。 | 局部一致性预校验。hash 全 1 概率极低,实际安全。 |
| `client_hint_hash u64` | 与 `VoxelImpactIntent` 一致。 | 服务端可忽略;排障/快速拒绝过期目标。 |

`action` 枚举:

| 值 | 名称 | 含义 |
| --- | --- | --- |
| 0 | `Place` | 在目标邻接位放置(`material_id` / `blueprint_ref` 至少一个有意义)。`face_normal` 决定相邻偏移。 |
| 1 | `Break` | 破坏目标。 |
| 2 | `Damage` | 减目标 health(具体规则在 attribute system 实施后明确)。 |
| 3 | `Replace` | 用 `material_id` 替换目标材质。 |
| 4 | `AttributePatch` | 应用 `attribute_patch_ref` 引用的补丁(attribute system 实施后明确)。 |

未来值保留;decoder 应接受未知 `action` 并交业务层拒绝。

`target_granularity` 枚举:

| 值 | 名称 | 含义 |
| --- | --- | --- |
| 0 | `Macro` | 命中整宏格。`target_world_micro` 由服务端 floor 到 macro。 |
| 1 | `Micro` | 命中单 micro slot。`target_world_micro` 取 micro 精度。 |
| 2 | `ObjectPart` | 命中由 `(object_ref, part_ref)` 标识的对象部件;`target_world_micro` 用于排障定位。 |

未来值保留。

客户端不能提交 actor;Gate 必须从已鉴权会话注入 actor,并把注入后的服务端内部事件交给 Scene。`client_hint_hash` 与 `expected_chunk_version` / `expected_cell_hash` 都是非权威预校验,服务端最终以自身真相为准。

**Phase 1b 实施范围**:Gate 解码并落 observe 日志,**不路由到 Scene 也不返回 `VoxelIntentResult`**。Scene mutation API 与端到端通路在 Phase 1c 引入。客户端不应在 1b 期间发送 `VoxelEditIntent`;若发送,observe 日志能帮助定位"提交了但未生效"的现象。

### 13.7 VoxelIntentResult `0x68`

```text
request_id          u64
client_intent_seq   u32
logical_scene_id            u64
result_code         u8
result_ref          u64
authoritative_count u16
authoritative[] {
  chunk_coord        i32 cx, i32 cy, i32 cz
  chunk_version      u64
  macro_index        u16
  cell_version       u32
  cell_hash          u32
  payload_kind        u8
  cell_payload       bytes
}
reason              string
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `request_id u64` | 与请求关联。 | 客户端匹配结果。 |
| `client_intent_seq u32` | 与客户端意图序列一致。 | 幂等（重复提交同一请求不会产生重复效果）和排序。 |
| `logical_scene_id u64` | 场景路由。 | 所属场景。 |
| `result_code u8` | 结果枚举很小。 | 接受/延迟/拒绝/过期。 |
| `result_ref u64` | 可引用事务、对象或事件。 | 后续查询和审计。 |
| `authoritative_count u16` | 结果内联权威片段数量有限。 | 后续 `authoritative[]` 长度。 |
| `authoritative[]` | 变长数组。 | 返回权威区块/格子片段。 |
| `chunk_coord ChunkCoord` | 片段所在区块。 | 定位权威片段。 |
| `chunk_version u64` | 片段对应区块版本。 | 客户端顺序校验。 |
| `macro_index u16` | 定位宏格。 | 更新目标格子。 |
| `cell_version u32` | 宏格版本。 | 局部过期判断。 |
| `cell_hash u32` | 宏格哈希（内容摘要）。 | 局部一致性校验。 |
| `payload_kind u8` | 复用 `delta_kind` 小枚举。 | 告诉客户端 `cell_payload` 应按 Empty、Solid、Refined、Environment 或 ObjectRef 解码。 |
| `cell_payload bytes` | 结果载荷（消息里的实际内容）类型可变。 | 下发权威格子内容。 |
| `reason string` | 拒绝/延迟原因需要人类可读。 | CLI（命令行接口）/observe（结构化观察日志）/HUD（屏幕调试叠层）排障。 |

`result_code`：

| 值 | 名称 | 含义 |
| --- | --- | --- |
| `0` | `Accepted` | 已接受并已提交或即将由增量表达 |
| `1` | `Deferred` | 已入队或等待建设/规则帧 |
| `2` | `Rejected` | 权限、资源、几何、规则不满足 |
| `3` | `Stale` | 客户端基于过期区块/对象/地块状态发起 |

`payload_kind` 复用 `ChunkDelta.delta_kind` 的取值；如果 `result_code` 不是 `Accepted`，`authoritative_count` 可以为 0，客户端只显示 `reason` 并保持已确认体素存储不变。

### 13.8 ObjectStateDelta `0x6C`

```text
logical_scene_id      u64
object_id             u64
object_version        u64
state_flags           u32
attribute_patch_count u16
attribute_patches[] {
  attribute_id        u16
  patch_kind          u8
  value_q16           i32
}
tag_patch_count       u16
tag_patches[] {
  tag_id              u32
  patch_kind          u8
}
affected_chunk_count  u16
affected_chunks[]     ChunkCoord
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `logical_scene_id u64` | 场景路由。 | 所属场景。 |
| `object_id u64` | 对象长期持久。 | 被更新的对象。 |
| `object_version u64` | 对象长期更新，需要大版本。 | 客户端排序对象状态。 |
| `state_flags u32` | 状态位集。 | 对象开关、破坏、激活、燃烧等状态。 |
| `attribute_patch_count/tag_patch_count u16` | 单对象补丁数量有限。 | 后续补丁数组长度。 |
| `attribute_patches[] / tag_patches[]` | 补丁数量可变。 | 对象属性和标签增量。 |
| `affected_chunk_count u16` | 单对象覆盖区块数量有限。 | 后续 `affected_chunks` 长度。 |
| `affected_chunks[] ChunkCoord` | 对象可跨区块。 | 客户端刷新订阅、渲染和碰撞范围。 |

### 13.9 CatalogSnapshot `0x6D / 0x6E`

```text
logical_scene_id      u64
catalog_version       u64
entry_count           u16
entries[]             bytes
catalog_hash          u64
```

字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `logical_scene_id u64` | 场景路由。 | 所属场景。 |
| `catalog_version u64` | 目录长期更新。 | 客户端判断目录新旧。 |
| `entry_count u16` | 单包目录项数量有限。 | 后续 `entries` 长度。 |
| `entries[] bytes` | 标签和属性目录项结构不同。 | `0x6D` 承载 `VoxelTagCatalogEntry`，`0x6E` 承载 `VoxelAttributeCatalogEntry`。 |
| `catalog_hash u64` | 目录摘要用于快速一致性校验。 | 客户端确认目录完整性。 |

## 14. 客户端状态模型

客户端分三层，但没有体素真相预测层：

```text
角色预测状态
  移动、施法动画、本地粒子、音频、镜头、准星。

体素预览状态
  建造线框、地块叠加层、合法性提示、在途意图标记。
  它绝不修改已确认体素几何或体素属性。

已确认体素存储
  只由 ChunkSnapshot、ChunkDelta、ObjectStateDelta、
  TagCatalogSnapshot、AttributeCatalogSnapshot、VoxelIntentResult 载荷修改。
```

CLI（命令行接口）/HUD（屏幕调试叠层）必须暴露：

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

CLI（命令行接口）/HUD（屏幕调试叠层）字段说明：

| 字段 | 类型选择理由 | 用途 |
| --- | --- | --- |
| `voxel_sync` | 小枚举字符串便于命令行直接阅读。 | 标明体素同步模式。 |
| `voxel_truth_source` | 字符串可读性高。 | 标明体素真相来源。 |
| `subscribed_chunks` | 集合结构。 | 当前订阅区块。 |
| `confirmed_chunk_versions` | map 结构。 | 已确认区块版本。 |
| `inflight_intent_count` | 整数计数。 | 当前在途意图数量。 |
| `last_intent_result` | 结构化对象或字符串。 | 最近意图结果。 |
| `last_reject_reason` | 字符串。 | 最近拒绝原因。 |
| `snapshot_rx_count` | 单调计数。 | 已收到快照（完整状态）数量。 |
| `delta_rx_count` | 单调计数。 | 已收到区块增量（只含变化）数量。 |
| `object_delta_rx_count` | 单调计数。 | 已收到对象增量（只含变化）数量。 |
| `voxel_codec_endian` | 小枚举字符串。 | 当前编解码端序。 |
| `micro_resolution` | 小整数。 | 当前微格精度。 |

`offline-local-dev` 只允许作为开发模式，不能冒充 MMO 权威链路。

## 15. 编码结构与黄金样例（golden fixtures，用来让不同语言实现对齐的固定二进制样例）

先落编解码、结构和样例，再落玩法：

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

Elixir 和 TypeScript 必须对同一样例做往返编解码；Rust/UE 接入时读同一组样例。

## 16. 实施顺序

1. **S0 数据结构 + 大端序编解码 + 样例**：Storage、线类型、属性/标签/对象基础结构。
2. **S1 只读区块权威**：`ChunkSubscribe / ChunkSnapshot`，两个客户端哈希（内容摘要）一致。
3. **S2 World 地图账本（区域、地块、租约和摘要的权威目录）+ 租约管理器**：区域分配、owner_epoch、区块摘要、SceneLease、DataService 写入令牌 CAS。
4. **S3 地块 + 建设保留**：地块查询、权限、排他保留（临时锁定建设范围）、CLI（命令行接口）/observe（结构化观察日志）。
5. **S4 prefab 放置事务**：World 协调跨 Scene 准备/提交；事务决议可恢复；Scene 重算栅格并提交区块/对象增量（只包含变化）。
6. **S5 迁移协调器**：转移、分裂、合并三种迁移流程和路由翻转。
7. **S6 体素状态模拟**：温度、湿度、燃烧、冻结、结构完整度，由服务器规则帧后下发数据。
8. **S7 破坏/影响**：技能/爆炸导致的微格/对象破坏，服务端结算，客户端数据驱动表现。

## 17. 验收口径

S0：

- Elixir/TypeScript 对 `empty_chunk / solid_cell / refined_512_cell / prefab_place_intent / object_state_delta` 样例哈希（内容摘要）一致。
- 活跃协议文档和编解码注释只声明大端序与 `xxHash64` seed `0`。
- `window.__voxelCli.run("voxel_transport")` 能显示真相来源、端序、微格精度。

S1：

- 两个浏览器订阅同一场景/区块，`snapshot.chunk_hash` 一致。
- 客户端已确认体素存储只由快照（完整状态）/增量（只含变化）更新。

S2/S3：

- 未授权地块的 prefab 放置被拒绝。
- 同一地块/区域并发放置只允许一个事务成功。
- 跨区块 / 跨 Scene prefab 不会部分落地。
- 客户端没有把被拒绝意图写进已确认几何。
- DataService 使用 `LeaseWriteToken` 拒绝旧 `owner_epoch` / 旧 `owner_scene_instance_ref` 写入。
- World 在 prepare 后崩溃，恢复后必须根据 `BuildTransaction` 决议继续 commit 或 abort，不产生半提交。
- 同一 Scene 拥有多个参与区域时，跨区块事务必须按参与租约分别校验 `lease_id + owner_scene_instance_ref + owner_epoch`。

S5：

- 转移：旧 Scene 栅栏（旧世代拒写条件）/刷写，新 Scene 加载/预热（先加载数据和索引再对外服务）/哈希（内容摘要）校验后，World 才翻转分配。
- 分裂：新区域边界贴合区块/地块，迁出区域使用新 owner_epoch，边界只读缓冲带（邻区只读摘要）可用。
- 合并：源 Scene 刷写后目标 Scene 加载完整区域，旧租约被释放且旧世代写入被拒绝。
- 普通跨边界燃烧/冻结传播不经过 World 热路径，而是通过 `BoundaryVoxelEvent` 幂等传播。
- 迁移后到达的旧 `BoundaryVoxelEvent` 必须因目标租约或目标世代不匹配被丢弃。

S6/S7：

- 客户端先播放技能粒子，但燃烧/冻结/破坏只在服务器增量（只含变化）后进入体素效果管线。
- 相同输入样例在服务端重复计算得到相同 `ChunkDelta / ObjectStateDelta` 哈希（内容摘要）。

## 18. 设计警戒线

1. 不要把体素数据做客户端预测真相。
2. 不要让技能特效结果直接改体素存储。
3. 不要让客户端上传最终 prefab 栅格当权威结果。
4. 不要绕过地块/归属权限直接写区块。
5. 不要丢掉对象/部件来源追踪。
6. 不要把所有区块默认展开成微格数组。
7. 不要让 Scene 私自扩张或持久占有区域；区域所有权必须来自 World 租约（写入授权令牌）。
8. 不要在迁移时允许两个 owner_epoch 同时写同一区块。
9. 不要只做 GUI；必须同步命令行/可观测（CLI 和结构化日志能读到关键状态）/黄金样例（固定输入输出样例）。
