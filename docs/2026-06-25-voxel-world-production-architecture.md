# 体素世界架构决策稿:从临时竞技场到可发布无界世界

- 日期:2026-06-25
- 状态:**决策稿(待拍板)**
- 作者:首席架构师(体素 MMO)
- 关联冻结稿:`docs/HEMIFUTURE-MMO-架构设计规范-v2.0.1-冻结稿.md`(`CELL-1~24`、`LOAD-1~11`、`AUTH-3`、`FROZEN-1~5`、`PERS-4/5`)
- 关联契约:`apps/mmo_contracts/lib/mmo_contracts/cell_id.ex`(`:region`/`:morton` 两种等价编码,`region↔morton` 为 D-2 迁移接缝)
- 关联路线:`docs/2026-04-07-增量迁移计划.md` §4、`docs/2026-06-23-loop-and-zone-scale.md`(两轨范围)、`docs/2026-04-17-场景空间索引架构设计.md`(AOI=N² 交互)

---

## 1. 背景与本稿目标

### 1.1 背景

体素权威层(World/Scene/Gate/DataService + bevy 客户端)已具备**全套正确的 durable 原语**:`owner_epoch` 的 DB 线性化分配器(`RegionEpochStore.allocate_next`)、write-token DB fence(`WriteTokenStore`)、per-chunk `chunk_version` 单调 CAS(`ChunkSnapshotStore`,`pg_advisory_xact_lock + SELECT FOR UPDATE`)、replication outbox、`begin/plan_slice/prewarm/cutover/complete` 迁移状态机、`command_id` exactly-once 重放。这些原语本身是对的,且 `CELL-19 [v2.0.2]` 已确认 per-chunk `chunk_version` CAS 是**合规 fencing 路径**。

但把这些原语粘起来的是一层临时胶水:dev 世界写死成固定 5×5×5=125 chunk 的单盒子(`DevSeed`)、route miss 是终态错误而非懒创建触发器、生产 `WorldSup` 根本没给 `MapLedger` 接已就绪的 durable 后端、AOI 跨边界整框 O(radius³) 重订阅且同步阻塞 connection 进程、编辑纯往返无预测无反馈。本次直接触发的两个症状——**走出 125-chunk 盒子编辑"没反应"(`:unassigned_chunk`)** 与 **跨 chunk 边界重订阅把编辑帧堵在 mailbox 后 ~3.5s**——正是这层胶水的直接产物。

### 1.2 一句话现状判断

> **当前是一堆临时设计,因为正确的 durable 原语被一层"够 dev/smoke 跑通"的胶水包裹:世界被写死成一个有边界的固定竞技场、控制面目录声明 durable 却跑在纯内存、编辑与流式共用一条会互相阻塞的同步通道——产品级的"无界探索、即时建造、重启自愈、水平扩展"没有一项被结构性支撑,全部停留在单盒子单 owner 的 MVP 假设上。**

### 1.3 本稿目标

产出**整体最优、面向最终可发布产品**的体素世界架构,并给出**不破坏现状、逐 step 可单独 commit、第一阶段即缓解"越界编辑没反应"**的实施路径。整体最优意味着:不在各子系统各自局部最优,而是选一个**与冻结稿 v2.0.2 对齐**的统一抽象(隐式坐标分区 + 目录派生化),把三个候选方案的精华嫁接到这个最精简的底座上。

### 1.4 对一处关键评审分歧的裁决(载入决策)

对抗评审认定"3D 均匀分块违背冻结规范的 XZ-column 四叉树",并建议改用 XZ-column。**经核对冻结稿原文,此评审结论错误,本稿不采纳。** 依据:

- `CELL-3 [v2.0.2 修订]`(规范第 283 行)原文:**"允许 3D 归属:region 可含 Y bounds(垂直分片……),此时 Y 参与所有权不视为违背;XZ-column 降为推荐默认而非强制(见 D-2)。"**
- `CELL-2 [v2.0.2 修订]`(第 282 行):`(level, morton)` **降为可选编码之一**;允许以 `region_id`(连续 chunk 矩形 bounds)作等价所有权单位。
- `cell_id.ex` 契约自述:`:region` kind 是 **"含 Y 的 3D AABB,本仓当前生产路径"**。

因此 region=f(chunk_coord) 的 **3D 整除分块(含 Y)是 spec 内的当前生产路径**,不是违规新抽象。`region↔morton` 等价映射是 D-2 接缝(`cell_id.ex` 目前返回 `:mapping_not_implemented`),本稿在 region 编码上落地,morton 等价说明随 D-2 补齐——这正是规范要求的方向,而非偏离。

---

## 2. 当前临时设计清单

下表汇总测绘里全部临时/MVP/写死设计。**触发本次问题的两条标 ⚠️。**

| # | 设计点 | 现状 | 危害 |
|---|--------|------|------|
| W1 ⚠️ | dev 世界写死单盒子 | `DevSeed` 硬编码 `@default_region_id=1_000_001`、bounds `{-2,-2,-2}..{3,3,3}`(125 chunk)、`@default_logical_scene_id=1`、单 owner | 整个可玩世界=一个固定盒子;走/建出盒子即 `:unassigned_chunk`。本质是竞技场不是 MMO |
| W2 ⚠️ | route miss 是终态而非触发器 | `route_chunk_in_state`(map_ledger.ex:1107-1116)Enum.find 命中失败即 `{:error, :unassigned_chunk}`,Gate 直接拒绝玩家 | "走到没人去过的地方"是硬失败;无按需区域创建路径。**这就是越界编辑没反应的根因** |
| W3 | `MapLedger` 生产未接 durable | `WorldSup`(world_sup.ex:23-26)只传 `write_token_store`/`scene_node_registry`,**漏传** `persist_fn/load_fn`;`MapLedgerStore` 已就绪。旁边 `TransactionCoordinator` 就接了(:30-31) | 声明 `durable_authoritative` 实则纯内存;World 重启即丢区域/lease 目录,违 `CELL-23`(禁仅凭内存单进程保 epoch) |
| W4 | `MapLedger` 单 GenServer 非分布式单写者 | 每 World 节点一个本地具名进程,无 Horde/全局唯一 | 多 World 节点目录分叉;承载节点挂掉该 scene 控制面全不可用;无 HA |
| W5 | scene_node round-robin 冻结、掉线不重分配 | `SceneNodeRegistry` join-order round-robin,分配后冻结;`SceneNodeMonitor` `:nodedown` 只摘除不迁移 | 负载不均;节点掉线其 region 永久不可达(`fetch_scene_node_for_route` 拿到死节点)。违 `LOAD-2/3` |
| W6 | lease 靠 dev bootstrapper 定时器续约 | TTL 5 分钟,dev 区靠 `DefaultRegionBootstrapper` 每 30 分钟重 seed | 非 dev 区无续约路径,过期即 `:lease_expired` 写被拒;参数写死 |
| W7 | 路由 O(n) 线性扫描 | `route_chunk_in_state` 对全部 active assignment filter+find | region 数随无界世界增长后,每次移动/建造路由 O(region 数),单 GenServer 串行成瓶颈 |
| S1 | 程序化地形=DevSeed 一次性单点种子 | 唯一内容源是 bootstrap 时一次性 value-noise 高度图;无运行时 chunk-on-demand 生成 | 平台外即真空;无 biome/结构/矿脉/水;开放世界完全缺位 |
| S2 | chunk 进程永不卸载 | `ChunkProcess` 启动即常驻;`ChunkDirectory.chunks` 无界 map;无 idle/LRU/hibernate | 万级 chunk × 4096 macro header + 100ms tick + field worker 无界增长内存与定时器 |
| S3 | `ChunkDirectory` 不监控 chunk pid | 存裸 pid,仅 lookup 时 `Process.alive?` 懒检测 | chunk 崩溃后 subscriber 静默丢失,无 ChunkInvalidate,客户端卡陈旧快照 |
| S4 | 冷加载 persist-race 补丁化收敛 | init load + 单次 stale 自愈;残留 ~15-20s 预热窗口 | 启动期窗口仍可能 stale 反复;依赖"load 一次+单次 retry"乐观假设 |
| S5 | delta 失配即整块快照回退 | 属性/表面/material/load/stale-recover 全走 `push_snapshot_fallbacks`(空快照 ~78KB) | 高频涌现反复触发全量快照,带宽随订阅者线性放大;delta-base 失配→Resync 风暴 |
| S6 | replication outbox 失败仅降级 | `append_replication_outbox` 失败只 emit observe 继续 fanout | outbox 写失败该 delta 永不可重投;重连客户端只能全量恢复 |
| S7 | chunk 尺寸/schema 编译期写死 | `Storage` schema_version=1、16/8/4096 常量;空 chunk 恒 4096 header | 无 schema 演进;稀疏世界每个空 chunk 付 4096 元素成本 |
| S8 | 事务 fence delete 失败重试耗尽即放行 | commit/abort 后有界重试 3×25ms,耗尽则内存清 fence 放行 | DB 持久 fence 与内存可短暂分叉,依赖 orphan 路径兜底而非确定性补偿 |
| A1 ⚠️ | 整框重订阅 O(radius³) | 客户端跨界即整框;gate `subscribe_voxel_chunks` 无条件展开 5×5×5=125 逐个处理,不读 `voxel_subscriptions` 做差集 | 移动一格做 125×2=250 跨节点往返,5× 必要工作量 |
| A2 ⚠️ | 逐 chunk 同步阻塞 GenServer.call | `subscribe_voxel_chunk` 对每 chunk 串行 route+subscribe(各 15s 超时),全程占 connection 进程 | connection 在 ~250 往返期间无法处理该玩家其它帧(VoxelEditIntent/move 全堵 mailbox)。**实测编辑簇延迟 ~3.5s** |
| A3 | `MapLedger`/`ChunkDirectory` 单 GenServer 串行点 | 所有玩家所有 chunk 的 route/subscribe 汇聚两个单进程 | N 玩家同时移动→N×250 call 线性排队,队头阻塞,无法水平扩展 |
| A4 | known[] 仅抑制下行不抑制往返 | known 全量上行;命中也无条件 `encode_snapshot_payload`(chunk_process.ex:1086) | 省字节不省往返;known 包随 session 单调变大 |
| A5 | 无背压/带宽/优先级 fan-out | `send/2` 直灌 connection mailbox 立即转发,无水位/预算/优先级 | 慢客户端 mailbox 无界增长;近处地形与远景争带宽 |
| A6 | AOI 触发无滞回去抖 | `center != current` 即整框,每帧检查 | 边界抖动反复触发 125×2 风暴 |
| E1 ⚠️ | 客户端对被拒/stale 的 0x68 零反馈 | `VoxelIntentResult` 在 authority.rs:212 当 `Ignored` 丢弃;`is_failure()/result_label()` 写好却无人调用 | 编辑失败画面无变化无提示,玩家无法区分丢包/被拒/瞄错。建造靠玄学试错 |
| E2 | 无客户端预测/乐观放置 | `handle_live_voxel_build` 只发 intent 不写本地;等广播 ChunkDelta 才可见(含同步 PG 写) | 每次放/拆有可感知延迟;durable-before-ack 把 PostgreSQL 写进关键路径 |
| E3 | `client_intent_seq` 只发不存 | 无 seq→(target,action,old) 待决映射 | 封死乐观预测+回滚路径;reject 到达无法定位回滚格 |
| E4 | `VOXEL_REACH` 写死 + 纯客户端可达性 | reach=1200 写死;服务端 `apply_voxel_edit_intent` 只校验 cid>0 与 lease,零距离校验 | 不可调;改 client 即可任意距离编辑(只要 chunk 被 lease 覆盖),作弊面 |
| E5 | accepted ACK `authoritative` 恒空 [] | 0x68 可携 `AuthoritativeCell[]` 但服务端从不填 | 客户端无法用 ACK roll-forward 对账,只能等广播 delta |
| E6 | prefab/surface 失败语义不结构化 | 统一 `inspect` 文本 reason;部分成功无字段表达 | 客户端无法差异化反馈/重试;半个 prefab 不知为何 |
| C1 | 缓存按 scene_id 单值且写死 1 | `scene_{id}.vmc`,scene_id=1;路径不含服务器指纹 | 连不同服/scene 复用同一 `scene_1.vmc`;known[] 跨世界误 diff,隐性世界串味 |
| C2 | 周期 20s 全量写盘 | `save_map_cache_periodic` 每 20s 全量 encode,主线程同步 | 丢失窗口 20s;O(n) 写放大主线程卡顿 |
| C3 | AOI 驱逐与磁盘缓存冲突 | `evict` 物理删 chunk;写盘只 dump 当前 store | 走远→evict→写盘也没了→返回该区 known[] 空→全量重传。缓存只对 spawn 区有效 |
| C4 | field_store 无 AOI 驱逐 | 只在 `FieldRegionDestroyed` 删;无 evict 路径 | 离开 AOI 后 stale region 永不回收,仍参与烤光,内存单调增长 |
| C5 | 渲染整 chunk 全量重网格 | 任一 cell 变即整 16³+邻居主线程重网格,预算 8/帧 | 放一个方块掉帧;无 LOD/异步/持久光照 |
| C6 | 固定写死 24 项 build palette + material_color | 源码 const + 平行硬编码调色板,与服务端 catalog 人工对齐 | 新增材质改两处重编译;漂移(多次补 magenta);无资源/库存 |
| C7 | 缓存版本无校验 | seed 无条件信任磁盘版本;只校验 magic | 磁盘篡改/截断/回退时 advertise 错版本,服务端信任则渲染陈旧 |
| P1 | `logical_scene_id` 写死 1 + 无 world/region 维度 | wire 只有 `logical_scene_id:u64`+`chunk_coord:i32×3`,客户端恒发 1 | 无法多世界/多 scene/分片寻址;任何跨 world 须破协议加字段 |
| P2 | gate 不校验 `logical_scene_id` | 原样喂 `MapLedger` 路由,连接态无 scene 绑定 | 多 scene 上线即越权读写漏洞 |
| P3 | 订阅永不发 delta | `subscribe` 只判 known==当前:相等不发,否则全量 snapshot;从不算 N→M | 重连/AOI 重入即使差一格也全量;known 节省仅在"完全无变化"时生效 |
| P4 | 无连接级协议版本协商 | 无 protocol_version 握手;schema_version 仅在 snapshot 内写死 1 | 无法灰度/滚动升级;任何 wire 改动须 client 全量同步发布 |
| P5 | 无压缩/无批量合帧 | payload 明文;空 chunk 恒 4096 header 全量;125 chunk 进场 125 独立帧 | 稀疏 chunk ~78KB 基线浪费;进场风暴 |
| P6 | known[] 依赖 512 硬上限隐式约束 | known 全量上行无截断;gate 超 512 整帧 `:invalid_message` 拒绝 | 驱逐漏掉/加大半径→超 512→订阅帧被整体拒,玩家拿不到地形无降级 |
| P7 | 0x73/0x74 payload 自带 opcode | FieldRegion 消息 payload 含 opcode 字节绕过 codec;其它 voxel 消息不含 | 协议内两套约定,中间层(代理/录制/审计)须特判 |
| P8 | 0x72 EnvironmentUpdated 客户端无 decoder | 服务端已 fanout;bevy `decode_voxel_server_message` 无 arm,落 unsupported | 温湿度环境增量收不到/报错;涌现表现链客户端不完整 |

---

## 3. 目标架构

总纲:**采用"隐式坐标分区 + 目录派生化"为世界/区域底座(主导=Implicit-Partition 方案),把"编辑脊椎 + 按区一致性分级"嫁接其上(来源=EditLane 方案),路由洞见与懒物化生命周期取自 Lattice 方案,持久化的小状态行级 ledger + 稀疏 chunk 取自 Implicit-Partition 独有推论。** 一切与冻结稿 `CELL/LOAD/FROZEN` 对齐。

### 3.1 世界 / 区域

**最终设计:region = f(chunk_coord) 的确定性 3D 整除分块(含 Y),控制面目录退化为坐标派生视图,只持久化"偏离默认的覆盖项 + owner 心跳 lease"。**

- **地址即坐标(主导:Implicit-Partition)**:定义 `RegionGrid` 纯函数模块:`region_index(chunk_coord) = {div_euclid(cx,Sx), div_euclid(cy,Sy), div_euclid(cz,Sz)}`,`region_id = encode(logical_scene_id, region_index)`。`RegionAssignment` 去掉 `bounds_chunk_min/max` 写死常量,bounds 由 `region_index*S..(region_index+1)*S` 隐式导出;`contains_chunk?` 退化为 `region_index(coord)==自身` 的 O(1) 判定。**3D(含 Y)是 `CELL-3 [v2.0.2]` 明确允许的垂直分片**,且与 `cell_id.ex` 的 `:region` kind(3D AABB 含 Y)一字不差对齐。这一步同时消灭 W1/W2/W7/S1 的根因。
  - **Y 轴取舍**:对 99% 玩法集中在地表薄层的现实,`Sy` 可配置为远大于 `Sx/Sz`(如 `Sx=Sz=8, Sy=64`),使绝大多数垂直空间落入同一 region,避免大量永久空的天空/深岩 region 参与记账——既吃到规范允许的垂直分片杠杆(可把地下/地表/天空分给不同 owner),又不付均匀 3D 切分的空 region 税。这是对 Lattice 方案"均匀 stride"批评的正面回应:**stride 按轴可配置,非均匀**。
- **route miss → 懒物化触发器(来源:Lattice + EditLane 共识)**:`route_chunk_in_state` 的 `{:error, :unassigned_chunk}` 分支(map_ledger.ex:1113)改为 `ensure_region(region_id)`:查 `owner_leases` 命中且未过期→返回 owner;未命中→分配 `owner_epoch`(已有 `RegionEpochStore`)、容量感知选 scene_node、发 lease+write-token、durable upsert 覆盖项(仅当偏离默认放置)、返回 owner。**"走到没人去过的地方"成为正常懒分配路径,编辑永不越界被拒。** Gate 侧把"拒绝"改为"短暂 pending+排队该 intent 重试"。bounds 重叠校验整类消失(整除分块永不重叠)。
  - **与 `LOAD-7`(禁动态分裂)的合规性澄清**:懒物化的是一个**静态尺寸**(`CELL-4` base cell 当量)的隐式 region 的**运行时进程**,region 的尺寸/边界由坐标函数静态决定、永不在线改变;这不是 `level` 下降的动态分裂,符合 `LOAD-7`。`level` 上升的冷区合并(`CELL-4` 异构静态尺寸)作为后续静态扩容能力保留,不在 MVP 路径。
- **区域生命周期(来源:Lattice 命名,Implicit 简化)**:`Created`(坐标一映射即存在,纯逻辑)→ `Materialized`(首触达 ensure_region)→ `Active` → `Idle`(无订阅者 N 秒)→ `Drained`(持久化 + 停 ChunkProcess/field worker + ChunkInvalidate)→ `Dormant`(纯坐标态,内存零占用,可被任意重算唤醒)。消灭 S2"只有 active 一种稳定态"。
- **scene_node 弹性放置 + failover(对齐 `LOAD-2/3/4`)**:`SceneNodeRegistry` 升级容量/负载感知放置(记录每节点 region 数/内存/tick 预算,选最空闲健康节点),取代纯 round-robin;`SceneNodeMonitor` `:nodedown` 时把死节点 region 标 orphaned,**复用已存在的 `begin/plan_slice/prewarm/cutover/complete` 迁移状态机**自动迁移到存活节点(`owner_epoch` 必然前进使旧 write-token 失效)。**优先迁冷区(`LOAD-2`)、迁移决策配滞回阈值(`LOAD-3`)、热迁移排最末(`LOAD-4`)。** 消灭 W5。
- **控制面 HA(对齐 `CELL-23`)**:`MapLedger` 走 Horde 全局单写者按 `logical_scene` 分片(每 logical_scene 一实例,集群内唯一);承载节点挂掉 Horde 在存活节点重启它,从 DB(覆盖项 + owner_leases)+ 坐标函数重建 `hot_index`——**重启自愈,无内存目录可丢**。`owner_epoch` DB 线性化(已有)是防双写底座,Horde 分片只切负载与故障域。消灭 W3/W4。
- **owner 心跳续租**:scene 实例作为 owner 周期向 ledger 续租,ledger 据心跳超时回收并触发迁移;TTL/刷新参数可配,去掉对 `DefaultRegionBootstrapper` 定时器的依赖。消灭 W6。
- **多世界**:`logical_scene_id` 进协议字段(见 §3.6),`Sx/Sy/Sz`/biome 按 logical_scene 配置,去掉 =1 写死。

**关键决策与取舍**:放弃任意形状 region 的灵活性(region 必须是固定 stride 的规则盒子),换 O(1) 路由 + 无界世界 + 零重叠校验 + 目录派生重启自愈四重收益。少数例外(boss 房/副本)由覆盖项表或独立 instance 通道承载,不污染开放世界 lattice。**保留覆盖项表的诚实说明**:覆盖项 + owner_leases 仍是被维护的显式状态,但它只装"非默认放置/活跃租约"这一小撮(O(活跃 region) 而非 O(全 region)),不再是被批判的全 assignment 表——这是减状态而非消除状态。

### 3.2 AOI / 流式

**最终设计:增量订阅 + 非阻塞 per-connection 订阅 worker + 批量跨节点 + 优先级背压。这是修复本次 3.5s 编辑簇延迟的核心。**(三方案此层完全共识,主导取 Implicit-Partition 的差集表述,流控取 EditLane 的物理隔离表述。)

- **差集订阅(消灭 A1/A4)**:gate 持每连接 `voxel_subscriptions` 集合,跨边界只算 `new_box ∖ old_box`(一个 slab ≈ radius² ≈ 25)做 route+subscribe,`old_box ∖ new_box` 做 unsubscribe;移动一格成本从 O(radius³)=125 降到 O(radius²)=25。客户端 `subscribe_voxel_around` 同样只对真正新增 chunk 发起;known[] 只携带新进框内摘要而非整个 session store;`ChunkProcess.subscribe` known 命中时不再无条件 `encode_snapshot_payload`(chunk_process.ex:1086)。
- **非阻塞(消灭 A2,本次问题的直接修复)**:把 route+subscribe 从 connection 主 GenServer 同步 `handle_info` 剥离到 **per-connection 订阅 worker**(Task/独立 GenServer),connection 只投递订阅意图并立即返回,订阅结果与快照经现有 fan-out 通道异步回来。**connection 主进程永不被订阅风暴阻塞,VoxelEditIntent/movement 帧始终低延迟处理——3.5s 编辑簇延迟根除。**
- **批量跨节点(消灭 A3 部分)**:订阅走已存在的 `route_chunks_with_leases`(map_ledger.ex:343,prefab 已用)一次拿全 slab 路由;为 `ChunkDirectory` 加 `{:subscribe_many, coords}` 批量接口把 N 次 call 压成 1 次;ChunkProcess 冷启动/快照编码移出订阅同步路径。
- **去单点(消灭 A3,对齐 `CELL-6/21`)**:`MapLedger` 按 logical_scene 分片;route 结果在 Gate 侧 ETS 缓存到 lease epoch 失效(**ETS 仅作 routing hint,权威性由 `owner_epoch` 校验保证,严格符合 `CELL-6/21`**);`ChunkDirectory` 按 region 分片。
- **增量同步(消灭 P3/S5)**:订阅命中已有版本时服务端基于 known_version 算 N→M delta(维护有界 per-chunk delta ring buffer,缺口超窗口才回退全量),不再"全量 snapshot 或不发"二选一。
- **背压 + 优先级(消灭 A5,对齐 `LOAD-5/REPL-3`)**:voxel 流接入与 `player_move` 同级的 `priority_band`(按到玩家距离/视锥分 band,脚下地形优先、远景限速渐进)+ 每 tick 字节预算 + 合批;connection→socket 用 `{active, once}` + 写水位监测,mailbox/未发队列超阈值时向上游 ChunkProcess 反压(丢可重发快照、保 delta 顺序)。**`LOAD-5` 要求复制层第一天走"打分+出口预算"接口,禁止全量广播渗入玩法代码——voxel 流必须接入这个接口。**
- **AOI 去抖(消灭 A6,对齐 `LOAD-3` 滞回精神)**:chunk 边界滞回带 + 沿速度方向预取下一 slab + 一帧内多次跨界合并。
- **field 层对齐(消灭 C4)**:field_store 跟随 chunk AOI 驱逐回收 region,stale region 不再参与烤光。
- **共享实现**:`ws_connection` 与 `tcp_connection` 当前逐字镜像,抽出共享 `VoxelSubscription` 模块杜绝漂移。

**关键决策与取舍**:per-connection 订阅 worker 增加每连接一个进程与跨进程消息,换 connection 主进程永不阻塞——在"编辑响应"目标下完全值得。per-chunk delta ring buffer 增加 Scene 侧内存,窗口大小是带宽 vs 内存的可调参数。

### 3.3 编辑一致性

**最终设计:编辑提升为一等公民,乐观预测 overlay + 服务端权威校正 + 稳定错误码反馈闭环 + 按区一致性分级。**(主导=EditLane 脊椎,overlay 双层来自 EditLane 独有洞见,一致性分级是 EditLane 对 Implicit 缺口的补强。)

- **客户端乐观预测 overlay(消灭 E2/E3,来源:EditLane 双层模型)**:点击即在一个 **预测 overlay**(叠加在 base authority chunk 上渲染)写入预测 cell(立即可见),base 权威镜像不被污染;记 pending-edit 表 `client_intent_seq → {chunk_coord, macro_index, operation, 旧 CellState 快照, base chunk_version/cell_hash, 超时}`(补上 runtime.rs:90 只发不存的缺口)。复用移动层 `sim/predictor.rs` 的 "fixed-step 预测 + seq 对账 + reconcile" 骨架(pending 表 ≈ input buffer,authoritative cell ≈ server snapshot)。
- **服务端权威校正(消灭 E1/E5)**:0x68 `VoxelIntentResult` 必须被客户端消费(当前 authority.rs:212 当 `Ignored`):
  - 服务端 `voxel_edit_intent_result_ok`(ws_connection.ex:1501)**真正填满** `AuthoritativeCell[]`(chunk_version/cell_version/cell_hash/payload,wire 双端 codec 已就绪);
  - 客户端 accepted → 用 authoritative cell 从 overlay 提交进 base 并按 cell_hash 与广播 delta 去重(谁先到用谁,cell_version 单调保序);rejected/stale → 从 overlay 撤回预测格到旧值快照。
- **反馈闭环(消灭 E1/E6)**:按 result_code(accepted/deferred/rejected_occupied/rejected_empty/rejected_out_of_reach/stale_version/stale_hash/unassigned/lease_lost/partial_applied)在 HUD/光标/音效给即时反馈(接通已写好的 `is_failure()/result_label()`);reason 从 Elixir `inspect` 文本改为**稳定 enum 错误码**,客户端本地化文案;prefab 部分成功用 `deferred + applied_count` 表达。
- **服务端权威可达性(消灭 E4,反作弊)**:把"玩家权威坐标↔目标 world_micro 距离 + 视线遮挡 + 工具/物品 reach(数据化按方块/工具配置)"做成 gate/scene 侧校验;客户端 `VOXEL_REACH` 退化为纯预测/UI 提示而非安全边界。
- **乐观并发启用**:编辑携 `expected_chunk_version`(全 chunk)+ `expected_cell_hash`(单 macro)(服务端校验 chunk_process.ex:2054 已实现),取代客户端恒发 0xFF 哨兵;哨兵保留给"无视并发强写"特例。
- **按区一致性分级(关键补强,来源:EditLane 对 Implicit ack-then-persist 缺口的修补)**:`durable-before-ack` 改为**可按 region 重要性配置的两档**——
  - **核心/PvP/领地区**:保留 durable-before-ack(强一致,手感让位正确性);
  - **普通建造区**:ack-then-persist(内存权威即时 ACK + 异步 persist,`command_id` 幂等 + write-token fence + outbox 保 durability),把 PostgreSQL 写移出可见延迟关键路径。
  - 这直面 Implicit-Partition 被批"内存已 ack 未落库窗口无兜底"的缺口:**默认建造区接受秒级窗口(`command_id` replay + 崩溃后从 DB canonical 重载压最小),核心区不接受则用 durable-before-ack**。跨 region 的 prefab/大编辑原子事务统一走 `TransactionCoordinator` 的 `decision_version` 全序(`AUTH-3 [v2.0.2]`:跨 chunk 顺序由事务 decision_version 补足),**混合一致性下跨 region 原子性由事务协调器而非乐观 ack 保证**——这补上 EditLane 自身被批的"两通道无序回滚"坑:多格原子编辑的因果一致由事务层、不由 per-cell 通道顺序保证。
- **速率限制**:服务端对单连接编辑频率限流,校验 material/blueprint/surface_type 合法性,取代"cid>0 即放行"。

**关键决策与取舍**:ack-then-persist 放宽强一致换手感,但**仅对普通建造区且有事务层兜底跨区原子性**;乐观预测引入回滚抖动,靠 cell_hash 精确对账 + 平滑回滚动画 + 大多数编辑会 accepted 使抖动罕见。`outbox durability 时点`明确为:ack-then-persist 区的 outbox **同步落 DB**(这是该区唯一保留的一次同步写,但它是异步复制日志的提交点,不在玩家可见的编辑反馈路径上——玩家看到的是 overlay 即时反馈),从而既移出"可见延迟"又不丢 durability——回应 EditLane 自身被批的 outbox 时点模糊。

### 3.4 持久化

**最终设计:控制面小状态行级 ledger + chunk 稀疏表示 + 运行时 WorldGen + 客户端内存/磁盘分层。**(主导=Implicit-Partition 独有的小状态行级 upsert + 稀疏 chunk,WorldGen 来自 Lattice/Implicit 共识。)

- **MapLedger 接 durable + 行级 upsert(消灭 W3,Implicit 独有锋利推论)**:生产 `WorldSup` 立即传 `MapLedgerStore` 的 `persist_fn/load_fn`(已就绪);**且因目录是坐标派生态,只持久化覆盖项 + owner_leases 小状态,把 `MapLedgerStore` 的单行 `term_to_binary` blob upsert(map_ledger_store.ex:41-64,`@row_id=1`)改为新建 `voxel_region_overrides` 表按 region_id 行级 upsert**——消除单行 blob 随 region 数膨胀/写放大。重启从 DB + 坐标函数重算,消除 epoch 重建致 `:stale_token` 与 ~20s 预热窗口(S4 根因)。
- **chunk 真值 + 稀疏表示(消灭 S7/S4,Implicit 独有)**:保留已较完善的 `chunk_version` 单调 CAS + advisory lock + `CommandLog` exactly-once(`CELL-19 [v2.0.2]` 合规);**空/稀疏 chunk 用稀疏表示(palette + 非空 macro 列表),空快照从 ~78KB 降到几十字节**(无界世界绝大多数 chunk 为空气/地下,这是数量级收益);`schema_version` 从写死改为版本化迁移路径(`FROZEN-4` 要求破坏性变更提供迁移计划)。**明确丢弃"内容寻址作存储键"的命名**——评审正确指出它会破坏 per-coordinate 单调版本不变量;真正落地的是稀疏编码,主键仍是 `(logical_scene_id, coord)` + `chunk_version` CAS。补启动期 load↔first-write 结构性串行化,消除残留 persist-race。
- **运行时 WorldGen(消灭 S1)**:chunk 进程首次访问且 DB 无行时,按确定性可版本化地形函数(seed+噪声+biome+结构/矿脉/水,按 logical_scene 配置,复用已有 `terrain_noise.ex`)按需生成——**生成结果 = chunk_version 基线,首次编辑在其上 bump**,与冷加载/编辑/持久化版本语义统一。`DevSeed` 退化为"default biome 的一组参数"而非写死盒子。
- **chunk 生命周期(消灭 S2/S3)**:基于活跃度(订阅者数/最近访问/lease)的 LRU 驱逐/休眠;lease 撤销时确定性 quiesce(持久化→停 field worker→ChunkInvalidate 广播→优雅停进程)。`ChunkDirectory` monitor chunk pid,崩溃 emit + 主动 ChunkInvalidate 通知 subscriber 重订阅。
- **可靠投递收尾(消灭 S6/S8)**:replication outbox 补 watermark/重投消费端/积压上限/GC,断线重连走增量补齐;事务 fence 清理用确定性补偿事务取代"重试耗尽即放行"。
- **客户端分层缓存(消灭 C1/C2/C3/C7)**:缓存按 `(server_identity, real_scene_id)` 共同 keying(路径含服务器指纹哈希),杜绝跨世界串味;**内存 store 走 AOI LRU,磁盘缓存独立持久化"已探索世界全史"**(evict 出内存的 chunk 仍留磁盘,返回老区 known[] 增量拉)——解耦 evict 与缓存,消灭驱逐反噬;per-chunk 脏标增量写(append-log 或嵌入式 KV 如 redb)+ 异步落盘,崩溃窗口降到秒级;per-chunk 校验和 + 版本单调校验,服务端对 known[] 版本做合法性校验防伪造。

**关键决策与取舍**:稀疏 chunk + schema 迁移 + 全路径 delta 化是大工程,触及持久化格式与所有 storage 写路径,迁移期需双写/版本兼容窗口 + 跨语言 golden 重做一轮;但空 chunk 数量级收益对稀疏无界世界是必须的。

### 3.5 客户端

**最终设计:双 store + 预测层 + catalog 驱动 + 异步网格 + 可发布 UX。**(此层三方案共识,主导取 Implicit-Partition 表述,预测 overlay 取 EditLane。)

- **store 解耦**:内存 `AuthorityStore` 走 AOI LRU(evict);磁盘缓存持"探索全史";base + 预测 overlay 双层渲染(见 §3.3);field_store 跟随 chunk AOI 驱逐。
- **渲染异步化(消灭 C5)**:网格化与光照烘焙下放 off-thread/compute,dirty 粒度细到 micro 区域而非整 16³ chunk(放一个方块不再整 chunk+邻居主线程重网格),加 LOD/距离剔除;持久光照替代每帧逐顶点烤光。
- **catalog 驱动(消灭 C6)**:`material_color` 与 build palette 由服务端下发 catalog(`CatalogPatch` wire 已有但渲染未消费)动态构建,客户端不再硬编码 id→color(消灭 magenta 漂移);24 项线性滚轮升级为分类/分页/可搜索构件库 UI;infinite-resource 接资源/库存/成本/权限系统(对齐 `docs/2026-06-23-loop-and-zone-scale.md` Track A "采集→建造→涌现"闭环:挖方块产材料、放方块消耗材料)。
- **崩溃恢复**:配合服务端 `ChunkDirectory` monitor + ChunkInvalidate 广播,客户端收 invalidate 即重订阅,消灭卡陈旧快照。
- **decoder 完整性(消灭 P8)**:每个服务端 opcode(含 0x72 EnvironmentUpdated)必须有客户端 dispatch + golden round-trip parity,CI 强制 server-opcode↔client-decoder 全覆盖。

### 3.6 协议

**最终设计:显式世界寻址 + 强校验 + 版本协商 + 增量优先 + framing 统一。纪律:只追加字段不破坏 wire layout,接入 golden-fixture 跨语言 parity。**(此层三方案共识。)

- **世界/区域寻址(消灭 P1,对齐 `FROZEN-1`)**:wire 显式携带 `logical_scene_id`(/`world_id`)——`logical_scene_id` 已在每条 voxel 消息但客户端写死 1,先让客户端真传服务端下发的 `real_scene_id`;`region_id` 由坐标函数推导**不必上 wire**(无界分区的优势),但 `region↔morton` 等价说明随 D-2 在服务端补齐(`cell_id.ex` 当前 `:mapping_not_implemented`)。`chunk_coord` 保持 i32×3。
- **scene 归属强校验(消灭 P2,对齐 `CELL-6`)**:gate 把连接绑定到认证态/进场态授权的 scene 集合,拒绝越权 `logical_scene_id` 订阅/编辑,关闭越权读写面。
- **版本协商握手(消灭 P4,对齐 `FROZEN-4`)**:connect 时交换 `protocol_version` + capability flags,支持多版本并存窗口、灰度/滚动升级、旧客户端优雅降级,取代"同版本同时部署否则长度 mismatch 断线"。
- **增量优先(消灭 P3/S5)**:订阅基于 known_version 发 N→M delta;所有 storage 写路径(涌现/反应/场/结构/属性/表面元件/对象)产 delta 取代 `push_snapshot_fallbacks` 全量,高频涌现合批/限频/脏区聚合。
- **压缩与批量(消灭 P5)**:稀疏/空 chunk header RLE + payload 可协商压缩(zstd/lz4)+ 多 chunk 进场批量合帧。
- **framing 统一(消灭 P7)**:所有 voxel 消息统一"payload 不含 opcode、framing 层加 opcode",消除 0x73/0x74 自带 opcode 特例。
- **known[] 健壮降级(消灭 P6)**:客户端显式 cap + 服务端对超限截断/分页而非整帧 `:invalid_message` 拒绝。

---

## 4. 分阶段实施计划

原则:有序、每阶段独立可交付且不破坏现状、逐 step 可单独 commit。**第一阶段(阶段 0)立刻缓解"越界编辑没反应"——但因真正的根因是 route miss 终态(W2),阶段 0 给即时反馈让玩家"知道为何没反应",阶段 1 才让"不再没反应"。** 这是有意的:先用零风险改动止血(让失败可见),再做结构性修复(让失败消失)。

> **遵守本仓纪律**:决策稿先行(本稿)、逐 step commit、不 push、不留兼容分支、Windows 测试方式(`cd apps/<app> && cmd /c mix test --no-start`)。

### 阶段 0 — 编辑反馈闭环(止血,零协议破坏,纯客户端 + ACK 填充)

立即让"越界编辑没反应"变成"越界编辑有明确提示"。

- step 0.1:服务端 `voxel_edit_intent_result_ok/error` 把 reason 从 `inspect` 文本改为稳定 enum 错误码(含 `:unassigned`/`:out_of_reach`/`:stale_version` 等)。
- step 0.2:服务端 0x68 成功 ACK 填满 `AuthoritativeCell[]`(wire 双端 codec 已就绪)。
- step 0.3:bevy 客户端把已写好的 `is_failure()/result_label()`(intent_result.rs,目前只在 observe.rs 当日志)接到 HUD/光标变色/音效。
- **消灭**:E1、E5、E6 部分。
- **风险**:极低(复用已铺管道,无后端重构)。
- **验收**:headless harness 发越界 intent → 收到 `:unassigned` enum → HUD 显示"越界,该区域尚未开放";golden round-trip parity 通过。

### 阶段 1 — 隐式分区核心 + route-miss 懒物化(消除越界,世界无界)

本次问题的结构性根治。**世界此刻即无界可探索可建造,`:unassigned_chunk` 拒绝消失。**

- step 1.1:新增 `RegionGrid` 纯函数模块(`region_index`/`region_id`/bounds 派生,`Sx/Sy/Sz` 可配置)。
- step 1.2:`RegionAssignment` 去 bounds 写死常量改派生;`contains_chunk?` 改 O(1)。
- step 1.3:`route_chunk_in_state` 改 O(1) lattice 查 + miss 分支改 `{:materialize, region_id}`。
- step 1.4:`ensure_region` 懒物化路径(分配 epoch + 容量选 node + 发 lease);Gate 侧 route miss 改"pending 排队重试"而非拒绝。
- step 1.5:`DevSeed` 退化为"spawn 周围预热少量 region 内容"的 WorldGen 调用,不再定义边界。
- **消灭**:W1、W2、W7。
- **风险**:中(改所有权寻址语义,需与 region/lease/owner_epoch 契约、golden fixture 对齐;`region↔morton` D-2 等价说明须同步补)。
- **验收**:玩家走出原 125-chunk 盒子任意距离仍能订阅/编辑;路由不再返回 `:unassigned_chunk`;`mmo_contracts` cell_id 测试 + map_ledger 测试通过。

### 阶段 2 — durable region 目录(重启自愈)

- step 2.1:`WorldSup` 给 `MapLedger` 接 `MapLedgerStore` 的 `persist_fn/load_fn`(已就绪),先让现有目录自愈。
- step 2.2:新建 `voxel_region_overrides` 表 + 行级 upsert,持久化只存覆盖项 + owner_leases。
- step 2.3:owner 心跳续租取代 `DefaultRegionBootstrapper` 定时器。
- step 2.4:补 telemetry(route-miss 率/lease 续约失败率/迁移耗时)。
- **消灭**:W3、W6、S4 根因。
- **风险**:低(阶段 2.1 零行为变更)。
- **验收**:World 节点重启后区域目录从 DB + 坐标函数恢复,无 ~20s 预热窗口,无 `:stale_token`。

### 阶段 3 — 运行时 WorldGen + chunk 生命周期

- step 3.1:chunk 首触达且 DB 无行时调确定性 WorldGen 生成基线(=chunk_version 0)。
- step 3.2:chunk 进程 LRU/idle 驱逐 + lease 撤销 quiesce。
- step 3.3:`ChunkDirectory` monitor chunk pid,崩溃 emit + ChunkInvalidate 广播。
- **消灭**:S1、S2、S3。
- **风险**:中(生成/加载版本语义须统一)。
- **验收**:走到全新区域看到程序化地形;万级 chunk 内存有界;杀掉 chunk 进程后订阅者收到 invalidate 并重订阅。

### 阶段 4 — AOI 增量 + 非阻塞(消灭 3.5s 编辑簇延迟)

- step 4.1:抽出共享 `VoxelSubscription` 模块(ws/tcp 去镜像)。
- step 4.2:gate 差集订阅(只处理新进 slab)。
- step 4.3:route+subscribe 剥离到 per-connection 订阅 worker。
- step 4.4:`route_chunks_with_leases` 批量 + `ChunkDirectory.subscribe_many`。
- step 4.5:客户端滞回带 + 方向预取 + 一帧合并。
- **消灭**:A1、A2、A3 部分、A4、A6。
- **风险**:中(进程拓扑变化,需压测延迟/吞吐)。
- **验收**:移动跨边界时编辑帧延迟 < 100ms(当前 ~3.5s);移动一格订阅往返从 250 降到 ~50。

### 阶段 5 — 编辑预测 + 反作弊

- step 5.1:客户端 pending-edit 表 + 预测 overlay 即时渲染。
- step 5.2:消费 0x68 做 accepted 提交 / rejected 回滚 + 超时重发。
- step 5.3:服务端权威可达性校验(坐标+视线+工具 reach),客户端 reach 降为 UI。
- step 5.4:启用 `expected_chunk_version`/`expected_cell_hash` 乐观并发。
- **消灭**:E2、E3、E4。
- **风险**:中(回滚抖动,需 cell_hash 对账 + 平滑动画)。
- **验收**:点击即见方块(0ms 本地);被拒平滑回滚 + HUD 提示;伪造距离编辑被服务端拒。

### 阶段 6 — 按区一致性 + 增量复制全覆盖 + 背压

- step 6.1:ack-then-persist(普通建造区)+ durable-before-ack(核心区)按 region 配置;outbox 同步落库时点明确。
- step 6.2:订阅 N→M delta + per-chunk delta ring buffer。
- step 6.3:所有 storage 写路径产 delta + 高频涌现合批限频。
- step 6.4:voxel 流接入 `priority_band` + 字节预算 + socket 背压(`LOAD-5`)。
- **消灭**:E2 延迟尾、P3、S5、S6、S8、A5。
- **风险**:中高(一致性模型分级 + delta 历史窗口 + 跨区事务原子性)。
- **验收**:建造区编辑手感不受 PG 延迟支配;涌现区带宽从 O(N×chunk_size) 降到 O(N×delta);慢客户端 mailbox 有界。

### 阶段 7 — 协议成熟 + 多世界

- step 7.1:`real_scene_id` 进协议字段 + gate scene 授权强校验。
- step 7.2:`protocol_version` + capability 握手。
- step 7.3:framing 统一(去 0x73/0x74 特例)+ 补 0x72 decoder + CI opcode↔decoder 闸门。
- step 7.4:稀疏 header RLE + payload 压缩 + 批量合帧。
- **消灭**:P1、P2、P4、P5、P7、P8、P6。
- **风险**:中(破坏性协议变更需版本协商分阶段铺,旧客户端 world_id=0 兼容窗口)。
- **验收**:多 scene 可寻址且越权被拒;灰度升级旧客户端不断线。

### 阶段 8 — 控制面 HA + 弹性 + 客户端工业化

- step 8.1:`MapLedger` 走 Horde 按 logical_scene 分片单写者(`CELL-23`)。
- step 8.2:scene_node 容量感知放置 + `:nodedown` 复用 migration 状态机自动 failover(`LOAD-2/3/4`)。
- step 8.3:稀疏 chunk 表示 + schema 版本化迁移 + 事务 fence 确定性补偿 + outbox 重投闭环。
- step 8.4:客户端缓存分世界 keying + 内存/磁盘分层 + 增量异步落盘 + per-chunk 校验和 + field AOI 驱逐。
- step 8.5:catalog 驱动 palette/material + 异步网格 + LOD + 持久光照 + 资源/库存系统。
- **消灭**:W4、W5、S7、C1-C7 全部。
- **风险**:高(HA/分片/选主 + 持久化格式迁移,工程量最大)。
- **验收**:承载节点挂掉控制面秒级从 DB 重选主无数据丢失;scene_node 掉线 region 自动迁移;客户端跨服无缓存串味。

---

## 5. 与现有代码的迁移路径(点名关键文件/模块)

### 世界 / 区域(World)
- `apps/world_server/lib/world_server/voxel/map_ledger.ex`:`route_chunk_in_state`(:1107)改 O(1) + miss→`ensure_region`;新增 `ensure_region`/`hot_index`/owner 心跳续租;Horde 分片(阶段 8)。
- `apps/world_server/lib/world_server/voxel/region_assignment.ex`:去 bounds 写死改派生,`contains_chunk?` 改 O(1)。
- **新增** `apps/world_server/lib/world_server/voxel/region_grid.ex`:`region_index`/`region_id`/bounds 纯函数。
- `apps/world_server/lib/world_server/voxel/scene_node_registry.ex` + `scene_node_monitor.ex`:容量感知放置 + `:nodedown` 自动迁移。
- `apps/world_server/lib/world_server/sup/world_sup.ex`:给 `MapLedger` 接 `persist_fn/load_fn`(:23-26,对照 `TransactionCoordinator` :30-31)。
- `apps/world_server/lib/world_server/voxel/dev_seed.ex` + `default_region_bootstrapper.ex`:退化为 WorldGen 预热,去定时器续租。
- `apps/world_server/lib/world_server/voxel/migration_plan.ex`:failover 复用其状态机。
- `apps/mmo_contracts/lib/mmo_contracts/cell_id.ex`:落地 `region_to_morton`/`morton_to_region`(D-2 接缝,当前 `:mapping_not_implemented`)。

### 持久化(DataService)
- `apps/data_service/lib/data_service/voxel/map_ledger_store.ex`:单行 blob(:41-64)改 `voxel_region_overrides` 行级 upsert。
- **新增** migration:`voxel_region_overrides` 表。
- `apps/data_service/lib/data_service/voxel/chunk_snapshot_store.ex`:稀疏表示 + schema 迁移(保留 chunk_version CAS)。
- `apps/data_service/lib/data_service/voxel/write_token_store.ex` / `region_epoch_store.ex`:不变(已对)。
- `apps/data_service/lib/data_service/voxel/outbox.ex`:补 watermark/重投/GC。
- `apps/data_service/lib/data_service/voxel/chunk_pending_transaction_store.ex`:fence 确定性补偿。

### 场景 chunk(Scene)
- `apps/scene_server/lib/scene_server/voxel/chunk_process.ex`:WorldGen 基线生成;LRU/quiesce;known 命中不再编码快照(:1086);所有写路径产 delta 取代 `push_snapshot_fallbacks`(:4098);per-chunk delta ring buffer;ack-then-persist 分级。
- `apps/scene_server/lib/scene_server/voxel/chunk_directory.ex`:monitor pid + ChunkInvalidate;`subscribe_many` 批量接口。
- `apps/scene_server/lib/scene_server/voxel/storage.ex`:稀疏表示 + schema 版本化(:33-37)。
- `apps/scene_server/lib/scene_server/voxel/codec.ex`:N→M delta 编码;framing 统一;0x72 编码确认。
- `apps/scene_server/lib/scene_server/voxel/field/field_provisioner.ex`:AOI 驱逐协调。

### 网关(Gate)
- `apps/gate_server/lib/gate_server/worker/tcp_connection.ex` + `ws_connection.ex`:**抽出共享 `VoxelSubscription` 模块**;差集订阅(`subscribe_voxel_chunks` :2800/2932);per-connection 订阅 worker;`route_chunks_with_leases` 批量(:1395 已存在未用);scene 授权强校验(:1380);0x68 enum reason + `AuthoritativeCell` 填充(:1488/1501);服务端可达性校验(`apply_voxel_edit_intent` :1212);voxel 流 `priority_band` + 背压(对照 player_move :131-167)。
- `apps/gate_server/lib/gate_server/codec.ex`:protocol_version 握手;known[] 截断;压缩。

### 客户端(bevy)
- `clients/bevy_client/src/voxel/authority.rs`:base + overlay 双层;消费 0x68(:212);known cap;per-chunk 校验。
- `clients/bevy_client/src/voxel/authority_plugin.rs` + `plugin.rs`:pending-edit 表;乐观预测(plugin.rs:460);差集订阅 + 滞回去抖(plugin.rs:312);reach 降为 UI(:43)。
- `clients/bevy_client/src/voxel/wire/intent_result.rs`:接 HUD(`is_failure`/`result_label`)。
- `clients/bevy_client/src/voxel/persistence.rs`:分世界 keying + 内存/磁盘分层 + 增量异步落盘。
- `clients/bevy_client/src/voxel/chunk_render.rs`:micro dirty + off-thread + LOD + 持久光照;catalog 驱动 material_color(:492)。
- `clients/bevy_client/src/voxel/build_palette.rs`:catalog 驱动 palette(:69)。
- `clients/bevy_client/src/voxel/field_view.rs`:AOI 驱逐。
- `clients/bevy_client/src/net/runtime.rs` + `plugin.rs`:`real_scene_id` 取代写死 1;client_intent_seq 存表(runtime.rs:90)。
- `clients/bevy_client/src/voxel/wire/mod.rs`:补 0x72 decoder + golden parity。

### 协议文档
- `docs/2026-04-10-线协议规范.md`:world/scene 寻址字段、版本协商、framing 统一、增量 delta、压缩——只追加不重排。

---

## 6. 风险与未决问题

### 已识别风险
1. **阶段 1 是寻址 keystone**:隐式分区一旦落地即改变所有权寻址语义,与 region/lease/owner_epoch/CellId 契约、golden fixture、迁移状态机耦合。虽标"独立可交付",但它在寻址轴上是 keystone 不是可回退增量——须先把 `cell_id.ex` D-2 等价映射、golden parity 守住再铺。
2. **混合一致性的跨区原子性**:ack-then-persist 区与 durable-before-ack 区相邻时,跨 region 的 prefab/大编辑必须全走 `TransactionCoordinator` 的 `decision_version` 全序——若有任何编辑路径绕过事务协调器直接乐观 ack,跨区原子性破裂。须 CI/审计强制"跨 region 编辑必经事务层"。
3. **Horde 分片脑裂**:网络分区下 Horde 再均衡可能短暂双实例;靠 `owner_epoch` DB 线性化(`CELL-23`)兜底防双写真值,但分片粒度(logical_scene)决定故障爆炸半径,须列入 `CELL-22` 故障演练清单。
4. **稀疏 chunk + schema 迁移**:改持久化与 wire 格式,需双写/版本兼容窗口 + 跨语言 golden 重做一轮,迁移期长。
5. **8 阶段长征**:可发布性真正解锁在中后段(HA 在阶段 8)。**缓解**:阶段 0-5 已交付"无界世界 + 即时建造 + 重启自愈 + 非阻塞流",单 World 节点即可发布小规模产品;HA 是规模门槛非首发门槛。

### 未决问题(需拍板)
1. **`Sx/Sy/Sz` 取值**:建议 `Sx=Sz=8 chunk`(对齐 `CELL-4` base cell 当量),`Sy=64`(地表薄层减空 region)。需按 chunk 体量与玩法密度压测定稿,且进 logical_scene 配置而非全局写死。**待压测。**
2. **`region↔morton` D-2 映射策略**:`cell_id.ex` 留的等价接缝具体如何编码(region_index→morton 的位交织规则)?XZ-column morton 与 3D region 的等价说明须在 D-2 定稿——这是 `CELL-2 [v2.0.2]` 的硬性要求。**待 D-2 决策稿。**
3. **核心区 vs 建造区的一致性边界由谁定义**:按 logical_scene 全局配?按 region 标记?按领地系统(build-reservation,当前是 stub)?须与 Track A 资源/领地系统对齐。**待领地系统设计。**
4. **`LOAD-9~11` 产品阀门**:若 MVP 不实现热迁移,须至少提供一个产品层阀门(软上限/分线/实例化/排队/时间膨胀)。本稿世界层支撑分线/实例化,但具体阀门策略未定。**待容量设计。**
5. **客户端嵌入式 KV 选型**(redb vs sled vs 自定义 append-log):影响崩溃恢复窗口与跨平台。**待技术选型。**
6. **per-chunk delta ring buffer 窗口大小**:带宽 vs Scene 内存的权衡参数,无界世界 + 多订阅者下的内存上界须压测。**待压测。**
---

## 7. 实施进度日志(2026-06-25)

### ✅ 阶段 0 — 编辑反馈闭环(止血)
- `clients/bevy_client/src/hud/edit_feedback.rs`(新):`EditFeedback` 资源 + `EditFeedbackPlugin`,
  失败 ACK(`VoxelIntentResult.is_failure()`)→ 屏幕中上方淡入淡出中文提示(`localize_reason` 剥离
  `inspect` 前导冒号 + 映射);接入 `net/plugin.rs::poll_network_events`,失败不再被静默吞掉。
- commit `8a3e902`。bevy lib 355/0。

### ✅ 阶段 1 — 隐式分区 + route-miss 懒物化(根治越界,世界无界)
- step1.1 `WorldServer.Voxel.RegionGrid`(新,commit `57e703c`):`region = f(chunk_coord)` 纯函数;
  `region_id` 把 `logical_scene_id`(24 位)+ zigzag(rx 16/rz 16/ry 7)打包成全局唯一 63 位 bigint
  (保持 assignments/leases/epoch 按 region_id 单键索引不变);双射逆 `decode_region_id`;越界抛错。
- step1.3/1.4 `MapLedger`(commit `5a88db6`):`route_chunk_in_state` 改 O(1) grid-id 快路径 + 扫描回退
  (对显式 region 逐位不变);新 `route_chunk_with_lease_ensuring`/`route_chunks_with_leases_ensuring`
  懒物化(选 owner 节点 + 单调 epoch + lease + 写令牌),失败干净回滚;纯路由保留给 validate/事务。
- step1.4 接线(commit `3dc56ed`):Gate(tcp+ws)订阅/编辑/prefab 改 `*_ensuring`;region_id 位预算
  适配真实 scene id;`ensure_region` `safe_locate` 防崩。
- step1.5 `DevSeed`(commit `5497705`):退化为 grid 上的 WorldGen 预热,不再定义盒子(消除盒边与
  grid region 重叠 bug);footprint 跨 4 个 grid region,每 chunk 用其 region lease 写地形。
- D-2 接缝(commit `032fb52`):`cell_id.ex` 注明生产 region_id = RegionGrid 稠密格点 id(非 morton)。
- **keystone 评审 + 修复**(commit `24fa4b1`):13-agent 对抗式评审。采纳 F1(快路径补 logical_scene_id
  守卫,闭合跨 scene 路由分歧 + 回归测试)、F4(物化 lease TTL 6h→24h 缓解)。
- 测试:region_grid 9/0、map_ledger 23/0、dev_seed 5/0、world/voxel 全目录 153/0、ws_voxel 36/0、
  tcp+cross-region 31/0、mmo_contracts 47/0。

### 评审遗留(非阶段1回归,转入后续阶段 backlog)
- **F3**(critical-标注)`handle_call` persist 失败仍返成功:既有 wrapper 行为,且生产
  `MapLedger` 未配 `persist_fn`(nil)→ 当前 moot。**阶段2** durable 目录接持久化时须改 fail-fast
  并把"发布写令牌 + 落盘"纳入同一事务边界。
- **F5** 订阅/移动物化风暴(每首访 region 在 MapLedger GenServer 内同步 2 次 DB):有界(每 region
  一次),但单 World 进程串行化所有路由。**阶段5** 非阻塞流时改异步物化 / 预热 / 背压。
- **F6** 批量 ensuring 中途失败留下已物化 region:有效 grid region,重试即复用(自愈),非损坏;
  **阶段2** region GC 清理未用 region。
- **F7** DevSeed 部分地形写:与旧版同且幂等(`already_seeded?` 跳过,重跑补齐),非回归。
- **F8** `:stale_token`→`:rejected` 丢失可重试语义:单调 epoch 下物化路径不产生 `:stale_token`;
  若将来引入,**阶段5** 增 `result_code` 4=transient/retry。

---

## 8. 设计澄清与 scale-first 重定标(2026-06-25,用户拍板)

用户拍板两条贯穿全程的原则,载入决策,修订本稿后续所有阶段:

### 8.1 "服务端启动时间"与"客户端加载时间"是两条独立轴,分别度量、分别优化

二者**不同频率、不同主体、不同手段**,生产环境基本不同时发生,**严禁合并成"总加载时间"**:

| | 服务端启动时间(集群引导) | 客户端加载时间(每会话/每玩家) |
|---|---|---|
| 主体 | World/Scene 节点冷启动到可服务 | 玩家连接到看见周围世界 |
| 频率 | 运维事件(部署/重启),与玩家会话解耦 | 每次玩家进入,高频 |
| 现状 | ~20s(预热链:`SceneServer.Interface` 串行 `join_cluster` + `await world_server` 30s 轮询 + `DefaultRegionBootstrapper` 1s 重试 + DevSeed 铺地形) | 首次=订阅+物化;重复=磁盘缓存 + diff(已快,`persistence.rs`) |
| 优化手段 | 并行化预热、消除固定 sleep、懒初始化、就绪探针代替轮询 sleep | 差集订阅、priority band(先近后远)、非阻塞流、客户端缓存预测 |
| 指标 | node boot → first-serve | enter_scene → first_chunk_rendered;→ AOI_complete |
| 性质 | **运维体验** | **玩家体验** |

→ 服务端启动归入**阶段 7-bis(运维就绪)**单独立项;客户端加载归入**阶段 5(非阻塞流)**。各自有独立指标,不混算。

### 8.2 体素区域从设计之初即面向大规模——无"临时小区域",stopgap 在执行层且按 scale-first 归位

**澄清**:世界**不是**临时小区域。`RegionGrid` 从第一行起即**无界**(region=f(chunk),±数百万 chunk × 1670 万 logical scene)。DevSeed 的 5×5 只是**出生点地形预热区**,非世界边界。**分区层已是 scale-final,无早/晚路线分歧、无需重构。** 数据面(chunk truth)亦已经 Horde 分布于 Scene 节点。

剩余 stopgap 全在**执行层**,且**不再是"以后再说"的创可贴,而是从现在起按大规模设计**(避免前后期路线分歧 → 后期大重构):

1. **目录持久化(评审 F3)→ 阶段2**:region 目录 DB 落地,任意 World 节点可载;"发布写令牌 + 落盘"纳入同一事务边界(fail-fast)。**接口做成 resolver 形**(`region_id → owning ledger`),使将来按 logical_scene / region 段**分片**是部署配置而非重构。
2. **热路径(评审 F5)→ Gate 边缘 route 缓存(提前到阶段2-bis,不留到阶段5)**:region 所有权稳定,Gate 按 region 缓存 route/lease,只在**进入新 region** 时打控制面(MapLedger),而非每 chunk。控制面物化改**非阻塞 + 幂等**,不阻塞其他路由。控制面单进程因此不在每帧热路径上——这才是控制面该有的形态,也是单 World 进程能撑大规模的关键。
3. **lease 生命周期(评审 F4)→ 阶段2**:真正的续约 + region GC,替掉 24h TTL 创可贴。

**重定标后的阶段顺序**(阶段名以正文 `### 阶段 N` 标题为准;此处仅在原序列中插入 2-bis / 7-bis):
阶段2 durable 目录(事务边界 + lease 生命周期)→ **阶段2-bis Gate route 缓存 + 非阻塞物化** →
阶段3 运行时 WorldGen + chunk 生命周期 → 阶段4 AOI 增量 + 非阻塞 → 阶段5 编辑预测 + 反作弊 →
阶段6 按区一致性 + 增量复制 + 背压 → 阶段7 协议成熟 + 多世界 → **阶段7-bis 服务端启动优化**(seed
DB I/O + 预热链)→ 阶段8 控制面 HA。(注:服务端权威可达性校验在阶段5 step5.3;resolver 分片接缝
已在 region_id 编码 + fetch_world_node,无需独立模块。)

### ✅ 阶段 2(部分)— durable region 目录 + lease 生命周期(scale-first 执行层)
- step2.1/2.2(commit `38a8141`):`voxel_region_directory` **每 region 一行**表(主键 region_id,
  编码 logical_scene_id,logical_scene 建索引可分片)+ `RegionDirectoryStore`(纯 map API,
  `*_in_repo` 变体供同事务)。取代 MapLedgerStore 单行 blob(O(N))→ O(1) per change。
- step2.3/2.4(commit `93023c7`):`WorldServer.Voxel.RegionDirectory` 适配器(行↔结构);MapLedger
  物化/迁移把"写令牌 + 目录行"走**同一 Repo.transaction**(评审 F3,split-brain 窗口消除),
  boot 从目录重建 assignments/leases(**重启自愈**);world_sup 接 RegionDirectoryStore;
  WriteTokenStore 增 `upsert_token_in_repo`。
- step2.5(commit `ae9ddd9`):lease **生命周期**(评审 F4)——route 命中过期/将过期 lease 即
  **原地续约**(原子 re-issue,对编辑透明);后台 **region GC** 回收废弃(长期过期未续约)region,
  防目录无界增长。退掉 24h TTL 创可贴(默认 TTL 2h,全可注入)。
- **剩余**:step2.6 resolver 接口(并入阶段2-bis Gate 路由边界)、阶段2-bis Gate route 缓存 +
  非阻塞物化(评审 F5,把控制面单进程移出每帧热路径)。
- 测试:region_directory_store 7/0、world/voxel 全目录 160/0、write_token 11/0、state_class 11/0。

### 冷启动地形 seed 性能(诊断 + 部分修复,2026-06-25)
停服冷启实测拆解(两条时间轴分离后,这是**服务端启动**轴的"出生点内容就绪",一次性运维开销,暖启 `already_seeded?` 跳过):
- 进程/接口就绪(gate 接客户端):**~2.3-2.9s**(实测),app 监督树本身 ~0.3s,快;余下是预热门控
  (`join_cluster` 固定 1s sleep + 串行 await + bootstrapper 1s 轮询重试 2 次等 scene 注册)。
- 出生点地形 seed:旧 ~290s。**根因 = `Storage.put_solid_block/4` 的 O(N²)**(List.replace_at 4096
  headers + `++` O(n) 追加 + 每 cell 两次全量 `normalize!`)。**已修**(commit 822b074):批量
  `Storage.put_solid_blocks/2` O(macro_count+N);micro-bench 1280 cell **4.4ms vs 逐 cell 3291.9ms
  (750×)**,逐位相等。DevSeed 整块一次 apply(去每块 ~5× encode/persist 写放大)。
- **余下瓶颈 = DB I/O**(非场 provisioning——实测场 sweep 仅 ~14ms):每 chunk ~2.7s persist +
  ~4.8s 队列/重复加载(`already_seeded?` 读 + ChunkProcess 冷启再读同一 ~100KB 快照 + 连接池争用 +
  seed 期间 24 个 ChunkProcess 每 100ms tick)。属**阶段7-bis** 调优:批量/单次 persist、避免双读、
  池/并发整治、seed 期间暂停 tick。是一次性 ops 开销,不进每客户端加载。

### ✅ 阶段 2-bis(部分)— Gate 边缘 route 缓存(评审 F5)
- `GateServer.Voxel.RouteCache`(纯数据结构,commit aaef48d/8674676):chunk 落在已路由 region 且
  lease 新鲜 → 本地命中,只在进入新 region / lease 临近过期时打控制面 MapLedger;tcp + ws 两侧
  subscribe 接入;ChunkInvalidate 清缓存。把"每玩家逐 chunk 流量挤进单 GenServer"降为"每 region 一次"。
- **回归修复**:阶段2 lease 续约窗口 15min > gate 测试的 60s 租约 → 误续约 → ws_voxel 16 失败(漏跑
  ws 测发现)。续约窗口 15min→30s(短于现实租约,reactive on-expiry 兜底返回新鲜租约不丢编辑);
  Gate 缓存窗口对齐 30s。
- **2-bis 剩余(降级 backlog)**:非阻塞物化(MapLedger 内 2 次同步 DB)——route 缓存已把控制面负载从
  "每 chunk"降到"每 region 首访 + 续约",物化已罕见,非阻塞化收益变小,留作后续。resolver 分片接口
  ——region_id 已编码 logical_scene_id + 现有 fetch_world_node 即分片点,按 logical_scene 分片是改
  fetch_world_node 本体而非重构,接缝已在,无需独立模块。

### 本轮验证总览(2026-06-25)
world/voxel 160/0、data/voxel 90/0、gate codec 88/0、ws_voxel 36/0、route_cache 7/0、map_ledger 29/0、
cross-region 全绿、scene/voxel 1130/0(2 个 --no-start harness 失败为预存,baseline 同样失败,其一带 app
启动即过)、bevy lib 355/0。

### ✅ 阶段3 step3.1 + 阶段7-bis(2026-06-25)— 运行时 WorldGen + 冷启动 >150s→2.78s
**阶段3 step3.1 运行时 WorldGen**(视频法的服务端实现):
- `SceneServer.Voxel.WorldGen`:分形 value-noise 多 octave(4km 大陆→精细 5 层)+ 指数 shaper
  (≈2^noise)→ 草甸+尖峰山脉;确定性 (wx,wz,seed);cubic chunks 无高度上限;generate_chunk_storage
  按列高填 + 批量 put_solid_blocks 快填(全空/全实心快速)。~32×32km 展示尺度,噪声本身无限。
- ChunkProcess init:DB 无行的纯净 chunk → 确定性生成 version 0(**不持久化**,重生成逐位一致,
  与客户端缓存 version 0 一致不重传)——"传种子 + 只存改动"模型。默认禁用(单测得空 chunk),
  runtime config dev/prod opt-in。WorldGen 8/0 + 集成 3/0。
**阶段7-bis 服务端启动**(实测停服冷启):
- seed:bootstrapper seed_terrain?: false——不再 bulk-seed 地形(出生点由懒 WorldGen 供给),
  消灭一次性 seed DB I/O。terrain-seed events 0、region-materialized 3。**voxel-ready >150s→4.6s**。
- 预热链:BeaconServer join_cluster 固定 sleep(1000) → 轮询 peer(50ms)+ give-up 250ms(早返回)。
  **voxel-ready 4.6s→2.78s(≈gate-ready)**。
- **合计冷启动 voxel-ready:本会话初 >150s → ~2.78s(~54×)**;余 ~2.78s 主要是 mix/BEAM 启动开销。
- 这片 32km 地形地基让后续可见性(greedy meshing/LOD)、服务端分区流送、AOI 优化得以开展。

### ✅ 阶段3 step3.2/3.3 — chunk 生命周期(大世界内存有界)
- step3.2 idle 驱逐:ChunkProcess 无订阅者 + 无活跃 field region + 无 pending fence,连续 idle 达
  阈值即自停(:normal)。已编辑 chunk 编辑路径同步落库、纯净 chunk 由 WorldGen 重生成 → 停止无
  数据丢失;再访问由 ChunkDirectory alive? 检查重启。默认禁用(单测),dev/prod config opt-in
  (check 15s / evict 2min)。这与阶段2 region GC 互补:那个收 region 所有权,这个收 chunk 数据进程。
- step3.3 ChunkDirectory monitor:monitor 每个 chunk pid → DOWN 即时从 chunks 表清除(该表随驱逐
  有界),崩溃 emit voxel_chunk_process_down;竞态安全(仅当仍指向死 pid 才删)。**遗留**:崩溃时
  主动 ChunkInvalidate 广播给订阅者需 ChunkDirectory 侧订阅者表(当前靠移动 AOI 重订阅兜底),留作后续。
- **阶段3 完整落地**(WorldGen + chunk 生命周期);idle 驱逐 3/0、chunk_directory 11/0、
  scene/voxel --seed 0 稳定 1146/2(仅 2 预存 flaky)。

---

## 9. 阶段 4 设计 — AOI 增量 + 非阻塞(消灭实测 ~3.5s 编辑簇延迟,2026-06-25)

### 9.1 测绘确认的病灶

- **A2(直接病因)**:`subscribe_voxel_chunks` 在 connection 主 GenServer 内**同步逐 chunk** `safe_call`
  (各 15s 超时)。整框 radius=2 → 125 chunk 冷路由全程占 connection 进程,实测把后续
  `VoxelEditIntent`/movement 帧堵在 mailbox ~3.5s。
- **A1/A4**:gate `subscribe_voxel_chunks` **不做差集**——客户端每次跨 chunk 边界发整框
  `center+radius+known[全量]`(已验:bevy `subscribe_voxel_around` 无滞回/无预取,逐边界整框),
  gate 对框内**每个** chunk(含已订阅的)都重打 `ChunkDirectory.subscribe`,5× 必要工作量。
- **镜像**:tcp_connection 与 ws_connection 的体素订阅域(subscribe/unsubscribe/route/rebind/cleanup/
  scene_unsubscribe/fetch_world_node/fetch_scene_node_for_route)**逐字镜像**,漂移风险。

### 9.2 目标架构(三新模块,gate 内)

- **`GateServer.Voxel.Routing`(新,step4.1 去镜像)**:把 world/scene 路由 + scene subscribe/
  unsubscribe 的 I/O(`world_node`/`route_chunk`/`route_chunks`/`scene_node_for_route`/`subscribe`/
  `unsubscribe`/`safe_call`)抽成**唯一**实现,worker 与两侧 connection 的编辑/rebind 路径共用,杜绝镜像漂移。
- **`GateServer.Voxel.SubscriptionWorker`(新,step4.3 非阻塞核心)**:**per-connection GenServer**,
  与 connection 链接(随其退出)。connection 把订阅意图 `cast` 给它**立即返回**,route+subscribe
  这段慢 I/O 在 worker 进程跑——**connection 主进程永不被订阅风暴阻塞,编辑/移动帧始终低延迟**。
  worker 用 `subscriber: connection_pid` 订阅,故快照/delta 仍**直达 connection→socket**(fan-out
  热路径零改动);订阅结果 `cast` 回 connection 落 `voxel_subscriptions`,路由失败 `cast` 回让
  connection 编 `0x68` error 帧(`reason: inspect(reason)`,保留失败测试字节)。worker 持
  `RouteCache`(region 级缓存即 step4.4 批路由收益:一个 slab 命中同 region 只打一次控制面)。
- **差集(step4.2)**:connection 持 `voxel_subscriptions`(权威 + introspection 不破)+ 新增
  `voxel_pending`(在途键集)。订阅时 `diff = 框 ∖ (已订阅 ∪ 在途)`,只把**新键**投给 worker;
  已订阅/在途 chunk 不再重打 ChunkDirectory。移动一格成本 O(radius³)=125 → O(radius²)≈25(尾框
  由客户端既有 `chunks_falling_out` 显式 unsubscribe 兜掉)。

### 9.3 关键取舍与契约保全

- **快照即 ACK**:订阅成功路径**不发**结果帧(现状同),快照由 worker 订阅触发经 fan-out 异步到达;
  失败走 worker→connection 的 `0x68`。`assert_receive` 对异步到达天然容忍。
- **introspection 不破**:`voxel_subscriptions` 仍在 connection state(由 worker 回 cast 维护),
  `:sys.get_state(conn).voxel_subscriptions` 测试零改动。**消息序保证**:ChunkProcess 在
  `subscribe` 调用内先 `send` 快照给 connection,worker 收到 reply 后才 cast 回订阅——故
  connection mailbox 序 [快照, 订阅 cast],测试「收到 0x62 后再 `:sys.get_state`」必见已落库的订阅。
- **rebind 保持同步**(迁移罕见、非编辑热路径):留在 connection 但改走 `Routing` 去镜像;rebind 后
  `cast` worker 清 route_cache,避免迁移后用陈旧缓存路由。**已知小竞态**:迁移恰逢某 chunk 在途订阅
  → 该 chunk 可能漏过本次 rebind,由 AOI 重订阅/lease 过期自愈(罕见,记入 backlog)。
- **失败语义**:async streaming——首个路由/订阅失败 `cast` 一帧 error 即止(不回滚已订阅,异步回滚会
  闪掉客户端已见 chunk);radius=0 的全部失败测试逐位不变。
- **step4.5(客户端滞回/预取/合帧)**:bevy 侧独立 commit。

### ✅ 阶段 4 服务端落地(step4.1-4.4,2026-06-25)
- **step4.1 去镜像**:`GateServer.Voxel.Routing`(新)——world/scene 路由 + scene subscribe/unsubscribe
  的唯一实现,worker 与两侧 connection 的编辑/rebind 路径共用;tcp/ws 的 route_voxel_chunk(s)/
  fetch_scene_node_for_route/scene_unsubscribe 全部委派,删掉镜像实现。
- **step4.3 非阻塞核心**:`GateServer.Voxel.SubscriptionWorker`(新,per-connection GenServer,与
  连接链接)。connection 订阅时只 `cast` 意图后立即返回,route+subscribe 慢 I/O 在 worker 进程跑
  → **连接主进程永不被订阅风暴阻塞,编辑/移动帧低延迟**。worker 用 `subscriber: connection_pid`
  订阅,快照/delta 仍直达连接→socket(fan-out 热路径零改动);结果经 `{:voxel_subscribed,...}` /
  `{:voxel_subscribe_failed,...}` / `{:voxel_reconcile_settled,...}` 回连接落 state。阶段2-bis 的
  per-region route 缓存随之移入 worker。
- **step4.2 差集**:connection 持 `voxel_subscriptions`(权威,introspection 不破)+ 新增
  `voxel_pending`(在途键集)。订阅框 `diff = 框 ∖ (已订阅 ∪ 在途)`,只把新 chunk 投 worker;
  已订阅/在途 chunk 不再打 ChunkDirectory。
- **step4.4 批路由**:worker 持 RouteCache → 一个 slab 命中同 region 只打一次控制面(region 级批
  路由收益已得)。`ChunkDirectory.subscribe_many`(批本地订阅)判为收益小(非阻塞已消除阻塞)降 backlog。
- **修复 subscribe/unsubscribe 乱序竞态**(异步必然引入):订阅在途时退订 → 撤 `voxel_pending`「想要」
  标记;worker 回报 `:voxel_subscribed` 时自检不在 pending → 撤销 scene 侧订阅、不加入,杜绝退订后
  被重新加回。两侧 connection 同修。
- 测试:gate_server 全套 **228→229/0**(新增 ws「差集 no-op」测试,ws_voxel 37/0、tcp+cross-region
  31/0)。**注**:`ws_connection_voxel_test` 的 rebind 用例在 `--seed 0` 下有**既有**(baseline 同样
  失败)顺序相关 flaky(epoch store (779,5) 跨序累积致 owner_epoch 2),与本改动无关,随机 seed 全绿。
