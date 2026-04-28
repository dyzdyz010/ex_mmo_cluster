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
- Real WebSocket smoke coverage now asserts AOI priority metadata on the
  observed remote `player_move` frame. Verified with a temporary local Postgres
  container plus migrations:
  `MMO_DB_PORT=55432 node scripts/run_ws_dual_smoke_supervised.js`.
  The probe observed `priority=high:0.764:118.0:1` on B's remote movement frame.

## Follow-Up

- Continue from this checkpoint by tightening server-side input governance and
  expanding end-to-end smoke coverage for AOI priority behavior over real
  WebSocket sessions.
- Promote the temporary-Postgres smoke setup into a repeatable local command or
  CI fixture so the WebSocket AOI priority probe does not depend on a manually
  prepared database.
- Combat lag compensation / rewind remains intentionally out of scope for this
  checkpoint.
