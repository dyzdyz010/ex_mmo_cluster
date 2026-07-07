# 下一作战任务交接 —— 远景 FPS 优化 + 视觉正确性收尾（backlog）

> 2026-07-07 建。上一作战任务（**VLOD-A3b 远景 per-cell greedy merge + Lit-default + 渲染管线研究**）已收口。本文件是下一作战任务的**单一冷启动入口**——列停放项、优先级、战略上下文与详情指针。真正开工时再据此写正式 phase 决策稿。

## 0. 上一任务收口状态（全 commit、未 push）

- **clients/Voxia（代码）**：`19e957a` VLOD-A3b merge（几何 −57%）、`060aaea` Lit-default（远景消色差、Unlit 降 alt）。工作树干净。
- **ex_mmo_cluster（文档）**：`88cabfd` A3b 收官+渲染管线研究、`2d6b0e8` F1、`09f3229` A/B/C 实测。
- **已交付**：VLOD-A3b Step 0–6（merge 落地 + automation 19+36 测绿 + 真实 RHI 4 跑存活 0 device-removal）；Lit-default；渲染管线研究（相机→LOD→渲染，3 mermaid，全 file:line）；F1–F8 开放议题登记 + §9 优化 roadmap。

## 1. 战略上下文（实测钉死，勿重复踩）

**远景 FPS 是像素-bound，不是三角形-bound。**（Step 6 + A/B/C 实测）
- 帧成本 = base-pass overdraw + **Lumen 全屏 GI（实测 ~2-4ms/帧、重载占 ~34%，关掉 +36~40 FPS）** + TSR，全按**像素/覆盖**计价。
- **merge / 顶点瘦身 / Nanite 守恒覆盖 → 只减三角形不减像素 → 天然动不了 FPS**（FPS 中性是必然、非失败），价值恒在 VRAM/带宽/内存。
- **要动远景 FPS 只能减像素**：Lumen 成本 或 真 overdraw 减量。
- **剔除已证真生效**（可见 RHI 361→101 可见=28%，~72% 出视锥被剔），**不是瓶颈**——别再往剔除上使劲。

## 2. 停放项（按优先级）

### P0 · 远景 FPS 主线（回报最高，像素侧）
- **Lumen 距离降质量 / exclude 远景出 GI** —— C 实测 ~2-4ms 可回收，最大单一杠杆。候选：按距离 fade Lumen 质量、远景组件 `bAffectDynamicIndirectLighting=false` 已做满但 ScreenProbeGather 全屏 pass 仍在（见 A2 §128）；可能需 per-view 或距离场分区。**牵渲染管线配置，是实打实的新工作项。**
- **base-pass overdraw 真减像素** —— ~6-8ms 帧成本大头。手段：激进距离 LOD、impostor（VHI 后端已在）、雾遮 far。**merge 这类保覆盖手段无效。**

### P1 · 视觉正确性
- **F3 跨环界裂缝/T-junction**（中-高，几何正确性）——d4↔d3 无跨环 stitch/skirt 代码；须可见 RHI 巡航肉眼查 + 若有缝设计跨环缝合。
- **F8 高频 voxel 边缘白斑伪影**（低-中）——Lit/Unlit 两图都有=材质无关、预存，疑 TSR 77% 上采样 shimmer；查 TSR 设置或屏幕百分比。
- **F2 emergence 缝**（中-低）——远景无发光/温度（`MaterialForBounds` 单材质），即便 Lit 仍与近景热单元 glow 不一致；评估是否烘焙简化 emissive。

### P2 · 规模/内存（D，用户 2026-07-07 定：暂不做、写入计划）
- **A5 顶点瘦身**（远景 mesh 顶点属性精简）。
- **Nanite bake**（`EVoxiaFarFieldRenderBackend::NaniteStaticMeshBake` 枚举已预留、运行期未接；静态远景 shell 天然适合）。
- **趁几何 −57% 推更大 LOD 半径/密度**（merge 腾出的预算换更远可视距离/更细远景）。

### P3 · 正确性/债
- **F5 真实服务器 InScene 路径**（中）——`NearWindow.CenterTile` 是否服务器 AOI 下发未证；影响联网 A/B 与流送正确性。读 `Net/VoxiaTransportSubsystem` 网络分支 + `Interest/VoxiaClientInterestSubsystem`。
- **F6 `bStaticBakeReady` 运行期不 gate**（低，设计债）——确认意图后补接线或删字段。
- **F7 `MeshComponentDesc.h:27` 头注释过时**（低）——顺手清理。

## 3. 详情指针（不重复正文，去这些看）

- **渲染管线研究 + F1–F8 登记 + §9 优化 roadmap**：[`2026-07-07-voxia-render-pipeline-camera-lod.md`](2026-07-07-voxia-render-pipeline-camera-lod.md)
- **A3b 决策稿（Step 1–6 + §5.B 裁决 + §10 交接）**：[`phase-vlod-a3b-per-cell-greedy-merge.md`](phase-vlod-a3b-per-cell-greedy-merge.md)
- **A2 分组件/Lumen 事实（Lumen 关不掉 ScreenProbeGather 全屏 pass 等）**：[`phase-vlod-a2-partitioned-staticdraw.md`](phase-vlod-a2-partitioned-staticdraw.md) §128/§131/§132
- **实测证据日志**：`clients/Voxia/Saved/`（`far_lit_shell.png`/`far_unlit_shell.png`）+ 会话 scratchpad `step6_*.log`/`f1_*.log`/`f4_*.log`/`c_lumen_off.log`

## 4. 环境/纪律提醒（动手前复核）

- 引擎 `D:\Epic Games\UE_5.8`；`Voxia.Build.cs` 保持 `bUseUnity=false`。
- 真实 RHI 存活纪律：崩后 `nvidia-smi` 确认恢复、**绝不 `-gpucrashdebugging`**；raymarch 生产终态默认关、绝不重开 go-live GPU 路径。
- 机位/命令铁律（真实 RHI A/B）：同 pawn 位=CenterTile；除受测 flag 外命令行一致；`far_visible` 遥测 **offscreen 卡死=1**、须 `--visible-rhi` 才有效。
- 代码 commit 在 `clients/Voxia`、文档在 `ex_mmo_cluster`；默认不 push；中文注释。
