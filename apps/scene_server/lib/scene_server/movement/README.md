# Movement module map

This directory holds the shared movement model used by both player and NPC
actors.

## Responsibilities

- `Profile` - shared movement tuning parameters
- `InputFrame` - one sanitized fixed-step input sample
- `State` - authoritative movement state at a tick
- `Ack` - controlling-client reconciliation payload
- `RemoteSnapshot` - AOI broadcast payload for remote observers
- `Engine` - stable Elixir API over the Rustler movement math
- `VoxelCollision` - stateless read-only adapter from movement AABBs to
  authoritative voxel occupancy queries
- `Integrator` - readable Elixir reference implementation for tests/docs

## Authority / reconciliation contract

- `PlayerCharacter` owns the authoritative player movement state. Gate
  connections only forward sanitized input frames and encoded acks.
- `VoxelCollision` does not own actor or voxel state. It converts the
  `PlayerCharacter` center-anchor movement state into voxel samples and asks
  `ChunkDirectory` / `ChunkProcess` for read-only occupancy truth. Ground
  contact is half-open: a center at `terrain_top + avatar_half_height` is clear,
  while descending into the terrain resolves back to that center height.
- `ChunkProcess` remains the only owner of hot voxel storage. Movement receives
  occupied samples and returns corrected movement state plus
  `CorrectionFlags.collision_push/0` when terrain blocks replay.
- Queued player input replay resolves collision after each server replayed
  fixed step. The corrected state from one step feeds the next step, so bursty
  input delivery cannot turn several fixed steps into one long collision sweep.
- `Engine.build_ack_with_intent/5` is the preferred player hot-path ack builder
  when the input frame that produced the state is available. It preserves
  server correction intent such as collision push; `build_ack/4` remains the
  legacy snapshot-only path and intentionally emits zero correction flags.
- `Ack.auth_tick` is the client reconciliation timeline. `ack_seq` identifies
  the last accepted input command, but clients should anchor replay to
  `auth_tick` first and use `ack_seq` only as a fallback lookup.
- `State.tick` is server-owned. `client_tick` is accepted only as input
  metadata and ordering guard; `PlayerCharacter` renumbers both single-frame
  and queued replay inputs before calling `Engine`, so spoofed client ticks do
  not enter authoritative state.
- `RemoteSnapshot` is created from authoritative actor state. AOI workers may
  add observer-specific priority metadata before fan-out; movement actors do
  not own observer priority.

## Time-base contract

- `server_tick` / `auth_tick` are authoritative sequence numbers, not wall-clock
  time. They remain the ordering and reconciliation keys.
- Scene stamps `server_state_ms` on authoritative movement state from the
  server-owned tick and fixed dt. Gate senders attach `server_send_ms` at the
  TCP/UDP/WS send site for `PlayerMove` and `MovementAck`. The web client sends
  periodic TimeSync requests, then uses `server_state_ms + serverClockOffsetMs`
  to drive remote interpolation. `server_send_ms` is kept for transport latency
  / queue diagnostics only. If a local test or offline transport has no
  state-time anchor, or if adjacent `server_state_ms` deltas no longer match the
  authoritative tick deltas, remote interpolation falls back to the
  tick-duration timeline and marks `serverStateTimelineHealthy=false` in debug
  snapshots.
- The visible local authority-render marker follows the latest-ack projection,
  not the local visual correction smoothing path. Raw ack position remains a
  separate CLI/trace diagnostic. Latest-ack projection uses `server_state_ms`
  on the synced server clock when TimeSync is available, and falls back to a
  short arrival-time projection of roughly two `fixed_dt_ms` steps before
  TimeSync is ready.
- Remote interpolation and local authority-render diagnostics expose the active
  time axis and last playback server time so CLI/devtools snapshots can show
  whether rendering is using `server_state_ms` or an explicit tick path.

## Jump / airborne contract

- `InputFrame.movement_flags` uses `0x0004` as a one-shot jump request.
- Only `:grounded` actors can consume that request and enter `:airborne`.
- `State.ground_z` is owned by the movement state so an airborne arc can land
  back on the ground height it launched from, independent of current Z.
- `Profile` owns airborne tuning: `jump_impulse`, `gravity`, `air_control`,
  `air_accel`, and `max_fall_speed`. The default `jump_impulse=900` gives an
  apex of roughly 4.1m under `gravity=980`, so players can escape multi-block
  voxel traps while collision testing.

## Relationship to actors

- `SceneServer.PlayerCharacter` consumes network input and steps movement here
- `SceneServer.Npc.Actor` builds its own input via `Npc.Navigation` and steps
  movement here

This shared layer is what keeps player and NPC motion on the same authority
rules.
