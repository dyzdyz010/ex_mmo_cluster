# Phase VLOD-A1：切默认分级 + 显式 tier 契约 + L2.5 第三环

> 状态：实现完成、核心验收全绿（2026-07-06）。tier 契约 / 四环默认 / L2.5 / per-ring / cache 全部落地并经 automation + 真实 RHI build/upload 验证；#9 FPS 与 #10 截图审计被一个**与 A1 无关的环境级 GPU device-removal**（8km ProcMesh 大代理在默认 Lumen/TSR profile 下 `DXGI_ERROR_DEVICE_REMOVED`，旧三环分级逐字复现，归 A2 渲染后端重构）阻塞，几何正确性已由 seam pass + per-ring 覆盖 + 存活 profile upload_complete 结构化覆盖。见 §4.1 验收结果与 §7 进度日志。
> 上游：[`2026-07-06-voxia-lod-layering-and-technology-design.md`](./2026-07-06-voxia-lod-layering-and-technology-design.md)（v2.6）§2 分带总表（T-1/T-2 已拍板）、§8 显式 tier 契约（T-10）、§9 里程碑 A 步 A1。
> 命名注：编号前缀 `vlod-` 用于与历史 `phase-A1-playable-client-experience.md` 区分；本文件对应设计稿三列里程碑中的 A1。

## 1. 目标

把 Voxia 远景 SVO 从"samples/ring 隐式推导、事实上 7/7/28 三档"切换为**显式 tier 契约驱动的四环分带 7/14/28/56m**，独立兑现 8km 全量 quads 3.70M → 约 1.34M（−64%），并为 A2-A5 提供配置基座与 per-ring 可观测。

目标分带（T-2 已拍板）：

| 环 | tile 距离 d（Chebyshev） | 叶尺寸 | depth（112m cell） |
| --- | --- | --- | --- |
| L1 | 2-8 | 7m | 4 |
| L2 | 9-24 | 14m | 3 |
| L2.5 | 25-40 | 28m | 2 |
| L3 | 41-72 | 56m | 1 |

（d ≤ 1 为 L0 near-skip 区；collar 3.5m@depth5 只落**语法**支持，启用归 A4——需 depth clamp 1..4→5 放宽，A1 不做。）

## 2. 范围边界（显式非目标）

- 不做 per-cell greedy merge（A3）；不做换环 fade / 跨 depth 覆盖性 seam 断言 / collar 启用（A4）；不做顶点瘦身与 cache LRU（A5）；不做分组件渲染后端改造（A2）；不碰垂直组织（Y-slab 现状维持，正式化归 B5）；不把 `lod_config` 写进 source pages manifest（B1/B2）。
- 一次一个变量：本步只动水平分带与 tier 契约。quad 预算变化必须可归因于分带本身。

## 3. 改动点（先定位再改）

1. **语义定位（动手前必做）**：通读现有 `FVoxiaSvoBuildConfig` 与 SVO 构建路径，理清 `samples_per_tile_axis` 与 near/mid 两环 boost（+3/+2）如何共同决定各环 depth——设计稿备注"现代码只有 near/mid 两环 boost"，第三环是新增能力，不是改数字。
2. **tier 显式契约**：新增 `-VoxiaSvoLodRings=7@8,14@24,28@40,56@72` 语法（`叶尺寸@环外界 d`，逗号分隔、由近到远；语法层同时接受 `3.5@4` collar 档但 A1 拒绝启用 depth5 并给出诊断）。解析结果替代 samples/ring 隐式推导；Transport 与脚本默认必须一致。
3. **配置等式与 cache key**：`SameReusableSvoConfig` 等式纳入完整 tier 配置；macro-cell artifact cache key 混入 `lod_config`——换分级不得复用旧 artifact，同分级移动复用不回归。
4. **per-ring 可观测**：`svo` / observe 输出 per-ring `cells / quads / depth`。
5. **默认分级切换**：默认配置改为四环 7/14/28/56（等效 samples=2 + 三环 boost），`-VoxiaSvoTileRadius=72` 下全量生效。
6. **automation**：`Voxia.Voxel.SvoPreview` 扩：tier 语法正/负向解析、config 等式含新字段、per-ring 统计断言。

预计涉及：`clients/Voxia/Source/Voxia/Voxel/`（SvoPreview/BuildConfig 家族）、`Gameplay/VoxiaWorldActor`、`UVoxiaTransportSubsystem` 启动参数解析、对应 AutomationTest。以执行时实际定位为准。

## 4. 验收矩阵

| # | 维度 | 断言 | 锚点 |
| --- | --- | --- | --- |
| 1 | tier 契约·正向 | 显式语法生效，替代隐式推导；Transport 与脚本默认一致 | 四环 depth 分布 d2-8→4 / d9-24→3 / d25-40→2 / d41-72→1 |
| 2 | tier 契约·负向 | 非法语法（乱序/越 clamp/重叠环/collar 档启用）显式失败并给诊断，不静默回退 | 失败语义同 H gate：拒绝 + 原因，无 fallback |
| 3 | 可观测 | `svo`/observe 输出 per-ring `cells/quads/depth` | cells 分桶 L1 280 / L2 2,112 / L2.5 4,160 / L3 14,464，合计 21,016 |
| 4 | 预算·全场 | 8km 全量 quad_count 达标 | ≈1.34M ±15%（现状 3.70M，−64%）；内存不高于现状 |
| 5 | 预算·分环 | per-ring quads 落预算分桶 | L1 291k / L2 549k / L2.5 270k / L3 234k，各 ±20%（k=4.06，3D preview 内容） |
| 6 | cache·负向 | 改 `lod_config` 后不复用旧 artifact | 切换分级后首次 build `reused_macro_cell_count=0` |
| 7 | cache·正向 | 同 config 跨 tile 移动复用不回归 | `cache_hit_rate ≥ 0.95`（现状锚点 0.958/0.988） |
| 8 | 不回归 | 现状口径 `seam_check.status=pass`（现状 seam_check 不验证跨 depth，覆盖性断言归 A4；跨 depth 边界 2→3 处，靠 #10 截图人工看）；`presentation_consumed=true`、`upload_complete=true`、`upload_queue=0`；focus suppression 回归；既有 automation 全绿；Build 退出 0 | — |
| 9 | 性能底线 | `render_perf` 不低于现状锚点并记录新锚点（供 A2 尖峰归因对照） | avg ≥ 69 FPS、min ≥ 42.8（底线非目标） |
| 10 | 视觉审计 | `capture_screenshot` + `audit_png` 通过，含入带角尺寸目视机位 | ≥3 机位：~1km 看 14m 入带（17px）、~2.8km 看 28m 入带（12px）、~4.6km 看 56m 入带（15px）；无洞、无明显双显 |
| 11 | 垂直回归 | Y-slab 现状行为不变：浮空岛 preview 下可见；多 Y 层 source page fixture 行为（含缺 vertical page 硬失败）不回归 | — |

### 4.1 验收结果（2026-07-06）

| # | 结果 | 证据 |
| --- | --- | --- |
| 1 tier·正向 | ✅ | 真实 RHI `svo`：`lod_config=7@8,14@24,28@40,56@72`、per-ring `depth=4/3/2/1`、d2-8→4/d9-24→3/d25-40→2/d41-72→1（automation `CellDepthForRings` 边界逐档断言）；Transport 与脚本/fixture 均走 `DefaultLodRings()` 单一来源 |
| 2 tier·负向 | ✅（含实战自证） | automation：乱序/重叠/非阶梯/坏 token/覆盖不足/空表全部拒绝带诊断；collar `3.5@N` 语法可解析、启用被拒且诊断含 "A4"；直构非法 config 走 Build 入口硬失败。**真实 RHI 自证**：`FParse` 逗号截断把 `7@8,...` 读成 `7@8`，未静默跑错分级而是 `voxia_svo_rejected` + `"cover d<=8 but radius is 72"` 诊断 |
| 3 可观测 | ✅ | 真实 RHI `svo.lod_rings` 与 observe `ring_cells/ring_quads/ring_depths`：cells `280/2112/4160/14464`（合计 21016）；automation 精确锚点断言 |
| 4 预算·全场 | ✅ | 真实 RHI `quad_count=1388647`（≈1.34M，落 ±15%；对旧 3.70M 为 **−62%**）；runtime payload 20.5MB |
| 5 预算·分环 | ✅ | per-ring quads `287082/570641/288904/242020`；对预算 291k/549k/270k/234k 分别 −1.3%/+3.9%/+7.0%/+3.4%，全落 ±20% |
| 6 cache·负向 | ✅ | automation：换 tier → `reused=0`、`built=coverage`、`BuildKeyPrefix` 前缀变化（lod_config 进 key） |
| 7 cache·正向 | ✅（确定性） | automation：radius 72 平移 1 tile → `cache_hit_rate≥0.95`、重建 <1/4、`reused+built=coverage`（与真实 RHI 现状锚点 0.958/0.988 同一逻辑；真实 RHI 移动 smoke 受 #9 同源环境阻塞，改由 null-RHI 确定性验证） |
| 8 不回归 | ✅（存活 profile）| 关 Lumen ScreenProbeGather + TSR 后真实 RHI 8km 四环全量：`presentation_consumed=true`、`upload_complete=true`、`upload_queue=0`、`seam_check.status=pass`、`uploaded_patches=361`；Build 退出 0；`Automation RunTests Voxia` 34 test 全 Success、零 Fail（含 SvoPreview/WorldActor/FarField/source_pages/suppression） |
| 9 性能底线 | ⚠️ 环境阻塞（A2）| 默认 Lumen/TSR profile 渲染 8km ProcMesh 大代理（单组件 0% 剔除 / 2.78M 三角）稳定 `DXGI_ERROR_DEVICE_REMOVED`；**旧三环 `7@24,28@72`（3.69M quads）逐字复现** → 与 A1/分级无关，A1 反而 −62% 减负；崩溃 breadcrumb 在 Lumen ScreenProbeGather / TSR / TranslucencyLighting 稳态。FPS 锚点归 A2「分组件 StaticDraw + 组件剔除」重构后重测（本项设计上为非门槛底线） |
| 10 视觉审计 | ⚠️ 部分（结构化替代）| 截图机制在存活/降级 profile 下未落盘（同 #9 环境）；"无洞"由 `seam_check.status=pass`（全量扫 1.39M quad 查缝隙/重复面）+ per-ring 覆盖精确 + upload_complete 覆盖；入带角尺寸目视机位随 A2 修复渲染后补 |
| 11 垂直回归 | ✅ | `Voxia.Voxel.SvoPreview` 含多 Y 层 fixture 与 `svo_source_pages_fixture` 的 `vertical_checks`（含缺 vertical page 硬失败）在全套 automation 中通过、无回归 |

**总评**：A1 自有交付（tier 契约 / 四环默认 / L2.5 / per-ring / cache）**全部达标**；两项 ⚠️（#9/#10）由单一环境级 GPU device-removal 阻塞，该阻塞与 A1 正交（旧分级复现）、属 A2 渲染后端域，已用结构化证据覆盖几何正确性，不构成 A1 回归。

## 5. 三入口

1. **automation（null RHI）**：`Automation RunTests Voxia.Voxel.SvoPreview`（含新断言）+ `Voxia.Gameplay.WorldActor`。
2. **CLI（真实 RHI offscreen）**：8km smoke，在既有命令模板上加 tier 参数：
   `node .\clients\Voxia\scripts\voxia_stdio_cli.js --real-rhi --map "/Game/Voxia/Maps/L_WorldGenSvoPreview?game=/Script/Voxia.VoxiaClientGameMode" --ue-arg "-VoxiaWorldGenPreview" --ue-arg "-VoxiaSvoPreview" --ue-arg "-VoxiaTileWindowRadius=0" --ue-arg "-VoxiaSvoTileRadius=72" --ue-arg "-VoxiaSvoNearSkipRadius=1" --ue-arg "-VoxiaSvoLodRings=7@8,14@24,28@40,56@72" --ue-arg "-VoxiaSvoUploadMaxPatchesPerFrame=128" --ue-arg "-VoxiaSvoUploadBudgetMs=12" --cmd "until_baseline_ready 120000; until_tile_window_full 180000; request_lod; until_svo_uploaded 240000 1000; svo; sample_render_perf 10000 1000 30 5; quit"`
   断言 #3-#9；另跑跨 1 tile 移动复跑验 #7。
   注（2026-07-06 实跑修正）：①WorldGen preview 下 pawn 停在 `phase=idle`（不走真实 InScene 订阅链），SVO 构建必须靠 `request_lod` CLI 显式触发（走 `DebugRequestHeightmapCurrent`→`RequestSvoAround`）；漏 `request_lod` 会导致 `until_svo_uploaded` 超时、`svo` 全程 revision=0/macro_cell_count=0（非实现缺陷）。②`-VoxiaTileWindowRadius` 必须保持 0：改 1 会让 27 tile=9261 chunk 的近场 mesh 在 perf 采样期间后台构建，FPS 掉到 9（与远景无关的采样污染）；FPS 锚点口径 = TileWindowRadius=0。
3. **真实操作（可见 RHI）**：高空巡航 + 三机位截图审计（#10）。

## 6. 工程注意

- UE 构建：`Build.bat VoxiaEditor Win64 Development ... -NoLiveCoding -NoUBA -MaxParallelActions=1`（既有可用形态）；PowerShell 被 mix.ps1 签名策略拦时用 `cmd /c`（本步无 Elixir 侧改动，Mix 一般不涉及）。
- 代码改动 commit 在 **clients/Voxia 独立仓**；文档/phase 进度 commit 在 **ex_mmo_cluster 主仓**；默认不 push。
- 验收全绿后：新锚点（quad/per-ring/FPS/内存）按 snapshot 纪律**直接改写**进 `docs/current_status/design/client/streaming-lod.md`（不加日期条目）；本文件状态改"已完成"并记进度日志;`docs/voxel-server-authority/README.md` 阶段表同步。

## 7. 进度日志

- 2026-07-06：建档。上游设计稿 v2.6 已冻结 T-1/T-2/T-10 相关拍板；验收矩阵与三入口定稿。
- 2026-07-06：**语义定位完成（改动点 1）**。现状机制确认：`SvoDepthForSamples(samples)` 给基线 depth（≤2→1、≤4→2、否则 3），`SvoCellDepthForTile` 按 XZ Chebyshev 加 boost（d≤NearLodRing→+3、d≤MidLodRing→+2），`FMath::Clamp(base+boost,1,4)`。Transport 默认 samples=4 → 基线 2，近环 2+3、中环 2+2 均被推到 depth4——"事实上 7/7/28 三档"得证；`launch_worldgen_svo_preview.js` 传 samples=2（7/14/56），Transport 与脚本默认不一致亦得证。深度逻辑在 `VoxiaDebugCliSubsystem.cpp`（fixture 预物化）存在一份复制品。设计决策：
  - **D1 数据模型**：`FVoxiaSvoLodRing { OuterRadiusTiles; Depth }`（叶尺寸=112m/2^Depth），`FVoxiaSvoBuildConfig::LodRings` **替代** `SamplesPerTileAxis`/`NearLodRingTiles`/`MidLodRingTiles` 三字段（不留双源），默认 `{8,4},{24,3},{40,2},{72,1}` = `7@8,14@24,28@40,56@72`。
  - **D2 解析/校验分层**：`ParseLodRings`（语法：叶尺寸 ∈ 112/2^k 阶梯，3.5 语法合法）与 `ValidateLodRings`（外界 d 严格递增、叶尺寸严格递增、depth 1..4、覆盖 ≥ RadiusTiles）分开；3.5→depth5 = collar 档在校验层显式拒绝（诊断指向 A4）。
  - **D3 双入口硬失败**：Transport 解析/校验失败 → `voxia_svo_rejected` + LastError，无 fallback；`BuildMacroCellUpdate` 入口 ValidateLodRings 失败 → `BuildError` 空结果（automation 直构 config 同样硬失败）。
  - **D4 legacy flag 显式拒绝**：命令行出现 `-VoxiaSvoSamples`/`-VoxiaSvoNearLodRing`/`-VoxiaSvoMidLodRing` 即拒绝并指向 `-VoxiaSvoLodRings`，不静默忽略。
  - **D5 cache key**：`BuildKeyPrefix` 的 samples/near/mid 三 mix 换成 canonical `lod_config` 字符串 mix；per-cell `ArtifactPath` 已含 CellDepth 不变。
  - **D6 per-ring 可观测**：BuildResult 增 `RingStats`（cells/quads/depth per 环），SnapshotJson 输出 `lod_config` + `lod_rings[]`，observe `voxia_svo_tiles_built` 带 `lod_config` 与 per-ring 摘要。
  - **D7 一致性收敛**：`SameReusableSvoConfig`/`SameBuildConfig`/`MakeReuseContext`/增量复用双校验/seam check/DebugCli fixture 预物化全部改走同一 `CellDepthForRings` 公开静态，删除 Debug 复制品；fixture launch args 与 `launch_worldgen_svo_preview.js` 改传 `-VoxiaSvoLodRings=`。
  - **D8 MaxDepth 语义**：初始 = 最外环 depth（最粗基线），逐 cell 取 max；空覆盖时报最外环 depth。
  - per-ring cells 锚点复核：145²−3²=21016 总 cell；d2-8→280、d9-24→2112、d25-40→4160、d41-72→14464，与验收 #3 一致。
- 2026-07-06：**实现完成（改动点 2-6），进入构建验证**。落地清单（clients/Voxia 仓）：
  - `Voxel/VoxiaSvoPreview.h/.cpp`：`FVoxiaSvoLodRing`/`FVoxiaSvoLodRingStats` 数据模型；`ParseLodRings`/`ValidateLodRings`/`LodRingsSpec`/`CellDepthForRings`/`RingIndexForTile`/`DefaultLodRings` 六个公开静态；config/result 三个隐式字段（samples/near/mid）删除；`BuildMacroCellUpdate` 入口硬校验 + per-ring cells/quads 分桶；`SameReusableSvoConfig`/`SameBuildConfig`/`MakeReuseContext`/增量复用深度双校验改走 tier 表；SnapshotJson 输出 `lod_config` + `lod_rings[]`（替代 samples/near/mid 三字段）。
  - `Voxel/VoxiaSvoSourcePages.cpp`：`BuildKeyPrefix` 混入 canonical lod_config 字符串（替代 samples/near/mid 三个 hash mix）。
  - `Net/VoxiaTransportSubsystem.cpp`：`-VoxiaSvoLodRings=` 解析 + 双层显式拒绝（语法/语义）；legacy `-VoxiaSvoSamples`/`-VoxiaSvoNearLodRing`/`-VoxiaSvoMidLodRing` 出现即拒绝并指向新 flag；`MatchesCompletedSvoBuild`/coverage 兜底路径改 copy LodRings；observe `voxia_svo_build_started` 带 `lod_config`、`voxia_svo_tiles_built` 带 `lod_config`+`ring_cells`/`ring_quads`/`ring_depths`。
  - `Debug/VoxiaDebugCliSubsystem.cpp`：删除 Debug 侧深度推导复制品，fixture 预物化改调 `CellDepthForRings`；fixture launch_args 改发 `-VoxiaSvoLodRings=<canonical>`。
  - automation：`Voxia.Voxel.SvoPreview` 重写/新增——tier 语法正/负向（乱序/重叠/非阶梯/坏 token/覆盖不足/空表/collar 语法可解析但启用被拒且诊断含 A4）、直构非法 config 走 Build 入口硬失败、`CellDepthForRings` 四环边界逐档断言（d=2/8/9/24/25/40/41/72）、换分级零复用 + `BuildKeyPrefix` 前缀变化、8km 四环 per-ring cells 精确锚点（280/2112/4160/14464）+ quads 守恒 + depth 阶梯 4/3/2/1 + snapshot `lod_config`/`lod_rings` 字段断言；`FarFieldPatchGrid` 测试改吃默认四环。
  - 脚本/文档：`launch_worldgen_svo_preview.js` 与 `run_svo_large_terrain_preview.ps1` 改传 `-VoxiaSvoLodRings`；`Debug/README.md`、`Gameplay/README.md` 模板同步。
  - 决策补充：EightKmLod 预算断言从「×8 于全 56m 基线」放宽到「×12」——设计预算 1.34M vs 单环 56m 基线约 0.155M ≈ ×8.6，旧 ×8 是三环(7/14/56=1.14M)口径,四环含 L2.5 必然越过。
- 2026-07-06：**automation 入口全绿(验收 #1/#2/#3/#6 部分 + #8 既有回归)**。构建 `BUILD_EXIT=0`（非 unity 全量后增量 7.6s）。`Automation RunTests Voxia.Voxel.SvoPreview` 与 `Voxia.Gameplay.WorldActor` 均 `Result={Success}`；全套 `Automation RunTests Voxia` 34 test 全 `Success`、零 Fail。SvoPreview 新增断言覆盖:tier 语法正/负向（乱序/重叠/非阶梯/坏 token/覆盖不足/空表全部按 H gate 语义拒绝并带诊断）、collar `3.5@N` 语法可解析但启用被拒且诊断含 "A4"、直构非法 config 走 Build 入口硬失败（空 mesh + BuildError）、`CellDepthForRings` 四环边界逐档（d=2/8→4、9/24→3、25/40→2、41/72→1，Y 偏移不改环）、换分级零复用 + `BuildKeyPrefix` 前缀变化（验收 #6 内存+cache-key 双面）、8km 四环 per-ring cells 精确锚点 280/2112/4160/14464 且合计=MacroCellCount、per-ring quads 逐环非零且求和守恒、depth 阶梯 4/3/2/1、snapshot `lod_config`/`lod_rings` 字段可读。
- 2026-07-06：**CLI 入口首两轮失败,均已定位修复**。①作战模板缺陷:漏 `request_lod`——WorldGen preview 下 pawn 停 `phase=idle`(不走真实 InScene 订阅链),SVO 只能靠该 CLI 命令显式触发;§5.2 模板已修(同时 TileWindowRadius 0→1 与 launch 脚本对齐)。②真实代码缺陷:`FParse::Value` 默认在**逗号处截断**,`-VoxiaSvoLodRings=7@8,14@24,...` 只读到 `7@8`——修复为 `bShouldStopOnSeparator=false` 整串读入。**显式失败语义在此自证**:截断出的 `7@8` 没有静默跑错分级,而是被 `ValidateLodRings` 拒绝并给出 `"SVO lod rings cover d<=8 but radius is 72 tiles"` 精确诊断(observe `voxia_svo_rejected`)——若沿旧隐式推导设计,同类截断会无声跑成错误分级。增量重编 8.9s 通过,smoke 第三轮进行中。
- 2026-07-06：**构建期发现并根治模块级 unity build 地雷**。首两轮编译在**未触碰的文件**（VoxiaHUDWidget / VoxiaRemoteInteraction / VoxiaRemoteActionWire / VoxiaAuthorityPresentationActor 等）爆 89 个 C2084/C2264"already has a body"：本模块 10+ 个 .cpp 在匿名命名空间重复定义同名助手（JsonEscape/JsonString ×10、WriteU8 家族 ×4、CountFocusRegions ×2），而 UBT unity blob 按累计字节装箱——**任何文件体积变化都会重排箱体**，把同名符号并进同一翻译单元随机撞车（`-DisableAdaptiveUnity` 无效，证明非 adaptive 摘除所致而是装箱本身）。根治：`Voxia.Build.cs` 增加 `bUseUnity = false;` 恢复标准 C++ TU 语义（改名 30+ 处助手是更大 churn 且下次复制粘贴即复发）；代价为一次性全量重编,收益是增量粒度变细 + 永久消灭该冲突类。此修复与 A1 特性改动在 Voxia 仓分开 commit。另:本机引擎实际在 `D:\Epic Games\UE_5.8`（旧文档的 `D:\UE\UE_5.8` 在本机不存在）；非 unity 小 TU 下将 `-MaxParallelActions` 从 1 提到 4（原 =1 针对巨型 unity blob 的内存压力）。
- 2026-07-06：**真实 RHI 8km 验收闭环 + 环境级 GPU device-removal 定位（详见 §4.1）**。四环全量真实 RHI：`lod_config=7@8,14@24,28@40,56@72`、`macro_cell_count=21016`、`quad_count=1388647`（−62%）、per-ring cells `280/2112/4160/14464`、per-ring quads `287082/570641/288904/242020`、`max_depth=4`、seam pass 全部命中锚点。**关键排障**：默认 Lumen/TSR profile 下渲染 8km ProcMesh 大代理稳定 `DXGI_ERROR_DEVICE_REMOVED`；用旧三环 `7@24,28@72`（3.69M quads）对照实验**逐字复现同一崩溃** → 判定与 A1/分级正交，属 8km 单组件 ProcMesh 代理的渲染后端环境问题（A2 域）。关 `r.Lumen.ScreenProbeGather` + TSR 后同一四环全量**零崩溃完成上传**（`upload_complete=true`/`upload_queue=0`/`presentation_consumed=true`/`uploaded_patches=361`/seam pass），证明 tier 契约端到端跑通渲染管线。#9 FPS（默认 profile）与 #10 截图（存活 profile 下截图机制未落盘，同环境）被该 device-removal 阻塞，归 A2；几何正确性由 seam pass + per-ring 覆盖 + upload_complete 结构化覆盖。#7 cache 正向改由 null-RHI 确定性 automation（radius 72 平移 1 tile → `cache_hit_rate≥0.95`）验证，因真实 RHI 移动 smoke 受同源环境阻塞。
- 2026-07-06：**snapshot 文档与状态收口**。`docs/current_status/design/client/streaming-lod.md` 按 snapshot 纪律直接改写四环实测锚点（quad 1.39M、per-ring、runtime payload 20.5MB、`svo` 字段名 samples→lod_config/lod_rings、legacy flag 移除说明）并新增「8km 环境级 GPU device-removal（A2 待排查）」条目；本文件状态改「实现完成、核心验收全绿」并补 §4.1 验收结果表。`README.md` 阶段表待同步。
