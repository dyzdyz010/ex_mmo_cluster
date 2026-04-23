import { VoxelMaterialId } from "../../material/catalog";
import type { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";

export interface MovementKeys {
  forward: boolean;
  backward: boolean;
  left: boolean;
  right: boolean;
}

/**
 * Translates raw keyboard events into domain intents.
 *
 * Continuous state (movement keys) is exposed via a pull-style getter because
 * the simulation reads it on fixed-dt steps; firing events per keydown/keyup
 * would force subscribers to debounce. One-shot actions (material change,
 * place, break) go through the event bus.
 */
export class InputController {
  private readonly keys: MovementKeys = {
    forward: false,
    backward: false,
    left: false,
    right: false,
  };

  constructor(private readonly bus: EventBus<AppEvents>) {}

  attach(target: Window): () => void {
    target.addEventListener("keydown", this.handleKeyDown);
    target.addEventListener("keyup", this.handleKeyUp);
    target.addEventListener("pointerdown", this.handlePointerDown);
    target.addEventListener("wheel", this.handleWheel);
    target.addEventListener("contextmenu", this.preventContextMenu);
    return () => {
      target.removeEventListener("keydown", this.handleKeyDown);
      target.removeEventListener("keyup", this.handleKeyUp);
      target.removeEventListener("pointerdown", this.handlePointerDown);
      target.removeEventListener("wheel", this.handleWheel);
      target.removeEventListener("contextmenu", this.preventContextMenu);
    };
  }

  getMovementKeys(): Readonly<MovementKeys> {
    return this.keys;
  }

  private readonly preventContextMenu = (event: Event): void => {
    event.preventDefault();
  };

  private readonly handlePointerDown = (event: PointerEvent): void => {
    switch (event.button) {
      case 0:
        event.preventDefault();
        this.bus.emit("input:break-block", { source: "mouse_left" });
        break;
      case 2:
        event.preventDefault();
        this.bus.emit("input:place-block", { source: "mouse_right" });
        break;
      default:
        break;
    }
  };

  private readonly handleWheel = (event: WheelEvent): void => {
    if (event.ctrlKey || event.deltaY === 0) {
      return;
    }
    event.preventDefault();
    this.bus.emit("input:hotbar-cycle", {
      direction: event.deltaY > 0 ? 1 : -1,
      source: "wheel",
    });
  };

  private readonly handleKeyDown = (event: KeyboardEvent): void => {
    switch (event.code) {
      case "KeyW":
      case "ArrowUp":
        this.keys.forward = true;
        break;
      case "KeyS":
      case "ArrowDown":
        this.keys.backward = true;
        break;
      case "KeyA":
      case "ArrowLeft":
        this.keys.left = true;
        break;
      case "KeyD":
      case "ArrowRight":
        this.keys.right = true;
        break;
      case "Digit1":
        this.bus.emit("input:material-selected", {
          materialId: VoxelMaterialId.Dirt,
          source: "keyboard",
        });
        break;
      case "Digit2":
        this.bus.emit("input:material-selected", {
          materialId: VoxelMaterialId.Stone,
          source: "keyboard",
        });
        break;
      case "Digit3":
        this.bus.emit("input:material-selected", {
          materialId: VoxelMaterialId.Wood,
          source: "keyboard",
        });
        break;
      case "Digit4":
        this.bus.emit("input:material-selected", {
          materialId: VoxelMaterialId.Ice,
          source: "keyboard",
        });
        break;
      case "Digit5":
      case "Digit6":
      case "Digit7":
        this.bus.emit("input:hotbar-select", {
          index: Number.parseInt(event.code.slice("Digit".length), 10) - 1,
          source: "keyboard",
        });
        break;
      case "KeyF":
        this.bus.emit("input:place-block", { source: "keyboard" });
        break;
      case "KeyG":
        this.bus.emit("input:break-block", { source: "keyboard" });
        break;
      default:
        break;
    }
  };

  private readonly handleKeyUp = (event: KeyboardEvent): void => {
    switch (event.code) {
      case "KeyW":
      case "ArrowUp":
        this.keys.forward = false;
        break;
      case "KeyS":
      case "ArrowDown":
        this.keys.backward = false;
        break;
      case "KeyA":
      case "ArrowLeft":
        this.keys.left = false;
        break;
      case "KeyD":
      case "ArrowRight":
        this.keys.right = false;
        break;
      default:
        break;
    }
  };
}
