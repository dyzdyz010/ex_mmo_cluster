---
status: archived
---

# 视觉打磨：体素块闪烁 + 屏幕边缘白色渐变（TSR / 后处理 / dither）

> ✅ **本文已归档**：互补 dither、TSR 抗闪参数与 fog 去雾均已实现并通过自动化与 RHI 运动录像验证；后续完整 3D 流送工作不再以本文作为 resume 指针。

> 历史任务说明：这是当时插队的视觉打磨任务；现已完成并归档，不再决定当前 A/B 排期。改动落 `clients/Voxia`，阶段证据保留在本文。
> 模型路由（用户拍板）：重思考/路线调研/算法架构设计/代码审查/问题排查 → fable5；实施/精确编辑/裁决 → 主会话 Opus；纯机械 token 大户 → codex。

## 1. 目标 / 范围

用户在可视 RHI 客户端（`voxia_stdio_cli.js --visible-rhi`，即 `-game` 可交互窗口，鼠标 look + WASD）观察到两个视觉问题：
- **① 屏幕边缘白色渐变** —— 用户口径修正（本轮 AskUserQuestion）：**不是锐利白环**，而是「整体发灰发雾、越靠边/越远越发白」。
- **② 屏幕中体素块闪烁** —— 时域，静态相机收敛后不闪。

**硬约束（用户拍板）**：光照不做特化，用全局默认 Lumen/引擎自带平行光；修复方向偏**后处理 / TSR / TAA / 曝光 / dither**，不改光照本身。

**边界**：本任务不是里程碑 A/B 的一部分，是插队视觉打磨；不碰 raymarch/go-live GPU 路径（默认关，`ShouldEnableSvoRaymarch→false`）。

## 2. 取证矩阵（已完成，2026-07-09）

取证锚：`--visible-rhi` + `L_WorldGenSvoPreview` + `-VoxiaSvoPreview -VoxiaWorldGenPreview -VoxiaSvoTileRadius=72 -VoxiaWorldGenSpawnMacroX=1234 -VoxiaWorldGenSpawnMacroZ=-5678`；机位前必 `fly 1; wait 800`；`exec <cvar>` 现场切；`until_svo_uploaded 900000 8000`；截图 `FScreenshotRequest`（不受锁屏影响）。分析工具 `scratchpad/png_analyze.js`（屏边亮度环 + 逐帧 diff）。

| 测项 | 方法 | 结果 |
|---|---|---|
| 屏边白环是否静态锐环 | 10%/2% 外环亮度环分析（baseline） | 屏边亮 1.2–1.45x 但**无纯白像素**、是**内容驱动**（天空在上/亮沙在侧），非锐环 |
| 白环随 AA 方法变？ | `exec r.AntiAliasingMethod 0/1/2/4` 逐个截图 | 外环比 1.21–1.23 **五档全一致**（含 AA 全关）→ 排除 TSR/AA 为静态白环源 |
| 白环随 ScreenPercentage 变？ | `r.ScreenPercentage 77/100` | 无变化 → 排除 SP 为静态白环源 |
| 白环随 bloom/sharpen 变？ | `r.BloomQuality 0`、`r.Tonemapper.Sharpen 0` | bloom off 全图均匀降 ~6 lum（非边缘集中）；sharpen 无变化 |
| 白环是 HUD 叠加？ | showUi=1 vs 0 | HUD 无 vignette/边框 → 排除 HUD |
| 闪烁静态是否存在 | 静态相机连拍 4 帧逐帧 diff | `changed_ratio` 0.0003–0.0014 → **静态 TSR 已收敛，几乎不闪** |
| 运动瞬态能否截到 | look-snap 后立即截图 vs settled | snap 帧 ≈ settled 帧（截图总在 TSR 重收敛后 resolve）→ **单帧拍不到时域瞬态** |
| 曝光是否过曝（fable5 F1 假设） | `-VoxiaExposure=12` 重启 | **全图纯黑** → EV100 越高越暗，EV100=1 在本场景偏亮但合理（tonemapper 压住，无死白）→ **证伪"EV100=1 过曝"**，"发灰发雾"非曝光 |
| ① 环境项隔离 | 默认曝光下逐个关 bloom/atmosphere/fog | （run4，见进度日志） |

**取证阶段性结论**：两个问题都是**时域/内容性**，静态单帧 A/B（AA/SP/bloom/sharpen）拍不到，`--visible-rhi` live（运动 + 流式换环）才显形。

## 3. 根因判定（截至本轮）

### ② 体素块闪烁 —— 双源
- **B1（已代码核实，实锤）换环 cross-fade 的 dither 非互补**：新旧远景组件共用 `M_VoxelFarDither`，新 `FadeAlpha=α`（过 `r<α`）、旧 `FadeAlpha=1-α`（过 `r<1-α`），**同噪声 r**（`VoxiaWorldActor.cpp:2549-2556/1144-1148`、`FadeController.cpp AdvanceTo AlphaOut=1-Alpha`、`create_far_dither_material.py OpacityMask=DitherTemporalAA(FadeAlpha)`）。两通过集都取噪声低端、**不互补**：α=0.5 时全等 → 50% 双写 z-fight + 50% 双裁露天空（过曝下闪白）。正确应旧过 `r≥α`。同 [Cesium #1388](https://github.com/CesiumGS/cesium-unreal/issues/1388)。稳态 α=1 恒过无事，**只在 0.35s fade 窗爆发**（移动/流式频繁换环时持续）。
- **B2（config）TSR × 高频方块几何 × SP77 亚像素 shimmer**：远处 1px 级方块棱/薄 quad 在 77% 内部分辨率下反复跨采样格，TSR shading rejection 接受↔拒绝历史横跳 → 运动时闪。

### ① 整体发灰发雾越边越白 —— 待 run4 定
- **已排除**：曝光过曝（EV100=12 全黑，证伪）；TSR/AA/SP（静态无关）；HUD。
- **候选**：ExponentialHeightFog inscattering（`SetupEnvironment` 设 hazy blue 0.55,0.66,0.80）+ SkyAtmosphere aerial perspective（地平线/远处最强，投到屏幕周边=越边越白）；bloom 边界 clamp 堆积（次）。run4 隔离定夺。

## 4. 决策项（已落地）

- **D-1（②-B1）dither 互补修复 ✅**：fable5 方案 B（单材质 + `FadeInvert` 标量 lerp）。核实 `DitherTemporalAA` 输出连续 `Result=α+D−0.5`（D 为像素/帧确定性噪声），clip 在 c=0.3333；正确互补 = 旧组件掩码 `2c−Dither(α)`（同一 α，非 1−α）→ 保留 ⟺ `Result≤c`，与正向 `Result≥c` 精确划分。实现：`create_far_dither_material.py` 加 `FadeInvert` scalar + `Subtract(ConstA=2c, B=Dither)` + `Lerp(A=Dither, B=2c−Dither, Alpha=FadeInvert)→OpacityMask`；`VoxiaWorldActor.cpp` 新 MID FadeInvert=0/旧 FadeInvert=1、两者同设 `Sample.Alpha`；`FadeController` AlphaIn/AlphaOut 合并为单 `Alpha`。稳态 FadeAlpha=1+FadeInvert=0 → mask=0.5+D≥0.5 恒过（零代价）。新旧共用同一 shader → 噪声逐位一致，互补是构造性保证。
- **D-2（②-B2）TSR 抗闪 cvar ✅**：`.ini [ConsoleVariables]` 加 `Flickering.Period=6`、`Flickering.AdjustToFrameRate=0`、`History.SampleCount=32`、`RejectionAntiAliasingQuality=3`。**不提 ScreenPercentage、不动 History.ScreenPercentage**（护 8GB 显存）；不关 AA。
- **D-3（①）fog 去雾 ✅**：`SetupEnvironment` fog 密度 1e-6→5e-7、起雾 2.5→4km、inscattering 0.55,0.66,0.80→0.34,0.40,0.50（压暗去白）。**只动我们主动加的 fog**，未碰 sun/skylight/Lumen/SkyAtmosphere（后者=全局默认，按约束保留）。run4 隔离证据：fog-off 明显去雾（但集中在地平线/边缘=正打"越边越白"）；atmosphere 才是雾主源但属全局默认不动。
- **D-4 验证 ✅**：见 §6 进度日志（automation + RHI 运动录像）。

## 5. 测试矩阵（验收）

1. **静态回归**：`Automation RunTests Voxia.Voxel` 全绿 + Build 0（改材质/FadeController 后）。
2. **② fade 闪**：静态相机触发换环，运动 GIF / ffmpeg 逐帧时域 std 热图 → fade 窗内无白点爆发、无 z-fight。
3. **② 运动 shimmer**：运动 GIF before/after（TSR 抗闪 cvar）→ 方块棱 shimmer 明显减轻。
4. **① 雾/边白**：静态 A/B → 目标项关掉后 milky/边白消退；用户 live 确认。
5. **不回归光照**：远景受光观感不变（不动光照）。

## 6. 进度日志

- 2026-07-09（建档 + 取证 + 根因初判）：承接 A4 §8「F8 白斑(预存 TSR)」延期项。完成 §2 全取证矩阵（run1 AA/SP/bloom/sharpen 静态 A/B + 闪烁逐帧 diff；run2 运动 snap；run3 exposure=12 证伪过曝）。**核实 ②-B1 dither 非互补为实锤代码 bug**。fable5 路线调研到位（TSR 抗闪 cvar 清单 + F1/F2 两发现，F1 曝光过曝经 run3 证伪、F2 dither 经代码核实成立）。用户 AskUserQuestion：① = 雾感非锐环；验证 = 解锁录 GIF。下一步：run4 隔离 ① 环境项 → fable5 出 D-1 方案 → 实施 D-1/D-2/D-3 → GIF 验证 → fable5 审查 → 收口。
- 2026-07-09（实施 D-1/D-2/D-3 + 验证）：run4 隔离 ①（fog-off 明显去雾、atmosphere 主源但全局默认不动）。fable5 出 D-1 方案 B（dump 引擎 DitherTemporalAA 表达式图推出精确公式 + 互补构造）。**实施三处修复**（分工=fable5 设计/审查、Opus 实施/裁决）：D-1 互补 dither（材质脚本 +FadeInvert/Subtract/Lerp、`VoxiaWorldActor` 3 处、`FadeController` 字段合并、新增 `FarDitherMaterialContract` automation 测试）、D-2 TSR cvar、D-3 fog 去雾。**验证**：Build 0 错；材质 commandlet 重生成成功；`FarFieldFadeController`+`FarDitherMaterialContract` 两测 Success；**全量 `Voxia.Voxel` 25/25 Success 0 Fail**（零回归）；RHI `--visible-rhi` 运动录像（`-VoxiaSvoFadeSeconds=5` 拉长 fade + yaw 扫 + creep）量化：**近白像素跨 192 帧恒定（零白闪）、无 fade 洞、去雾明显**（视频已发用户）。**运动 before/after 直接对比未做**（dither 修复无法运行时开关切换，需旧代码单独重建录一段，用户按需再定）。待 fable5 push 前审查回来 → 收口 commit（默认不 push）。
