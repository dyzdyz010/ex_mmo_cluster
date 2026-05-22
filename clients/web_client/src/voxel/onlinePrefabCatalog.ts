// Server-authoritative prefab catalog for the online voxel adapter.
//
// Phase A1-1: server-side BlueprintCatalog 升级到 v2 micro mask 表示,跟
// 客户端 prefab/definitions.ts 的几何函数(球/圆柱/阶梯)对齐。每个 prefab
// 占用单 macro 内的若干 micro slots (0..511);wire 上携带 blueprint_id
// + blueprint_version + anchor_world_micro + rotation,服务端按同一套 quarter-turn
// yaw 语义展开成 micro `:put_micro_block` intents。
//
// IMPORTANT:
// - Names that are NOT in this catalog must NOT be sent over the wire.
//   Callers should treat `resolveBlueprint` returning `null` as a hard
//   reject and surface a `world:voxel-sync-error` event with reason
//   `unknown_blueprint:<name>`.
// - `expectedCellCount` 是 micro slot 数(不再是 macro cell 数),只用于 UI
//   层的 optimistic `placed` 返回值,真实状态走 ChunkDelta。

const BLUEPRINT_VERSION = 2;

export interface OnlinePrefabBlueprint {
  readonly id: number;
  readonly version: number;
  /**
   * Phase A1-1 起改为 micro slot 数(单 macro 内 0..512)。仅用于 UI 层
   * 在 dispatch intent 后立即 echo 一个 placed 计数。authoritative state
   * 仍由 ChunkDelta 推送。
   */
  readonly expectedCellCount: number;
}

// 跟服务端 BlueprintCatalog 对齐:
// id 1 = sphere       (Ice = 4),~248 micro slots
// id 2 = cylinder     (Stone = 2),~336 micro slots
// id 3 = stairs       (Wood = 3),288 micro slots(y ≤ x rule × 8 z)
// id 4 = conductor X  (Iron = 5),2×2 wire spanning x
// id 5 = conductor XZ (Iron = 5),cross-junction spanning x/z
// id 6 = power X      (PowerBlock = 6),conductive power terminal spanning x
// id 7 = load X       (LoadBlock = 7),conductive load terminal spanning x
const ONLINE_PREFAB_CATALOG: Readonly<Record<string, OnlinePrefabBlueprint>> = {
  builtin_sphere: { id: 1, version: BLUEPRINT_VERSION, expectedCellCount: 248 },
  builtin_cylinder: { id: 2, version: BLUEPRINT_VERSION, expectedCellCount: 336 },
  builtin_stairs: { id: 3, version: BLUEPRINT_VERSION, expectedCellCount: 288 },
  builtin_conductor_wire_x: { id: 4, version: BLUEPRINT_VERSION, expectedCellCount: 32 },
  builtin_conductor_junction_xz: { id: 5, version: BLUEPRINT_VERSION, expectedCellCount: 56 },
  builtin_power_terminal_x: { id: 6, version: BLUEPRINT_VERSION, expectedCellCount: 32 },
  builtin_load_terminal_x: { id: 7, version: BLUEPRINT_VERSION, expectedCellCount: 32 },
};

export function resolveBlueprint(name: string): OnlinePrefabBlueprint | null {
  return ONLINE_PREFAB_CATALOG[name] ?? null;
}

export function listOnlinePrefabNames(): readonly string[] {
  return Object.keys(ONLINE_PREFAB_CATALOG);
}

export const OnlinePrefabBlueprintVersion = BLUEPRINT_VERSION;
