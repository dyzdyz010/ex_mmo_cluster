import { describe, expect, it } from "vitest";
import {
  OnlinePrefabBlueprintVersion,
  listOnlinePrefabNames,
  resolveBlueprint,
} from "./onlinePrefabCatalog";

describe("onlinePrefabCatalog", () => {
  it("resolves the three v1 builtin blueprints to their server-side ids", () => {
    expect(resolveBlueprint("builtin_pillar_3")).toEqual({
      id: 1,
      version: OnlinePrefabBlueprintVersion,
      expectedCellCount: 3,
    });
    expect(resolveBlueprint("builtin_floor_3x3")).toEqual({
      id: 2,
      version: OnlinePrefabBlueprintVersion,
      expectedCellCount: 9,
    });
    expect(resolveBlueprint("builtin_cube_2x2x2")).toEqual({
      id: 3,
      version: OnlinePrefabBlueprintVersion,
      expectedCellCount: 8,
    });
  });

  it("returns null for any name not in the v1 catalog", () => {
    expect(resolveBlueprint("builtin_sphere")).toBeNull();
    expect(resolveBlueprint("")).toBeNull();
    expect(resolveBlueprint("totally_unknown_prefab")).toBeNull();
  });

  it("exposes the full v1 name list in a stable order for callers/UI", () => {
    expect(listOnlinePrefabNames()).toEqual([
      "builtin_pillar_3",
      "builtin_floor_3x3",
      "builtin_cube_2x2x2",
    ]);
  });
});
