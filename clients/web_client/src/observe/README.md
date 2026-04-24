# Observe

职责：

- 统一浏览器客户端的结构化 observe 日志。
- 提供非 GUI CLI 调试入口，避免只能靠画面排查。
- 暴露最近事件、运行时快照和命令执行结果给 `window` 调试面。
- movement 跳跃调试必须能通过 CLI / 日志读取：`jump_pressed`、`input_frame.movement_flags`、`movement_mode`、每帧 `renderedY/deltaY/velocityY`、ack 的 `movement_mode` 与 `correction_distance`，以及 `snapshot.actorDisplay.local.y` 这样的渲染显示高度。
- voxel 微格调试必须能通过 CLI 读取：`micro_cell` 用于检查 prefab/refined cell
  的内部 micro slot；不要把 micro 暴露成玩家可直接放置/删除的编辑命令。

边界：

- `logger.ts` 拥有日志缓冲与结构化输出。
- `cli.ts` 只做命令入口与结果回传，不拥有业务状态。
- 具体业务状态由 runtime/world/movement/render 子系统提供，observe 只负责读取和展示。
