# Web Client Mobile Touch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `clients/web_client/` 在横屏触屏设备上完整可玩（移动 / 视角 / 跳跃 / 破坏 / 放置 / hotbar），桌面端零回退。

**Architecture:** 新增 `presentation/touch/TouchControlsView.ts` 表示层模块，挂在新 `#touch-controls` 容器；`InputController` 暴露 `getVirtualMovement/setVirtualMovement/setDisableCanvasActions`；`scene.ts` 暴露 `applyCameraYawPitchDelta/setDisableCanvasInput`；`bootstrap` 探测 `isTouchPrimary` 后启用整条触屏路径，桌面端走原路径。

**Tech Stack:** TypeScript + Vite + Three.js + Vitest。开发命令在 `clients/web_client/` 下：`npx vitest run <path>`。

**Spec:** `docs/superpowers/specs/2026-05-12-web-client-mobile-touch-design.md`（commit aa9eaa2）。

---

## File Structure

| 路径（均 `clients/web_client/` 相对） | 操作 | 职责 |
|---|---|---|
| `index.html` | 修改 | 加 `#touch-controls` 容器 + CSS（含 portrait warning） |
| `src/domain/movement/inputDirection.ts` | 重写 | 拆出 `keysToAxes / clampUnitVec / buildMovementWorldDirection` |
| `src/domain/movement/inputDirection.test.ts` | 新增 | 测三个纯函数 |
| `src/app/controllers/inputController.ts` | 修改 | 加 `disableCanvasActions / virtualMovement` + 在 `handlePointerDown` 顶部短路 |
| `src/app/controllers/inputController.test.ts` | 扩展 | 测新增字段与短路行为 |
| `src/render/scene.ts` | 修改 | 抽出 yaw/pitch 累加成 `applyCameraYawPitchDelta`；加 `setDisableCanvasInput`；暴露在 `SceneHandles` |
| `src/presentation/touch/TouchControlsView.ts` | 新增 | 摇杆状态机 + 按钮 dispatch + 每帧 yaw/pitch 推进 |
| `src/presentation/touch/TouchControlsView.test.ts` | 新增 | mock PointerEvent + mock InputController / scene，断言分发 |
| `src/presentation/hud/hudShell.test.ts` | 扩展 | 加 `#touch-controls` 样式存在性测试 |
| `src/app/controllers/localPlayerController.ts` | 修改 | 改用新 `buildMovementWorldDirection`；合并键盘 + 摇杆 axes |
| `src/app/bootstrap.ts` | 修改 | 探测 `isTouchPrimary` → toggle html class、装 view、透传 flag |

---

## Task 1：样式骨架与 DOM 容器

**Files:**
- Modify: `clients/web_client/index.html`
- Test: `clients/web_client/src/presentation/hud/hudShell.test.ts`

- [ ] **Step 1.1：扩展 hudShell 测试覆盖 #touch-controls 样式骨架**

编辑 `clients/web_client/src/presentation/hud/hudShell.test.ts`，在 `describe("HUD shell layout", ...)` 末尾追加：

```ts
  it("declares #touch-controls hidden by default and shown only under html.is-touch", () => {
    const touchRule = indexHtml.match(/#touch-controls\s*\{[^}]*\}/s)?.[0] ?? "";
    expect(touchRule).toContain("display: none");

    const enableRule = indexHtml.match(/html\.is-touch\s+#touch-controls\s*\{[^}]*\}/s)?.[0] ?? "";
    expect(enableRule).toContain("display: block");
  });

  it("provides touch zones, sticks and action buttons inside touch-controls", () => {
    expect(indexHtml).toMatch(/\.touch-zone--left\s*\{[^}]*pointer-events:\s*auto/s);
    expect(indexHtml).toMatch(/\.touch-zone--right\s*\{[^}]*pointer-events:\s*auto/s);
    expect(indexHtml).toMatch(/\.touch-stick--left\s*\{/);
    expect(indexHtml).toMatch(/\.touch-stick--right\s*\{/);
    expect(indexHtml).toMatch(/\.touch-buttons\s*\{[^}]*pointer-events:\s*auto/s);
    expect(indexHtml).toMatch(/\.touch-btn--jump\s*\{/);
    expect(indexHtml).toMatch(/\.touch-btn--break\s*\{/);
    expect(indexHtml).toMatch(/\.touch-btn--place\s*\{/);
  });

  it("hides touch sticks/buttons and shows orientation warning in portrait", () => {
    const portraitBlock = indexHtml.match(/@media \(orientation: portrait\)[^@]*/s)?.[0] ?? "";
    expect(portraitBlock).toMatch(/\.orientation-warning\s*\{[^}]*display:\s*flex/s);
    expect(portraitBlock).toMatch(/\.touch-zone[^{]*\{[^}]*display:\s*none/s);
    expect(portraitBlock).toMatch(/\.touch-buttons\s*\{[^}]*display:\s*none/s);
  });
```

`indexHtml` 已在文件顶部从 `import indexHtml from "../../../index.html?raw"` 引入；上面三段直接复用。

- [ ] **Step 1.2：运行新测试，确认失败**

```bash
cd clients/web_client
npx vitest run src/presentation/hud/hudShell.test.ts
```

期望：三个新 `it` 失败，原有 3 个通过。

- [ ] **Step 1.3：往 `index.html` 加 DOM 容器**

在 `clients/web_client/index.html` 中 `<canvas id="app"></canvas>` 之后、`<div id="hud"></div>` 之前插入：

```html
    <div id="touch-controls" aria-hidden="true">
      <div class="orientation-warning" role="alert">
        <p>请将设备旋转至横屏以游玩</p>
      </div>
      <div class="touch-zone touch-zone--left"></div>
      <div class="touch-zone touch-zone--right"></div>
      <div class="touch-stick touch-stick--left"><span class="touch-stick__nub"></span></div>
      <div class="touch-stick touch-stick--right"><span class="touch-stick__nub"></span></div>
      <div class="touch-buttons">
        <button class="touch-btn touch-btn--jump" type="button" aria-label="Jump">↑</button>
        <button class="touch-btn touch-btn--place" type="button" aria-label="Place block">+</button>
        <button class="touch-btn touch-btn--break" type="button" aria-label="Break block">✕</button>
      </div>
    </div>
```

- [ ] **Step 1.4：往 `index.html` `<style>` 末尾（`@media (max-width: 480px)` 之前）插入触屏样式**

```css
      #touch-controls {
        position: fixed;
        inset: 0;
        z-index: 9;
        display: none;
        pointer-events: none;
      }
      html.is-touch #touch-controls {
        display: block;
      }
      .touch-zone {
        position: absolute;
        top: 0;
        bottom: 0;
        pointer-events: auto;
        touch-action: none;
      }
      .touch-zone--left {
        left: 0;
        right: 50%;
      }
      .touch-zone--right {
        left: 50%;
        right: 0;
      }
      .touch-stick {
        position: fixed;
        width: 160px;
        height: 160px;
        border-radius: 50%;
        border: 2px solid rgba(255, 255, 255, 0.42);
        background: rgba(20, 28, 36, 0.32);
        pointer-events: none;
        display: none;
        transform: translate(-50%, -50%);
      }
      .touch-stick.is-active {
        display: block;
      }
      .touch-stick__nub {
        position: absolute;
        top: 50%;
        left: 50%;
        width: 64px;
        height: 64px;
        margin: -32px 0 0 -32px;
        border-radius: 50%;
        background: rgba(255, 255, 255, 0.78);
        box-shadow: 0 4px 16px rgba(0, 0, 0, 0.42);
        transform: translate(0, 0);
      }
      .touch-buttons {
        position: fixed;
        right: calc(env(safe-area-inset-right, 0px) + 18px);
        bottom: calc(env(safe-area-inset-bottom, 0px) + 96px);
        display: grid;
        grid-template-columns: repeat(2, 64px);
        grid-template-rows: repeat(2, 64px);
        grid-template-areas:
          ". jump"
          "place break";
        gap: 10px;
        pointer-events: auto;
        touch-action: manipulation;
      }
      .touch-btn {
        width: 64px;
        height: 64px;
        border-radius: 50%;
        border: 1px solid rgba(255, 255, 255, 0.48);
        background: rgba(8, 15, 22, 0.62);
        color: #f4faff;
        font-size: 26px;
        line-height: 1;
        padding: 0;
        cursor: pointer;
        touch-action: manipulation;
      }
      .touch-btn:active {
        background: rgba(53, 80, 96, 0.92);
      }
      .touch-btn--jump {
        grid-area: jump;
      }
      .touch-btn--place {
        grid-area: place;
      }
      .touch-btn--break {
        grid-area: break;
      }
      .orientation-warning {
        position: fixed;
        inset: 0;
        display: none;
        align-items: center;
        justify-content: center;
        background: rgba(0, 0, 0, 0.82);
        color: #eef7fb;
        font-size: 16px;
        line-height: 1.4;
        text-align: center;
        padding: 24px;
        pointer-events: auto;
      }
      @media (orientation: portrait) {
        html.is-touch .orientation-warning {
          display: flex;
        }
        html.is-touch .touch-zone,
        html.is-touch .touch-stick,
        html.is-touch .touch-buttons {
          display: none;
        }
      }
```

- [ ] **Step 1.5：跑测试确认通过**

```bash
cd clients/web_client
npx vitest run src/presentation/hud/hudShell.test.ts
```

期望：全部 6 个测试通过。

- [ ] **Step 1.6：跑 build 确认 vite 不报错**

```bash
cd clients/web_client
npx tsc --noEmit
```

期望：无错误。`html` 文件不入 TS 编译，但确保新增 CSS 不影响 import 类型。

- [ ] **Step 1.7：commit**

```bash
git add clients/web_client/index.html clients/web_client/src/presentation/hud/hudShell.test.ts
git commit -m "$(cat <<'EOF'
Add touch-controls DOM scaffold and portrait warning

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2：纯函数与控制器契约

**Files:**
- Rewrite: `clients/web_client/src/domain/movement/inputDirection.ts`
- Create: `clients/web_client/src/domain/movement/inputDirection.test.ts`
- Modify: `clients/web_client/src/app/controllers/inputController.ts`
- Modify: `clients/web_client/src/app/controllers/inputController.test.ts`
- Modify: `clients/web_client/src/render/scene.ts`

### 2A — `inputDirection.ts` 拆纯函数

- [ ] **Step 2A.1：写 `inputDirection.test.ts`**

创建 `clients/web_client/src/domain/movement/inputDirection.test.ts`：

```ts
import { describe, expect, it } from "vitest";
import {
  buildMovementWorldDirection,
  clampUnitVec,
  keysToAxes,
} from "./inputDirection";

describe("keysToAxes", () => {
  it("returns zero when no keys are pressed", () => {
    const axes = keysToAxes({ forward: false, backward: false, left: false, right: false });
    expect(axes).toEqual({ strafe: 0, forward: 0 });
  });

  it("returns unit forward when only forward is pressed", () => {
    const axes = keysToAxes({ forward: true, backward: false, left: false, right: false });
    expect(axes).toEqual({ strafe: 0, forward: 1 });
  });

  it("opposing keys cancel out", () => {
    const axes = keysToAxes({ forward: true, backward: true, left: true, right: true });
    expect(axes).toEqual({ strafe: 0, forward: 0 });
  });
});

describe("clampUnitVec", () => {
  it("passes through vectors with length <= 1", () => {
    expect(clampUnitVec({ x: 0.6, y: 0.6 }).x).toBeCloseTo(0.6);
    expect(clampUnitVec({ x: 0.6, y: 0.6 }).y).toBeCloseTo(0.6);
  });

  it("scales vectors longer than 1 to unit length", () => {
    const v = clampUnitVec({ x: 3, y: 4 });
    const length = Math.hypot(v.x, v.y);
    expect(length).toBeCloseTo(1);
    expect(v.x).toBeCloseTo(0.6);
    expect(v.y).toBeCloseTo(0.8);
  });

  it("returns zero for zero input", () => {
    expect(clampUnitVec({ x: 0, y: 0 })).toEqual({ x: 0, y: 0 });
  });
});

describe("buildMovementWorldDirection", () => {
  it("returns zero for zero axes regardless of yaw", () => {
    const v = buildMovementWorldDirection({ strafe: 0, forward: 0 }, 1.5);
    expect(v.x).toBeCloseTo(0);
    expect(v.y).toBeCloseTo(0);
  });

  it("yaw=0 → forward axis maps to -z world", () => {
    const v = buildMovementWorldDirection({ strafe: 0, forward: 1 }, 0);
    expect(v.x).toBeCloseTo(0);
    expect(v.y).toBeCloseTo(-1);
  });

  it("yaw=0 → strafe axis maps to +x world", () => {
    const v = buildMovementWorldDirection({ strafe: 1, forward: 0 }, 0);
    expect(v.x).toBeCloseTo(1);
    expect(v.y).toBeCloseTo(0);
  });
});
```

- [ ] **Step 2A.2：跑测试确认失败**

```bash
cd clients/web_client
npx vitest run src/domain/movement/inputDirection.test.ts
```

期望：所有断言失败（symbol not exported）。

- [ ] **Step 2A.3：重写 `inputDirection.ts`**

```ts
import { Vector2 } from "three";

export interface MovementKeys {
  forward: boolean;
  backward: boolean;
  left: boolean;
  right: boolean;
}

export interface MovementAxes {
  strafe: number;
  forward: number;
}

export function keysToAxes(keys: MovementKeys): MovementAxes {
  return {
    strafe: Number(keys.right) - Number(keys.left),
    forward: Number(keys.forward) - Number(keys.backward),
  };
}

export function clampUnitVec(v: { x: number; y: number }): { x: number; y: number } {
  const length = Math.hypot(v.x, v.y);
  if (length <= 1 || length === 0) {
    return { x: v.x, y: v.y };
  }
  return { x: v.x / length, y: v.y / length };
}

export function buildMovementWorldDirection(
  axes: MovementAxes,
  cameraYawRadians = 0,
): Vector2 {
  const cosYaw = Math.cos(cameraYawRadians);
  const sinYaw = Math.sin(cameraYawRadians);
  const worldX = axes.strafe * cosYaw + axes.forward * -sinYaw;
  const worldZ = axes.strafe * -sinYaw + axes.forward * -cosYaw;
  return new Vector2(worldX, worldZ);
}
```

- [ ] **Step 2A.4：跑测试确认通过**

```bash
cd clients/web_client
npx vitest run src/domain/movement/inputDirection.test.ts
```

期望：全部 9 个测试通过。

### 2B — `InputController` 加触屏接口

- [ ] **Step 2B.1：扩 `inputController.test.ts`**

文件中已有 `FakeWindowTarget`、`pointerDown(button, shiftKey?)` 等 helper（见 `inputController.test.ts:6-57`）。在文件末尾追加一个新 `describe` 块复用它们：

```ts
describe("InputController virtual movement and canvas disable flag", () => {
  it("getVirtualMovement returns zero by default", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new InputController(bus);
    expect(controller.getVirtualMovement()).toEqual({ x: 0, y: 0 });
  });

  it("setVirtualMovement updates state and clamps to unit length", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new InputController(bus);

    controller.setVirtualMovement({ x: 0.4, y: -0.2 });
    expect(controller.getVirtualMovement().x).toBeCloseTo(0.4);
    expect(controller.getVirtualMovement().y).toBeCloseTo(-0.2);

    controller.setVirtualMovement({ x: 3, y: 4 });
    const clamped = controller.getVirtualMovement();
    expect(Math.hypot(clamped.x, clamped.y)).toBeCloseTo(1);
  });

  it("setDisableCanvasActions short-circuits pointerdown break/place emit", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new InputController(bus);
    const target = new FakeWindowTarget();
    let breakCount = 0;
    bus.on("input:break-block", () => {
      breakCount += 1;
    });

    controller.attach(target as unknown as Window);
    target.dispatch("pointerdown", pointerDown(0));
    expect(breakCount).toBe(1);

    controller.setDisableCanvasActions(true);
    target.dispatch("pointerdown", pointerDown(0));
    expect(breakCount).toBe(1);

    controller.setDisableCanvasActions(false);
    target.dispatch("pointerdown", pointerDown(0));
    expect(breakCount).toBe(2);
  });
});
```

- [ ] **Step 2B.2：跑测试确认失败**

```bash
cd clients/web_client
npx vitest run src/app/controllers/inputController.test.ts
```

期望：三个新 `it` 失败。

- [ ] **Step 2B.3：实现 InputController 的新字段与方法**

编辑 `clients/web_client/src/app/controllers/inputController.ts`：

1. 顶部 import 增加 `import { clampUnitVec } from "../../domain/movement/inputDirection";`
2. 把 `MovementKeys` 接口替换为 re-export：删除本文件 export 的 `MovementKeys`，改 `export type { MovementKeys } from "../../domain/movement/inputDirection";`（旧定义与新文件中定义结构相同，统一来源）。
3. 在类的字段区加：

```ts
  private virtualMovement: { x: number; y: number } = { x: 0, y: 0 };
  private disableCanvasActions = false;
```

4. 在 `handlePointerDown` 顶部加：

```ts
    if (this.disableCanvasActions) {
      return;
    }
```

5. 在 `consumeJumpPressed` 附近加方法：

```ts
  getVirtualMovement(): Readonly<{ x: number; y: number }> {
    return this.virtualMovement;
  }

  setVirtualMovement(vec: { x: number; y: number }): void {
    this.virtualMovement = clampUnitVec(vec);
  }

  setDisableCanvasActions(flag: boolean): void {
    this.disableCanvasActions = flag;
  }
```

- [ ] **Step 2B.4：跑测试确认通过**

```bash
cd clients/web_client
npx vitest run src/app/controllers/inputController.test.ts
```

期望：全部通过（既有 + 三个新）。

### 2C — `scene.ts` 抽出 yaw/pitch + 加 disable flag

- [ ] **Step 2C.1：修改 `scene.ts` 抽出累加函数**

编辑 `clients/web_client/src/render/scene.ts`：

1. 在 `onPointerMove` 内的两行 yaw/pitch 计算抽成局部辅助函数。在 `let dragActive = false;` 一段之后定义：

```ts
  let disableCanvasInput = false;

  const applyCameraYawPitchDelta = (deltaYawRadians: number, deltaPitchRadians: number): void => {
    orbitYaw -= deltaYawRadians;
    orbitPitch = clampCameraOrbitPitch(orbitPitch + deltaPitchRadians);
    lastCameraInteractionMs = performance.now();
  };

  const setDisableCanvasInput = (flag: boolean): void => {
    disableCanvasInput = flag;
    if (flag) {
      dragActive = false;
      if (document.pointerLockElement === canvas) {
        document.exitPointerLock();
      }
    }
  };
```

2. 把 `onPointerMove` 内：

```ts
    orbitYaw -= deltaX * CAMERA_YAW_SENSITIVITY;
    orbitPitch = clampCameraOrbitPitch(orbitPitch + deltaY * CAMERA_PITCH_SENSITIVITY);
```

替换为：

```ts
    applyCameraYawPitchDelta(
      deltaX * CAMERA_YAW_SENSITIVITY,
      deltaY * CAMERA_PITCH_SENSITIVITY,
    );
```

3. 在 `onPointerDown` 函数体顶部加：

```ts
    if (disableCanvasInput) {
      return;
    }
```

4. 在返回的 `SceneHandles` 对象加两个字段：

```ts
    applyCameraYawPitchDelta,
    setDisableCanvasInput,
```

5. 同步更新 `SceneHandles` interface（同文件顶部）：

```ts
export interface SceneHandles {
  // ... existing fields ...
  applyCameraYawPitchDelta: (deltaYawRadians: number, deltaPitchRadians: number) => void;
  setDisableCanvasInput: (flag: boolean) => void;
}
```

- [ ] **Step 2C.2：跑 tsc 验证**

```bash
cd clients/web_client
npx tsc --noEmit
```

期望：无 error。

- [ ] **Step 2C.3：跑既有 scene 相关测试确认无回归**

```bash
cd clients/web_client
npx vitest run src/render
```

期望：全部既有测试通过。

### 2D — 修复 LocalPlayerController 因 inputDirection 重写而坏的 import

- [ ] **Step 2D.1：把 LocalPlayerController 切到新 API（最小改动版，纯键盘路径，摇杆合并下 Task 4 再做）**

编辑 `clients/web_client/src/app/controllers/localPlayerController.ts`：

1. import 行改：

```ts
import {
  buildMovementWorldDirection,
  keysToAxes,
} from "@domain/movement/inputDirection";
```

2. 第 151 行和 283 行的 `buildMovementInputDirection(this.input.getMovementKeys(), this.cameraYawResolver())` 替换为：

```ts
buildMovementWorldDirection(
  keysToAxes(this.input.getMovementKeys()),
  this.cameraYawResolver(),
)
```

- [ ] **Step 2D.2：跑全部既有测试，确认 0 回归**

```bash
cd clients/web_client
npx vitest run
```

期望：全部通过。

- [ ] **Step 2D.3：commit Task 2 整体**

```bash
git add clients/web_client/src/domain/movement/inputDirection.ts \
        clients/web_client/src/domain/movement/inputDirection.test.ts \
        clients/web_client/src/app/controllers/inputController.ts \
        clients/web_client/src/app/controllers/inputController.test.ts \
        clients/web_client/src/render/scene.ts \
        clients/web_client/src/app/controllers/localPlayerController.ts
git commit -m "$(cat <<'EOF'
Expose touch contracts on input controller, scene, and movement axes

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3：`TouchControlsView` 模块

**Files:**
- Create: `clients/web_client/src/presentation/touch/TouchControlsView.ts`
- Create: `clients/web_client/src/presentation/touch/TouchControlsView.test.ts`

> Touch yaw/pitch 灵敏度常量在该模块内定义（不放 `scene.ts`），因为它只与摇杆 vec 单位换算相关，与桌面鼠标 deltaX/Y 单位不同。

- [ ] **Step 3.1：写 TouchControlsView.test.ts**

创建 `clients/web_client/src/presentation/touch/TouchControlsView.test.ts`：

```ts
import { describe, expect, it, vi } from "vitest";
import { TouchControlsView, type TouchControlsPorts } from "./TouchControlsView";

class FakeElement {
  classList = new Set<string>();
  style: Record<string, string> = {};
  private listeners = new Map<string, EventListener[]>();
  setPointerCapture = vi.fn();
  releasePointerCapture = vi.fn();
  getBoundingClientRect(): DOMRect {
    return { left: 0, top: 0, right: 200, bottom: 600, width: 200, height: 600, x: 0, y: 0, toJSON: () => ({}) } as DOMRect;
  }
  addEventListener(type: string, fn: EventListener): void {
    const arr = this.listeners.get(type) ?? [];
    arr.push(fn);
    this.listeners.set(type, arr);
  }
  removeEventListener(type: string, fn: EventListener): void {
    const arr = this.listeners.get(type) ?? [];
    this.listeners.set(type, arr.filter((f) => f !== fn));
  }
  fire(type: string, evt: Partial<PointerEvent>): void {
    for (const fn of this.listeners.get(type) ?? []) fn(evt as PointerEvent);
  }
}

function makePorts(): TouchControlsPorts {
  return {
    setMovement: vi.fn(),
    requestJump: vi.fn(),
    emitBreak: vi.fn(),
    emitPlace: vi.fn(),
    applyCameraYawPitchDelta: vi.fn(),
  };
}

function makeFakeDom(): {
  root: FakeElement;
  zoneLeft: FakeElement;
  zoneRight: FakeElement;
  stickLeft: FakeElement;
  stickRight: FakeElement;
  btnJump: FakeElement;
  btnBreak: FakeElement;
  btnPlace: FakeElement;
} {
  return {
    root: new FakeElement(),
    zoneLeft: new FakeElement(),
    zoneRight: new FakeElement(),
    stickLeft: new FakeElement(),
    stickRight: new FakeElement(),
    btnJump: new FakeElement(),
    btnBreak: new FakeElement(),
    btnPlace: new FakeElement(),
  };
}

describe("TouchControlsView", () => {
  it("left stick pointerdown captures pointer and updates movement", () => {
    const dom = makeFakeDom();
    const ports = makePorts();
    const view = new TouchControlsView(dom as unknown as Parameters<typeof TouchControlsView>[0], ports);

    dom.zoneLeft.fire("pointerdown", {
      pointerId: 1,
      clientX: 60,
      clientY: 300,
      preventDefault: () => undefined,
    });
    expect(dom.zoneLeft.setPointerCapture).toHaveBeenCalledWith(1);

    dom.zoneLeft.fire("pointermove", {
      pointerId: 1,
      clientX: 140,
      clientY: 300,
      preventDefault: () => undefined,
    });
    const lastCall = (ports.setMovement as ReturnType<typeof vi.fn>).mock.calls.at(-1)?.[0];
    expect(lastCall.x).toBeCloseTo(1);
    expect(lastCall.y).toBeCloseTo(0);

    dom.zoneLeft.fire("pointerup", { pointerId: 1 });
    const finalCall = (ports.setMovement as ReturnType<typeof vi.fn>).mock.calls.at(-1)?.[0];
    expect(finalCall).toEqual({ x: 0, y: 0 });

    view.dispose();
  });

  it("second pointer in same zone does not steal the active stick", () => {
    const dom = makeFakeDom();
    const ports = makePorts();
    new TouchControlsView(dom as unknown as Parameters<typeof TouchControlsView>[0], ports);

    dom.zoneLeft.fire("pointerdown", { pointerId: 1, clientX: 60, clientY: 300, preventDefault: () => undefined });
    const before = (ports.setMovement as ReturnType<typeof vi.fn>).mock.calls.length;

    dom.zoneLeft.fire("pointerdown", { pointerId: 2, clientX: 10, clientY: 10, preventDefault: () => undefined });
    expect((ports.setMovement as ReturnType<typeof vi.fn>).mock.calls.length).toBe(before);
  });

  it("right stick drives applyCameraYawPitchDelta on frame", () => {
    const dom = makeFakeDom();
    const ports = makePorts();
    const view = new TouchControlsView(dom as unknown as Parameters<typeof TouchControlsView>[0], ports);

    dom.zoneRight.fire("pointerdown", { pointerId: 5, clientX: 100, clientY: 300, preventDefault: () => undefined });
    dom.zoneRight.fire("pointermove", { pointerId: 5, clientX: 180, clientY: 300, preventDefault: () => undefined });

    view.onFrame(0, 100);
    const [yaw, pitch] = (ports.applyCameraYawPitchDelta as ReturnType<typeof vi.fn>).mock.calls.at(-1) ?? [0, 0];
    expect(yaw).toBeGreaterThan(0);
    expect(pitch).toBeCloseTo(0);
  });

  it("jump button pointerdown calls requestJump immediately", () => {
    const dom = makeFakeDom();
    const ports = makePorts();
    new TouchControlsView(dom as unknown as Parameters<typeof TouchControlsView>[0], ports);
    dom.btnJump.fire("pointerdown", { pointerId: 9, preventDefault: () => undefined, stopPropagation: () => undefined });
    expect(ports.requestJump).toHaveBeenCalledOnce();
  });

  it("break/place buttons emit through ports", () => {
    const dom = makeFakeDom();
    const ports = makePorts();
    new TouchControlsView(dom as unknown as Parameters<typeof TouchControlsView>[0], ports);

    dom.btnBreak.fire("pointerdown", { pointerId: 10, preventDefault: () => undefined, stopPropagation: () => undefined });
    expect(ports.emitBreak).toHaveBeenCalledOnce();

    dom.btnPlace.fire("pointerdown", { pointerId: 11, preventDefault: () => undefined, stopPropagation: () => undefined });
    expect(ports.emitPlace).toHaveBeenCalledOnce();
  });
});
```

- [ ] **Step 3.2：跑测试确认失败**

```bash
cd clients/web_client
npx vitest run src/presentation/touch/TouchControlsView.test.ts
```

期望：所有失败（模块不存在）。

- [ ] **Step 3.3：实现 TouchControlsView.ts**

创建 `clients/web_client/src/presentation/touch/TouchControlsView.ts`：

```ts
import { clampUnitVec } from "../../domain/movement/inputDirection";
import type { FrameSubscriber } from "../../app/gameLoop";

const STICK_RADIUS_PX = 80;
const TOUCH_YAW_SENSITIVITY = 0.0035;
const TOUCH_PITCH_SENSITIVITY = 0.0028;

export interface TouchControlsPorts {
  setMovement(vec: { x: number; y: number }): void;
  requestJump(source: string): void;
  emitBreak(): void;
  emitPlace(): void;
  applyCameraYawPitchDelta(deltaYawRadians: number, deltaPitchRadians: number): void;
}

export interface TouchControlsElements {
  root: HTMLElement;
  zoneLeft: HTMLElement;
  zoneRight: HTMLElement;
  stickLeft: HTMLElement;
  stickRight: HTMLElement;
  btnJump: HTMLElement;
  btnBreak: HTMLElement;
  btnPlace: HTMLElement;
}

interface StickState {
  pointerId: number | null;
  originX: number;
  originY: number;
  vec: { x: number; y: number };
}

export class TouchControlsView implements FrameSubscriber {
  private readonly left: StickState = { pointerId: null, originX: 0, originY: 0, vec: { x: 0, y: 0 } };
  private readonly right: StickState = { pointerId: null, originX: 0, originY: 0, vec: { x: 0, y: 0 } };
  private readonly detachers: Array<() => void> = [];

  constructor(
    private readonly elements: TouchControlsElements,
    private readonly ports: TouchControlsPorts,
  ) {
    this.bindZone(elements.zoneLeft, elements.stickLeft, this.left, true);
    this.bindZone(elements.zoneRight, elements.stickRight, this.right, false);
    this.bindButton(elements.btnJump, () => this.ports.requestJump("touch"));
    this.bindButton(elements.btnBreak, () => this.ports.emitBreak());
    this.bindButton(elements.btnPlace, () => this.ports.emitPlace());
  }

  onFrame(_nowMs: number, dtMs: number): void {
    if (this.right.pointerId === null) {
      return;
    }
    const dt = dtMs / 1000;
    this.ports.applyCameraYawPitchDelta(
      this.right.vec.x * TOUCH_YAW_SENSITIVITY * dtMs,
      this.right.vec.y * TOUCH_PITCH_SENSITIVITY * dtMs,
    );
    void dt;
  }

  dispose(): void {
    for (const off of this.detachers) off();
    this.detachers.length = 0;
  }

  private bindZone(
    zone: HTMLElement,
    stick: HTMLElement,
    state: StickState,
    isLeft: boolean,
  ): void {
    const onDown = (event: PointerEvent): void => {
      if (state.pointerId !== null) {
        return;
      }
      state.pointerId = event.pointerId;
      state.originX = event.clientX;
      state.originY = event.clientY;
      state.vec = { x: 0, y: 0 };
      try {
        zone.setPointerCapture(event.pointerId);
      } catch {
        // ignore — fallback to window-level pointermove still works
      }
      stick.style.left = `${event.clientX}px`;
      stick.style.top = `${event.clientY}px`;
      stick.classList.add("is-active");
      if (isLeft) {
        this.ports.setMovement(state.vec);
      }
    };

    const onMove = (event: PointerEvent): void => {
      if (state.pointerId !== event.pointerId) {
        return;
      }
      const dx = (event.clientX - state.originX) / STICK_RADIUS_PX;
      const dy = (event.clientY - state.originY) / STICK_RADIUS_PX;
      state.vec = clampUnitVec({ x: dx, y: dy });
      if (isLeft) {
        // Left stick semantics: x = strafe, y = forward (up = forward → negative dy = forward).
        this.ports.setMovement({ x: state.vec.x, y: -state.vec.y });
      }
    };

    const onEnd = (event: PointerEvent): void => {
      if (state.pointerId !== event.pointerId) {
        return;
      }
      state.pointerId = null;
      state.vec = { x: 0, y: 0 };
      stick.classList.remove("is-active");
      try {
        zone.releasePointerCapture(event.pointerId);
      } catch {
        // ignore
      }
      if (isLeft) {
        this.ports.setMovement({ x: 0, y: 0 });
      }
    };

    zone.addEventListener("pointerdown", onDown);
    zone.addEventListener("pointermove", onMove);
    zone.addEventListener("pointerup", onEnd);
    zone.addEventListener("pointercancel", onEnd);

    this.detachers.push(() => {
      zone.removeEventListener("pointerdown", onDown);
      zone.removeEventListener("pointermove", onMove);
      zone.removeEventListener("pointerup", onEnd);
      zone.removeEventListener("pointercancel", onEnd);
    });
  }

  private bindButton(button: HTMLElement, action: () => void): void {
    const handler = (event: PointerEvent): void => {
      event.preventDefault();
      event.stopPropagation();
      action();
    };
    button.addEventListener("pointerdown", handler);
    this.detachers.push(() => button.removeEventListener("pointerdown", handler));
  }
}
```

> 注意：左摇杆的 y 翻转——屏幕坐标向下为正，但前进期望是"远离玩家"。约定 `setMovement({x, y})` 中 `y > 0 = forward`，与 keysToAxes 一致。

- [ ] **Step 3.4：跑测试确认通过**

```bash
cd clients/web_client
npx vitest run src/presentation/touch/TouchControlsView.test.ts
```

期望：5 个测试全过。

- [ ] **Step 3.5：跑 tsc + 全部测试确认无回归**

```bash
cd clients/web_client
npx tsc --noEmit
npx vitest run
```

期望：全部通过。

- [ ] **Step 3.6：commit Task 3**

```bash
git add clients/web_client/src/presentation/touch
git commit -m "$(cat <<'EOF'
Add TouchControlsView with dual-stick gesture machine and action buttons

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4：`LocalPlayerController` 合并键盘 + 摇杆

**Files:**
- Modify: `clients/web_client/src/app/controllers/localPlayerController.ts`
- Modify: `clients/web_client/src/app/controllers/localPlayerController.test.ts`

- [ ] **Step 4.1：扩 LocalPlayerController 测试**

既有测试不用 harness——每个 `it` 自行构造 `bus / input / transport / pump / controller`（见 `localPlayerController.test.ts:43-55`）。同款风格，在 `describe("LocalPlayerController", ...)` 末尾追加：

```ts
  it("merges keyboard and virtual stick axes, clamping to unit length", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    const keys = input.getMovementKeys() as MovementKeys;
    keys.forward = true;
    input.setVirtualMovement({ x: 0.8, y: 0 });

    const axes = controller.getCombinedMovementAxesForTest();
    // keyboard forward = 1, stick x = 0.8, stick y = 0
    // raw sum length = sqrt(0.8^2 + 1^2) ≈ 1.28 → clampUnitVec → length 1
    expect(Math.hypot(axes.strafe, axes.forward)).toBeCloseTo(1);
    expect(axes.strafe).toBeGreaterThan(0);
    expect(axes.forward).toBeGreaterThan(0);
  });
```

`getCombinedMovementAxesForTest` 是 LocalPlayerController 上新增的 test-only getter（见 Step 4.3）。

- [ ] **Step 4.2：跑测试确认失败**

```bash
cd clients/web_client
npx vitest run src/app/controllers/localPlayerController.test.ts
```

期望：新测试失败（`combinedAxes` / `getCombinedMovementAxesForTest` 不存在）。

- [ ] **Step 4.3：在 LocalPlayerController 内实现合并**

编辑 `clients/web_client/src/app/controllers/localPlayerController.ts`：

1. import 行加 `MovementAxes`、`clampUnitVec`：

```ts
import {
  buildMovementWorldDirection,
  clampUnitVec,
  keysToAxes,
  type MovementAxes,
} from "@domain/movement/inputDirection";
```

2. 加私有方法 `combinedAxes()`：

```ts
  private combinedAxes(): MovementAxes {
    const keyboard = keysToAxes(this.input.getMovementKeys());
    const stick = this.input.getVirtualMovement();
    const merged = clampUnitVec({
      x: keyboard.strafe + stick.x,
      y: keyboard.forward + stick.y,
    });
    return { strafe: merged.x, forward: merged.y };
  }
```

3. 第 151 行和 283 行的 `buildMovementWorldDirection(keysToAxes(this.input.getMovementKeys()), ...)` 全部替换为：

```ts
buildMovementWorldDirection(this.combinedAxes(), this.cameraYawResolver())
```

4. 在 `emitInputBlockedIfActive` 内（约第 188 行），保持原 keys 检测：键盘还在用 boolean keys 判定"有意图"。**额外**判断摇杆是否有非零向量：

```ts
  private emitInputBlockedIfActive(nowMs: number): void {
    const keys = this.input.getMovementKeys();
    const stick = this.input.getVirtualMovement();
    const jump = this.input.hasPendingJump();
    const hasMoveInput =
      keys.forward || keys.backward || keys.left || keys.right ||
      stick.x !== 0 || stick.y !== 0;
    // ... 余下原样
```

5. 加 test-only getter（见 4.1）：

```ts
  /** Visible for tests. */
  getCombinedMovementAxesForTest(): MovementAxes {
    return this.combinedAxes();
  }
```

- [ ] **Step 4.4：跑测试确认通过 + 无回归**

```bash
cd clients/web_client
npx vitest run
```

期望：全部通过。

- [ ] **Step 4.5：commit Task 4**

```bash
git add clients/web_client/src/app/controllers/localPlayerController.ts \
        clients/web_client/src/app/controllers/localPlayerController.test.ts
git commit -m "$(cat <<'EOF'
Merge virtual stick into local player movement axes

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5：bootstrap 接入触屏路径

**Files:**
- Modify: `clients/web_client/src/app/bootstrap.ts`
- Modify: `clients/web_client/index.html` (如有需要补 `<div id="touch-controls">` 子节点选择器对齐)
- Modify: `clients/web_client/src/app/bootstrap.test.ts`（若存在）

- [ ] **Step 5.1：在 `bootstrap.ts` 加触屏探测与 view 装配**

编辑 `clients/web_client/src/app/bootstrap.ts`：

1. 加 import：

```ts
import { TouchControlsView, type TouchControlsElements } from "../presentation/touch/TouchControlsView";
```

2. 在 `BootstrapTargets` 接口加 `touchControls: HTMLDivElement | null`（null 兼容缺失场景）。

3. 在 `bootstrap` 函数末尾、`loop.start()` 之前插入：

```ts
  const isTouchPrimary =
    window.matchMedia?.("(pointer: coarse)")?.matches === true ||
    (typeof navigator !== "undefined" && navigator.maxTouchPoints > 0);

  let touchControlsView: TouchControlsView | null = null;

  if (isTouchPrimary && touchControls) {
    document.documentElement.classList.add("is-touch");
    input.setDisableCanvasActions(true);
    sceneHandles.setDisableCanvasInput(true);

    const elements = resolveTouchControlsElements(touchControls);
    if (elements) {
      touchControlsView = new TouchControlsView(elements, {
        setMovement: (vec) => input.setVirtualMovement(vec),
        requestJump: (source) => input.requestJump(source),
        emitBreak: () => eventBus.emit("input:break-block", { source: "touch_button" }),
        emitPlace: () => eventBus.emit("input:place-block", { source: "touch_button" }),
        applyCameraYawPitchDelta: (yaw, pitch) => sceneHandles.applyCameraYawPitchDelta(yaw, pitch),
      });
      loop.subscribe(touchControlsView);
    }
  }
```

4. 在文件末尾添加 helper：

```ts
function resolveTouchControlsElements(root: HTMLElement): TouchControlsElements | null {
  const q = <T extends HTMLElement>(sel: string) => root.querySelector(sel) as T | null;
  const zoneLeft = q(".touch-zone--left");
  const zoneRight = q(".touch-zone--right");
  const stickLeft = q(".touch-stick--left");
  const stickRight = q(".touch-stick--right");
  const btnJump = q(".touch-btn--jump");
  const btnBreak = q(".touch-btn--break");
  const btnPlace = q(".touch-btn--place");
  if (!zoneLeft || !zoneRight || !stickLeft || !stickRight || !btnJump || !btnBreak || !btnPlace) {
    return null;
  }
  return { root, zoneLeft, zoneRight, stickLeft, stickRight, btnJump, btnBreak, btnPlace };
}
```

5. 在 `dispose` 内加：

```ts
    touchControlsView?.dispose();
```

- [ ] **Step 5.2：在 `main.ts` 拿到 `#touch-controls` DOM 节点传给 bootstrap**

`main.ts` 当前用 `require<Thing>()` factory 模式（见 `main.ts:3-33`）。`#touch-controls` 在桌面端也存在但 CSS `display:none`——所以一定能查到，类型严格 require 即可。追加 factory 并在 `main()` 里传入：

```ts
function requireTouchControls(): HTMLDivElement {
  const root = document.getElementById("touch-controls");
  if (!(root instanceof HTMLDivElement)) {
    throw new Error("#touch-controls element missing or wrong type");
  }
  return root;
}

async function main(): Promise<void> {
  await bootstrap({
    canvas: requireCanvas(),
    hud: requireHud(),
    hotbarDock: requireHotbarDock(),
    voxelPanel: requireVoxelPanel(),
    touchControls: requireTouchControls(),
  });
}
```

对应地，Step 5.1 中 `BootstrapTargets` 接口的 `touchControls` 字段应为 `HTMLDivElement`（非 nullable）。Step 5.1 的 `if (isTouchPrimary && touchControls)` 简化为 `if (isTouchPrimary)`。

- [ ] **Step 5.3：跑 tsc 验证**

```bash
cd clients/web_client
npx tsc --noEmit
```

期望：无 error。

- [ ] **Step 5.4：跑全部 vitest 确认无回归**

```bash
cd clients/web_client
npx vitest run
```

期望：全部通过。

- [ ] **Step 5.5：本地手动验证横屏 / 竖屏 / 桌面（dev 自检）**

```bash
cd clients/web_client
npx vite --host 0.0.0.0
```

在浏览器：

1. Chrome DevTools "Toggle device toolbar" → iPhone 14 Pro Max **横屏**：
   - 左下拖动 → 角色移动；
   - 右下拖动 → 视角转动；
   - 右下三按钮：跳 / 放 / 破有反馈（用 `window.__voxelCli?.run("snapshot")` 或 observer 日志确认 emit）。
2. 切**竖屏**：看到"请将设备旋转至横屏以游玩"全屏覆盖，摇杆与按钮均消失/不响应。
3. 切回**桌面**视图（关掉 device toolbar）：`html.is-touch` 类不存在，触摸 DOM `display:none`，鼠标点 canvas 仍能破坏方块、按住拖能转视角。

观察任一不符则记录并修。

- [ ] **Step 5.6：commit Task 5**

```bash
git add clients/web_client/src/app/bootstrap.ts clients/web_client/src/main.ts
git commit -m "$(cat <<'EOF'
Wire touch controls into bootstrap when pointer:coarse is primary

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## 完成判定

- 所有 5 个 task 的 commit 已落盘到 `master`（不 push，按 `feedback_decision_stub_workflow.md` 约定）。
- `npx vitest run` 在 `clients/web_client` 下全绿。
- 手动验证清单（Step 5.5）三项通过。
- 桌面端在 `git checkout master~5 && build` 与 `master && build` 下肉眼可比，鼠键交互无差别。
