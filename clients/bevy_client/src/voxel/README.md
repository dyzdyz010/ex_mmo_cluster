# Bevy voxel client module

`voxel/` owns the Bevy client's offline-local voxel world. It mirrors the web
client's local runtime boundary: macro cells and refined micro occupancy are
client truth, prefab placement is local, and later server authority must enter
through an adapter instead of writing render state directly.

## Responsibilities

- `VoxelWorld` owns local world truth, edit stats, hotbar state, prefab
  registry, and snapshot import/export.
- `LocalPrefabRegistry` owns built-in and captured prefab definitions.
- Render and stdio layers consume public methods on `VoxelWorld`; they do not
  own voxel storage.
- Microgrid writes are internal validation/storage capabilities. Public player
  commands expose macro placement, prefab placement, and read-only
  `micro_cell` inspection, matching the browser client boundary.
