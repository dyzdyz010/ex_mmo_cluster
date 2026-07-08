---
status: obsolete
subsystem: voxel-far-field
superseded_by: 30-reference/overview/2026-07-06-voxia-lod-layering-and-technology-design.md
obsoleted_on: 2026-07-08
---

> ⚠️ **本文已失效** — docs/docs/30-reference/overview/2026-07-05-voxia-voxel-lod-production-route.md 与 2026-07-06-gpt55-lod23-proposal-review.md 明确标注本文档为"外部方案 v1，仅参考"，其核心主张（客户端 worldgen 采样为主）已被 2026-07-06 评审裁决拒绝，可采纳部分并入下游分层设计稿。 现行事实见 [`2026-07-06-voxia-lod-layering-and-technology-design.md`](../../30-reference/overview/2026-07-06-voxia-lod-layering-and-technology-design.md)。
> 仅存历史 provenance，**勿作现行依据**。
# UE5.8 真 3D 体素世界远景渲染方案：LOD2 / LOD3 定案

> 目标：在 **1m 体素、16m chunk、112m tile、8km 可视范围** 的真 3D 体素 MMO 中，实现高帧率远景渲染，同时保留运行时大事件（核爆、坍塌、浮空岛破坏等）对远景形态的可见影响。

---

## 0. 最终结论

LOD2 / LOD3 不应该被设计成“客户端实时生成 Nanite HLOD”，也不应该被设计成“游戏启动后永远不变的静态资产”。

正确结构是：

```text
LOD2 / LOD3
= 3D Region / Macro Cell 空间索引
+ 客户端运行时生成的 Shell Proxy Mesh
+ 可选的稳定 Nanite Static Proxy Cache
+ 大事件 Event Overlay
+ 后台低频缓存更新
```

也就是说：

```text
稳定世界：
  优先显示 Nanite / HLOD / Static Proxy Cache

动态变化：
  立即显示 Runtime Proxy + VFX + Overlay

长期稳定后：
  再低频生成新的稳定缓存
```

服务端是 Elixir，因此服务端不应管理 UE 资产。服务端只管理世界真值、版本、diff、事件和中立数据。UE 客户端负责把这些数据转换成本地渲染对象。

---

## 1. 基础尺寸与坐标单位

### 1.1 已确定单位

| 类型 | 含义 | 尺寸 |
|---|---|---:|
| `Voxel` | 基础体素 | 1m × 1m × 1m |
| `Chunk` | 基础体素存储/编辑单位 | 16 × 16 × 16 voxel = 16m 边长 |
| `Tile` | 客户端近景流送单位 | 7 × 7 × 7 chunk = 112m 边长 |
| `LOD0 Window` | 真实近景窗口 | 3 × 3 × 3 tile = 336m 边长 |

### 1.2 数量关系

```text
1 chunk = 16^3 = 4096 voxel slots
1 tile = 7^3 = 343 chunks
LOD0 window = 3^3 = 27 tiles
LOD0 chunk count = 27 × 343 = 9261 chunks
LOD0 voxel slot count = 9261 × 4096 = 37,933,056 voxel slots
```

这里的 `voxel slot` 是空间槽位，不代表每个槽位都必须常驻存储。真实实现应该是稀疏存储、chunk dirty、按需生成。

---

## 2. 全局 LOD 分层

| 层级 | 距离范围 | 精度 | 空间单位 | 主要职责 | 主要渲染方式 |
|---|---:|---:|---|---|---|
| LOD0 | 0–约300m | 1m | Chunk / Tile | 真实交互、碰撞、破坏、建造 | 自定义动态体素渲染 / Greedy Mesh / HISM |
| LOD1 | 约300m–1km | 2m / 4m | 3D Tile Shell | 中景外壳，承接近景到远景 | Runtime Mesh / 自定义 UPrimitiveComponent |
| LOD2 | 约1km–4km | 16m，后期可局部 8m | 3D Region Shell | 远景大形、山体、浮空岛、巨构 | Runtime Proxy 为主；稳定区可 Nanite Static Proxy |
| LOD3 | 约4km–8km | 64m，后期可局部 32m | 3D Macro / Horizon Shell | 地平线剪影、大色块、巨型轮廓 | Horizon Proxy / Impostor / Nanite Static Proxy |
| 8km 外 | 8km+ | 无真实几何 | 无 | 天空、大气、极远视觉暗示 | Sky / Fog / 非真实剪影 |

本文重点只定义 **LOD2 / LOD3**。

---

## 3. 核心概念定义

### 3.1 Shell

`Shell` 指“实体体素与空气/空空间交界处的表面集合”。

方块体素的最简单 shell 判断：

```cpp
for each voxel v:
    if IsSolid(v):
        for each dir in SixDirections:
            if IsAir(v + dir):
                EmitFace(v, dir);
```

也就是说：

```text
实体旁边还是实体：不生成面
实体旁边是空气：生成面
完全埋在内部的实体：不渲染
```

对于自然地形风格，可以把 `IsSolid` 换成 SDF / density field 的等值面判断，然后用 Surface Nets、Dual Contouring 或 Marching Cubes 提取表面。

### 3.2 Proxy Mesh

`Proxy Mesh` 是由体素真值或低精度体素 mip 生成的三角网格代理。

它不是世界真值，只是渲染缓存。

```text
World Truth = seed + worldgen version + snapshot + diff
Proxy Mesh = 从 World Truth 派生出来的可丢弃渲染数据
```

### 3.3 Runtime Proxy

`Runtime Proxy` 是客户端在游戏运行时生成的普通 mesh。

特点：

```text
可以运行时生成
可以运行时替换
可以响应大事件
通常不支持 Nanite
通常不参与真实碰撞
不作为权威世界状态
```

UE 中可用的组件：

```text
原型：UDynamicMeshComponent / UProceduralMeshComponent
正式：自定义 UPrimitiveComponent + FPrimitiveSceneProxy + 自己的 Vertex/Index Buffer
```

### 3.4 Stable Proxy / Base Proxy

`Stable Proxy` 是稳定世界状态下的远景代理。

特点：

```text
低频更新
可以预构建
可以本地缓存
可以变成 Static Mesh
可以开启 Nanite
可以接入 World Partition / HLOD
```

它适合表示：

```text
稳定山体
稳定浮空岛
稳定大建筑
稳定城市外壳
稳定地平线轮廓
```

不适合表示：

```text
核爆后一秒内的新坑洞
玩家实时挖掘产生的地形变化
频繁改拓扑的远景区域
```

### 3.5 Event Overlay

`Event Overlay` 是大事件发生后立即给玩家看的临时视觉层。

包括：

```text
Niagara 爆炸 / 烟尘 / 冲击波
Runtime Crater Mesh
Burn / Dust / Snow / Ash material mask
Decal / RVT 写入
隐藏旧 proxy 的遮挡层
临时坍塌模型
```

它的目的不是精确表达世界真值，而是让画面立即可信。

### 3.6 Snapshot / Diff

| 类型 | 含义 | 归属 |
|---|---|---|
| `Snapshot` | 某个区域在某个版本的稳定状态 | 服务端权威 |
| `Diff` | 相对于 worldgen / snapshot 的体素变化 | 服务端权威 |
| `Render Proxy Cache` | 根据 snapshot + diff 派生的渲染代理 | 客户端缓存 / 可选后台构建 |

---

## 4. 服务端、客户端、UE 各自负责什么

### 4.1 Elixir 服务端负责

服务端管理世界真值，不管理 UE 资产。

服务端负责：

```text
world seed
worldgen version
region / tile / chunk id
snapshot version
authoritative diff
major event log
region dirty state
player AOI / interest management
低精度 mip 或 compact diff 的下发
```

服务端不负责：

```text
.uasset
Nanite cooked data
World Partition Actor
HLOD Actor
StaticMesh asset
Material instance
UE component
UE collision asset
```

### 4.2 UE 客户端负责

客户端负责把服务端下发的中立数据变成可显示内容。

客户端负责：

```text
本地 deterministic worldgen 采样
合并服务端 diff
生成 LOD2 / LOD3 voxel mip
提取 shell
生成 runtime proxy mesh
管理 proxy 的显示、隐藏、替换和淡入淡出
播放 event overlay
管理本地 stable proxy cache
接入 UE 渲染组件
```

### 4.3 UE 引擎提供

UE 提供的是渲染基础设施，不提供体素远景 shell 系统。

UE 提供：

```text
UDynamicMeshComponent / UProceduralMeshComponent：运行时 mesh 原型
UPrimitiveComponent / FPrimitiveSceneProxy：正式自定义渲染组件基础
Static Mesh：稳定代理资产载体
Nanite：稳定高面数代理的虚拟化几何渲染
World Partition：大世界静态/准静态 actor 流送
World Partition HLOD：稳定远景代理的合并和显示
Runtime Virtual Texture：大面积地表/远景材质缓存
Virtual Texture：大贴图流送
ISM / HISM：重复物实例化
Niagara：事件 VFX
Frustum / Occlusion Culling：常规可见性剔除
```

UE 不提供：

```text
从你的体素真值自动生成 3D shell 的系统
自动理解你的 Elixir diff 的系统
运行时高频生成 Nanite HLOD 的稳定 gameplay 管线
真 3D 体素 MMO 的 region version 状态机
体素 LOD seam 逻辑
核爆后远景地形代理替换逻辑
```

---

## 5. LOD2 定案：3D Region Surface Proxy

### 5.1 目标

LOD2 负责 1km–4km 范围内的可信远景大形。

它不负责真实交互，也不负责精确体素细节。

显示内容：

```text
山体外壳
浮空岛外壳
大型建筑外壳
巨型洞口轮廓
悬崖轮廓
大裂谷
大型水体表面
核爆、塌方等大事件后的远景轮廓
```

剔除内容：

```text
山体内部
地下洞穴深处
每个 1m 体素细节
单棵树
小建筑构件
近战可交互物
碰撞
AI 数据
```

### 5.2 空间单位

推荐第一版：

```text
LOD2 Region = 4 × 4 × 4 tile
            = 448m × 448m × 448m
```

原因：

```text
1 tile = 112m
4 tile = 448m
1km–4km 范围内 region 数量可控
region 不至于太大，便于 dirty/rebuild/replace
```

### 5.3 精度

第一版推荐：

```text
LOD2 voxel mip = 16m
```

优势：

```text
16m 正好等于 chunk 边长
448m / 16m = 28
每个 LOD2 region 采样约 28^3 = 21,952 个 cell
客户端后台生成压力可控
```

后期可对重要区域改用 8m：

```text
448m / 8m = 56
56^3 = 175,616 个 cell
质量更好，但生成和内存成本更高
```

### 5.4 数据来源

LOD2 的数据来源不是服务端直接下发完整 1m 体素。

推荐来源：

```text
客户端本地 deterministic worldgen
+ 服务端 compact diff
+ 服务端 snapshot version
+ major event descriptor
```

必要时，服务端可以直接下发：

```text
LOD2 voxel mip patch
或
LOD2 surface mesh payload
```

但第一优先级应是让客户端用相同 worldgen 生成基础形状，服务端只下发差异。

### 5.5 客户端生成流程

```text
1. 根据玩家位置计算需要哪些 LOD2 regions
2. 根据 RegionId 运行本地 worldgen 采样 16m mip
3. 拉取服务端 snapshot version / diff / event
4. 合并 diff 到低精度 occupancy / density field
5. 执行 shell extraction
6. 执行 greedy meshing / dual contouring
7. 执行 seam 处理
8. 生成 runtime proxy mesh
9. 提交到 UE 渲染组件
10. 如果有 stable Nanite cache，则优先显示 stable cache
```

### 5.6 Shell 提取算法选择

方块风格：

```text
Occupancy voxel mip
→ Face exposure test
→ Greedy meshing
→ Material atlas / texture array
```

自然地形：

```text
Density / SDF mip
→ Surface Nets / Dual Contouring
→ 简化法线和材质
→ seam stitching
```

如果你的主世界仍是方块感，第一版建议先做方块式：

```text
16m occupancy mip + exposed face + greedy mesh
```

这比一开始上 Dual Contouring 更容易验证完整流送和版本系统。

### 5.7 UE 渲染方式

LOD2 分成两条渲染路径。

#### 5.7.1 Runtime Proxy 路径

用于：

```text
刚进入视野但没有稳定缓存的 region
服务端版本已更新的 dirty region
大事件后的临时地形
客户端后台生成的普通代理
```

UE 组件：

```text
原型阶段：UDynamicMeshComponent / UProceduralMeshComponent
正式阶段：UVoxelRegionProxyComponent : UPrimitiveComponent
```

正式版建议自己实现：

```text
FPrimitiveSceneProxy
FVertexBuffer
FIndexBuffer
FLocalVertexFactory
FMeshBatch
异步 MeshData 生成
主线程分帧提交
```

#### 5.7.2 Stable Proxy 路径

用于：

```text
稳定世界状态
很少变化的山体/浮空岛/大建筑
客户端已有缓存的远景 region
后台构建过的 proxy
```

UE 组件：

```text
StaticMeshComponent
Nanite enabled Static Mesh
World Partition / HLOD 可选接入
```

注意：Stable Proxy 可以被替换，但不应被当作高频动态拓扑对象。

---

## 6. LOD3 定案：3D Macro / Horizon Shell

### 6.1 目标

LOD3 负责 4km–8km 的地平线和超远景。

它的目标不是“粗体素世界”，而是：

```text
远处大轮廓可信
地平线丰富
玩家感觉世界巨大
性能成本极低
```

显示内容：

```text
远山剪影
浮空岛剪影
超大型城市/巨构轮廓
大裂谷方向
海岸线 / 大湖 / 大河
大森林色块
火山、核爆蘑菇云、巨型魔法事件的宏观轮廓
```

剔除内容：

```text
洞穴入口细节
建筑窗户
单个 chunk 级变化
单棵树
小山坡细节
局部破坏
真实洞穴内部
动态阴影
碰撞
```

### 6.2 空间单位

推荐第一版：

```text
LOD3 Macro Cell = 8 × 8 × 8 tile
                = 896m × 896m × 896m
```

后期可测试：

```text
16 × 16 × 16 tile = 1792m 边长
```

但第一版用 896m 更稳，便于大事件局部替换。

### 6.3 精度

第一版推荐：

```text
LOD3 voxel mip = 64m
```

数量：

```text
896m / 64m = 14
14^3 = 2744 个采样 cell
```

重要区域可用 32m：

```text
896m / 32m = 28
28^3 = 21,952 个采样 cell
```

LOD3 的成本应该远低于 LOD2。

### 6.4 数据来源

LOD3 不应该接收普通小 diff。

来源应是：

```text
客户端 deterministic worldgen 的宏观采样
+ 服务端 major event descriptor
+ 少量 macro diff
+ snapshot version
```

普通玩家挖洞、建房、砍树，不应该影响 LOD3。

### 6.5 客户端生成流程

```text
1. 计算 4km–8km 内的 Macro Cells
2. 根据视锥和距离剔除不可见 macro cell
3. 用本地 worldgen 生成 64m macro field
4. 应用 major event descriptor，例如核爆 crater、浮空岛坠落、火山喷发
5. 生成极简 horizon shell / silhouette mesh
6. 绑定极简远景材质
7. 通过雾、大气、颜色渐变隐藏切换边界
```

### 6.6 UE 渲染方式

LOD3 可用三种形式：

```text
A. Runtime Horizon Mesh
   用于当前动态生成的宏观轮廓

B. Nanite Static Horizon Proxy
   用于稳定远景大形

C. Impostor / Billboard / Card
   用于极远浮空岛、城市轮廓、山脉剪影
```

优先级建议：

```text
第一版：Runtime Horizon Mesh + 极简材质
第二版：稳定区域缓存为 Static Mesh
第三版：重要稳定远景改成 Nanite Static Proxy / HLOD
```

---

## 7. LOD2 / LOD3 的运行时状态机

每个远景 region / macro cell 不只是“加载/未加载”，而应该有状态。

```cpp
enum class EFarProxyState
{
    Missing,          // 没有可显示代理
    Generating,       // 客户端后台生成中
    RuntimeReady,     // Runtime Proxy 可显示
    StableCached,     // 有 Stable / Nanite Proxy 可显示
    Dirty,            // 服务端版本更新，旧代理过期
    Replacing,        // 新旧代理切换中
    HiddenByEvent,    // 被爆炸、烟尘、大事件临时遮挡
    Unloaded          // 已离开可视范围
};
```

推荐数据结构：

```cpp
struct FFarRegionProxy
{
    FRegionId RegionId;
    int32 LODLevel; // 2 or 3

    int32 SnapshotVersion;
    int32 LocalGeneratedVersion;
    int32 ServerKnownVersion;

    EFarProxyState State;

    UStaticMeshComponent* StableProxyComponent;
    UVoxelRuntimeProxyComponent* RuntimeProxyComponent;

    TArray<FActiveEventOverlay> ActiveOverlays;

    double LastVisibleTime;
    double LastRebuildRequestTime;
    bool bDirtyFromServer;
};
```

### 7.1 状态转换

```text
Missing
  → Generating
  → RuntimeReady

StableCached
  → Dirty
  → Generating
  → Replacing
  → RuntimeReady 或 StableCached

StableCached
  → HiddenByEvent
  → RuntimeReady
  → Replacing
  → StableCached
```

### 7.2 切换原则

```text
不要瞬间切换远景轮廓
用雾、烟尘、距离淡入淡出隐藏切换
region 粒度不能过大，否则隐藏/替换会太明显
LOD2 的 region 建议 448m
LOD3 的 macro cell 建议 896m
```

---

## 8. 大事件处理：核爆示例

### 8.1 事件包

服务端广播的是世界事件，不是 UE 资产。

```cpp
struct FMajorTerrainEvent
{
    FGuid EventId;
    EEventType Type; // NuclearExplosion, Earthquake, IslandCollapse, etc.

    FVector Location;
    float Radius;
    float Strength;
    double ServerTime;

    int32 BeforeSnapshotVersion;
    int32 AfterSnapshotVersion;

    TArray<FRegionId> AffectedLOD2Regions;
    TArray<FRegionId> AffectedLOD3MacroCells;

    FEventVisualDescriptor Visual;
};
```

### 8.2 客户端流程

```text
T + 0s：
  收到 MajorTerrainEvent

T + 0.1s：
  播放远景闪光、冲击波、蘑菇云、音效延迟

T + 0.5s：
  affected LOD2 / LOD3 region 进入 HiddenByEvent
  旧 Stable Proxy 被烟尘/火球遮挡

T + 1s：
  客户端生成 Runtime Crater Proxy / Collapse Proxy
  暂时隐藏旧的 affected Stable Proxy

T + 3–10s：
  服务端下发 compact region diff 或 LOD2/LOD3 replacement payload
  客户端后台重建 Runtime Proxy

T + 后续：
  事件区域进入 Dirty 状态
  等待稳定后低频生成新的 Stable Proxy Cache
```

### 8.3 画面合成

```text
Final Far View
= Base Stable Proxy
+ Runtime Replacement Proxy
+ Event Overlay
+ VFX / Smoke / Fog
+ Material Masks
```

核爆不应该等待 Nanite HLOD 构建完成后再显示地形变化。正确做法是先显示 VFX 和 Runtime Proxy，长期再缓存为 Stable Proxy。

---

## 9. Nanite / HLOD 在本方案中的位置

### 9.1 Nanite 适合做什么

Nanite 适合：

```text
稳定的远景山体 proxy
稳定的浮空岛 proxy
稳定的巨构/城市外壳 proxy
稳定的 LOD2 region base proxy
稳定的 LOD3 horizon proxy
高几何复杂度但低频变化的静态网格
```

### 9.2 Nanite 不适合做什么

Nanite 不适合：

```text
玩家正在挖的近景 chunk
频繁改拓扑的 runtime voxel mesh
核爆后立即出现的新 crater mesh
每秒重新生成的体素代理
客户端 gameplay loop 内高频构建 HLOD
```

### 9.3 HLOD 适合做什么

World Partition HLOD 适合：

```text
大量稳定 Static Mesh Actor 的远景代理合并
显示未加载的 World Partition cell
减少 draw call
稳定开放世界区域的预构建代理
```

### 9.4 HLOD 不适合做什么

HLOD 不适合：

```text
运行时体素 diff 的即时显示
真 3D region 状态机
核爆后的秒级地形变更
客户端每个玩家本地实时构建 Nanite HLOD
```

---

## 10. 后台构建策略

### 10.1 客户端后台：Runtime Proxy

这是主路线。

```text
输入：seed + diff + mip + event descriptor
输出：runtime vertex/index buffer
适用：LOD2/LOD3 的即时远景更新
耗时目标：几十毫秒到数秒，取决于 region 精度和复杂度
```

注意：这个不是 Nanite 构建。

### 10.2 独立 UE Build Worker：Stable Nanite Proxy

这是可选长期优化。

```text
Elixir Game Server：
  只输出世界版本和 dirty region 信息

UE Build Worker：
  使用 UnrealEditor / commandlet / 内部工具
  生成 StaticMesh / Nanite / HLOD proxy

CDN / Patch Storage：
  分发稳定 proxy cache

UE Client：
  下次加载或区域重进时使用新的 stable proxy
```

这种方式适合：

```text
赛季更新
长期世界变化
大型战役后地图永久改变
服务端低负载时批量刷新远景缓存
```

不适合：

```text
核爆后一秒内更新画面
玩家挖山后立即生成 Nanite HLOD
```

---

## 11. 类型清单：从哪里来、谁实现、UE 提供什么

### 11.1 世界/网络类型

| 类型 | 含义 | 来源 | 谁实现 |
|---|---|---|---|
| `WorldSeed` | 确定性世界生成种子 | 服务端下发 / 客户端缓存 | 自己实现 |
| `WorldgenVersion` | 世界生成算法版本 | 服务端权威 | 自己实现 |
| `SnapshotVersion` | 区域稳定状态版本 | 服务端权威 | 自己实现 |
| `RegionId` | LOD2 3D region 坐标 | 客户端/服务端共同计算 | 自己实现 |
| `MacroCellId` | LOD3 macro cell 坐标 | 客户端/服务端共同计算 | 自己实现 |
| `ChunkDiff` | 近景 chunk 变化 | 服务端权威 | 自己实现 |
| `RegionDiff` | LOD2 低频区域变化 | 服务端权威 | 自己实现 |
| `MacroDiff` | LOD3 大事件变化 | 服务端权威 | 自己实现 |
| `MajorTerrainEvent` | 核爆/地震/坍塌等事件 | 服务端广播 | 自己实现 |

### 11.2 体素/LOD 数据类型

| 类型 | 含义 | 来源 | 谁实现 |
|---|---|---|---|
| `VoxelMip0` | 1m 真实体素 | worldgen + diff | 自己实现 |
| `VoxelMip1` | 2m/4m 中景体素 | 客户端生成 / 可服务端辅助 | 自己实现 |
| `VoxelMip2` | 8m/16m 远景体素 | 客户端生成 / 服务端 diff 修正 | 自己实现 |
| `VoxelMip3` | 32m/64m 超远景体素 | 客户端生成 / 大事件修正 | 自己实现 |
| `OccupancyField` | solid/air 低精度场 | 客户端生成 | 自己实现 |
| `DensityField` | SDF/density 场 | 客户端生成 | 自己实现 |
| `MaterialIdField` | 材质 ID 场 | worldgen + diff | 自己实现 |
| `BiomeField` | 生物群落/颜色场 | worldgen | 自己实现 |

### 11.3 Mesh 生成类型

| 类型 | 含义 | 来源 | 谁实现 |
|---|---|---|---|
| `VoxelShellExtractor` | 从 voxel/density 中提取 shell | 客户端 C++ | 自己实现 |
| `GreedyMesher` | 合并共面方块面 | 客户端 C++ | 自己实现 |
| `DualContouringMesher` | 自然地形表面提取 | 客户端 C++，后期 | 自己实现 |
| `SeamStitcher` | LOD 边界缝合/skirt | 客户端 C++ | 自己实现 |
| `ProxyMeshData` | 顶点/索引/材质数据 | 客户端生成 | 自己实现 |
| `RuntimeProxyMesh` | 运行时显示的 mesh 数据 | 客户端生成 | 自己实现 + UE 组件承载 |

### 11.4 UE 渲染类型

| 类型 | 含义 | 来源 | 谁提供 |
|---|---|---|---|
| `UDynamicMeshComponent` | 运行时动态 mesh 组件 | UE | UE 提供，适合原型 |
| `UProceduralMeshComponent` | 运行时过程 mesh 组件 | UE | UE 提供，适合原型 |
| `UPrimitiveComponent` | 自定义渲染组件基类 | UE | UE 提供基础，你自己实现子类 |
| `FPrimitiveSceneProxy` | 渲染线程代理 | UE | UE 提供基础，你自己实现子类 |
| `UStaticMesh` | 稳定静态网格资产 | UE | UE 提供 |
| `Nanite` | 虚拟化几何渲染 | UE | UE 提供 |
| `World Partition` | 大世界流送 | UE | UE 提供 |
| `World Partition HLOD` | 静态远景代理合并 | UE | UE 提供 |
| `Runtime Virtual Texture` | 运行时虚拟纹理 | UE | UE 提供 |
| `Niagara` | VFX 系统 | UE | UE 提供 |
| `ISM / HISM` | 实例化静态网格 | UE | UE 提供 |

---

## 12. 推荐客户端模块划分

### 12.1 `UVoxelFarViewSubsystem`

职责：

```text
管理 LOD2/LOD3 region 生命周期
根据玩家位置计算可视 region
发起服务端请求
管理状态机
调度后台生成任务
管理 proxy 切换
```

### 12.2 `FVoxelRegionKey / FMacroCellKey`

职责：

```text
把世界坐标映射到 LOD2 region / LOD3 macro cell
支持 hash map 查询
支持版本管理
```

### 12.3 `FVoxelMipBuilder`

职责：

```text
从 worldgen + diff 生成 16m / 64m mip
输出 OccupancyField / DensityField / MaterialIdField
```

### 12.4 `FVoxelShellExtractor`

职责：

```text
从 mip field 生成可见表面
方块风格：exposed face
自然风格：SDF 等值面
```

### 12.5 `FVoxelProxyMesher`

职责：

```text
执行 greedy meshing
生成 vertices / indices / material sections
压缩顶点格式
合并材质槽
生成 bounds
```

### 12.6 `UVoxelRuntimeProxyComponent`

职责：

```text
把 ProxyMeshData 提交给 UE 渲染
支持异步数据交换
支持淡入淡出
支持隐藏/显示
支持 event overlay 叠加
```

第一版可以先包装 `UDynamicMeshComponent`，正式版再改成自定义 `UPrimitiveComponent`。

### 12.7 `UVoxelStableProxyCache`

职责：

```text
管理本地 Stable Proxy 缓存
根据 RegionId + SnapshotVersion 查找可用 StaticMesh
判断是否过期
支持 fallback 到 Runtime Proxy
```

---

## 13. LOD2/3 渲染优先级

每个 region / macro cell 的显示优先级：

```text
1. 如果被大事件遮挡：显示 Event Overlay，隐藏或淡出旧 proxy
2. 如果有最新 Stable Proxy：显示 Nanite / Static Proxy
3. 如果 Stable Proxy 过期但 Runtime Proxy 可用：显示 Runtime Proxy
4. 如果正在生成：显示低一级 LOD 或临时极简 proxy
5. 如果完全不可见：不生成、不显示
```

伪代码：

```cpp
void UpdateFarRegion(FFarRegionProxy& Region)
{
    if (!IsInViewRange(Region))
    {
        UnloadOrKeepWarm(Region);
        return;
    }

    if (HasActiveMajorEvent(Region))
    {
        ShowEventOverlay(Region);
        HideOrFadeStableProxy(Region);
        EnsureRuntimeReplacementQueued(Region);
        return;
    }

    if (HasFreshStableProxy(Region))
    {
        ShowStableProxy(Region);
        HideRuntimeProxyIfNotNeeded(Region);
        return;
    }

    if (HasRuntimeProxy(Region))
    {
        ShowRuntimeProxy(Region);
        return;
    }

    QueueRuntimeProxyBuild(Region);
    ShowFallbackLowerLOD(Region);
}
```

---

## 14. 性能规则

### 14.1 LOD2 性能规则

```text
默认 16m mip，不要第一版就上 8m 全覆盖
region = 4x4x4 tile，不要太大
runtime mesh 不做复杂碰撞
大多数 LOD2 proxy 不投动态阴影
材质槽尽量少
优先 opaque
尽量用 atlas / texture array
后台生成 mesh，主线程只提交
旧新 proxy 交叉淡入淡出
```

### 14.2 LOD3 性能规则

```text
默认 64m mip
macro cell = 8x8x8 tile
只保留大轮廓
基本不投动态阴影
靠雾和大气隐藏细节
能 impostor 就不要真实高精 mesh
普通小 diff 不影响 LOD3
```

### 14.3 禁止事项

```text
不要加载 8km 内完整 3D 体素体积
不要让服务端下发 1m 体素给 LOD2/3
不要每次玩家挖方块都更新 LOD2/3
不要把 runtime proxy 当成 Nanite
不要把 HLOD build 放进实时 gameplay loop
不要让每个 chunk 都成为 UE Actor
不要让 9261 个近景 chunk 各自 Tick
```

---

## 15. 第一版 MVP 实现顺序

### 阶段 1：LOD2 Runtime Proxy

```text
1. 定义 RegionId：4x4x4 tile
2. 实现 16m occupancy mip 采样
3. 实现 exposed face shell extraction
4. 实现 greedy meshing
5. 用 UDynamicMeshComponent 显示
6. 距离 1–4km 内按 region 加载/卸载
```

### 阶段 2：LOD3 Horizon Proxy

```text
1. 定义 MacroCellId：8x8x8 tile
2. 实现 64m macro field
3. 生成极简 silhouette / shell mesh
4. 加入雾融合材质
5. 4–8km 范围加载/卸载
```

### 阶段 3：大事件 Overlay

```text
1. 定义 MajorTerrainEvent
2. 核爆事件影响 LOD2/3 region
3. 隐藏旧 proxy
4. 播放 Niagara VFX
5. 生成 Runtime Crater Proxy
6. 后台重建 affected region
```

### 阶段 4：Stable Proxy Cache

```text
1. 为稳定 region 生成 StaticMesh proxy
2. 本地缓存 RegionId + SnapshotVersion
3. Stable cache 命中时替换 runtime proxy
4. 需要时开启 Nanite
```

### 阶段 5：正式渲染组件

```text
1. 把 UDynamicMeshComponent 原型换成自定义 UVoxelRuntimeProxyComponent
2. 实现 render buffer 更新
3. 分帧提交
4. 减少组件数量和 draw call
5. 接入材质 atlas / RVT
```

### 阶段 6：可选 UE Build Worker

```text
1. 独立 UnrealEditor commandlet 生成稳定 proxy
2. 不接入 Elixir 实时 gameplay loop
3. 输出客户端可下载的 proxy package
4. 用于长期稳定世界缓存
```

---

## 16. 参考 UE 能力边界

以下是本方案依赖的 UE 能力边界：

1. Nanite 是 UE 的虚拟化几何系统，适合启用 Nanite 的三角网格 / Static Mesh 类型资源，并通过内部格式和流送机制进行高效渲染；但 Nanite 构建需要处理时间，不应作为实时体素拓扑变更的主路径。  
   Reference: Unreal Engine Documentation — Nanite Virtualized Geometry  
   https://dev.epicgames.com/documentation/unreal-engine/nanite-virtualized-geometry-in-unreal-engine

2. World Partition HLOD 通过 HLOD Layer 组织大量 Static Mesh Actors，并生成 proxy mesh 和 material，用于显示未加载的 World Partition cell、减少 draw call、提升大世界性能。  
   Reference: Unreal Engine Documentation — World Partition HLOD  
   https://dev.epicgames.com/documentation/unreal-engine/world-partition---hierarchical-level-of-detail-in-unreal-engine

3. World Partition HLODs Builder commandlet 是 HLOD 生成流程的一部分，更适合编辑器/构建管线，而不是实时 gameplay loop。  
   Reference: Unreal Engine Documentation — World Partition Builder Commandlet Reference  
   https://dev.epicgames.com/documentation/unreal-engine/world-partition-builder-commandlet-reference

4. UDynamicMesh / Geometry Scripting 支持运行时创建和修改 mesh 数据，适合作为 runtime mesh 原型基础；但它不是 Nanite/HLOD 的替代品。  
   Reference: Unreal Engine Documentation — Geometry Scripting Users Guide  
   https://dev.epicgames.com/documentation/unreal-engine/geometry-scripting-users-guide-in-unreal-engine

5. Runtime Virtual Texture 可以在运行时按需生成和缓存 texel 数据，适合大面积地表、远景材质、类似 decal/spline 的材质效果。  
   Reference: Unreal Engine Documentation — Runtime Virtual Texturing  
   https://dev.epicgames.com/documentation/unreal-engine/runtime-virtual-texturing-in-unreal-engine

---

## 17. 最终架构图

```text
Elixir Game Server
  ├── WorldSeed
  ├── WorldgenVersion
  ├── SnapshotVersion
  ├── Authoritative Diff
  ├── MajorTerrainEvent
  └── Region Dirty State
              │
              │ 中立数据，不是 UE 资产
              ▼
UE Client
  ├── Deterministic Worldgen Sampler
  ├── VoxelMipBuilder
  │     ├── LOD2: 16m / 8m mip
  │     └── LOD3: 64m / 32m mip
  ├── VoxelShellExtractor
  ├── ProxyMesher
  ├── FarProxyStateMachine
  ├── Runtime Proxy Layer
  │     ├── LOD2 Runtime Region Proxy
  │     └── LOD3 Runtime Horizon Proxy
  ├── Event Overlay Layer
  │     ├── Niagara
  │     ├── Crater Mesh
  │     ├── Dust/Burn Mask
  │     └── Proxy Hide/Fade
  └── Stable Proxy Cache Layer
        ├── StaticMesh Proxy
        ├── Nanite optional
        └── World Partition / HLOD optional
```

---

## 18. 一句话定案

LOD2 / LOD3 的最终方案是：

```text
LOD2：
  1km–4km
  4x4x4 tile region
  16m mip 第一版
  Runtime Shell Proxy 为主
  稳定区域可缓存为 Nanite Static Proxy

LOD3：
  4km–8km
  8x8x8 tile macro cell
  64m mip 第一版
  Horizon / Macro Shell Proxy 为主
  稳定区域可缓存为 Nanite / HLOD / Impostor

动态事件：
  永远先走 Runtime Proxy + Event Overlay
  不等待 Nanite/HLOD

服务端：
  只管 seed、diff、snapshot、event、version
  不管 UE 资产

客户端：
  负责 worldgen 采样、shell 提取、proxy mesh 生成、状态机和 UE 渲染承载
```

