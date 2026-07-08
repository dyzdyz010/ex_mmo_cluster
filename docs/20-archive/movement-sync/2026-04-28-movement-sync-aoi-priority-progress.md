# 2026-04-28 Movement Sync AOI Priority Progress

## Scope

This checkpoint records the current movement-sync implementation pass for:

- server-authoritative movement snapshot fan-out
- local-player client prediction / server reconciliation observability
- remote-entity snapshot interpolation observability
- AOI priority synchronization

Combat lag-compensation / rewind is intentionally not implemented in this
checkpoint.

## Implemented

- Added `SceneServer.Aoi.Priority` as a pure AOI policy module. It classifies
  observer targets into `:high`, `:medium`, and `:low` priority bands, assigns
  delivery intervals, and decorates remote movement snapshots with per-observer
  priority metadata.
- Extended `SceneServer.AoiManager` with cached AOI locations and entry lookup
  so `AoiItem` can build priority targets without owning global index state.
- Reworked `SceneServer.Aoi.AoiItem` fan-out to store priority targets instead
  of raw subscriber PIDs, throttle movement snapshots by priority, always send
  stop snapshots, and emit structured AOI refresh / priority snapshot observe
  events.
- Extended `SceneServer.Movement.RemoteSnapshot` with optional AOI priority
  fields: `priority_band`, `priority_score`, `observer_distance`, and
  `delivery_interval`.
- Extended gate `player_move` encoding with an optional priority metadata
  suffix while preserving the existing bare snapshot layout.
- Updated TCP and WebSocket gate downlinks to forward decorated priority
  snapshots and expose priority metadata in observe logs.
- Extended the web client movement domain and gate protocol decoder with
  optional AOI priority metadata.
- Added per-CID remote interpolation diagnostics in the web client, including
  buffer length, latest server tick, interpolation/extrapolation mode, and AOI
  priority fields.
- Added web CLI commands / data surfaces: `aoi`, `remote <cid>`, and
  `sync_stats`; expanded `players`, `snapshot`, diagnostics logs, and movement
  observe events with AOI / sync fields.
- Added focused tests for AOI priority policy, AOI priority fan-out,
  priority-extended gate protocol encoding/decoding, and remote-client
  diagnostics.

## Verification Status

- `cmd /c mix format --check-formatted` passes after formatting the gate codec
  and TCP / WebSocket downlink files.
- `npm run typecheck` passes in `clients/web_client`.
- Focused server regression coverage passes:
  `cmd /c mix test apps/gate_server/test/gate_server/codec_test.exs
  apps/scene_server/test/scene_server/aoi/priority_test.exs
  apps/scene_server/test/aoi_item_test.exs`.
- Focused web regression coverage passes:
  `npm test -- src/infrastructure/net/gateProtocol.test.ts
  src/app/controllers/remotePlayerController.test.ts
  src/domain/movement/remotePlayer.test.ts`.
- Full web regression / build coverage passes:
  `npm test` and `npm run build` from `clients/web_client`.
- Full umbrella regression coverage passes with a temporary local Postgres
  container exposed through `MMO_DB_PORT=55432`: `cmd /c mix test`.
- Real WebSocket smoke coverage is now a repeatable supervised runner:
  `node scripts/run_ws_dual_smoke_supervised.js`. The runner starts the full
  `MIX_ENV=dev` runtime on free local ports, creates/migrates the configured
  Postgres database, seeds `ws_smoke_a` / `ws_smoke_b`, runs a two-client
  WebSocket probe, writes logs and JSON summary under `.demo/observe/`, then
  cleans up the booted BEAM process tree.
- Latest local supervised probe observed B receiving A's movement stream with
  AOI priority metadata and jump sync: remote ticks advanced, priority samples
  included `high:1.000:0.0:1`, remote airborne samples were observed, and
  remote Z rose from `100` to `170`.
- CI now includes `smoke-ws-dual`, a dedicated Postgres-backed job that runs
  the same supervised WebSocket smoke command.

## Follow-Up

- Continue from this checkpoint by tightening server-side input governance and
  expanding end-to-end smoke coverage for rejection / correction behavior over
  real WebSocket sessions.
- Combat lag compensation / rewind remains intentionally out of scope for this
  checkpoint.
