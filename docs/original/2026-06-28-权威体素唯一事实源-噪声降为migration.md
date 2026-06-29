# 权威体素 = 唯一事实源；WorldGen 噪声降为一次性 migration（2026-06-28）

> 性质：**地基级架构决策稿**。仅决策，未动代码。
> 适用：scene_server 世界生成/存储/LOD 派生，及所有客户端（Voxia 主线 / bevy / web）的远景渲染取数口径。
> 纪律：先读 [`docs/2026-06-27-架构设计指导思想-系统正交.md`](2026-06-27-架构设计指导思想-系统正交.md) 并过其「开工前自查清单」。
> 当前整合状态见：[`docs/2026-06-28-体素世界与远景渲染-当前真相(整合).md`](2026-06-28-体素世界与远景渲染-当前真相(整合).md)。

---

## 0. 一句话

**权威体素数据是服务器整个生命周期里唯一的事实源；WorldGen 噪声只是一次性的 world-seed migration（开发期占位，与未来"真实地图导入"互换），跑完即弃、不进运行时、不进正式发布；chunk 服务、远景 LOD、raycast 等一切只读 / 派生自权威体素，且每个派生物显式维护它与体素的一致性。**

---

## 1. 背景与动机

### 1.1 触发问题

复盘远景 LOD（heightmap，`0x6A/0x6B`）时发现：`heightmap_region`（`apps/scene_server/lib/scene_server/voxel/world_gen.ex:95` → Rust `world_gen_noise`）是**在运行时重新跑噪声函数** `column_height_impl(x,z,seed)` 算出来的，**完全不读权威体素存储**。

后果：

- 权威 chunk = **噪声基底 ⊕ 持久化编辑**；近场流式发的是这个（含编辑）。
- 远景 heightmap = **只有噪声基底**（不含编辑）。
- 同一块地形，走近是坑、退远变回原始山包——near 反映编辑、far 不反映。

### 1.2 真正的根因（不是"远景看不到编辑"这个现象）

远景 LOD 用了**一套与权威体素并行的、第二份"地形是什么"的真值**（噪声函数）。这条真值**没人维护**：生成时刻 near/far 同源（都用 `column_height`），但一旦编辑发生，权威体素前进、噪声原地不动，二者**静默分叉**。

这正撞在本仓核心红线（系统正交文档）：

> "绝不让别的系统的正确性悄悄依赖一个**没人维护**的假设" / "显式契约 > 隐式假设"。

### 1.3 为什么必须现在定调（面向真实地图）

未来世界要从**真实世界地图导入**替换噪声。**真实地图没有生成函数**——它是固定数据集。任何"把生成函数当运行时真值"的架构都无法接纳真实地图。把噪声降格成 migration，它就和"真实地图导入"成为**可互换的兄弟 migration**，都往同一个权威 store 灌数据，**运行时对世界来源完全无感**——这是能"无痛换地图"的唯一结构。

> 备注：先前一版设想"噪声作为运行时 fallback（未材化列用噪声）"**已废弃**——它仍把噪声留成活真值源，与本决策互斥。本决策下**不存在"未材化的列"**：首次初始化后 store 完整，无 fallback 概念。

---

## 2. 核心原则与不变量

- **I-1 单一事实源**：服务器全生命周期内，"世界是什么"只有一个答案——权威体素 store。
- **I-2 噪声=migration**：WorldGen 噪声只在 world-seed migration 内执行一次，输出落进权威 store；此后运行时任何路径**不得**调用噪声。dev-only，不进生产。
- **I-3 世界来源可插拔**：噪声 seed 与真实地图导入是同层的兄弟 migration，灌同一个 store；runtime 不感知来源。
- **I-4 一切派生自体素**：chunk 服务、LOD、raycast、碰撞、可见性等均只读/派生自 store。
- **I-5 派生物自维护一致性**：每个派生缓存（尤其 LOD mip）必须显式维护它对 store 的一致性（编辑 → dirty → 重建），不得隐式假设"源没变"。

---

## 3. 决策

- **D-1**：`heightmap_region` 改为**从权威体素派生**（每列求最高实心 + 顶面材质），永不调用噪声。
- **D-2**：远景 LOD 形态改为**持久化的"派生 mip 金字塔"**（逐 stride 预算的列顶/材质缓存），请求时从缓存读；体素编辑时把受影响 LOD cell 标脏、惰性/即时重建（满足 I-5）。mip 各层天然就是多 tier 级联（见整合文档"LOD 级联"）。
- **D-3**：chunk 服务路径改**只读权威 store**；正式运行时**缺块=错误/未材化告警**，不得静默跑噪声现生成（`generate_chunk_storage` 的运行时调用点移除）。
- **D-4**：WorldGen 噪声搬入 **world-seed migration**（与 `apps/world_server/lib/world_server/voxel/dev_seed.ex`、`migration_plan.ex`、`mix migrate_*` 同列），dev-only；新增**真实地图导入 migration** 作为生产世界来源（灌同一 store）。
- **D-5**：世界材化策略默认 **eager 全量首次初始化**（对真实地图导入最自然）；允许 dev 期 **lazy-but-permanent** 作为启动优化（首访材化+持久化，噪声对每区域至多一次，之后只读 store）——两者都满足 I-1/I-2。
- **D-6**：放弃"只发种子、客户端自生成底图"的带宽技巧（与"世界是数据"互斥且真实地图无 seed）；客户端一律流权威数据（near chunk + far LOD mip）。

---

## 4. 现状 → 目标（具体改动点）

| 路径 | 现状（运行时跑噪声/平行真值） | 目标（派生自权威体素） |
|------|------|------|
| chunk 服务 | 缺块按 `column_height` 现生成 | 只读 store；缺块即错误（D-3） |
| 远景 LOD | `heightmap_region` 重跑噪声、不含编辑 | 从 store 派生列顶 mip、含编辑、持久化+dirty 维护（D-1/D-2） |
| 世界来源 | 噪声在运行时是真值 | 噪声=一次性 dev migration；真实地图=生产 migration（D-4） |
| 远程瞄准/交互 | （未实现） | 服务端对 store 求交/模拟（派生自体素，见整合文档"远程交互"） |

受影响文件（起点，非穷举）：

- `apps/scene_server/lib/scene_server/voxel/world_gen.ex` — `heightmap_region/6`、`generate_chunk_storage/3`、`column_height/3` 的角色重定义
- `apps/scene_server/native/world_gen_noise/src/lib.rs` — 噪声实现移出运行时热路径，仅供 migration
- `apps/scene_server/lib/scene_server/voxel/storage.ex` + ChunkDirectory/ledger — 成为唯一读源；新增"列顶/LOD mip"派生与索引
- `apps/gate_server/lib/gate_server/worker/tcp_connection.ex` — `0x6A` 处理改读派生 mip（协议不变）
- `apps/world_server/lib/world_server/voxel/{dev_seed,migration_plan}.ex` — 收纳噪声 world-seed；新增真实地图导入 migration
- 客户端（Voxia `VoxiaHeightmapMesher`/`VoxiaWorldActor` 等）：取数口径不变（仍是 `0x6B`），但内容从此含编辑、可多 tier

---

## 5. 取舍（诚实）

1. **全量世界存储 / 更新数据量**：这是后续容量、分发和流送工程风险，不作为当前“可操作区域不刷新 / 编辑无效”的主因，也不作为否决单一事实源的前置理由。大体素包、世界基线和大范围重写应放在启动器 / 更新阶段或入场前校验阶段；场景运行时只流已验证基线之上的 diff。真正碰到吞吐瓶颈时，先用 observe / CLI 统计 `tiles_changed`、`chunks_changed`、`ops`、`bytes`、`encode_ms`、`send_queue_bytes`，再设计压缩、分片、channel 或预算策略。
2. **首次初始化/导入成本**：一次性材化重。eager 全量（生产/真实地图最自然）vs lazy-but-permanent（dev 启动更轻，噪声每区域至多一次）。无论哪种，LOD 都派生自 store。
3. **失去 seed 带宽技巧**：客户端无法用 seed 重建底图，必须流权威数据；LOD mip 流式是带宽答案（与瘦客户端一致）。
4. **LOD 缓存维护成本**：编辑要 dirty 派生 mip——这是**正确的耦合**（显式派生+维护），取代当前**错误的隐式耦合**（假设噪声==真值）。

---

## 6. 开工前自查（系统正交清单要点）

- 本改动让"世界真值"从两份（体素 + 噪声）收敛为一份（体素）——**减少**隐藏耦合，方向正确。
- 新引入依赖：LOD 派生 → 权威 store。这是**应有**依赖（远景本就该依赖权威），且以"编辑 dirty mip"显式维护，不留没人管的不变量。
- 协议（`0x6A/0x6B`、`ChunkSnapshot/Delta`）布局不变，只改服务端取数源——客户端不破坏。
- 缺块语义从"静默兜底"改为"显式错误"——把一个隐式假设升级为显式契约。

---

## 7. 与其他文档关系

- 整合当前状态（入口）：[`docs/2026-06-28-体素世界与远景渲染-当前真相(整合).md`](2026-06-28-体素世界与远景渲染-当前真相(整合).md)
- 远景 LOD + 缝隙根因（原始）：[`clients/Voxia/docs/2026-06-28-远景LOD-heightmap-设计与拼接缝隙根因.md`](../clients/Voxia/docs/2026-06-28-远景LOD-heightmap-设计与拼接缝隙根因.md)
- 流式窗口跟随（原始）：[`clients/Voxia/docs/2026-06-28-streaming-window-follow-fix.md`](../clients/Voxia/docs/2026-06-28-streaming-window-follow-fix.md)
- 体素生产架构（原始）：[`docs/2026-06-25-voxel-world-production-architecture.md`](2026-06-25-voxel-world-production-architecture.md)
- 指导思想：[`docs/2026-06-27-架构设计指导思想-系统正交.md`](2026-06-27-架构设计指导思想-系统正交.md)

## 8. 状态

**决策稿，未拍板动手。** 建议落地顺序见整合文档"路线"。
