# Phase VLOD-A3b：远景 SVO per-cell masked greedy merge（几何/带宽优化）

> 承接自 [`phase-vlod-a3-per-cell-greedy-merge.md`](phase-vlod-a3-per-cell-greedy-merge.md) §9 结项裁决。
> **前提已换**：A3 原把 merge 当「device-removal 根治承重墙」，该崩溃已由 raymarch 默认关（`clients/Voxia@1fc93d2`）独立修复、且经 A3.0 实测证明与 merge **正交**（r16=0.49M 与 r72=1.39M 同样崩，减 quad 修不了）。
> 故本 phase **不挂靠任何崩溃修复**，merge 仅作**独立几何/带宽/内存优化**推进。

## 0. 一句话

远景 SVO leaf-surface mesh 现状逐面 `EmitQuad` 无合并，8km 全量 r72 = **1,388,647 quad**；本步在**每 leaf cell 内**对 exposed face 做 masked greedy 合并，把 quad 降到设计预算 **0.51-0.84M**，减小组件 mesh → 降 VRAM/带宽/base-pass 成本、抬远景 FPS 余量，**视觉等价、tier/cell 契约逐字不变**。

## 1. 目标

- **几何目标（确定性，必达）**：8km 全量 `quad_count` **1,388,647 → 0.51-0.84M**；per-ring 落按带系数区间；tier/cell 契约逐字不变；视觉等价（只减 quad 不减覆盖）。
- **收益目标（可测，条件性）**：quad↓ 兑现为**可测的 VRAM / base-pass / FPS 收益**——对照 A3.0 实测的 raymarch-off 基线 **r72 默认 Lumen = 均值 176.5 FPS / min 149.6 / 1.39M quad**（`a3-diag/verify_r72_defaultLumen.*`），merge 后同机位同配置应 quad 显著下降且 FPS/显存不劣化、预期改善。**不预设改善幅度，实测标定并如实记录。**

## 2. 范围边界（显式非目标）

- **不修崩溃、不挂靠 device-removal**：崩溃已由 raymarch-off 解决（见 A3 §8/§9）；本步纯几何优化，成败**不以崩溃为判据**。
- **merge 作用域严格限 cell 内**——不跨 cell、不跨 depth 合并；越 cell 会破 tier/cell 契约并侵入覆盖性 seam 域。
- **不碰 tier/cell 契约**（cells/depth/lod_config/max_depth/macro_cell_count 铁律不变）。
- **不动 A2 渲染管线**：合并后 mesh 仍走 PartitionedDynamicMesh 分组件 + StaticDraw + 剔除 + Unlit + bulk-hide。
- **不重开 raymarch**（生产终态=默认关；重启 raymarch 是另一条独立线，见 A3 §9 风险提示）。

## 3. 改动点（先定位再改）

### 3.1 per-cell masked greedy merge（承重墙）
远景 leaf-surface mesh 生成（`VoxiaSvoPreview.cpp` `BuildMacroCellUpdate` 家族，现状逐面 `EmitQuad`）加 per-cell masked greedy merge：对每 leaf cell 的 exposed face 按**轴向平面 + 同材质 + 同朝向**分组做贪心合并，**严格限 cell 内**。

### 3.2 可观测
svo snapshot/observe 增：per-ring merged quads、per-ring merge 系数实测值（前/后比）、总 quad 前后对比、`merge_enabled`；逃生门 `-VoxiaSvoFarNoMerge`（关 merge 走旧逐面路径供 A/B 对照）。

### 3.3 视觉等价断言
`seam_check.status=pass` 不回归；无新洞 / 无双面 / 覆盖面积守恒（合并只减 quad 不减覆盖）；可选 A/B 像素对比（merge vs `-VoxiaSvoFarNoMerge` 同机位截图无可见差）。

### 3.4 automation
扩 `Voxia.Voxel.SvoPreview`：按带 merge 系数落区间、覆盖面积守恒、tier/cell 契约逐字不变、merge 前后 quad 单调下降落预算；`VoxiaGreedyMesher`-风格单测（注：既有 `FVoxiaGreedyMesher` 是 chunk-level，与本步 per-cell SVO 变深度 leaf 语义不同，见 §7）。

## 4. 决策项（自 A3 §4 迁入；D3 已作废）

| # | 决策 | 选项 | 推荐 |
| --- | --- | --- | --- |
| D1 | merge 实现 | (a) 复用/扩展 `FVoxiaGreedyMesher`，抽 cell 内 masked greedy 核心适配 SVO 变深度 leaf；(b) 远景 SVO 专用新 merge | **✅ 拍板 (a)-核心复用**（2026-07-07 用户认同）：抽贪心 mask-sweep 核心为坐标无关共享 primitive + 复用 `EmitQuad`；**不**整体套 `FVoxiaGreedyMesher::Build`（三处语义差 → 破坐标口径/视觉等价）。落地方案见 **§9**。 |
| D2 | 视觉等价验证 | (a) 覆盖面积守恒断言（automation）；(b) A/B 像素对比（真实 RHI）；(c) 都上 | **(c)**：守恒断言硬门槛，真实 RHI A/B 人工兜底 |
| D4 | merge 系数验收带宽 | (a) 按 §5 表（细环÷2-4/粗环÷1.2-2）；(b) 实测收窄 | **(a) 起步**；显著偏离则查算法或如实修订预算 |
| D5 | 对照口径 | (a) 半径梯度改可见 quad；(c) merge 后 vs merge 前同 r72 对照 | **(a)+(c)**；(a) 的 nullrhi quad 阶梯 A3.0 已产出（r8..r72→287082..1388647），可直接复用 |
| ~~D3~~ | ~~merge 不足则重挂 A5/雾/Lumen~~ | — | **作废**（其「merge 兑现 device-removal 根治」前提随 A3 §9 一并失效） |

## 5. 验收矩阵

### 5.A 几何层（确定性，本步必达）

| # | 维度 | 断言 | 锚点 |
| --- | --- | --- | --- |
| 1 | quad 总量回归 | merge 后 8km 全量 `quad_count` 落设计预算 | **1388647 → 0.51-0.84M** |
| 2 | 按带系数 | per-ring merged quads 落按带区间 | L1 `287082→72-144k`(÷2-4)、L2 `570641→190-285k`(÷2-3)、L2.5 `288904→144-241k`(÷1.2-2)、L3 `242020→121-202k`(÷1.2-2) |
| 3 | tier/cell 契约不变（铁律） | cells/depth/lod_config/max_depth/macro_cell_count 逐字不变 | `280/2112/4160/14464`、`4/3/2/1`、`7@8,14@24,28@40,56@72`、`4`、`21016` 全不变 |
| 4 | 视觉等价 | 无新洞/无双面/覆盖守恒；seam 不回归 | 覆盖面积守恒断言 pass；`seam_check.status=pass`；A/B 像素 merge vs no-merge 无可见差 |
| 5 | 不回归 | automation 全绿 + Build 0；A2 分组件/StaticDraw/剔除/Unlit/bulk-hide 不回归；near mesh 不回归 | `Automation RunTests Voxia` 全 Success |

### 5.B 收益层（可测，非崩溃——取代 A3 原 device-removal 挂靠）

| # | 维度 | 断言 | 门槛/基线 |
| --- | --- | --- | --- |
| 6 | quad↓ 兑现资源收益 | merge-on vs merge-off（`-VoxiaSvoFarNoMerge`）同 r72 默认 Lumen 同机位：quad 显著下降，VRAM/base-pass 时间/FPS **不劣化且预期改善** | 基线 = raymarch-off r72 默认 Lumen **176.5 FPS / 1.39M quad**（`a3-diag/verify_r72_defaultLumen.*`）；改善幅度实测标定、不预设 |
| 7 | 无隐性代价 | merge 不引入 build_ms 爆增/内存尖峰/首帧卡顿 | `build_ms` 与 merge-off 同量级；实测记录 |

**严格性说明**：几何层（5.A）是确定性契约、必达；收益层（5.B）是**可测目标**——merge 的价值在于资源/性能改善，用真基线对照量化，**绝不用「应该更快了」糊过去**；若实测收益不显著，如实记录并据此判 merge 是否值得保留全量。

**5.B 实测裁决（2026-07-07 Step 6，如实）**：#6 **部分达成**——生产场景 quad **−57.3%**（592937 vs 1388647，确定性达成）、mesh 显存/带宽 ≈−57%（几何确定性）、build 更快（4948<5247）；但 **FPS 中性/混合**（@-35 ON 77.93 vs OFF 84.39，被 DRS 77% + Lumen 全屏 GI 主导混淆，远景几何非 FPS 瓶颈），**未兑现 FPS 改善、也未劣化到影响可用**。#7 **达成**（build 不爆增、无内存尖峰、4 跑全存活 0 device-removal）。**裁决保留 merge**：价值落在几何/带宽/内存（与 A3b 定位一致），FPS 中性是预期。definitive FPS（关 DRS + 掠地平线最大化 overdraw）归后续 F1 补测。详见 §8 Step 6。

## 6. 三入口

1. **automation（null RHI）**：`Voxia.Voxel.SvoPreview` 扩——按带 merge 系数区间、覆盖面积守恒、tier/cell 契约逐字不变、merge 前后 quad 单调下降落预算；per-cell greedy 核心单测。
2. **CLI（真实 RHI offscreen）**：merge vs `-VoxiaSvoFarNoMerge` 同机位 r72 默认 Lumen 的 quad/FPS/VRAM/build_ms A/B（对照 176FPS/1.39M 基线）。
3. **真实操作（可见 RHI）**：高空 overview + facing 巡航肉眼验无洞/无双显/无 merge 伪影。

## 7. 工程注意

- **merge 限 cell 内**——越 cell 破 tier/cell 契约且侵入覆盖性 seam 域；严守 cell 边界。
- **复用 `FVoxiaGreedyMesher` 注意近/远语义差**：近景 1m 均匀网格；远景是 SVO 变深度 leaf（同一 cell 内可能多深度叶）——mask 构造与坐标口径需适配，勿照搬。
- **merge 改 quad、A2 渲染管线承接不变**：合并后 mesh 仍走 PartitionedDynamicMesh 分组件 + StaticDraw + 剔除 + Unlit + bulk-hide；quad 降→组件 mesh 更小→显存/带宽/base-pass 均降。
- **本步不碰 raymarch/go-live GPU 路径**（生产终态默认关，见 A3 §9）；跑真实 RHI 沿用 A3.0 纪律（存活优先、崩后 nvidia-smi 确认恢复、绝不 `-gpucrashdebugging`）。
- **commit 拆分**：代码 commit 在 `clients/Voxia`；文档/进度 commit 在 `ex_mmo_cluster`；默认不 push。
- 引擎 `D:\UE\UE_5.8`；`Voxia.Build.cs` 保持 `bUseUnity=false`。

## 8. 进度日志

- 2026-07-07：建档。自 A3 §9 结项裁决迁出——A3.0 诊断证明 merge 与 far-mesh-go-live 崩溃正交、崩溃已由 raymarch-off 修复；本 phase 承接 merge 作纯几何/带宽优化，前提重写、验收矩阵去掉 device-removal 挂靠、换成对 raymarch-off 真基线（r72 默认 Lumen 176FPS/1.39M quad）的可测收益对照。scope（§3.1-3.4）、几何验收（§5.A）、决策项 D1/D2/D4/D5 自 A3 迁入；D3 作废。**尚未开工 merge 代码**（决策稿先行）。
- 2026-07-07（**D1 拍板 + 实现方案落定，开工 Step 1**）：读透 A3/A3b 决策稿 + 承重代码（`VoxiaGreedyMesher.{h,cpp}` 全量、`VoxiaSvoPreview.cpp` 远景 emit/artifact/seam 段）后拍板 **D1=(a)-核心复用**（详见 §9）；用户认同「不跨 depth」口径 = **不跨 ring/cell 边界**、cell 内变深度叶经共同 leaf-grid mask 合并（§7「同一 cell 内可能多深度叶…mask 需适配」佐证）。两仓已 pull（Voxia HEAD `2a9e21a`，含 `1fc93d2` raymarch-off，mesh 起点干净）；引擎自举 = `D:\Epic Games\UE_5.8`。**尚未改 merge 代码，先落本方案**。
- 2026-07-07（**Step 1 完成：抽 `MergeMaskRects` 核心 + 近景零回归绿**）：`VoxiaGreedyMesher.{h,cpp}` 抽出坐标无关 `MergeMaskRects(Keys,SizeU,SizeV,Emit)`（= 原 `BuildInternal` 内 228-282 扫描逐字同算法，参数化为矩形 `SizeU×SizeV`）；`BuildInternal` 改调它，近景 emit lambda 保留线性 `CellSize` 口径，每 `d` 层全量重填 `Mask`+`MaskKeys` 无残留态。**验证**：VoxiaEditor Win64 Development 编译 `Result: Succeeded`（37 动作、link 干净）；`Voxia.Voxel.GreedyMesher` automation（nullrhi）`Result={Success}`——单 cell 6 面 / 2-cell 合并成 6 / 邻剔成 5 / 混材质 10 / 冷热同材不合并 10 五不变量全过 → **近景零回归坐实**。代码未 commit（默认不 push）。
- 2026-07-07（**Step 2 完成：远景 collect + 逃生门 `-VoxiaSvoFarNoMerge`，零回归绿**）：`EmitSvoLeafSurface` 改为收集暴露面到 `FSvoFaceRec`（经 `Context.FaceSink` 可变指针，镜像 `ColumnCache` 范式），`MakeMacroCellArtifact` 递归后调 `EmitCellFaces`（Step 2 先逐面 replay = 旧路径逐字、顺序不变）；新增 `EmitFaceRec` 派发器（坐标口径唯一来源）。flag `bFarMergeEnabled`（默认 ON）全链路：config/result 字段 + `FSvoBuildContext` + result(1641)/context(1863) 流转 + **两处 `Same*Config` cache key**（`SameReusableSvoConfig` reuse 级 + `SameBuildConfig` build 级，merge on/off 同时失效两级缓存）；CLI `-VoxiaSvoFarNoMerge` 在 `VoxiaTransportSubsystem.cpp` 唯一 build Config 构造点解析。**§9.3 更正**：`VoxiaWorldActor` 不构造 build Config（`ShouldSkipSvoProxyMesh` 只做 actor 自身可见性门控），逃生门只需 transport 一处，非原稿列的两处。**验证**：编译 `Result: Succeeded`；`Voxia.Voxel` 全 18 测 `Result={Success}`（含 `SvoPreview`/`GoldenParity`/`FarField*`/`GreedyMesher`）→ collect+replay 逐字零回归坐实。代码未 commit。

### （进度续）Step 3
- 2026-07-07（**Step 3 完成：远景 per-cell masked greedy merge 落地，几何正确性绿**）：`EmitCellFaces` merge 分支实现——非 skirt 面按 `(Axis,Sign,平面)` 分组，每组 in-plane U/V 边界坐标压缩（**鲁棒于八叉树非均匀 Y 分割**，不假设均匀 leaf-grid）→ rasterize（key=MaterialId）→ 复用 Step 1 `MergeMaskRects` 合并 → synthetic `FSvoBounds` 经 `EmitFaceRec` 发射（坐标口径完全复用 `EmitSvoLeafFace*`）；skirt 边界面 v1 逐面 replay 不合并。新增 `FaceGroupCoords`/`EmitMergedRect`。**验证**（扩 `SvoPreview` automation 加 merge on/off A/B）：`Result={Success}`——合并严格减 quad（`A.QuadCount < NoMerge.QuadCount`）、**覆盖面积守恒**（∑三角形面积 merge-on == merge-off，1e-4 容差 = 视觉等价硬门槛）、pre-merge Top/Side/Boundary 计数两侧逐字相同、seam 两侧 `Mismatch/Duplicate/Missing==0`；`Voxia.Voxel` 全 18 测仍绿。代码未 commit。budget 实数（r72 1.39M→?）+ per-ring 带待 Step 4 可观测 + Step 5 多环 automation + Step 6 真实 RHI。

### （进度续）Step 4
- 2026-07-07（**Step 4 完成：per-ring 合并系数可观测落地，零回归绿**）：`FVoxiaSvoLodRingStats`（`VoxiaSvoPreview.h:52`）加 `int32 PreMergeQuadCount`（合并前逐面 `Top+Side` 口径）；`WhileTiles` 循环 `RingQuadCount` lambda（post，含 proxy-off 退化口径）后新增统一累加器 `AccumulateRingQuads(RingIndex,Artifact)`，把 **4 处累加点**（SourcePages 缓存命中 + reuse + artifact-cache 命中 + 新建）统一为「post(`RingQuadCount`) + pre(`Top+Side`)」并累；`SnapshotJson` per-ring 加 `pre_merge_quads` + `merge_ratio`(pre/post，除零守卫→1.0)，主 JSON 加 `pre_merge_quad_count`(`Result.Top+Side`=总量前) + `merge_enabled`(`Result.bFarMergeEnabled`)（总量后沿用既有 `quad_count`）。**口径要点**：pre 恒用逐面 `Top+Side`（非把 post 简写成 `QuadCount`）→ proxy-off 下 `Artifact.QuadCount` 可能为 0 时仍使 pre=post、ratio=1 语义正确；`merge_ratio` = pre/post 与 §5.A#2 除数同口径（L1 ÷2-4 即 ratio∈[2,4]）；merge 严限 cell 内 → per-cell pre/post 比值天然合法。**验证**：VoxiaEditor Win64 Development 编译 `Result: Succeeded`（24 TU，含 `VoxiaSvoPreview.cpp` + `VoxiaSvoPreviewAutomationTest.cpp`）；`Voxia.Voxel` 全 **18 测 `Result={Success}`、0 Fail、无 Error**（含 `SvoPreview` A/B + `GreedyMesher` + `GoldenParity` + `FarField*`）→ 加字段零回归坐实。**注**：per-ring/总量新字段的**值断言**（落带系数区间）归 Step 5 nullrhi automation；真实 RHI snapshot 实证归 Step 6（`svo` 命令走 `--visible-rhi`，Step 4 纯几何不碰 GPU）。代码未 commit（默认不 push）。

### （进度续）Step 5
- 2026-07-07（**Step 5 完成：多环预算/系数 automation + `MergeMaskRects` primitive 单测，全绿**）：新增 `Voxia.Voxel.SvoMergeBudget`（`VoxiaSvoMergeBudgetAutomationTest.cpp`）——r72 默认四环 merge-on/off A/B，先 `AddInfo` dump 实测再硬断言：契约绝对值（`macro_cell_count=21016`/`max_depth=4`/cells `280/2112/4160/14464`/depth `4/3/2/1`/outer `8/24/40/72`）+ per-ring 系数带（`RatioLow={2,2,1.2,1.2}` / `RatioHigh={4,3,2.5,2}`，L2.5 上界 2.0→2.5 吸纳合成场景合并率）+ 总预算 510k-840k + `merge.pre==no-merge.post` + 单调降 + 覆盖守恒 + seam；`MergeMaskRects` primitive 单测（`VoxiaGreedyMesherAutomationTest.cpp` block 6，8 形状：空/单格/整行/整列/满格/双key/棋盘/带洞，验覆盖守恒+不重叠+界内+同key）。**实测**（合成场景 seed 1337 r72）：merged **627293 quad**（raw 1318669，−52.4%），ratio L1 2.32/L2 2.23/L2.5 2.14/L3 1.69，契约逐字复现。**验证**：编译 `Result: Succeeded`（0 error）；`Voxia.Voxel` 全 **19 测 `Result={Success}`、0 Fail**（真实日志 `automation_full_step5_real.log` 坐实）。**口径认定**：§5.A#2 的绝对 quad（287082…）经 codex 取证 + Step 6 真实 RHI 双证=**生产场景**值（合成 raw 1.32M ≠ 生产 1.39M）→ automation 只硬断言场景无关量（契约/系数带/单调/守恒），绝对预算归 Step 6。代码未 commit。

### （进度续）Step 6
- 2026-07-07（**Step 6 完成：真实 RHI merge on/off A/B —— 几何/内存干净赢、FPS 中性且 Lumen-bound，如实记录不糊**）：4 次真实 RHI（`--real-rhi` offscreen，r72 默认 Lumen，`TileWindowRadius=0` 隔离近景，无 raymarch/无 backend override）**全存活、0 device-removal**（再证 raymarch-off go-live 在 r72 默认 Lumen 稳定）。**同机位 A/B**（同 pawn 位=CenterTile `macro(1234,-5678)`，`look -10/-35 yaw45`）：
  - **几何（§5.A，生产场景，干净赢）**：merge-ON quad **592,937** vs merge-OFF **1,388,647**（**−57.3%**）；pre-merge=1,388,647 + per-ring 逐字=§5.A#2（287082/570641/288904/242020）→ **坐实 §5.A#2=生产场景**；契约 21016/max_depth 4/seam pass 不变；merge-ON `build_ms 4948` < merge-OFF `5247`（面更少建更快）。
  - **FPS（§5.B，中性/混合，如实）**：@俯角-10 ON 130.98/OFF 123.78；@俯角-35 ON **77.93**/OFF **84.39**（OFF 反略快）。**判读**：DRS 作祟（两侧 `screen_percentage=77`，动态分辨率托帧、掩盖 GPU 开销差）+ Lumen 全屏 GI 主导（分辨率 bound 非几何 bound）→ 远景 quad 减半几乎不动 FPS。**与 A3.0 一致**（成本从来不是远景 overdraw 而是 raymarch+Lumen），**印证 A3b 定位=纯几何/带宽/内存优化，本就不挂靠 FPS**。
  - **VRAM/带宽**：mesh 顶点/索引缓冲 ≈ −57%（quad 比几何确定性）；干净绝对 VRAM 未抓（`runtime_gpu_bytes` 两侧同=20.5MB，仅 SVO buffer 不含 mesh）。
  - **裁决（§5.B「据此判 merge 是否值得保留」）**：**保留 merge**——几何/mesh 显存/上传带宽 −57%（确定性）+ build 更快 + 视觉等价（覆盖守恒+seam）+ 8GB 4060 Laptop 显存余量宝贵 + Lit-far(F1)/更大半径的前置；FPS 中性是预期且可接受，非失败。
  - **测量局限（留 F1 定量档补）**：DRS 未关（应 `-VoxiaSvoScreenPercentage=100`）；`far_visible` 遥测 offscreen 卡死=1（`CountVisibleSvoPartitionedComponents` POV 采集 bug，**不影响 FPS 有效性**——FPS 随俯角 131→78 剧变已证渲染跟随相机）；机位未最大化 far overdraw（掠地平线从地面）。definitive FPS 归 F1 Lit-far 一并跑。证据 `scratchpad/step6_*.log`。代码未 commit。

## 9. D1 落地方案（施工蓝图）

> 2026-07-07 拍板并经用户认同。所有 file:line 锚基于 `clients/Voxia@2a9e21a`（含 `1fc93d2` raymarch-off）。

### 9.1 D1 拍板：复用「贪心核心」，不复用 `FVoxiaGreedyMesher::Build` 整体

**否决整体套 `Build`**——三处语义差会破坏坐标口径 → 破视觉等价（正是 §7 警告的「照搬」）：

| 维度 | 近景 `FVoxiaGreedyMesher::Build`（`VoxiaGreedyMesher.cpp:287`） | 远景 SVO（`VoxiaSvoPreview.cpp`） | 冲突 |
| --- | --- | --- | --- |
| 网格 | 均匀 `Size³` 单元 + `SolidAt(gx,gy,gz)` 逐单元 | 变深度 leaf（7/14/28/56m 混一 cell，`FSvoBounds` 变尺寸） | 逐单元扫描口径对不上 |
| 坐标 | 线性 `CellSize` 三轴同构 | 水平 `MacroCm`（线性，`:22`）+ 垂直 `ProxyHeightCm=MacroCm-Sink`（仿射，`:27`）+ near-skip 边界 skirt 下探 `GVoxiaSvoBoundarySkirtMacros=24`（`:19`） | 套 `Build` 丢 sink/skirt → 破视觉等价 |
| 外观/剔除 | `SolidAt` 回调 + emergence shade 量化（`AppearanceKey` 27bit，`:17`） | `MaterialForBounds` 每 leaf 单材质（无 emergence 变化，走 `EmitQuad(...,uint16 Material)` 重载）+ `IsNearSkipBoundaryFace` 抑制（`:573`） | `Build` 无从表达 near-skip 语义 |

**复用清单**：
1. **`EmitQuad`（`VoxiaGreedyMesher.cpp:48/134`）——已在复用**（远景 `EmitSvoLeafFaceX/Z/Top/Bottom`，`VoxiaSvoPreview.cpp:624/646/666/686` 全转调它）。merged quad 仍经它发射，绕线/顶点色/UV 口径与近景逐字一致。
2. **贪心 mask-sweep 核心（`VoxiaGreedyMesher.cpp:228-282` 最大矩形扫描）——抽成坐标无关共享 primitive** `MergeMaskRects(const TArray<int64>& Keys, int32 SizeU, int32 SizeV, TFunctionRef<void(int32 i,int32 j,int32 W,int32 H,int64 Key)> Emit)`。近景 `BuildInternal` 改调它（零回归自证），远景建自己的 per-plane mask 也调它。
3. **`AppearanceKey` 思路复用，远景 key 更简单**：纯 `MaterialId`（+ 侧面 skirt 竖直 extent），无需 emergence 量化。

### 9.2 关键事实锚点

- 常量：`VoxiaMacroSizeCm=100cm=1m`（`VoxiaCoords.h:11`）；`VoxiaChunkSizeInMacro=16`（`:13`）；`VoxiaTileSizeInChunks=7`（`VoxiaTileWindow.h:9`）→ `GVoxiaSvoTileMacros=112`（`VoxiaSvoPreview.cpp:13`）。∴ 单 macro cell(tile)=112×112 macro 足迹；leaf 尺寸 7/14/28/56m = depth 4/3/2/1；**leaf-grid 分辨率 = `2^MaxDepth`（≤16）/轴**。
- **插入点**：`MakeMacroCellArtifact`（`:1350`）在 `BuildOccupancySvoNode`（`:787`）后、`Artifact.Mesh = MoveTemp(CellResult.Mesh)`（`:1375`）与 `Artifact.QuadCount = Mesh.QuadCount()`（`:1376`）前——严格 per-macro-cell、cell 内。
- **pre/post merge 计数天然可观测、无需新前值管线**：`TopQuadCount+SideQuadCount`（逐面累加，`:715/729/…/769/778`）= 合并前；`Mesh.QuadCount()` = 合并后。
- **seam_check 兼容**（`RunSvoSeamCheck`,`:1504`）：① 重复面检测（`:1523`）是安全网（merge 只减面不造重复）；② 一致性用 post-merge `Σ Artifact.Mesh.QuadCount() == Out.Mesh.QuadCount()`（`:1579`）两侧同步不打架。
- **垂直合并精确性**：`ProxyHeightCm` 仿射 → 合并竖直矩形面积守恒精确（覆盖守恒断言可硬门槛化，D2=c）。

### 9.3 施工 step（每 step：`mix format`/编译 + 最小测试 + 进度日志；默认不 push；代码 commit 在 `clients/Voxia`、文档在 `ex_mmo_cluster`）

- **Step 1 抽核心 + 近景零回归**：抽 `MergeMaskRects` primitive（`VoxiaGreedyMesher.{h,cpp}`）；`BuildInternal` 改调它。跑 `VoxiaGreedyMesherAutomationTest` 全绿证明近景逐字不变。
- **Step 2 远景 collect + 逃生门**：`EmitSvoLeafSurface` 改为收集 exposed face 记录（`{axis,sign,planeIndex,uv extent(macro),material,skirt}`）到 per-cell face list；`Top/Side/Boundary` 计数保留不动。加 `FVoxiaSvoBuildConfig::bFarMergeEnabled`(默认 ON) + CLI `-VoxiaSvoFarNoMerge`——**镜像 `bBuildProxyMesh` 接线**（`VoxiaWorldActor.cpp:120` / `VoxiaTransportSubsystem.cpp:2481` / `NormalizeConfig` / `SameBuildConfig` 1331+2640 / Result 1641 流转）。**铁律：merge flag 必进 cache key（`SameBuildConfig`），否则 A/B 不重建**。NoMerge → 逐面 emit 走今天路径（保 A/B 语义一致）。
- **Step 3 远景 merge+emit**：插入点(§9.2)对 face list 按 `(axis,sign,planeIndex)` 分组 → 建 leaf-grid mask（≤16×16）→ 调 `MergeMaskRects` → 经 `EmitSvoLeafFaceX/Z/Top/Bottom` 发 merged quad（坐标口径原样复用）。**skirt 边界面 v1 保守**：key 含 `(material,Ybottom,Ytop)` 只同 extent 合并，或先不合并（`BoundarySideQuadCount` 是少数；预算够则 v1 不合并、v2 再优化）。gate = `bBuildProxyMesh && bFarMergeEnabled`。
- **Step 4 可观测（§3.2）**：`FVoxiaSvoLodRingStats` 加 pre/post merge quad + 系数；`SnapshotJson` 加 `merge_enabled` + per-ring 前后比 + 总量前后。
- **Step 5 automation（§3.4）**：扩 `Voxia.Voxel.SvoPreview`——按带系数落区间（§5.A #2）、覆盖面积守恒（D2=c 硬门槛）、契约逐字不变（§5.A #3）、merge 前后单调下降落预算；`MergeMaskRects` primitive 单测。
- **Step 6 真实 RHI A/B（§5.B）**：merge-on vs `-VoxiaSvoFarNoMerge` 同 r72 默认 Lumen 同机位，quad/FPS/VRAM/build_ms 对照 176.5FPS/1.39M 基线；幅度实测标定不预设；存活纪律（崩后 `nvidia-smi` 确认恢复、绝不 `-gpucrashdebugging`）。

### 9.4 环境自举（本机）

- 引擎：`D:\Epic Games\UE_5.8`（`Engine\Build\BatchFiles\Build.bat`）。编译：`Build.bat VoxiaEditor Win64 Development -project=<abs>\clients\Voxia\Voxia.uproject -waitmutex`（`bUseUnity=false` 勿改回）。
- 几何层验证优先 nullrhi automation（GPU 无关、快）：`node clients/Voxia/scripts/voxia_stdio_cli.js --nullrhi ...`；真实 RHI 收益对照才 `--real-rhi`。
- **automation 单测命令（自包含、无需服务器，本项目实测跑法）**：
  `& "D:\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" "<abs>\clients\Voxia\Voxia.uproject" -nullrhi -unattended -nopause -nosplash -NoLiveCoding -ExecCmds="Automation RunTests Voxia.Voxel; Quit" -TestExit="Automation Test Queue Empty" -abslog="<log>"` → 日志 grep `Result={Success}` / `Result={Fail}`、`LogAutomationController: Error`。

## 10. 会话交接状态（2026-07-07，Step 6 结束 = A3b 主体收官，剩 F1–F7 后续议题）

> 本节供新会话无上下文接手。所有改动**未 commit / 未 push**（遵纪律「默认不 push」）。

### 10.1 已完成 + 验证绿（Step 0–6）
- **Step 0**：D1 拍板 + §9 施工蓝图 + §8 进度日志（本文件）。
- **Step 1**：抽坐标无关 `FVoxiaGreedyMesher::MergeMaskRects`（`VoxiaGreedyMesher.{h,cpp}`）；`BuildInternal` 改调它。验证：编译 `Succeeded` + `Voxia.Voxel.GreedyMesher` 五不变量绿 = 近景零回归。
- **Step 2**：`EmitSvoLeafSurface` 改收集 `FSvoFaceRec`（`Context.FaceSink`）；`MakeMacroCellArtifact` 递归后 `EmitCellFaces`（先逐面 replay）；`EmitFaceRec` 派发器。flag `bFarMergeEnabled`（默认 ON）全链路 + **两处 `Same*Config` cache key** + CLI `-VoxiaSvoFarNoMerge`（仅 `VoxiaTransportSubsystem.cpp` 一处）。验证：编译 + `Voxia.Voxel` 全 18 测绿（含 GoldenParity）= collect+replay 逐字零回归。
- **Step 3**：`EmitCellFaces` merge 分支——(Axis,Sign,平面) 分组 + 坐标压缩 + `MergeMaskRects` + synthetic Bounds 发射；skirt 面逐面。`FaceGroupCoords`/`EmitMergedRect`。验证：`SvoPreview` automation 扩 merge on/off A/B `Result={Success}`——严格减 quad + **覆盖面积守恒**（∑三角形面积 1e-4 容差）+ pre-merge 计数两侧逐字同 + seam 两侧 0。
- **Step 4**：per-ring 合并系数可观测——`FVoxiaSvoLodRingStats.PreMergeQuadCount`（合并前逐面 Top+Side）+ `AccumulateRingQuads` 把 4 处累加点统一为 post(`RingQuadCount`)+pre(`Top+Side`) 并累 + `SnapshotJson` per-ring `pre_merge_quads`/`merge_ratio`(pre/post) + 主 JSON `pre_merge_quad_count`/`merge_enabled`。验证：编译 `Succeeded`（24 TU）+ `Voxia.Voxel` 全 18 测 `Result={Success}` 0 Fail = 加字段零回归。
- **Step 5**：新增 `Voxia.Voxel.SvoMergeBudget`（r72 四环 A/B：契约绝对值 + per-ring 系数带 + 总预算 510k-840k + 单调降 + 覆盖守恒 + seam）+ `MergeMaskRects` primitive 单测（8 形状）。验证：编译 `Succeeded` + `Voxia.Voxel` 全 **19 测绿**（真实日志坐实）；实测合成 r72 merged 627293（−52.4%）。
- **Step 6**：真实 RHI merge on/off A/B（4 跑全存活 0 device-removal）。**几何生产场景 −57.3%**（592937 vs 1388647，per-ring 逐字=§5.A#2、契约/seam 不变、build 更快）；**FPS 中性**（DRS+Lumen 混淆，远景非 FPS 瓶颈——印证 A3b=几何/带宽/内存优化）；裁决**保留 merge**。定量 FPS/Lit-far 归 F1。

### 10.2 未提交改动面（HEAD = `clients/Voxia@2a9e21a`）
- **clients/Voxia（代码仓，未 commit）**：`Source/Voxia/Voxel/VoxiaGreedyMesher.{h,cpp}`（Step 1）、`Source/Voxia/Voxel/VoxiaSvoPreview.{h,cpp}`（Step 2/3/4）、`Source/Voxia/Net/VoxiaTransportSubsystem.cpp`（Step 2 逃生门）、`Source/Voxia/Voxel/VoxiaSvoPreviewAutomationTest.cpp`（Step 3 A/B）、`Source/Voxia/Voxel/VoxiaSvoMergeBudgetAutomationTest.cpp`（**Step 5 新增**）、`Source/Voxia/Voxel/VoxiaGreedyMesherAutomationTest.cpp`（**Step 5** primitive 单测 block 6）。Step 6 只跑真实 RHI，**无代码改动**。
- **ex_mmo_cluster（文档仓，未 commit）**：本决策稿 + `2026-07-07-voxia-render-pipeline-camera-lod.md`（渲染管线研究 + F1–F7 开放议题登记表）。

### 10.3 剩余工作（Step 0–6 已完成；下一会话从这里接）
> A3b 主体（几何优化 + automation + 真实 RHI A/B）已收官。剩余全部是 §8 登记的**后续议题**，非 A3b 核心。
- **F1（定量补测）DRS-off definitive FPS + Lit-far**：Step 6 的 FPS 被 DRS(77%)+Lumen 混淆、未给干净数。补一对 `-VoxiaSvoScreenPercentage=100`（关 DRS）+ 掠地平线从地面（最大化 far overdraw）的 merge on/off，并叠 `-VoxiaSvoFarLitMaterial`——definitive 回答"FPS 到底动不动 + Lit-far 消色差代价"。**机位铁律沿用**（同 pawn 位=CenterTile；除受测 flag 外命令行一致；**绝不带 `-VoxiaSvoRaymarch*` / `-VoxiaSvoRenderBackend=`**）；存活纪律（崩后 `nvidia-smi` 确认恢复、绝不 `-gpucrashdebugging`）。
- **F3 环界裂缝 / F4 剔除实证**：任意真实 RHI 巡航顺带肉眼看——F3 查 d4↔d3 裂缝/T-junction；F4 侧/背视确认 `far_visible < far_component`（注意 offscreen 该遥测有 bug、卡死=1，须用 `--visible-rhi`）。
- **开放议题登记表**见 [`2026-07-07-voxia-render-pipeline-camera-lod.md`](2026-07-07-voxia-render-pipeline-camera-lod.md) §8（F1 近/远光照色差、F2 emergence 缝、F3 环界裂缝、F4 剔除实证、F5 服务器 CenterTile 来源、F6 bStaticBakeReady 设计债、F7 头注释清理）——**讨论沉淀的待办，不随对话消散**；Step 6 后按优先级推进。

### 10.4 铁律提醒（动手前复核）
- merge **严格限 cell 内**（不跨 cell / 不跨 ring depth）；tier/cell 契约逐字不变；不重开 raymarch（生产终态默认关）；不动 A2 管线；中文注释；默认不 push。
