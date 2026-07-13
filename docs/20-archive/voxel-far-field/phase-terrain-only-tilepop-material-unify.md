---
status: archived
---

# 决策稿：worldgen 只留地形 + 跨 tile 远景消失修复 + 近/远材质统一

> ✅ **本文已归档**：T1/T2/T3 与对应 Real-RHI 验收已完成。文中的列源 `Y=0` 只记录迁移期修复，不能作为现行三维设计；当前纯 3D 路线见 [`2026-07-12-pure-3d-voxel-shell-migration.md`](../../10-active/voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md)。

- **日期**：2026-07-10
- **状态**：实现完成（T1/T2/T3 已通过 automation + 真实 RHI smoke；UDS 主观调参另续）
- **触发**：用户在可视取证会话（L_WorldGenSvoPreview + UDS 光照调参）中拍板三项：
  1. 去掉 worldgen 的浮空结构生成，只生成地形；
  2. 跨越 tile 时远景整体消失再出现，跳变严重，须修复；
  3. 近景/远景材质与光照不统一，边界肉眼可见跳变——统一逻辑，近远只允许几何差异。

## 目标与范围

| # | 目标 | 范围 | 不做 |
| --- | --- | --- | --- |
| T1 | worldgen 仅产出地形（无独立悬浮结构） | `VoxiaWorldGenV1`（客户端 dev 预览源）+ 受影响测试/shape 签名 | 不动服务端权威 worldgen（除非诊断确认共享实现） |
| T2 | 跨 tile recenter 时旧远景保持可见，新覆盖建好后增量/渐变换入 | SVO 预览远场管线（CoveragePlanner/BuildPipeline/PatchGrid/FadeController/WorldActor 编排） | 不重写管线，只修 recenter 生命周期 |
| T3 | 近/远单一材质口径：同 shader、同组件渲染标志、同顶点色编码；仅几何不同 | 材质生成脚本 + near/far 组件创建处 + 顶点色编码函数 | 不特化光照（沿用全局默认口径，A 决策沿袭） |

## 决策项（诊断回填，2026-07-10）

- **D-1 = 删分支**。浮空块是独立"浮空岛"算法层（D-C，2026-07-01；`IslandColumnAt` region 噪声阈值生透镜实心带），非 3D 噪声副产品——`ColumnHeight` 是纯 2.5D 高度场，删除岛层后地形保证无悬浮几何。
- **D-2 = 两步走**。跨 tile 跳变真根因是**垂直 tile.Y 标签混入远景身份键**（非水平换环）：远景 macro-cell 是与 Y 无关的全高度列，但 build config/coverage/复用表/patch 键全携带 `CenterTile.Y`（玩家高度每 112m 一档）→ 跨档后 2.1 万 cell 复用全 miss 全量重建 + actor 侧旧组件池先行销毁 + uploader bulk-hide（pending≥64 且池空）把新组件藏到全部上传完。修复 Step1=列源 CenterTile.Y≡0 显式契约（请求点归一化 + BuildMacroCellUpdate 硬校验 H-gate）；Step2=RemovedPatches 销毁延后到上传完成（原子换入硬化，防未来任何全量翻转再黑屏）。水平换环 fade 机制不动。
- **D-3 = 以近景 Lit 观感为基准**。稳态近远已同用 M_VoxelVertexColor——跳变来自四处非几何差异：①远景 DynamicMesh 构建器不写法线 overlay→引擎 fallback 常量 (0,1,0)（主因）；②不写 UV→恒采 T_VoxelMosaic 单 texel；③远景 bCastShadow=false vs 近景 true；④fade 窗 M_VoxelFarDither 缺纹理链。修复=FlatShading（方案 A 零顶点内存）+ UV overlay 共享 helper + 组件 desc 升格近远单一事实源 + dither 材质改从 M_VoxelVertexColor 复制派生。顶点色编码已证近远逐位一致（排除）。
- **D-4 = 自动翻新，无手动迁移**。ShapeSignature 因删 9 个 Island 字段+AlgorithmVersion 1→2 自动改变；BuildKeyPrefix worldgen printf 串同步变——旧 artifact 全 miss 成孤儿由 A4 Step5 卫生机制回收。服务端 apps/ 零 island 引用，无需同步。

## 测试矩阵（初稿）

- worldgen：`VoxiaWorldGenV1AutomationTest` 全量 + golden fixture 更新后跨端一致性口径不破。
- 远场：`VoxiaFarField*AutomationTest` + `VoxiaSvoPreviewAutomationTest`；新增 recenter 生命周期契约（跨 tile 时可见组件数不落零）。
- 材质：`VoxiaFarDitherMaterialAutomationTest` 扩为近远一致性契约；Layer-3 GPU 像素测试补近远边界同色断言（--test-threads=1 口径不适用，UE 侧走 automation RHI）。
- 可视取证：RHI 开窗会话录像跨 tile 飞行（远景不消失）+ 近远边界截图（无色差线）。

## 进度日志

- 2026-07-10 立稿；fable 三诊断 agent 并行启动（浮空结构定位/跨 tile 生命周期/材质差异盘点）。UDS 光照调参会话暂停让位（uds_* 反射 CLI 已并入本轮构建，调参循环修完本批恢复）。
- 2026-07-10 三线诊断全部回来（两线因 API 断线经 workflow resume 重跑），D-1~D-4 全部回填拍板（见上）。
- 2026-07-10 **T1 完成**：浮空岛整层移除（WorldGenV1 核心 + SVO 消费面 + 键/观测面 + ps1 透传，净 -375 行），terrain-only 负向契约固化进 WorldGenV1 测试；**6/6 automation Success**（WorldGenV1/SvoPreview/SvoCacheHygiene/SvoSlidingFollow/VhiImpostor/SvoMergeBudget，nullrhi）。Voxia@180e104。
- 2026-07-10 **T2 Step1 落地（编译通过，回归待跑）**：①RequestSvoAround 列源 CenterTile.Y≡0 归一化（ConfirmedVoxelStore 保留 3D）；②BuildMacroCellUpdate 列源 Y≠0 硬拒绝（H-gate）；③source-pages fixture 删 ±Dy 垂直层预物化/自检（CLI 签名变为 `[tile] [radius] [near_skip] [movement]`），smoke 脚本同步去 --vertical-radius 并强制 Y=0；④SvoPreview 测试 FarSigned 中心 Y=4→0。**用户指示暂停点**：进度先行提交推送。
- 2026-07-10 **T2 完成**：`NormalizeCenterTileForSource` 成为请求归一化单一入口，新增垂直跨档 100% 复用与非法非零 Y 硬失败回归；uploader 新增 staged removal，`VoxiaWorldActor` 只在 `MarkUploadFinished` 后原子退役旧 patch。`Voxia.Voxel.SvoPreview` 与 `Voxia.Voxel.Far*` 全绿。
- 2026-07-10 **T3 完成**：DynamicMesh 主 UV overlay 改走 `FVoxiaFarMesher::PrimaryUvForVertex` 共享 helper；`FVoxiaFarFieldMeshComponentDesc` 统一 near/far ProcMesh、DynamicMesh、HISM 的 CastShadow/非 Lumen/RT 属性，DynamicMesh 启用零 normal-overlay FlatShading；`M_VoxelFarDither` 改为完整复制 `M_VoxelVertexColor` 后只叠加 masked dither。`Voxia.Voxel.Far` 10/10 Success。
- 2026-07-10 **真实 RHI smoke 通过**：近窗从 `center_tile=[11,0,-51]` 垂直跨到 `[11,1,-51]` 后，far SVO 仍保持 `revision=1` / `center_tile=[11,0,-51]` / `far_component_count=35` / `far_visible_component_count=2` / `upload_queue=0`，证明列源没有重建或黑屏窗口；`Saved/voxia_t2_t3_vertical_tile_real_rhi.png` 审计 `1920x1080`、`unique_colors=24522`、`non_black_ratio=1`、`passed=true`。
- 2026-07-10 **零参数编辑器入口完成并实跑**：`DefaultEngine.ini` 的 game/editor 默认地图统一为 `L_WorldGenSvoPreview`；地图专用 `VoxiaPreviewRuntimeProfile` 只自动启用 WorldGen baseline 与 SVO，PIE 前缀 `UEDPIE_0_` 已纳入精确识别，其他地图不受影响。用户复核指出 40000 cm 概览 SpringArm 不是真实第一人称后，该错误覆盖已移除；入口恢复 Pawn 原生 `arm_length_cm=0` / `eye_height_cm=60` / `field_of_view=90`，并以 `voxia_preview_first_person_camera_ready` 显式观测。只用 `UnrealEditor.exe Voxia.uproject` 启动并点击 Play 后，observe 记录 `activation=map_profile`；默认 8km 构建仍得到 `macro_cell_count=21016` / `quad_count=1329713` / `seam_status=pass`，361 个分区上传完成后的第一人称实际画面为 `.demo/observe/voxia_editor_zero_arg_first_person.png`。
- **Resume 指针（下一步）**：恢复 UDS 主观调参循环（`--with-sky` + `uds_set "Time of Day" 1300` + UDS 内部 HeightFog 密度），并在真实天空/雾环境下补近远边界最终人工复核；T1/T2/T3 不再是阻塞项。
- 已知残留（本轮范围外，记账）：近景水/冰 Translucent 与 Emissive bucket 远景无对应（边界落在水面/发光体仍有差异）；远景 CastShadow=true 的 GPU 代价需 -VoxiaFarNoShadow A/B 实测。
