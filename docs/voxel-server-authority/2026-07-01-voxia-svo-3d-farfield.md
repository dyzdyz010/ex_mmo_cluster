# Voxia SVO 正式 3D 远景 — 决策稿

> 当前决策稿。目标：把 Voxia SVO 远景从「结构 3D、内容 2.5D」升级成**真正显示 3D 结构**（悬崖体积感 / 浮空岛 / 远山起伏）的正式远景，先在 SVO 专用关卡内做到：近景窗口 + 远景 SVO 都正确渲染、移动时流送顺滑无卡顿、架构正常运转。
>
> 上游证据源：`2026-07-01` SVO 全面审计（10-agent 对抗式，见记忆 `voxia-svo-farfield-status-gaps`）、`2026-06-30-voxia-svo-preview-design.md`、`2026-06-30-voxia-farfield-common-components-and-vhi-baseline.md`（D-5 = 切 3D 源为下个里程碑）、`2026-06-29-voxel-baseline-streaming-boundary.md`（远景=确定性 WorldGen 派生的 materialized view）。

## 1. 背景：为什么现在出不来 3D

审计（重建 HEAD 二进制 + RHI 实跑）确认：SVO 八叉树**结构已是 3D**（2×2×2 递归 empty/solid/mixed），8km 155k quad、191–231 FPS、seam pass。但它**永远出不来 3D 结构**，根因是喂给它的 occupancy 100% 来自 2.5D 高度场：

- `FVoxiaWorldGenV1::MaterialAt(x,y,z)` = 纯 `y < ColumnHeight(x,z)`（`VoxiaWorldGenV1.cpp:154-166`），一列一个实心段、上面全空，结构上表达不了洞穴/悬崖背面/浮空岛。
- SVO 的 `ClassifyBounds` / `SampleHeightRange` / `MaterialForBounds` / `FaceOutsideHasAir` 全部**硬写**成读 `ColumnHeight`（`VoxiaSvoPreview.cpp:169-247`）——不是可注入的 `occupancy(x,y,z)`。
- 根 Y 范围 `BuildTileSvoRootBounds` 由列高采样钳制（`:469-490`，连 `Tile.Y` 都丢弃），任何离开地表皮的几何都被裁掉。
- `MakeSvoCoverageConfig` 硬编码 `VerticalRadiusTiles=0`（`:45`）——只规划单 Y 带。

## 2. 用户拍板（2026-07-01）

| # | 决策项 | 拍板 |
| --- | --- | --- |
| U-1 | 3D 内容来源 | **客户端本地程序化 3D**：给 `FVoxiaWorldGenV1` 加 3D 噪声，近场 + SVO **同源**采样。不动协议/服务端。 |
| U-2 | 落地范围 | **仅 SVO 专用关卡（`-VoxiaSvoPreview`）**：近景窗口 + 远景 SVO 都正确渲染、**移动时流送顺滑无卡顿**、架构正常。暂不接连接态。 |
| U-3 | 3D 效果重点 | **悬崖/陡坡实体体积感 + 浮空岛/悬空结构 + 远处山脉起伏**。（洞穴/地下空腔本轮不做。） |

## 3. 关键架构判断（决定方案可行且低风险）

1. **preview 近场是现算的，不是烤好的 pack。** preview 模式 `RequestTerrainBaseline` 只标记 Ready（`VoxiaTransportSubsystem.cpp:375-395`）；近场每个 chunk 由 `BuildChunkSnapshot` **实时生成**（`:684-700`）。→ 只要改 WorldGen 占用函数，**近场自动变 3D**，无需重烤 pack。
2. **近场与远景同源 ⇒ 边界天然一致。** 两者都吃客户端本地 `FVoxiaWorldGenV1`（`WorldGenPreviewConfig()`）。只要它们对同一 `IsSolid(x,y,z)` 达成一致，near/far 边界就不会结构性打架。seam 问题退化为 LOD 粒度差（SVO 粗块 vs 近场细体素），用 skirt/真 seam check 兜底。
3. **跨端 bit-exact 本轮不涉及。** near 与 far 都是**客户端本地**推导；服务端不参与。因此本轮**不背** WorldGen 跨端一致的包袱。⚠️ 但这也意味着客户端 `FVoxiaWorldGenV1` 将**偏离**服务端 2.5D WorldGen —— 这是接连接态（未来里程碑）的显式前置依赖：届时服务端 WorldGen 必须同步升 3D，或客户端 3D 生成器上升为共享规范。**本决策稿在文末「7. 未来接连接态的前置」记录之。**
4. **近场 mesher 已能吃任意 3D 占用。** `FVoxiaGreedyMesher` 在体素 macro 网格上按 solid↔air 剔面、跨 chunk 感知——给它 3D 体素就渲染 3D，无需改近场 mesher。
5. **`BuildChunkSnapshot` 的列式早退对 3D 无效，必须改。** `:210`（`ChunkBaseY >= MaxColumnHeight → 返回空`）会吞掉地表之上的浮空岛；`:217`（底部全实心块）对洞穴无效（本轮不做洞穴，此早退可保留但要与新占用函数一致）。

## 4. 3D 内容设计（U-3 三件事，纯客户端 WorldGen）

单一权威占用函数 **`FVoxiaWorldGenV1::IsSolid(x,y,z, Config) -> bool`** + **`MaterialAt(x,y,z)`**（返回材质，0=air），三处特征叠加。所有消费者（`BuildChunkSnapshot` 近场、SVO 采样）都只调它，杜绝"两套占用"。

1. **远山起伏（D-A）**：WorldGen 已有山脉项（`GVoxiaMountainAmplitude=1400`，被 `Mask∈[0.62,0.9]` 门控），但出生点 macro `(1234,-5678)` 落在 lowland → 平坦。改法（纯常量/映射调参，最小侵入）：降低山脉 mask 门槛 / 提高 lowland 振幅，让预览出生区就有明显起伏；或把预览出生点移到山区。**只动 `ColumnHeight` 的调参，不改结构。**
2. **悬崖/陡坡体积感（D-B）**：两层——
   - **渲染层**：SVO 按**真 3D 体占用**采样（不是列高比较），陡坡列高梯度大处自然产出高竖直崖面 + 实心体积；配合 D-C 的深度/采样加密，崖面不再是单点判定的"全高或没有"。
   - **内容层（可选增强）**：近地表叠一层 3D 密度扰动（`density(x,y,z)` 在 `y≈ColumnHeight` 附近），产生**外凸岩檐/悬垂**（真 overhang，2.5D 表达不了的）。第一版可只做渲染层，overhang 作为 D-B+ 增量。
3. **浮空岛（D-C）**：地表之上 `y∈[ColumnHeight+Gap, +Height]` 的 Y 带里，用 3D 值噪声阈值产出**孤立实心团**（islandMaterial）。需要 SVO **垂直覆盖 + 根 Y 上探**才渲染得到。

## 5. 工程改造面（按 step，每 step = build + 最小测试 + commit）

> UE 验证回路（关编辑器）：`Build.bat VoxiaEditor Win64 Development -Project=... -WaitMutex -NoLiveCoding`；`Automation RunTests Voxia.Voxel`；RHI 实跑用 `-VoxiaSvoPreview` + stdio CLI `look/move/exec` 截图（见记忆 `voxia-svo-farfield-status-gaps` 的运行/截图坑）。

| Step | 内容 | 验证 | 风险 |
| --- | --- | --- | --- |
| **S1** | **占用注入化**：SVO 抽 `TFunctionRef<bool(int32,int32,int32)> IsSolidFn` + `MaterialFn`，`ClassifyBounds`/`FaceOutsideHasAir`/`MaterialForBounds` 改调注入源;`BuildTileSvoRootBounds` 改按真 3D 竖直范围（含 island 上界）取 min/max、用 `Tile.Y`;补 -Y 底面。**仍喂现列式占用**（占用值不变，只换通路）。 | Automation：列式源下 node/leaf/quad 与基线一致或仅因 -Y 面/体采样的**可解释**差异;seam 断言更新 | 高（渲染状态机 + 数值基线变） |
| **S2** | **WorldGen 加 3D**：新增 `IsSolid(x,y,z)`（列式基 + D-C 浮空岛 + 可选 D-B overhang）;`MaterialAt` 走 3D;`BuildChunkSnapshot` 改逐格调 `IsSolid`、去列式早退（或改 3D 感知）;D-A 调参出远山。近场自动 3D。 | Automation：新增 3D 占用断言（地表之上存在实心 island 格;overhang 若做则断言）;`BuildChunkSnapshot` 近场含 island | 中（生成器数学 + 近场 snapshot 结构） |
| **S3** | **SVO 垂直覆盖**：`MakeSvoCoverageConfig` `VerticalRadiusTiles>0`（由 island 上界派生）;coverage/planner Y 带贯通;root Y 覆盖 island。RHI 实跑看到浮空岛 + 崖面 + 远山。 | RHI 开窗截图（悬崖/岛/山可见）;FPS≥120;quad 规模可控 | 中 |
| **S4** | **流送顺滑（U-2 硬要求）**：SVO 接 `PlanIncremental`（reuse/upsert/remove，镜像 VHI 的 `BuildWorldGenTileUpdate`+`ReuseContext`）+ per-macro-cell 缓存（key=coord+config+worldgen 版本）+ **增量上传**（section 复用/free-list，替 `ClearAllMeshSections`，镜像 VHI `QueueVhiUpdate`）。 | CLI 跨 tile smoke：移动只重建新增 ring;实跑连续移动**无秒级卡顿**;`upload_queue`/`cache_hit_rate` 接真值 | 高（渲染上传状态机 + 增量正确性） |
| **S5** | **近/远无缝**：真 seam check（三项：边界占用一致 / 面归属去重漏 / 高度材质连续，替空壳）+ 需要处加 skirt/underlap。 | Automation seam check 真断言;RHI 边界无缝/无洞 | 中 |
| **S6** | **端到端视觉验收**：飞行环绕截图（崖/岛/山）、跨 tile 移动录屏无卡顿、FPS 报告。清理 + 进度日志。 | RHI + gif;FPS;截图 | 低 |

## 6. 测试矩阵

| 层级 | 验证 |
| --- | --- |
| Automation `Voxia.Voxel.WorldGenV1` | `IsSolid` 3D：地表之上存在 island 实心格;列式基不回归;`BuildChunkSnapshot` 含 island、无列式早退误吞 |
| Automation `Voxia.Voxel.SvoPreview` | 注入占用通路正确;垂直覆盖含 island;真 seam check 三项;-Y 面;per-cell 切片仍聚合等价 |
| Automation `Voxia.Voxel.FarFieldCoverage` | `VerticalRadiusTiles>0` 的 Y 带规划;PlanIncremental reuse/upsert/remove |
| CLI smoke | `until_svo` 出 3D 统计;跨 tile smoke 只建新增 ring;`upload_queue`/`cache_hit_rate` 非零真值 |
| RHI 视觉 | 悬崖体积 / 浮空岛 / 远山可见;近/远无缝;连续移动无秒级卡顿;FPS≥120 |

## 7. 未来接连接态的前置（本轮不做，显式记录）

- 客户端本地 3D WorldGen **偏离**服务端 2.5D WorldGen。接连接态时：服务端 WorldGen 升同款 3D（或本 3D 生成器上升为跨端共享规范）+ WorldGen 跨端 bit-exact + golden fixture（见 `2026-06-29` baseline 决策的迁移钥匙）。
- 连接态远景当前由**服务端 heightmap LodMesh** 渲染（不是 SVO）;接入需把 far-field 渲染从 LodMesh 切到 SVO（`VoxiaWorldActor` Tick 分支）+ 数据源接入。
- 玩家编辑/服务端 delta 在远景体现：SVO 需读 VoxelStore/delta 而非纯 WorldGen（当前不读）。

## 8. 不在本轮范围

- 洞穴/地下空腔（U-3 未选）。
- 接连接态正式远景（U-2 = 仅 preview）。
- SVDAG 去重 / GPU raymarch（既有非目标）。
- 服务端 WorldGen 3D 化 / 跨端 bit-exact（见 §7）。

## 9. 进度日志

- 2026-07-01：落地决策稿。承接 SVO 审计。用户拍板 U-1（客户端本地程序化 3D）/U-2（仅 preview + 流送顺滑）/U-3（悬崖体积 + 浮空岛 + 远山）。确认 preview 近场现算（改 WorldGen 即近场+远景同源变 3D）、本轮不背跨端 bit-exact。
- 2026-07-01：**Step A 完成**（Voxia `39e5f8b`）。`WorldGenV1` 加统一权威占用 `IsSolid(x,y,z)`=地表体+透镜状浮空岛；`MaterialAt` 与之一致；`BuildChunkSnapshot` 逐格调用去列式早退（改含岛顶的 `MaxSolidY` 上界 + 地下全实心早退）→ 近场窗口自动 3D（近场 mesher 本就吃任意 3D 体素）。远山调参（lowland 振幅 150→340 + 山脉门槛降）。自测 parity 精确值→语义断言（确定性/落带/有起伏）+ 浮空岛 3D 断言。Voxia.Voxel 15/15 绿。
- 2026-07-01：**Step B 完成**（Voxia `e672baa`）。SVO `ClassifyBounds` 从 2.5D 高度比较→3D 占用（地表高度带 + `BoxIslandIntersects` 岛带相交）；root Y 上探到岛顶（`SampleMaxIslandTop`）；`MaterialForBounds` 岛叶取岛材质；新增 -Y 底面（`EmitSvoLeafBottom`）。8km quad 155k→407k、mixed 叶 92k→123k。岛参数调优（threshold 0.64→0.56、gap 55→85、halfThick 26→32）。RHI 实测 117–156 FPS（>120）：远景=块状 3D 崖壁/山地/浮空岛（对比之前扁平壳）。Voxia.Voxel 15/15 绿。
- 2026-07-01：**Step C + D 委派 Fable 模型 agent 实现**（用户指定）。C=跨 tile 增量流送（镜像 VHI `BuildWorldGenTileUpdate`+`FVoxiaVhiReuseContext`+`VhiPatchSection`/`FreeVhiSections` 增量上传，`PlanIncremental`，per-macro-cell 缓存，`cache_hit_rate`/`upload_queue` 接真值）；D=真 seam check（dedup/missing/一致性三项，替空壳）+ 近/远 skirt。每步 build+test+commit（不 push）。完成后主线做 RHI 视觉验证（移动不重刷 + 无缝）。
