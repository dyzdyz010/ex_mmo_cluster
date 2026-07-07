# Phase VLOD-A3：远景 per-cell greedy merge（减 overdraw 几何量）

> 状态：未开始（决策稿）。
> 上游：[`2026-07-06-voxia-lod-layering-and-technology-design.md`](./2026-07-06-voxia-lod-layering-and-technology-design.md)（v2.6）§3.2c（T-5：per-cell masked greedy merge，作用域限 cell 内）、§4 预算表（I-4 按带系数）、§9 里程碑 A 步 A3。
> 前置：[`phase-vlod-a2-partitioned-staticdraw.md`](./phase-vlod-a2-partitioned-staticdraw.md)（**范围内完成**，分组件池 + StaticDraw + 组件剔除 + Unlit + bulk-hide，渲染基座就绪）。**A2 的 8 次真实 RHI 实测 airtight 归因是本步的直接依据**：8km device-removal 是 GPU TDR（崩溃现场显存 38%、非 OOM），真凶=远景几何量在可见 frustum 内的 overdraw；A2 用尽全部「怎么渲染」杠杆仍不能让默认全 Lumen 8km facing 存活——减 overdraw 只有减几何量能做，即本步。
> 硬件口径：实测 GPU 为 **RTX 4060 Laptop 8GB**；device-removal 均为 GPU TDR。

## 0. 一句话

给远景 SVO leaf-surface mesh 生成加 **per-cell masked greedy merge**（作用域限 cell 内、不跨 cell/不跨 depth），把 8km 远景 quad 从 **1.39M 降到 0.51-0.84M**（按带系数、视觉等价、tier/cell 契约逐字不变），**减半量级的 overdraw**——**但先诊断（A3.0）实测「Lumen-on facing 存活 + 达标所需的 quad/overdraw 阈值」，再拿 merge 产出去比，据数据判 merge 是否够；不够则诚实按升级序列（A5 瘦身 → 远景雾/距离裁切 → Lumen 配置决策）补，不空口承诺 merge 单独根治 device-removal。**

## 1. 目标

1. **减几何量（核心，确定性可验）**：per-cell greedy merge 把 exposed-face quad 按带合并——L1(7m)÷2-4、L2(14m)÷2-3、L2.5(28m)÷1.2-2、L3(56m)÷1.2-2，`quad_count` 从 A1 实测 1388647 降到 **0.51-0.84M**（§4 预算表区间）。
2. **视觉等价（铁律）**：合并后渲染表面与合并前**逐像素等价**——无新洞、无双面、覆盖不变、`seam_check.status=pass` 不回归。A3 改 quad 数，但**不改可见几何形态**（同一表面、更少 quad）。
3. **兑现 A2 留下的渲染目标（条件性，A3.0 数据驱动）**：默认 Lumen profile（不降载）8km facing/overview 稳态巡航**零 device-removal** + FPS 达标——**当且仅当 A3.0 证明 merge 后 quad < 存活阈值**；若 A3.0 证 merge 不够，本项按升级序列（§4 D3）重挂并诚实记录，A3 仍以几何目标（目标 1/2）判完成。
4. **为 A4/垂直腾预算（承重墙）**：merge 后 3.5m collar（A4，净增 +56-112k）与垂直多层（B5，×1.3-2.5）的预算才可负担。

## 2. 范围边界（显式非目标）

- **不碰 tier/cell 契约**：cells `280/2112/4160/14464`、depth `4/3/2/1`、`lod_config=7@8,14@24,28@40,56@72`、`max_depth=4`、`macro_cell_count=21016` **逐字不变**——A3 只降每 cell 的 quad 数，不动 cell 集合/深度/分带（A1 冻结）。
- **merge 作用域限 cell 内**：不跨 cell、不跨 depth 合并。跨 depth 覆盖性 seam 断言归 A4；本步只在单个 leaf cell 内对 exposed face 做 masked greedy。
- 不做顶点格式瘦身 / cache LRU（A5）；不做 collar 启用 / 换环 fade（A4）；不动分组件渲染后端（A2 已完成，merge 后的 mesh 仍走 PartitionedDynamicMesh + StaticDraw + 剔除 + Unlit + bulk-hide）；不碰垂直组织（B5）。
- **不改全局 Lumen 配置**——除非 A3.0 数据明确指向"merge+A5 仍不足、必须动 Lumen"，且作为**显式决策项**由用户拍板（非 A3 默认动作）。
- 一次一个变量：本步唯一变量是"每 cell 的 exposed face 如何合并成更少 quad"；quad 数变化必须可归因于 merge 本身，可见几何形态零变化。

## 3. 改动点（先定位再改）

### 3.0 诊断先行（步 A3.0，动手 merge 前必做）—— 把"预期效果"锚到硬数据

A2 只证了"1.39M facing 崩"，**没测过"降到多少 quad 才能过 TDR"**。A3.0 用与 A2.0 同法（真实 RHI + `-gpucrashdebugging` + Monitor 宽崩溃签名）坐实**存活/达标阈值**：

1. **quad/overdraw 阈值扫描**：默认 Lumen profile 下，用半径梯度（如 r24/r36/r48/r60/r72）或 near-skip 梯度改变**可见远景 quad 数**，逐档实测"facing 机位稳态是否 device-remove + FPS"，找出 **`Q_survive`（facing 存活的最大可见 quad 数）** 与 **`Q_target_fps`（达 FPS 门槛的可见 quad 数）**。（存活配置优先跑；每崩一次留可杀 device-removal，注意 GPU 清理。）
2. **overdraw 直读（尽力）**：`exec "ProfileGPU"`/`stat RHI` 在存活档取 base-pass ms 与显存，佐证 overdraw 随 quad 线性/超线性关系。
3. **判定**：把 merge 产出 **0.51-0.84M**（及按带分布）与 `Q_survive`/`Q_target_fps` 比——
   - merge 后 quad < `Q_survive` 且 < `Q_target_fps` → **merge 足够**，目标 3 由 A3 单独兑现；
   - merge 后 quad 仍 > 阈值 → **merge 不足**，量化"还差几倍"，按升级序列（§4 D3）决定叠加 A5（顶点瘦身，正交降显存/带宽但不降 overdraw 像素数）/ 远景雾/距离裁切（降可见 quad）/ Lumen 配置（降 pass 成本），并**如实把目标 3 重挂到组合方案**。
   - A3.0 结论写进进度日志，驱动后续动多大——**不预设 merge 一定够**。

### 3.1 per-cell masked greedy merge（承重墙）

- **定位**：远景 SVO leaf-surface mesh 生成在 `clients/Voxia/Source/Voxia/Voxel/VoxiaSvoPreview.cpp`（`BuildMacroCellUpdate` 家族，现状逐 leaf 面 EmitQuad 无合并，产 `top_quad_count/side_quad_count/boundary_side_quad_count`）。近景已有 `FVoxiaGreedyMesher`（`clients/Voxia/Source/Voxia/Voxel/VoxiaGreedyMesher.{h,cpp}`，per-chunk mask+merge）可**复用或参照**（注意近景 1m 均匀网格 vs 远景 SVO 变深度 leaf 的语义差异）。以执行时实际定位为准。
- **算法**：对每个 leaf cell 的 exposed face 集合，按**轴向平面 + 同材质 + 同朝向**分组，在 cell 内做 masked greedy meshing（贪心把共面相邻同材质 face 合并成大 quad）。作用域**严格限 cell 内**——不越 cell 边界（保 tier/cell 契约、把跨 depth 覆盖性留 A4）。
- **收益按带（I-4，预期非承诺）**：细环（7m）同深度平面多 → ÷2-4；粗环（28/56m）octree 同质坍缩已吃大平面（depth1 cell 仅 8 叶）→ ÷1.2-2。侧/底面占比高（顶面仅 ~1/k≈25%），崖壁/岛侧壁大平面收益最好。

### 3.2 可观测

- `svo` snapshot / observe 增：per-ring **merged** quads、per-ring **merge 系数实测值**（merge 前/后比）、总 quad 前后对比、`merge_enabled`。
- 逃生门 `-VoxiaSvoFarNoMerge`（关 merge 走旧逐面路径，供 A/B 对照 quad/FPS/视觉）。

### 3.3 视觉等价断言

- `seam_check.status=pass` 不回归（现状全量扫查缝隙/重复面）。
- **无新洞 / 无双面**：merge 前后同一 cell 的 exposed-face **覆盖面积守恒**断言（合并只减 quad 数、不减覆盖）。
- 可选 A/B 像素对比：同机位 merge vs `-VoxiaSvoFarNoMerge` 截图 `audit_png` 无可见差（真实 RHI）。

### 3.4 automation

- `Voxia.Voxel.SvoPreview` 扩：按带 merge 系数落区间断言、覆盖面积守恒、tier/cell 契约不变（cells/depth/lod_config 逐字）、merge 前后 quad 单调下降且落预算。

预计涉及：`clients/Voxia/Source/Voxia/Voxel/VoxiaSvoPreview.{h,cpp}`、`VoxiaGreedyMesher.{h,cpp}`（复用/扩展）、对应 AutomationTest。以执行时实际定位为准。

## 4. 决策项（待拍板，附推荐）

| # | 决策 | 选项 | 推荐 |
| --- | --- | --- | --- |
| D1 | merge 实现 | (a) 复用/扩展 `FVoxiaGreedyMesher`；(b) 远景 SVO 专用新 merge | **(a) 优先复用**，抽出 cell 内 masked greedy 核心，适配 SVO 变深度 leaf；语义差异大到无法复用再 (b) |
| D2 | 视觉等价验证 | (a) 覆盖面积守恒断言（automation）；(b) A/B 像素对比（真实 RHI）；(c) 二者都上 | **(c)**：automation 守恒断言做硬门槛，真实 RHI A/B 像素做人工兜底 |
| D3 | A3.0 若证 merge 不足 | (a) 只交付几何目标、目标 3 重挂 A5+雾+Lumen 组合；(b) 本步内即叠 A5/雾 | **(a)**：A3 边界=merge；不足则量化差距、把 device-removal 根治重挂显式组合方案（A5/雾/Lumen 各自独立决策），A3 以几何目标判完成——**不假装 merge 单独修好** |
| D4 | merge 系数验收带宽 | (a) 按 §4 表（细环÷2-4/粗环÷1.2-2）；(b) 实测收窄 | **(a) 起步**：按设计区间验收；实测显著偏离（如粗环 <÷1.2）则查算法或如实修订预算 |
| D5 | 阈值扫描口径 | (a) 半径梯度改可见 quad；(b) near-skip 梯度；(c) 直接 merge 后 vs merge 前对照 | **(a)+(c)**：半径梯度找 `Q_survive` 曲线，merge 前后同 r72 直接对照落点 |

## 5. 验收矩阵（严格——分"几何层确定性"与"渲染层条件性"两级）

### 5.A 几何层（确定性，A3 必达）

| # | 维度 | 断言 | 锚点 |
| --- | --- | --- | --- |
| 1 | quad 总量回归 | merge 后 8km 全量 `quad_count` 落设计预算 | **1388647 → 0.51-0.84M**（§4 表；A1 实测基线换算约 0.53-0.87M） |
| 2 | 按带系数 | per-ring merged quads 落按带区间 | L1 `287082→72-144k`(÷2-4)、L2 `570641→190-285k`(÷2-3)、L2.5 `288904→144-241k`(÷1.2-2)、L3 `242020→121-202k`(÷1.2-2) |
| 3 | tier/cell 契约不变（铁律） | cells/depth/lod_config/max_depth/macro_cell_count 逐字不变 | `280/2112/4160/14464`、`4/3/2/1`、`7@8,14@24,28@40,56@72`、`4`、`21016` 全不变 |
| 4 | 视觉等价 | 无新洞/无双面/覆盖守恒；seam 不回归 | 覆盖面积守恒断言 pass；`seam_check.status=pass`；A/B 像素 merge vs no-merge 无可见差 |
| 5 | 不回归 | automation 全绿 + Build 0；A2 分组件/StaticDraw/剔除/Unlit/bulk-hide 不回归；near mesh 不回归 | `Automation RunTests Voxia` 全 Success |

### 5.B 渲染层（条件性，A3.0 数据驱动，兑现 A2 留下的 #1/#2）

| # | 维度 | 断言 | 门槛条件 |
| --- | --- | --- | --- |
| 6 | device-removal 消除 | 默认 Lumen profile（不降载、1080p、TileWindowRadius=0）8km facing/overview 稳态 ≥60s 巡航零 `DXGI_ERROR_DEVICE_REMOVED` | **仅当 A3.0 证 merge 后可见 quad < `Q_survive`**；否则按 D3 重挂 A5+雾+Lumen 组合并诚实记录 |
| 7 | FPS 达标 | `render_perf` 达门槛 | 门槛由 A3.0 结合 4060 Laptop 现实标定（A1 旧记 avg 69/min 42.8 需按 A3.0 数据复核是否现实） |

**严格性说明**：几何层（5.A）是 A3 的**确定性契约**——merge 系数、契约不变、视觉等价都是可 automation 硬断言的、必达。渲染层（5.B）是 A3 的**真目标但受物理约束**——是否由 A3 单独兑现，**由 A3.0 诊断的硬阈值数据裁决**，不预设、不假装；若 merge 不足，量化差距 + 升级序列 + 如实重挂，绝不用"应该够了"糊过去。

## 6. 三入口

1. **automation（null RHI）**：`Voxia.Voxel.SvoPreview` 扩——按带 merge 系数区间、覆盖面积守恒、tier/cell 契约逐字不变、merge 前后 quad 单调下降落预算；`VoxiaGreedyMesher` 单测。
2. **CLI（真实 RHI offscreen）**：①A3.0 阈值扫描（半径梯度 × 默认 Lumen，找 `Q_survive`/`Q_target_fps`，Monitor 宽崩溃签名 `GPU timeout`+`DXGI_ERROR_DEVICE_REMOVED`）；②merge 后 8km 默认 profile facing 稳态 smoke（验 5.B，若阈值达）；③merge vs `-VoxiaSvoFarNoMerge` 同机位 quad/FPS/像素 A/B。
3. **真实操作（可见 RHI）**：高空 overview + facing 巡航肉眼验无洞/无双显/无 merge 伪影；补 A1/A2 欠的三机位入带角尺寸截图（渲染稳定后）。

## 7. 工程注意

- **merge 作用域限 cell 内**——越 cell 合并会破 tier/cell 契约且侵入 A4 覆盖性 seam 域；严守 cell 边界。
- **复用 `FVoxiaGreedyMesher` 注意近/远语义差**：近景 1m 均匀网格；远景是 SVO 变深度 leaf（同一 cell 内可能多深度叶）——mask 构造与坐标口径需适配，勿照搬。
- **merge 改 quad、A2 渲染管线承接不变**：合并后的 mesh 仍走 PartitionedDynamicMesh 分组件 + StaticDraw + 剔除 + Unlit + bulk-hide；quad 降→组件 mesh 更小→显存/带宽/base-pass 均降。
- **A3.0 崩溃跑纪律（承 A2 教训）**：GPU-hang（5s payload timeout）留不可杀僵尸须重启；device-removal（DXGI）UE 自身干净退出可杀；存活配置优先、崩溃配置最后、Monitor 同时匹配两类签名。
- **commit 拆分**：代码 commit 在 `clients/Voxia` 独立仓；文档/进度 commit 在 `ex_mmo_cluster` 主仓；默认不 push。
- 本机引擎 `D:\Epic Games\UE_5.8`；`Voxia.Build.cs` 保持 `bUseUnity=false`。

## 8. 进度日志

- 2026-07-07：建档。承 A2 的 airtight 归因（device-removal=远景几何量 overdraw 超 TDR、非 OOM）。A3 边界=per-cell greedy merge（限 cell 内、视觉等价、tier 契约不变），几何目标 1.39M→0.51-0.84M 按设计 §4 I-4 系数确定性可验；渲染目标（兑现 A2 留下的 #1/#2）由步 A3.0 诊断的硬阈值数据裁决 merge 是否足够，不足则量化差距 + 升级序列（A5/雾/Lumen 各独立决策）+ 如实重挂，不预设 merge 单独根治。决策项 D1-D5 待拍板。
