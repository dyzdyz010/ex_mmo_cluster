import { describe, expect, it } from "vitest";
import { EVoxelRotation } from "../../voxel/core/types";
import {
  HotbarDockView,
  renderHotbarDockHtml,
  type HotbarDockEditPort,
} from "./hotbarDockView";
import type { HotbarEntry, HotbarState } from "../../app/controllers/worldEditController";
import { VoxelMaterialId } from "../../material/catalog";

class FakeDockRoot {
  innerHTML = "";
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

  clickHotbarIndex(index: number): void {
    this.clickListener?.({
      preventDefault: () => undefined,
      target: {
        closest: () => ({
          getAttribute: (name: string) => (name === "data-hotbar-index" ? String(index) : null),
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

class FakeHotbarEdit implements HotbarDockEditPort {
  readonly selected: number[] = [];
  private selectedIndex = 0;

  getHotbarState(): HotbarState {
    return makeHotbarState(this.selectedIndex);
  }

  selectHotbarIndex(index: number, source: string): void {
    expect(source).toBe("hotbar_dock");
    this.selected.push(index);
    this.selectedIndex = index;
  }
}

describe("HotbarDockView", () => {
  it("renders the full hotbar with selected state and prefab shape icons", () => {
    const state = makeHotbarState(4);
    const html = renderHotbarDockHtml(state);

    expect(html.match(/data-hotbar-index=/g)).toHaveLength(state.entries.length);
    expect(html).toContain('aria-pressed="true"');
    expect(html).toContain('aria-label="5 sphere prefab"');
    expect(html).toContain("hotbar-icon--sphere");
    expect(html).toContain("hotbar-icon--cylinder");
    expect(html).toContain("hotbar-icon--stairs");
  });

  it("selects a clicked slot through the edit controller and refreshes the dock", () => {
    const root = new FakeDockRoot();
    const edit = new FakeHotbarEdit();
    const view = new HotbarDockView(root as unknown as HTMLDivElement, edit);

    root.clickHotbarIndex(5);

    expect(edit.selected).toEqual([5]);
    expect(root.innerHTML).toContain('aria-label="6 cylinder prefab"');
    expect(root.innerHTML).toContain('aria-pressed="true"');

    view.dispose();
    root.clickHotbarIndex(1);
    expect(edit.selected).toEqual([5]);
  });

  it("stops dock pointer presses before they reach world editing", () => {
    const root = new FakeDockRoot();
    const edit = new FakeHotbarEdit();
    const view = new HotbarDockView(root as unknown as HTMLDivElement, edit);

    expect(root.pointerDown()).toBe(true);

    view.dispose();
    expect(root.pointerDown()).toBe(false);
  });
});

function makeHotbarState(selectedIndex: number): HotbarState {
  const entries: HotbarEntry[] = [
    { kind: "material", label: "dirt", materialId: VoxelMaterialId.Dirt },
    { kind: "material", label: "stone", materialId: VoxelMaterialId.Stone },
    { kind: "material", label: "wood", materialId: VoxelMaterialId.Wood },
    { kind: "material", label: "ice", materialId: VoxelMaterialId.Ice },
    { kind: "prefab", label: "sphere", prefabName: "builtin_sphere", rotation: EVoxelRotation.Rot0 },
    {
      kind: "prefab",
      label: "cylinder",
      prefabName: "builtin_cylinder",
      rotation: EVoxelRotation.Rot0,
    },
    { kind: "prefab", label: "stairs", prefabName: "builtin_stairs", rotation: EVoxelRotation.Rot0 },
  ];

  return {
    entries,
    selectedIndex,
    selected: entries[selectedIndex]!,
  };
}
