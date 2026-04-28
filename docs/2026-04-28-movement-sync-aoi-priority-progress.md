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

- `mix format` was attempted, but failed before formatting due to an Erlang
  `:einval` while Mix inspected a git dependency under `deps/heroicons`.
- `npm run typecheck` was attempted before dependencies were present and failed
  because `tsc` was unavailable.
- `npm ci` was attempted to restore web dependencies; the first sandboxed run
  failed because npm cache-only mode lacked cached packages. A follow-up install
  was interrupted by the user, so web typecheck/tests were not completed in this
  checkpoint.

## Follow-Up

- Re-run Elixir formatting/tests after resolving the local Mix dependency git
  inspection issue.
- Re-run `npm ci`, `npm run typecheck`, and focused Vitest suites after the web
  dependency install is allowed to finish.
- Continue from this checkpoint by tightening server-side input governance and
  expanding end-to-end smoke coverage for AOI priority behavior over real
  WebSocket sessions.
