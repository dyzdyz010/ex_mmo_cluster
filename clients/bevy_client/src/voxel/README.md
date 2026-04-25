# Bevy voxel client module

`voxel/` owns the Bevy client's offline-local voxel world. It mirrors the web
client's local runtime boundary: macro cells and refined micro occupancy are
client truth, prefab placement is local, and later server authority must enter
through an adapter instead of writing render state directly.

## Layout

```
voxel/
├── core/         pure primitives (no Bevy)
│   ├── coord.rs      MacroCoord / MicroCoord / Rotation, parse + format,
│   │                 micro index helpers, MICRO_PER_MACRO constants
│   ├── mask.rs       512-bit MicroMask + bitset operations
│   └── material.rs   VoxelMaterialId (+ defaults / labels)
├── prefab/       prefab geometry layer (no Bevy)
│   ├── definition.rs PrefabDefinitionData / Cell / Part / Raster / CellData
│   ├── registry.rs   LocalPrefab + LocalPrefabRegistry (built-ins + capture)
│   ├── boundary.rs   BoundarySnapRequest / Preview / PlaceResult, contact
│   │                 helpers, prefab_cell_from_mask
│   ├── builtins.rs   sphere / cylinder / stairs micro masks
│   └── rotation.rs   rotate_macro_offset / rotate_prefab_cell
├── world/        runtime truth (Bevy Resource)
│   ├── store.rs      VoxelWorld + NormalBlockData + RefinedCellData +
│   │                 PrefabInstanceData + EditStats + VoxelRenderCell +
│   │                 PrefabPlaceResult
│   ├── snapshot.rs   WorldSnapshot + SnapshotCell
│   └── hotbar.rs     HotbarEntry / HotbarEntryKind / HotbarState
├── cli.rs        VoxelCliCommand / VoxelCliResult parse + execute
└── mod.rs        re-export shell so callers keep using bevy_client::voxel::T
```

## Boundary

- `core::*` is pure: only depends on std + serde + glam-via-Bevy types if
  any. It must not import Bevy or world types.
- `prefab::*` depends on `core::*` only.
- `world::*` depends on `core::*` and `prefab::*`. `VoxelWorld` is the only
  `bevy::Resource` in this directory.
- `cli` depends on all of the above through `VoxelWorld`.
- The Bevy plugin layer lands in `voxel::plugin` (Phase 4) and will own
  systems, scheduling, and event flow. Render and stdio layers consume
  public methods on `VoxelWorld`; they do not own voxel storage.

## Conventions

- Microgrid writes are internal validation/storage capabilities. Public
  player commands expose macro placement, prefab placement, and read-only
  `micro_cell` inspection, matching the browser client boundary.
- `MICRO_PER_MACRO = 8`, `MICRO_GRID_SLOT_COUNT = 512`.
- Built-in occupied slot counts (`builtin_sphere=280`, `builtin_cylinder=416`,
  `builtin_stairs` not protocol-fixed) are locked by
  `tests/voxel_parity.rs::builtin_prefabs_match_web_resolution_and_smoke_counts`.
