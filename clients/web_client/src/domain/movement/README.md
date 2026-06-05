# Movement (domain)

Note: browser movement positions are avatar centers. Voxel collision keeps
terrain contact half-open at `surface_top + AvatarConstants.HalfHeightCm`, and
falling collision resolves the center back to that height.

职责：

- 实现浏览器版 fixed-tick 本地预测、权威 ack 对账、渲染平滑和远端插值。
- 对齐 `clients/bevy_client/src/sim/*` 与 `src/world/*` 的同步架构，而不是复用旧辅助函数。
- 为 CLI/observe 暴露 seq、tick、重放、硬纠正、漂移等调试数据。

边界：

- `types.ts` / `profile.ts` 定义纯数据与参数。`CorrectionFlag` 的 4 个位义 (Teleport / CollisionPush / AntiCheatReject / StatusOverride) 是 domain 契约，`reconcile.ts` 和 `remotePlayer.ts` 会按位分支；协议编解码在 `infrastructure/net/gateProtocol.ts` 里映射到这组 flag。
- `MovementFlag` 与服务端 bitfield 保持一致：`Run=0x01`、`Brake=0x02`、`Jump=0x04`。`Jump` 是一次性按键边沿，不允许长按重复触发。
- `MovementMode` 使用 `grounded / airborne / scripted / disabled` 字符串；协议层将服务端 `u8` mode 解码到该枚举。
- Web 坐标采用 Three.js 习惯：`x/z` 为水平面，`y` 为垂直轴；协议层负责把服务端 `(x, y, z)` 映射为浏览器 `(x, z, y)`。
- `PredictedMoveState.groundY` 保存本次 airborne arc 的起跳地面高度，确保 CLI/日志可复现每帧竖直位移和落地判定。
- `history.ts` 拥有输入/预测历史缓冲。预测历史按 `authTick`
  优先对账，并在同 tick / seq 重复写入时使用最新样本，避免旧预测覆盖
  后到的服务端锚点。
- `collision.ts` 定义浏览器 movement 碰撞端口和 CLI 可读 summary。它不导入
  voxel storage；`app/voxel` 适配器注入 resolver，让 fixed-step prediction、
  ack replay 和 render partial step 共用同一套碰撞契约。
- `predictor.ts` 只负责单步近似运动学积分。
- `reconcile.ts` 只负责权威对账策略。服务端 ack 的 `authTick` 是
  本机预测/服务器校正的主时间轴；`ackSeq` 只作为兜底索引。历史缺失时
  从服务端权威状态重放尚未确认的输入，不允许静默把缺失当作接受。
- `localPlayer.ts` / `remotePlayer.ts` 负责运行时编排。`remotePlayer.ts`
  只维护单个远端实体的快照插值缓冲；多实体生命周期由
  `app/controllers/remotePlayerController.ts` 按 `cid` 管理。
- 浏览器 app 层的 `app/controllers/localPlayerController.ts` 会在 domain
  fixed-tick anchor 之上再做一层 **per-frame partial-step render prediction**，
  用来填平 16 ms tick (约 62.5Hz) 之间的视觉空档；它不写回 history，也不改变网络发送频率。
- 本地灰色 server-authority cube 不是远端玩家插值对象，也不是本地视觉平滑
  后的位置。屏幕上显示的是 latest-ack projection，用来独立对照本地预测
  与服务端权威轨迹；raw ack 位置仍保留给 CLI/trace 做 reconcile / latency
  诊断；latest-ack projection 在
  TimeSync 可用时按 `server_state_ms + serverClockOffsetMs` 计算，
  TimeSync 尚未建立时退回最多 2 个 `serverFixedDtMs` 的短窗口投影。
- 渲染层消费 movement 输出的 3D 坐标作为角色显示真相。体素地表查询只用于
  spawn/teleport 选点，不能在每帧用“当前 x/z 最高 solid block”覆盖
  movement Y；否则上方桥、天花板或 prefab 会被误判成脚下地面。
- `ReplayGovernanceStats.totalAcks` 统计所有权威回包；`totalCorrections`
  只统计 replay / snap / status override 等真实校正，不再把 accepted ack
  误报成“拉回”。
- online movement 要求权威 chunk 后才按本地 voxel resolver 前进。严格查询缺
  chunk 时会请求缺失 chunk 并停在上一帧安全位置，避免 fail-open 穿模后再被
  服务端拉回。
- `remotePlayer.ts` 当前采用 **150 ms 插值延迟 + 250 ms 封顶外推**：
  150 ms 仍保留给远端实体吸收网络抖动/优先级节流，不额外拖出
  220 ms 的远端钝感。tick 时长默认 16 ms (约 62.5Hz)，但会接受服务端 ack 回传的
  `serverFixedDtMs`，避免远端插值时间轴与服务端固定步长漂移。
- `transport.ts` 定义 `MovementTransport` port；domain 只依赖接口，具体适配器由 composition root 注入。
- `inputDirection.ts` 把按键状态映射成单位输入方向，纯函数、无副作用。

约束：

- 本目录 **不得** 依赖 `infrastructure/*`、`app/*`、`presentation/*`。如果你想 `import` 一个 adapter，说明需要再抽一层 port。
