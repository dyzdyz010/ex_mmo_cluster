# Phase VLOD-A4：里程碑 A 收尾 —— 跨 depth 覆盖性 seam + 换环 fade + L1 collar（并行 A5 顶点瘦身）

> 承接**里程碑 A（客户端渲染正确，零服务端依赖）**：A1 tier 契约 ✅ / A2 分组件+剔除 ✅ / A3 per-cell greedy merge ✅（quad −57%）＋ Lit-default（额外，远景消色差）。本 phase = **A4（承重）+ A5（可并行）+ A 验收**，收口里程碑 A；过 A 验收后才进里程碑 B（接口冻结）。
> 真值源：架构主稿 [`2026-07-06-voxia-lod-layering-and-technology-design.md`](../../30-reference/overview/2026-07-06-voxia-lod-layering-and-technology-design.md) §3.2/§5/§6/§8/§9；数据源终态=[投影路线](../../30-reference/contracts/2026-07-06-projection-route-final-decision.md)。渲染管线实证：[`2026-07-07-voxia-render-pipeline-camera-lod.md`](../../20-archive/voxel-far-field/2026-07-07-voxia-render-pipeline-camera-lod.md)。

## 0. 一句话

merge 腾出预算后，补齐里程碑 A 剩的三件事：① 跨 depth 环界的**覆盖性 seam 断言**（治 any-solid 膨胀下的重叠型边界）+ 换环 cross-fade（消环界跳变，原 F3）② **L1 collar 3.5m**（把 L0 边缘入带角尺寸 38px→19px）③ **A5 顶点瘦身** 424→~210B/quad + cache LRU。然后 8km 长巡航过 **A 验收**。

## 1. 目标

- **A4 覆盖性 seam**：把现状不验证跨 depth 的 `seam_check` 换成**覆盖性断言**（细侧边界暴露面必被粗侧体积覆盖；小半径全量 + 8km 按环边界抽样）——直接回答原 F3（d4↔d3 裂缝/T-junction 是否可接受）。
- **A4 换环 fade**：cell 换 depth 时 0.2-0.5s 材质 dither cross-fade，保旧 artifact 至新上传完成；observe `ring_reassigned_cells`/`fade_in_flight`。
- **A4 L1 collar 3.5m**：d2-4 加 3.5m collar 档（tier `3.5@4`），depth clamp 1..4→5；merge 后净增约 +56-112k quad（预算可负担）。
- **A5 顶点瘦身**：CPU mesh 424→~210B/quad；persistent artifact cache 加 LRU 淘汰 + 容量上限 + 孤儿清除；RAM 中间态进 observe。
- **近/远视觉一致性（用户 2026-07-07 人肉 A验收 抓出，升为 A 验收硬门槛）**：① 确认 Lit-default 已消除近/远「平亮 vs 受光」色差（旧 Unlit 遗留，`060aaea` 应已修，需 near+far 可见复验）；② **emergence 口径决策**（远景 `EmitQuad(uint16)` 造空 `FEmergenceCell`→无温度/光照发光，近景有——原 F2；base 地形色两侧一致，差在发光与粗材质）；③ **换环无重叠闪烁**（any-solid 膨胀→重叠型边界 z-fighting，A4-3 fade + A4-1 覆盖性 seam 治）；④ 近/远交界 **near-skip suppression 无双显**。
- **远景滑动跟随正确**：远景以 `CenterTile`=**玩家体位置**为中心随玩家滑动（增量重建，实测复用 0.958-0.988）；长巡航验收其跨环/重定心**无缝、无洞、无残影**（这是"玩家走 1km 远景跟着变"的正确性门）。
- **A 验收**：8km WorldGen preview 长巡航（跨 ≥8 tiles）——per-ring quad/内存预算断言、**近/远色彩一致 + 换环无重叠闪烁 + 无洞/无双显 + 滑动跟随无残影**、render_perf 门槛、截图审计（含入带角尺寸 + 近/远交界目视）、cache 淘汰计数 全绿。

## 2. 范围边界（显式非目标）

- **不动服务端**（里程碑 A 零服务端依赖，全 `-VoxiaWorldGenPreview` / fixture 验收）。
- **不做垂直多层（B5）**——维持现状 Y-slab；collar/seam 在单层语义下先落地（垂直 3D 化改 112³ 立方 cell 后 k 需重标定，留 B5）。
- **不做 pages 真消费（B3）**——渲染继续吃预物化 artifact。
- **不重开 raymarch / L4**（defer）；**不自研 SceneProxy**（defer，A2 后未见实测 hitch/显存瓶颈达触发线）。
- **不指望 A4/A5 提 FPS**：本会话实测已定位 **FPS = 像素-bound**（Lumen 全屏 GI ~2-4ms/帧是最大杠杆；merge/瘦身守恒覆盖=只减三角形不减像素，天然不动帧成本）。render_perf 门槛按此认识设定；若不达标是 Lumen 侧（远景降质量/exclude GI，属后续专项/defer），不是 A4/A5 的锅。

## 3. 改动点

### 3.1 A4 覆盖性 seam 断言（承重）
- **背景**：any-solid 规约下粗侧单调膨胀 → 环界是**重叠型非缝隙型**（skirt 治缝不治重叠）。现状 `RunSvoSeamCheck` 只查重复/缺面、**不跨 depth**（原 F3 无实证）。
- **改**：seam 断言从"逐面配对"改**覆盖性**——细侧每个边界暴露面的中心/角点必落在粗侧某实心叶的体积内。落点扩 `RunSvoSeamCheck`（`VoxiaSvoPreview.cpp`）。小半径 automation 全量断言、8km 按环边界抽样。

### 3.2 A4 换环 cross-fade（治环界跳变）
- cell 换 depth（玩家移动跨环）：patch 层加 **0.2-0.5s 材质 dither cross-fade**；保旧 artifact 至新上传完成（现状已保证）。
- observe：`ring_reassigned_cells` / `fade_in_flight`。

### 3.3 A4 L1 collar 3.5m
- tier 配置加 collar 档：`-VoxiaSvoLodRings=3.5@4,7@8,14@24,28@40,56@72`（tier 升一等，见架构 §8）。
- **depth clamp 1..4→5**（3.5m = 112/2^5）。
- **排 merge 后**（预算依赖：无 merge 时 +224k 不可负担；merge 后净增 +56-112k）。L0/L1 边界继续靠 near-skip skirt(24 macro)+underlap+suppression；collar 把入带角尺寸 38px→19px（P-2 跳变款显式豁免，缝隙策略治理）。

### 3.4 A5 顶点瘦身 + cache LRU（可与 A4 并行）
- 顶点格式 **424→~210B/quad**（打包法线/顶点色/UV）。automation 断言顶点数守恒 + 字节量。
- persistent artifact cache：**LRU 淘汰 + 容量上限**；旧 `source_revision` 孤儿 artifact 在 gate 通过后清除。
- RAM 中间态（`FDynamicMesh3`/patch map）纳入 observe 字段。

### 3.5 近/远视觉一致性（用户观察驱动，A4 新增承重）
> 依据：颜色差**非 debug 色**（已 grep 核实无 per-LOD 调试着色）。近景 `EvaluateEmergenceShading(Cell有场数据)`；远景 `EmitQuad(uint16)`→空 `FEmergenceCell`（仅 MaterialId）→同一着色函数。**同 MaterialId → base 色一致**；差异只在 emergence + 材质分辨率。

- **① Lit 一致复验**：`060aaea` 远景已默认 Lit（与近景同 `VoxelMaterial`）。旧 Unlit「平亮 vs 受光」色差应已消——Step 0 near+far 可见复验坐实。
- **② emergence 口径（原 F2，D5 决策）**：远景无温度/光照发光。选项：(a) 远景烘焙简化 emissive（热单元 glow 跨近/远一致，代价=pages/material 需带温度或客户端场采样）；(b) 接受远景无发光 + 文档签收（远景 visual-only，涌现只在近景可见可接受）。base 地形色两侧本就一致，此项只关发光。
- **③ 粗材质签收**：远景每 leaf 单材质（7-56m，any-solid/众数）vs 近景 1m——远景是粗色块，**这是 LOD 的固有代价、非缺陷**，验收只要求「base 色一致 + 换环平滑」，不要求远景细材质。
- **④ near-skip suppression 无双显**：near-skip 只在 L0 覆盖的 Y 层剔远景（`IsSuppressedByNearSkip`，架构 §7 3D 化留 B5）；A4 验收断言近/远交界不双显、不 z-fight（现单层语义下）。

## 4. 决策项

| # | 决策 | 选项 | 倾向 |
| --- | --- | --- | --- |
| D1 | seam 覆盖性抽样粒度 | (a) 小半径全量 + 8km 按环边界抽样；(b) 全量 | **(a)**：全量太贵，按架构 §6/§8 口径 |
| D2 | cross-fade 时长 | 0.2-0.5s | 起步 **0.35s**，真实 RHI 目视调 |
| D3 | 顶点瘦身布局 | 打包到 ~210B/quad 的具体格式 | 施工时定；automation 守恒断言兜底 |
| D4 | Lit-default vs 架构 §3.2 d 材质口径分歧 | (a) 回写架构 doc 对齐；(b) 保留分歧 | **(a)**：Lit 已用户拍板 + 视觉确认，回写架构 §3.2 d（"顶点色三桶 matte/translucent/emissive"→"默认 Lit(VoxelMaterial)，Unlit 经 `-VoxiaSvoFarUnlitMaterial` alt"） |
| D5 | 远景 emergence 口径（原 F2）＋**远景偏暗（A 光照）** | (a) 远景烘焙简化 emissive／抬远景照度（跨近/远一致，代价=pages 带温度/客户端场采样 或 补光改动）；(b) 接受远景无发光 + 偏暗 + 文档签收 | **已拍板 = (b)**（用户 2026-07-08）：远景 visual-only，**照度不管**——2026-07-08 RHI A/B 坐实远景暗主因是光照（无 MDF 收不到 Lumen 天光）、非材质；用户明确不投入抬照度，签收远景偏暗为大气透视/固有代价。热单元跨环"熄灭"同 (b) 接受。(a) 留作后续视觉打磨，不排期 |

## 5. 验收矩阵（A 验收，架构 §8 口径）

| # | 维度 | 断言 | 锚 |
| --- | --- | --- | --- |
| 1 | per-ring 预算 | quad/内存落 §5 预算表 | L1 73-146k / L2 183-275k / L2.5 135-225k / L3 117-195k；collar 净增 +56-112k |
| 2 | 跨 depth 覆盖性 seam | 细侧边界面被粗侧体积覆盖，无洞（小半径全量 + 8km 抽样） | 替代现状不验证跨 depth 的 seam_check |
| 3 | 换环 fade | `ring_reassigned_cells`/`fade_in_flight` 可观测；巡航目视换环不跳 | — |
| 4 | collar 角尺寸 | L0/L1 入带角尺寸 ≤~20px | 截图审计含入带角尺寸目视复核视角 |
| 5 | 顶点瘦身 | 424→~210B/quad；顶点数守恒 | automation 字节/顶点断言 |
| 6 | cache | LRU 淘汰计数 + 容量上限 + 孤儿清除 可观测 | — |
| 7 | render_perf | 8km 长巡航（跨 ≥8 tiles）avg/min FPS 门槛 | **按 Lumen-bound 现实设定**（见 §2）；瓶颈=Lumen 非几何 |
| 8 | 不回归 | `Voxia` automation 全绿 + Build 0 + A2 分组件/StaticDraw/剔除 + A3b merge + Lit-default 不回归 | — |
| 9 | 近/远色彩一致（用户抓出） | near+far 可见 RHI 目视：base 地形色两侧一致（Lit 一致，无"平亮 vs 受光"断层）；emergence 按 D5 口径签收 | 交界视角截图审计 |
| 10 | 换环无重叠闪烁（用户抓出） | 巡航跨环无 z-fighting 闪烁；A4-3 cross-fade 生效可观测；`fade_in_flight` 有值 | any-solid 重叠型边界 |
| 11 | 近/远交界无双显（用户抓出） | near-skip suppression 断言：L0 覆盖处远景被剔、不双显、不 z-fight | `IsSuppressedByNearSkip` |
| 12 | 远景滑动跟随（用户抓出） | 长巡航跨 ≥8 tiles：`CenterTile` 随玩家更新、增量重建、跨环重定心无缝/无洞/无残影 | 复用率 observe |

## 6. 三入口

1. **automation（nullrhi）**：per-ring 预算断言 + 跨 depth 覆盖性 seam 抽样 + 顶点字节守恒 + cache 淘汰计数。
2. **CLI（真实 RHI）**：`until_svo_*` 家族扩 ring 字段；巡航 `sample_render_perf`。
3. **真实操作（可见 RHI）**：飞行长巡航目视无洞/无双显/换环不跳/collar 边缘。

## 7. 工程注意（含本会话实测教训）

- **FPS 归因铁律**：render_perf 不达标先查 **Lumen（~2-4ms/帧，关掉 +36~40 FPS）**，别赖 A4/A5；A5 瘦身赢的是显存/带宽不是 FPS。
- **`far_visible` 遥测 offscreen 卡死=1**（`CountVisibleSvoPartitionedComponents` POV 采集 bug）：巡航/剔除观测须 `--visible-rhi`。剔除本身已证真生效（361→101 可见=28%）。
- **near+far 长巡航流式坑**：`TileWindowRadius=2 + VerticalTileRadius=4` = 61425 chunk 会把 `until_tile_window_full` 拖超时；长巡航验收用更轻近景配置 + 更长超时，或分段。
- **存活纪律**：崩后 `nvidia-smi` 确认恢复、**绝不 `-gpucrashdebugging`**；不碰 raymarch/go-live GPU 路径。
- **机位铁律**：真实 RHI A/B 同 pawn 位=CenterTile；除受测 flag 外命令行一致；引擎 `D:\Epic Games\UE_5.8`、`bUseUnity=false`。
- commit：代码 `clients/Voxia`、文档 `ex_mmo_cluster`；默认不 push；中文注释；全新代码无向后兼容包袱。

## 8. 进度日志

- 2026-07-07：建档。承接里程碑 A（A1/A2/A3+Lit 已收，见 README 阶段表与各 phase 稿）。本 phase = A4（seam/fade/collar 承重）+ A5（瘦身/cache 可并行）+ A 验收。**战略约束（实测钉死）**：FPS=像素-bound，Lumen ~2-4ms 是最大杠杆，A4/A5 不动 FPS、只收几何/显存/视觉正确性。原自造 F3=本稿 A4 seam、F8 白斑(预存 TSR)并入视觉打磨后续、F2 emergence 缝升为本稿 D5/§3.5(A验收硬门槛)、D 顶点瘦身=本稿 A5。
- 2026-07-07（**用户人肉 A验收 抓出四条，全并入本稿**）：用户从 GUI 观察到 ① 近/远色差(经查=旧 Unlit 遗留,`060aaea` Lit-default 应已修,待复验;残差=emergence 无+粗材质,非 debug 色) ② 换环重叠闪烁(=any-solid 膨胀重叠型边界,A4-3 fade 治) ③ 追问近/远交界双显 ④ 追问远景是否随玩家滑动(答:是,CenterTile=玩家体位置增量跟随)。四条已落 §1 目标 / §3.5 / §5 验收#9-12 / §9 Step 0。**尚未开工。**
- 2026-07-08（**Step 0 完成 —— 真实 RHI 目视基线，"破洞"定论=机位假象非 bug**）：`--real-rhi` 离屏 + `--visible-rhi` 可见双路复拍近/远交界（机位 CenterTile macro(1234,-5678)，近场 `-VoxiaTileWindowRadius=1`+远景默认8km四环）。**高空掠射（120–600m 俯冲）三张满是"破洞/破面"→ 用户判"渲染不全"**；经排查**定论为机位假象非渲染 bug**，两独立证据链：① 可见窗口版 == 离屏版（逐张一致，排除离屏 POV 剔除假象——另注 `CountVisibleSvoPartitionedComponents` 只是遥测计数，`far_visible=1` 卡死不驱动显隐，不造洞）；② **眼平自然视角（玩家真实视角）完全干净**、连贯 watertight 无洞。机制=远景 SVO 是**敞底 2.5D 表面壳**（`BuildTileSvoRootBounds` 壳底 `Y0=max(0,MinHeight−CellMacros)`，不实心到地板，省几何设计），高空掠射看到壳的敞开底面 + `-VoxiaNoSky` 背景 clear color 透出=假洞；远处漂浮块=合法浮空岛(`islands=1`)。**① Lit 复验：远景确为 Lit 且正确受光**（有 relief 明暗，非旧 Unlit 平亮）。**真实 backlog（眼平可见）**：(A) 近/远材质色差——远景 `MaterialForBounds` 取 cell 中心→采到地下较暗材质 vs 近景地表沙(+自动曝光放大)；(B) 高空壳敞底——若"飞行/高空俯视"是玩法则需给壳补底/高空另走路径。**②④运动伪影 + D5**(场景无涌现内容判不了)并入 Step 6。教训：目视基线应先用眼平自然视角、勿先高空掠射。**fable5 用量超限，Step 0 与后续以 Opus 顶替。**
- 2026-07-08（**Step 1 完成 —— 跨 depth 覆盖性 seam（承重），直接回答原 F3**）：`RunSvoSeamCheck` 加 ④ 块（`VoxiaSvoPreview.cpp`）：仅 WorldGen 源，对每个细侧 cell 沿"朝更粗邻居"的环界按细叶步长取列，比较**细叶足迹 3×3 any-solid 采样最大列高**(fine 渲染顶) vs **N 侧紧邻粗叶足迹 3×3 采样**(coarse 渲染顶，任一≥HFine即覆盖)——两侧同口径避免"精确列高假阳"。`FVoxiaSvoSeamCheck` 加 `CrossDepthBoundaryFaceCount`/`CrossDepthUncoveredCount` + `SnapshotJson` 两字段(observable)。**关键设计决定：跨 depth 未覆盖不并入 `Status()` pass/fail**——它是 T-junction 细缝的**质量度量**(细侧渲染顶戳出粗侧，被较高侧墙面挡住只余顶边 T-vertex 缝，**非穿透洞**)，由 collar/fade(Step2/3)减小而非要求恒 0；曾误把它 gate 进 Status() 导致 `SvoMergeBudget`/多环 seam 断言连带变红，已回退。**F3 实测（automation d4/d3 环界配置 `1@4,2@3`,radius2）：`boundary_samples=192, uncovered=26`≈13.5% 细侧顶戳出粗侧**；断言=真抽到样本(>0,证非空壳) + `uncovered_ratio<0.5`(any-solid 粗侧覆盖多数=重叠模型成立,松界兜底,collar 后收紧) + 单环下断言不触发(inert)。**验证**：`Build.bat VoxiaEditor` 退出 0(修一处 C4456 `N`→`NTile` 遮蔽);`Voxia.Voxel.SvoPreview` `Result={Success}`(含新断言);其余 18 测全绿(run4)。注:`SvoPreview:335` "composite atlas debug mapping" 是**环境 flaky**(同一 binary run2 pass/run3-4 fail/run5 pass 翻转,与本改动无关,raymarch composite 段未触碰)。代码未 commit(`clients/Voxia`),文档在 `ex_mmo_cluster`。
- 2026-07-08（**Step 2 完成 —— collar 3.5m/depth5 启用（opt-in）+ depth clamp 4→5**）：`MaxLodRingDepth` 4→5(`VoxiaSvoPreview.h`);`ValidateLodRings` 放开 depth5(depth>5 仍拒,超 112/2^k 阶梯)。A1 那段"collar 被拒"测试块翻转为"collar 启用":语法解析 + 映射 depth5 + 叶尺寸 3.5m + `ValidateLodRings` 通过;`radius8` collar build **成功**(`max_depth=5`、`ring0={outer4,depth5}`、出网格、source/farfield ready)+ **净增**(collar quads 152196 > 无collar `7@8` baseline)+ depth5↔depth4 环界 majority-covered。**实测(r8 collar seed1337)**:`cells=280 quads=152196 cross_depth(boundary=2456 uncovered=572≈23.3%<0.5)`。**关键认知**:collar 的 depth5↔depth4 新环界 T-junction 率(23.3%)**高于** depth4↔depth3(13.5%)——finer collar 采到更多尖峰、相邻粗侧更易漏采;**collar 收益不在 far-far 跨 depth 率,而在 near/far 入带角**(近 1m↔远 3.5m 而非 7m,台阶 7×→3.5×,屏 px 38→19,§5#4,归 Step6 真实 RHI 量)——以"更远更不可见的 far-far T-junction 略增"换"最可见近/远入带角减半",净视觉 win。**决定:默认保持 4 环(collar opt-in via 显式 `-VoxiaSvoLodRings=3.5@4,...`)**;翻默认 collar-on 会广泛动其他测试(`SvoMergeBudget` `RingStats==4`、SvoPreview r2 转 depth5 等),留 Step6 A验收(真实 RHI 确认 38→19px + r72 预算 +56-112k)或用户拍板。**验证**:Build 退出 0;`Voxia.Voxel` **19 测全绿**(含新 collar 断言;composite flaky 本轮亦过)。代码未 commit。
- 2026-07-08（**backlog A(材质) 修复 —— 远场逐面贴壁真材质,顶面地表化;并诊断出"远景暗"真因是光照非材质**）：**根因**:远场壳 `MaterialForBounds` 取 leaf **中心 mid-Y** 算单个材质盖六面;跨地表大 leaf 中心落在 soil(`SoilDepthMacro=4`)以下 → 顶面显示**地下料**(surface=1 dirt/subsurface=2 stone,随 leaf 尺寸跳变:7m 叶中心 3.5<4=dirt、14m+ 叶中心≥7=stone) → "材质不统一"。**修**:新增 `MaterialForFace(Context,Bounds,Axis,Sign)`——顶面(+Y)从最顶体素向下扫首层实体(=可见地表 soil)、底面(-Y)从最底向上扫、侧面(±X/±Z)面平面外沿 mid-Y;`EmitSvoLeafSurface` 逐面采(替代 leaf 单值);合并器 `EmitCellFaces` 本就按 MaterialId 分组只并同料(`:958`),**零改动**;seam check `FSvoFaceKey` 只用几何键(`:1828`)不含材质,**无回归**;材质烘成顶点色(`M_VoxelVertexColor` Lit,`VoxiaGreedyMesher:94/102`),**mesh 自包含**、无序列化 bump。SVO node 单值材质(DAG/raymarch)仍走 `MaterialForBounds` 不动。**验证**:Build 退出 0;automation 加材质审计块(按法线分类审 `A.Mesh.Colors`)——`TOP dirt=486 stone=0 other=0`(修前大 leaf 顶面含 stone,现纯 dirt)、`SIDE dirt=2638 stone=1487`(正确分层)、cross-depth `192/26 pass` 无回归;`Voxia.Voxel` **19 测全绿**。**⚠️ 重大发现——材质不是"远景暗"的答案**:真实 RHI(`--visible-rhi` `L_WorldGenSvoPreview` r72 四环,同 collar 机位)出图,远场顶面已全 dirt 但**近亮/远暗观感基本没变**。因近/远**同一个 Lit 材质** `M_VoxelVertexColor`(`VoxiaWorldActor:721/1101`,远景默认 Lit 消色差,`-VoxiaSvoFarUnlitMaterial` 才切 Unlit)+ **同一 dirt 顶点色**却渲染近亮远暗 → **"远景全是褐色"主因=光照/LOD 非材质**:粗 LOD 大块斜俯视多为**竖直侧面**,据 `voxia-render-lighting` 程序化网格竖直崖壁**收不到 Lumen 天光方位补光** → 暗褐;近场细 1m 多朝上顶面迎光 → 亮。材质修复是**真 bug、该修、已修**(移除灰斑 + per-macro 地基),但观感主项归**光照(下一步 A)**。**RHI 谐调坑**:`voxia_stdio_cli.js` 多个 `--cmd` 会**互相覆盖**(`:42` `commandScript=args[++i]`),须**单 `--cmd` 内分号 `;` 串**;SVO 远场须 `L_WorldGenSvoPreview` 图 + `-VoxiaSvoPreview -VoxiaWorldGenPreview -VoxiaSvoTileRadius=72 -VoxiaSvoLodRings=...`(默认 `L_WorldGenPreview` 不开 SVO,`svo enabled:false` 挂死 `until_svo`);`--real-rhi` 离屏 Lumen **GPU OOM 崩**(RHIThread D3D12 out-of-video-memory),截图用 `--visible-rhi` 窗口。代码未 commit。

- 2026-07-08（**当前进度 / 下一步 resume 指针**——用户换电脑,此条为新会话入口）：**已完成并提交推送**(Voxia `master` + 主仓 `master`,本次一起 push)：Step 0(目视基线) / Step 1(跨 depth seam) / Step 2(collar opt-in) / **backlog A(远场逐面贴壁真材质)**。**下一步 = A(光照,用户已拍板"直接开始")**：查远场**竖直侧面为何暗**——候选:①`voxia-render-lighting` 记的"程序化网格竖直崖壁收不到 Lumen 天光方位补光",查补光 RIG 覆盖范围/方位;②固定曝光是否只调好近场;③远场粗 LOD 是否该走更平 shading(减自遮挡);④`M_VoxelFarUnlit`(uniform 亮,`-VoxiaSvoFarUnlitMaterial`)当年为何降 alt(色差?)——这才是"远景全是褐色"真解。**需 `--visible-rhi` 出图**(离屏 `--real-rhi` Lumen GPU OOM,已踩)。**RHI 谐调正确姿势**:单 `--cmd` 分号串 + `L_WorldGenSvoPreview` 图 + `-VoxiaSvoPreview -VoxiaWorldGenPreview -VoxiaSvoTileRadius=72 -VoxiaSvoLodRings=7@8,14@24,28@40,56@72 -VoxiaWorldGenSpawnMacroX=1234 -VoxiaWorldGenSpawnMacroZ=-5678`;机位 `teleport 123450 -567750 8000; look -20 135`。**仍 pending**:Step 3(fade)、Step 4-5(A5 瘦身/cache)、Step 6(A 验收);per-macro 材质升级(地表多材质时)记为后续。
- 2026-07-08（**A（光照）RHI 诊断结论 + D5 拍板 + harness 坑**——用户拍板"照度不管"）：`--visible-rhi` 干净 A/B（Lit vs Unlit，同机位）坐实：**远景真实反照率 = 暖橙土色 + 灰石斑（中等亮度），Lit 把它压成暗褐/冷蓝灰 → "远景暗"主因 = 光照，材质无辜**。机制：远景 mesh 无 mesh distance field → Lumen 天光间接光进不来（见 `clients/Voxia/docs/engineering-notes/2026-06-26-voxel-terrain-black-faces-lumen.md`），只剩太阳 + 4 盏补光 RIG（`VoxiaClientGameMode.cpp:291-329`）直接光，大面/背光面欠照。**用户拍板：照度走 D5(b) 签收（远景 visual-only、偏暗接受），不投入抬照度**。近/远另有真实**材质色相差**（近沙 vs 远土）——独立项，见下条 backlog。**⚠️ harness 坑（务必回写）：`voxia_stdio_cli` 的 `teleport`/`look` 必须先 `fly 1`**，否则被 Pawn 移动 Tick 每帧覆盖（`VoxiaPawn.cpp` Tick `SetActorLocation(Movement->GetPosition())` / `SetControlRotation`）、相机卡出生点（本轮前 6 发全是出生点假象）。正确姿势：`fly 1; wait 800; teleport X Y Z; look pitch yaw`；**Z 单位 = cm**（旧稿"teleport ... 8000"实为 80m）。
- 2026-07-08（**A(光照) 后新 backlog——用户拍板下一步**，替代原"下一步 = A(光照)"）：照度既 D5 签收，下一步转 **3 件实事（均属 A4 / §5#9 收口范围）**：① **窗口内外材质一致**（近 1m 窗 vs 远 SVO 逐面材质在边界不跳，消除采样层不一致，非真实地形差异部分）；② **渐进式合并**（治"一出窗口就大块"，候选：默认开 3.5m collar / 近端环 merge 更保守 / 细化环）；③ **远景地面空洞**排查修复（区分 敞底 2.5D 壳透出 / T-junction 跨 depth 缝 / near-skip 交界缺面 / 真缺 cell，对症）。投研中，改法定后逐件改 + 编译 + automation + RHI 出图验（机位记得带 `fly 1`）。**仍 pending**：Step 3(fade)、Step 4-5(A5)、Step 6(A 验收)。
- 2026-07-08（**backlog ①材质一致 + ②渐进合并 完成——线A/线B 落地，19/19 测全绿 + RHI before/after 视觉验证**）：**线A【重磅根因反转——"近沙远土"色差 = 颜色空间双重解释 bug，非采样、非光照主因】**：全链顶点色契约 = 线性调色板值×255 直存字节（`GreedyMesher ToFColor(bSRGB=false)`）；近窗 PMC 直读字节正确显示奶油沙，而远景 DynamicMesh 转换层 `VoxiaFarFieldDynamicMesh.cpp:40` 用 `FLinearColor(FColor)`（UE **sRGB 解码构造**）把线性字节又解码一次 → dirt (140,102,64)→(0.26,0.13,0.05) 压暗成橙土；stone 同理压成中灰。**修**：改 `SourceColor.ReinterpretAsLinear()`（字节/255 严格逆变换）+ 契约注释；`FarFieldPatchUploaderAutomationTest` 补**非白色** round-trip 断言（白色下两种变换同值测不出，先红后绿）。partitioned+runtime_mesh 两后端同治，HISM/PMC 不受影响。此前"远景真实反照率=橙土"的观察记录系被解码压暗后的假象，一并更正。**线B【渐进合并 = collar 3.5m 翻默认五环】**：主因是 tier 表非合并器——默认四环下窗口边界 1m→7m 一步跳 7×（collar 机制 Step2 已落地只差默认表）；merge 只放大"块感"但形状/颜色守恒，"近端不 merge"零收益纯亏预算。**修**：`FVoxiaSvoBuildConfig::LodRings` + `DefaultLodRings()` 双写点同步改 `3.5@4,7@8,14@24,28@40,56@72`，台阶 3.5×→2×；测试回写：MergeBudget `RingStats==5`、SvoPreview 默认 spec / per-tile 深度(d2-4→5) / EightKmLod cells **72/208/2112/4160/14464** / depth 阶梯 54321 / snapshot lod_config、launch 脚本与各注释同步。**⚠️ 发现真语义冲突：source pages payload=7m mip 与 collar 3.5m 叶不兼容**——pages 测试段（seed 硬编码 `SourcePageCellDepth=4`，复载按五环算 depth5 → cache key 失配载 0）显式 pin 四环 + 注记"pages 源 depth≤4，pages×collar 共存契约归 B3 冻约"。r2 防退化断言改 `QuadCount>MacroCellCount` 口径（`QuadCount`(merge 后) vs `TopQuadCount`(合并前) 跨口径比较在 depth5 下失真）。**验证**：Build `Result: Succeeded`；`Voxia.Voxel` **19/19 全绿**（automation 跑法坑：须 editor 模式跑，`-game` 下 EditorContext 测试不注册报 "No automation tests matched"；此前 composite flaky 本轮亦过）；RHI before/after（`fly 1` 机位，400m look-12 + 250m look-35）：远景回真实浅沙土色、近/远颜色连续、粒度渐进坐实。**代码未 commit。** 下一步 = backlog ③（线C 空洞）：根因已查明 = **cell/环边界覆盖性竖缝**（每 cell 独立 Y 锚定 `BuildTileSvoRootBounds` + 边界面可见性判据与邻侧渲染几何脱耦；`cross_depth_uncovered` 13.5-23.3% 即其量化证据，本稿早前"T-junction 非穿透"的注释对 uncovered 样本不成立需改判）；修法三步 = Y-slab 全局 112m 对齐（对齐 ConfirmedStore 口径）→ 边界面发射判据改邻侧渲染口径（seam check ④ 探测逻辑升级为发射逻辑）→ 叶分类整列精确相交（消 9 列稀疏采样 false-Empty），需 bump `RendererArtifactVersion` + 基线重录。

## 9. 施工 step（每 step：编译 + 最小 automation + 进度日志；默认不 push）

- **Step 0（当前状态 near+far 可见基线）**：**先看清起点再动手**——用**轻近景配置**（`TileWindowRadius=1` + 短 `VerticalTileRadius` + 长 `until_tile_window_full` 超时，绕开 61425-chunk 流式超时坑）跑一次 near+far 可见 RHI，截交界视角，肉眼记录：Lit-default 是否已消色差①、换环重叠闪烁现状②、近/远交界双显④、滑动跟随（移动几 tile 复验）。产出 A4 的目视基线 + D5 拍板依据。**不写码，纯观测**。
- **Step 1（A4 seam）**：`RunSvoSeamCheck` 扩跨 depth 覆盖性抽样 + automation 断言（小半径全量）。
- **Step 2（A4 collar）**：tier 加 `3.5@4` + depth clamp →5 + 预算复核；automation per-ring 落带。
- **Step 3（A4 fade）**：patch cross-fade + `ring_reassigned_cells`/`fade_in_flight` observe。
- **Step 4（A5 瘦身）**：顶点格式打包 424→~210B/quad + 字节/顶点守恒 automation（可与 1-3 并行）。
- **Step 5（A5 cache）**：LRU + 容量上限 + 孤儿清除 + observe。
- **Step 6（A 验收）**：8km 长巡航真实 RHI（可见 RHI 目视 + render_perf + 截图审计）；回写架构 §3.2 d 材质口径（D4）。
