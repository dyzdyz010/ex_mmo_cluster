# Web Client Prefab / Microgrid / Jump Display Implementation (2026-04-24)

## 1. 当前结论

`clients/web_client` 当前仍是 **voxel offline-local + movement server-ws 优先** 的浏览器验证客户端。  
本轮实现把三个用户可见问题收口到同一条客户端运行时边界上：

1. 内置 prefab：`builtin_sphere`、`builtin_cylinder`、`builtin_stairs` 已落在 refined micro occupancy 上。
2. microgrid：当前浏览器端量化为 `8x8x8 = 512` slots，用于 prefab/refined 数据，不作为玩家可直接放置的方块单位。
3. Space jump：输入、预测、日志、frame trace 和 avatar 显示高度现在能在真实浏览器路径中闭环验证。

注意：`docs/2026-04-20-体素世界服务端规划.md` 是历史规划。当前 canonical 服务端权威设计见 `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md`，server v1 与浏览器端统一采用 `MicroPerMacro=8`；UE `test1` 的 `MicroPerMacro=4` 只作为早期参考。

## 2. 文件职责

核心实现文件：

| 文件 | 职责 |
| --- | --- |
| `clients/web_client/src/voxel/core/constants.ts` | 浏览器端 voxel 量化常量；当前 `MicroPerMacro=8`。 |
| `clients/web_client/src/voxel/microgrid/governance.ts` | 单个 refined cell 的 micro index、mask、读写、归一化。 |
| `clients/web_client/src/voxel/storage/chunkStorage.ts` | Chunk truth 的真实写入层；负责 SolidBlock / Refined mode 转换。 |
| `clients/web_client/src/voxel/worldStore.ts` | 多 Chunk 世界索引、snapshot import/export、世界级写入入口。 |
| `clients/web_client/src/voxel/prefab.ts` | 本地 prefab definition / instance 编排，内置 prefab 生成与放置。 |
| `clients/web_client/src/voxel/meshing/chunkMesher.ts` | 把 refined micro occupancy 转成实际 micro cube faces。 |
| `clients/web_client/src/render/chunkRenderer.ts` | Chunk mesh 挂载、准星选中、prefab micro-wire preview。 |
| `clients/web_client/src/app/controllers/worldEditController.ts` | 玩家编辑意图入口；只处理宏格和 prefab，不暴露 micro write。 |
| `clients/web_client/src/app/controllers/renderOrchestrator.ts` | avatar 显示高度、摄像机跟随、render frame orchestration。 |
| `clients/web_client/src/presentation/devtools/devToolsCli.ts` | 浏览器 CLI 命令实现；提供 `micro_cell` 只读检查与 `actorDisplay` 快照。 |

目录旁 README 只保留职责边界；本文档记录跨目录实现链路。

## 3. Microgrid 数据结构

### 3.1 量化

当前浏览器端常量：

```ts
VoxelConstants.MicroPerMacro = 8
VoxelConstants.MicroCountPerMacro = 8 * 8 * 8
```

`MicroGridSlotCount` 派生自 `VoxelConstants.MicroCountPerMacro`。所有 refined payload 数组都应使用该派生值，不要写死 `64` 或 `512`。

### 3.2 slot 索引

单个 macro 内 micro slot 的线性索引：

```ts
index = x + y * MicroPerMacro + z * MicroPerMacro * MicroPerMacro
```

合法范围由 `isMicroCoordInBounds` 判断。越界 micro 写入必须失败并计入 rejected。

### 3.3 refined cell payload

`FRefinedCellData` 当前字段：

```ts
{
  microOccupancyMask: bigint,
  microMaterialIds: number[],
  microStateFlags: number[],
  microPartIds: number[],
  prefabInstanceIds: number[],
  boundaryCache: number,
}
```

约束：

1. `microOccupancyMask` 使用 BigInt，bit 数跟 `MicroGridSlotCount` 一致。
2. `microMaterialIds`、`microStateFlags`、`microPartIds` 都必须归一化到 `MicroGridSlotCount` 长度。
3. `microPartIds` 的 `-1` 表示未占用或无 part。
4. snapshot 序列化时 BigInt 转字符串；反序列化后必须经过 `normalizeRefinedCell`。

### 3.4 public boundary

microgrid 不是玩家编辑单位。当前公共用户路径只有：

1. 宏格放置 / 破坏：左键、右键、`F`、`G`、`place`、`break`
2. prefab 放置：hotbar 5/6/7、`select_prefab`、`prefab_place`
3. micro 只读检查：`micro_cell <x> <y> <z> <mx> <my> <mz>`

不要重新暴露 `micro_place` / `micro_break`。未来如果实现局部破坏，也应从“破坏 prefab 的某个 micro/part”语义进入，而不是让玩家直接“放置微格”。

## 4. Prefab 实现链路

### 4.1 Definition

`LocalPrefabRegistry` 构造时注册三个内置 prefab：

1. `builtin_sphere`
2. `builtin_cylinder`
3. `builtin_stairs`

内置 prefab 的 `definition.microResolution` 必须等于 `VoxelConstants.MicroPerMacro`。  
`definition.microPartIds` 长度必须等于 `MicroGridSlotCount`。

### 4.2 内置形状采样

球和圆柱都在单个 macro 内生成 refined occupancy：

1. 以 micro cell 中心点采样：`x + 0.5`、`y + 0.5`、`z + 0.5`
2. 使用 `center = MicroPerMacro / 2`
3. 使用 `radius = center - 0.1`
4. 满足距离条件时写入 occupancy bit

当前 smoke 中的形状占用量：

| prefab | occupied slots |
| --- | ---: |
| `builtin_sphere` | 280 / 512 |
| `builtin_cylinder` | 416 / 512 |

这两个数字不是协议契约，但可以作为回归信号：如果降回几十个 slot，形状精度已经退化。

### 4.3 Capture

`prefab_capture <name> <min> <max>` 当前只从普通宏格 capture：

1. 遍历 bbox 中的 macro cells。
2. 普通 block 转成 full-macro refined occupancy。
3. 为每个捕获的 macro block 创建一个 part definition。
4. `microPartIds` 里对应 macro 的所有 occupied micro 都指向该 part。

这保证用户捕获的模板和内置 refined prefab 共用同一条 storage / meshing / persistence 路径。

### 4.4 Place

`LocalPrefabRegistry.place` 的步骤：

1. 读取 prefab definition。
2. 根据 `EVoxelRotation` 做 macro offset 旋转。
3. 同步旋转每个 cell 的 micro occupancy 和 `microPartIds`。
4. 调 `wouldOverwriteExistingCells` 检查目标世界是否已有占用。
5. 为本次放置分配 `instanceId`。
6. 对每个覆盖到的 macro 调 `WorldStore.setPrefabRefinedMicroCellWorld`。
7. 在每个覆盖到的 chunk 记录同一个 `FPrefabInstanceData`，保留 `ownerChunk` 作为 anchor。

冲突策略目前保守：目标 macro 只要已有 normal/refined block，就拒绝整个 prefab place，并计入 `editStats.conflicts`。

## 5. Storage / Persistence

### 5.1 状态归属

状态归属必须保持清晰：

1. `ChunkStorage` 拥有单 Chunk truth。
2. `WorldStore` 拥有跨 Chunk 索引和本地 snapshot。
3. `WorldEditController` 只拥有编辑意图和 hotbar selection，不拥有 world truth。
4. `chunkMesher` / `chunkRenderer` 只消费快照，不回写 storage。
5. `DevToolsCli` 只读取或调用 controller/world 的公开入口，不拥有业务状态。

### 5.2 SolidBlock 与 Refined 转换

`ChunkStorage.clearMicroBlock` 支持从 SolidBlock 中凿掉一个 micro：

1. 将 SolidBlock 转成 full refined cell。
2. 清除目标 micro bit。
3. 原 normal block slot 回收到 free list。
4. header 切为 `EVoxelCellMode.Refined`。

这个能力是未来 prefab 局部破坏的底层基础；当前不直接给玩家 UI/CLI 作为 micro edit 功能。

### 5.3 Snapshot

`WorldStore.exportSnapshot()` 会序列化：

1. 非空 cell
2. refined payload
3. prefab instances
4. edit stats

`microOccupancyMask` 用字符串保存，避免 JSON 丢 BigInt。导入时 `deserializeRefinedCell` 必须归一化 payload 槽数，旧快照或缺槽数据不能直接进入运行时。

## 6. Rendering

### 6.1 Refined meshing

`chunkMesher` 对 refined cell 做 per-micro cube meshing：

1. 遍历 `0..MicroPerMacro` 三轴。
2. 对 occupied micro 生成 cube faces。
3. 同一 macro 内相邻 occupied micro 的内部面剔除。
4. 跨 macro 的相邻 micro 也通过 `isSolidWorldMicroCoord` / chunk snapshot 剔除内部面。

这使 prefab 局部凿除后不会渲染隐藏面。

### 6.2 Prefab micro-wire preview

`RenderOrchestrator` 每帧读取当前准星 selection 和 hotbar selected item。  
如果选中的是 prefab，则 `chunkRenderer.setPrefabPreview` 在 adjacent placement cells 上渲染低成本 micro-wire preview。当前实现不再使用半透明实体 ghost、glow 或填充材质。

实际写入仍由：

```text
InputController -> EventBus -> WorldEditController -> WorldStore -> ChunkStorage
```

render 层不得直接修改 world truth。

### 6.3 Space jump display

跳跃输入本身在 `InputController` 已经能产生：

1. `input:jump`
2. `jumpPressed`
3. movement frame flag `MovementFlag.Jump`
4. `movement:local-step`
5. observe event `jump_pressed`

之前浏览器里“看起来没反应”的根因是 `RenderOrchestrator.groundActorPosition` 使用 `surfaceCenterYAtWorldXZ` 把 avatar 显示高度夹到地表中心，导致 airborne 的上升位移被地表吸附逻辑吃掉。

当前显示高度计算为：

```ts
displayY = surfaceCenterY + max(0, movementY - movementGroundY)
```

`movementY - movementGroundY` 是预测层的 airborne offset；`surfaceCenterY` 是渲染层根据当前世界地表推导的角色中心高度。这样 movement truth 和 voxel 地表显示不会互相覆盖。

## 7. Editor / Input

### 7.1 当前用户操作

| 操作 | 语义 |
| --- | --- |
| 左键 / `G` | 破坏准星命中 macro。 |
| 右键 / `F` | 在命中面的 adjacent macro 放置当前 hotbar 项。 |
| 鼠标滚轮 | 切换 hotbar。 |
| `1..4` | 选择材质。 |
| `5..7` | 选择内置 prefab。 |
| `Space` | one-shot jump request。 |

Shift + 鼠标不再有 micro edit 特殊语义。

### 7.2 hotbar

hotbar entries 当前包含：

1. `dirt`
2. `stone`
3. `wood`
4. `ice`
5. `sphere`
6. `cylinder`
7. `stairs`

selection state 由 `WorldEditController` 维护；dock view 只读渲染并发出 selection intent。

## 8. CLI / Observe

浏览器 CLI 是验收面，不是辅助玩具。相关命令：

```js
window.__voxelCli?.run("prefabs");
window.__voxelCli?.run("prefab_place builtin_sphere 24 12 24");
window.__voxelCli?.run("micro_cell 24 12 24 4 4 4");
window.__voxelCli?.run("snapshot");
window.__voxelCli?.run("frame_trace_start 40");
window.__voxelCli?.run("frame_trace");
window.__voxelObserve?.recent(200);
```

`snapshot` 当前包含：

1. `hotbar`
2. `currentSelection`
3. `prefabPreview`
4. `actorDisplay`
5. `player`
6. `transportState`

Space jump 验收不要只看画面，应同时检查：

1. `input/jump_pressed`
2. movement `input_frame.movement_flags` 含 `0x04`
3. `frame_trace.samples[*].movementMode` 出现 `airborne`
4. `frame_trace.samples[*].renderedY` 有变化
5. `snapshot.actorDisplay.local.y` 有变化

## 9. Verification Contract

最小本地验证：

```powershell
cd clients/web_client
npm run typecheck
npm run lint
npm run test
npm run build
```

本轮通过的全量结果：

1. `npm run typecheck` 通过
2. `npm run lint` 通过
3. `npm run test` 通过，20 个测试文件 / 58 个测试
4. `npm run build` 通过

浏览器 CLI smoke 产物：

```text
.demo/observe/web-client-cli-smoke-prefab-resolution-jump.json
```

该 smoke 覆盖：

1. `microResolution=8`
2. sphere/cylinder/stairs 的 prefab definition
3. sphere/cylinder refined occupancy 数量
4. `micro_cell` 中心 occupied / corner empty
5. Space jump 的输入日志、movement flag、airborne trace 和 actor display Y 变化

## 10. Future Work

后续实现 prefab 局部破坏时，建议保持以下顺序：

1. 先定义“破坏 prefab part / micro slot”的用户语义，不叫“放置微格”。
2. 在 `WorldEditController` 增加 prefab-local break intent。
3. 由 `WorldStore` / `ChunkStorage` 对 refined payload 做局部 clear。
4. 同步维护 `microPartIds` 和 `prefabInstanceIds`。
5. 让 `chunkMesher` 直接消费更新后的 refined payload。
6. 通过 `micro_cell`、`snapshot`、`world_export` 和浏览器 smoke 证明数据、渲染、编辑入口一致。

如果接入服务端 voxel authority，需要先解决：

1. `MicroPerMacro=8` 与服务端/UE 当前 `4` 的量化差异。
2. refined payload 的 wire format。
3. prefab definition / instance 的版本号与兼容策略。
4. 多人编辑冲突时 refined cell 的合并或拒绝规则。
