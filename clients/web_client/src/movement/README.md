# Movement

职责：

- 实现浏览器版 fixed-tick 本地预测、权威 ack 对账、渲染平滑和远端插值。
- 对齐 `clients/bevy_client/src/sim/*` 与 `src/world/*` 的同步架构，而不是复用旧辅助函数。
- 为 CLI/observe 暴露 seq、tick、重放、硬纠正、漂移等调试数据。

边界：

- `types.ts` / `profile.ts` 定义纯数据与参数。
- `history.ts` 拥有输入/预测历史缓冲。
- `predictor.ts` 只负责单步近似运动学积分。
- `reconcile.ts` 只负责权威对账策略。
- `localPlayer.ts` / `remotePlayer.ts` 负责运行时编排。
