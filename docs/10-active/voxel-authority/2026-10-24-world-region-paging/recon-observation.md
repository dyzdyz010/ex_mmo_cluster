# 调研：观察／订阅／下发链路（按区域分页世界真值 决策稿输入）

范围：服务端 `D:\hemifuture\ex_mmo_cluster`（HEAD b9b305f4），客户端 `D:\hemifuture\Voxim`（Source/Voxim）。只读，未对运行中的容器做 rpc。
实测数字来自 `ex_mmo_cluster/docs/10-active/voxel-authority/2026-10-23-world-memory-compaction.md` 和
`Voxim/Saved/Playtest/release-20261023/heap-probe.json`；其余数字由代码字段推算，推算出的标“推断”。

尺度：tile = region = 64 macro（`CollisionStream.box` 用 `Payload.extent()-2 = 64`）。`box(_,1)` = 3×3×3 = 27 region，
即 192 m 立方、7 077 888 个宏格。如园窗口的 1 969 651 条 epochs 约占窗口内宏格的 27.8 %。

---

## 1. 窗口决定与向 World 取数

### 1.1 Scene 侧：窗口怎么定

| 步骤 | 位置 | 行为 |
|---|---|---|
| 首个窗口 | `scene_server/.../movement/player.ex:248-253` | `streaming_radius>0`（`scene.ex:106` 读 `collision_window_radius_tiles`）时用 `CollisionStream.box(probe, r)` 起一个 `CollisionStream` 进程，进程寿命跟 Gate 绑定 |
| 窗口盒 | `voxel_region/collision_stream.ex:17-23` | `center = floor(pos/64)`，盒 = `[c-r, c+r+1)`，三轴都算（完整 XYZ） |
| 滞回 | `collision_stream.ex:26-36` | 位置离开中心 tile 外扩 1/4 tile 的范围后才换盒 |
| 每 tick 判断 | `player.ex:2093-2117` `stream_window/1` | 盒变了、并且上一个窗口已经装好（`window_pending=false`），才调用 `request_window` |
| 请求 | `player.ex:2119-2128` → `collision_stream.ex:59,78-89` | `CollisionStream.window/2` 在权威节点 spawn 一个进程去调 `World.canonical_snapshot_and_subscribe(authority, box, stream, ref)` |
| 订阅生命周期 | `collision_stream.ex:39-46,72-76` | 一个连接一个 stream，窗口变化不新建 stream；跨 Scene 移交用 `attach` 按 cursor 重放；Gate 或 World 挂掉时 stream 停止。World 端以 `canonical_subs[pid] = box` 记账，`Process.monitor` 负责清理（`world.ex:1346,1354`）。**没有租约和续租**，换窗时覆盖 box |

### 1.2 World 侧：快照怎么组装（`world.ex:1337-1360` → `observation.ex:47-68`）

`canonical_snapshot_and_subscribe` 先在调用方进程 `prepare` 27 个 L0 region（冷生成，`world.ex:442-467`），
再 `GenServer.call {:canonical_snapshot,...}`。World 进程串行执行 `capture_canonical_snapshot`：

| 组成 | 位置 | 按区域取还是扫全表 |
|---|---|---|
| 区域字节 | `payloads.ex:440-447` `canonical_regions` → `payload_bytes`（`payloads.ex:66-123`） | 按区域取。命中缓存时 O(1)；未命中时物化（见下一行） |
| 物化细节 `with_existing_details` | `payloads.ex:158-194` | refined 走区域索引（`refined_in_regions`，按区域）；以下几项**扫全表**：`macro_owners` 全表 filter（178）、`refined_owners` 全表（180）、`liquid_units` 全表（185）、`Attachments.extract` 遍历全部附件槽（`attachments.ex:37-43`） |
| 树冠 `Canopy.project` | `world/canopy.ex:9-27,48-54` | `candidates/1` 每次都遍历**全世界** `macro_owners` 并查 prefab 定义 |
| 叶子几何缓存 `prepare_component_cache` | `observation.ex:138-164` | `order` 索引由**全世界** `state.refined` 建出（146）；遍历全部 `refined_owners`，逐个 owner 检查是否与窗口相交（151） |
| 属性快照 `property_snapshot` | `observation.ex:182-201` | 都是**先取全世界再投影**：`state.damage` 全表（184），`owned_macro_observations` 遍历全部 `macro_owners`（207），`component_observations` 同上，`attachment_observations` 对全部附件 `group_by`（471），**`epochs: state.epochs` 整表（194，4 692 422 条）** 再经 `PropertyObservation.project` 的 `Map.filter` 逐条判断是否在盒内（`property_observation.ex:19`） |
| 其它 | `observation.ex:58,195-197` | `food_receipts` 整表、protection／semblances／casts 整表，投影后发出（protection／semblances／casts 投影；food_receipts 不投影，只在 Scene 内消费） |
| 碰撞 chunk | `canonical_feed.ex:19-23` → `collision_source.ex:34-42` | 在每个订阅者自己的 Feed 进程里，把 27 个 region 全部解码，每个 region 投影出 64 个 chunk（共 1 728 个） |

实测：如园窗口在 World 内组装耗时 0.74 s，World 进程在此期间被阻塞（压缩稿 §实测）。**推断**：主要开销是对 469 万条 epochs 的
`Map.filter` 和对全部 refined／owner 表的遍历，两者都是 O(世界)，与窗口大小无关。

### 1.3 增量：提交后怎么下发（`observation.ex:340-461`）

| 步骤 | 位置 | 说明 |
|---|---|---|
| 碰撞 chunk 前后像 | `observation.ex:343-366` | 只取变化格所在、并且落在某个订阅盒内的 chunk（按区域） |
| 属性事务 `property_transaction` | `observation.ex:216-306` | 每笔有格条目的事务都要**扫全表**：`before.refined` 与 `state.refined` 键的并集（223）；`component_geometry` 的 `order` 由全世界 refined 建出（146）；`macro_owners` 键的并集（265）；附件表整表比较，变了就对**全世界附件**重建观察行（258-263） |
| 发给 canonical 订阅者 | `observation.ex:390-409` | `CanonicalDelta.transaction = PropertyObservation.project(txn, box)`。**`project` 只过滤 property_states／falls／operation／epochs／protection／semblances／casts，不过滤 `entries` 和 `coarse`**（`property_observation.ex:14-23`）。结果是全世界的格条目、region 后像整字节和结构条目都发给每个订阅者 |
| Replica 订阅者 | `observation.ex:412-460` | region 字节按订阅盒过滤，`delta.chunks` 也按盒过滤 |
| 旧 R6 overlay 订阅（`subs`） | `world.ex:1312-1323`、`log_projection.ex:55-113` | 按盒外扩 1 region 投影条目；`level ≥ coarse_min_level` 的粗格对所有订阅者都发 |

### 1.4 Scene Replica（拓扑里配置时才有）

`replica.ex:38-85`：用一个固定 box 从 World 取一次快照，之后接收 `canonical_replica_delta`。这条路径的快照属性行**只有稀疏的 `state.damage`**（146），
不含 World 快照里派生出的 owner 宏格行、叶子行和附件行。**推断**：这和 World 的 `property_snapshot` 不是同一个取值函数（DRY/SSOT 分叉）。
玩家的 CollisionStream 只连 World authority（`collision_stream.ex:85`），所以目前不影响流送玩家；非流送拓扑下 Scene 从 Replica 拿 anchor 时会受影响。

---

## 2. 下发消息的线格式与大小增长

协议版本：`mmo_contracts/session/codec.ex:2` `@protocol_version 41`。M1 Voxel envelope 定义在 `mmo_contracts/voxel/codec.ex:4-64`。

| 消息 | 定义 | 线格式要点 | 单条大小 | 随什么增长 | 窗口有界？ |
|---|---|---|---|---|---|
| CollisionWindow（M1 kind 4） | `voxel/codec.ex:30-43`；发送 `player.ex:1739-1750`；客户端解码 `VoxelGateCodec.cpp:627-664` | apply_tick、identity、cv、rev、seq、l0 盒、travel 盒，加上 `regions: [coord 12 B + blob]`，**27 个 region 每次都整字节发** | 每个 region 是 zlib 压缩的 VXR body：66³×u16 格（压缩前 575 KB）+ 表皮 CSR + 细节尾段（refined 槽每槽 16 B、实例 69/85 B、附件槽 36 B、液体 8 B/格、结构、树冠），见 `payload.ex:3-8,62-66` | region 内的作者内容密度：refined 槽数、实例、附件、树冠 | 区域数有界（27 个）；字节数随密度线性增长；**每次换窗都重发全部 27 个，其中 18 个是保留区**，客户端会解码全部 27 个，再在 `AdmitWindowRegion` 丢掉已驻留的 region（`VoxelLodWorld.cpp:1814-1817`） |
| CanonicalBootstrap（M1 kind 2） | `codec.ex:14-25`、`player.ex:865` | 同上，不带 apply_tick | 同上 | 同上 | 同上 |
| PropertyBatch（M1 kind 5） | `codec.ex:44-60`；组装 `player.ex:1781-1820`；客户端 `VoxelGateCodec.cpp:680-713` | 盒、complete、hp/thermal 开关、digest 32 B、ambient；`epochs: bytes`（每条 x,y,z i32 + epoch u64 = **20 B**，`player.ex:1792`）；`states: [u32 len + 0x7E 行]`；protection／semblances／casts 的 bytes | 0x7E 行（`codec.ex:442-490`）：基础 121 B，加温度 8、燃烧 17、电 16、电源 24；数组前缀 4 B。客户端按每行至少 125 B 做上界校验（`VoxelGateCodec.cpp:690`） | epochs 数量（安装或替换过的宏格数）、属性行数（稀疏损伤／温度 + **每个 owner 宏格一行 + 每个叶子一行 + 每个附件一行**，含默认值） | **无界**，随内容线性增长。如园：epochs 1 969 651 × 20 B ≈ 37.6 MB（实测）；83 672 行 × 约 129–133 B ≈ 10.8–11.1 MB（**推断**） |
| PropertyBatch 增量（complete=0） | `player.ex:1756` | 同一结构，内容是投影后的事务属性行和 epochs | 每笔事务 | 本笔事务改动的属性行；**`Parcel.install` 一笔就写入几十万到上百万条 epochs**（`parcel.ex:208`、`tools.ex:482`） | 按盒投影，但单笔大小没有上界 |
| 0x79 `voxel_log_transaction_payload` | `codec.ex:930-944,1017-1034`；`player.ex:1854,1754` | seq、`[u32 len + entry]`、coarse、falls（tag 2，每条 16 B）、operation（tag 3） | 格条目 24 B + 粗格；region 条目是**整个 region 的后像字节**；结构条目 22 B + 网格 | 全世界的编辑活动（entries 和 coarse 都不按盒过滤） | **不随窗口有界**：盒外的 L0 格条目和 region 后像也发给每个玩家。客户端只应用到已驻留或 pending 的 region（`VoxelLodWorld.cpp:1644-1663`）。粗格本来就要求全世界一致（远景 LOD），这部分属于设计行为 |
| CollisionApplied（M1 kind 1） | `codec.ex:5-12`、`player.ex:1759-1766` | 变化 chunk 坐标，每个 12 B | 很小 | 本笔事务的 chunk 数 | 有界 |
| TimelineFence／Relocate | `codec.ex:26-28,64` | 定长 | 很小 | — | 有界 |
| 碰撞 chunk（**不上线**） | `collision_source.ex:206-271` | 普通 chunk 16³ = 4 KB；**含任一 refined 格的 chunk 是 128³ = 2 MiB** | — | 窗口内含 refined 的 chunk 数 × 玩家数（每个 Player 有自己的 `CollisionUpdates`／Native 世界，`collision_updates.ex:25,41-69`） | 按窗口有界，但常数大。**推断**：如园级密度下每个玩家的 Scene 内存可能达到数百 MB，需要实测 |

协议里的冗余字段（PropertyBatch 内每一行都带，客户端还会逐行校验它与批次一致，`VoxelGateCodec.cpp:696-697`）：
`request_id` 8 B（快照里恒为 0）、`seq` 8 B（等于批次 seq）、`digest` 32 B（等于批次 digest），加上 `defense` 8 B（可由目录推导）。
合计每行 56 B，如园窗口约 4.7 MB（**推断**）。

---

## 3. 客户端如何消费

| 用途 | 位置 | 是否只需要非默认状态 |
|---|---|---|
| 完整批次：`Reset()` 后整体重建 | `VoxelDamageState.cpp:74-94`；`VoxelM1Client.cpp:398-400`（每个新窗口先 `DamageStates.Reset()`） | 换窗时把保留区的状态也丢掉并重收 |
| epochs 写入 `TMap<FIntVector,uint64> Epochs`，值变化时 `++OwnerRevision` | `VoxelDamageState.cpp:99-103`、`.h:175` | — |
| 用途 1：属性行配对，`State.Target.Incarnation == Epochs[Macro]` | `ConfirmedMacroState` `VoxelDamageState.cpp:17-18`；`RetirePrefabMetadata` 34 | **只在有行时才需要**该格的 epoch |
| 用途 2：没有行的普通宏格派生默认态，`Default.Target.Incarnation = Epochs.FindRef(Macro)` | `VoxelDamageState.cpp:152-159` | 准星选中任意宏格时都要知道它的 epoch，工具意图要带上它，服务端用它防 ABA（`Tools`：`hit.incarnation == request.incarnation`，见压缩稿 §自查 1）。也就是说**客户端需要窗口内任一格的 epoch**，但只在选中目标时才需要，可以用规则推导（盒戳、region 内稀疏段），不必逐格下发 |
| 普通宏格默认 HP／温度 | `VoxelDamageState.cpp:153-158` | **客户端已经能自己推导**：目录里的 `MaxHpPerMacro`、`Defense`，以及 `AmbientAt` 气候区 |
| owner 宏格 | `VoxelDamageState.cpp:129-131` 的注释：“Macro ownership is carried by this authoritative property row. Only refined cells also carry ownership in the canonical geometry payload.” | **宏格的 owner 身份目前只靠属性行传递**，属于几何身份借道属性通道。所以 `owned_macro_observations` 会给每个 owner 宏格都发一行默认行（`observation.ex:204-214`）；`SelectionFootprint`、`RetirePrefabMetadata` 也依赖这些行 |
| 叶子（refined 部件，granularity 2） | `Resolve` 的 151-152 行：“叶子必须有服务器汇总” | 每个与窗口相交的叶子都要一行（`component_observations`），没损伤也发。整件 max_hp = Σ 微格 `max_hp_per_macro/512`（`canonical.ex` 的 `component_max_hp`），按 refined 原顺序做浮点求和（`observation.ex:145` 注释说不能换序）。叶子可能跨出窗口，客户端只有窗口内的几何，**目前无法自己算出越界叶子的总 HP**（**推断**） |
| 附件（3）／附件槽温度（4） | `ResolveAttachment` 169-187 | 每个附件实例都要一行；默认 max_hp = 目录值 × 槽材料量（`canonical.ex` 的 `attachment_max_hp`），实例也可能越界 |
| 事务失效 | `InvalidateTransaction` 189-209 | 收到 Kind 1（region 后像）时遍历全部状态比对，开销 O(窗口行数) |

结论：快照里真正需要的“非默认状态”只有 ① `state.damage` 里的稀疏记录（全世界 58 948 条，heap-probe），② 被替换过的格的世代。
其余都是派生出的默认行：owner 宏格行、未损伤的叶子行和附件行。这些行存在，是因为 owner 身份和整件 max_hp 没有放进几何载荷。

---

## 4. 已有的分页、缓存和有界机制

| 机制 | 位置 | 上限 | 备注 |
|---|---|---|---|
| World 载荷缓存 `payloads` | `payloads.ex:375-412`、`world.ex:514-526` | L0–L3 按 LRU 淘汰，默认 `@default_cache_bytes` 512 MiB（`world.ex:38`，可由 `:payload_cache_bytes` 配置，`config/runtime.exs:179`）；**L4+ 常驻，无上限** | 只缓存派生字节，可以丢弃 |
| `decoded` 源载荷解码缓存 | `canonical.ex:93-107` | **无上限**，只在 `log.ex:199` 删除；碰过的 region 都会留在里面 | **推断**：会随访问或编辑过的 region 数增长 |
| `region_bases` | `canonical.ex:86` | 随提交过完整区域的 region 数增长（48 MB） | 这是真值，不是缓存 |
| `served_headers` | `payloads.ex:29-33` | 每个 (level,region) 一条 | 很小 |
| GeneratedStore | `generated_store.ex:1-15` | 磁盘上的 VXR4 baseline，L0 按需生成；ETS 只存锁和列边界 | 本身有界；L0 冷 miss 由调用方并发预备 |
| 客户端 HTTP region 缓存 | `VoxelRegionFetcher.h:115-131` | 磁盘 `CacheBudgetBytes` 默认 2 GiB，L0–L3 按 mtime 淘汰，L4+ 常驻；请求带 (seq,hash)，服务端可以回 `unchanged` 或 `entries`（`payloads.ex:20-63`） | **只用于 serve 路径（远景 L1+）**；M1 CollisionWindow 和 Bootstrap 不走 have_seq/hash，也不复用磁盘缓存 |
| 客户端 L0 驻留 | `VoxelLodWorld.cpp:1792-1812` | 只驻留窗口内的 region，盒外的释放 | 有界 |
| 客户端属性副本 | `VoxelDamageState.h:175-188` | 窗口内的全部行和 epochs | 窗口有界，但随密度线性增长；`GeometrySeq`／`TargetGeometrySeq` 只增不减，直到下一次 Reset |
| Scene 碰撞历史 | `collision_updates.ex:41-69,233-245` | 按 revision 保留 artifacts | 按窗口有界；refined chunk 的常数大（2 MiB） |
| CollisionStream 待确认队列 | `collision_stream.ex:52-55,95-99` | 收到 ack 就裁掉 | 有界 |

当前**不存在**按区域分页的世界真值：`refined`、`epochs`、`damage`、`macro_owners`、`attachments`、`instances`、`prefabs`
都是单个 World 进程里的全世界 Map（heap-probe：refined 310 MB、epochs 276 MB、prefabs 239 MB、entries 309 MB）。

---

## 5. 结论

### 5.1 窗口内各项下发量：有界与线性增长

| 项 | 窗口有界 | 随内容密度线性 | 随世界总量增长（与窗口无关） |
|---|---|---|---|
| region 数／chunk 数 | ✔ | | |
| 每个 region 的载荷字节 | | ✔（refined 槽、实例、附件、树冠） | |
| 换窗下发量 | | ✔，并且是需要量的 3 倍（27 个 region 全部重发，实际只进入 9 个） | |
| PropertyBatch epochs | | ✔（每个替换过的格 20 B；如园 37.6 MB） | 组装开销：全表 filter |
| PropertyBatch 属性行 | | ✔（owner 宏格、叶子、附件都有默认行；如园 8.4 万行，约 11 MB，**推断**） | 组装开销：全表遍历 |
| 0x79 事务 entries/coarse | | | ✔（不按盒投影，全世界的编辑都广播给每个玩家） |
| 单笔增量 epochs（安装） | | ✔（单笔无上界） | |
| CollisionApplied／Fence／Relocate | ✔ | | |
| Scene 侧碰撞 chunk 内存 | ✔ | ✔（refined chunk 2 MiB；× 玩家数） | |
| World 快照和事务的 CPU | | | ✔（observation.ex:146/184/194/207/223/265/471，payloads.ex:178-188，canopy.ex:49） |

### 5.2 为“只发非默认状态”需要改的协议点

1. **epochs → 稀疏世代 + 区域内表示**（PropertyBatch kind 5 的 `epochs` 字段）
   - 选项 A：压缩稿里的 D3 盒戳 `epoch_boxes`（每条 32 B，`epoch_at = max(稀疏, 覆盖盒戳)`）。
   - 选项 B（适合分页）：把世代作为 region 载荷里的一个稀疏尾段（region 局部坐标 + seq，或整区替换 seq），世代就随 region 分页、缓存和失效。
   - 两种选项下，客户端 `Epochs.FindRef` 的三处（`VoxelDamageState.cpp:18,34,155`）都要换成同一个取值函数；Replica（`replica.ex:62,186`）也要一起换。
2. **宏格 owner 身份移进几何载荷**：在 VXR 尾段加一个稀疏的 `macro_owners`（region 局部 index → {birth,occ}）。
   有了它就可以删掉 `owned_macro_observations` 的默认行（`observation.ex:189,204-214,265-276`）；客户端 `Resolve`／`SelectionFootprint`／`RetirePrefabMetadata` 改为从载荷读 owner。
   这一项会改变 region 载荷的格式版本，影响 `payload.ex` 和 `VoxelRegionCodec.cpp`。
3. **叶子和附件只发非默认行**：未损伤的叶子行和附件行不再发送，客户端按“缺行 = 满血 + 环境温度”推导。前提是客户端能拿到整件 max_hp，可选做法：
   (a) 在载荷的实例或附件段里带上整件 max_hp（u32 或 f64）；
   (b) 客户端按目录自己求和，但越界的叶子算不出来，浮点求和顺序也要冻结。
   需要把 `Resolve` 151-152 行的“叶子必须有汇总”改成显式的默认语义。
4. **0x7E 行瘦身**：在 PropertyBatch 内去掉逐行的 `request_id`／`seq`／`digest`（批次已经给出），`defense` 由目录推导。
   可以新增一种批内行格式，或者用 flags 位声明；独立的 0x7E 帧（意图应答）保持原样。
5. **CollisionWindow 只发进入的 region**：带上保留区的 (coord, seq, hash) 断言，或者让客户端按“盒差集”只收新进入的区域。
   保留区的 seq 已经由同一条可靠流的增量推到快照 seq，需要显式规定“保留区 = 当前驻留副本”的契约，以及失配时的显式失败。
   完整 PropertyBatch 也应只针对进入的区域，或者改成“盒差集 + 退出区清除”；当前客户端每次 `Reset()`（`VoxelM1Client.cpp:400`）。
6. **事务 entries 和 coarse 按订阅盒投影**：`PropertyObservation.project`（或 `fanout_canonical`）要过滤 L0 格条目、region 后像和结构条目；粗格按 LOD 带过滤，或者继续保持全局。
   客户端已经能处理“盒外条目不出现”。这一项不改线格式，只改语义（盒外条目不再出现）。
7. **单笔安装的 epochs 增量**：采用第 1 项后自然变成每笔一条盒戳，否则一笔 PropertyBatch 增量会有数十 MB。
8. **服务端组装改成按区域索引**（非协议，但要实现第 1–6 项就离不开它）：对 epochs、damage、macro_owners、refined_owners、attachments、liquid_units、canopy candidates 建 region → 集合的索引，或者干脆按 region 分页持有。
   需要替换的全表扫描点：`observation.ex:146,184,194,207,223,265,258-263,471`，`property_observation.ex:19`，`payloads.ex:178,180,185,188`，`canopy.ex:49`。

### 5.3 风险和待测项

- 如园 8.4 万行里 owner 宏格行、叶子行、附件行、稀疏 damage 行各占多少，没有拿到分项计数（**推断**：damage 全世界 58 948 条，窗口内的其余行就是派生默认行）。需要在 Windows 原生服务端统计各粒度的行数。
- 真实客户端从未进过如园窗口（压缩稿 §实测），客户端解码 37.6 MB epochs 加约 11 MB 属性行的耗时和内存还没测过。
- Scene 侧每个玩家的 refined 碰撞 chunk（每个 2 MiB）总量没测过。
- `decoded` 缓存没有上限，在分页设计里应该一起归入有界缓存。
