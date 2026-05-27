# SceneServer 运行时边界

本目录承载项目的权威模拟和场景运行时。

## 顶层监督树

`SceneServer.Application` 启动：

- `SceneServer.InterfaceSup`
  - 节点注册和服务发现入口，测试环境之外启用
- `SceneServer.PhysicsSup`
  - 原生场景和物理集成
- `SceneServer.VoxelSup`
  - `SceneServer.Voxel.RegionRuntime`
  - `SceneServer.VoxelChunkSup`
  - `SceneServer.Voxel.ChunkDirectory`
- `SceneServer.AoiSup`
  - `SceneServer.Aoi.RemoteMirrorLedger`
  - `SceneServer.AoiManager`
  - `SceneServer.AoiItemSup`
- `SceneServer.PlayerSup`
  - `SceneServer.PlayerCharacterSup`
  - `SceneServer.PlayerManager`
- `SceneServer.NpcSup`
  - `SceneServer.NpcActorSup`
  - `SceneServer.NpcManager`

## 权威边界

### `movement/`

共享权威移动模型：

- `Profile`：共享移动调参。
- `InputFrame`：固定步长输入样本。
- `State`：权威移动状态。
- `Ack`：发给操控客户端的校正载荷。
- `RemoteSnapshot`：AOI 广播快照载荷。
- `Engine`：Rustler 移动数学的 Elixir 门面。
- `Integrator`：测试和文档使用的 Elixir 参考实现。

### `combat/`

玩家和 NPC 共享的战斗基础结构：

- `Profile`：生命值和重生默认值。
- `State`：生命值与死亡状态机。
- `Skill`：面向玩家的技能定义。
- `Targeting`：不依赖具体角色类型的 AOI 选目标逻辑。

### `worker/`

长生命周期的权威角色和基础设施：

- `PlayerCharacter`：一个在线玩家的聚合根。
- `PlayerManager`：玩家生成和索引门面。
- `AoiManager`：共享八叉树和索引。
- `Aoi.RemoteMirrorLedger`：远端 halo ghost/prewarm 需求账本，按逻辑场景和远端块聚合同一份跨 Scene 镜像复制需求，不拥有远端实体真相。
- `Aoi.AoiItem`：每个角色的 AOI 订阅和广播适配器。
- `Worker.Aoi.RemoteMirrorRunner`：一次性消费远端 halo 需求分组，触发跨 Scene
  ghost/prewarm 获取并输出可观测摘要，但不把远端 actor 放入本地 AOI
  live fan-out。

### `voxel/`

Scene 侧热体素运行时：

- `RegionRuntime`：本地租约缓存、邻区租约缓存，以及 `BoundaryVoxelEvent` 校验。
  迁移期间的旧事件会先在这里被拒绝，不能影响热体素状态。
- `ChunkProcess`：一个已租约区块的热状态拥有者。它生成快照载荷，并且必须通过
  DataService 写入令牌围栏持久化之后才提交状态。
- `ChunkDirectory`：区块进程的稳定查找和按需启动门面。

### `npc/`

建立在共享移动和战斗基础上的 NPC 专属角色模型：

- `Profile`：静态 NPC 模板和配置。
- `Facts`：只读感知快照。
- `Brain`：纯意图选择逻辑。
- `Navigation`：从意图到移动输入的转换。
- `Attack`：从 NPC 配置到战斗技能的转换。
- `State`：NPC 意图状态。
- `Actor`：一个在线 NPC 的聚合根。
- `Manager`：NPC 生成和索引门面。

NPC 细分流程见 `npc/README.md`。
