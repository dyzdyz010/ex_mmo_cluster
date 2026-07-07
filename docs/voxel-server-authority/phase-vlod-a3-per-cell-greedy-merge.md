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

- 2026-07-07（**干净 GPU 实测：raymarch 默认关消除 far-mesh-go-live 崩溃——真凶（runtime GPU buffer 上传 + raymarch dispatch）坐实**）：
  - **环境**：新机/重启后干净 GPU（RTX 5060 Laptop 8151MiB，运行前 4273MiB/util7%/49℃，**无 UnrealEditor 残留占显存**；余量为浏览器/模拟器等桌面常驻，非 wedged UE context）。构建 `clients/Voxia@1fc93d2`（纯净目标 commit，detached checkout，本地 WIP 隔离在 `master@2a9e21a` 不参与）→ VoxiaEditor 增量编译 30/30 `Result: Succeeded`。
  - **step 3 · r16 默认 smoke（复现 expB 必崩配置，唯一变量=raymarch 默认关）**：`-VoxiaSvoTileRadius=16` + 全关 Lumen/GI/DF/RT（`-dpcvars` 同 expB）+ **不传任何 raymarch flag**；命令面 `until_baseline_ready→until_tile_window_full→until_svo→until_svo_uploaded(1000 cells)→sample_render_perf 20s`。**结果全绿**：
    - `raymarch_dispatched:false`（27/27 采样）、`raymarch_mode:none`——默认路径确不 dispatch raymarch、不建 runtime GPU buffer；
    - `quad_count:491837`（**与 nullrhi 阶梯 r16 逐字一致、正是 expB 的 0.49M 几何**）、`macro_cell_count:1080`、`far_component_count:25`/`far_visible_component_count:1`（同 expB 近空场景）、`presentation_consumed:true`/`upload_complete:true`（**远景 mesh 确 go-live 并 present**）；
    - `sample_render_perf`：go-live 后 20 样本、均值 **457.6 FPS**、min 370.9、`passed:true`——**跑满崩溃窗口（go-live+N 帧）未崩**；
    - `child exit code=0`/`NODE_EXIT=0` 干净退出；Voxia.log **无** `DXGI_ERROR_DEVICE_REMOVED`/`Out of video memory`/`GPU timeout: A payload`/Aftermath/residency-OOM，干净 `LogExit: Exiting`；GPU 运行后 4243MiB/util4% **完全恢复无泄漏**。
  - **裁决（干净 A/B，airtight）**：**同一 r16 几何（491837 quad）+ 同一 Lumen-off 环境，expB(raymarch ON) 在 go-live+1 帧 `DXGI_ERROR_DEVICE_REMOVED`（§8 上批 expB），本次(raymarch OFF) go-live 后稳跑 20s @457FPS**。唯一变量=raymarch/runtime-buffer → **真凶 = go-live 路径的 SVO runtime GPU buffer 上传 + raymarch dispatch（codex 取证 [HIGH #1]）坐实；崩溃已消除**。同时逐项复证前批结论：非几何量（0.49M 同崩→现活）、非后端、非 Lumen（本就全关仍崩→现活）。
  - **纪律留痕**：仍未写任何 merge 代码；契约冻结项未动；`-gpucrashdebugging` 全程未加（`r.GPUCrashDebugging:0` 已核）。证据存 `clients/Voxia/Saved/a3-diag/verify_r16_raymarchOFF.{log,Voxia.log,gpu.txt}`。
  - **step 4 · r72 + 默认 Lumen ON（生产目标配置，最重）**：清干净 GPU 至 2328MiB/util1% 后跑（用户关掉浏览器/模拟器等常驻）；`-VoxiaSvoTileRadius=72`、**去掉整条 `-dpcvars`（默认 Lumen/AA ON）**、raymarch 仍默认关。**结果全绿**：
    - Voxia.log 实证 Lumen 确 ON（`r.DynamicGlobalIlluminationMethod:1`/`r.Lumen.DiffuseIndirect.Allow:1`/`r.Lumen.FinalGatherMethod:1`/LumenScene SurfaceCache 4096），非抑制档；
    - `raymarch_dispatched:false`（51/51）、`raymarch_mode:none`；
    - `quad_count:1388647`（=1.39M，**正是 postrestart/expA 崩溃的同一 r72 几何**）、`macro_cell_count:21016`、`far_component_count:361`（与 postrestart 的 361 逐字一致）、`presentation_consumed`/`upload_complete:true`（远景 mesh go-live 并 present）；
    - `sample_render_perf`：go-live 后 20 样本、均值 **176.5 FPS**、min 149.6、`passed:true`；
    - `NODE_EXIT=0` 干净退出；Voxia.log **无** device-removed/OOM/payload-timeout/Aftermath/Fatal，干净 `LogExit: Exiting`；GPU 运行后 2171MiB/util5% **完全恢复**。
  - **裁决（step 4，airtight）**：**postrestart(Partitioned r72 Lumen反射ON，OOM@BgWorker#23) + expA(r72 全关，payload>5s timeout→OOM) 崩溃的同一 1.39M/361 配置，raymarch 关掉后带默认 Lumen 稳跑 176FPS**。→ 复证「OOM 是 GPU-hang 的下游级联」（§8 上批），raymarch/runtime-buffer 一撤，OOM/device-removed 同时消失。**生产目标配置（8km facing + 默认 Lumen）稳态无 device-removal 达成。**
  - **总结论（初版，因果机制经下条阴/阳性对照进一步精化——务必连读下条）**：**far-mesh-go-live device-removed/OOM 崩溃已消除；崩溃位于 go-live 路径的 SVO runtime GPU buffer 上传 + raymarch dispatch（对画面零贡献的实验性 raymarch 子系统），与 overdraw/几何量/后端/Lumen 全正交。** `clients/Voxia@1fc93d2`（raymarch 默认关）为该崩溃的机制级修复。A3 原「per-cell greedy merge 减 overdraw 兑现 device-removal 根治」前提彻底作废（§8 上批已证伪，本批实测封棺）；merge 若做仅作独立几何/带宽优化，不挂靠崩溃修复。证据存 `clients/Voxia/Saved/a3-diag/verify_r72_defaultLumen.{log,Voxia.log,gpu.txt}`。
    - ⚠️ **纠偏**：本条初写「真凶=raymarch…坐实」属**过度断言**（只有阴性对照）。下条阴/阳性对照闭环后精化为：**崩溃是真的且位于 raymarch 路径，但是一个「二进制内存布局相关的潜伏 UB」，非"raymarch 代码一跑必崩"**——详见下条。

- 2026-07-07（**阴/阳性对照闭环：崩溃是真的（6df0a0c 干净 GPU 复现）+ 潜伏「布局相关 UB」+ raymarch-off 是可靠修复；纠正上条"坐实"过度断言**）：
  - **动机**：用户追问「是不是 raymarch 的问题？打开 raymarch 试试把问题钉死」——上条只做了阴性对照（raymarch off 存活），缺阳性对照。补三档受控实验（同机同 GPU，`-gpucrashdebugging` 全程未加，一次一档、崩后 nvidia-smi 确认恢复）。
  - **1fc93d2 diff 实证**：`git show 1fc93d2` = **纯加壳门控**——新增 `ShouldEnableSvoRaymarch()`，把 runtime buffer build **原样**包进 `if(ShouldEnableSvoRaymarch)`；`if` 块内代码与 `6df0a0c` **逐字相同**。故传 `-VoxiaSvoRaymarch` 时执行的 raymarch buffer+probe 路径与 6df0a0c 完全一致（实测 `raymarch_mode:probe`/`dispatched:true` 证实真跑）。
  - **三档对照实测**：

    | 二进制 | raymarch | 半径/Lumen | 结果 | 证据 |
    | --- | --- | --- | --- | --- |
    | **1fc93d2** | **强开** `-VoxiaSvoRaymarch` | r16 / Lumen-off | **存活 505 FPS**（probe 真 dispatch） | `verify_r16_raymarchON_positivecontrol.{log,gpu}` |
    | **6df0a0c**（expB 崩溃二进制） | on（无条件默认） | r16 / Lumen-off | **崩 `DXGI_ERROR_DEVICE_REMOVED`@go-live(frame383)+Aftermath 超时**，`NODE_EXIT=3`；只到 `tile_window_full` | `verify_6df0a0c_r16_repro.{log,Voxia.log,gpu}` |
    | **1fc93d2** | **强开** `-VoxiaSvoRaymarch` | **r72** / Lumen-off（=expA） | **存活 418 FPS**（probe 真 dispatch，1.39M/361） | `verify_1fc93d2_r72_raymarchON.{log,Voxia.log,gpu}` |

  - **裁决①：崩溃是真的、二进制级的，非环境假象**——同一块干净 GPU、同一会话、同一 r16 配置，**只换二进制**：6df0a0c 崩、1fc93d2 活。**忠实复现 expB 签名**（DXGI_ERROR_DEVICE_REMOVED @ go-live + Aftermath timeout）。→ §8 前批「完整重启后 5 组受控实验」的崩溃证据被**证实（vindicated）**，不是 GPU 污染/时序噪声。
  - **裁决②：这是一个「二进制内存布局相关的潜伏 UB」，非"raymarch 一跑必崩"**——**同一份 raymarch 源码**（1fc93d2 门控内 = 6df0a0c）：在 6df0a0c 的编译布局下**确定性崩**（r16 崩、§8 expA/postrestart r72 崩），在 1fc93d2 的编译布局下**被掩盖**（r16 505 + r72 418 强开均活，含最重 expA 配置）。高度符合 codex HIGH#1 假设：`InitRHI` 建的 ByteAddressBuffer 尺寸/元素数不对 → raymarch 读 SRV 越界 → GPU page fault → device-removed；这类 UB 的**触发依赖内存/资源布局**，故对二进制微小 codegen 差异敏感（那层 `if` 壳即足以移动布局、避开或触发）。
  - **裁决③：`1fc93d2`（raymarch 默认关）是可靠修复，但"1fc93d2 强开仍活"是脆弱偶然、不可依赖**——可靠正因为它**根本不跑那条 buggy 路径**（默认 go-live 只三角形 mesh）。**若将来重启用 raymarch（defer 化 L4 超远景路线），必须先根因修复该 buffer/SRV UB（codex HIGH#1：核对 node/root/rootLookup ByteAddressBuffer 的元素数/字节数/SRV 边界），不能依赖当前布局的偶然掩盖。**
  - **对上条纠偏**：上条「真凶=raymarch…坐实」应读作「崩溃真实存在且位于 raymarch runtime-buffer/dispatch 路径（6df0a0c 复现坐实），其性质=布局相关潜伏 UB；raymarch-off 是稳修、但底层 buffer bug 只是被门控隔离、未被修复」。生产结论不变：默认路径（raymarch off）已验证 r16/r72+Lumen 稳态无崩，可采用。
  - **纪律留痕**：未写任何 merge/修复代码（仅诊断）；`-gpucrashdebugging` 全程未加；每次崩后 GPU 均自动恢复（6df0a0c 崩后 2465MiB/无 UE 残留）后才做下一档。证据全存 `clients/Voxia/Saved/a3-diag/`（阳性对照 Voxia.log 因 UE 每次轮转被后续 run 覆盖未及时拷贝，node 日志已存 dispatched:true+存活）。git：诊断在 `1fc93d2`/`6df0a0c`（detached）上做，测毕已复位 `master@2a9e21a`（WIP 完整）；当前编译产物为 1fc93d2。

- 2026-07-07（**根因下探：6df0a0c 代码路径二分——崩溃 = raymarch probe dispatch(#1b) × proxy-mesh go-live(#2) 的交互，非单点越界；修正裁决②**）：
  - **动机**：用户要「把最根源最细致的地方钉死，方便后续修复」。在**会崩的 6df0a0c 二进制**上用运行时逃生门 flag 做代码路径二分（不违反 `-gpucrashdebugging` 硬约束：flag 关某个 GPU 操作、看崩不崩）。go-live 三个 GPU 操作（`VoxiaWorldActor.cpp`）：**#1a runtime buffer 上传**（1942-1952，无条件）/ **#1b raymarch probe dispatch**（1955-2028，`DispatchProbe` 读 node/root/rootLookup SRV）/ **#2 proxy mesh go-live**（2078+，SetMesh/RegisterComponent → GPUScene 上传）。
  - **二分真值表**（全 6df0a0c/r16/Lumen-off，同干净 GPU，一次一档，崩后 nvidia-smi 确认恢复）：

    | 配置 | #1a buffer | #1b probe | #2 proxy | 结果 | 证据 |
    | --- | :-: | :-: | :-: | --- | --- |
    | default（=expB） | ✓ | ✓ | ✓ | **崩 DXGI_ERROR_DEVICE_REMOVED @go-live** | `verify_6df0a0c_r16_repro.*` |
    | `-VoxiaSvoRaymarchDeferInitialProbe` | ✓ | ✗ | ✓ | **存活 516 FPS**（干净单次 go-live） | `verify_6df0a0c_r16_deferprobe_bisect.*` |
    | `-VoxiaSvoSkipProxyMesh` | ✓ | ✓ | ✗ | **不崩**（probe dispatch ×854、300s 无崩，hang 在 harness 收尾条件=NODE_EXIT124） | `verify_6df0a0c_r16_skipproxy_bisect.*` |

  - **逐项证伪（都在同一崩溃二进制上）**：
    - **#1a buffer 上传单独安全**：defer-probe run 里 buffer 实建（`runtime_gpu_bytes:4956036`、`runtime_node_count:76560`、`runtime_root_count:1080`、`runtime_resource_ready:true`）+ proxy mesh live，**去掉 probe 就不崩** → buffer 上传不是触发。
    - **#1b probe dispatch 单独也安全**：skip-proxy run 里 probe **dispatch 了 854 次**（`raymarch_mode:probe`/`dispatched:true`）、跑满 300s、Voxia.log 零崩溃签名 → probe 的 SRV 读**不是独立越界**（否则第一次就崩）。**这否证了裁决②「raymarch 读 SRV 越界」的单点解释。**
    - **只有 #1b + #2 同时在场才崩**：default（三者全在）崩；抽掉 probe(defer) 或抽掉 proxy(skip) 都不崩。
  - **根因（当前证据支持的最细定位）**：**far-mesh-go-live device-removed = raymarch probe compute dispatch（`VoxiaWorldActor.cpp:2009-2026` → `FVoxiaSvoRaymarchCS::DispatchProbe`，`VoxiaSvoRaymarchShader.cpp:311-357`）与 proxy-mesh go-live 渲染（`VoxiaWorldActor.cpp:2078+`，GPUScene/descriptor 上传）在同一 build cycle 共存时的 GPU/驱动层状态交互**。二者在 CPU 侧是顺序执行（probe 块带 `FlushRenderingCommands` 同步、DispatchProbe 内对 UAV 做 Transition 且 flush），故交互发生在**跨调用的 GPU 资源/驱动状态**层面（descriptor heap / 资源生命周期 / barrier 时序之一），对二进制内存布局敏感（解释 1fc93d2 codegen 掩盖）。
  - **修正裁决②**：原「probe 读 SRV 越界（单点 UB）」被 skip-proxy 的 854 次无崩 dispatch 否证。更准确表述：**崩溃是 probe dispatch 与 proxy-mesh go-live 的交互态 fault，非任一单独操作的越界**；「布局相关」性质不变。
  - **修复指引（给后续）**：
    1. **生产（已落地）**：`1fc93d2` raymarch 默认关 = 移除 #1b，两操作不再共存 → 可靠修复（r16/r72+Lumen 已验证）。**这是当前推荐终态。**
    2. **若将来重启用 raymarch（L4 超远景）**：`-VoxiaSvoRaymarchDeferInitialProbe` 实测存活 → **把 probe 与 proxy-mesh go-live 解耦到不同帧**（延后/错帧 probe）即可规避，无需砍功能；这是最小改法方向。
    3. **要坐实精确 faulting 资源/指令**：须 DRED/Aftermath breadcrumb，但 §8 记 `-gpucrashdebugging` 会把本崩溃路径 wedge 成不可杀僵尸（硬约束禁用）。**替代**：`r.D3D12.DRED=1`（轻于 Aftermath）+ 缩到 go-live 前一帧即 quit 只回读 breadcrumb（有 wedge 残险，需用户授权再做）。**此步未做——精确指令级定位是当前唯一未闭合项，且被硬约束挡住，非诊断不足。**
  - **纪律留痕**：未写任何修复/merge 代码；`-gpucrashdebugging` 全程未加；每档崩/hang 后 GPU 均恢复（终态 2479MiB/无 UE 残留）。证据 `clients/Voxia/Saved/a3-diag/verify_6df0a0c_r16_{repro,deferprobe_bisect,skipproxy_bisect}.*`。git 已复位 `master@2a9e21a`（WIP 完整）；当前编译产物为 6df0a0c 诊断残留，用户复工前需 rebuild master。

- 2026-07-07（**DRED-lite + RHI breadcrumb 取证：崩溃 = GPU TDR 挂起（非越界），落在 far-mesh go-live 后的渲染帧、graphics/async-compute 跨队列错帧；精确 faulting 指令被 Heisenbug 本质挡住**）：
  - **动机**：用户授权做 DRED-lite（`r.D3D12.DRED`，不用 `-gpucrashdebugging`）把精确 faulting 资源/指令钉死。
  - **DRED 机制核实**（`D3D12Adapter.cpp:156-617` + `RHI.cpp:2092 ShouldEnableGPUCrashFeature`）：`-dred` 命令行开关**独立启用** Full DRED（auto-breadcrumb + page-fault），走 `FParse::Param(..,"dred")` 分支，**不触发 `-gpucrashdebugging` 总闸、不拉 Aftermath dump**。安全可控。
  - **DRED 实测 = 崩溃消失（Heisenbug 铁证）**：6df0a0c r16 Lumen-off + `-dred` → `[DRED] DRED enabled` 生效，却 **`NODE_EXIT=0` 存活**（svo_1000_uploaded 全过）、GPU 未 wedge。**DRED 插桩（每 GPU op 前后写 breadcrumb + 改资源分配/时序）扰动足以掩盖崩溃**，与 1fc93d2 codegen 掩盖同源。→ **若为静态 OOB，DRED 的 page-fault 追踪正该抓到且照样 fault；DRED 让 fault 消失 = 不是越界，是时序/同步竞态。**
  - **改从裸崩日志挖 RHI breadcrumb**（`r.GPUCrashDebugging.Breadcrumbs` 默认=1，`verify_6df0a0c_r16_repro.Voxia.log:1646-2206`，无插桩无掩盖）：
    - `LogD3D12RHI: Error: GPU crash detected: Device 0 Removed: DXGI_ERROR_DEVICE_REMOVED`；`Shader diagnostic messages: No shader diagnostics found`（**非 shader assert/越界**）。
    - **Graphics 队列**（`In:0x8000e54c/Out:0x8000e54b`）：崩在 **Frame 377 → PostProcessing → ComposeTranslucencyToNewSceneColor / MotionBlur `[Active]`**；其后 LocalExposure/Bloom/FXAA/Frame378 全 `[Not Started]`。
    - **AsyncCompute 队列**（`In:0x8000e591/Out:0x8000e5af`）：已跑到 **Frame 378 → SceneRender → Scene → FXSystemPreRender `[Active]`**。→ **两队列错帧（Graphics 377 vs AsyncCompute 378）**。
    - **`DRED: No PageFault data`**（裸崩 page-fault 追踪未开，故此项不可用于判越界；但结合 Aftermath「无 shader 诊断」+ DRED 掩盖，OOB 已被三重否证）。
  - **根因（当前证据能到达的最深、且诚实标注边界）**：
    - **性质 = GPU TDR 挂起（hang），非静态越界 OOB**：无 shader 诊断、DRED 一开即掩盖（Heisenbug）、§8 前批实测 `payload>5s timeout`。
    - **发生位置 = far-mesh go-live 之后的渲染帧**（Frame 377/378 引擎 PostProcessing/FXSystemPreRender，非 `QueueSvoMeshUpdate` go-live 代码本身——go-live 已同步完成）；此时场景**同时含**新注册 proxy mesh(#2) + 常驻 raymarch runtime buffer/probe 已跑(#1b)。
    - **机制类 = raymarch probe 路径与 proxy-mesh 渲染在 GPU 跨队列（graphics×async-compute）的同步/时序竞态**：与二分（probe 或 proxy 缺一即不崩）+ 布局/插桩敏感（1fc93d2、DRED 均掩盖）完全自洽。
  - **精确 faulting 指令 = 当前不可观测（非诊断不足，是 Heisenbug + 硬约束双重封死）**：① Aftermath dump 超时取不到 shader 级；② page-fault 需 DRED，而 DRED 一开崩溃即消失；③ RHI breadcrumb 只到 pass 级、且崩点在挂起被察觉处（PostProcessing）非真凶 op。**任何能取到精确指令的插桩都会扰动掉这个时序竞态。** 此项就此定性封存。
  - **修复指引（终版）**：
    1. **生产（已落地验证）**：`1fc93d2` raymarch 默认关 = 彻底移除 #1b probe 路径 → 两操作不再共存、竞态消失。**推荐终态。**
    2. **将来重启用 raymarch**：`-VoxiaSvoRaymarchDeferInitialProbe` 实测存活 → 把 probe 与 proxy-mesh go-live/后续渲染**跨帧解耦**；根治需在 probe 的 GPU 资源与 proxy-mesh 渲染之间补正确的**跨队列同步（barrier / 避免 async-compute 重叠 / fence）**，而非依赖布局偶然。
    3. 不要再尝试用插桩抓精确指令（会掩盖）；若必须，唯一路径是**离线静态审查** probe dispatch 与 proxy-mesh 上传对共享 GPU 资源的 barrier/state 处理（`DispatchProbe` 的 UAV Transition + `QueueSvoMeshUpdate` 后续 RegisterComponent 的 GPUScene 上传时序）。
  - **纪律留痕**：`-dred` 独立启用（非 `-gpucrashdebugging`）、GPU 全程未 wedge（终态无 UE 残留）；未写任何修复代码。证据 `clients/Voxia/Saved/a3-diag/verify_6df0a0c_r16_DRED.*`（存活）+ `verify_6df0a0c_r16_repro.Voxia.log:1646-2206`（breadcrumb）。
