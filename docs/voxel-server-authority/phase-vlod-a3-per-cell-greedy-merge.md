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

- 2026-07-07（**步 A3.0 诊断先行·第一批：harness 验证 + quad 阶梯（solid）+ 真实 RHI facing 扫描撞上 GPU 状态混杂（suspect，未决）**）。证据存 `clients/Voxia/Saved/a3-diag/`。
  - **【SOLID·GPU 无关·nullrhi 实测】harness 全通 + quad 阶梯**：CLI/命令面核实（`teleport/look_at/look/move/exec` UE 侧，`sample_render_perf d i minfps minsamples`）；A2 base（clients/Voxia@6df0a0c）已编译就绪无需重构；nullrhi r72 逐字复现契约（`quad_count=1388647`、`macro_cell_count=21016`、`max_depth=4`、per-ring `280/2112/4160/14464` 与 `287082/570641/288904/242020`、`seam_check.status=pass`）。**半径→quad 阶梯（减半径不触发覆盖硬失败）**：r8=287082、r12=376043、r16=491837、r20=655692、r24=857723、r36=1063459、r48=1196238、r60=1283435、r72=1388647。**关键推论**：L1(287082)+L2(570641)=**857k 在 r≥24 已全满**，半径只调 L2.5/L3；**merge 目标 [0.51M,0.84M] 恰映射到半径 [16,24]**（r16≈merge 下界、r24≈merge 上界）→ A3.0 崩溃扫描可用 r16/r24 直接回答「merge 后 quad 在 facing 下崩不崩」。
  - **【SUSPECT·真实 RHI·GPU 状态存疑】r8 facing 扫描全崩、与 A2 记录冲突**：default-Lumen r8（287082 quad、`far_visible_component_count=1`）在**远景 mesh 变 live 那刻**（near-only frames 0~200 全程存活）`DXGI_ERROR_DEVICE_REMOVED`、显存 15%（`Local Used 1062/Budget 7189MB`、非 OOM）、`payload_timeout=0`（纯 removal 非 hang）、`TerminateOnGPUCrash` 干净退出 code=3。连测 5 档**全崩**且崩法同型：Lumen-ON、Lumen-OFF(`-dpcvars` 已核实生效：`DeviceProfile CVar r.DynamicGlobalIlluminationMethod:0`+`ScreenProbeGather:0`)、Lumen-OFF+`r.GenerateMeshDistanceFields=0`、ProcMesh 后端 Lumen-OFF、Partitioned 默认。
  - **冲突点（必须澄清才能续）**：A2 §5.1/§8 记 ProcMesh Lumen-off r72(**1.39M**)存活 12 FPS、Partitioned Lumen-off r72 存活 26 FPS；而此处 287k(1/5 量)即崩。**287k 崩、1.39M 却活方向相反，单纯 overdraw/quad 数解释不通**，且 far_visible=1（仅 1 组件在视锥）几乎排除 overdraw 物理极限。
  - **最可能根因 = GPU/驱动 TDR 阈值被污染（非干净基线）**：A2 本身以大量 GPU 崩溃/hang 收尾；若 A2 与本 session 间**未重启**，则 preflight 的「1581MiB idle」非真干净（驱动层 TDR 退化 nvidia-smi 看不出）。佐证首崩即带 `Aftermath: Timed out ... No breadcrumb`（硬 GPU 挂到无法 dump）。反证（不完全）：崩溃帧 108/162/217 无单调提前，非典型退化曲线，**故「r8 真的会崩（far-mesh-go-live 路径级 GPU 崩溃，与 quad/Lumen 无关）」这一可能不能排除**——若成立则 A2「overdraw airtight」归因（A3 全部预设的地基）需重审。
  - **未决 + 重启后判决序列**（清干净 GPU 后按序，存活优先）：① 首跑 **A2 已证存活档**（ProcMesh Lumen-off r72 spawn，或 Partitioned Lumen-off r72 spawn）——存活⇒证 GPU 已恢复、之前是污染，从干净态重跑 r8/r16/r24… Lumen-ON facing 半径扫描定 Q_survive；仍崩⇒非污染，是真实回归/环境变化，升级为 **far-mesh-go-live 渲染路径调查**（DRED/Aftermath breadcrumb 定位崩溃 GPU pass），并据此重审 A2 overdraw 归因，A3 merge 计划相应调整。② 无论哪支，A3.0 判定（Q_survive vs 0.51-0.84M）都须建立在干净 GPU 数据上，不采信本批 suspect 数据。
  - **纪律留痕**：本批未写任何 merge 代码（严守「A3.0 诊断先行」）；契约冻结项（tier/cell）经 nullrhi 逐字复核未动；quad 阶梯是 GPU 无关的可复用产出。

- 2026-07-07（**A3.0 混杂坐实为 GPU 退化，本批真实 RHI 崩溃数据全部作废；待完整重启重做**）：
  - 用户确认 **A2 崩溃收尾（昨晚 ~00:16、多次 GPU 崩溃/hang）后到本 session 之间未重启** → preflight 的「1581MiB idle」非干净基线，驱动层 TDR 退化 nvidia-smi 不可见。
  - 用户先做**驱动重置**（非完整重启）：重置后 Partitioned r8 Lumen-off **仍崩**（clean removal, exit 3）→ 驱动重置不足以清 TDR 退化。
  - **决定性判别**：跑 **A2 明证存活档 = Partitioned r72 Lumen-off spawn**（A2 §5.1/§8 记 26 FPS 存活，同一 6df0a0c 二进制、~1 小时前）——**现在也崩**（exit 3、`far_component_count=361` 满几何已建、无 perf）。**一个确定存活过的配置现在崩 = GPU 退化铁证**。
  - **裁决**：本 session 全部真实 RHI 崩溃观测（r8 连崩 6 次、跨 ProcMesh/Partitioned、Lumen 开关、DF 开关）**均为退化 GPU 假象，不采信**；不据此对 overdraw/merge/far-mesh-go-live 下任何结论。A2 的 airtight overdraw 归因**未被本批推翻也未被证实**，悬置待干净数据。
  - **完整重启后接力序列（严格按序，存活优先）**：
    1. 干净启动后先 `nvidia-smi` 确认 idle；
    2. **首跑 A2 存活基线**：`Partitioned r72 Lumen-off spawn`（模板见下），**必须存活**（≈26 FPS）才算 GPU 恢复、harness 可信；若仍崩=真实回归，转 far-mesh-go-live 渲染路径调查（`-gpucrashdebugging` 取 DRED/Aftermath breadcrumb 定位崩溃 pass）；
    3. GPU 恢复后做 **Lumen-ON facing 半径扫描定 Q_survive**：r8→r16→r24→r36→r48→r60→r72（存活优先、小→大），每档记 quad(见阶梯)/存活/FPS/崩法；用 nullrhi 阶梯把崩溃边界半径换算成 quad；
    4. 判定 Q_survive vs merge 目标 [0.51M(≈r16),0.84M(≈r24)]：r24 存活⇒merge 上界够；r16 崩⇒连 merge 最好情形都不够，按 D3 重挂；
    5. overdraw 直读：存活档 `exec ProfileGPU`/`stat RHI`。
  - **可复用模板（干净 GPU 首跑基线，Lumen-off r72）**：`node clients/Voxia/scripts/voxia_stdio_cli.js --real-rhi --map "/Game/Voxia/Maps/L_WorldGenSvoPreview?game=/Script/Voxia.VoxiaClientGameMode" --ue-arg "-VoxiaWorldGenPreview" --ue-arg "-VoxiaSvoPreview" --ue-arg "-VoxiaTileWindowRadius=0" --ue-arg "-VoxiaSvoTileRadius=72" --ue-arg "-VoxiaSvoNearSkipRadius=1" --ue-arg "-VoxiaSvoLodRings=7@8,14@24,28@40,56@72" --ue-arg "-dpcvars=r.Lumen.ScreenProbeGather=0,r.DynamicGlobalIlluminationMethod=0,r.AntiAliasingMethod=1" --cmd "until_baseline_ready 120000; until_tile_window_full 180000; request_lod; until_svo 300000 1; svo; until_svo_uploaded 300000 1000; svo; sample_render_perf 20000 1000 1 10; render_perf; quit"`（Lumen-ON 扫描去掉 `-dpcvars` 那行、半径改 8/16/24/…）。证据存 `clients/Voxia/Saved/a3-diag/`。

- 2026-07-07（**完整重启后执行接力序列：A2「overdraw airtight」归因被干净 GPU 数据证伪；A3「merge 减 overdraw」前提失效；真凶=far-mesh-go-live 路径级 GPU 挂起，与几何量/后端/Lumen 均正交**）：
  - **前置就绪**：用户完整重启，GPU 干净 idle（1252MiB/util4%/54°C）；`clients/Voxia@6df0a0c`（A2 base）二进制就位无需重构；nvidia-smi 全程可核。
  - **接力步 2 判决 —— A2 存活基线现在也崩**：重跑 `Partitioned r72 Lumen-off spawn`（A2 §8「run A2」记 26 FPS 存活的同一配置/同一 6df0a0c 二进制）→ **FPS 22→14 衰减后 `exit 3`**。按接力序列既定判据「首跑存活基线仍崩 = 真实回归」，转 far-mesh-go-live 路径调查。证据 `postrestart_A2survivor_lumenOFF_r72.{log,Voxia.log}`。
  - **崩溃签名颠覆 A2 结论**：Voxia.log 实测崩溃 = **`D3D12Util.cpp:815 Out of video memory trying to allocate a rendering resource`**，Local Used 仅 2013MB / budget 7189MB，`Reserved Buffer Memory (Uncommitted)=10223.688MB`，崩在 Background Worker #23，breadcrumb=LumenReflections/DiffuseIndirectAndAO。→ 与 A2 反复用「崩溃现场显存 38%、非 OOM、是纯 TDR」钉死的结论**直接矛盾**；并发现 A2 与本批的 `-dpcvars` Lumen-off **不完整**（svo dump `reflection_method=1`，只关了 GI method+ScreenProbeGather、**Lumen 反射一直开着**）。
  - **5 组干净 GPU 受控实验**（每次 OOM/removal 均干净退出、GPU 自动恢复，可连续 A/B；证据均 `exp*.{log,Voxia.log}`）：

    | 实验 | 变量 | quad/comp | FPS | 崩溃签名 | 崩溃时显存 |
    | --- | --- | --- | --- | --- | --- |
    | postrestart | Partitioned/StaticDraw · Lumen反射ON | 1.39M/361 | 22→14 | OOM · BgWorker#23 | 2013MB |
    | expA | r72 · 全关Lumen反射/GI/DF/RT | 1.39M/361 | 稳定26-28 | **先 payload>5s timeout(3D+Compute)→后OOM** · RHISubmissionThread/BasePass | 2391MB |
    | expB | **r16** · 全关 | **0.49M/25** | **59.5** | **DEVICE_REMOVED@frame427（go-live 后 1 帧）** · Aftermath超时/DRED off | **861MB** |
    | expC | r16 · 全关+DynamicDraw（无StaticDraw缓存） | 0.49M | — | 崩 | — |
    | expD | r16 · 全关+ProcMesh（A2 前老后端） | 0.49M | — | 崩 | — |

  - **逐项证伪（这就是 A3.0 要的硬数据，全部干净 GPU）**：
    - **非 overdraw**：expB r16 在 59.5 FPS / 25 组件 / 861MB / far_visible=1（近空场景）下仍 device-removed → 可见 overdraw 不可能是因。
    - **非真显存 OOM**：全部崩溃在 0.8–2.4GB（远低于 7.2GB budget）；codex 独立取证两份 r72 日志确认「**GPU timeout/hang 在前、`D3D12Residency pSet->Open() E_OUTOFMEMORY` 在后，OOM 是下游崩溃模式**」。
    - **非 Lumen**：expA 全关 Lumen反射/GI/DF/RT 仍崩（只把帧时从衰减稳成 26 FPS，不消除崩溃）。
    - **非几何量/quad 数（直接否定 A3 merge 前提）**：expB r16=0.49M（已达 merge 目标下界 [0.51M,0.84M] 附近）与 r72=1.39M **同样崩** → **减 quad（A3 merge / A5 瘦身）不能修此崩溃**；codex「降到 0.5M 很可能规避」的猜测被 expB 直接证伪（codex 只有 r72 日志、无 r16 数据）。
    - **非渲染后端**：expC(DynamicDraw)/expD(ProcMesh) 与 expB(Partitioned/StaticDraw) 同崩 → StaticDraw 缓存 draw command、A2 的分组件后端均排除；真凶在**所有后端共有的 go-live 路径**（SVO runtime GPU 资源上传/绑定 + raymarch 资源 + mesh buffer 上传；expB 崩溃 breadcrumb 出现 `FRDGBuilder::SubmitBufferUploads`/`BufferPoolCopyOps`）。
    - **raymarch dispatch 本身规模不足以挂 GPU**（groups[1,1,1]/grid[1,1]/samples1/hit=miss=invalid=0），但其 GPU 资源创建/遍历 shader 仍在共有路径内，待源码核查（codex 调查 task bmss4zy0k）。
  - **主根因（当前最受证据支持）**：**far-mesh-go-live 那一刻某个 GPU 操作挂起 GPU（payload>5s→TDR/device-removed），OOM/residency 失败是崩溃级联的下游**，与 A2 全部「怎么渲染」杠杆及 A3 全部「减几何量」杠杆**正交**。**A3 决策稿 §0–§5 的核心前提（device-removal=overdraw、merge 减半 overdraw 即可兑现渲染目标 #6/#7）就此失效，须重写。** 几何层目标（§5.A：merge 系数/契约不变/视觉等价）仍确定性可做，但**不再挂靠「兑现 A2 device-removal 根治」**。
  - **Exp E DRED 定位受阻 + GPU 被 wedged（须重启）**：为定位挂起 pass 跑 `-gpucrashdebugging`（r16 全关）→ **进程 hang 5min 未退、GPU 100% util 钉死、UnrealEditor-Cmd(22144) 成驱动层孤儿 context**（`taskkill /F /T`、`Stop-Process -Force` 均杀不掉，OS 进程表已无但 nvidia-smi 仍持有），**未捕获到 breadcrumb**（hang 阻止崩溃处理器运行）。**印证 A2 的 `-gpucrashdebugging` 僵尸警告 —— 须完整重启才能清 GPU。** 后续 DRED 定位需换策略（缩到 go-live 前一帧即触发、只回读 `r.D3D12.DRED` 不等 Aftermath dump、或先靠源码假设定向禁用嫌疑 pass 做 A/B）。
  - **纪律留痕**：仍未写任何 merge 代码（严守 A3.0 诊断先行）；tier/cell 契约冻结项未动；expE 之前各档均为干净 GPU 数据（每次崩溃 GPU 自动恢复后才做下一档），不受 wedged 影响。证据全存 `clients/Voxia/Saved/a3-diag/`。
  - **待用户裁决**：(1) 完整重启清 GPU；(2) A3 方向重定——头号阻塞项（default-Lumen 8km 无 device-removal）根因已非 overdraw/merge，需新开子步「far-mesh-go-live GPU 挂起根因定位与修复」（先 DRED/源码定位挂起 pass、再从机制层面修复），A3 原「per-cell greedy merge」降级为**独立几何优化**（仍有减带宽/内存价值，但不再承担「兑现 A2 渲染目标」）。
  - **codex 源码取证（task bmss4zy0k，只读静态，未跑 UE）—— go-live 共有路径 top 嫌疑（均带 文件:行号，逃生门已核实真实存在）**：
    - **[HIGH #1] SVO runtime GPU buffer 每 revision 全量重建 + probe raymarch**：`VoxiaWorldActor.cpp:1942-1974`——`ReleaseSvoRuntimeGpuBuffers → MakeGpuPayload → BeginInitResource → FlushRenderingCommands`（同步建 node/root/rootLookup ByteAddressBuffer，正贴 `SubmitBufferUploads/BufferPoolCopyOps` breadcrumb），随后建 `FRuntimeBufferView` 并 dispatch probe raymarch。**这是所有后端 + raymarch 共读的公共 buffer**，最贴合「backend/几何/Lumen 无关的 go-live device-removed」。嫌疑机制：InitRHI 建的 ByteAddressBuffer 尺寸/元素数不对 → raymarch 读 SRV 越界 → GPU page fault → device-removed（低显存、go-live 后 1 帧，与 expB 完全吻合）。
    - **[HIGH #2] 远景代理 mesh go-live 渲染**：`VoxiaWorldActor.cpp:1322-1349/2358-2375`——`SetMesh → RegisterComponent → SetSvoPartitionedComponentsVisibility(true)` 一帧暴露代理，触发 render resource + GPUScene/descriptor 上传。
    - **[MED/已基本排除 #3] raymarch composite 全屏每像素 root-lookup DDA**（`VoxiaSvoRaymarchComposite.cpp` + `VoxiaSvoRaymarch.usf` `for Iteration<256`）——**仅当传 `-VoxiaSvoRaymarchComposite` 才触发；本批全程未传，svo dump `raymarch_composite_pass_observed:false`，排除**。
    - codex 排除项：MainCS 默认 probe 1×1、screen probe cap 65536、shader 无无界 `while`、root-lookup CPU 构建有 `CellCount64>1048576` 拦截；源码侧无 `CreateReservedResource`/10GB+ Voxia buffer（那 10223.688MB reserved 是 UE RHI 池的虚拟保留、非 Voxia 分配）。
  - **重启后 A3.0-bis 定位梯（严格按序、存活优先、全 r16 全关、避免 `-gpucrashdebugging` 再 wedge）**：
    1. `nvidia-smi` 确认 idle；
    2. **判别器（无改码单跑）**：加 `-VoxiaSvoSkipProxyMesh`（**只关代理 mesh、保留 runtime buffer 上传 + probe raymarch**；已核实 `VoxiaWorldActor.cpp:117-136` 语义）——**存活 ⇒ 真凶 = #2 代理 mesh go-live 渲染；仍崩 ⇒ 真凶 = #1 runtime buffer 上传 / probe raymarch**；
    3. 若指向 #1：再用 `ShouldDeferInitialSvoRaymarchProbe`（`VoxiaWorldActor.cpp:1972`，查其触发 flag）延迟 probe 分离「buffer 上传 vs raymarch probe」；仍不够则加最小 flag `-VoxiaSvoSkipRuntimeGpuUpload` 在 `1942` 前短路，二分定位；
    4. 若指向 #2：查 `SetMesh/RegisterComponent` 与 GPUScene/descriptor 上传的资源生命周期（stale SRV / 未初始化 buffer / mobility）；
    5. 定位到具体 pass 后**从机制层面修复**（非补丁），再复测 default-Lumen 8km 巡航无 device-removal。
    - DRED 若仍需：换「缩到 go-live 前一帧即 quit / 只回读 `r.D3D12.DRED` 不等 Aftermath dump」策略，勿再用会 hang 的全量 `-gpucrashdebugging`。
  - **git 回归考古（用户提问「A1 之前远景渲染正常，为何现在崩」——亲自查、未用 codex）**：
    - **go-live 的 runtime-buffer + raymarch dispatch 代码每一行都在 A1/A2 之前**（git blame `VoxiaWorldActor.cpp:1942-2010`）：runtime GPU buffer `0c3ecad9`(07-01)、**raymarch dispatch probe `76edfc1e`(07-02)**、raymarch mode/composite `93faa21/d483e52`(07-03)、**root-lookup grid + defer-probe `e1dd1f83`(07-05)**。
    - **A1(`800e68c`,07-06) 只改 tier 结构**（`VoxiaSvoPreview.cpp` +344：`CellDepthForRings`/四环/depth 4-3-2-1/per-ring payload），**A2(`6df0a0c`,07-07) 只改渲染后端**（`VoxiaWorldActor.cpp` +366 全在 partitioned 组件池/材质/可见性/bulk-hide/剔除，**未碰公共 runtime/raymarch 段**——故 Exp D ProcMesh-flag 仍崩 = **A2 非公共路径回归源**）。
    - **已知良好基线 = 07-01「8km 104-115 FPS」（README 记）**——那时 runtime buffer 已在，但 **raymarch probe(07-02)/root-lookup(07-05) 都还没加**。即用户记忆的「正常远景渲染」正是 **07-01、raymarch probe 之前**。
    - **raymarch shader 循环已排除无限循环**（`Shaders/VoxiaSvoRaymarch.usf`：所有 loop 上限 16/256/8/StepLimit/ScanCount，node/root 索引全带 `>=Count` 守卫）→ probe 挂起若成立，多半是 **buffer 绑定/SVO 结构不一致**（A1 改的 depth/root-lookup 喂给 07-02/07-05 的 raymarch）而非 shader 死循环。
    - **回归窗口锁定 = 07-02（raymarch probe）/ 07-05（root-lookup）叠加 + A1(07-06) tier 改动点燃**；A2 排除。**重启后用 code-path 二分（无需重建）定 commit**：① `-VoxiaSvoRaymarchDeferInitialProbe`（`VoxiaWorldActor.cpp:480`，只跳 probe）存活⇒probe(07-02) 是真凶；② `-VoxiaSvoSkipProxyMesh` 存活⇒A1 的 mesh/proxy 渲染是真凶；③ 两者都关仍崩⇒runtime buffer 上传(07-01) 本身。若仍要定 commit，再 git-bisect 重建 07-01/A1 二进制实测。
  - **架构裁决 + 落地：raymarch 默认关（用户拍板「就全部类 minecraft 三角形渲染」）**：
    - **依据（源码实证）**：`SvoRuntimeGpuBuffers` 的 `GetNodeSrv/GetRootSrv/GetRootLookupSrv` **唯一读者全是 raymarch**（go-live probe / deferred probe / composite）；三角形 proxy mesh 有自己的 VB/IB、**不消费 runtime buffer**。go-live probe 实测 `raymarch_visual_pixels:0`、composite 未触发——**对画面零贡献**。raymarch 是 defer 化的可选 L4「光线步进八叉树」超远景路线 + 诊断 probe（设计稿 v2.4 已 defer），L0-L3 生产路径用不到。故 go-live 的三个 GPU 操作里，**①runtime buffer 上传 + ②raymarch dispatch 纯为 raymarch、零可见、且是崩溃两大嫌疑；③三角形 mesh 是唯一真画世界的、且 07-01 验证过正常**。
    - **改动**（`clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.cpp`）：新增 `ShouldEnableSvoRaymarch()`（默认 false，仅 `-VoxiaSvoRaymarch`/`-VoxiaSvoRaymarchComposite`/`-VoxiaSvoRaymarchOnly`/`-VoxiaSvoRaymarchScreenProbe`/`-VoxiaSvoRaymarchWorldSpace`/`-VoxiaSvoRaymarchPreviewGrid=`/`-VoxiaSvoRaymarchDeferInitialProbe` 显式请求才 true）；把 runtime buffer build 用它包起来。buffer 不建→`bSvoRuntimeGpuBuffersReady` 保持 false→下方 raymarch dispatch 块与 deferred probe 自然跳过。**默认 go-live = 只三角形 mesh，整块跳过 ①②**；显式 raymarch 档位行为完全不变。automation 无「默认 raymarch dispatch」断言（已核 line 300/825/895 均不受影响）。
    - **预期**：默认路径去掉 07-02 加的 raymarch probe + 07-01 的 runtime buffer 上传，只剩 07-01 验证过的三角形 mesh → **极可能消除 far-mesh-go-live device-removed**；同时把实验性非可见子系统移出默认热路径（架构简化，非补丁）。
    - **状态**：本机 GPU 仍 wedged 无法实测；用户将在另一台机器 build + 测。**验证口径**：默认 smoke（不传任何 raymarch flag，`svo` dump 应见 `raymarch_dispatched:false`/`runtime_resource_ready` 仍为 CPU 侧值）8km facing 稳态无 `DXGI_ERROR_DEVICE_REMOVED`⇒真凶=raymarch/runtime-buffer 坐实、崩溃解决；若默认路径仍崩⇒真凶落到三角形 mesh 本身，顺 #2（proxy mesh go-live 渲染）继续查。代码 commit 在 `clients/Voxia`、文档在 `ex_mmo_cluster`，均已 push 供另一台机器拉取。
