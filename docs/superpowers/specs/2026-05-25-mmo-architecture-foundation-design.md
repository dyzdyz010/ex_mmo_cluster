# MMO Architecture Foundation Design

## Goal

Build the MMO around seamless server-authoritative world partitions, budgeted
voxel synchronization, and observable runtime lanes instead of continuing to
polish isolated effects.

## Scope

This design is the new engineering baseline for the next implementation line in
`ex_mmo_cluster`. It covers the target architecture and the first executable
slice. It does not replace the existing voxel authority, movement, field, or
prefab contracts; it organizes them into a larger MMO runtime.

## Authority Model

- Gate owns connection state, authentication, protocol encoding, transport
  recovery, per-client rate limits, and CLI-visible session diagnostics.
- World owns logical scene partitioning, region assignment, leases, migration
  state, cross-region transaction planning, and routing decisions.
- Scene owns hot actors, NPCs, AOI workers, chunk processes, field regions,
  combat/runtime effects, and authoritative tick state for leased regions.
- DataService owns durable storage: account/character data, chunk snapshots,
  transaction recovery rows, future chat history, and audit/event logs.
- Native Rust code owns deterministic computation only. It may calculate
  movement integration, voxel collision samples, field propagation, AOI broad
  phase, or LOD/proxy generation, but it must not own MMO state.

## Non-Negotiable Boundaries

- Do not create a second routing directory. `MapLedger`, `RegionAssignment`,
  `SceneLease`, and `MigrationPlan` remain the routing and lease truth.
- `partition_window` is a read model over existing World ownership state. It
  must not mutate leases, chunk state, subscriptions, or DataService rows.
- Gate must not compute partition semantics. It may ask World for the window
  and adapt the result into client subscriptions.
- Chat truth must not live inside Scene AOI loops. Scene may provide candidate
  recipients, but a Chat runtime owns channel policy, fan-out, history, and
  moderation hooks.
- DataService durable writes must not become part of the hot routing path.
- Native Rust may accelerate deterministic geometry or classification later,
  but it must stay DTO-in/DTO-out and must not own lease, session, or region
  state.

## World Partition Model

The world uses four spatial layers:

```text
logical scene
  -> region shard        # movable runtime ownership unit
  -> chunk               # voxel sync and persistence unit
  -> macro/micro voxel   # edit/collision/field truth
```

Regions are not player-visible loading zones. They are ownership and scaling
units. Clients should see a continuous world while World and Scene migrate
region ownership behind the subscription and lease layers.

The first partition API must answer this question without touching chunk truth:

```text
Given a logical scene and a center chunk, which nearby chunks are active,
which surrounding chunks are halo/prewarm candidates, which regions own them,
which leases apply, and which chunks are missing or unrouted?
```

This is the control-plane primitive for seamless handoff, cross-region AOI,
chunk prewarm, and sync budget scheduling.

## Synchronization Budget

Voxel sync must be budgeted from the start:

- Near field: authoritative chunk snapshots/deltas, object deltas, field
  snapshots, collision-relevant occupancy, and combat-relevant object state.
- Mid field: chunk summaries, occupancy masks, object summaries, low-rate
  environment/field aggregates.
- Far field: derived LOD/proxy mesh/impostor/skyline data. Far data is derived
  from voxel truth and is never the edit truth.

Every client eventually needs a budget ledger:

- bytes per second by stream class
- pending reliable messages
- high/medium/low AOI priority
- chunk snapshot/delta backlog
- field bandwidth
- recovery requests and version gaps

The first partition window returns enough metadata to drive that scheduler
later without putting bandwidth policy inside `MapLedger`.

`MapLedger` now keeps a derived `RouteIndex` for routing reads. The index is a
bucket-grid projection of active `RegionAssignment` bounds grouped by
`logical_scene_id`; it stores candidate region ids only, is rebuilt from
assignments on startup or region geometry changes, and is not persisted. Route
hits still fetch the current assignment and lease from `MapLedger`, so lease
renewals and migration cutovers cannot create a second routing truth.

Partition-window calls are therefore safe as the shared control-plane primitive
for Gate subscription planning and CLI/debug. They remain read-only: lookup
stats are emitted through observe logs, not written into authoritative state.

## Chat Architecture

World chat must not run through Scene hot tick state. The target shape is a
separate Chat runtime:

- world channel: global pub/sub, durable append log, rate limits, moderation
  hooks, and reconnect history.
- region channel: routed by World partition metadata, not by Scene actor loops.
- local channel: uses AOI or partition queries to decide recipients, but the
  chat process owns message fan-out and history.
- system/party/guild channels: separate channel identities with their own
  authorization and history policies.

Gate authenticates and forwards chat intents. Chat owns channel policy and
delivery. Scene may provide AOI recipient candidates but does not store chat
truth.

Chat v1 now has an executable service boundary in `apps/chat_server/`: Gate
registers server-side chat sessions after `EnterScene`, forwards `0x08
ChatSay` to `ChatServer.Runtime`, and receives `0x89 ChatMessage` casts for
client delivery. This removes the Gate send path from Scene AOI. The current
`region` / `local` scope metadata is still a v1 session-registration input; the
next partition slice must feed it from World partition and authoritative
movement boundary events.

Gate partition context v1 adds that missing bridge as a pure planner:
`GateServer.PartitionContext` consumes Scene-authoritative movement position and
a World partition window, computes the current chunk/region, subscription diff,
and Chat presence refresh payload, then leaves application of those changes to
connection processes or CLI smoke tasks. It does not own routing truth and does
not call World, Scene, or Chat directly. Chunk conversion uses
`SceneServer.Voxel.Types.chunk_from_world_cm!/1`, so chat presence and voxel
streaming share the same 1600 cm chunk edge rule.

## First Executable Slice: World Partition v1

The first slice creates an observable partition interest window:

- pure window builder for near and halo chunk coordinates
- derived `RouteIndex` inside `MapLedger` for indexed region lookup
- `MapLedger.partition_window/4` API using existing region assignments and
  leases
- `MapLedger.route_window_with_leases/4` uses the same index-backed route
  lookup and then backfills current lease truth
- structured result with active/halo/missing chunks and per-region summaries
- CLI observe task writing deterministic `.demo/observe/` logs with
  `route_index_*` stats
- unit tests for pure geometry, ledger routing, missing chunks, and lease
  summaries

This slice intentionally does not start cross-Scene migration automatically and
does not modify Gate subscriptions yet. It creates the stable control-plane
primitive those later features will use.

Follow-on work must define a cross-region gameplay reliability matrix before
the runtime is called seamless for combat and effects. Each cross-region action
must be classified as transactional, replayable/idempotent, or best-effort with
observable drop reasons.

## Acceptance Criteria

- The partition window can be called without GUI or running browser code.
- The result distinguishes active near chunks, halo chunks, and missing chunks.
- The result groups routed chunks by region and includes current lease IDs when
  available.
- The API is read-only and does not mutate region assignments, leases, chunk
  truth, actor state, or DataService rows.
- CLI output includes a machine-readable summary and structured observe events.
- CLI output exposes route-index source, strategy, bucket, entry, and region
  counts so headless runs can confirm the indexed path is active.
- Tests cover geometry, World ledger integration, and CLI smoke behavior.
