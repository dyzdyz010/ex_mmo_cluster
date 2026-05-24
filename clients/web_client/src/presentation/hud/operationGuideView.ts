type GuideActionTarget = {
  getAttribute(name: string): string | null;
};

type GuideKeyTarget = Pick<Window, "addEventListener" | "removeEventListener">;

/**
 * Dedicated touch-friendly operation-guide trigger. It keeps the mobile entry
 * point independent from the desktop voxel panel, which is hidden on touch UI.
 */
export class OperationGuideButtonView {
  constructor(
    private readonly button: HTMLButtonElement,
    private readonly openGuide: () => void,
  ) {
    this.button.addEventListener("pointerdown", this.handlePointerDown);
  }

  dispose(): void {
    this.button.removeEventListener("pointerdown", this.handlePointerDown);
  }

  private readonly handlePointerDown = (event: PointerEvent): void => {
    event.preventDefault();
    event.stopPropagation();
    this.openGuide();
  };
}

/**
 * Operation guide overlay. It owns only popup visibility and DOM events; the
 * gameplay controls remain in their existing HUD, input, and CLI surfaces.
 */
export class OperationGuideView {
  private openState = false;

  constructor(
    private readonly root: HTMLDivElement,
    private readonly keyTarget: GuideKeyTarget | undefined = typeof window === "undefined"
      ? undefined
      : window,
  ) {
    this.root.className = "operation-guide-root";
    this.root.addEventListener("click", this.handleClick);
    this.root.addEventListener("pointerdown", this.stopWorldEditPointer);
    this.keyTarget?.addEventListener("keydown", this.handleKeydown);
    this.render();
  }

  open(): void {
    this.openState = true;
    this.render();
  }

  close(): void {
    this.openState = false;
    this.render();
  }

  isOpen(): boolean {
    return this.openState;
  }

  dispose(): void {
    this.root.removeEventListener("click", this.handleClick);
    this.root.removeEventListener("pointerdown", this.stopWorldEditPointer);
    this.keyTarget?.removeEventListener("keydown", this.handleKeydown);
    this.root.innerHTML = "";
    this.root.className = "operation-guide-root";
  }

  private readonly handleClick = (event: MouseEvent): void => {
    const action = closestGuideAction(event.target)?.getAttribute("data-guide-action");
    if (action !== "close") {
      return;
    }

    event.preventDefault?.();
    this.close();
  };

  private readonly handleKeydown = (event: KeyboardEvent): void => {
    if (!this.openState || event.key !== "Escape") {
      return;
    }

    event.preventDefault();
    this.close();
  };

  private readonly stopWorldEditPointer = (event: PointerEvent): void => {
    event.stopPropagation();
  };

  private render(): void {
    this.root.className = this.openState ? "operation-guide-root is-open" : "operation-guide-root";
    this.root.innerHTML = renderOperationGuideHtml(this.openState);
  }
}

export function renderOperationGuideHtml(open: boolean): string {
  if (!open) {
    return "";
  }

  return [
    `<div class="operation-guide-backdrop" data-guide-action="close"></div>`,
    `<section class="operation-guide-dialog" role="dialog" aria-modal="true" aria-labelledby="operation-guide-title">`,
    `<header class="operation-guide-header">`,
    `<div>`,
    `<p class="operation-guide-kicker">Web Client</p>`,
    `<h2 id="operation-guide-title">操作指南</h2>`,
    `</div>`,
    `<button class="operation-guide-close" type="button" data-guide-action="close" aria-label="Close guide">Close</button>`,
    `</header>`,
    `<div class="operation-guide-content operation-guide-desktop">`,
    renderGuideSection("移动与视角", [
      `<strong>WASD</strong> 移动，<strong>Space</strong> 跳跃，鼠标拖动视角。`,
      `左键破坏对准的方块，右键放置当前热栏材料。`,
    ]),
    renderGuideSection("材料与电源", [
      `热栏里的电源块是 <code>power_block</code>，它是电流的真实来源，不再是虚空供电。`,
      `铁块适合作为导线；空气、泥土、石头、木头和冰不会形成有效导电路径。`,
    ]),
    renderGuideSection("通电流程", [
      `桌面端鼠标主要被视角占用：用 <strong>Z / X / C</strong> 记录电源、记录目标并执行 <strong>Conduct</strong>。`,
      `准星对准目标时按 <strong>L</strong>：实体优先，没有实体命中时使用准星方块；完全没有命中时使用本地角色作测试目标。`,
      `高级参数走控制台，例如 <code>voxel_conduct ...</code>；需要订阅地块时再脱出指针点 <code>voxel_subscribe</code> 表单。`,
    ]),
    renderGuideSection("观察效果", [
      `点 <strong>Field</strong> 显示电场和发热观察层；右侧状态会显示 electric 与 smoke 数量。`,
      `发热用烟雾粒子表示，<strong>smoke</strong> 越多代表本 tick 热量越高。`,
    ]),
    `</div>`,
    `<div class="operation-guide-content operation-guide-touch">`,
    renderGuideSection("移动与视角", [
      `<strong>左半屏</strong> 按住拖动控制移动；<strong>右半屏</strong> 按住拖动控制视角。`,
      `触屏模式以横屏为主；竖屏会先显示 <strong>横屏</strong> 提示，避免按钮挤压。`,
    ]),
    renderGuideSection("触屏按钮", [
      `<strong>Jump</strong> 跳跃，<strong>Place</strong> 放置当前热栏方块，<strong>Break</strong> 破坏准星方块。`,
      `左上角操作条提供 <strong>Field</strong>、<strong>Heat</strong>、<strong>Conduct</strong> 和 <strong>Sub Aim</strong>，不依赖桌面端右侧面板。`,
      `右上角 <strong>?</strong> 随时打开本指南。`,
    ]),
    renderGuideSection("材料与电源", [
      `底部热栏可点选材料；<code>power_block</code> 是真实电源块，铁块适合作为导线。`,
      `移动端先完成移动、放置、破坏和观察；高级电路参数仍建议用桌面端或 CLI 调试。`,
    ]),
    renderGuideSection("观察效果", [
      `电热效果用烟雾粒子表达，<strong>smoke</strong> 越多代表本 tick 热量越高。`,
      `<strong>Sub Aim</strong> 会按当前准星方块所在 chunk 自动订阅；需要精确参数时再用 <code>window.__voxelCli</code>。`,
    ]),
    `</div>`,
    `</section>`,
  ].join("");
}

function renderGuideSection(title: string, items: string[]): string {
  return [
    `<section class="operation-guide-section">`,
    `<h3>${escapeHtml(title)}</h3>`,
    `<ul>`,
    ...items.map((item) => `<li>${item}</li>`),
    `</ul>`,
    `</section>`,
  ].join("");
}

function closestGuideAction(target: EventTarget | null): GuideActionTarget | null {
  const candidate = target as { closest?: (selector: string) => unknown } | null;
  const action = candidate?.closest?.("[data-guide-action]");
  if (!action || typeof (action as { getAttribute?: unknown }).getAttribute !== "function") {
    return null;
  }
  return action as GuideActionTarget;
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (char) => {
    switch (char) {
      case "&":
        return "&amp;";
      case "<":
        return "&lt;";
      case ">":
        return "&gt;";
      case '"':
        return "&quot;";
      case "'":
        return "&#39;";
      default:
        return char;
    }
  });
}
