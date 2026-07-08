# Web Client Mobile Touch Design (2026-05-12)

## 1. 背景与目标

`clients/web_client/` 当前的输入栈完全面向键鼠：

- `InputController` 监听 window 的 keydown/keyup/pointerdown/wheel；移动 WASD、跳跃 Space、放置/破坏 鼠标左/右键、hotbar 切换滚轮、材料 Digit1-7。
- `render/scene.ts` 自己监听 canvas 的 PointerEvent + pointerlockchange，左键按住拖动转视角，ctrl+wheel 改 orbitDistance。

移动端浏览器进站后无法操作：没有键盘、没有鼠标右键，pointer lock 在移动端基本不可用；触屏单次点击同时被 scene（启动 drag）和 InputController（emit `input:break-block`）拾取，语义打架。HUD 和 voxel-panel 已在 commit `d87fd2e` 隐藏，但操作层缺失。

**目标**：让横屏触屏设备能完整游玩 voxel 沙盒——移动、视角、跳跃、破坏、放置、切 hotbar 全部可用，桌面端零回退。

## 2. 范围与非范围

**Scope**：

- `clients/web_client/` 表示层 + 输入层改造
- 触屏判定（pointer:coarse / maxTouchPoints）
- 虚拟双摇杆 + 三按钮（跳/破/放）
- 摄像机 yaw/pitch 接受摇杆驱动
- 竖屏提示用户旋转，不做布局适配
- 桌面端通过 feature detection 完全跳过，不显示触屏 UI、不挂触屏事件

**Non-scope**：

- 双指捏合 zoom（移动端固定 `orbitDistance = 500`，与桌面初值一致）
- 长按持续动作（破坏/放置一次只触发一次 emit，按住不连发）
- 陀螺仪转视角
- 运行时切换 input mode（接外接键盘的平板需刷新页面）
- 真实设备 e2e / 视觉回归（CI 不覆盖）

## 3. 关键设计

### 3.1 模块边界

新增 1 个表示层模块 `src/presentation/touch/TouchControlsView.ts`，与 `HudView` / `HotbarDockView` 并列。它持有摇杆 DOM + 按钮 DOM、监听 PointerEvent，把"摇杆向量 / 按钮按下"翻译成对 `InputController` 与 `SceneHandles` 的调用：

- `InputController.setVirtualMovement({x, y})` — 替代键盘 WASD 的 pull-style 输入源
- `InputController.requestJump("touch")` — 现有方法
- `bus.emit("input:place-block" | "input:break-block", { source: "touch_button" })`
- `SceneHandles.applyCameraYawPitchDelta(dy, dp)` — 视角摇杆驱动

分层契合现有 `controllers/`（输入意图）vs `presentation/`（DOM）的划分。InputController 仍只负责"意图"，不关心控件长什么样。

### 3.2 触屏判定

```ts
const isTouchPrimary =
  window.matchMedia("(pointer: coarse)").matches ||
  navigator.maxTouchPoints > 0;
```

bootstrap 只在启动时探测一次。`isTouchPrimary === true` 时：

1. `document.documentElement.classList.add("is-touch")`，CSS 用 `html.is-touch #touch-controls { display: block }` 显示控件
2. `InputController.setDisableCanvasActions(true)` — 屏蔽 `pointerdown button=0/2 → break/place` 路径
3. `SceneHandles.setDisableCanvasInput(true)` — 屏蔽 scene 的 canvas pointerdown drag
4. 把 `TouchControlsView` 加入 GameLoop 的 frame subscriber

桌面端这棵 DOM `display: none`，事件回调不挂，零开销零回退。

### 3.3 DOM 结构

`index.html` 顶层新增：

```
<div id="touch-controls" aria-hidden="true"></div>
```

由 `TouchControlsView` 内部维护子树：

```
#touch-controls                  fixed; inset:0; pointer-events:none; z:9
├── .orientation-warning         全屏覆盖，仅 portrait 显示
├── .touch-zone--left            absolute; left:0; w:50vw; h:100% — 移动半屏
├── .touch-zone--right           absolute; right:0; w:50vw; h:100% — 视角半屏
├── .touch-stick.touch-stick--left   active 时浮现，inactive 时 display:none
├── .touch-stick.touch-stick--right
└── .touch-buttons               grid-template-areas: ". jump" "place break"
    ├── button.touch-btn--jump
    ├── button.touch-btn--place
    └── button.touch-btn--break
```

CSS 关键规则：

- 容器 `pointer-events:none`；`.touch-zone--*` 与 `.touch-btn--*` 各自 `pointer-events:auto`
- 按钮 `touch-action: manipulation`；摇杆 zone `touch-action: none`
- 按钮 grid：跳跃在最近的右上、破坏在最远位置（破坏不可逆，按钮距离做轻摩擦）
- 摇杆 80dp 外圈 + 36dp 内圈半透明白色
- z-index：`#touch-controls = 9 < #hotbar-dock = 10`，hotbar 槽位仍可点击

### 3.4 摇杆状态机

每个摇杆独立，逻辑相同（side = "left" | "right"）：

```
idle  --[pointerdown 落在 .touch-zone--{side}]-->  active(pid, origin)
active(pid, origin)
  --[pointermove pid]--> active(pid, origin, vec)
       vec = clamp(touch - origin, 80dp) / 80dp     分量范围 -1~1，长度 ≤ 1
  --[pointerup/pointercancel pid 或 pointerleave]-->  idle
```

- `setPointerCapture(pid)`：手指滑出 zone 也继续转视角
- pointerId 锁定：第二根手指落到同区域不抢占
- idle → active 切换时 pointerdown 位置就是摇杆中心（落点为中心）

每帧产物：

- 左摇杆 vec → `InputController.setVirtualMovement(vec)`
- 右摇杆 vec → 在 `TouchControlsView.onFrame` 内乘灵敏度后 `scene.applyCameraYawPitchDelta(-vec.x * dt * sens, vec.y * dt * sens)`，与桌面端鼠标 deltaX/Y 复用同一段 `orbitYaw / orbitPitch` 累加代码

不在 PointerEvent 回调里直接驱动 yaw/pitch，避免触摸事件频率与渲染帧率脱节。

### 3.5 按钮分发

- `pointerdown` 时立即触发动作（不等 `click`，省 300ms 延迟）；按钮自身 `event.stopPropagation()` 阻止冒泡到 touch-zone
- `touch-btn--jump` → `inputController.requestJump("touch")`
- `touch-btn--break` → `bus.emit("input:break-block", { source: "touch_button" })`
- `touch-btn--place` → `bus.emit("input:place-block", { source: "touch_button" })`

按钮一次按下只 emit 一次，没有"长按连发"逻辑。

### 3.6 输入合并

`LocalPlayerController` 现有读 movement keys 的地方加入合并：

```ts
const keyboard = keysToVector(input.getMovementKeys()); // 既有归一化
const stick = input.getVirtualMovement();
const movement = clampUnit({
  x: keyboard.x + stick.x,
  y: keyboard.y + stick.y,
});
```

`keysToVector` 在 `LocalPlayerController` 内部抽出公共归一化函数 `clampUnit`，键盘归一化和摇杆合并共用，不重新发明。

### 3.7 InputController / SceneHandles 改造摘要

只加方法和字段，不改既有签名：

| 文件 | 新增 |
|---|---|
| `inputController.ts` | `getVirtualMovement()` / `setVirtualMovement(vec)` / `setDisableCanvasActions(flag)` |
| `inputController.ts` | `handlePointerDown` 开头 `if (disableCanvasActions) return;` |
| `render/scene.ts` | `applyCameraYawPitchDelta(deltaYawRadians, deltaPitchRadians)` — 抽出 yaw/pitch 累加 + clamp |
| `render/scene.ts` | `setDisableCanvasInput(flag)` — `onPointerDown` 开头 `if (disable) return;` |
| `app/bootstrap.ts` | 探测 `isTouchPrimary`，按 §3.2 启用触屏路径 |
| `index.html` | 新增 `#touch-controls` 容器 + CSS（含 portrait 警告） |

桌面端这些新方法不会被调用，flag 默认 false，行为 100% 一致。

## 4. 测试策略

按现有 vitest 风格，pure logic + DOM mock，不开 headless。

| 测试对象 | 形态 | 关键断言 |
|---|---|---|
| `clampUnit` 与摇杆/键盘合并 | 纯函数 | 单源、双源、长度 ≤ 1 |
| `TouchControlsView` | 注入伪 PointerEvent，断言 mock 调用 | 单指 capture、第二指不抢、按钮立即 emit、按钮不漏到摇杆 |
| `index.html` 触屏样式 | `?raw` 引入，沿用 `hudShell.test.ts` 风格 | `html.is-touch #touch-controls` 显示；`(orientation: portrait)` 下 orientation-warning 显示、摇杆 display:none；桌面 default 隐藏 |

不测：scene.ts 的 yaw/pitch 累加（既有桌面 rotate 测试已隐含）、真实设备视觉回归。

**手动验证清单**（dev 自检用）：

1. Chrome DevTools "Toggle device toolbar" → iPhone 14 Pro Max 横屏：摇杆浮现、按钮可点、视角能转、跳/破/放在 observer 日志可见。
2. 同上切竖屏：看到"请旋转设备"提示，摇杆和按钮均不响应。
3. 同上切桌面：`html.is-touch` 类不存在，触摸 DOM `display:none`，鼠标点 canvas 仍能破坏方块。

## 5. 实施切片

5 步，每步一个 commit；前 4 步互不依赖运行时（可独立 ship 而不显化触屏行为）。

1. **样式骨架**：`index.html` 加 `#touch-controls` + `.orientation-warning` + CSS；DOM 挂上不挂事件。配 `?raw` 样式存在性测试。
2. **flag 与 contract**：`InputController` 加 `disableCanvasActions` / `getVirtualMovement` / `setVirtualMovement`；`scene.ts` 加 `applyCameraYawPitchDelta` / `setDisableCanvasInput`；抽出 `clampUnit`。配 unit test。
3. **TouchControlsView**：手势状态机 + 按钮分发。配 unit test。还**不**在 bootstrap 启用。
4. **LocalPlayerController 接入**：键盘 + 摇杆合并。键盘端既有测试不应回归。
5. **bootstrap 接入**：`isTouchPrimary` 探测 → toggle html class + 装 TouchControlsView + 透传 disable flag。

## 6. 风险

- **iOS Safari 的 setPointerCapture**：某些版本有 bug。`TouchControlsView` 内用 try/catch 包 capture，失败时回退到 window-level pointermove + pointerId 跟踪，不需要 capture。
- **触屏事件频率 vs 渲染帧率**：右摇杆 yaw/pitch 必须在 GameLoop frame 内累积，不在 PointerEvent 回调内直接调，避免 60Hz 触摸与 90/120Hz 显示脱节。
- **横屏锁定**：浏览器无法编程强制横屏（iOS 不支持 `screen.orientation.lock`）。只能用 portrait warning，由用户旋转设备。产品决策已接受。
- **平板外接键鼠**：探测仅在 bootstrap 跑一次；如需切换 input mode 需刷新页面。可接受取舍。

## 7. 决策基线（brainstorming 会话产物）

| 决策点 | 取值 | 理由 |
|---|---|---|
| 移动端目标 | 完整游玩（移动 + 视角 + 跳 + 破 + 放 + hotbar） | voxel 沙盒去掉建造就没核心循环 |
| 主交互风格 | 双摇杆 + 右下三按钮 | 用户偏好"明确按钮"语义 |
| 摇杆形态 | 触摸落点为中心、抬起隐藏（浮现式） | 现代手游主流，省屏，适配手大小 |
| 缩放 | 不做，固定默认距离 500 | 简化范围 |
| 竖屏 | 仅提示旋转，不做布局 | 简化范围 |
| 桌面端 | feature detection 完全跳过 | 零回退风险 |
| 复用策略 | 视角累加、向量归一化均复用既有桌面代码路径 | 保持架构整洁 |
