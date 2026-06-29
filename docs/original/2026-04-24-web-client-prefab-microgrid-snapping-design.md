# Web Client Prefab Microgrid Snapping Design (2026-04-24)

## 1. 背景

`clients/web_client` 已经把 prefab 真值落到 refined micro occupancy：

1. 世界仍按 macro / chunk 分页和索引。
2. 单个 macro 内使用 `8x8x8` micro slots 表达细节。
3. prefab instance 使用 `anchorMicroCoord` 作为世界 micro 坐标锚点。
4. 写入时把 prefab micro occupancy rasterize 到受影响的 macro refined cells。

前一版设计把 socket 当成贴合主路径。新的结论是：如果产品目标是不限制用户把什么 prefab 放到一起，只要求离散微格无缝贴合，那么 socket 不应成为必需概念。

## 2. 设计结论

推荐路线改为：

```text
macro/chunk = 世界骨架
micro grid = 离散放置格
micro occupancy = 形状真值
boundary snap = 默认贴合算法
socket/profile = 可选语义扩展
```

核心规则：

1. prefab 只能放在整数 world micro 坐标上，不允许实数自由移动。
2. 任意 prefab 都可以参与 micro boundary snap，不要求手写 socket。
3. 有效贴合只看几何条件：`overlapSlots === 0` 且 `contactSlots > 0`。
4. 候选排序必须 deterministic：接触面积优先，其次准星/命中 micro 附近，其次偏移量和坐标字典序。
5. socket 可以保留为未来资产语义层，但不能阻止几何上合法的微格贴合。

## 3. 为什么仍不做自由摆放

micro boundary snap 不是自由 mesh 编辑器。它避免了自由摆放的问题：

1. 坐标仍是整数 micro，不存在浮点漂移。
2. 写入结果仍切分到 macro / chunk refined cells。
3. overlap check 仍是 bitmask 事务，失败不写入半个 prefab。
4. snapshot 仍记录整数 `anchorMicroCoord`、covered macro bbox 和 refined payload。
5. 服务端未来可以按整数 micro payload 做 authority / merge / reject。

## 4. 核心模型

### 4.1 Prefab Definition

`FPrefabDefinitionData` 的最小 snapping 数据是 occupancy：

```ts
interface FPrefabDefinitionData {
  prefabId: string;
  boundsInMacroCells: FMacroCoord;
  microResolution: number;
  occupancyWords: bigint[];
  materialChannels: number[];
  partDefinitions: FPrefabPartDefinition[];
  microPartIds: number[];
  allowedRotations: EVoxelRotation[];
  boundarySignature: number[];
  boundaryFaceMasks: FPrefabBoundaryFaceMasks;
  sockets?: FPrefabSocketDefinition[];
  tags: string[];
}
```

`boundaryFaceMasks` 是摘要和调试数据；真正的 snap 计算应使用完整 rasterize 后的 incoming cells 与 world truth 做 overlap/contact 评估，避免只看外边界造成误判。

### 4.2 Boundary Face Masks

每个 prefab 仍生成 6 个 `8x8` face mask：

```ts
interface FPrefabBoundaryFaceMasks {
  negX: bigint;
  posX: bigint;
  negY: bigint;
  posY: bigint;
  negZ: bigint;
  posZ: bigint;
}
```

用途：

1. CLI 展示 prefab 的边界占用摘要。
2. 为快速候选筛选提供粗略信号。
3. 为自动测试锁定内置 prefab 的边界形状。
4. 为后续 debug overlay 显示接触面。

### 4.3 Runtime Instance

`FPrefabInstanceData.anchorMicroCoord` 是唯一运行时锚点：

```ts
interface FPrefabInstanceData {
  instanceId: number;
  prefabId: string;
  anchorMicroCoord: FMicroCoord;
  rotation: EVoxelRotation;
  ownerChunk: FChunkCoord;
  coveredMacroMin: FMacroCoord;
  coveredMacroMax: FMacroCoord;
  overrideSetIndex: number;
}
```

关键约束：

1. `anchorMicroCoord` 必须是整数 world micro 坐标。
2. `coveredMacroMin` / `coveredMacroMax` 来自 rasterize 后真实触达范围。
3. 跨 chunk instance 记录到每个覆盖 chunk，`ownerChunk` 只表示 anchor 所在 chunk。

## 5. 放置流程

### 5.1 普通宏格放置

旧路径仍支持：

```text
macro origin -> anchorMicroCoord = macro * MicroPerMacro -> rasterize -> transaction commit
```

这让普通 full-macro prefab 和旧 `prefab_place` 行为保持稳定。

### 5.2 Micro Boundary Snap

目标流程：

```text
hit result
-> choose hit macro/micro/face normal
-> choose selected prefab + rotation
-> enumerate integer micro anchors around the hit boundary
-> rasterize prefab micro occupancy into affected macro cells
-> compute overlapSlots and contactSlots against world truth
-> choose best valid candidate
-> ghost preview uses the same rasterize cells
-> transaction commit refined union
-> record prefab instance in covered chunks
-> observe/CLI export preview, commit, reject reason
```

### 5.3 候选枚举

输入：

1. 命中目标：`occupiedMacro`、`faceNormal`、可选 `occupiedMicro`。
2. 待放置 prefab 和 rotation。
3. 搜索半径，默认 `MicroPerMacro - 1`。

算法：

1. 旋转 prefab occupancy。
2. 找出 incoming prefab 在相反法线方向上的 boundary micro points。
3. 找出 world 在命中法线面附近的 occupied boundary micro points。
4. 对每对 boundary points 计算整数 `anchorMicroCoord`，让 incoming boundary 点落到目标面外侧的相邻 micro。
5. 对每个 anchor rasterize incoming prefab。
6. 计算：
   - `overlapSlots = sum(existingMask & incomingMask)`
   - `contactSlots = incoming occupied slot 沿 -faceNormal 邻接到 existing occupied slot 的数量`
7. 保留 `overlapSlots === 0 && contactSlots > 0` 的候选。
8. 按 deterministic score 选最优候选。

这样非规则 prefab 不需要 socket。只要边界上有 micro slot 能接触，就能像宏格方块一样在离散格上自然贴合。

## 6. 写入与冲突治理

### 6.1 Transaction

写入必须先检查再提交：

```text
collect affected macro cells
-> build incoming masks/materials/states/parts per macro
-> read existing masks
-> reject if any overlap
-> commit all cells
```

失败不写入任何 chunk。

### 6.2 Micro Overlap

冲突判断：

```ts
const conflict = (existingMask & incomingMask) !== 0n;
```

允许：

1. 同一 macro 内多个 prefab 占用不同 micro slots。
2. 空 macro 写入 refined cell。
3. 与普通 solid block 比较时，solid block 视为 full occupancy。

拒绝：

1. 任意 occupied micro slot 重叠。
2. rasterize 结果为空。
3. 找不到任何接触 candidate。

### 6.3 Union

commit 使用 refined union：

```text
microOccupancyMask = existingMask | incomingMask
microMaterialIds[index] = incoming occupied ? incoming material : existing material
microStateFlags[index] = incoming occupied ? incoming state : existing state
microPartIds[index] = incoming occupied ? incoming part : existing part
prefabInstanceIds = sorted unique union
```

后续删除单个 prefab instance 时再增加 slot provenance，例如 `microOwnerInstanceIds`。

## 7. 编辑器与用户操作

用户仍不直接放置裸 micro 方块。交互层表现为：

1. 选中 prefab 后，命中任意已有体素表面时显示 micro boundary snap ghost。
2. 右键或 `F` 提交最优 snap candidate。
3. 如果找不到合法 candidate，回退到 macro adjacent placement 或明确拒绝，具体由当前编辑模式决定。
4. CLI 可以直接 preview/commit micro boundary snap，方便自动化验证。

玩家看到的是“prefab 按微格吸附到已有形状表面”，而不是手动输入 micro 坐标。

## 8. Rendering / Collision

渲染保持既有原则：

1. 渲染只消费 world truth，不直接写 storage。
2. ghost preview 使用 preview 返回的 rasterize cells。
3. mesher 继续按 refined micro occupancy 输出几何并剔除相邻 micro 内部面。

短期 collision 仍从 micro occupancy 派生，不能和视觉 mesh 分叉成两套真值。

## 9. Snapshot / Protocol

snapshot 至少记录：

1. instance `anchorMicroCoord`。
2. covered macro bbox。
3. refined cell occupancy/material/state/part/instance payload。
4. prefab definition version。

接入服务端 authority 时需要遵守第一版规范：

1. `MicroPerMacro=8`。
2. refined payload wire format 使用 512-bit occupancy。
3. prefab definition registry 与版本兼容。
4. 客户端只提交 placement intent，服务端重算 raster。
5. 跨 chunk transaction 边界。

## 10. CLI / Observe

新增/保留 CLI：

```js
window.__voxelCli?.run("prefab_boundary builtin_stairs");
window.__voxelCli?.run(
  "prefab_snap_preview builtin_sphere <x> <y> <z> <nx> <ny> <nz>",
);
window.__voxelCli?.run(
  "prefab_place_snap builtin_sphere <x> <y> <z> <nx> <ny> <nz>",
);
window.__voxelCli?.run("micro_cell <x> <y> <z> <mx> <my> <mz>");
window.__voxelCli?.run("world_export");
```

observe event：

1. `prefab_boundary_snap_previewed`
2. `prefab_boundary_snap_rejected`
3. `prefab_boundary_snap_committed`
4. `prefab_overlap_conflict`

字段至少包括：

1. `prefabId`
2. `instanceId`
3. `anchorMicroCoord`
4. `affectedMacroCount`
5. `incomingOccupiedSlots`
6. `overlapSlots`
7. `contactSlots`
8. `rejectReason`

## 11. 实施顺序

### Phase 1: 几何候选

1. 保留 `boundaryFaceMasks` 摘要。
2. 实现 micro boundary candidate enumeration。
3. 单元测试覆盖 sphere/cylinder/stairs 无 socket preview。

### Phase 2: Preview

1. CLI 暴露 `prefab_snap_preview` 的 hit-face 版本。
2. Renderer ghost preview 使用真实 rasterize cells。
3. Observe 输出 anchor/contact/overlap。

### Phase 3: Commit

1. 实现 `prefab_place_snap`。
2. 复用事务 overlap check 和 refined union。
3. 保证失败不写入任何 chunk。
4. Browser smoke 覆盖 CLI、真实页面、snapshot import/export。

### Phase 4: Delete / Break

1. 增加 slot provenance。
2. 支持删除单个 prefab instance。
3. 支持按 part 局部破坏。

## 12. 验收标准

1. 单元测试：boundary masks、candidate ranking、overlap、contact、union。
2. CLI：preview、commit、reject reason、snapshot export/import。
3. Observe：能看到 anchor、affected macros、contact/overlap 和拒绝原因。
4. Browser smoke：真实 Vite 页面中可通过 `window.__voxelCli` 操作。
5. Persistence：保存再加载后 instance anchor 和 refined occupancy 不丢失。

## 13. 最终判断

紧密贴合应通过 `integer micro boundary snapping + micro occupancy union` 实现。socket 不是基础能力，只是可选语义元数据。

宏格保留系统可维护性，微格提供离散贴合和形状真值。这样非规则 prefab 不需要手写连接点，也不会退化成自由 mesh 编辑器。
