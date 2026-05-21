import { describe, expect, it } from "vitest";
import {
  OnlinePrefabBlueprintVersion,
  listOnlinePrefabNames,
  resolveBlueprint,
} from "./onlinePrefabCatalog";

describe("onlinePrefabCatalog", () => {
  it("resolves the v2 builtin blueprints to their server-side ids", () => {
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
    expect(resolveBlueprint("builtin_conductor_wire_x")).toEqual({
      id: 4,
      version: OnlinePrefabBlueprintVersion,
      expectedCellCount: 32,
    });
    expect(resolveBlueprint("builtin_conductor_junction_xz")).toEqual({
      id: 5,
      version: OnlinePrefabBlueprintVersion,
      expectedCellCount: 56,
    });
    expect(resolveBlueprint("builtin_power_terminal_x")).toEqual({
      id: 6,
      version: OnlinePrefabBlueprintVersion,
      expectedCellCount: 32,
    });
    expect(resolveBlueprint("builtin_load_terminal_x")).toEqual({
      id: 7,
      version: OnlinePrefabBlueprintVersion,
      expectedCellCount: 32,
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
      "builtin_conductor_wire_x",
      "builtin_conductor_junction_xz",
      "builtin_power_terminal_x",
      "builtin_load_terminal_x",
    ]);
  });

  it("exposes blueprint version 2 (Phase A1-1 micro-mask wire)", () => {
    expect(OnlinePrefabBlueprintVersion).toBe(2);
  });
});
