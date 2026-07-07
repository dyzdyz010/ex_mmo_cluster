# Phase VLOD-A4：里程碑 A 收尾 —— 跨 depth 覆盖性 seam + 换环 fade + L1 collar（并行 A5 顶点瘦身）

> 承接**里程碑 A（客户端渲染正确，零服务端依赖）**：A1 tier 契约 ✅ / A2 分组件+剔除 ✅ / A3 per-cell greedy merge ✅（quad −57%）＋ Lit-default（额外，远景消色差）。本 phase = **A4（承重）+ A5（可并行）+ A 验收**，收口里程碑 A；过 A 验收后才进里程碑 B（接口冻结）。
> 真值源：架构主稿 [`2026-07-06-voxia-lod-layering-and-technology-design.md`](./2026-07-06-voxia-lod-layering-and-technology-design.md) §3.2/§5/§6/§8/§9；数据源终态=[投影路线](./2026-07-06-projection-route-final-decision.md)。渲染管线实证：[`2026-07-07-voxia-render-pipeline-camera-lod.md`](./2026-07-07-voxia-render-pipeline-camera-lod.md)。

## 0. 一句话

merge 腾出预算后，补齐里程碑 A 剩的三件事：① 跨 depth 环界的**覆盖性 seam 断言**（治 any-solid 膨胀下的重叠型边界）+ 换环 cross-fade（消环界跳变，原 F3）② **L1 collar 3.5m**（把 L0 边缘入带角尺寸 38px→19px）③ **A5 顶点瘦身** 424→~210B/quad + cache LRU。然后 8km 长巡航过 **A 验收**。

## 1. 目标

- **A4 覆盖性 seam**：把现状不验证跨 depth 的 `seam_check` 换成**覆盖性断言**（细侧边界暴露面必被粗侧体积覆盖；小半径全量 + 8km 按环边界抽样）——直接回答原 F3（d4↔d3 裂缝/T-junction 是否可接受）。
- **A4 换环 fade**：cell 换 depth 时 0.2-0.5s 材质 dither cross-fade，保旧 artifact 至新上传完成；observe `ring_reassigned_cells`/`fade_in_flight`。
- **A4 L1 collar 3.5m**：d2-4 加 3.5m collar 档（tier `3.5@4`），depth clamp 1..4→5；merge 后净增约 +56-112k quad（预算可负担）。
- **A5 顶点瘦身**：CPU mesh 424→~210B/quad；persistent artifact cache 加 LRU 淘汰 + 容量上限 + 孤儿清除；RAM 中间态进 observe。
- **A 验收**：8km WorldGen preview 长巡航（跨 ≥8 tiles）——per-ring quad/内存预算断言、无洞/无双显/换环不跳、render_perf 门槛、截图审计（含入带角尺寸目视）、cache 淘汰计数 全绿。

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

## 4. 决策项

| # | 决策 | 选项 | 倾向 |
| --- | --- | --- | --- |
| D1 | seam 覆盖性抽样粒度 | (a) 小半径全量 + 8km 按环边界抽样；(b) 全量 | **(a)**：全量太贵，按架构 §6/§8 口径 |
| D2 | cross-fade 时长 | 0.2-0.5s | 起步 **0.35s**，真实 RHI 目视调 |
| D3 | 顶点瘦身布局 | 打包到 ~210B/quad 的具体格式 | 施工时定；automation 守恒断言兜底 |
| D4 | Lit-default vs 架构 §3.2 d 材质口径分歧 | (a) 回写架构 doc 对齐；(b) 保留分歧 | **(a)**：Lit 已用户拍板 + 视觉确认，回写架构 §3.2 d（"顶点色三桶 matte/translucent/emissive"→"默认 Lit(VoxelMaterial)，Unlit 经 `-VoxiaSvoFarUnlitMaterial` alt"） |

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

- 2026-07-07：建档。承接里程碑 A（A1/A2/A3+Lit 已收，见 README 阶段表与各 phase 稿）。本 phase = A4（seam/fade/collar 承重）+ A5（瘦身/cache 可并行）+ A 验收。**战略约束（实测钉死）**：FPS=像素-bound，Lumen ~2-4ms 是最大杠杆，A4/A5 不动 FPS、只收几何/显存/视觉正确性。原自造 F3=本稿 A4 seam、F8 白斑(预存 TSR)/F2 emergence 缝并入视觉打磨后续、D 顶点瘦身=本稿 A5。**尚未开工。**

## 9. 施工 step（每 step：编译 + 最小 automation + 进度日志；默认不 push）

- **Step 1（A4 seam）**：`RunSvoSeamCheck` 扩跨 depth 覆盖性抽样 + automation 断言（小半径全量）。
- **Step 2（A4 collar）**：tier 加 `3.5@4` + depth clamp →5 + 预算复核；automation per-ring 落带。
- **Step 3（A4 fade）**：patch cross-fade + `ring_reassigned_cells`/`fade_in_flight` observe。
- **Step 4（A5 瘦身）**：顶点格式打包 424→~210B/quad + 字节/顶点守恒 automation（可与 1-3 并行）。
- **Step 5（A5 cache）**：LRU + 容量上限 + 孤儿清除 + observe。
- **Step 6（A 验收）**：8km 长巡航真实 RHI（可见 RHI 目视 + render_perf + 截图审计）；回写架构 §3.2 d 材质口径（D4）。
