# Phase VLOD-A1：切默认分级 + 显式 tier 契约 + L2.5 第三环

> 状态：未开始
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

## 5. 三入口

1. **automation（null RHI）**：`Automation RunTests Voxia.Voxel.SvoPreview`（含新断言）+ `Voxia.Gameplay.WorldActor`。
2. **CLI（真实 RHI offscreen）**：8km smoke，在既有命令模板上加 tier 参数：
   `node .\clients\Voxia\scripts\voxia_stdio_cli.js --real-rhi --map "/Game/Voxia/Maps/L_WorldGenSvoPreview?game=/Script/Voxia.VoxiaClientGameMode" --ue-arg "-VoxiaWorldGenPreview" --ue-arg "-VoxiaSvoPreview" --ue-arg "-VoxiaTileWindowRadius=0" --ue-arg "-VoxiaSvoTileRadius=72" --ue-arg "-VoxiaSvoNearSkipRadius=1" --ue-arg "-VoxiaSvoLodRings=7@8,14@24,28@40,56@72" --ue-arg "-VoxiaSvoUploadMaxPatchesPerFrame=128" --ue-arg "-VoxiaSvoUploadBudgetMs=12" --cmd "until_baseline_ready 120000; until_tile_window_full 180000; until_svo_uploaded 240000 1000; svo; sample_render_perf 10000 1000 30 5; quit"`
   断言 #3-#9；另跑跨 1 tile 移动复跑验 #7。
3. **真实操作（可见 RHI）**：高空巡航 + 三机位截图审计（#10）。

## 6. 工程注意

- UE 构建：`Build.bat VoxiaEditor Win64 Development ... -NoLiveCoding -NoUBA -MaxParallelActions=1`（既有可用形态）；PowerShell 被 mix.ps1 签名策略拦时用 `cmd /c`（本步无 Elixir 侧改动，Mix 一般不涉及）。
- 代码改动 commit 在 **clients/Voxia 独立仓**；文档/phase 进度 commit 在 **ex_mmo_cluster 主仓**；默认不 push。
- 验收全绿后：新锚点（quad/per-ring/FPS/内存）按 snapshot 纪律**直接改写**进 `docs/current_status/design/client/streaming-lod.md`（不加日期条目）；本文件状态改"已完成"并记进度日志;`docs/voxel-server-authority/README.md` 阶段表同步。

## 7. 进度日志

- 2026-07-06：建档。上游设计稿 v2.6 已冻结 T-1/T-2/T-10 相关拍板；验收矩阵与三入口定稿。
