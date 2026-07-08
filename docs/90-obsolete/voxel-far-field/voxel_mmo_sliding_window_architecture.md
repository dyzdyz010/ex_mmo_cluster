---
status: obsolete
subsystem: voxel-far-field
superseded_by: 30-reference/protocol/2026-06-29-voxel-sync-window-and-render-design.md
obsoleted_on: 2026-07-08
---

> ⚠️ **本文已失效** — 2026-06-29-voxel-sync-window-and-render-design.md §6.7 明确注明"整合用户提供的 design/voxel_mmo_sliding_window_architecture.md"，其架构正确性短板由该稿 W-8~W-13 补齐，原文档已被吸收。 现行事实见 [`2026-06-29-voxel-sync-window-and-render-design.md`](../../30-reference/protocol/2026-06-29-voxel-sync-window-and-render-design.md)。
> 仅存历史 provenance，**勿作现行依据**。
# 体素 MMO 滑动窗口架构（最小可行设计）

## 1. 设计目标

构建一个可扩展的基于体素的 MMO 世界，其中：

- 只有玩家附近的 **3×3×3 tile 滑动窗口** 作为真实体素世界运行，也就是 L0。
- 窗口外只使用低成本远景代理，也就是 L2。
- 系统依赖 **预测加载 + 滑动窗口**，而不是客户端全世界体素模拟。
- 第一版不引入复杂 L1 中间层，避免过早增加工程复杂度。

这个设计避免：

- 客户端加载完整 32×32 km 体素世界；
- 全局体素模拟；
- 多层 LOD 的碰撞与状态一致性问题；
- brush / DAG / SVO 等复杂系统的早期引入；
- 玩家移动时进行大规模实时世界重建。

---

## 2. 核心世界模型

世界分为两层：

```text
World
 ├── L0: Active Voxel Window，3×3×3 tiles
 └── L2: Far-Field Proxy Terrain
```

本设计暂时不使用 L1。

核心原则：

> L0 是玩法真实世界；L2 是远景表现层。

---

## 3. 空间结构

### 3.1 Chunk

```text
chunk = 16 × 16 × 16 voxels
```

chunk 是最小体素存储和网格生成单位。

每个 chunk 可以包含：

- voxel material id；
- 空气 / 固体 / 液体等状态；
- 局部修改 diff；
- mesh dirty flag；
- collision dirty flag；
- version / content hash。

---

### 3.2 Tile

```text
tile = 7 × 7 × 7 chunks
```

如果 voxel size = 1m，则：

```text
tile ≈ 112m × 112m × 112m
```

tile 是主要 streaming 单位。

每个 tile 包含：

```text
7 × 7 × 7 = 343 chunks
```

---

### 3.3 Active Window

```text
active window = 3 × 3 × 3 tiles
```

窗口内总 tile 数：

```text
27 tiles
```

窗口内总 chunk 数：

```text
27 × 343 = 9261 chunks
```

窗口内总体素数：

```text
9261 × 16 × 16 × 16
= 37,933,056 voxels
```

这部分是客户端当前真正持有的 L0 体素世界。

---

## 4. 层级定义

## 4.1 L0：真实体素层

L0 是唯一的真实 gameplay 层。

职责：

- 加载完整体素数据；
- 保留精确 material id；
- 支持挖掘、建造、破坏；
- 支持战斗和交互；
- 生成真实地形 mesh；
- 生成 gameplay collision；
- 接收并应用服务端 diff / snapshot；
- 与服务器版本保持一致。

L0 内的数据不允许近似。

原则：

> 玩家能到达、能交互、能碰撞的区域，必须是 L0。

---

## 4.2 L2：远景表现层

L2 是纯视觉层。

可用技术：

- heightmap terrain；
- server baked mesh；
- proxy mesh；
- impostor；
- skyline mesh；
- 远山轮廓；
- 大气雾 / 距离雾遮挡。

L2 不负责：

- gameplay；
- 挖掘；
- 建造；
- 精确碰撞；
- 精确材质；
- 体素状态同步。

原则：

> L2 只负责让远处“看起来合理”，不负责成为真实世界。

---

## 5. 为什么不做 L1

第一版不引入 L1 的原因：

- 减少 L0 / L1 切换问题；
- 避免 L1 collision 与 L0 collision 不一致；
- 避免 L1 mesh 与 L0 voxel 状态不一致；
- 避免额外的 tile 状态机；
- 避免 brush / semantic LOD / geometry proxy 过早复杂化；
- 降低 UE5 客户端实现难度。

简化后的结构是：

```text
窗口内：全 L0
窗口外：全 L2
```

也就是：

```text
近处是真体素，远处是视觉代理。
```

---

## 6. 窗口滑动模型

### 6.1 基本原则

客户端不是加载整个世界，而是维护一个围绕玩家的 L0 窗口。

当玩家移动时，窗口跟随玩家滑动。

```text
Player moves
  ↓
Predict next tile direction
  ↓
Preload entering tiles
  ↓
Build mesh and collision asynchronously
  ↓
Promote new tiles into L0 window
  ↓
Unload old tiles after grace period
```

---

### 6.2 不要等跨 tile 后再加载

错误方式：

```text
玩家进入新 tile
  → 请求服务器
  → 下载 voxel
  → 解压
  → 生成 mesh
  → 生成 collision
```

这会导致卡顿、掉落、空气墙或 rubber band。

正确方式：

```text
玩家接近 tile 边界前
  → 预测移动方向
  → 提前请求新 tile
  → 提前解压 voxel
  → 提前生成 mesh
  → 提前生成 collision
  → 玩家跨越时直接切换
```

---

### 6.3 滑动时的新进入区域

如果玩家沿 X 方向移动一个 tile，新的 L0 区域不是 27 个 tile 全部重新加载，而是新增一个 slab：

```text
1 × 3 × 3 tiles = 9 tiles
```

新进入 chunk 数：

```text
9 × 343 = 3087 chunks
```

新进入 voxel 数：

```text
3087 × 4096 = 12,644,352 voxels
```

这部分不应该在一帧内完成，必须异步、分帧、按优先级处理。

---

## 7. 本地推导 + Snapshot + Diff

### 7.1 世界状态来源

每个 tile 的状态由三部分决定：

```text
Final Tile State
=
Procedural Base Terrain
+ Persistent Diff
+ Optional Snapshot
```

---

### 7.2 Procedural Base

基础地形由确定性算法推导：

```text
base_voxel = terrain_function(seed, world_position)
```

优点：

- 不需要存储未修改地形；
- 客户端可以本地推导；
- 服务端与客户端可使用相同 seed / version 校验；
- 适合超大世界。

---

### 7.3 Diff

diff 只记录被玩家或系统修改过的部分。

例如：

- 挖掉某些 voxel；
- 放置建筑 voxel；
- 修改材质；
- 破坏结构；
- 液体变化；
- 资源采集变化。

diff 是稀疏的。

---

### 7.4 Snapshot

snapshot 不是全世界预烘焙，而是局部加速缓存。

用途：

- 避免重复 replay 很长的 diff log；
- 加快热点 tile 加载；
- 作为 tile 的某个版本 checkpoint；
- 使冷却后的区域可以更快恢复。

推荐理解：

> Snapshot 是局部 tile 的重建加速器，不是全世界预烘焙。

---

## 8. Hot / Cold 处理思路

不需要预烘焙整个世界，因为体素世界会持续变化。

但可以缓存局部稳定状态。

### 8.1 Hot Tile

正在玩家 L0 窗口内。

特点：

- 高频变化；
- 需要实时 diff；
- 需要完整 voxel；
- 需要 mesh / collision 更新；
- 不适合只依赖旧 snapshot。

---

### 8.2 Warm Tile

玩家即将进入或刚离开的区域。

特点：

- 可以保留 voxel cache；
- 可以保留 mesh cache；
- 可以延迟卸载；
- 可以后台更新 snapshot。

---

### 8.3 Cold Tile

远离玩家、短期不会交互的区域。

特点：

- 不需要完整 voxel 驻留；
- 可以只保留 snapshot / diff / L2 proxy；
- 可以延迟合并 diff；
- 可以由服务端后台生成远景代理。

---

## 9. 客户端窗口内一致性策略

本设计的核心简化是：

> 只保证窗口内 L0 一致，窗口外不保证真实体素交互。

窗口外发生变化时：

- 不立即物化为客户端体素；
- 可以更新 L2 proxy；
- 或等待该区域进入 L0 窗口时再加载最新 snapshot / diff；
- 玩家走过去前通常已有足够时间加载。

---

## 10. 加载优先级

### 10.1 方向优先

根据玩家移动方向决定加载优先级。

```text
priority = distance_weight + direction_weight + velocity_weight
```

优先级：

```text
1. 玩家前进方向即将进入的 tile
2. 玩家侧向附近 tile
3. 玩家身后 tile
4. 远景 L2 proxy
```

---

### 10.2 按阶段加载

每个新 tile 不应该一次性完成所有工作，而是分阶段：

```text
1. 请求版本信息
2. 下载 snapshot / diff
3. 本地推导 base voxel
4. 应用 snapshot / diff
5. 生成 render mesh
6. 生成 collision
7. 标记 tile ready
8. 加入 L0 window
```

---

## 11. Mesh 生成策略

L0 mesh 由真实 voxel 生成。

建议：

- air 不生成面；
- 使用 greedy meshing 或类似合并算法；
- 按 chunk 或 mesh page 异步生成；
- 避免每个 chunk 一个 UE component；
- 使用 mesh page 聚合多个 chunk；
- mesh 生成和 RHI 上传分帧处理。

推荐结构：

```text
Chunk → Mesh Page → Tile
```

例如：

```text
mesh page = 2×2×2 chunks
```

或：

```text
mesh page = 4×4×4 chunks
```

---

## 12. Collision 策略

L0 窗口内需要 collision，但不代表所有区域都必须 full gameplay active。

可以拆成：

```text
voxel data resident
render mesh resident
collision resident
gameplay active
```

推荐：

| 区域 | voxel 数据 | 渲染 | 碰撞 | 交互 |
|---|---:|---:|---:|---:|
| 玩家脚下和附近核心区 | 是 | 是 | 精确 | 是 |
| 3×3×3 外圈 | 是 | 是 | 预生成 / 简化 | 通常否 |
| 即将进入方向 | 是 | 预生成 | 优先生成 | 即将启用 |
| 窗口外 | 否 | L2 | 无 | 否 |

核心规则：

> 玩家脚下和即将到达的区域，collision 必须提前 ready。

---

## 13. L2 远景渲染

窗口外使用 L2。

推荐组合：

```text
Far View =
  heightmap terrain
+ baked terrain mesh
+ large structure proxy
+ cave entrance proxy
+ city / building impostor
+ vegetation impostor
+ skyline mesh
+ fog / atmospheric hiding
```

### 13.1 Heightmap

适合：

- 山脉；
- 平原；
- 丘陵；
- 大地貌轮廓。

限制：

- 表达不了洞穴；
- 表达不了悬空结构；
- 表达不了桥梁；
- 表达不了多层建筑。

---

### 13.2 Proxy Mesh

用于补充 heightmap 表达不了的内容：

- 巨型玩家建筑；
- 城堡；
- 桥梁；
- 洞口；
- 悬空结构；
- 大型矿坑；
- 战场破坏痕迹。

---

### 13.3 Impostor / Skyline

用于超远景：

- 远山轮廓；
- 城市剪影；
- 森林块；
- 大陆边界；
- 低成本天际线。

---

## 14. 版本一致性

每个 tile / chunk / proxy 都应该携带版本信息。

```text
tile_id
chunk_id
server_version
content_hash
```

用途：

- 判断客户端缓存是否过期；
- 判断是否需要拉取 diff；
- 防止旧 mesh 覆盖新状态；
- 方便 debug；
- 支持断线重连和区域重新进入。

---

## 15. 服务端权威模型

服务端是唯一世界真相。

服务端负责：

- 接收玩家编辑请求；
- 验证合法性；
- 更新权威 voxel state / diff；
- 维护 tile version；
- 生成 snapshot；
- 生成 L2 proxy；
- 向客户端发送窗口内最新数据。

客户端负责：

- 本地推导 base terrain；
- 应用服务端批准的 diff / snapshot；
- 渲染；
- 预测加载；
- 不做权威世界修改。

原则：

> Client can predict, but server decides.

---

## 16. 网络协议草案

### 16.1 请求 tile

```text
RequestTile {
  tile_id
  client_version
  desired_level: L0
}
```

### 16.2 返回 tile

```text
TilePayload {
  tile_id
  server_version
  base_seed_version
  snapshot_id
  diff_list
  content_hash
}
```

### 16.3 请求 L2 远景

```text
RequestFarProxy {
  region_id
  client_version
}
```

### 16.4 返回 L2

```text
FarProxyPayload {
  region_id
  server_version
  heightmap
  proxy_meshes
  impostor_data
  material_map
}
```

---

## 17. 失败处理

### 17.1 L0 未加载完成

如果玩家即将进入的 tile 还没有 ready：

可选策略：

- 临时减速；
- 软空气墙；
- 雾墙遮挡；
- 等待 collision ready；
- 服务端位置纠正。

不要允许玩家进入未完成 collision 的区域。

---

### 17.2 网络延迟

处理方式：

- 优先加载前进方向 tile；
- 降低远景更新优先级；
- 保留旧 tile 一段时间；
- 延迟卸载；
- 使用旧 snapshot 临时显示，但不允许交互。

---

## 18. 最小可行版本建议

第一版只做：

```text
L0:
  3×3×3 tile true voxel window

L2:
  heightmap / baked mesh / proxy / impostor

No L1.
No DAG.
No SVO.
No complex brush hierarchy.
```

核心工程任务：

1. tile streaming；
2. 本地 terrain function；
3. snapshot / diff；
4. async voxel decode；
5. async mesh generation；
6. async collision generation；
7. L2 far proxy；
8. server versioning。

---

## 19. 关键设计结论

这个架构的本质是：

> 一个以 3×3×3 tile 为唯一真实体素窗口的 MMO voxel streaming 系统。

它的核心取舍是：

- 不追求客户端全世界体素模拟；
- 不在第一版引入复杂 LOD；
- 不让玩家接触未加载区域；
- 用预测加载保证移动体验；
- 用 L2 代理保证远景视觉；
- 用 snapshot / diff 保证窗口内一致性。

最终原则：

> 窗口内必须真实，窗口外可以近似。
