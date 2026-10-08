# GateServer 运行时边界

GateServer 负责鉴权、会话与 Voxim 协议解码转发，不拥有权威玩法状态。

## 顶层监督树（测试构建之外）

- `GateServer.Session.Claims`：Gate 侧唯一的会话身份分配
- `GateServer.Transport.QuicListener`：Voxim QUIC 监听与每连接进程
- `GateServer.NpcNames`：在跑的 NPC Body 按 cid 的登记（重复键 `Registry`，`Body.start/2` 填），NPC 注册表据此找到它们
- `GateServer.NpcSup`：NPC 身体（`npc/`）的动态监督器；Body 为 transient，会话丢失由 Body 自己重新 claim，只有崩溃才经监督者重启（见 `npc/README.md`）
- 一次性 Task `GateServer.Npc.Registry.start_all/0`：拉起 NPC 注册表（`npc_specs` 表）里全部 enabled 的 NPC，节点重启后它们自动回来

## Voxim M1 正式入口

Gate 只有 Voxim QUIC 一条入口：启动 `QuicListener` 与每连接的
`QuicConnection`。TLS/ALPN `voxim-m1`、两个固定双向可靠流（purpose 1 control / 2 voxel）
与 DATAGRAM 共用一个 QUIC connection；没有 TCP/fast-lane 自动回退。
部署必须提供证书、key、UDP 端口、kernel/profile identity；M1 编辑还需显式
`VOXIM_M1_CONFIG`，范围从 `Scene.load_config!/1` 取得。UE CA 是连接私有的信任根，不导入系统证书库。

Auth token、username、cid 同时验证后，由 Gate 唯一分配 session epoch 并调用 Scene.join。
Scene 仅用 `Sink.reliable/4`、`datagram/3`、`close/3` 出站；close 先可靠发送 SessionEnd 并完成
control send shutdown，再关闭连接。Scene 的 voxel 出口保持 transaction/marker 顺序；旧 R6
subscribe 只接纳该客户端编辑资格，不创建第二份 World 订阅。体素意图由连接的编辑 worker 串行交给 `Session.Dispatch`；角色世界意图经 `SceneServer.Movement.Intent.run/3`（与 NPC Body 同一入口）进 `VoxelRegion.World`；施法经 `Player.spell/4`，原始编辑与余额查询直接转给 World。

TCP / WebSocket / UDP 快车道、旧 chunk 订阅与旧体素意图管线已于 2026-09-30 随旧客户端删除。
