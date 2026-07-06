# Phase VLOD-A2：远景渲染后端分组件 + StaticDraw + 视锥剔除

> 状态：未开始
> 上游：[`2026-07-06-voxia-lod-layering-and-technology-design.md`](./2026-07-06-voxia-lod-layering-and-technology-design.md)（v2.6）§3.2d（T-6 渲染后端选型 + F-1 修订）、§9 里程碑 A 步 A2。
> 前置：[`phase-vlod-a1-explicit-tiering.md`](./phase-vlod-a1-explicit-tiering.md)（已完成，四环 tier 契约 + 1.39M quads 基座）。A1 §4.1 记录的 **8km 环境级 GPU device-removal** 是本步的头号靶心。
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
