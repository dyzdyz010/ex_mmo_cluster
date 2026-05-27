# HUD 与网页调试面

本目录拥有浏览器运行时的可见观察面。它只做 DOM 投影和用户操作入口，不拥有 world、
movement、render 或 transport 的真相状态。

- `hudView.ts` 是左上角只读运行态文本，持续显示移动、渲染、体素同步和编辑统计。
  窄屏移动端由 `index.html` 的 HUD shell 样式负责把该文本限制在安全区域内，
  使用 `pre-wrap` 换行并允许纵向触摸滚动，避免调试文本覆盖热栏或体素面板。
- `hotbarDockView.ts` 是底部快捷栏，负责材料 / prefab 选择入口；选择真相仍在
  `WorldEditController`。
- `chatPanelView.ts` 是左下角世界聊天入口。它只保存当前输入框、scope 选择和最近
  下行消息；发送走 `DevToolsCli` 的 `chat` 命令，接收走 `chat:message-received`
  事件。客户端只能选择 `world` / `region` / `local` scope，不能携带 region/chunk
  权威字段。
- `voxelDebugPanelView.ts` 是右上角服务器权威体素观察面。桌面端鼠标主要被视角占用，
  所以该面板默认展示运行状态、快捷键和 CLI 指令提示；只有 `Field`、`Guide` 和
  `voxel_subscribe` 这类值得脱出指针的操作保留为可点击控件。其它体素调试能力仍走
  `window.__voxelCli`、键盘事件或 observe 日志。
- `operationGuideView.ts` 是操作指南弹框和触屏独立入口，只负责打开、关闭、Esc 退出和阻断世界编辑指针事件。
  桌面入口在右侧体素面板的 `Guide` 按钮；触屏入口是独立 `?` 按钮，因为移动触屏模式会隐藏右侧面板。
  具体业务动作仍由右侧体素面板、快捷栏、输入控制器和 CLI/observe 面共同承接。
- 移动端不复用桌面右侧体素面板；`touch/TouchControlsView.ts` 提供手指友好的独立操作面：
  双摇杆、Jump、Place、Break，以及 `Field`、`Heat`、`Conduct`、`Sub Aim` 操作条。
  `Sub Aim` 按当前准星方块所在 chunk 自动执行 `voxel_subscribe`，避免在手机上填写坐标。

当前 UI 优化焦点：

- 先把已落地的电源块、导电路径、电热写回和热烟状态变成玩家能理解的可见指示。
- 需要显示的业务状态包括：选中的电源/导线材料、导电 source/target 端点、请求 accepted/rejected、
  FieldRegion id、电源模式、电压、负载电流、热烟粒子强度。
- 暂停继续扩展底层物理：跨 chunk 电场、持续能量扣减、材料熔断、伤害结算先不进入本轮。

边界规则：

- 本目录不能直接改 `WorldStore`，写入必须通过 controller、adapter 或 CLI command port。
- 面板点击、快捷栏点击都要阻断 canvas 世界编辑指针事件，避免 UI 操作同时触发放置 / 破坏。
- 新增可见控件时，要同步保留 CLI / observe 可验证入口，不能只提供 GUI。
- 聊天面板不能复用体素面板的状态或 World/Render 入口；聊天频道真相在服务器，
  浏览器只负责提交 scope 和展示服务器下发消息。
