# HUD 与网页调试面

本目录拥有浏览器运行时的可见观察面。它只做 DOM 投影和用户操作入口，不拥有 world、
movement、render 或 transport 的真相状态。

- `hudView.ts` 是左上角只读运行态文本，持续显示移动、渲染、体素同步和编辑统计。
  窄屏移动端由 `index.html` 的 HUD shell 样式负责把该文本限制在安全区域内，
  使用 `pre-wrap` 换行并允许纵向触摸滚动，避免调试文本覆盖热栏或体素面板。
- `hotbarDockView.ts` 是底部快捷栏，负责材料 / prefab 选择入口；选择真相仍在
  `WorldEditController`。
- `voxelDebugPanelView.ts` 是右上角服务器权威体素面板，复用 DevTools CLI 的命令分发，
  把 `voxel_sync`、`voxel_probe`、`voxel_probe voxel_rebind ...`、`chunk_versions`、
  `voxel_subscribe` 和 `voxel_impact` 暴露成可点击 UI。`Rebind` 按钮走同一条
  WebSocket 调试探针路径，便于在迁移 cutover 后从网页直接触发订阅重绑定并用日志验证。

边界规则：

- 本目录不能直接改 `WorldStore`，写入必须通过 controller、adapter 或 CLI command port。
- 面板点击、快捷栏点击都要阻断 canvas 世界编辑指针事件，避免 UI 操作同时触发放置 / 破坏。
- 新增可见控件时，要同步保留 CLI / observe 可验证入口，不能只提供 GUI。
