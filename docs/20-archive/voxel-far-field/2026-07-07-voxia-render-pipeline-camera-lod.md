# Voxia 客户端 voxel 渲染管线：相机 · 焦点 · LOD 切换（研究笔记）

> 2026-07-07。为 VLOD-A3b Step 6 真实 RHI A/B 的机位设计而做的管线研究。方法：6 路子代理并行深挖 + 综合交叉核验，全程 `文件:行号` 实证。
> **覆盖范围局限**：端到端链路主要覆盖 `-VoxiaWorldGenPreview` **本地预览路径**；真实服务器 InScene 路径（`NearWindow.CenterTile` 是否服务器 AOI 下发）未证实——见 §6 开放问题。
> 行号锚基于 `clients/Voxia`（子仓，含 `1fc93d2` raymarch 默认关）。

## 0. 头号结论：相机**不驱动**稳态 LOD 切换

客户端里**没有任何 camera-frustum / screen-space-error 的 LOD 逻辑**。某 tile 被赋予哪个 LOD depth，是**玩家角色体位置**（`GetActorLocation()`）的纯函数，**与相机朝向/FOV/位置无关**。

- 稳态 LOD/流送中心 = `GetStreamingWorldPosition() = GetActorLocation()`（`Gameplay/VoxiaPawn.cpp:620`，注释 "centre on the LOCAL character"），**不是相机**。
- 相机位姿（`GetCrosshairRay`，`Gameplay/VoxiaPawn.cpp:1622`）只喂 3 个用途，**无一赋 per-tile depth**：① crosshair 挖放；② 按 `T` 键望远镜 Focus（一次性远景 AOI region，`Gameplay/VoxiaFocusTarget.cpp:99`）；③ 渲染侧朝向（VHI 排序 `:542` / far 组件视锥剔除**仅遥测** `:1155` / raymarch probe 原点，默认关）。
- 结论：原地转相机不改任何 tile 的 depth / 覆盖 / tile 集。相机唯一影响"渲染了什么"的是 UE 引擎对每个 far 分组件的相机相对视锥剔除——是**可见性剔除**，非 LOD 选择。

## 1. 端到端管线（相机 / 体位置 双源）

```mermaid
flowchart TD
    Tick["AVoxiaPawn::Tick 每帧主驱动<br/>VoxiaPawn.cpp:389"]

    subgraph BODY["稳态 LOD 中心 = 角色体位置(非相机)"]
        Body["GetStreamingWorldPosition = GetActorLocation()<br/>VoxiaPawn.cpp:620"]
        TileF["TileForSim: ChunkForSim=floor(sim/1600) 再 FloorDiv(,7)<br/>VoxiaTileWindow.cpp:17"]
        Center["CenterTile"]
        Body --> TileF --> Center
    end

    subgraph CAM["相机射线 = 仅 3 用途(不驱动稳态 LOD)"]
        Ray["GetCrosshairRay: PlayerCameraManager 位姿<br/>VoxiaPawn.cpp:1622"]
        U1["① crosshair 挖放选择"]
        U2["② T键望远镜Focus→外推8km→远景AOI<br/>VoxiaFocusTarget.cpp:99"]
        U3["③ 渲染朝向: VHI排序542 / far视锥剔除(仅遥测)1155 / raymarch原点(默认关)"]
        Ray --> U1 & U2 & U3
    end

    Tick --> Body
    Tick --> Ray

    subgraph FAR["远景 SVO 构建 (CenterTile 驱动)"]
        Cfg["RequestSvoAround 装配 FVoxiaSvoBuildConfig<br/>CenterTile=2484 · Radius=72 · NearSkip · bFarMergeEnabled=!NoMerge(2492)"]
        Ring["RingIndexForTile: XZ Chebyshev=max(|dX|,|dZ|)<br/>VoxiaSvoPreview.cpp:2780"]
        Depth["CellDepthForRings → 八叉树 MaxDepth<br/>默认 8→d4 · 24→d3 · 40→d2 · 72→d1 (2794)"]
        Cover["CoveragePlanner.ShouldCover: 超半径+near-skip整tile剔除<br/>VoxiaFarFieldCoveragePlanner.cpp:18"]
        Build["BuildMacroCellUpdate: signature+depth双校验→复用/重建<br/>VoxiaSvoPreview.cpp:1834"]
        Cfg --> Ring --> Depth --> Cover --> Build
    end
    Center --> Cfg

    subgraph NEAR["近景构建 (WorldActor, revision-gated)"]
        NB["StartNearMeshBuild<br/>VoxiaWorldActor.cpp:1310"]
        NM["GreedyMesher::BuildByMaterial 均匀1m网格<br/>→ 单root ProcMesh 的 sections (2775)"]
        NB --> NM
    end

    subgraph RENDER["远景上传 + 渲染"]
        Q["QueueSvoMeshUpdate: ResolveSvoRenderBackend=PartitionedDynamicMesh<br/>VoxiaWorldActor.cpp:1371"]
        Up["ContinueSvoUpload: 一patch一UDynamicMeshComponent<br/>Movable+Unlit+StaticDraw · 3ms/8patch (2369)"]
        Rev["upload完成→SetVisibility(true)一次性reveal<br/>bulk-hide阈值64 (2448)"]
        Cull["UE引擎 per-component 视锥/遮挡剔除 [推断]<br/>每patch独立bounds"]
        Q --> Up --> Rev --> Cull
    end
    Build --> Q
    Center --> NB
```

## 2. LOD depth 因果链（"相机→LOD"的精确回答）

```mermaid
flowchart LR
    A["角色体位置<br/>GetActorLocation :620"] --> B["CenterSim<br/>WorldToSim"]
    B --> C["CenterTile<br/>TileForSim :17"]
    C --> D["Config.CenterTile<br/>:2484"]
    D --> E["每 tile: Chebyshev=max(|dX|,|dZ|)<br/>RingIndexForTile :2780"]
    E --> F["环索引 → Depth<br/>CellDepthForRings :2794"]
    F --> G["八叉树 MaxDepth<br/>leaf 尺寸 = 112m / 2^depth"]
    CAM["相机 朝向/FOV/位置"] -. "代码里无任何连线(不存在此逻辑)" .-> E
```

- 四环 tier 契约默认 `{8→d4, 24→d3, 40→d2, 72→d1}`（`CellDepthForRings`，`VoxiaSvoPreview.cpp:2794`）。
- 环距用 **XZ 平面 Chebyshev 距离** `max(|dX|,|dZ|)`（`RingIndexForTile:2780`），线性扫环取首个 `Chebyshev ≤ OuterRadiusTiles`。
- leaf 尺寸 = `112m / 2^depth`（tile 足迹 112m，depth 决定八叉树细分）。

## 3. 中心移动时的 LOD 切换（增量复用）

```mermaid
flowchart TD
    Move["玩家跨 tile: TileForSim ≠ LastTile<br/>VoxiaPawn.cpp:1496"] --> Reuse["SameReusableSvoConfig 刻意不比 CenterTile<br/>→ bCanReuse=true (1520)"]
    Reuse --> Check{"per-tile 双校验<br/>VoxiaSvoPreview.cpp:2098"}
    Check -->|"signature(new)==signature(old)<br/>且 depth==depth(old)"| Keep["复用旧 artifact<br/>AppendMacroCellArtifact"]
    Check -->|"跨环(depth变)<br/>或 near-skip邻接变(signature变)"| Rebuild["重建 MakeMacroCellArtifact<br/>:2146 + DirtyMacroCells"]
    Move --> Out["移出窗口 tile → RemovedMacroCells :2177<br/>分组件按 Section 增量销毁(无 O(N²))"]
```

- `SvoTileSignature`（`:1644`）对 ±X/±Z 四邻的 near-skip 抑制状态编码：**远离近场环的 tile 签名恒=1、depth 不变 → 直接复用**；中心移动只重建"薄薄一圈"边界 tile。
- 双校验保证"增量结果 == 全量结果"：几何是"源+tile+深度"纯函数，但边界统计/skirt 依赖近场邻接、depth 依赖距离环，中心移动同改两者，故受影响 tile 必须重建。

## 4. 近景 vs 远景 渲染分工

| 维度 | 近景 | 远景 SVO |
| --- | --- | --- |
| 中心 | 角色体位置 chunk（`ResolveNearMeshPriorityCenterChunk:418`） | CenterTile（角色体 tile） |
| 触发 | revision-gated（Voxel/Field revision 变）+ 4ms/512chunk 预算续帧（`:2902`） | SvoRevision 变 + 0.25s poll + 3ms/8patch（`:2369`） |
| mesh | `GreedyMesher::BuildByMaterial` 均匀 1m 网格（16³, 100cm）+ 12.5cm 精修（`:609`） | per-cell 变深度 leaf + **A3b greedy merge** |
| 组件 | 合批进**单个 root ProcMesh**，按 render bucket（matte/translucent/emissive）每 chunk 1-3 section，池化复用（`:2775`） | **一 patch 一 `UDynamicMeshComponent`**（Movable+Unlit+StaticDraw，`:2369`） |
| 剔除 | 近景 root 始终可见；空 chunk / 六邻全实心遮挡 chunk 直接跳过（`IsFullyOccludedUniformChunk:505`） | UE 引擎 per-component 视锥/遮挡剔除 **[推断]**；游戏侧只做 bulk on/off（`:1368`） |
| 材质/光照 | `MaterialForId` 路由 Voxel/Translucent/Emissive 材质，读 FieldStore 温度/光照做 emergence shading（`SolidAtWorld:558`）→ **进 Lumen** | `ResolveSvoPartitionedMaterial` **Unlit**，`FarVisual.ApplyTo` 关 DistanceField/RT/Shadow（`:1239` / `MeshComponentDesc.cpp:47`）→ **不进 Lumen GI** |
| 边界 | — | near-skip 整 tile 剔除让远景避开近景区；交界竖面 **24m skirt**（`GVoxiaSvoBoundarySkirtMacros`，`:19`） |

## 5. 后端与 raymarch

- **默认后端 = `PartitionedDynamicMesh`**（`ResolveSvoRenderBackend:891`，无 override 时 `:906` 返回它）。ProcMesh/HISM/RuntimeMesh/Partitioned 均可经 `-VoxiaSvoRenderBackend=` 覆盖；第 5 枚举 `NaniteStaticMeshBake` 保留未用。
- **StaticDraw 无条件应用**（`:2387`），仅 `-VoxiaSvoFarDynamicDraw` 能覆盖。`bStaticBakeReady`（`RenderArtifact.cpp:60`）**运行期不 gate**，只被 automation 断言——与任务原描述"准入门"不符（见 §6）。
- **raymarch 默认关**：`ShouldEnableSvoRaymarch`（`VoxiaWorldActor.cpp:490`）+ gate（`:1969`）+ `bSvoRuntimeGpuBuffersReady`（`:1984`）默认 false → go-live 不建 runtime buffer、不跑 compute，只走三角形 proxy mesh。开启时才用 world-space camera ray（`RaymarchComposite.cpp:292`）。

## 6. 诚实边界（推断 / 未证 / 已纠正）

1. **[推断]** "UE 引擎真的对每个 far 组件执行视锥/遮挡剔除"——只证到前置条件（每 patch 是独立组件带自身 bounds，`:2455`/`:1208`），未追引擎渲染器代码证明剔除真触发。远景"相机↔渲染"耦合的关键推断点。
2. **[未证 · Step 6 重点看]** 跨 depth 环界（depth4↔depth3）是否产生可见裂缝/T-junction——只有 near-skip 24m skirt，**无跨环 stitch 代码**，判据里也无"外邻 tile 深度不同"一项。
3. **[未证]** 真实服务器 InScene 下 `NearWindow.CenterTile` 是否服务器 AOI 下发（而非本地角色位置）。
4. **[已纠正的假警报]** 子代理称 `1fc93d2`（raymarch 默认关）不存在——**错误**：它确在 `clients/Voxia` 子仓；子代理在 `ex_mmo_cluster` 仓跑 git 才失败。raymarch 默认关成立（代码 gate + `1fc93d2` 双证）。
5. **[头注释过时]** `MeshComponentDesc.h:27` 注释称需 Static mobility，但 `.cpp:47` 强制 Movable（执行真相）。
6. **[未证]** 帧内 `Pawn::Tick` vs `WorldActor::Tick` 调度顺序；持久 artifact cache 命中与增量双校验两条"复用"来源的等价性；近景 greedy mesher 竖直轴落 grid 轴 1 还是 2（三处口径自洽但未逐面验）。

## 7. 对 Step 6 真实 RHI A/B 的启示

1. **"同机位" = 同一 pawn actor 位置（同 CenterTile）**，不是仅同相机朝向。tile 集/每 tile depth/覆盖全由体位置决定。采样前先核对两次 tile 集与组件数一致，才能把 RHI delta 干净归因给 merge。
2. **A/B 开关 = `-VoxiaSvoFarNoMerge`**（`:2492`，`bFarMergeEnabled=!Param`，默认 ON）。除该 flag 外命令行必须完全一致——**绝不带 `-VoxiaSvoRaymarch*`**（会转真走 GPU compute、彻底改 RHI 画像）、不带 `-VoxiaSvoRenderBackend=`、不带 `-VoxiaSvoFarDynamicDraw`。
3. **机位朝外眺望穿过多环**，让远景 shell 落入视锥——否则相机朝地/朝近会被引擎剔掉大部分 far 组件，merge 的 overdraw 收益被掩盖。用 `far_visible` 遥测（`CountVisibleSvoPartitionedComponents:1155`）确认视锥内 far 组件数，作 A/B 可比性前置门槛。
4. **先等 LOD 收敛再采样**：far 异步构建 + 0.25s poll + **bulk-hide（阈值 64）藏整池直到 upload_complete 才一次性 reveal**（`:2448`）——必须 reveal 后稳态截取。
5. **Lumen 归因**：远景 SVO 是 Unlit、不进 Lumen GI；merge on/off 的 RHI 差异主要落在**光栅/overdraw 与 draw-call 数**，而非 Lumen 光照。别把 Lumen 侧波动算到 merge 头上。

## 8. 后续行动计划（开放议题登记 —— 勿讨论完即弃）

> 这些议题在 2026-07-07 相机/LOD 研究 + 近/远材质讨论中浮现，登记为**待办**，不随讨论消散。Step 6 先跑**纯 merge A/B**（用户拍板），下列议题按优先级/时机排在其后或并入 Step 6 的可见 RHI 巡航。

| # | 开放议题 | 优先级 | 时机/依赖 |
| --- | --- | --- | --- |
| F1 | 近 Lit / 远 Unlit **光照色差** | ✅ 已实施 | Lit 转默认、Unlit 降 alt（`-VoxiaSvoFarUnlitMaterial`）；视觉质量待肉眼确认；见下详情 |
| F2 | 近/远 **emergence 缝**（远景无发光/温度） | 中-低 | 取决于 emergence gameplay 权重；F1 之后 |
| F3 | **跨 depth 环界（d4↔d3）裂缝/T-junction** | 中-高（几何正确性） | Step 6 可见 RHI 巡航**顺带肉眼看**（不加 A/B 维度） |
| F4 | 引擎 per-component **剔除是否真触发** | ✅ 已证 | 可见 RHI 实测 361→101 可见(28%)=剔除真生效；`far_visible` offscreen 卡死=1 是 offscreen 专有 bug |
| F8 | 远景 voxel **高频边缘白斑伪影**（疑 TSR 上采样 shimmer） | 低-中 | Lit/Unlit 两图都有=材质无关、预存；查 TSR/边缘或降屏幕百分比影响 |
| F5 | 真实服务器 InScene 下 **CenterTile 来源**未证 | 中 | 独立调查（不阻塞 Step 6 本地预览路径） |
| F6 | `bStaticBakeReady` 运行期不 gate（设计债） | 低 | 确认设计意图后决定补接线或删字段 |
| F7 | `MeshComponentDesc.h:27` 头注释过时（Static vs Movable） | 低 | 顺手清理 |

**F1 近 Lit / 远 Unlit 光照色差（最主要议题）**
- 证据：近 `M_VoxelVertexColor`(MSM_DefaultLit，顶点色受光，`VoxiaWorldActor.cpp:721`) vs 远 `M_VoxelFarUnlit`(MSM_UNLIT，顶点色直出 Emissive 不受光，`:752`)；解析 `ResolveSvoPartitionedMaterial:1239`。
- 为何重要：强方向光/阴影/昼夜下，近景边缘（≈112m）会出现 lit/unlit 亮度断层。**可见程度未经真实 RHI 视觉验证**（不臆断）。
- 关键背景：Unlit 的**崩溃规避理由已失效**——A2.0 曾把崩溃归为 overdraw 而引入 D6 Unlit，A3.0 反转证明崩溃真凶是 **raymarch**（已由 raymarch-off 修复、与 overdraw 正交）。Unlit 现仅剩 perf/overdraw 理由，且 **A3b merge −52% quad → overdraw 减半**已进一步削弱其必要性。
- 拟定动作：Step 6 纯 merge 跑完后，独立跑一档 **`-VoxiaSvoFarLitMaterial`**（远景改用与近景同一 Lit 材质），量 Lit-far 的 FPS/VRAM 代价；若可接受则评估默认改 Lit 消色差。**FPS delta 必须与 merge 收益单独隔离归因**，不混入纯 merge 对照。
- **实测 + 决议（2026-07-07 F1，已实施）**：
  - **DRS 误判纠正**：Step 6 把 `screen_percentage=77` 当动态 DRS，实为**静态 TSR 屏幕百分比**（所有样本恒定 77.00、FPS 却剧烈变——若是 DRS 会反过来靠调分辨率稳住 FPS）。故 Step 6 的 FPS 对比**本就有效、无 DRS 混淆**，merge FPS 中性是真结论（Lumen-bound）。
  - **Lit-far 代价实测**（merge-ON，`-VoxiaSvoFarLitMaterial`，77% 静态，offscreen）：@-20 Unlit 126.6 vs Lit 120.4（−5%）、@-30 126.7 vs 128.1（噪声内 ≈0）、@-40 Lit 80.3。→ **消色差 FPS 代价基本在噪声内（0~5%）**（Lumen 主导、远景仅占屏一小片）。材质干净生效（无 "material not compiled" 告警）、存活。
  - **决议（用户拍板）**：**远景默认改 Lit**（`VoxelMaterial`，与近景同材质消色差）；**Unlit 降为 alt**，`-VoxiaSvoFarUnlitMaterial` 逃生门切回 A2-D6 便宜材质。实施：`ResolveSvoPartitionedMaterial` 翻默认（`VoxiaWorldActor.cpp:1239`）+ `.h`/注释同步。验证：编译绿 + `Voxia` 全 **36 测 `Result={Success}` 0 Fail**（零回归）；Lit 路径行为已由 `-VoxiaSvoFarLitMaterial` 真实 RHI run 验证（同 `return VoxelMaterial` 路径）。
  - **视觉确认（2026-07-07，已做）**：Lit-vs-Unlit 同机位可见 RHI 对比（`Saved/far_lit_shell.png` / `far_unlit_shell.png`，远景 shell 俯视）——**Lit 受光偏暗蓝、与近景光照一致（消色差达标）；Unlit 平铺偏亮灰橙、不匹配近景 → Lit-default 正确**。**白斑伪影两图都有 → 非 Lit specular（早期猜测证伪），是预存高频 voxel 边缘伪影（疑 TSR 上采样），登记 F8。Lit-default 未引入新伪影，视觉通过。** 近/远交界的直接色差对比（需近景窗口）暂缺——near 流式 61425 chunk 超时，留后续用更轻近景配置补。

**F2 emergence 缝**：近景烘焙 emergence（热单元 emissive glow / 温度光照，`SolidAtWorld:558`），远景 `MaterialForBounds` 每 leaf 单材质**无 emergence**（A3b 稿 §9.1）。即便 F1 让远景 Lit，发光/温度差异仍在。动作：评估远景是否需烘焙简化 emissive，或接受远景无发光。

**F3 跨环界裂缝**：判据里**无"外邻 tile 深度不同"项**（`IsNearSkipBoundaryFace:589` 只判 near-skip 邻接），无跨环 stitch/skirt 代码；唯一遮缝是 near-skip 24m skirt。d4↔d3 等相邻不同深度环之间是否产生可见裂缝/T-junction 无实证。动作：Step 6 可见 RHI 巡航**重点看环界**；若有缝，设计跨环 stitch 或 skirt（新工作项）。

**F5 服务器路径**：本次端到端只覆盖 `-VoxiaWorldGenPreview` 本地路径；真实服务器下 `NearWindow.CenterTile` 是否服务器 AOI 下发未证。动作：读 `Net/VoxiaTransportSubsystem` 网络分支 + `Interest/VoxiaClientInterestSubsystem` 定论——决定 Step 6 之外的联网 A/B 是否需固定 pawn 位以避免 AOI 抖动引入非 merge 的 tile 集差异。

## 9. 远景优化路线候选（roadmap，2026-07-07 沉淀）

> **Step 6 + A/B/C 实测认识（2026-07-07）**：远景 **FPS 是像素-bound，不是三角形-bound**。帧成本 = base-pass overdraw + **Lumen 全屏 GI（C 实测 ~2-4ms/帧、重载占 ~34%，关掉 +36~40 FPS）** + TSR，全按**像素/覆盖**计价。**merge 守恒覆盖面积（视觉等价硬门槛）→ 只减三角形不减像素 → 天然动不了帧成本 → FPS 中性是必然**，其价值恒在顶点/VRAM/带宽。故要动 FPS 只能减像素成本，方向按**目标**分：

- **FPS 方向（回报最高，均像素/覆盖侧）**：
  - **Lumen 成本（C 实测：~2-4ms/帧，关掉 +36~40 FPS，最大单一可削减杠杆）**——候选：按距离降 Lumen 质量 / exclude 远景出 GI / 远景更便宜光照。牵渲染管线配置、最复杂但回报最高。
  - **base-pass overdraw（~6-8ms，帧成本大头）**——要真减**像素/覆盖**：激进 LOD / impostor（VHI 已在）/ 雾遮 far；**merge 这类保覆盖手段无效**。
  - **剔除（F4 已证，非瓶颈）**——可见 RHI 实测 361→101 可见(28%)，A2 per-component 剔除**真生效**（~72% 出视锥被剔）；offscreen `far_visible` 卡死=1 是遥测 bug、非剔除失效。
- **VRAM/带宽/规模方向（D，用户 2026-07-07 定：写入后续计划、暂不做）**：
  - **A5 顶点瘦身**——远景 mesh 顶点属性精简（A2/A3 已提及）。
  - **Nanite bake**——`EVoxiaFarFieldRenderBackend::NaniteStaticMeshBake`（`FarField/VoxiaFarFieldRenderArtifact.h:14`）枚举已预留、运行期未接；远景静态 shell 天然适合 Nanite。
  - **趁几何 −57% 推更大 LOD 半径/密度**——merge 腾出的几何预算可换更远可视距离或更细远景。
- **视觉正确性方向**：F1 视觉确认（Lit 默认是否消缝/不显脏）、F2 emergence 缝、F3 跨环界裂缝。

三方向不冲突、可并行，但**产品若追帧率，FPS 方向（Lumen/剔除）优先于继续减几何**——这是 Step 6 实测倒逼的排序。
