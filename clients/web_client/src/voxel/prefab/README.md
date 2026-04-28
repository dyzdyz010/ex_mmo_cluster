# Prefab

Responsibilities:

- `types.ts` owns prefab data contracts shared by registry, renderer, CLI, and tests.
- `math.ts` owns micro-coordinate conversion, rotation, bit counting, and cache helpers.
- `boundary.ts` owns boundary signatures and face masks derived from prefab occupancy.
- `rasterize.ts` turns local prefab cells into world micro-cell writes and covered chunk records.
- `snapping.ts` owns boundary/socket snap preview search and rejection reasons.
- `definitions.ts` owns built-in/captured socket definitions and prefab bounds helpers.
- `runtime.ts` is a compatibility facade for existing internal imports while callers migrate to narrower modules.
- `../prefab.ts` remains the public facade. Callers should keep importing from `voxel/prefab` unless they are maintaining prefab internals.

Boundaries:

- `LocalPrefabRegistry` owns prefab registration and instance id allocation.
- `WorldStore` remains the truth owner for placed refined micro cells and prefab instance records.
- Render and DevTools code may inspect `PrefabRasterCell` and preview snapshots, but must not mutate prefab registry internals.
