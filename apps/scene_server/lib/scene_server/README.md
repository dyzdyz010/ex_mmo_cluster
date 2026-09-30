# SceneServer 运行时边界

本目录承载 Voxim 的移动权威与身体模拟。Voxim 是唯一客户端；旧的 chunk/field/AOI/NPC/Physics 链路已于 2026-09-30 删除。

## 顶层监督树

`SceneServer.Application` 只在单 Scene 部署（设了 `VOXIM_M1_CONFIG`、没设 `VOXIM_TOPOLOGY`）时直接启动 `Movement.Scene`；
多 Scene 由 `WorldServer.Topology` 在本应用的监督树下（或 peer 节点上）启动。部署入口先启动真实 `VoxelRegion.World`。

- `SceneServer.Movement.Scene`
  - M3 公共60Hz时钟与 W1 碰撞 FIFO，发布不可变 P1 world 版本
  - 启动独立 Player DynamicSupervisor 与单个 Replication 派生 owner
  - 显式加载 D1 资产导出配置，完成 source/bootstrap 前不启动移动

## 权威边界

### `movement/`

M3 玩家移动由 `Scene` / `Player` / `InputSlots` / `CollisionUpdates` 组合：
Gate 从 Scene 入场获得唯一 Player 路由，之后直接发送已鉴权输入、Ready 和 TimeProbe。
Scene 通过 W1 显式 World 引用接收 canonical snapshot/delta；各 Player 独占输入、状态和 ACK，
只消费已发布碰撞前缀；Replication 异步消费只读步后状态。详见本目录
[`movement/README.md`](movement/README.md) 的 API、时间线和测试入口。

### `body/`

身体 L1 纯值模型（Voxim `Docs/Magic.md` §6，首片只接体温）：`Body` 保存核心 / 皮肤温度、烧伤冻伤剂量与
濒死计时，推导系统功能水平、生命值和伤病表；`Body.Thermo.step/3` 按多层模型（Stolwijk 1971 被动系统按躯干 + 头 / 四肢归并的七节点，冷暴露按实测校准，见 `body/README.md`）推进一步并返回能量账。
尚未接入 `Movement.Player`，参数与依据见 [`body/README.md`](body/README.md)。

### `native/`

`VoximMovement`：与 Voxim 客户端共享的移动内核（`native/voxim_movement_nif`，路径依赖 `../Voxim/Plugins/VoximMovement/Native`）。
`native/voxim_m0` 是同一内核的服务端离线回放实验入口。

### `prefab_designer`

无状态 prefab 设计检查，通过 `VoxelRegion.World` 正式入口发布（供 NPC 设计技能调用）。
