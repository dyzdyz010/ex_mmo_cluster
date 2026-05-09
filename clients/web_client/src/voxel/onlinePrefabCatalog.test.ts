import { describe, expect, it } from "vitest";
import {
  OnlinePrefabBlueprintVersion,
  listOnlinePrefabNames,
  resolveBlueprint,
} from "./onlinePrefabCatalog";

describe("onlinePrefabCatalog", () => {
  it("resolves the three v2 builtin blueprints to their server-side ids", () => {
    expect(resolveBlueprint("builtin_sphere")).toEqual({
      id: 1,
      version: OnlinePrefabBlueprintVersion,
      expectedCellCount: 248,
    });
    expect(resolveBlueprint("builtin_cylinder")).toEqual({
      id: 2,
      version: OnlinePrefabBlueprintVersion,
      expectedCellCount: 336,
    });
    expect(resolveBlueprint("builtin_stairs")).toEqual({
      id: 3,
      version: OnlinePrefabBlueprintVersion,
      expectedCellCount: 288,
    });
  });

  it("returns null for any name not in the v2 catalog", () => {
    expect(resolveBlueprint("builtin_pillar_3")).toBeNull();
    expect(resolveBlueprint("")).toBeNull();
    expect(resolveBlueprint("totally_unknown_prefab")).toBeNull();
  });

  it("exposes the full v2 name list in a stable order for callers/UI", () => {
    expect(listOnlinePrefabNames()).toEqual([
      "builtin_sphere",
      "builtin_cylinder",
      "builtin_stairs",
    ]);
  });

  it("exposes blueprint version 2 (Phase A1-1 micro-mask wire)", () => {
    expect(OnlinePrefabBlueprintVersion).toBe(2);
  });
});
