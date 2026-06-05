# Scene 监督树子树

本目录包含用于组织 Scene 运行时树的小型监督器包装模块。

## 当前子树

- `InterfaceSup`
  - `SceneServer.Interface`
- `PhysicsSup`
  - `SceneServer.PhysicsManager`
- `VoxelSup`
  - `SceneServer.Voxel.RegionRuntime`
  - `SceneServer.Voxel.ChunkRegistry`（chunk 进程身份注册表，`Registry` `:unique`；
    必须早于 `VoxelChunkSup` / `ChunkDirectory`）
  - `SceneServer.Voxel.ChunkPersistPool`（阶段5.2：有界 write-behind 持久化池，
    poolboy；对 DB 写施背压，必须早于任何 chunk 启动）
  - `SceneServer.VoxelChunkSup`
  - `SceneServer.Voxel.ChunkDirectory`（无状态 facade；热路径已 Registry 直达 +
    碰撞读走 `ChunkOccupancyTable` ETS 快照，facade 只承载生命周期串行操作）
- `AoiSup`
  - `SceneServer.Aoi.RemoteMirrorLedger`
  - `SceneServer.Aoi.IndexHeir`（AOI 索引 ETS 表的 heir，必须先于 IndexStore 启动）
  - `SceneServer.Aoi.IndexStore`（八叉树句柄 + CID 索引 ETS 表的权威 owner；替代旧的单点
    `AoiManager` GenServer，`AoiManager` 现为无状态 facade，不进监督树）
  - `SceneServer.AoiItemSup`
- `PlayerSup`
  - `SceneServer.PlayerCharacterSup`
  - `SceneServer.PlayerManager`
- `NpcSup`
  - `SceneServer.NpcActorSup`
  - `SceneServer.NpcManager`

## 为什么保持包装模块轻量

这些包装模块让应用监督树更容易阅读，并为每个子系统提供稳定归属。领域逻辑不应塞进
监督器；监督器只负责启动、重启和组织进程。
