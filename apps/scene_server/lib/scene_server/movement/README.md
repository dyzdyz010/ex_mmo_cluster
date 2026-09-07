# Movement module map

M1 players use `SceneServer.Movement.Scene`, a single 60 Hz writer over the
P1 shared Rapier NIF. `InputSlots` owns the contiguous input prefix;
`CollisionUpdates` consumes W1's immutable transaction/marker FIFO. The
remaining movement modules below serve legacy actor tests and NPC callers.

## M1 production composition

`SceneServer.Application` starts `Scene` instead of `PlayerSup`. Gate owns
authentication and allocates `Session.Identity` once; `join/4` consumes the
authorized character's `id`, never its saved centimetre position. Gate's
old `Session.Scene.add_player/5` admission is retired by T1. NPC integration
and its existing Engine are unchanged.

The explicit application config is `Application.fetch_env!(:scene_server,
SceneServer.Movement.Scene)`, with `name`, `scene_id`, `scene_epoch`,
`world_ref` and `config_path`. `config_path` names D1's
`voxim-m1-demo-v1` JSON export. `Scene.load_config!/1` checks and constructs
the deployment values, deriving the native profile tuple through C1's
`encode_profile/1`. It supplies no profile or terrain defaults. The test
fixture is explicitly separate from the still-pending D1 asset export.

Public calls are `join/4` (queued `:ok`), `ready/4`, `input/3`, `leave/2`,
`time_probe/3`, and read-only `observe/1`. All arguments include an explicit
Scene reference. Outputs call `GateServer.Session.Sink.reliable/4`,
`datagram/3`, or `close/3`; Sink owns SessionEnd plus graceful transport
close. Canonical transactions retain W1's `%{seq, entries, coarse}` shape
and use C1 `Voxel.Codec.encode_transaction/1` plus the existing R6 tuple.

The first snapshot installs the world before the tick clock starts. Joins
admitted during source preparation reserve their slots but request their
markers only after that installation. Later snapshots never replace the
shared world: the FIFO consumes every earlier transaction, at most one
occupancy change per tick, then anchors a marker after that tick. Markers
stop the prefix even when following transactions do not change collision.
Joining characters continue zero-input physics. Ready confirms the exact
baseline N/R, TimeProbe enables clock readiness, and InputStart fixes
origin=A+30. Inputs may be queued after InputStart; consumption and the
public `active` state begin at origin. ACK and its preceding Voxel fence
are emitted every third tick for active characters.

Deadlines use integer microseconds times 60, with a ceiling when scheduling
the next millisecond timer; physics always calls P1's exact 1/60 step.
Input arrival never runs physics. TimeReply's fixed monotonic-to-server-time
mapping is independent of the tick clock's later bootstrap origin.
Query and spawn-cast endpoint bounds call P1's public query function;
out-of-domain candidates are not committed or clamped. World loss or
incomplete source closes sessions with reason 5 and disables stepping,
without automatic retries or retained incoming terrain history.

`observe/1` exposes tick, initialized/failure, canonical seq/revision,
queue length/wait, aggregate build/NIF/full-tick costs, maximum tick time,
mailbox peak, overdue debt, substitutions and immutable character states.
Logger debug event `voxim_scene_tick` records each character's exact
tick/state/input-seq/substitution and collision revision. The clock/source/
sink/native constructor seams allow isolated process tests; they do not
create a second production solver or scheduler.

Targeted tests: `mix test apps/scene_server/test/scene_server/movement/voxim_scene_test.exs`.
The existing umbrella test helper touches shared DB state, so the approved
isolated Linux command is `python Docs/M1/runtime/S1/run.py <fresh-label>`
from the sibling Voxim repository. It compiles current sources with private
BEAM paths, loads the existing P1/T1 native artifacts, and runs that exact
ExUnit file without application boot or DB access. The S1 report records
artifact provenance, commands, red/green results and acceptance limits.

AOI lifecycle/snapshot fan-out is A1's next Scene integration; E1 takes over
the existing `CollisionUpdates` path for online edit admission and UE
collision/render acceptance. Neither adds another player writer.

## Legacy and NPC responsibilities

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
- `Engine.build_ack_with_intent/5` is the preferred player hot-path ack builder
  when the input frame that produced the state is available. It preserves
  server correction intent such as collision push; `build_ack/4` remains the
  legacy snapshot-only path and intentionally emits zero correction flags.
- `Ack.auth_tick` is the client reconciliation timeline. `ack_seq` identifies
  the last accepted input command, but clients should anchor replay to
  `auth_tick` first and use `ack_seq` only as a fallback lookup.
- `RemoteSnapshot` is created from authoritative actor state. AOI workers may
  add observer-specific priority metadata before fan-out; movement actors do
  not own observer priority.

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
