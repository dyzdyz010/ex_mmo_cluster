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
| D1 | merge 实现 | (a) 复用/扩展 `FVoxiaGreedyMesher`，抽 cell 内 masked greedy 核心适配 SVO 变深度 leaf；(b) 远景 SVO 专用新 merge | **(a) 优先复用**；语义差异大到无法复用再 (b) |
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
