# UE5.8 真 3D 体素世界 LOD0–LOD3 完整远景渲染计划

版本：v1.0  
目标：1m 体素、真 3D 场景、8km 最大可视范围、Elixir 权威服务器、UE5.8 客户端高帧率渲染。  
核心原则：**世界真值是体素，远景渲染不是完整体积，而是三维 shell / proxy。**

---

## 0. 最终结论

你的系统应该采用四层结构：

```text
LOD0：真实体素层，0–约300m
  1m voxel，完整 chunk/tile，真实交互、碰撞、破坏、建造。

LOD1：中景 Tile Shell，约300m–1km
  2m/4m mip，tile 级表面壳，客户端 runtime mesh，低频动态更新。

LOD2：远景 Region Proxy，约1km–4km
  16m/8m mip，4x4x4 tile 的 3D region 表面代理。
  运行时以普通 runtime proxy 为主，稳定区域可用 Nanite StaticMesh cache。

LOD3：地平线 Horizon / Macro Proxy，约4km–8km
  64m/32m mip，8x8x8 tile 的 macro cell，大轮廓、剪影、色块、impostor。
  稳定区域可用 Nanite HLOD / StaticMesh cache。

8km 以外：
  不加载真实几何，不加载真实体素，不参与碰撞、AI、diff 精确显示。
  只保留天空、大气、云、极远剪影、特殊天体现象。
```

一句话：

> **LOD0 是真实世界，LOD1 是近中景壳，LOD2 是远景三维 region 壳，LOD3 是地平线宏观壳。Nanite/HLOD 只服务稳定代理，不服务实时体素拓扑变化。**

---

## 1. 基础单位与尺寸

### 1.1 基础单位

```text
1 voxel = 1m x 1m x 1m
1 chunk = 16 x 16 x 16 voxel = 16m 边长
1 tile = 7 x 7 x 7 chunk = 112m 边长
真实近景窗口 = 3 x 3 x 3 tile = 336m 边长
最大可视范围 = 8km = 8000m
```

### 1.2 数量换算

```text
1 chunk = 16^3 = 4096 voxel slots
1 tile = 7^3 = 343 chunk
1 tile = 112^3 m³

真实窗口 = 3^3 tile = 27 tile
真实窗口 chunk 数 = 27 x 343 = 9261 chunk
真实窗口 voxel slot 数 = 9261 x 4096 = 37,933,056 voxel slots
```

注意：这里的 `voxel slot` 是空间格位，不代表每个格位都要保存完整数据。实际存储应该稀疏化。

---

## 2. 关键设计原则

### 2.1 数据组织是 3D，渲染对象是 shell

你的世界是真 3D，所以 chunk、tile、region、macro cell 都应该按三维组织：

```text
chunk -> tile：7 x 7 x 7
LOD2 region：4 x 4 x 4 tile
LOD3 macro cell：8 x 8 x 8 tile
```

但是远景渲染不能按完整 3D volume 加载。正确做法是：

```text
3D space index
+ visibility candidate selection
+ coarse voxel/density sampling
+ shell extraction
+ proxy mesh rendering
```

错误做法是：

```text
8km 半径内完整 3D 体素全部加载、全部网格化、全部渲染
```

### 2.2 8km 是 hard visual budget

8km 以外不渲染真实几何。可保留：

```text
天空盒
云层
大气雾
太阳/月亮/星空
极远山脉剪影
超大型事件云团
```

不要保留：

```text
8km 外真实 chunk
8km 外真实 diff
8km 外真实碰撞
8km 外 AI/navmesh
8km 外逐体素表面
```

### 2.3 Nanite/HLOD 不是运行时体素重建器

UE5.8 的 Nanite 是虚拟化几何渲染系统，适合高复杂度 Static Mesh / 稳定代理；World Partition HLOD 适合把大量静态 Actor 合并为远景代理。它们不是“体素变化后立刻生成 Nanite HLOD”的实时系统。

因此：

```text
稳定远景：
  Nanite / HLOD / StaticMesh cache

运行时变化：
  runtime mesh proxy / VFX / material mask / overlay

最终稳定化：
  后台低频 rebuild，之后替换 cache
```

---

## 3. 世界真值与渲染缓存的关系

### 3.1 世界真值

世界真值由服务端权威管理：

```text
WorldTruth = deterministic worldgen + authoritative diff + snapshot/version
```

其中：

| 类型 | 是什么 | 从哪里来 | 谁负责 |
|---|---|---|---|
| `WorldSeed` | 世界生成种子 | 服务端创建 | Elixir Server |
| `WorldgenVersion` | 世界生成算法版本 | 服务端发布 | Elixir Server + Client 同步实现 |
| `Diff` | 玩家/事件造成的实际变化 | 服务器权威记录 | Elixir Server |
| `Snapshot` | 某区域当前稳定状态的压缩基线 | 服务端周期合并 | Elixir Server |
| `EventLog` | 核爆、地震、坍塌等大事件记录 | 服务端广播/存储 | Elixir Server |

### 3.2 渲染缓存

渲染缓存不是世界真值，只是客户端为了画面效率生成的派生物：

| 类型 | 是什么 | 从哪里来 | 谁负责 |
|---|---|---|---|
| `RuntimeChunkMesh` | LOD0 chunk 表面 mesh | 客户端从真实体素生成 | UE Client 自研 |
| `TileShellMesh` | LOD1 tile 表面壳 | 客户端从 2m/4m mip 生成 | UE Client 自研 |
| `RuntimeRegionProxy` | LOD2 普通运行时代理 | 客户端从 16m/8m mip 生成 | UE Client 自研 |
| `RuntimeHorizonProxy` | LOD3 普通宏观代理 | 客户端从 64m/32m mip 生成 | UE Client 自研 |
| `StableNaniteProxy` | 稳定 Nanite StaticMesh 代理 | 预构建/后台构建/本地缓存 | UE 构建管线 + 可选后台 worker |
| `EventOverlay` | 大事件临时视觉覆盖 | 服务端事件 + 客户端表现 | Server 协议 + Client 自研 |

---

## 4. 服务端与客户端职责边界

### 4.1 Elixir 服务器负责什么

Elixir 服务端负责世界真值、版本和事件，不管理 UE 资产。

```text
Elixir Server
├── WorldSeed
├── WorldgenVersion
├── RegionSnapshotVersion
├── Chunk/Tile/Region Diff
├── MajorTerrainEvent
├── DirtyRegionState
├── Optional Low-Res Mip Payload
└── Optional Surface Proxy Payload
```

服务端可以下发：

```text
RegionId
LODLevel
SnapshotVersion
CompactDiff
VoxelMipData
SurfaceMeshPayload
MaterialIdMap
MajorTerrainEvent
ActiveOverlayState
```

服务端不应该下发或管理：

```text
.uasset
Nanite cooked data
World Partition cell asset
HLOD Actor
UE StaticMesh asset
UE Material asset
UE RuntimeVirtualTexture asset
```

### 4.2 UE 客户端负责什么

UE 客户端负责把中立世界数据转成可渲染对象：

```text
UE Client
├── deterministic worldgen implementation
├── diff merge
├── voxel mip generation
├── shell extraction
├── greedy meshing / surface nets / dual contouring
├── runtime mesh buffer upload
├── LOD state machine
├── proxy cache
├── event overlay rendering
├── stable proxy asset loading
└── UE renderer integration
```

---

## 5. LOD0：真实体素层

### 5.1 定义

```text
名称：LOD0_REAL_VOXEL
范围：0–约300m
空间单位：chunk / tile
精度：1m voxel
窗口：3 x 3 x 3 tile
尺寸：336m x 336m x 336m
```

LOD0 是玩家真实交互区域。它不是 proxy，而是世界的近景真实表达。

### 5.2 内容

LOD0 包含：

```text
真实体素
真实 diff
真实材质
真实破坏/建造
真实碰撞
近距离物理
近距离交互
必要 AI/navmesh 支持
```

### 5.3 数据来源

```text
基础形状：client deterministic worldgen
当前变化：server authoritative diff / snapshot
本地缓存：已加载 chunk/tile cache
```

### 5.4 需要自己实现的部分

| 模块 | 是否自研 | 说明 |
|---|---:|---|
| `VoxelChunkStorage` | 是 | chunk 内体素压缩存储、稀疏表示、dirty 标记 |
| `ChunkDiffMerge` | 是 | 合并服务端 diff 与本地生成数据 |
| `ChunkMeshBuilder` | 是 | 1m 表面提取，方块风格优先 greedy meshing |
| `ChunkDirtyQueue` | 是 | 被修改 chunk 异步重建队列 |
| `VoxelCollisionBuilder` | 是 | 只给近身范围生成碰撞 |
| `VoxelReplicationAdapter` | 是 | 把 Elixir 协议转成客户端体素状态 |
| `TileActor/TileComponent` | 是 | tile 级管理 chunk，避免一个 chunk 一个 Actor |

### 5.5 UE 提供的部分

| UE 能力 | 用法 | 注意 |
|---|---|---|
| `UPrimitiveComponent` | 正式版自定义渲染组件基类 | 推荐最终自研组件 |
| `UDynamicMeshComponent` | 原型阶段可用于 runtime mesh | 不支持 Nanite/Lumen，适合原型 |
| `UProceduralMeshComponent` | 原型阶段可用 | 长期性能和维护不如自定义组件 |
| Chaos Collision | 近处碰撞 | 只给近身 chunk 生成，不能给全部 LOD0 都做复杂碰撞 |
| Material System | 体素材质 | 材质槽必须少，优先 atlas/texture array |

### 5.6 渲染策略

LOD0 推荐：

```text
方块风格：
  solid voxel -> exposed faces -> greedy meshing -> chunk section mesh

自然风格：
  density/SDF -> dual contouring / surface nets -> mesh
```

正式项目中不建议每个 chunk 一个 Actor。推荐：

```text
TileActor
└── UVoxelTileComponent
    ├── chunk data array
    ├── dirty chunk list
    ├── render sections
    ├── collision sections
    └── async mesh jobs
```

### 5.7 性能规则

```text
1. 不要让 9261 个 chunk 全部成为 Actor。
2. 不要让所有 chunk Tick。
3. 只重建 dirty chunk。
4. 只给近身范围生成碰撞。
5. 材质槽数量必须少。
6. Greedy meshing 必须做。
7. 主线程只接收已完成 mesh buffer，不做重计算。
8. 视锥外 chunk 不提交 draw。
```

---

## 6. LOD1：中景 Tile Shell

### 6.1 定义

```text
名称：LOD1_TILE_SHELL
范围：约300m–1km
空间单位：tile
精度：2m 或 4m voxel mip
组织方式：3D tile shell
```

LOD1 是近景真实体素和远景 region proxy 之间的过渡层。

### 6.2 内容

LOD1 只保留：

```text
地形表面
大洞口轮廓
山坡/悬崖
大型建筑外形
浮空岛近中景轮廓
大水面
明显破坏后的中景外壳
```

LOD1 不保留：

```text
完整内部体素
洞穴深处
每个小方块细节
真实碰撞
AI/navmesh
小物件
复杂动态阴影
```

### 6.3 数据来源

```text
基础：client deterministic worldgen
变化：server diff / tile snapshot
精度：client 生成 2m/4m mip，或 server 下发 compact mip
```

### 6.4 需要自己实现的部分

| 模块 | 是否自研 | 说明 |
|---|---:|---|
| `VoxelMipBuilder` | 是 | 从 1m/世界生成函数得到 2m/4m coarse grid |
| `TileShellExtractor` | 是 | 只提取 solid-air 边界表面 |
| `LOD1MeshBuilder` | 是 | greedy mesh / surface nets / dual contouring |
| `LOD0LOD1SeamFixer` | 是 | LOD0 与 LOD1 边界 skirt / stitching |
| `LOD1StreamingQueue` | 是 | 玩家跨 tile 后异步生成/释放 |
| `LOD1MaterialMapper` | 是 | 粗材质映射、biome color、atlas id |

### 6.5 UE 提供的部分

| UE 能力 | 用法 | 注意 |
|---|---|---|
| `UDynamicMeshComponent` | 原型阶段显示 tile shell | 适合快速验证 |
| `UProceduralMeshComponent` | 原型可用 | 不建议最终大规模依赖 |
| 自定义 `UPrimitiveComponent` 基础设施 | 正式渲染路径 | 你需要实现 SceneProxy/buffer 管理 |
| Frustum Culling | UE 自动做组件级剔除 | 组件粒度要合理 |
| Material System | 简化材质 | 尽量使用少材质槽 |

### 6.6 渲染策略

```text
输入：2m/4m tile coarse voxel grid
处理：shell extraction
合并：greedy meshing 或自然地形 surface extraction
输出：tile-level runtime mesh
```

LOD1 通常不用 Nanite，因为它仍然可能随玩家移动和 diff 变化而比较频繁地重建。

### 6.7 性能规则

```text
1. 一个 tile 尽量 1–4 个 mesh section。
2. 无真实碰撞，最多极简 query collision。
3. 不参与 AI/navmesh。
4. 不每帧更新，只在跨 tile 或 dirty 时更新。
5. 异步构建，分帧提交。
6. LOD1 材质比 LOD0 简化一个等级。
7. LOD1 阴影只保留大型轮廓，小结构不投远景阴影。
```

---

## 7. LOD2：远景 Region Proxy

### 7.1 定义

```text
名称：LOD2_REGION_PROXY
范围：约1km–4km
空间单位：3D region
推荐 region：4 x 4 x 4 tile
region 边长：448m
精度：第一版 16m；重要区域可升级 8m
```

一个 LOD2 region：

```text
4 x 4 x 4 tile = 64 tile
1 tile = 112m
LOD2 region = 448m x 448m x 448m
```

16m 采样时：

```text
448 / 16 = 28
28^3 = 21,952 coarse cells
```

8m 采样时：

```text
448 / 8 = 56
56^3 = 175,616 coarse cells
```

第一版推荐 16m，因为它刚好与 chunk 边长一致，计算量和视觉效果更均衡。

### 7.2 内容

LOD2 保留：

```text
山体外壳
大型悬崖
浮空岛外壳
大型建筑/城市外轮廓
大洞口轮廓
大水体表面
核爆坑/大规模塌方后的远景形状
```

LOD2 不保留：

```text
山体内部
地下洞穴深处
单个 1m 方块变化
小树、小石、小道具
真实碰撞
真实 AI/navmesh
细碎材质变化
```

### 7.3 LOD2 三层结构

LOD2 不等于 Nanite。LOD2 应该由三层组成：

```text
LOD2_BaseStableProxy
  稳定区域的 StaticMesh / Nanite cache。

LOD2_RuntimeReplacementProxy
  客户端运行时从 16m/8m mip 生成的普通 runtime mesh。

LOD2_EventOverlay
  核爆、烟尘、火焰、坍塌、材质遮罩等临时视觉层。
```

最终画面：

```text
LOD2 Final = BaseStableProxy + RuntimeReplacementProxy + EventOverlay
```

### 7.4 数据来源

```text
基础：client deterministic worldgen
变化：server compact diff / region snapshot
大事件：server MajorTerrainEvent
稳定缓存：local cache / patch / optional build worker output
```

### 7.5 需要自己实现的部分

| 模块 | 是否自研 | 说明 |
|---|---:|---|
| `VoxelRegionProxyManager` | 是 | LOD2 region 的状态、加载、生成、替换 |
| `RegionId3D` | 是 | 3D region 坐标编码 |
| `LOD2MipBuilder` | 是 | 16m/8m coarse field 生成 |
| `RegionShellExtractor` | 是 | 提取 3D region 的可见表面壳 |
| `RegionProxyMeshBuilder` | 是 | 生成 runtime proxy mesh |
| `RegionVersionManager` | 是 | 对比 server snapshot version 与本地 cache version |
| `LOD2SeamFixer` | 是 | LOD1/LOD2 之间的 skirt / stitching |
| `RuntimeProxyComponent` | 是 | 正式版建议自定义 UPrimitiveComponent |
| `StableProxyResolver` | 是 | 判断是否有可用 Nanite/static cache |
| `EventOverlayApplicator` | 是 | 大事件隐藏旧 proxy、显示临时替换层 |

### 7.6 UE 提供的部分

| UE 能力 | 用法 | 注意 |
|---|---|---|
| `UStaticMeshComponent` | 显示稳定 proxy | 稳定代理可开启 Nanite |
| Nanite | 稳定远景几何的虚拟化渲染 | 不负责实时体素拓扑变化 |
| World Partition | 稳定 proxy actor 的空间流送 | 不作为你的真 3D region 状态机 |
| HLOD | 稳定远景代理合并/显示未加载 cell | 构建流程偏编辑器/commandlet |
| Runtime Virtual Texture | 大面积颜色、biome、烧焦、雪、尘土等缓存 | 适合远景材质简化 |
| Niagara | 大事件 VFX | 核爆/火山/烟尘/冲击波 |

### 7.7 LOD2 状态机

每个 LOD2 region 应该有状态：

```cpp
enum class EProxyState
{
    Missing,          // 没有代理
    Queued,           // 等待后台生成
    Generating,       // 正在生成 runtime proxy
    RuntimeReady,     // runtime proxy 可显示
    StableCached,     // 有稳定 static/Nanite proxy
    Dirty,            // 服务端版本更新，旧代理过期
    Replacing,        // 新旧代理切换中
    HiddenByEvent     // 被大事件临时遮挡
};
```

推荐 region 数据结构：

```cpp
struct FFarRegionProxy
{
    FIntVector RegionCoord;
    int32 LODLevel;                 // 2
    int32 ServerSnapshotVersion;
    int32 LocalGeneratedVersion;
    EProxyState State;

    UStaticMeshComponent* StableNaniteProxy;
    UVoxelRuntimeProxyComponent* RuntimeProxy;
    TArray<FActiveEventOverlay> ActiveOverlays;
};
```

### 7.8 LOD2 渲染策略

默认流程：

```text
1. 计算相机 1km–4km 内候选 LOD2 regions。
2. 先做视锥裁剪、距离裁剪、重要性排序。
3. 如果本地有 StableNaniteProxy 且版本匹配，显示 stable proxy。
4. 如果没有 stable proxy，后台生成 RuntimeRegionProxy。
5. 如果服务端版本更新，标记 Dirty，并排队重建 runtime proxy。
6. 如果发生大事件，隐藏/淡出旧 proxy，显示 EventOverlay + RuntimeReplacement。
```

### 7.9 性能规则

```text
1. LOD2 不生成碰撞。
2. LOD2 不参与 AI/navmesh。
3. LOD2 大多数 proxy 不投动态阴影。
4. LOD2 材质必须高度简化，优先 atlas/RVT/biome color。
5. 运行时每帧只提交有限数量 proxy 更新。
6. RuntimeProxy 和 StableProxy 可以交叉淡入淡出。
7. 大事件优先 VFX 遮挡，再替换地形代理。
8. LOD2 region 不要过大；第一版 4x4x4 tile 合理。
```

---

## 8. LOD3：地平线 Horizon / Macro Proxy

### 8.1 定义

```text
名称：LOD3_HORIZON_PROXY
范围：约4km–8km
空间单位：3D macro cell
推荐 macro cell：8 x 8 x 8 tile
macro cell 边长：896m
精度：第一版 64m；重要轮廓可升级 32m
```

一个 LOD3 macro cell：

```text
8 x 8 x 8 tile = 512 tile
1 tile = 112m
LOD3 macro cell = 896m x 896m x 896m
```

64m 采样时：

```text
896 / 64 = 14
14^3 = 2744 coarse cells
```

32m 采样时：

```text
896 / 32 = 28
28^3 = 21,952 coarse cells
```

第一版推荐 64m，因为 LOD3 是地平线层，不是粗体素层。

### 8.2 内容

LOD3 保留：

```text
远山剪影
巨大浮空岛剪影
巨型建筑/城市轮廓
大裂谷轮廓
大水面
大型森林色块
火山烟柱/核爆云/巨大魔法事件轮廓
```

LOD3 不保留：

```text
洞穴入口细节
建筑窗户
小型地表起伏
单棵树
小规模玩家改动
真实材质细节
真实动态阴影
碰撞
AI/navmesh
```

### 8.3 LOD3 三层结构

```text
LOD3_BaseStableProxy
  稳定地平线 StaticMesh / Nanite HLOD / impostor cache。

LOD3_RuntimeHorizonProxy
  客户端运行时生成的极简 macro shell。

LOD3_EventOverlay
  大事件宏观视觉，如蘑菇云、火山灰、巨大光柱、远处城市燃烧色块。
```

### 8.4 数据来源

```text
基础：client deterministic worldgen
变化：server major event descriptor / macro diff
稳定缓存：local cache / patch / optional build worker output
```

LOD3 不应该频繁接收细粒度 diff。只接收足以改变大形的事件或宏观版本。

### 8.5 需要自己实现的部分

| 模块 | 是否自研 | 说明 |
|---|---:|---|
| `MacroCellId3D` | 是 | 3D macro cell 坐标 |
| `LOD3MacroSampler` | 是 | 64m/32m coarse field 生成 |
| `HorizonShellExtractor` | 是 | 提取远山/浮空岛/巨构大轮廓 |
| `ImpostorGenerator` | 可选自研 | 生成 billboards/cards/silhouette strips |
| `MacroMaterialMapper` | 是 | biome color、snow/dust/burn macro mask |
| `LOD3EventOverlayManager` | 是 | 超远景大事件表现 |
| `LOD3VisibilityScheduler` | 是 | 只保留相机方向与重要宏观目标 |

### 8.6 UE 提供的部分

| UE 能力 | 用法 | 注意 |
|---|---|---|
| Nanite StaticMesh | 稳定大轮廓代理 | 适合稳定远景，不适合实时变化 |
| HLOD | 稳定超远代理合并 | 用于稳定资产，不是运行时体素更新器 |
| Niagara | 巨大事件远景 VFX | 蘑菇云、火山灰、冲击波 |
| RVT/SVT | 大面积颜色/材质缓存 | 地平线层材质应极简 |
| Exponential Height Fog / SkyAtmosphere | 大气融合 | 用雾隐藏 LOD3 粗糙细节 |
| Impostor/Billboard 技术 | 超远物体替代几何 | 可自研或用 UE 材质/mesh 实现 |

### 8.7 LOD3 渲染策略

```text
1. 计算 4km–8km 内候选 macro cells。
2. 优先保留视锥内、有大形、有事件、有地标的 macro cells。
3. 生成极简 horizon mesh 或 impostor。
4. 稳定区域可显示 Nanite/static horizon proxy。
5. 用大气雾、距离淡出、低频材质遮罩隐藏粗糙边界。
```

### 8.8 性能规则

```text
1. LOD3 不做碰撞。
2. LOD3 不做 AI/navmesh。
3. LOD3 基本不投动态阴影。
4. LOD3 不追求真实洞穴/细节，只追求轮廓可信。
5. LOD3 材质要极简。
6. LOD3 更新频率应最低。
7. 4km–8km 的动态变化优先表现为 VFX/色块/剪影变化。
```

---

## 9. 三维 Shell Streaming 方案

### 9.1 Chebyshev 半径

因为 chunk/tile/region 都是立方体网格，建议使用 Chebyshev 半径做基础 shell：

```text
r = max(abs(dx), abs(dy), abs(dz))
```

推荐范围：

```text
LOD0：tile Chebyshev 半径 0–1
  3 x 3 x 3 tile

LOD1：tile Chebyshev 半径 2–9
  约224m–1008m

LOD2：tile Chebyshev 半径 10–36
  约1.12km–4.03km

LOD3：tile Chebyshev 半径 37–72
  约4.14km–8.06km
```

### 9.2 不能完整加载 shell

即使使用 3D shell，也不能把整个 shell 内所有 cell 都完整生成。必须加筛选：

```text
候选 shell
  ↓
距离裁剪
  ↓
视锥裁剪
  ↓
重要性排序
  ↓
occupancy / surface-bearing 测试
  ↓
预算调度
  ↓
异步生成 proxy
```

### 9.3 Active Set 与 Warm Cache

推荐拆成两个集合：

```text
Active Render Set：
  当前相机视锥内、需要立即显示的 LOD proxy。

Warm Cache Set：
  玩家附近但暂时不在视野内的 proxy cache，可低优先级准备。
```

这样可以避免 8km 真 3D 可视范围导致候选数爆炸。

---

## 10. Shell Extraction 具体算法

### 10.1 方块体素 shell

方块风格最直接：

```cpp
for each voxel v in coarseGrid:
    if IsSolid(v):
        for each dir in sixDirections:
            n = v + dir;
            if IsAir(n):
                EmitFace(v, dir);
```

然后做 greedy meshing：

```text
同材质 + 同法线 + 共面 + 连续面
  ↓
合并成大 quad
```

适用层级：

```text
LOD0：强烈建议使用
LOD1：建议使用
LOD2：方块风格世界可使用
LOD3：一般不需要逐面 greedy，直接宏观轮廓即可
```

### 10.2 自然地形 shell

如果你的体素不是硬方块，而是 density/SDF：

```text
density field / SDF
  ↓
surface crossing detection
  ↓
Surface Nets / Dual Contouring / Marching Cubes
  ↓
mesh simplification / material assignment
```

适用层级：

```text
LOD1：可选
LOD2：推荐用于自然山体、浮空岛、洞口
LOD3：只保留大轮廓
```

### 10.3 LOD 边界缝合

可能出现裂缝的位置：

```text
LOD0 ↔ LOD1
LOD1 ↔ LOD2
LOD2 ↔ LOD3
region ↔ region
macro cell ↔ macro cell
```

解决方案：

```text
Skirt：
  边界向下/向内延伸一圈遮缝，简单可靠。

Stitching：
  在高低精度边界生成过渡三角形。

Transvoxel-style transition：
  更系统的体素 LOD 过渡方案，适合自然体素地形。
```

第一版建议：

```text
LOD0/LOD1：先用 skirt
LOD1/LOD2：skirt + overlap fade
LOD2/LOD3：大气雾 + overlap fade + 极简 stitching
```

---

## 11. 大事件处理流程

### 11.1 大事件类型

```text
核爆
火山爆发
地震
巨兽撞山
城市坍塌
浮空岛坠落
大型魔法改变山脉
```

这些事件不能当作普通逐体素 diff 来即时渲染，而应该走 MajorTerrainEvent 协议。

### 11.2 事件数据结构

```cpp
struct FMajorTerrainEvent
{
    FGuid EventId;
    EEventType Type;
    FVector Location;
    float Radius;
    int64 ServerTimestamp;

    TArray<FRegionId> AffectedLOD2Regions;
    TArray<FMacroCellId> AffectedLOD3MacroCells;

    int32 BeforeSnapshotVersion;
    int32 AfterSnapshotVersion;

    FEventVisualDescriptor Visual;
};
```

### 11.3 客户端流程

```text
T+0：
  服务端广播 MajorTerrainEvent。

T+0.1s：
  客户端播放光球、冲击波、烟尘、声音、屏幕震动。

T+1s：
  受影响 LOD2/LOD3 stable proxy 被隐藏、烧焦化或淡出。

T+1–5s：
  客户端生成 RuntimeReplacementProxy，例如粗 crater mesh、坍塌外壳。

T+5–30s：
  服务端下发正式 compact diff / snapshot version。
  客户端重建 LOD1/LOD2/LOD3 runtime proxy。

之后：
  该 region 标记 dirty。
  可选后台 UE build worker 生成新的 StableNaniteProxy。
```

### 11.4 为什么这样做

因为核爆后的第一视觉重点是：

```text
闪光
火球
烟尘
冲击波
蘑菇云
大范围遮挡
```

不是“1 秒内生成精确 Nanite HLOD”。

正确策略是：

```text
VFX 立即反馈
Runtime proxy 短期替换
Stable proxy 长期缓存化
```

---

## 12. UE5.8 能力使用清单

### 12.1 UE 直接提供，建议使用

| UE 技术 | 用在哪一层 | 作用 | 边界 |
|---|---|---|---|
| Nanite | LOD2/LOD3 稳定代理 | 高复杂度稳定几何的虚拟化渲染 | 不做实时体素拓扑重建 |
| World Partition | 稳定 proxy / 大型静态地标 | 空间流送 | 不替代你的 3D voxel streaming manager |
| World Partition HLOD | 稳定远景合并代理 | 降 draw call、显示未加载 cell | 构建流程偏编辑器/commandlet |
| UDynamicMeshComponent | LOD0/1/2 原型 | runtime mesh 生成与修改 | 不支持 Nanite/Lumen，正式版需谨慎 |
| UProceduralMeshComponent | 原型 | 快速验证 chunk/tile mesh | 不建议大规模最终使用 |
| UStaticMeshComponent | 稳定代理 | 显示 StaticMesh/Nanite proxy | 适合稳定 cache |
| ISM/HISM | 重复物体 | 树、石头、重复构件实例化 | 远景批量重复物优先使用 |
| RVT/SVT | LOD1/2/3 材质 | 大面积颜色、地表、烧焦、积雪、尘土 | 远景材质缓存，不是几何系统 |
| Niagara | EventOverlay | 爆炸、烟尘、火、冲击波 | 视觉表现，不是世界真值 |
| Virtual Shadow Maps | LOD0/重要 LOD1/LOD2 | 高质量阴影 | 远景必须限制投影对象 |
| SkyAtmosphere / Fog | LOD3 | 隐藏粗糙远景、增强距离感 | 需要配合材质淡出 |

### 12.2 需要你自己实现

| 模块 | 用在哪些层 | 说明 |
|---|---|---|
| Deterministic Worldgen | LOD0–LOD3 | 客户端与服务端必须一致 |
| Authoritative Diff Merge | LOD0–LOD3 | 服务端 diff 合并逻辑 |
| Voxel Mip Builder | LOD1–LOD3 | 2m/4m/16m/64m coarse field |
| Shell Extraction | LOD0–LOD3 | 可见表面壳提取 |
| Greedy Meshing | LOD0–LOD2 | 方块体素面合并 |
| Dual Contouring / Surface Nets | LOD1–LOD3 可选 | 自然地形表面提取 |
| Seam Fixing | LOD0–LOD3 | skirt/stitching/transvoxel-style |
| 3D Shell Streaming Manager | LOD1–LOD3 | 真 3D shell 候选、裁剪、优先级 |
| Runtime Proxy Component | LOD1–LOD3 | 正式版高性能 runtime mesh 组件 |
| Proxy Cache Manager | LOD2–LOD3 | 稳定代理版本与本地缓存 |
| Event Overlay Manager | LOD1–LOD3 | 大事件视觉覆盖与临时替换 |
| Build Worker Pipeline | 可选 LOD2/3 | 后台构建 Nanite/HLOD cache |

---

## 13. 推荐客户端模块架构

```text
UVoxelWorldSubsystem
├── FVoxelNetworkClient
│   ├── snapshot/version sync
│   ├── diff sync
│   └── major event sync
│
├── FVoxelStreamingManager
│   ├── LOD0 real window manager
│   ├── LOD1 tile shell manager
│   ├── LOD2 region proxy manager
│   └── LOD3 horizon proxy manager
│
├── FVoxelWorldgenRuntime
│   ├── deterministic sampling
│   ├── biome/material sampling
│   └── density/occupancy sampling
│
├── FVoxelMipBuilder
│   ├── 2m/4m mip
│   ├── 16m/8m mip
│   └── 64m/32m mip
│
├── FVoxelShellExtractor
│   ├── exposed-face extraction
│   ├── greedy meshing
│   ├── surface nets / dual contouring
│   └── seam fixing
│
├── FVoxelProxyCache
│   ├── runtime proxy cache
│   ├── stable proxy asset refs
│   └── version invalidation
│
└── FVoxelEventOverlayManager
    ├── VFX spawning
    ├── proxy hiding/fading
    ├── runtime replacement proxy
    └── overlay lifetime management
```

---

## 14. 推荐服务端模块架构，Elixir

```text
WorldServer
├── RegionRegistry
│   ├── RegionId -> SnapshotVersion
│   ├── dirty state
│   └── active event state
│
├── WorldgenVersionService
│   ├── current algorithm version
│   └── client compatibility check
│
├── DiffStore
│   ├── chunk/tile/region diffs
│   ├── compact diff encoding
│   └── snapshot merge jobs
│
├── EventLog
│   ├── MajorTerrainEvent
│   ├── normal player edits
│   └── audit/history
│
├── SnapshotBuilder
│   ├── periodically merge diff into snapshot
│   └── publish new region version
│
└── LODPayloadService, optional
    ├── low-res voxel mip payload
    └── neutral surface mesh payload
```

服务端可以用 Elixir/OTP 管理 region 进程、dirty 状态和事件广播，但不要依赖 UE 资产格式。

---

## 15. 运行时加载流程

### 15.1 玩家进入世界

```text
1. 客户端获得 WorldSeed、WorldgenVersion、玩家位置。
2. 请求 LOD0 真实窗口 snapshot/diff。
3. 请求 8km 内 region manifest。
4. 本地检查是否有 LOD2/LOD3 stable cache。
5. 没有 cache 的区域排队生成 runtime proxy。
6. 加载 active major events。
7. 显示 LOD0/1/2/3。
```

### 15.2 玩家跨 tile

```text
1. LOD0 真实窗口平移。
2. 卸载离开的真实 tile，加载新进入真实 tile。
3. LOD1 更新 tile shell 队列。
4. LOD2 更新 region candidate set。
5. LOD3 更新 macro candidate set。
6. 旧 proxy 进入 cache 或释放。
7. 新 proxy 按优先级异步生成。
```

### 15.3 服务端推送 diff

```text
1. 如果 diff 在 LOD0 内，立即更新真实 chunk。
2. 如果 diff 在 LOD1 内，标记 tile shell dirty。
3. 如果 diff 在 LOD2 内，标记 region dirty，低频重建 runtime proxy。
4. 如果 diff 只影响 LOD3，通常不处理，除非是 macro-level 事件。
```

### 15.4 服务端推送大事件

```text
1. 客户端创建 EventOverlay。
2. 受影响 LOD2/LOD3 stable proxy 隐藏/淡出/材质覆盖。
3. 播放 Niagara/VFX/音效/震动。
4. 生成 runtime replacement proxy。
5. 等待正式 diff/snapshot。
6. 重建 runtime proxy。
7. 未来可替换为 stable cache。
```

---

## 16. 高帧率约束

### 16.1 LOD0 约束

```text
只更新 dirty chunk。
只给近身范围生成碰撞。
tile 级 Actor 管理 chunk。
材质槽少。
Greedy meshing 必须做。
不要每个 chunk 都 Tick。
```

### 16.2 LOD1 约束

```text
无真实碰撞。
无 AI/navmesh。
tile shell mesh sections 尽量少。
异步构建。
分帧提交。
距离越远材质越简单。
```

### 16.3 LOD2 约束

```text
默认无碰撞。
默认不投动态阴影。
runtime proxy 不要过细。
第一版 16m mip。
优先显示 stable Nanite proxy。
没 cache 时才生成 runtime proxy。
大事件先用 VFX 遮挡。
```

### 16.4 LOD3 约束

```text
无碰撞。
无 AI。
无真实动态阴影。
64m mip 第一版。
只保留大轮廓和色块。
用雾和大气隐藏粗糙度。
```

---

## 17. MVP 实现顺序

### 阶段 1：LOD0 原型

目标：真实体素窗口可运行。

```text
1. 16^3 chunk 数据结构。
2. 7^3 chunk 组成 tile。
3. 3^3 tile 真实窗口。
4. Greedy meshing。
5. 简单碰撞。
6. 服务端 diff 合并。
```

### 阶段 2：LOD1 Tile Shell

目标：300m–1km 中景不空。

```text
1. 2m/4m mip。
2. tile shell extraction。
3. runtime mesh 显示。
4. LOD0/LOD1 切换。
5. 简单 skirt 防裂。
```

### 阶段 3：LOD2 Runtime Region Proxy

目标：1km–4km 有远景大形。

```text
1. 4x4x4 tile region。
2. 16m mip。
3. region shell extraction。
4. runtime proxy component。
5. region 状态机。
6. 异步生成与缓存。
```

### 阶段 4：LOD3 Horizon Proxy

目标：4km–8km 有地平线轮廓。

```text
1. 8x8x8 tile macro cell。
2. 64m mip。
3. silhouette / macro shell。
4. 雾融合材质。
5. 超远事件 overlay。
```

### 阶段 5：大事件系统

目标：核爆/坍塌不会穿帮。

```text
1. MajorTerrainEvent 协议。
2. VFX overlay。
3. affected proxy hide/fade。
4. runtime replacement proxy。
5. dirty region rebuild。
```

### 阶段 6：Stable Proxy Cache

目标：稳定远景性能进一步提升。

```text
1. 本地 stable proxy manifest。
2. StaticMesh/Nanite cache 加载。
3. RuntimeProxy 与 StableProxy 切换。
4. 可选后台 UE build worker。
```

---

## 18. 类型总表

| 类型 | 层级 | 是什么 | 从哪里来 | 谁实现 | UE 是否提供 |
|---|---|---|---|---|---|
| `Voxel` | LOD0 | 1m 体素格位 | worldgen + diff | 自研 | 否 |
| `Chunk` | LOD0 | 16^3 voxel 单元 | 客户端/服务端约定 | 自研 | 否 |
| `Tile` | LOD0/1 | 7^3 chunk 单元 | 客户端/服务端约定 | 自研 | 否 |
| `Region` | LOD2 | 4^3 tile 单元 | 客户端计算 | 自研 | 否 |
| `MacroCell` | LOD3 | 8^3 tile 单元 | 客户端计算 | 自研 | 否 |
| `Diff` | 全层 | 权威变化 | 服务端 | 自研 | 否 |
| `Snapshot` | 全层 | 区域稳定状态 | 服务端 | 自研 | 否 |
| `VoxelMip` | LOD1–3 | 低分辨率采样场 | 客户端/可选服务端 | 自研 | 否 |
| `ShellMesh` | LOD0–3 | 表面壳 mesh | 客户端生成 | 自研 | UE 只负责显示 |
| `RuntimeProxy` | LOD1–3 | 运行时普通代理 | 客户端生成 | 自研 | 部分组件可用 |
| `StableProxy` | LOD2–3 | 稳定 StaticMesh/Nanite 代理 | 预构建/缓存 | 自研管线 + UE | 部分提供 |
| `HLOD` | LOD2–3 稳定层 | UE 合并远景代理 | UE 构建流程 | UE | 是 |
| `EventOverlay` | LOD1–3 | 大事件临时表现 | 服务端事件 + 客户端 | 自研 + UE VFX | 部分提供 |
| `RVT/SVT` | LOD1–3 | 大面积材质缓存 | UE | UE 配置 | 是 |
| `NiagaraVFX` | 事件 | 爆炸/烟尘/冲击波 | 客户端表现 | UE + 自研资产 | 是 |

---

## 19. 最终架构图

```text
Elixir Server
  ├── seed
  ├── worldgen version
  ├── snapshot
  ├── diff
  └── major events
          ↓
UE Client Network Layer
          ↓
Voxel Truth Reconstruction
  ├── deterministic worldgen
  ├── diff merge
  └── snapshot versioning
          ↓
Voxel LOD Data
  ├── LOD0：1m voxel
  ├── LOD1：2m/4m mip
  ├── LOD2：16m/8m mip
  └── LOD3：64m/32m mip
          ↓
Shell Extraction
  ├── exposed faces / greedy mesh
  ├── surface nets / dual contouring
  └── seam fixing
          ↓
Rendering Layers
  ├── LOD0 real chunk mesh
  ├── LOD1 tile runtime shell
  ├── LOD2 region runtime/stable proxy
  └── LOD3 horizon runtime/stable proxy
          ↓
UE Renderer
  ├── custom UPrimitiveComponent
  ├── UDynamicMeshComponent prototype
  ├── StaticMesh/Nanite stable proxy
  ├── World Partition/HLOD stable layer
  ├── RVT/SVT material cache
  └── Niagara event overlay
```

---

## 20. 最终定案

完整方案不是“用 UE 的 HLOD 自动解决体素远景”，也不是“8km 内全部 SVO/ray marching”。

最终方案是：

```text
LOD0：
  真实 1m 体素，3x3x3 tile，完整交互。

LOD1：
  2m/4m tile shell，客户端 runtime mesh，负责 300m–1km。

LOD2：
  16m/8m 3D region proxy，4x4x4 tile，负责 1km–4km。
  runtime proxy 是主路径，稳定区域可用 Nanite StaticMesh cache。

LOD3：
  64m/32m horizon macro proxy，8x8x8 tile，负责 4km–8km。
  只保留大轮廓、剪影和色块，稳定区域可用 Nanite HLOD/impostor。

动态大事件：
  先用 EventOverlay + RuntimeReplacementProxy。
  后续再通过 snapshot/diff 低频重建。
  Nanite/HLOD 只作为稳定缓存，不进入实时地形变化主循环。
```

最重要的一句话：

> **服务端管世界真值，客户端管 LOD/proxy 生成，UE 管渲染加速；三者不要混成一层。**

---

## 21. 参考资料

- Unreal Engine Nanite Virtualized Geometry：<https://dev.epicgames.com/documentation/unreal-engine/nanite-virtualized-geometry-in-unreal-engine>
- Unreal Engine World Partition HLOD：<https://dev.epicgames.com/documentation/unreal-engine/world-partition---hierarchical-level-of-detail-in-unreal-engine>
- Unreal Engine World Partition Builder Commandlet：<https://dev.epicgames.com/documentation/unreal-engine/world-partition-builder-commandlet-reference>
- Unreal Engine Geometry Scripting Users Guide：<https://dev.epicgames.com/documentation/unreal-engine/geometry-scripting-users-guide-in-unreal-engine>
- Unreal Engine UDynamicMeshComponent API：<https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/GeometryFramework/UDynamicMeshComponent>
- Unreal Engine Runtime Virtual Texturing：<https://dev.epicgames.com/documentation/unreal-engine/runtime-virtual-texturing-in-unreal-engine>
- Unreal Engine Instanced Static Mesh Component：<https://dev.epicgames.com/documentation/unreal-engine/instanced-static-mesh-component-in-unreal-engine>
- Transvoxel Algorithm：<https://transvoxel.org/>
