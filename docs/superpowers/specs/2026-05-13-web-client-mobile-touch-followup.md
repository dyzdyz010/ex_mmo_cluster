# Web Client Mobile Touch Followup (2026-05-13)

记 2026-05-12 上线 `web_client` 触屏方案后，在真实 iPhone Safari 横屏环境发现的两个 prod bug，根因与修法，以及未来类似前端工作的检查清单。

原方案：`2026-05-12-web-client-mobile-touch-design.md` / `2026-05-12-web-client-mobile-touch.md`。本次基线 commit：`694c6fc`。

## 1. Bug #1 — 横屏 iPhone 上 HUD 和 voxel-panel 占满屏幕、遮挡触屏 UI

### 现象

iOS Safari 横屏访问 `https://mmo.hemifuture.cn/client/`，触屏 UI（摇杆 + 三按钮）虽然挂上 DOM（`html.is-touch` 类已加），但屏幕上看到的是左上调试 HUD 大段文字 + 右上 voxel-panel 表单，把摇杆和按钮压在视觉上"不可见"的下层。

### 根因

两段早期工作各自独立、没有交互审视：

- 2026-05-12 第一轮（commit `d87fd2e`）：用 `@media (max-width: 480px) { #hud { display: none } #voxel-panel { display: none } }` 隐藏开发者面板。判定条件是**纯视口宽度**。
- 2026-05-12 第二轮（commit `694c6fc` 系列）：触屏 UI 用 `html.is-touch` JS feature detect 启用。判定条件是 `(pointer: coarse) || maxTouchPoints > 0`。

iPhone 14 横屏宽度约 844px > 480px → `max-width: 480px` 媒体查询**不触发** → 开发者面板照常显示。同一台设备 `maxTouchPoints > 0` → `html.is-touch` 添加成功 → 触屏 UI 同时在 DOM 树里。两个机制语义不一致，结果叠加。

### 修法

把 `#hud` / `#voxel-panel` 的隐藏改成与触屏 UI 显示同源：

```css
html.is-touch #hud,
html.is-touch #voxel-panel {
  display: none;
}
```

并从 `@media (max-width: 480px)` 块中删除原 `#hud { display: none }` 和 `#voxel-panel { display: none }`。

测试 `hudShell.test.ts` 中对应断言也从扫描 `@media (max-width: 480px)` 块改为正则匹配 `html.is-touch #hud …display: none`。

## 2. Bug #2 — 准星与方块高亮框纵向偏移

### 现象

iOS Safari 横屏，屏幕中心的 `#reticle` 十字与射线命中体素的 3D 高亮方框在 y 方向不对齐，偏移约 1 个体素高度。

### 根因

iOS Safari 的 `100vh` 是 "large viewport height"（地址栏完全收起后的最大视口高度），而 `window.innerHeight` 是 "small viewport height"（当前实际可见高度）。地址栏可见时两者差几十 px。

`#app` canvas 的 CSS 用 `height: 100vh`（large）；`scene.ts` 的 `onResize` 用 `renderer.setSize(window.innerWidth, window.innerHeight)`（small）。结果：

- 渲染 framebuffer：`innerWidth × innerHeight`（small）
- canvas DOM 显示尺寸：`100vw × 100vh`（large）
- 浏览器把 framebuffer 拉伸到 DOM 尺寸 → 渲染像素纵向被放大约 1.05x
- raycast 用 NDC (0, 0) 命中的 3D 点经 framebuffer → DOM canvas → 视觉坐标 `(50%w, 50% × framebufferH/canvasDOMH)`
- `#reticle` 用 `top: 50%; left: 50%` 定位在 layout viewport（也是 large 高度）的几何中心
- 两者中心 y 坐标差 = `(canvasDOMH − framebufferH) / 2 ≈ 15–30 px`

### 修法

`#app` 改用 dynamic viewport units，让 CSS 高度随地址栏伸缩自动跟 `innerHeight` 同步：

```css
#app {
  width: 100dvw;
  height: 100dvh;
  display: block;
}
```

`100dvh` 与 `window.innerHeight` 在任意时刻一致，framebuffer 与 canvas DOM 尺寸不再脱节。iOS Safari 15.4+ / Android Chrome 108+ 支持，覆盖目标设备群。

## 3. 反思 — 检查清单（写进 followup spec 是为下次类似工作复用）

合并新触屏 / 移动端路径时必查项：

1. **既有 mobile 相关 CSS 与新判定逻辑是否一致**。整仓 grep：
   ```
   grep -rn "max-width\|min-width\|orientation\|coarse\|hover:" clients/web_client/index.html src/
   ```
   任何已存在的"隐藏/缩小桌面 UI"规则都要确认与新 `html.is-touch` / `isTouchPrimary` 是否同语义；不一致就统一成同一开关。
2. **viewport 单位**：所有"应该占满可视区"的元素（canvas、全屏遮罩、固定底栏）用 `dvw / dvh / svw / svh`，不要用 `vw / vh`。地址栏可显隐的浏览器（iOS Safari、Android Chrome）下 `vh` 静态 = large viewport，会造成 CSS 高度与 `window.innerHeight` 不一致。
3. **设计稿 §6 风险章节穷尽不到的盲区**：把"viewport 单位选择"和"既有 dev-only UI 隐藏路径"列入未来 brainstorming 模板的必问项。
4. **真机 / 真浏览器验证不可省**：本次本地 vitest 全绿、桌面 Chrome 也"看起来正常"（Windows 触屏笔电反而误判 `maxTouchPoints > 0`，恰好走了正确分支），完全没暴露这两个 bug。手动验证步骤里应该明写：iOS Safari 横屏 + iPhone DPR、Android Chrome 横屏。
5. **prod hot-patch 用 `?diag=N` 守门**：用户不可能用 USB 调试时，临时把诊断 banner 加进 dist/index.html 是有效的远程诊断手段，但必须用 query string 守门避免影响普通玩家。

## 4. 受影响文件

| 文件 | 修改 |
|---|---|
| `clients/web_client/index.html` | `#app` 改 dvh/dvw；删除 `@media (max-width: 480px)` 里 `#hud`/`#voxel-panel` 隐藏；新增 `html.is-touch #hud, html.is-touch #voxel-panel { display: none }` |
| `clients/web_client/src/presentation/hud/hudShell.test.ts` | 断言改成 `html.is-touch` 路径；新增 `#app` 用 dvh/dvw 的断言 |
| `docs/superpowers/specs/2026-05-13-web-client-mobile-touch-followup.md` | 本文档 |

不修源码层的 `renderer.setSize(window.innerWidth, window.innerHeight)`——`dvh` 已经把 CSS 侧拉齐到 `innerHeight`，问题在 CSS 不在 JS。
