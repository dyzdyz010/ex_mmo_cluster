import { VoxelMaterialId } from "../../material/catalog";
import type { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import { clampUnitVec, type MovementKeys } from "../../domain/movement/inputDirection";

export type { MovementKeys } from "../../domain/movement/inputDirection";

const DEFAULT_HEAT_TARGET_CELSIUS = 800;
const DEFAULT_CONDUCTION_SOURCE_POTENTIAL = 120;
const DEFAULT_CONDUCTION_MAX_TICKS = 90;

/**
 * Translates raw keyboard events into domain intents.
 *
 * Continuous state (movement keys) is exposed via a pull-style getter because
 * the simulation reads it on fixed-dt steps; firing events per keydown/keyup
 * would force subscribers to debounce. One-shot actions (material change,
 * place, break, heat) go through the event bus.
 */
export class InputController {
  private readonly keys: MovementKeys = {
    forward: false,
    backward: false,
    left: false,
    right: false,
  };
  private jumpPressed = false;
  private virtualMovement: { x: number; y: number } = { x: 0, y: 0 };
  private disableCanvasActions = false;

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

  consumeJumpPressed(): boolean {
    const pressed = this.jumpPressed;
    this.jumpPressed = false;
    return pressed;
  }

  getVirtualMovement(): Readonly<{ x: number; y: number }> {
    return this.virtualMovement;
  }

  setVirtualMovement(vec: { x: number; y: number }): void {
    this.virtualMovement = clampUnitVec(vec);
  }

  setDisableCanvasActions(flag: boolean): void {
    this.disableCanvasActions = flag;
  }

  hasPendingJump(): boolean {
    return this.jumpPressed;
  }

  requestJump(source = "programmatic"): void {
    this.jumpPressed = true;
    this.bus.emit("input:jump", { source });
  }

  private readonly preventContextMenu = (event: Event): void => {
    event.preventDefault();
  };

  private readonly handlePointerDown = (event: PointerEvent): void => {
    if (this.disableCanvasActions) {
      return;
    }
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
      case "Digit8":
        this.bus.emit("input:hotbar-select", {
          index: Number.parseInt(event.code.slice("Digit".length), 10) - 1,
          source: "keyboard",
        });
        break;
      case "KeyF":
        if (!isPlainOneShotShortcut(event)) break;
        this.bus.emit("input:set-selected-voxel-temperature", {
          source: "keyboard",
          targetTemperatureCelsius: DEFAULT_HEAT_TARGET_CELSIUS,
        });
        break;
      case "KeyE":
        if (!isPlainOneShotShortcut(event)) break;
        this.bus.emit("input:conduct-selected-voxel", {
          source: "keyboard",
          sourcePotential: DEFAULT_CONDUCTION_SOURCE_POTENTIAL,
          maxTicks: DEFAULT_CONDUCTION_MAX_TICKS,
        });
        break;
      case "KeyZ":
        if (!isPlainOneShotShortcut(event)) break;
        this.bus.emit("input:capture-conduction-endpoint", {
          role: "source",
          source: "keyboard",
        });
        break;
      case "KeyX":
        if (!isPlainOneShotShortcut(event)) break;
        this.bus.emit("input:capture-conduction-endpoint", {
          role: "target",
          source: "keyboard",
        });
        break;
      case "KeyC":
        if (!isPlainOneShotShortcut(event)) break;
        this.bus.emit("input:submit-conduction", { source: "keyboard" });
        break;
      case "KeyG":
        this.bus.emit("input:break-block", { source: "keyboard" });
        break;
      case "Space":
        event.preventDefault();
        if (!event.repeat) {
          this.requestJumpFromKeyboard();
        }
        break;
      default:
        if (isSpaceKey(event)) {
          event.preventDefault();
          if (!event.repeat) {
            this.requestJumpFromKeyboard();
          }
        }
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

  private requestJumpFromKeyboard(): void {
    this.jumpPressed = true;
    this.bus.emit("input:jump", { source: "keyboard" });
  }
}

function isSpaceKey(event: KeyboardEvent): boolean {
  return event.code === "Space" || event.key === " " || event.key === "Spacebar";
}

function isPlainOneShotShortcut(event: KeyboardEvent): boolean {
  return !event.repeat && !event.ctrlKey && !event.metaKey && !event.altKey;
}
