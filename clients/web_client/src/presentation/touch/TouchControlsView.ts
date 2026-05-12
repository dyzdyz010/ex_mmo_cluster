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
    // Right stick: positive vec.y = finger moved down screen = look down.
    // Matches the mouse-drag convention in scene.ts (positive deltaY → positive pitch delta).
    this.ports.applyCameraYawPitchDelta(
      this.right.vec.x * TOUCH_YAW_SENSITIVITY * dtMs,
      this.right.vec.y * TOUCH_PITCH_SENSITIVITY * dtMs,
    );
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
        // fall back to window-level pointermove tracking
      }
      // `.touch-stick` uses `position: fixed`; `clientX/Y` are viewport-relative.
      // Works only if no ancestor has CSS `transform / perspective / filter` (those
      // create a new containing block for fixed elements). Task 1 places #touch-controls
      // at the document root, so this holds.
      stick.style.left = `${event.clientX}px`;
      stick.style.top = `${event.clientY}px`;
      stick.classList.add("is-active");
      if (isLeft) {
        this.ports.setMovement({ x: 0, y: 0 });
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
        // y screen-down is positive, but movement forward should be y > 0.
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
    zone.addEventListener("pointerleave", onEnd);

    this.detachers.push(() => {
      zone.removeEventListener("pointerdown", onDown);
      zone.removeEventListener("pointermove", onMove);
      zone.removeEventListener("pointerup", onEnd);
      zone.removeEventListener("pointercancel", onEnd);
      zone.removeEventListener("pointerleave", onEnd);
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
