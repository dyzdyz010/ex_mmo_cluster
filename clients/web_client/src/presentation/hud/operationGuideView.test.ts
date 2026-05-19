import { describe, expect, it } from "vitest";
import {
  OperationGuideButtonView,
  OperationGuideView,
  renderOperationGuideHtml,
} from "./operationGuideView";

class FakeGuideRoot {
  innerHTML = "";
  className = "";
  private clickListener: ((event: MouseEvent) => void) | null = null;
  private pointerDownListener: ((event: PointerEvent) => void) | null = null;

  addEventListener(type: string, listener: EventListenerOrEventListenerObject): void {
    if (type === "click") {
      this.clickListener = listener as (event: MouseEvent) => void;
    }
    if (type === "pointerdown") {
      this.pointerDownListener = listener as (event: PointerEvent) => void;
    }
  }

  removeEventListener(type: string, listener: EventListenerOrEventListenerObject): void {
    if (type === "click" && this.clickListener === listener) {
      this.clickListener = null;
    }
    if (type === "pointerdown" && this.pointerDownListener === listener) {
      this.pointerDownListener = null;
    }
  }

  clickAction(action: string): void {
    this.clickListener?.({
      target: {
        closest: () => ({
          getAttribute: (name: string) => (name === "data-guide-action" ? action : null),
        }),
      },
    } as unknown as MouseEvent);
  }

  pointerDown(): boolean {
    let stopped = false;
    this.pointerDownListener?.({
      stopPropagation: () => {
        stopped = true;
      },
    } as unknown as PointerEvent);
    return stopped;
  }
}

class FakeKeyTarget {
  private keydownListener: ((event: KeyboardEvent) => void) | null = null;

  addEventListener(type: string, listener: EventListenerOrEventListenerObject): void {
    if (type === "keydown") {
      this.keydownListener = listener as (event: KeyboardEvent) => void;
    }
  }

  removeEventListener(type: string, listener: EventListenerOrEventListenerObject): void {
    if (type === "keydown" && this.keydownListener === listener) {
      this.keydownListener = null;
    }
  }

  pressEscape(): void {
    this.keydownListener?.({
      key: "Escape",
      preventDefault: () => undefined,
    } as unknown as KeyboardEvent);
  }
}

class FakeGuideButton {
  private pointerDownListener: ((event: PointerEvent) => void) | null = null;

  addEventListener(type: string, listener: EventListenerOrEventListenerObject): void {
    if (type === "pointerdown") {
      this.pointerDownListener = listener as (event: PointerEvent) => void;
    }
  }

  removeEventListener(type: string, listener: EventListenerOrEventListenerObject): void {
    if (type === "pointerdown" && this.pointerDownListener === listener) {
      this.pointerDownListener = null;
    }
  }

  pointerDown(): { prevented: boolean; stopped: boolean } {
    const result = { prevented: false, stopped: false };
    this.pointerDownListener?.({
      preventDefault: () => {
        result.prevented = true;
      },
      stopPropagation: () => {
        result.stopped = true;
      },
    } as unknown as PointerEvent);
    return result;
  }
}

describe("OperationGuideView", () => {
  it("renders a guide dialog covering movement, voxel editing, and electric heat workflow", () => {
    const html = renderOperationGuideHtml(true);

    expect(html).toContain('role="dialog"');
    expect(html).toContain("操作指南");
    expect(html).toContain("WASD");
    expect(html).toContain("power_block");
    expect(html).toContain("Z / X / C");
    expect(html).toContain("voxel_subscribe");
    expect(html).toContain("Conduct");
    expect(html).toContain("smoke");
    expect(html).toContain('data-guide-action="close"');
  });

  it("renders touch-specific guide content for the mobile overlay", () => {
    const html = renderOperationGuideHtml(true);

    expect(html).toContain("operation-guide-touch");
    expect(html).toContain("左半屏");
    expect(html).toContain("右半屏");
    expect(html).toContain("Jump");
    expect(html).toContain("Place");
    expect(html).toContain("Break");
    expect(html).toContain("Field");
    expect(html).toContain("Heat");
    expect(html).toContain("Conduct");
    expect(html).toContain("Sub Aim");
    expect(html).toContain("横屏");
  });

  it("does not render dialog content while closed", () => {
    expect(renderOperationGuideHtml(false)).toBe("");
  });

  it("opens, closes, stops world-edit pointer propagation, and supports Escape", () => {
    const root = new FakeGuideRoot();
    const keyTarget = new FakeKeyTarget();
    const view = new OperationGuideView(
      root as unknown as HTMLDivElement,
      keyTarget as unknown as Window,
    );

    expect(view.isOpen()).toBe(false);
    expect(root.innerHTML).toBe("");

    view.open();

    expect(view.isOpen()).toBe(true);
    expect(root.className).toBe("operation-guide-root is-open");
    expect(root.innerHTML).toContain("操作指南");
    expect(root.pointerDown()).toBe(true);

    root.clickAction("close");

    expect(view.isOpen()).toBe(false);
    expect(root.innerHTML).toBe("");

    view.open();
    keyTarget.pressEscape();

    expect(view.isOpen()).toBe(false);

    view.dispose();
    view.open();
    root.clickAction("close");
    expect(view.isOpen()).toBe(true);
  });

  it("opens from the mobile guide button without leaking touch events to the world", () => {
    const button = new FakeGuideButton();
    let openCount = 0;
    const view = new OperationGuideButtonView(button as unknown as HTMLButtonElement, () => {
      openCount += 1;
    });

    expect(button.pointerDown()).toEqual({ prevented: true, stopped: true });
    expect(openCount).toBe(1);

    view.dispose();
    expect(button.pointerDown()).toEqual({ prevented: false, stopped: false });
    expect(openCount).toBe(1);
  });
});
