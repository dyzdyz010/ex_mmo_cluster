# Prefab Hot Path Implementation Status - 2026-05-11

## Implemented

- Gate now has a single-chunk prefab fast path for WebSocket and TCP:
  after MapLedger routing, if the rasterized prefab touches one chunk under one
  lease, Gate calls `SceneServer.Voxel.ChunkDirectory.apply_intents/2` directly.
- Multi-chunk, multi-lease, and cross-Scene-owner prefab plans still use the
  World `TransactionCoordinator` / `TransactionExecutor` path.
- Scene `ChunkProcess.apply_intents/2` keeps all-or-reject prefab semantics with
  `reject_occupied: true`, but applies micro writes grouped by macro cell.
  Boundary-snapped prefabs that touch several macro cells inside one chunk no
  longer fall back to per-micro-slot storage normalization.
- Prefab hot-path replies skip full snapshot payload generation with
  `return_snapshot_payload: false`; full snapshot persistence is queued in a
  background task after synchronous write-token validation.
- Chunk subscribers receive `ChunkDelta` on committed edits while full snapshots
  remain available for initial subscribe and recovery.
- Web chunk mesh rebuild work is offloaded to a module worker so delta-driven
  rebuilds do not block the main render thread.
- Client voxel debug snapshots expose enough CLI state to verify prefab intent
  send, intent result receipt, delta receipt, and render rebuild without relying
  on screenshots.

## Verified

- CLI/server smoke: single-macro sphere prefab placement is about 10-11ms.
- Browser right-click boundary-snap sphere:
  - before macro grouping: `ws_voxel_prefab_single_chunk_fast_path_applied`
    reported `elapsed_ms: 1379`.
  - after macro grouping: the same right-click path reported `elapsed_ms: 38`.
  - Browser CLI observed voxel message count increment, intent result receipt,
    delta receipt, and chunk version `1 -> 2`.
- Occupancy reject still returns `:micro_slot_already_occupied` and leaves the
  persisted chunk version unchanged.

## Validation Commands

- `mix test apps/gate_server/test/gate_server/ws_connection_voxel_test.exs`
- `mix test apps/scene_server/test/scene_server/voxel/chunk_process_test.exs apps/scene_server/test/scene_server/voxel/chunk_process_persistence_test.exs apps/gate_server/test/gate_server/ws_connection_voxel_cross_region_test.exs`
- `MIX_ENV=test mix precommit`
- `npm run typecheck`
- `npm test`
- `npm run build`

## Remaining Work

- True cross-Scene-server prefab placement still goes through the World
  transaction path. It benefits from the Scene-side batching, delta fan-out,
  async persistence, and worker mesh rebuild changes, but it is not expected to
  match the 38ms single-chunk fast path yet.
- A separate multi-participant transaction optimization pass is needed if
  cross-Scene prefab placement must become equally low-latency.
