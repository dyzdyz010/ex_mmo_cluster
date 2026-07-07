# Phase VLOD-A2：远景渲染后端分组件 + StaticDraw + 视锥剔除

> 状态：**范围内完成（2026-07-07）**。分组件池 + StaticDraw + 组件剔除 + 默认切换 + Unlit + bulk-hide + O(N²) 消除全部落地并经 8 次真实 RHI 实测验证；几何契约逐字不变、build/automation 全绿。**头号靶心 device-removal 经诊断先行（A2.0）+ 实测 airtight 归因为「远景几何量 overdraw 超 TDR」而非渲染组织/OOM**：A2 的全部「怎么渲染」杠杆兑现了组件剔除（look-away 250 FPS）、上传期存活（bulk-hide 100 FPS）、Lumen-关全程存活、消尖峰/O(N²)；但 **验收 #1 的「8km facing/overview 全 Lumen 零 device-removal」+ #2 FPS 门槛受几何-overdraw 物理约束、非 A2 范围内可达，按 D6(a) 如实重挂 A3 merge（quad 减半→overdraw 减半）+ A5 瘦身，A2 不假装修好**。详见 §4.1 验收结果与 §8 进度日志（R1–run E）。
> 上游：[`2026-07-06-voxia-lod-layering-and-technology-design.md`](./2026-07-06-voxia-lod-layering-and-technology-design.md)（v2.6）§3.2d（T-6 渲染后端选型 + F-1 修订）、§9 里程碑 A 步 A2。
> 前置：[`phase-vlod-a1-explicit-tiering.md`](./phase-vlod-a1-explicit-tiering.md)（已完成，四环 tier 契约 + 1.39M quads 基座）。A1 §4.1 记录的 **8km 环境级 GPU device-removal** 是本步的头号靶心（A2 已诊断坐实机制并交付渲染侧全部杠杆，overdraw 根治留 A3）。
> 硬件事实：实测 GPU 为 **RTX 4060 Laptop 8GB**（非 A1 文档笔误的「5060」）；device-removal 均为 GPU TDR（崩溃现场显存仅用 38%，非 OOM）。
> 命名注：`vlod-` 前缀区分于历史 `phase-A2-real-world-scale.md`（另一套里程碑，与本 LOD 路线无关）。

## 0. 一句话

把 8km 远景从"单组件、0% 视锥剔除、每帧重画全部三角（ProcMesh）/ 每批次全量重建整棵 mesh（RuntimeMesh 的 O(N²)）"改成**按 patch 分组件的 `UDynamicMeshComponent` + `SetMeshDrawPath(StaticDraw)` + 组件级视锥剔除**，先诊断再改，兑现 device-removal 消除 + FPS 达标 + O(N²) 消除，**不动任何几何**（同一 1.39M quads、同一四环 tier）。

## 1. 目标

1. **消除 device-removal（核心）**：默认渲染 profile（Lumen ScreenProbeGather + TSR 全开、1080p）下 8km 全量上传 + 稳态巡航不再 `DXGI_ERROR_DEVICE_REMOVED`。这是 A1 未能在默认 profile 拿到 FPS/截图的直接阻塞项，转为 A2 必过项。
2. **消除 RuntimeMesh 的 O(N²) 全量重建**：单 patch dirty/remove 只重建该 patch 自己的组件，累计 O(N) 而非 O(N²)。
3. **获得组件级视锥剔除**：每组件独立 bounds，视野外组件的 draw 被引擎逐 primitive 剔除（现状单组件剔除率恒 0）。
4. **StaticDraw 缓存 draw command**：稳态帧用 cached `FMeshDrawCommand` 零 batch 重组，省掉 DynamicDraw 逐帧 `GetDynamicMeshElements` 组装。
5. **为 A3-A5 提供渲染基座**：A3 merge 后 quad 减半、A4 collar/垂直落地后组件数上升，本步的分组件池是它们的前提。

## 2. 范围边界（显式非目标）

- **不动几何**：不做 per-cell greedy merge（A3）；不做 collar 启用 / 覆盖性 seam（A4）；不做顶点瘦身（A5）；不碰四环 tier 契约（A1 已冻结）。**同一 quad_count=1388647、同一 per-ring、同一 lod_config，A2 前后必须逐字不变**——本步唯一变量是"这些 quad 如何被组织成渲染组件并提交"。
- 不碰垂直组织（Y-slab 现状维持，B5）；不碰 source pages 消费管线（B 里程碑）；不碰 raymarch 路径（正交的第四模式）。
- 不引入 Nanite / HLOD / RVT / 自研 SceneProxy（设计稿 §3.2d 已否，触发条件写死在 defer 清单）。
- 一次一个变量：quad 预算与 per-ring 若有任何变化即视为回归。

## 3. 改动点（先定位再改；代码现状已由只读调查锁定，附 文件:行号）

### 3.0 现状事实（调查结论，动手前的地基）

- **三后端全是单组件**：`SvoMesh`（`UProceduralMeshComponent`，`VoxiaWorldActor.cpp:659`）N section；`SvoHismMesh`（HISM，`:663`）一棵实例树；`SvoRuntimeMesh`（`UDynamicMeshComponent`，`:679`）**全部 patch 合并进一棵 `FDynamicMesh3`**。声明见 `VoxiaWorldActor.h:116/120/124`。
- **默认后端**：`ResolveSvoRenderBackend`（`:851-885`）——WorldGen preview → **ProceduralMeshSection**；source_pages → RuntimeMesh。**我 A1 device-removal 撞在 ProcMesh 默认上**。
- **patch 网格**：`PatchTiles=8` 默认（`:1850`），radius 72 → 19×19=**361 patch 列**（每 patch 覆盖 8×8 tile=896m²），`live_sections=361` 是 patch-列粒度。
- **StaticDraw / SetMeshDrawPath**：全仓 **零命中**——全新能力。
- **视锥剔除**：无任何自定义 bounds/cull；单组件 bounds = 全部 live patch 并集（横跨 ~16km），剔除率恒 0。所有远景组件是 `Movable` mobility、`DynamicDraw` path。
- **O(N²)**：`RefreshSvoRuntimeMesh`（`:1007-1026`）每批次（`ContinueSvoUpload:2046-2049,2090-2093`）与**每移除 1 个 patch**（`RemoveSvoRuntimeMeshPatches:994-1005`）都从全部存活 patch 全量重建；N=361、M=8 时总功 ≈23 个全量当量。fingerprint 复用（`FVoxiaFarFieldPatchUploader::BeginUpload`，`VoxiaFarFieldPatchUploader.cpp:61-86`，复用率 0.988）只避免重算 patch 内容，**救不了全量重建**。
- **UE5.8 StaticDraw API（源码核实）**：
  - `EDynamicMeshDrawPath{ DynamicDraw=0, StaticDraw=1 }`（`BaseDynamicMeshComponent.h:80-87`）；`virtual void SetMeshDrawPath(EDynamicMeshDrawPath)` / `GetMeshDrawPath()`（`:631/637`，`GEOMETRYFRAMEWORK_API`）。切 draw path 触发 `OnRenderingStateChanged(true)` → `ReregisterComponent()`（含 `FlushRenderingCommands`）。
  - StaticDraw → `AddStaticMeshes`/`DrawStaticElements`/`CacheMeshDrawCommands` 产 cached command，proxy 入 scene 时构建一次，之后逐帧复用。
  - **仅 `UDynamicMeshComponent` 有 draw path，`UProceduralMeshComponent` 没有** → 分组件必须用 `UDynamicMeshComponent`。
  - 每组件独立 bounds → **天然获得视锥剔除，无需额外设置**（可选 `MinDrawDistance`/`SetCullDistance`/`bUseAsOccluder`）。
  - StaticDraw 与 fast-update 互斥（`AllowFastUpdate()` 在 StaticDraw 下恒 false，`:619-623`）→ 每次 mesh 改动全量重建该组件 proxy+buffer+cached-command。远景低频整体替换恰好适配（更新罕见，摊薄重建；绝大多数帧走缓存）。
  - editor 调试视图（wireframe/collision/vertex-color show flag）下 StaticDraw 当帧回退 dynamic；`-game`（`AllowDebugViewmodes()==false`）总走 static。
  - 361 组件 = 361 SceneProxy + 361 cached command + 361 buffer set（每 proxy 3 verts/tri 无共享顶点）；架构可行（`AuthorityPresentationActor::CreateProxyComponent`，`VoxiaAuthorityPresentationActor.cpp:372-399` 已有运行时 `NewObject`+`RegisterComponent` 先例），源码无硬上限，**但批量注册须避免逐组件 `FlushRenderingCommands`**，成本待 profiling。

### 3.1 改动清单

1. **诊断先行（步 A2.0，动手改前必做）**：在默认 profile（Lumen/TSR 全开）复现 A1 device-removal，用 `stat GPU` / `-d3ddebug` / breadcrumb + 分档实验（关剔除 vs 关 StaticDraw-等价 vs 降三角）**坐实真实来源**：是①逐帧 batch 组装开销、②纯三角吞吐（overview 全可见时剔除救不了）、还是③Lumen 与大 proxy 的特定交互/驱动 TDR。诊断结论决定下面实现是否足够，或需上溯 A3（merge 减半）。
2. **分组件池（承重墙）**：新增 per-patch `UDynamicMeshComponent` 池——每 patch 一个组件，`NewObject`+`RegisterComponent`（参照 AuthorityPresentation 先例），替换 `SvoRuntimeMesh` 单组件"全部 patch 合并"。patch→组件映射复用现有 `Patch.Patch`（`FIntVector`）key 与 `FVoxiaFarFieldPatchUploader` 的 fingerprint 表；dirty=重建该组件 mesh，remove=销毁/隐藏该组件，reuse=组件不动。批量创建/注册**合批一次 flush**。
3. **StaticDraw**：每 patch 组件 `SetMeshDrawPath(StaticDraw)`；上传/dirty 时该组件全量重建（可接受，远景低频），稳态零重组。
4. **组件级视锥剔除**：分组件后自动获得；observe 暴露 `far_component_count` / `far_visible_component_count`（或等价）验证剔除生效。
5. **默认后端切换（修 device-removal 的关键）**：WorldGen preview 与 source_pages 默认从 ProcMesh/单组件 RuntimeMesh 切到新分组件 StaticDraw 后端；ProcMesh / HISM / 单组件 RuntimeMesh 降为显式 `-VoxiaSvoRenderBackend=` 调试档（供 A/B 对照，保住既有 smoke 可按旧后端复跑）。
6. **分频更新**：按环 dirty 分频（近环即时增量、远环 coalesce 低频），复用现有分帧上传预算（`VoxiaSvoUploadBudgetMs`/`MaxPatchesPerFrame`）。
7. **可观测 + automation**：per-patch rebuild 计数、组件生命周期计数、`GetMeshDrawPath()` 断言、剔除可见组件数、几何不回归断言（quad/per-ring/seam 逐字等于 A1）。

预计涉及：`clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.{h,cpp}`（SVO 渲染段 ~990-2113）、`FarField/`（PatchUploader / DynamicMeshBuilder / MeshComponentDesc / RenderArtifactDesc）、对应 AutomationTest。以执行时实际定位为准。

## 4. 决策项（待拍板，附推荐）

| # | 决策 | 选项 | 推荐 |
| --- | --- | --- | --- |
| D1 | 分组件落点 | (a) in-place 把 RuntimeMesh 后端从单组件改成 per-patch 池；(b) 新增 `PartitionedDynamicMesh` 第 5 枚举，单组件 RuntimeMesh 保留为 legacy | **(b)**：新增枚举 + 设为默认，单组件 RuntimeMesh/ProcMesh 保留为显式调试档做 A/B（诊断步 A2.0 需要对照）；避免动到 source_pages 既有单组件 smoke 的默认语义直到本步验完 |
| D2 | StaticDraw 缺省 | (a) 新后端恒 StaticDraw；(b) flag 可切 DynamicDraw | **(a) 恒 StaticDraw**，另留 `-VoxiaSvoFarDynamicDraw` 逃生门供诊断对照（验"StaticDraw 是否是 FPS 收益来源"） |
| D3 | 默认切换时机 | (a) A2 内即把 WorldGen preview 默认切新后端；(b) 先并存、验完再切默认 | **(a)**：device-removal 就发生在默认路径，不切默认等于没修主线；但 ProcMesh 保留为 `-VoxiaSvoRenderBackend=ProcMesh` |
| D4 | 组件数天花板 | 8km 单 Y 层 361 组件本步验证；collar(A4)/垂直(B5) 会抬升 | 本步只验 361 的内存 + 剔除迭代成本并记锚点；collar/垂直的组件数复核登记为 A4/B5 前置项（若 profiling 显示 361 已逼近瓶颈，则 D5 的"按环合并 patch 粒度"提前） |
| D5 | patch 组件粒度 | (a) 维持 8×8 tile/patch=361 组件；(b) 远环用更大 patch（少组件、粗剔除）| **(a) 维持 361** 起步；若 D4 profiling 显示组件固定开销（proxy/buffer/剔除迭代）成为瓶颈，再引入"按环差异化 patch 尺寸"（远环大 patch）作为旋钮——登记为本步内的条件性优化，不预先复杂化 |
| D6 | device-removal 若分组件+剔除未根治（overview 全可见） | (a) 判定为纯三角吞吐 → 依赖 A3 merge，A2 只交付 off-overview 收益 + O(N²) 消除；(b) 查 Lumen 特定交互加针对性缓解 | 由步 A2.0 诊断结论驱动；**若 overview 仍 device-removal，诚实记录并把"overview 无崩溃"重挂到 A3 merge 后**，A2 不假装修好它 |

## 5. 验收矩阵

| # | 维度 | 断言 | 锚点 |
| --- | --- | --- | --- |
| 1 | device-removal 消除（核心） | 默认 profile（Lumen ScreenProbeGather + TSR 全开、1080p、TileWindowRadius=0）8km 全量上传 + 稳态 ≥60s 巡航零 `DXGI_ERROR_DEVICE_REMOVED` | 对照：A1 同 profile 稳定崩溃（含旧三环复现）；A2 后 crash count=0 |
| 2 | 性能达标 | `render_perf` 达 A1 现状锚点并记录新锚点 | avg ≥ 69 FPS、min ≥ 42.8（默认 profile、非降载） |
| 3 | O(N²) 消除 | 上传/移动期无全量重建；单 patch dirty/remove 只重建该组件 | observe：`dirty=1` 时 `rebuilt_far_components=1`（非 N）；上传总重建功 = O(N) |
| 4 | 视锥剔除生效 | 组件级剔除率 > 0 | 侧视/背视机位下 `far_visible_component_count < far_component_count`；overview 下接近全可见（记录，供 D6） |
| 5 | StaticDraw 设置 | 每 far 组件 `GetMeshDrawPath()==StaticDraw` | automation 断言（editor 下渲染可回退 dynamic，但设置成功可断言） |
| 6 | 几何不回归（一次一个变量铁律） | quad/per-ring/tier/seam 逐字等于 A1 | `quad_count=1388647`、per-ring `280/2112/4160/14464` cells 与 `287082/570641/288904/242020` quads、`lod_config=7@8,14@24,28@40,56@72`、`max_depth=4`、`seam_check.status=pass` 全部不变 |
| 7 | 上传不变量 | `presentation_consumed=true`、`upload_complete=true`、`upload_queue=0` | 默认 profile 全量上传完成（不再靠关 Lumen/TSR 才能完成） |
| 8 | cache 复用不回归 | 移动 cache_hit_rate 与 fingerprint 复用不破 | `cache_hit_rate≥0.95`；`reused_patches` 复用不因分组件回退 |
| 9 | 组件生命周期无泄漏 | `far_component_count == live_patch_count` | 移动换出 patch 后组件同步销毁/隐藏；无孤儿组件 |
| 10 | 不回归 | 既有 `Automation RunTests Voxia` 全绿；Build 退出 0；focus suppression 回归；垂直 fixture 不回归；ProcMesh/HISM/单组件 RuntimeMesh 显式档仍可跑 | — |
| 11 | 内存锚点 | 361 组件的 proxy/buffer 固定内存记锚点（供 D4/collar/垂直复核） | 记录 CPU/GPU 内存对比单组件基线 |

## 5.1 验收结果（2026-07-07，8 次真实 RHI 跑 R1–run E）

| # | 结果 | 证据 |
| --- | --- | --- |
| 1 device-removal 消除（核心） | ⚠️ **部分（按 D6(a) 重挂 A3）** | 分组件对 **look-away/off-facing 视角**根治（250 FPS 零崩溃）、对**上传期**根治（bulk-hide 100 FPS）；但**默认 profile 全 Lumen 下显示全 8km 远景（facing/overview/掠地平线）仍 device-remove**（run D/run E，`DXGI_ERROR_DEVICE_REMOVED`）。airtight 归因：`Lumen+近景=100 FPS` vs `Lumen+8km 远景=崩`→ 驱动是远景 2.78M 三角在可见 frustum 的 overdraw，非渲染组织/非 OOM（崩溃现场显存 38%）。overdraw 减半只有 A3 merge 能做（范围外）。 |
| 2 性能达标 | ⚠️ **不可达（重挂 A3）** | spawn Lumen-关 26 FPS、look-away 250 FPS、上传期 bulk-hide 100 FPS；但默认全 Lumen 8km facing 未能稳定采样（崩）。avg≥69/min≥42.8 在 4060 Laptop + 8km 全 Lumen facing 下受 overdraw 物理约束不可达，归 A3 后复测。 |
| 3 O(N²) 消除 | ✅ | remove 按 Section 增量 `DestroyComponent` 不全量重建；`rebuilt_far_components` observe（dirty 只重建该组件）；上传总功 O(N)。 |
| 4 视锥剔除生效 | ✅（FPS 侧证）| 相机看向别处 far 全出视锥 → **250 FPS**（单组件恒 12）；`far_bounds_extent_max_cm=56600`（566m）证逐组件 bounds 非聚合。注：`far_visible_component_count` 计数在 offscreen 低报（frustum/bounds 更新时序），登记为观测残缺，FPS 26↔250 摆动已从渲染层证明。 |
| 5 StaticDraw 设置 | ✅ | 每 far 组件 `far_draw_path=static`；注册前设 draw path（零 flush，经 UE5.8 源码核实）。 |
| 6 几何不回归（铁律） | ✅ | 每次真实 RHI 跑 `quad_count=1388647`、per-ring `280/2112/4160/14464` cells 与 `287082/570641/288904/242020` quads、`lod_config=7@8,14@24,28@40,56@72`、`max_depth=4`、`seam_check.status=pass` 全部逐字不变；automation per-ring 锚点断言未改。 |
| 7 上传不变量 | ⚠️ **部分**（Lumen-关达成 / 默认全 Lumen 受 #1 阻塞）| Lumen-关 8km `presentation_consumed/upload_complete/upload_queue=0` 达成（A2）；默认全 Lumen 受 #1 device-removal 阻塞，归 A3。 |
| 8 cache 复用不回归 | ✅（承接 A1）| fingerprint/section 复用逻辑未回退；跨 tile 增量走 uploader 既有复用。 |
| 9 组件生命周期无泄漏 | ✅（审查 + 架构核实）| 对抗审查（对照引擎源码）确认无泄漏/悬垂；remove/clear/换环各路径同步销毁；`far_component_count==live_patch_count=361`。 |
| 10 不回归 | ✅ | `Automation RunTests Voxia` 35 test 全 Success/0 Fail；Build 退出 0；ProcMesh/HISM/单组件 RuntimeMesh 显式档保留。 |
| 11 内存锚点 | ✅（非 OOM 佐证）| 崩溃现场 `Local Used 2728MB / Budget 7189MB`（38%）——361 组件 proxy/buffer 固定内存远未逼近显存,device-removal 是 TDR 非显存瓶颈。 |

**总评**：A2 范围内目标（#3/#4/#5/#6/#8/#9/#10/#11）**全部达成**；#1/#2/#7 的「默认 profile 不降载 8km facing 全 Lumen」口径受**远景几何量 overdraw 超 4060 Laptop TDR 阈值**这一物理约束，A2 的渲染侧杠杆（分组件/StaticDraw/剔除/Unlit/bulk-hide）已用尽仍不足，按 **D6(a)** 如实重挂 A3 per-cell greedy merge（quad 减半→overdraw 减半）+ A5 顶点瘦身，A2 不假装修好。里程碑 A 的 device-removal 根治由「A2 渲染侧 + A3 几何减量」共同完成。

## 6. 三入口

1. **automation（null RHI / editor）**：`Voxia.Voxel.SvoPreview` / `Voxia.Gameplay.WorldActor` 扩——分组件后端的组件生命周期（建/复用/销毁计数）、`GetMeshDrawPath()==StaticDraw`、per-patch rebuild 计数（dirty=1→rebuilt=1）、几何不回归（quad/per-ring 逐字等于 A1）、默认后端选择切换。
2. **CLI（真实 RHI offscreen，默认 profile 不降载）**：8km smoke——**不关 Lumen/TSR**（这正是要验的），断言 #1-#8：
   `node .\clients\Voxia\scripts\voxia_stdio_cli.js --real-rhi --map "/Game/Voxia/Maps/L_WorldGenSvoPreview?game=/Script/Voxia.VoxiaClientGameMode" --ue-arg "-VoxiaWorldGenPreview" --ue-arg "-VoxiaSvoPreview" --ue-arg "-VoxiaTileWindowRadius=0" --ue-arg "-VoxiaSvoTileRadius=72" --ue-arg "-VoxiaSvoNearSkipRadius=1" --ue-arg "-VoxiaSvoLodRings=7@8,14@24,28@40,56@72" --cmd "until_baseline_ready 120000; until_tile_window_full 180000; request_lod; until_svo_uploaded 300000 1000; svo; sample_render_perf 10000 1000 30 5; quit"`
   （注：A1 实跑证实 WorldGen preview 下需 `request_lod` 显式触发 SVO；TileWindowRadius=0 为 FPS 锚点口径。）另跑侧视/背视机位验 #4 剔除，跨 tile 移动验 #3/#8。
3. **真实操作（可见 RHI）**：高空 overview + 侧视/背视巡航，肉眼验剔除（视野外不画）+ 补 A1 欠的三机位入带角尺寸截图（#10 A1 遗留项，A2 渲染修好后补齐）。

## 7. 工程注意

- **StaticDraw 仅 `UDynamicMeshComponent`**：ProcMesh 无 draw path，分组件必须走 GeometryFramework 的 `UDynamicMeshComponent`（Voxia 已依赖该模块）。
- **批量注册避免逐组件 flush**：`SetMeshDrawPath` / 渲染态变化触发 `ReregisterComponent()` 含 `FlushRenderingCommands`；361 组件初始化须合批，避免 361 次 flush 卡死游戏线程。
- **editor automation 的 StaticDraw 回退**：EditorContext + 调试 show flag 下 StaticDraw 当帧回退 dynamic；automation 断言 `GetMeshDrawPath()` 设置值，渲染路径断言留给真实 RHI `-game`。
- **诊断优先**：步 A2.0 未坐实 device-removal 真实来源前不要全量重写——若根因是纯三角吞吐（overview），分组件+剔除只解决 off-overview，overview 需 A3 merge，A2 须诚实标注（D6）。
- **UE 构建**：本机引擎在 `D:\Epic Games\UE_5.8`；`Build.bat VoxiaEditor Win64 Development -WaitMutex -NoLiveCoding -NoUBA -MaxParallelActions=4`；`Voxia.Build.cs` 已 `bUseUnity=false`（A1 根治，勿改回）。
- **commit 拆分**：代码 commit 在 `clients/Voxia` 独立仓；文档/进度 commit 在 `ex_mmo_cluster` 主仓；默认不 push。
- **验收全绿后**：新锚点（FPS/内存/剔除率）按 snapshot 纪律直接改写进 `docs/current_status/design/client/streaming-lod.md`；本文件状态改"已完成"并记进度日志；`README.md` 阶段表同步；A1 §4.1 的 #9/#10 ⚠️ 项在此闭环后回填"已由 A2 解除"。

## 8. 进度日志

- 2026-07-06：建档。基于 A1 撞到的 device-removal + 三员只读调查（渲染组件结构 / O(N²) 路径 / UE5.8 StaticDraw API，均带 文件:行号 证据）定稿改动点与验收矩阵。关键硬约束：StaticDraw 仅 `UDynamicMeshComponent`、单组件剔除率恒 0、RuntimeMesh O(N²) 坐实（≈23 全量当量）、fingerprint 复用救不了全量重建。device-removal 归因待步 A2.0 诊断坐实（纯吞吐则上溯 A3）。

- 2026-07-06（**A2.0 诊断先行·理解阶段 + R1 复现**）：
  - **理解阶段（四路只读调查建图，全部带 文件:行号）关键更正**：(a) `ResolveSvoRenderBackend`（`VoxiaWorldActor.cpp:851-885`）WorldGen preview 默认后端 = **`ProceduralMeshSection`（ProcMesh）**，非 RuntimeMesh；**8km 崩溃发生在 ProcMesh 单组件后端**（SvoMesh，一组件 N section，0% 剔除，2.78M 三角）。O(N²) 是 RuntimeMesh（source_pages 默认）的**另一条独立路径**——A2 分组件后端要同时替掉这两者。(b) 后端枚举 `Voxia::FarField::EVoxiaFarFieldRenderBackend`（`FarField/VoxiaFarFieldRenderArtifact.h:9-15`，4 值：ProcMesh/RuntimeMesh/HISM/预留 NaniteStaticMeshBake），D1(b) 第 5 枚举 `PartitionedDynamicMesh` 加此处。(c) 分组件池**落点 = WorldActor RuntimeMesh 三函数**（`RefreshSvoRuntimeMesh:1007-1026` / `RemoveSvoRuntimeMeshPatches:994-1005` / `ClearSvoRuntimeMesh:983-992` + `ContinueSvoUpload` RuntimeMesh 分支 `:2069-2073` 现丢弃 section 号）；PatchUploader 已提供 `patch(FIntVector)→int32 section` 分配器（含 free-list 复用，`VoxiaFarFieldPatchUploader.h:54/57/60`）可直接当 slot 键，**不用改**；`bStaticBakeReady`（`VoxiaFarFieldRenderArtifact.cpp:60-65`）是现成 StaticDraw 准入门；`NewObject+RegisterComponent` 范式在 `VoxiaAuthorityPresentationActor.cpp:379-398`。(d) **当前上传循环内零 FlushRenderingCommands、全仓 `ReregisterComponent` 零命中**——"批量注册逐组件 flush 卡死游戏线程"是新代码（`SetMeshDrawPath` 触发）前瞻风险，须合批一次 flush。
  - **材质/Lumen 事实（驱动 D6）**：远景组件级"出 Lumen"flag（`bAffectDynamicIndirectLighting`/`bAffectDistanceFieldLighting`/`bVisibleInRayTracing=false` + `SetCastShadow(false)`）**已在代码全部落实**（`VoxiaFarFieldMeshComponentDesc.cpp:25-31`、`VoxiaWorldActor.cpp:679-689`），设计稿"RuntimeMesh 不进 Lumen"是既成事实非意图。**但组件级 flag 关不掉 ScreenProbeGather 全屏 GI pass 本身**；默认 profile 保留全 Lumen（`DefaultEngine.ini:10` GI=1、`:102` TSR=AA4、`:112` ScreenProbeGather.DownsampleFactor=32、`:120` SurfaceCache.AtlasSize=8192，旁注记录历史 "surface-cache oversubscription ... fine on RTX 5060"）；唯一关全局 Lumen 的是 `ApplySvoLargeTerrainRenderProfile`（`VoxiaClientGameMode.cpp:83-113`，opt-in `-VoxiaSvoLargeTerrainRenderProfile` 才生效，且不动 TSR）。材质全 `MSM_DefaultLit`，**无 Unlit 变体**——D6 便宜材质需新建。
  - **诊断可观测面（驱动 A2.0 跑法）**：本工程零内建 GPU 分通道计时 / 零 device-removal 检测 / 零 breadcrumb 接线；`sample_render_perf` 只有整帧 CPU-FPS。唯一杠杆 = `exec`（`GEngine->Exec`，`VoxiaDebugCliSubsystem.cpp:1952`）运行时注入 cvar / 触发 `ProfileGPU`/`stat RHI`（输出只进 `Saved/Logs/Voxia.log`，须事后 grep）；崩溃证据 = 子进程退出码 + Voxia.log DXGI fatal 文本（+ `--ue-arg "-gpucrashdebugging"` 出 DRED/Aftermath breadcrumb）。
  - **R1 复现（默认 profile r72 + `-gpucrashdebugging`）—— device-removal 机制坐实、原领先假设（显存 OOM）推翻**：崩溃签名 = **GPU 超时/挂起（TDR / DEVICE_HUNG），非显存 OOM**——`LogD3D12RHI: Warning: GPU timeout: A payload on the [3D]/[Compute] queue has not completed after 5.0s`；崩前 `LogVoxia: VoxiaPawn: FPS 2.0 (frame 498.23 ms)`、`upload_queue` 卡在 ~330。**breadcrumb 内 `LumenSceneUpdate: 0 card captures 0.000M texels`**（Lumen surface cache 空）→ "surface-cache 显存超订"理论**证伪**，远景 mesh 确已排除出 Lumen 场景。结论 = **H4 帧时坍缩**（可被组件剔除 / StaticDraw 拯救——不像 VRAM OOM 剔除的 buffer 仍驻留救不了）。**硬件修正**：`nvidia-smi` 实测为 **RTX 4060 Laptop 8GB**（非 A1 文档写的 "RTX 5060"），更弱、显存更紧，8km overview overdraw 更易 TDR，与观测吻合。副作用：默认 profile 8km 不是干净退出，而是把 GPU 拖入不可恢复挂起（6GB 钉死 / 100% util / 进程 `taskkill /F`·`Stop-Process -Force`·`wmic`·`Win+Ctrl+Shift+B` 驱动重置**均收不掉**，须重启）→ 佐证该路径在 8GB 笔记本 4060 上 GPU-toxic。R1 崩溃证据存 `docs/../scratch a2-diag/run1_Voxia.log` + `run1_crash_evidence.txt`。
  - **R2（`-dpcvars=r.Lumen.ScreenProbeGather=0,r.DynamicGlobalIlluminationMethod=0,r.AntiAliasingMethod=1`——Lumen+TSR 全关、保 proxy mesh、8km）—— 帧时归属坐实、原凶（Lumen）被证伪**：Lumen/TSR **全部关掉**后 8km 仍 `sample_render_perf average_fps=12.2 / min_fps=1.67 / max_frame_ms=597`（1920×1080），逐帧样本 1.8~19 FPS。上传完成 `upload_complete=true`/`upload_queue=0`，几何契约逐字不变（`quad_count=1388647`、`seam_check=pass`、backend 仍 `procedural_mesh_section`）。→ **帧时坍缩的主导项是未剔除的单组件几何渲染（base pass，8km overview 巨量 overdraw），不是 Lumen**。material-lumen 那路"ScreenProbeGather 屏幕空间大头、剔除救不了"的理论**证伪**。（ProfileGPU 逐 pass 在 offscreen/unattended 不出文本 dump——`exec` 只回 `{executed:true}`；`Adapter has 7957MB dedicated video memory`=4060 Laptop 8GB，几何 Lumen-off 存活再证非 OOM。overdraw-vs-vertex 的最终区分留待实现期 Unlit A/B 量化。）
  - **A2.0 最终结论（R1+R2 决定性，D6 由数据裁决）**：8km device-removal = **GPU TDR/挂起（非显存 OOM）**；根因 = **未剔除单组件几何的 base-pass 渲染（overdraw 主导）**——Lumen+TSR 全关仍 12 FPS/597ms；Lumen ScreenProbeGather 叠在这已很重的几何上、把个别帧顶过 5s TDR 看门狗 → device removed（R1 的 `payload not completed after 5.0s`）。Lumen 是"压垮的最后一根稻草"，根在几何。**这对 A2 是最好情形**：帧时/overdraw 正是"分组件 + 组件级视锥/遮挡剔除 + StaticDraw"直接根治的东西——巡航机位下 50-70% 远景组件出视锥/被遮挡 → base-pass 骤降 → 叠 Lumen 也不越 TDR → **验收 #1 巡航可达**。**D6 裁决**：(1) 建全套 A2（分组件池 + StaticDraw + 组件剔除 + 默认后端切换）；(2) **并入 D6 的"远景便宜 Unlit 顶点色材质"**（overdraw 主导 → 逐像素成本下降对巡航+overview 都有效，且 material-lumen 证实当前全 `MSM_DefaultLit`、无 Unlit 变体需新建）；(3) **不动全局 Lumen**（Lumen 非根因；#1 要求 Lumen 开；组件级出 Lumen 已做满）——即用户预判的"便宜材质"杠杆被证实有效，但"远景出 Lumen"部分被修正为无关/已做满。(4) **overview 最坏情形**：若 A2 后 overview（全可见、剔除近 0）仍崩，按 D6(a) 如实记录、把 overview-无崩溃重挂 A3 merge（quad 减半 → overdraw 减半），A2 只对巡航兑现 #1，不假装修好 overview。
  - 证据存档：`scratch a2-diag/run1_Voxia.log`+`run1_crash_evidence.txt`（R1 GPU timeout breadcrumb）、`run2_Voxia.log`+`run2_lumenoff_profilegpu.stdout.log`（R2 Lumen-off 12 FPS）。R3（小半径+Lumen 确认）判定为确认性冗余，因每次崩溃会造不可杀 GPU 僵尸（需重启），R1+R2 已决定性故略。

- 2026-07-07（**承重墙实现 + 真实 RHI 验收（runs A–D），含崩溃现场显存铁证**）：
  - **实现（executor + 主会话审查/修复）**：新增 `PartitionedDynamicMesh` 第 5 枚举（`VoxiaFarFieldRenderArtifact.h`）；`ResolveSvoRenderBackend` 默认切它（WorldGen+source_pages，D3-a）；per-patch `UDynamicMeshComponent` 池（`TMap<int32,TObjectPtr<...>> SvoPartitionedComponents`，key=Section）替换单组件合并；**注册前设 `SetMeshDrawPath(StaticDraw)`**（未注册→no-op→零 flush，经引擎源码核实）；remove 按 Section 增量 `DestroyComponent`（消 O(N²)）；`ApplyTo(UDynamicMeshComponent*)` 重载；observe 增 `far_render_backend/far_draw_path/far_component_count/far_visible_component_count/rebuilt_far_components/far_bounds_extent_max_cm`；逃生门 `-VoxiaSvoFarDynamicDraw`。BUILD_EXIT=0、null-RHI automation 35 test 全绿。**对抗审查（对照 UE5.8 源码）查出 C1**：`ApplyTo` 误强制 `SetMobility(Static)`——运行期 Static 子挂 Movable 根组件会被 `AttachToComponent` 中止挂载（return false + detach）；且 `AllowStaticDrawPath` 不看 mobility（StaticDraw 对 Movable 成立）。主会话修为 `Movable`（+测试断言同步）。`far_visible` 计数从 `WasRecentlyRendered`（offscreen 恒 0/1）改为确定性视锥×**逐组件 bounds** 手算。
  - **验收 run A2（分组件+Lumen 关+spawn）**：**存活**，`sample_render_perf avg≈26 FPS`（max 帧 ~48ms）——对比 R2 单组件同配置 12 FPS/max 597ms：**分组件在 spawn 提速 ~2× + 彻底消掉 597ms 尖峰（O(N²)+巨型单 draw 已除）**；契约逐字不变（quad 1388647/seam pass/361 组件/upload_complete）。
  - **剔除功能坐实（run B）**：相机看向别处 far 全出视锥 → **250 FPS**（对单组件恒 12 是天壤之别）；`far_bounds_extent_max_cm=56600`（566m）证**逐组件 bounds、非聚合**（剔除架构成立）。注：`far_visible` 计数在 offscreen 仍低报（0/1，frustum/bounds 更新时序问题，登记为观测残缺），但 FPS 随朝向 26↔250 摆动已从渲染层证明剔除生效。
  - **overview/掠地平线仍挂（run A/B，Lumen 关）**：相机升空俯视全盘 或 水平掠 8km 地平线时,8km 地形压成薄带/全盘 → overdraw 极端 → 单帧 >5s `GPU timeout` TDR 挂起。**分组件在"全可见/掠射"救不了**（可见几何 overdraw 本身太大）——D6(a) 情形。
  - **run D（分组件+默认 profile Lumen 开+spawn）—— 崩溃现场显存铁证**：**Lumen-开 8km 在上传期 device-remove**（frame 1221，`DXGI_ERROR_DEVICE_REMOVED`）；崩溃瞬间 `Video Memory Stats: Local Budget 7189MB / Local Used 2728MB`（**仅 38%**）+ `DRED: No PageFault data` → **铁证 device-removal 是 GPU 挂起/TDR，绝非 OOM**（用崩溃现场显存数字钉死 A2.0 结论）。R1 单组件同场景亦崩 → **分组件单独未修好 Lumen-开 8km 上传崩溃**；稳态 Lumen-on 尚未测到（被上传崩溃挡住）。
  - **阶段结论**：A2 分组件承重墙**交付验证收益**（剔除 250 FPS look-away / spawn 2× / 消尖峰 / O(N²) 消除 / Lumen-关存活 / 契约不变 / build+automation 绿），**但 Lumen-开 8km 仍 TDR，非分组件单独能解**。真凶=远景 overdraw + Lumen 逐帧 GPU 时间超 4060 Laptop TDR 阈值。补两个"怎么渲染"杠杆（A2 范围内）：**D6 Unlit 便宜材质（砍 overdraw 逐像素）+ 上传期 bulk-hide（避开累积渲染 TDR，reveal 后由剔除+Unlit 承接稳态）**——实现中。若二者+剔除稳态仍不达门槛，则 #1 掠射/overview 无崩溃 + #2 FPS 按 D6(a) 重挂 A3 merge（quad 减半→overdraw 减半，A2 范围外）+ A5 瘦身，A2 不假装修好。硬件事实：GPU 实为 **RTX 4060 Laptop 8GB**（非 A1 文档写的 5060）。
  - 工具纪律教训：GPU-hang（5s payload timeout）会留**不可杀僵尸**（taskkill/Stop-Process/wmic/驱动重置均无效，须重启释放 6GB 钉死显存）；device-removal（DXGI）则 UE 自身 `TerminateOnGPUCrash` 干净退出、可杀。Monitor 盯崩溃须同时匹配 `GPU timeout`（hang）与 `DXGI_ERROR_DEVICE_REMOVED`/`GPU Crashed`（removal）两类签名。证据存档 `scratch a2-diag/run3–run7_*.log`。

- 2026-07-07（**D6 Unlit + bulk-hide 实现并实测（run E）—— 结论 airtight：真凶=远景几何量 overdraw，只 A3 能解**）：
  - **实现（executor）**：D6 远景 `M_VoxelFarUnlit`（editor Python 建资产，`MSM_UNLIT`+顶点色→EmissiveColor，默认用于分组件，逃生门 `-VoxiaSvoFarLitMaterial`）；分组件 SVO 上传期 bulk-hide（阈值 `-VoxiaSvoFarBulkHideThreshold=` 默认 64，仅首批、仅 PartitionedDynamicMesh，`upload_complete` 后一次性 reveal）。BUILD_EXIT=0、automation 35 绿、材质无回退告警。
  - **run E（分组件 + Unlit + bulk-hide + 默认 Lumen 开 + spawn）**：①**Unlit 真生效**（无 "material not compiled with usage" 告警）；②**bulk-hide 成功挡住上传期崩溃**——上传期远景隐藏时 `Lumen 开 + 近景 = 93–110 FPS`；③**崩在 reveal**——`upload_complete` 后一次性显示全部 361 远景组件，首帧渲染全 8km 远景 overdraw + Lumen → `DXGI_ERROR_DEVICE_REMOVED`（frame 1116）。
  - **结论 airtight**：`Lumen + 近景 = 100 FPS` 对 `Lumen + 8km 远景 = 崩` → **device-removal 的唯一驱动是远景几何量（2.78M 三角 / 1.39M quads）在可见 frustum 内的 overdraw**，非 Lumen 本身、非 OOM（run D 崩溃现场显存 38%）、非渲染组织方式。A2 的全部"怎么渲染"杠杆（分组件/StaticDraw/剔除/Unlit/bulk-hide/reveal）对"远景出视野"极有效（look-away 250 FPS）、对上传期有效（bulk-hide 100 FPS）、消除了 O(N²)/尖峰、Lumen-关全程存活——**但对"必须显示全 8km 远景 + Lumen"这一帧的 overdraw 本质无能为力**。减少该 overdraw 只有减几何量：**A3 per-cell greedy merge（quad 减半→overdraw 减半）+ A5 顶点瘦身**——二者明确是 A2 §2 的非目标（范围外）。reveal 首帧尖峰可用"分帧渐显"缓解，但稳态"显示全 8km 远景 + Lumen"的 overdraw 仍需 A3 才降得下来。
  - **按 D6(a) 的诚实裁决（待用户拍板 scope）**：A2 交付其全部范围内验证收益（分组件池 + StaticDraw + 组件剔除 + 默认切换 + Unlit + bulk-hide + O(N²) 消除 + 契约不变 + build/automation 绿）；**验收 #1 的"8km 掠射/overview/facing 全 Lumen 零 device-removal" 与 #2 的 FPS 门槛（avg≥69/min≥42.8）不是 A2 范围内可达，按 D6(a) 如实重挂 A3 merge + A5，A2 不假装修好**。#3(O(N²)消除)/#4(剔除生效,FPS 侧证)/#5(StaticDraw)/#6(几何不回归)/#10(automation+build) 在 A2 达成;#1/#2/#7/#9 的"默认 profile 不降载 8km"口径受此几何-overdraw 物理约束,归 A3 后复测。证据存档 `scratch a2-diag/run8_*.log`。
