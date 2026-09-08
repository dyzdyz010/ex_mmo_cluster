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

## M1 ordinary runtime rows (I-S)

Scene emits `Logger.info` messages containing one JSON object with
`schema="voxim-scene-v1"`. Keep info logging enabled when collecting evidence;
normal Logger prefixes/other application messages are outside the JSON object.
The existing debug logs remain available. No new logger backend, switch,
telemetry process, sampling loop or scheduler is introduced.

Every row has `event`, `node`, `process`, `scene_id`, `scene_epoch`,
`server_tick`, `transaction_seq`, `collision_revision`, `monotonic_us`, and
`time_domain="scene_clock_monotonic_us"`. Character rows add `session_epoch`,
`entity_id`, `entity_epoch`. The deployment manifest binds node/process and
epochs to a VM/run lifetime; a PID alone is not a durable identity. Parse u64
identifiers exactly, without floating-point rounding. Timestamps may be negative.

- `bootstrap_resident`: `content_version`, `prepare_start_us`,
  `snapshot_received_us`, `installed_us`, `build_us`, `region_count`,
  `core_count`, `region_payload_bytes`, `occupancy_bytes`. The interval starts
  at the existing Scene init clock sample after config parsing, before world
  resource creation/source request, and ends after initial collider installation.
  It includes source preparation and Scene mailbox residence; it is not an
  isolated World preparation timer. Byte counts are exact received artifacts,
  not complete canonical/BEAM/native resident memory or compound count.
- `session_start`, `input_start`, `session_end`: complete admitted character
  identities and content version at the actual anchor/origin/drop branch.
  InputStart adds `origin_tick`; SessionEnd adds the existing numeric `reason`.
  The common tick/N/R are the actual step-after anchor or current drop state.
- `input_arrival`: one row per submitted frame, all stamped at the same Scene
  cast handler entry. Fields are `input_seq`, `due_tick`, quantized `axis_x`,
  `axis_z`, `yaw`, `jump_pressed`, `disposition`. Due tick is origin+seq-1;
  it is null before InputStart. InputSlots returns the actual existing branch
  metadata: resolved frames are `late`; live frames are `accepted`, `future`
  or `conflict`. Identical pending redundancy remains `accepted` (first wins),
  so accepted rows are not execution counts. Scene's existing missing-character
  and pre-InputStart branches report `unknown_identity` (entity fields null)
  and `not_started`. The unmatched API/batch identity clause retains its prior
  stale counter; it supplies no decoded-frame row. This is Scene handling time,
  not Gate/NIC receipt, and does not measure the preceding mailbox residence.
- `input_selected`: one row for each character about to enter the actual P1
  batch. `selection` is `received`, `inherited_axes`, `zero_after_six_missing`
  from the actual InputSlots branch, or `joining_zero` before activation.
  It includes quantized axes/yaw/jump, seq/due tick (null for joining), and
  `native_axis_x/z` exactly as passed to P1. Missing jump is always zero.
  Selection proves the submitted impulse, not a successful grounded jump;
  correlate with a completed region tick. It precedes the synchronous NIF call.
- `region_tick`: `due_us`, `start_us`, `end_us`, `overdue_ticks`, `tick_us`,
  `nif_us`, `build_us`, `stepped_count`, `mailbox_at_start`, `queue_before`,
  `queue_after`, `queue_oldest_age_us`, and
  `elapsed_time_domain="beam_monotonic_elapsed_us"`. Each cost is that call's
  existing timer value/delta, suitable for downstream distribution analysis.
  Overdue is the tick debt observed at handler entry, not the historic maximum.
  Queue age samples the oldest artifact at tick start, null when empty, and
  starts at Scene enqueue; it is not per-transaction wait, World commit latency
  or prior mailbox residence. Queue lengths cover the collision FIFO, while
  mailbox counts cover all Scene messages at the observation point.

`tick_us` brackets the existing `tick/1`: collision consume/build, log/control
fanout, input selection and its logging, NIF, result commit, joins and AOI.
`nif_us` brackets the complete synchronous `step_characters` wrapper call,
including DirtyCpu scheduling/encoding/return; it is not kernel CPU time.
`build_us` is the existing set_chunks elapsed delta (zero without an install).
Full tick includes spawn/query calls not included in step NIF time. Handler
bookkeeping, the region summary JSON encoding/Logger submission and subsequent
scheduling lie outside `tick_us`; start/end also exclude that final summary.
Logger destination I/O/backpressure and instrumentation overhead are not
independently measured. Arrival rows add at most six JSON submissions per
ordinary C1 batch, selection at most one per stepped character, and the region
summary one per Scene tick. No occupancy serialization or logging state is
added. Oldest age reads the queue head; the two queue length observations use
`:queue.len/1`, which traverses the queue lists. These lengths are evaluated
for the summary outside `tick_us`; their cost grows with queued artifacts.

Production Clock uses BEAM monotonic microseconds, while a test-injected clock
can be static during real work. Timer deltas always use BEAM elapsed time.
Never subtract these stamps directly from UE, another host or another VM's
clock; use the existing TimeProbe/TimeReply calibration and its uncertainty.
No cumulative average/max is represented as p95/p99 and these rows alone do
not constitute sustained performance, network, visible-frame or D1 acceptance.

`bootstrap_resident` also reads `native_colliders`, `native_compounds` and
`native_compound_children` through the owning native API after installation.
These count resident Rapier colliders, compound shapes and their child shapes;
they do not infer counts from occupancy or run greedy again. All-air chunks have
no native collider. Native allocator memory is not measured; occupancy and region
payload bytes retain their separate meanings. Shared native source changes require
publishing its generated kernel identity and rebuilding both DLL and NIF.

Focused verification from Voxim:
`python Docs/M1/runtime/I-S/run.py <fresh-label>` compiles copied source from
server pin `411eaae184de7f7e5bca8f3b9be1ef8106475c0b` plus the owned Scene,
InputSlots and instrumentation test into a private Linux cache, loading existing
P1/worldgen binaries. Two ordinary tests capture real World/FileStore/Scene/P1
and production Sink process messages under manual and actual Scene clocks.
`Docs/M1/reports/I-S.md` records the missing-row red, green, exact unchanged
normal behavior comparison, raw JSON messages, provenance and limitations.
No full application, Gate process, DB, network or native build is started.

## M1 AOI lifecycle (A1-S)

`AOI` is an immutable relation value owned only by Scene. Its `update/4`
receives origin-active, step-after `{identity, entity_id, entity_epoch,
state}` values, Scene tick and collision revision. It returns the new AOI,
C1 lifecycle messages and C1 `Movement.Snapshot` messages; it owns no actor,
clock, solver, connection or terrain. This implements the frozen
`Voxim/Docs/M1/plan.md` sections 2.1/2.4 using S1's existing writer and C1
types, without extending the wire contract.

On every third Scene tick (20 Hz), 32 m XYZ cells supply enter candidates.
Exact canonical 3D distance admits at <=30 m; existing relations retain
through 34 m even across two cells, and leave at >34 m. Only origin-active
characters observe or appear, and self never appears. Scene sends all
reliable Enter/Leave messages through Sink's `:control` purpose before
that tick's absolute snapshots. Stopped characters still receive/publish
20 Hz snapshots, including empty record lists when alone. Records are
sorted by entity ID and carry the same step-after state/revision as Scene.

Generation allocation is local to each observer identity: a scalar
counter increments for each new visible relation. A relation keeps its
generation until Leave; a return has a larger generation with the same
entity epoch. This needs no per-departed-entity tombstone cache. S1 still
allocates a new entity epoch on reconnect. Scene's existing `drop` path
immediately removes the departing observer and its visible edges, sending
matching Leave to remaining observers, including on Gate DOWN and source
failure. A stale identity cannot remove the new character.

`Scene.observe/1` includes each character's `entity_epoch` and `aoi` rows
with `identity`, `last_generation`, and sorted `visible` records containing
entity ID/epoch/generation. Debug `voxim_aoi_lifecycle` logs the typed
message. `AOI.observe/1` exposes immutable values only.

The bounded command from Voxim is
`python Docs/M1/runtime/A1-S/run.py <fresh-label>`. Six tests exercise pure
XYZ/hysteresis/generation algebra and real Scene/P1/Sink origin, cadence,
movement out/back, reconnect/DOWN and collision-revision publication.
`Docs/M1/reports/A1-S.md` records raw semantic red/green evidence and the
exact A1-U handoff. Tests use an explicit flat canonical fixture and
manual monotonic clock; they do not claim real terrain, authentication,
transport ordering on arrival, client rendering or capacity acceptance.
A1-U owns remote admission/reordering, interpolation, resources and UE
assets; reliable send order does not prevent DATAGRAM arriving first.

E1 takes over
the existing `CollisionUpdates` path for online edit admission and UE
collision/render acceptance. Neither adds another player writer.

## Server collision timeline verification (E1-S)

`voxim_collision_timeline_test.exs` composes real World, sealed R6 source
artifacts (and GeneratedStore for outside-domain edits), Scene, Sink and
the existing P1 NIF. Its native wrapper only observes calls and provides a
test barrier; it delegates every install, spawn query and physics step to
P1. Generic next-canonical and next-output receives assert order before
checking exact sequence/revision/tick values.

The bounded runner is `python Docs/M1/runtime/E1-S/run.py <fresh-label>`
from Voxim. Every run creates a private Linux source/BEAM cache pinned to
reviewed Git dependencies, without umbrella application boot, DB, ports,
Docker or native compilation. The report at `Docs/M1/reports/E1-S.md`
records the final T1 Scene source handoff, raw results and negative controls.
Coverage includes two-core atomic installation, consecutive core versions,
real World progress during a blocked install, empty-occupancy transactions,
reversed join preparation, Ready/InputStart/fences, stale-epoch cleanup,
both joining characters losing support and an edited wall blocking input.
Gate edit bounds are consumed by source inspection; client prediction,
arrival ordering, Presented and whole E1/M1 acceptance remain separate.

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
