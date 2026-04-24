import { getMaterialDefinition } from "../../material/catalog";
import type { FrameSubscriber } from "../../app/gameLoop";
import type { HotbarEntry, HotbarState } from "../../app/controllers/worldEditController";

export interface HotbarDockEditPort {
  getHotbarState(): HotbarState;
  selectHotbarIndex(index: number, source: string): void;
}

type HotbarButtonTarget = {
  getAttribute(name: string): string | null;
};

const HOTBAR_REFRESH_INTERVAL_MS = 80;

/**
 * Visible bottom dock for the editor hotbar. It owns only DOM projection and
 * pointer shielding; selection truth remains in WorldEditController.
 */
export class HotbarDockView implements FrameSubscriber {
  private refreshAccumulatorMs = HOTBAR_REFRESH_INTERVAL_MS;
  private renderKey = "";

  constructor(
    private readonly dock: HTMLDivElement,
    private readonly edit: HotbarDockEditPort,
  ) {
    this.dock.addEventListener("click", this.handleClick);
    this.dock.addEventListener("pointerdown", this.stopWorldEditPointer);
    this.renderNow();
  }

  onFrame(_nowMs: number, dtMs: number): void {
    this.refreshAccumulatorMs += dtMs;
    if (this.refreshAccumulatorMs < HOTBAR_REFRESH_INTERVAL_MS) {
      return;
    }
    this.refreshAccumulatorMs = 0;
    this.renderNow();
  }

  dispose(): void {
    this.dock.removeEventListener("click", this.handleClick);
    this.dock.removeEventListener("pointerdown", this.stopWorldEditPointer);
    this.dock.innerHTML = "";
  }

  private readonly handleClick = (event: MouseEvent): void => {
    const button = closestHotbarButton(event.target);
    if (!button) {
      return;
    }

    const index = Number.parseInt(button.getAttribute("data-hotbar-index") ?? "", 10);
    if (!Number.isInteger(index)) {
      return;
    }

    event.preventDefault();
    this.edit.selectHotbarIndex(index, "hotbar_dock");
    this.renderKey = "";
    this.renderNow();
  };

  private readonly stopWorldEditPointer = (event: PointerEvent): void => {
    event.stopPropagation();
  };

  private renderNow(): void {
    const state = this.edit.getHotbarState();
    const nextKey = hotbarRenderKey(state);
    if (nextKey === this.renderKey) {
      return;
    }
    this.dock.innerHTML = renderHotbarDockHtml(state);
    this.renderKey = nextKey;
  }
}

export function renderHotbarDockHtml(state: HotbarState): string {
  const selected = state.selected;
  const selectedLabel =
    selected.kind === "prefab" ? `prefab / ${selected.label}` : selected.label;

  return [
    `<div class="hotbar-current">${escapeHtml(`${state.selectedIndex + 1} ${selectedLabel}`)}</div>`,
    `<div class="hotbar-slots" role="toolbar" aria-label="Voxel hotbar">`,
    ...state.entries.map((entry, index) => renderHotbarSlot(entry, index, index === state.selectedIndex)),
    `</div>`,
  ].join("");
}

function renderHotbarSlot(entry: HotbarEntry, index: number, selected: boolean): string {
  const kindLabel = entry.kind === "prefab" ? "prefab" : "material";
  const label = escapeHtml(entry.label);
  const selectedClass = selected ? " is-selected" : "";
  const icon = entry.kind === "material" ? renderMaterialIcon(entry.materialId) : renderPrefabIcon(entry.label);

  return [
    `<button class="hotbar-slot hotbar-slot--${entry.kind}${selectedClass}"`,
    ` type="button" data-hotbar-index="${index}"`,
    ` aria-label="${index + 1} ${label} ${kindLabel}" aria-pressed="${selected ? "true" : "false"}"`,
    ` title="${index + 1} ${label}">`,
    `<span class="hotbar-key">${index + 1}</span>`,
    icon,
    `<span class="hotbar-label">${label}</span>`,
    `</button>`,
  ].join("");
}

function renderMaterialIcon(materialId: number): string {
  const color = `#${getMaterialDefinition(materialId).baseColorHex.toString(16).padStart(6, "0")}`;
  return `<span class="hotbar-icon hotbar-icon--material" style="--slot-color: ${color}"></span>`;
}

function renderPrefabIcon(label: string): string {
  const shapeClass = prefabShapeClass(label);
  return `<span class="hotbar-icon hotbar-icon--prefab ${shapeClass}" aria-hidden="true"></span>`;
}

function prefabShapeClass(label: string): string {
  switch (label) {
    case "sphere":
      return "hotbar-icon--sphere";
    case "cylinder":
      return "hotbar-icon--cylinder";
    case "stairs":
      return "hotbar-icon--stairs";
    default:
      return "hotbar-icon--prefab-generic";
  }
}

function closestHotbarButton(target: EventTarget | null): HotbarButtonTarget | null {
  const candidate = target as { closest?: (selector: string) => unknown } | null;
  const button = candidate?.closest?.("[data-hotbar-index]");
  if (!button || typeof (button as { getAttribute?: unknown }).getAttribute !== "function") {
    return null;
  }
  return button as HotbarButtonTarget;
}

function hotbarRenderKey(state: HotbarState): string {
  return [
    state.selectedIndex,
    ...state.entries.map((entry, index) =>
      entry.kind === "material"
        ? `${index}:m:${entry.label}:${entry.materialId}`
        : `${index}:p:${entry.label}:${entry.prefabName}:${entry.rotation}`,
    ),
  ].join("|");
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
