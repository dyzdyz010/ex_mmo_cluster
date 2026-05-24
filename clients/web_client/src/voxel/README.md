# Voxel

职责：

- 定义与 UE `test1` 对齐的空间、存储和 meshing 基础。
- 保存浏览器端体素世界真相层，不把 world truth 放在 three.js Mesh 上。
- 为编辑、渲染、网络 codec 和调试提供一致的数据入口。

边界：

- `core/` 负责坐标、常量和换算。
- `microgrid/` 负责 Macro 内 `8x8x8` Micro occupancy 的索引、边界治理和动态槽数 payload 规范。
- `storage/` 拥有 Chunk 真相层。
- `meshing/` 负责把真相层转成几何输入。
- `worldStore.ts` 拥有多 Chunk 世界级索引、编辑统计，以及世界级读写 API。
- `playerMovementCollision.ts` 是从 `WorldStore` occupancy 到 movement-domain
  collision port 的只读适配层。它不拥有 movement 状态；`LocalPlayerController`
  拥有预测状态，`WorldStore` 拥有 voxel truth。
- `worldAdapter.ts` 定义 UI / CLI 访问体素世界的端口；`LocalVoxelWorldAdapter` 拥有离线本地 truth。
- `onlineVoxelWorldAdapter.ts` 是 server-authoritative 适配器：它不让 UI 直接写本地 truth，而是提交服务端 intent、订阅 chunk snapshot，并在 snapshot 到达时一次性替换 `WorldStore` 中对应 chunk。
  在线模式启动时必须保持本地 store 为空，初始地形来自服务端已经准备好的默认区域和后续
  chunk snapshot；浏览器不再把默认区域准备当作首屏交互门槛，避免 CLI / 渲染结果混入离线
  showcase 的本地假数据。
  在线 prefab 热栏暴露服务端 v2 catalog 的 `builtin_sphere`、`builtin_cylinder`、
  `builtin_stairs`，以及导电测试用的 `builtin_conductor_wire_x`、
  `builtin_conductor_junction_xz`、`builtin_power_terminal_x`、
  `builtin_load_terminal_x`(Phase A1-1 起,跟客户端 micro mask 对齐);
  离线 refined prefab 仍保留在本地适配器里。
- `worldSnapshot.ts` 负责本地 snapshot import/export，用字符串化 bigint 保存 refined micro occupancy，供 CLI 存档、导入导出和 e2e 回归使用。
- `worldShowcase.ts` 只负责生成浏览器本地演示地形；它通过 `WorldStore` 公开写入口落地数据，不直接拥有世界状态。
- `field/` 负责服务端局部场的浏览器可视化：FieldDebugOverlay 显示 field snapshot，
  `heatSmokeEffect.ts` / `heatSmokeRenderer.ts` 把导电热量转为灰色上升烟粒子。
  业务边界是“热量出烟，不染方块本体”；烟量按
  `power_draw.estimated_tick_energy_joules` 缩放，CLI `field_overlay` 会返回
  `smoke` 粒子数用于非 GUI 验证。
- `overlayTarget.ts` 是只读目标投影层：输入来自 raycast selection 或 field macro cell。
  selection 命中会优先解析为最小 prefab/object 单位，没有 prefab/object 归属时退回宏格；
  render 层再把 prefab projection 转成贴合实际 occupancy 的外露表面边界线。field overlay
  仍输出“宏格 / 微格 / prefab”以及可渲染的 micro raster cells。render、field overlay、
  CLI 读取它的结果，不能反向修改世界状态。
- `prefab.ts` 负责浏览器本地 Prefab Definition/Instance 编排。当前阶段已按 UE
  `test1` 的 `FPrefabDefinitionData` / `FPrefabInstanceData` 分层建模：
  capture 生成定义，place 生成实例并写入所有覆盖到的 Chunk。内置
  `builtin_sphere`、`builtin_cylinder`、`builtin_stairs` 以及四种导电/电路 prefab 直接以
  refined micro occupancy 预置；玩家 capture 的普通块模板则落成 full-macro refined
  occupancy，和内置模板共用同一条 micro mesher 入口。
- Prefab definition 保留 `partDefinitions` 和 `microPartIds`。放置到场景后，
  `FRefinedCellData.microPartIds` 会随 micro occupancy 一起写入 Chunk truth，
  后续魔法/破坏系统可用 part tag 区分 roof / door / wall / stairs 等局部语义，
  不需要把运行时 prefab 还原成嵌套模板树。
- Prefab definition 同步生成 `boundaryFaceMasks`；`sockets` 只保留为可选语义兼容层。
  默认 snap 由 `prefab.ts` 使用完整 micro occupancy 枚举 boundary contact candidate，
  计算整数 world micro anchor，再把 prefab micro occupancy rasterize 到受影响的
  macro cells；`ChunkStorage` 只接收事务检查后的 refined union 写入。在线模式下，
  这个 anchor 只是浏览器从当前订阅 truth 算出的“放置提案”：`onlineVoxelWorldAdapter.ts`
  会通过 0x67 `PrefabPlaceIntent` 把 blueprint id/version + `anchorWorldMicro` +
  `rotation` 提交给服务端，服务端按同一套 `EVoxelRotation` 语义重新 rasterize
  并走 chunk transaction 决定最终是否落地。
- 微格写入 API 只服务 prefab/refined 内部数据治理和后续局部破坏系统，不作为
  玩家可直接放置 micro 方块的编辑入口。CLI 暴露 `micro_cell` 读取检查，以及
  `target_probe`、`prefab_boundary / prefab_snap_preview / prefab_place_snap` 验证目标投影和
  socket-free 微格边界贴合。

## Phase 4-bis：0x6C ObjectStateDelta + 碎屑粒子(2026-05-08)

服务端权威破坏事件(damage / part_destroyed / destroyed)推送到客户端后，
通过 `OnlineVoxelWorldAdapter` 内部 pipeline 转化为 HUD 提示 + 棕色碎屑
立方体粒子。模块拓扑(均在 `clients/web_client/src/voxel/`):

- `clearedSlotCache.ts`：per-object_id `Map<bigint, ClearedSlot[]>`，TTL
  2 秒 + 单 object 容量上限 256。**production cache hook 推到 Phase 5**
  (FRefinedCellData 当前不持 ownerObjectId，Phase 1c-5 wire-form-as-truth
  RFC park)；Phase 4-bis 数据结构 + sweep 已落，实际写入路径暂空。
- `debrisEffect.ts`：`DebrisSimulation` 纯数据状态机。`spawn(samplePoints, kind)`
  对每个采样点产生 `burstSize` 个粒子(默认 8，半球面随机方向 + 中心向外
  push + 切向抖动)；`update(dtMs)` symplectic Euler 重力积分(-9.8 m/s²)
  - lifetime(默认 0.8s)剔除 + array compaction；全局上限 500 粒子(超出
    FIFO trim oldest)。
- `debrisRenderer.ts`：`DebrisRenderer` THREE.InstancedMesh 包装。每帧
  `syncFromSimulation()` 把 `liveParticles()` 的位置写到 `setMatrixAt` +
  `count` + `instanceMatrix.needsUpdate`。粒子立方体边长 = 0.05m ×
  MacroWorldSize(=5 世界单位)，颜色 `#8b4513` MeshStandardMaterial。
- `OnlineVoxelWorldAdapter` 主循环顺序：
  ```
  tickDebris(nowMs)            ← sim.update(dt) + cache.sweep(now)
  drainVoxelMessages           ← drain transport queues + apply
  processObjectStateDeltaRetryQueue(nowMs)
  ```
  `ObjectStateDeltaConsumer.onDelta` 钩子通过去重后调
  `handleObjectStateDeltaForDebris`：
  1. cache.take 命中 → spawn(限额 destroyed 20 / part_destroyed 10 /
     damaged 5)+ emit `world:object-state-delta` event (source =
     "cleared_slot_cache")
  2. miss → push retry queue，retryAtMs = currentFrameTime + 100ms
  3. retry 到期再 take，仍空 → fallback 到 affected_chunks 中心点
     (source = "affected_chunks_fallback")
- HUD(`presentation/hud/hudView.ts`)订阅
  `world:object-state-delta` event，destroyed flag 时 showFlash 一行
  `object #N destroyed (M debris)` 3.5s。damaged / part_destroyed
  不上 HUD 避免高频破坏刷屏。
- RenderOrchestrator 通过 duck typing(`world.getDebrisSimulation`)
  在构造时实例化 DebrisRenderer 并加进 rootGroup，onFrame 调
  syncFromSimulation。离线 / 浏览器 fallback adapter 不暴露
  getDebrisSimulation 时静默 skip。

**已知限制 / 待 Phase 5 升级**：

- ChunkDelta apply 前的 cache hook 没接，production 路径全走 fallback
  (粒子从 chunk 中心点散开，不沿 micro slot 散布)。决策稿档 B 完整效果
  待 Phase 5 把 ownerObjectId 引入 FRefinedCellData 后落地。
- DebrisRenderer 暂用单一棕色 base material；per-instance 颜色微抖
  (instanceColor 通道)留待 Phase 5。
