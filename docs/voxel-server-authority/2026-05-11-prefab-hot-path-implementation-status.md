# Prefab Hot Path Implementation Status - 2026-05-11

## Implemented

- Gate now has a single-chunk prefab fast path for WebSocket and TCP:
  after MapLedger routing, if the rasterized prefab touches one chunk under one
  lease, Gate calls `SceneServer.Voxel.ChunkDirectory.apply_intents/2` directly.
- Gate bulk-routes prefab chunks through World `MapLedger` in one call for
  WebSocket and TCP.
- Multi-chunk prefab plans that still resolve to one concrete
  `{ChunkDirectory, scene_node}` now use a Scene-local prepare/commit/abort
  runner instead of the full World coordinator path.
- Split-owner prefab plans use the World `TransactionCoordinator` /
  `TransactionExecutor` path, but participants are now grouped by concrete
  Scene owner `{ChunkDirectory, scene_node}` instead of by lease. `chunk_owners`
  preserves the exact `{region_id, lease_id}` for every touched chunk.
- Gate rejects prefab/edit routing when World returns an assignment without
  `assigned_scene_node`; the owner-ref compatibility path was removed.
- World rejects `MapLedger.put_region/2` when neither a SceneNodeRegistry
  assignment nor an explicit `assigned_scene_node` is available. `MapLedger` no
  longer exposes a region-to-scene lookup API for recovery to infer routing.
- `TransactionParticipant` now requires `participant_key`,
  `assigned_scene_node`, and complete `chunk_owners`. Coordinator owner
  selection and executor object-registration fan-out hard-fail on missing chunk
  owners instead of falling back to `{region_id, lease_id}`.
- Recovery resume requires scene opts for every participant. Partial resolver
  results now keep the transaction parked instead of entering a half-resume.
- Commit-time object registration dispatches by `participant_key` and inflates
  `covered_chunks_by_region` from `chunk_owners`, so Scene-owner grouped
  participants still register objects with correct lease ownership metadata.
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
- `mix run --no-start <strict scene-owner smoke>`
- `npm run typecheck`
- `npm test`
- `npm run build`

## Remaining Work

- No known implementation tail remains in the prefab route/participant contract.
- Local startup was hardened after validation found two Windows-specific Erlang
  startup hazards: default EPMD port `4369` can be inside an excluded TCP port
  range, and long node names can trigger noisy `hosts` parsing when the Windows
  hosts file starts with a UTF-8 BOM. The server scripts now default to
  `ERL_EPMD_PORT=43690` and short node names.
- The next useful check is an end-to-end user smoke from a fresh shell:
  start `scripts/start-server.ps1`, start the web client, place single-chunk and
  boundary-snapped prefabs through the browser, and verify the CLI observe
  snapshot reports intent result, delta receipt, chunk version advance, and no
  server warning spam.
