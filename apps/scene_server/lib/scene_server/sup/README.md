# Scene 监督树子树

本目录包含用于组织 Scene 运行时树的小型监督器包装模块。

## 当前子树

- `InterfaceSup`
  - `SceneServer.Interface`
- `PhysicsSup`
  - `SceneServer.PhysicsManager`
- `VoxelSup`
  - `SceneServer.Voxel.RegionRuntime`
  - `SceneServer.VoxelChunkSup`
  - `SceneServer.Voxel.ChunkDirectory`
- `AoiSup`
  - `SceneServer.AoiManager`
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
