# Movement (domain)

职责：

- 实现浏览器版 fixed-tick 本地预测、权威 ack 对账、渲染平滑和远端插值。
- 对齐 `clients/bevy_client/src/sim/*` 与 `src/world/*` 的同步架构，而不是复用旧辅助函数。
- 为 CLI/observe 暴露 seq、tick、重放、硬纠正、漂移等调试数据。

边界：

- `types.ts` / `profile.ts` 定义纯数据与参数。`CorrectionFlag` 的 4 个位义 (Teleport / CollisionPush / AntiCheatReject / StatusOverride) 是 domain 契约，`reconcile.ts` 和 `remotePlayer.ts` 会按位分支；协议编解码在 `infrastructure/net/gateProtocol.ts` 里映射到这组 flag。
- `history.ts` 拥有输入/预测历史缓冲。
- `predictor.ts` 只负责单步近似运动学积分。
- `reconcile.ts` 只负责权威对账策略。
- `localPlayer.ts` / `remotePlayer.ts` 负责运行时编排。
- `transport.ts` 定义 `MovementTransport` port；domain 只依赖接口，具体适配器由 composition root 注入。
- `inputDirection.ts` 把按键状态映射成单位输入方向，纯函数、无副作用。

约束：

- 本目录 **不得** 依赖 `infrastructure/*`、`app/*`、`presentation/*`。如果你想 `import` 一个 adapter，说明需要再抽一层 port。
