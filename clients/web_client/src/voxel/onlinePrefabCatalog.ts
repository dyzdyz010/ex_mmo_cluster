// Server-authoritative prefab catalog for the online voxel adapter.
//
// The bevy/Elixir server owns the canonical prefab blueprint table. In v1
// the server registers a small fixed set of builtins under stable IDs;
// this map mirrors that table on the client so `placePrefab(name, ...)`
// can be translated into a wire-level `0x67 PrefabPlaceIntent` carrying
// the matching `blueprint_id` / `blueprint_version` pair.
//
// IMPORTANT:
// - Names that are NOT in this catalog must NOT be sent over the wire.
//   Callers should treat `resolveBlueprint` returning `null` as a hard
//   reject and surface a `world:voxel-sync-error` event with reason
//   `unknown_blueprint:<name>`.
// - Cell counts here describe how many macro cells the server is
//   expected to materialize for each blueprint, used purely for the
//   adapter's optimistic `placed` return value. Actual cell state is
//   delivered to the client via incoming ChunkDeltas; the client never
//   optimistically applies prefab cells locally in server-authoritative
//   mode.
// - Blueprint version is currently a single shared constant. Bumping it
//   requires coordination with the server-side blueprint registry; the
//   wire format treats this as an opaque u32.

const BLUEPRINT_VERSION = 1;

export interface OnlinePrefabBlueprint {
  readonly id: number;
  readonly version: number;
  /**
   * Number of macro cells the blueprint is expected to occupy. Used to
   * report a non-zero `placed` count back to the UI layer immediately
   * after dispatching the intent. The authoritative state still flows
   * through ChunkDeltas.
   */
  readonly expectedCellCount: number;
}

const ONLINE_PREFAB_CATALOG: Readonly<Record<string, OnlinePrefabBlueprint>> = {
  // 3 vertical blocks stacked on Z.
  builtin_pillar_3: { id: 1, version: BLUEPRINT_VERSION, expectedCellCount: 3 },
  // 3x3 floor laid out at z=0.
  builtin_floor_3x3: { id: 2, version: BLUEPRINT_VERSION, expectedCellCount: 9 },
  // 2x2x2 solid cube.
  builtin_cube_2x2x2: { id: 3, version: BLUEPRINT_VERSION, expectedCellCount: 8 },
};

export function resolveBlueprint(name: string): OnlinePrefabBlueprint | null {
  return ONLINE_PREFAB_CATALOG[name] ?? null;
}

export function listOnlinePrefabNames(): readonly string[] {
  return Object.keys(ONLINE_PREFAB_CATALOG);
}

export const OnlinePrefabBlueprintVersion = BLUEPRINT_VERSION;
