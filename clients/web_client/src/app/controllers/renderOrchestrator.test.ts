import { describe, expect, it } from "vitest";
import { EVoxelRotation } from "../../voxel/core/types";
import {
  prefabPreviewRequestKey,
  resolveActorDisplayY,
  shouldRefreshPrefabPreview,
  shouldUseCoarsePrefabPreview,
} from "./renderOrchestrator";

describe("resolveActorDisplayY", () => {
  it("adds airborne movement offset above the grounded surface center", () => {
    expect(
      resolveActorDisplayY({
        movementY: 172,
        movementGroundY: 100,
        surfaceCenterY: 160,
      }),
    ).toBe(232);
  });

  it("keeps grounded actors on the surface center when movement y is below the center", () => {
    expect(
      resolveActorDisplayY({
        movementY: 100,
        movementGroundY: 100,
        surfaceCenterY: 160,
      }),
    ).toBe(160);
  });
});

describe("prefabPreviewRequestKey", () => {
  const selectedPrefab = {
    kind: "prefab" as const,
    label: "sphere",
    prefabName: "builtin_sphere",
    rotation: EVoxelRotation.Rot0,
  };
  const selection = {
    occupiedMacro: { x: 1, y: 2, z: 3 },
    adjacentMacro: { x: 1, y: 3, z: 3 },
    faceNormal: { x: 0, y: 1, z: 0 },
    occupiedMicro: {
      macro: { x: 1, y: 2, z: 3 },
      micro: { x: 3, y: 7, z: 4 },
    },
  };

  it("stays stable for the same selected prefab, hit target, and world edit signature", () => {
    const first = prefabPreviewRequestKey(selectedPrefab, selection, {
      placed: 0,
      broken: 0,
      conflicts: 0,
    });

    const second = prefabPreviewRequestKey(
      { ...selectedPrefab },
      {
        ...selection,
        occupiedMacro: { ...selection.occupiedMacro },
        adjacentMacro: { ...selection.adjacentMacro },
        faceNormal: { ...selection.faceNormal },
        occupiedMicro: {
          macro: { ...selection.occupiedMicro.macro },
          micro: { ...selection.occupiedMicro.micro },
        },
      },
      { placed: 0, broken: 0, conflicts: 0 },
    );

    expect(second).toBe(first);
  });

  it("changes when the target micro slot or world edit signature changes", () => {
    const original = prefabPreviewRequestKey(selectedPrefab, selection, {
      placed: 0,
      broken: 0,
      conflicts: 0,
    });

    expect(
      prefabPreviewRequestKey(
        selectedPrefab,
        {
          ...selection,
          occupiedMicro: {
            ...selection.occupiedMicro,
            micro: { x: 4, y: 7, z: 4 },
          },
        },
        { placed: 0, broken: 0, conflicts: 0 },
      ),
    ).not.toBe(original);
    expect(
      prefabPreviewRequestKey(selectedPrefab, selection, {
        placed: 1,
        broken: 0,
        conflicts: 0,
      }),
    ).not.toBe(original);
  });

  it("does not create a preview key for material selections or empty ray selections", () => {
    expect(
      prefabPreviewRequestKey(
        { kind: "material", label: "stone", materialId: 2 },
        selection,
        { placed: 0, broken: 0, conflicts: 0 },
      ),
    ).toBeNull();
    expect(prefabPreviewRequestKey(selectedPrefab, null, { placed: 0, broken: 0, conflicts: 0 }))
      .toBeNull();
  });
});

describe("shouldRefreshPrefabPreview", () => {
  const base = {
    nowMs: 1000,
    requestKey: "sphere|slot-2",
    cachedKey: "sphere|slot-1",
    hasCachedPreview: true,
    lastRefreshMs: 960,
    selectedKey: "builtin_sphere:0",
    lastSelectedKey: "builtin_sphere:0",
    editSignature: "0:0:0",
    lastEditSignature: "0:0:0",
    refreshIntervalMs: 80,
  };

  it("defers pure raycast target churn while a cached prefab preview is fresh", () => {
    expect(shouldRefreshPrefabPreview(base)).toBe(false);
  });

  it("refreshes immediately without a cached preview, after the interval, or for exact key changes that matter", () => {
    expect(shouldRefreshPrefabPreview({ ...base, hasCachedPreview: false })).toBe(true);
    expect(shouldRefreshPrefabPreview({ ...base, nowMs: 1041 })).toBe(true);
    expect(
      shouldRefreshPrefabPreview({
        ...base,
        selectedKey: "builtin_cylinder:0",
      }),
    ).toBe(true);
    expect(
      shouldRefreshPrefabPreview({
        ...base,
        editSignature: "1:0:0",
      }),
    ).toBe(true);
  });

  it("does not refresh when the request key is unchanged", () => {
    expect(shouldRefreshPrefabPreview({ ...base, requestKey: base.cachedKey })).toBe(false);
  });
});

describe("shouldUseCoarsePrefabPreview", () => {
  it("uses coarse prefab preview only when camera interaction has no reusable precise preview", () => {
    const selectedPrefab = {
      kind: "prefab" as const,
      label: "sphere",
      prefabName: "builtin_sphere",
      rotation: EVoxelRotation.Rot0,
    };
    const selection = {
      occupiedMacro: { x: 1, y: 2, z: 3 },
      adjacentMacro: { x: 1, y: 3, z: 3 },
      faceNormal: { x: 0, y: 1, z: 0 },
    };

    expect(shouldUseCoarsePrefabPreview(selectedPrefab, selection, true, false)).toBe(true);
    expect(shouldUseCoarsePrefabPreview(selectedPrefab, selection, true, true)).toBe(false);
    expect(shouldUseCoarsePrefabPreview(selectedPrefab, selection, false, false)).toBe(false);
    expect(
      shouldUseCoarsePrefabPreview(
        { kind: "material", label: "stone", materialId: 2 },
        selection,
        true,
        false,
      ),
    ).toBe(false);
    expect(shouldUseCoarsePrefabPreview(selectedPrefab, null, true, false)).toBe(false);
  });
});
