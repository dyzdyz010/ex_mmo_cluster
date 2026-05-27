# Seamless Open World MMO Runtime Design

## Goal

Build `ex_mmo_cluster` as a seamless open-world MMO runtime instead of a set of
isolated gameplay features. World partitioning, world/region/local chat, voxel
synchronization, movement, combat, and field effects must share one
server-authoritative regional context.

The target player experience is:

- moving across the world does not expose server region boundaries;
- chat channels keep following the server-authoritative player location;
- nearby voxel edits, fields, prefabs, and actors arrive within an explicit
  bandwidth budget;
- far-world data degrades to summaries and LOD instead of flooding the client;
- failures are observable from CLI/logs without requiring a GUI.

## Non-Negotiable Principles

1. World partitioning is the MMO spine. Every high-volume runtime feature asks
   the same question first: which region and lease currently own this chunk?
2. Gate is an edge adapter. It owns connections, protocol, rate limits,
   per-client queues, and debug snapshots. It does not own gameplay truth.
3. World is the control-plane authority for region assignment, route indexes,
   leases, migration plans, and partition windows.
4. Scene is the hot data-plane authority for actors, chunks, AOI, fields,
   combat, and authoritative movement ticks inside leased regions.
5. Chat is a standalone runtime. Scene may supply AOI hints, but chat truth,
   channel policy, fan-out, history, and moderation do not live in Scene loops.
6. DataService is durable truth only. It must not be placed in the hot movement,
   partition, or chat fan-out path.
7. Rust NIF code accelerates pure deterministic computation. It must not own
   MMO authority, leases, sessions, sockets, migrations, or durable state.

## Runtime Layers

```text
Client
  -> Gate edge runtime
       connection state, protocol, UDP/TCP/WS, per-client budget, CLI snapshots
  -> World control plane
       route index, partition window, leases, migration director
  -> Scene regional data plane
       region runtime, chunk processes, AOI, movement, combat, fields, prefabs
  -> Chat runtime
       world/region/local/system channels, presence indexes, delivery policy
  -> DataService
       chunk snapshots, write tokens, accounts, character state, chat history
  -> Rust NIF kernels
       AOI broad phase, voxel diff/compression, field propagation, raycasts, LOD
```

The important boundary is not app names; it is state ownership. BEAM processes
own long-lived MMO state and supervision. Rust owns CPU-heavy transformations
over bounded DTO inputs and outputs.

## Region Runtime

The missing abstraction is a shared region runtime contract. It connects:

- Scene-authoritative movement location;
- World partition window and current lease;
- Gate subscription diff and sync budget;
- Chat presence;
- Scene chunk subscription and invalidation.

The connection process should not duplicate this logic in TCP and WebSocket
modules. Gate needs a shared `PartitionRuntime` / region-context bridge with
this behavior:

1. Same chunk movement: do not call World or Chat.
2. Chunk boundary: request a World partition window centered on the new chunk.
3. Region boundary: refresh Chat presence and compute a new voxel subscription
   plan from the same partition result.
4. Apply subscription diffs through one shared voxel subscription runtime.
5. Preserve previous context on unroutable or failed refresh, and emit a
   structured failure event.

Movement ACK delivery must not wait behind region refresh. The ACK can be sent
first, then the region refresh runs as an asynchronous, fenced update keyed by
connection generation and authoritative tick. Late refresh results are ignored.

## World Partitioning

The world has four spatial levels:

```text
logical scene
  -> region shard        # migration and runtime ownership unit
  -> chunk               # voxel sync and persistence unit
  -> macro/micro voxel   # edit, collision, field, and material truth
```

Regions are invisible scaling units, not loading zones. A player interest
window contains:

- near chunks: full gameplay-relevant truth;
- halo chunks: prewarm and low-rate streaming candidates;
- missing/unroutable chunks: explicit failure states;
- per-region summaries and current leases.

The initial cube window is acceptable for deterministic tests, but the open
world runtime needs configurable interest bodies: horizontal near/halo radius,
vertical layer limits, and special volumes for flight, underground spaces, or
large structures. V1 of this shape is implemented as independent horizontal
near/halo radii plus vertical near/halo radii, with cube semantics retained as
the default. A voxel world can be fully 3D, but most movement does not justify
subscribing to an entire cube of irrelevant vertical chunks.

`MapLedger` remains the authority. `RouteIndex` is a rebuildable projection,
not a second truth source. If route lookup becomes hot enough, the index can
move to a Rust NIF spatial kernel later, but only as a derived lookup table that
returns candidate region ids and still validates against current World state.

## Voxel Synchronization

Voxel sync cannot be a broadcast problem. It must be a budgeted stream problem.

Every client needs a budget ledger by stream class:

- reliable control;
- chunk snapshot;
- chunk delta;
- field state;
- recovery/resync.

Chunk delivery tiers:

- Near: authoritative chunk snapshot/delta, collision-relevant occupancy,
  combat-relevant objects, and field snapshots.
- Halo: chunk summaries, low-rate object summaries, occupancy masks, and
  prewarm data.
- Far: derived LOD/proxy/skyline data only. Far data is never edit truth.

Scene chunks should produce versioned snapshots and deltas. Gate tracks client
known versions and ACK gaps. The subscription planner allocates bytes by
priority and pressure; when congested, it prefers correctness-critical near
state over cosmetic or far state.

Current implementation note: Gate now has a per-connection
`ChunkVersionLedger` for reliable TCP/WebSocket voxel streams. It records
Scene-authoritative snapshot versions and applicable delta versions after Gate
forwards them, supplements client `known` hints on explicit `ChunkSubscribe`,
and feeds the same cache into movement-boundary subscription plans. Client
`known` values override Gate's cache for chunks they mention; the Gate cache
only fills missing chunks because it is not a client ACK ledger. Deltas only
advance the cache when their base version matches the previously forwarded
version, and `ChunkInvalidate` clears the affected entry. This is not an
authority transfer to Gate; it is only a bounded sync hint used to avoid
redundant full snapshots when Scene's current chunk version already matches
what the connection has received.

Current implementation note: Gate now gates live `ChunkSnapshot`, `ChunkDelta`,
and `FieldRegionSnapshot` sends with a per-connection `DeliveryScheduler`.
Subscription planning still decides what a client should receive, while the live
scheduler decides what leaves the Gate socket now. Over-budget state payloads
are queued locally and exposed through `voxel_transport` debug fields.
`ObjectStateDelta` uses the same observe surface as an immediate event lane, so
field snapshot backlog cannot starve object lifecycle events. The
forwarded-version cache advances only after TCP write success or WebSocket owner
handoff for chunk snapshot/delta frames. Field delivery scheduling only reads
the fixed 0x73 / 0x74 header needed for routing and pruning; it does not decode
or scan the high-frequency cell arrays on Gate.
`ChunkInvalidate` is a control-lane frame: it bypasses the data budget, clears
the forwarded-version cache, and prunes queued same-chunk data before
forwarding. `FieldRegionDestroyed` is also control-lane traffic: it bypasses the
data budget and prunes queued same-region field snapshots before forwarding.
Queue overflow preserves already-queued order and drops the incoming frame;
identified chunk snapshot/delta streams are marked resync-required so later
deltas cannot be sent across a broken version chain.

Scene-to-Gate voxel and field pushes now have a Gate-side envelope ingress for
the same small delivery contract:

```text
{logical_scene_id, chunk_coord, tier, stream_class, byte_size, server_version,
 lease_id, owner_epoch, payload}
```

Gate queues valid state envelopes per connection and drains them according to
the current budget ledger. TCP and WebSocket connections accept
`{:voxel_delivery_envelope, map}` from internal Scene senders; Gate validates
byte size, route metadata, lease, epoch, stream class, and version before using
the metadata for scheduling, pruning, and observe logs. The transport worker
also fences each envelope against its active subscription table before it can
touch the queue. Stale lease/epoch/region mismatches are dropped at ingress with
observable `invalid_envelope` actions; `ChunkInvalidate` envelopes share the
same forwarding, ledger clearing, resync clearing, and cutover rebind side
effects as legacy invalidates. Legacy raw payload messages remain supported as a
compatibility adapter and still decode minimal headers. Deeper version-staleness
drops and explicit object-state recovery remain later extensions.

The highest-value Rust NIF targets for voxel sync are:

- chunk diff mask generation;
- snapshot/delta compression and decompression helpers;
- AOI broad-phase candidate filtering;
- occupancy, raycast, and collision sampling;
- field propagation kernels;
- far LOD/proxy mesh generation.

These kernels must run on dirty CPU schedulers when heavy and must return
bounded results. They must not block BEAM schedulers or hold authoritative state.

## Chat

Chat follows server-side presence derived from the same partition context as
voxel subscriptions.

Channel model:

- `world`: sharded by logical scene, with rate limits and bounded recent
  history.
- `region`: routed by World region id from server-authoritative presence.
- `local`: routed by chunk/radius presence index, optionally refined by Scene
  AOI hints, but still delivered by Chat.
- `system`: authoritative server messages with explicit source.
- future `party` / `guild`: separate identity and authorization policy.

Chat presence updates are not taken from the client. They are refreshed after
Gate resolves a movement boundary through World. Region/local channel delivery
therefore stays consistent with the same server-authoritative world partition
used by voxel sync.

The current single-process runtime is only a v1 boundary. Production shape
requires sharding by `logical_scene_id` and, for region/local traffic, by region
or region group. Chat also needs membership indexes for `world`, `region`, and
`local` scopes so fan-out does not scan every session. Legacy Scene AOI chat
broadcasts must be treated as compatibility code and not expanded; otherwise two
different chat truths will coexist.

Current implementation note: local chat can now consume server-derived
`candidate_region_ids` from Gate's partition context. That lets Chat preselect
sessions through the region presence index when a local radius spans multiple
regions, then apply exact chunk-radius filtering before delivery. Gate records
the partition-window coverage as `candidate_region_radius` and only uses the
candidate hint when it covers the requested local radius; undersized hints fall
back to ordinary local chunk-window lookup to preserve correctness.

Current implementation note: Chat now has a logical-scene shard directory.
`ChatServer.RuntimeDirectory` maps an authoritative `logical_scene_id` to a
shard-local `ChatServer.Runtime`, while each runtime still owns its own session
table, world/region/local presence indexes, bounded history, and fan-out.
The directory rejects route mismatches such as a scene-7 session publishing to a
scene-8 world channel, and `mix chat_server.shard_observe` prints
`shard_key`, `route_target`, `shard_count`, and recipient counts for headless
verification. This is deliberately not region sharding yet: region and local
indexes stay co-located with the session truth for one logical scene.

Durable chat history is asynchronous. The hot delivery path writes bounded
in-memory history and emits observe logs; DataService persistence can trail with
at-least-once append semantics.

## Seamless Migration

Region migration is a staged protocol:

1. World creates a migration plan and new target lease.
2. Target Scene prewarms chunks, actors, field state, and voxel summaries.
3. Source Scene sends final catch-up deltas.
4. World cuts over the lease.
5. Gate invalidates/rebinds affected subscriptions.
6. Chat refreshes region indexes from authoritative movement/partition context.

No runtime should infer migration from a Scene node name or stale lease id.
Cutover is lease-fenced and observable. During cutover, clients may briefly see
retained old subscriptions, but writes and authoritative effects must validate
against the current lease.

Cutover must update one atomic routing identity:

```text
{lease_id, owner_epoch, owner_scene_instance_ref, assigned_scene_node}
```

`MigrationPlan` must carry the target Scene node explicitly. A cutover that
changes the lease but leaves `assigned_scene_node` pointing at the old Scene is
invalid because Gate subscriptions and voxel writes route by concrete Scene
owner.

## Optimization Strategy

Optimize by lane, not by feature.

Low latency lane:

- movement ACK;
- local actor snapshots;
- combat/effect confirmations;
- near-field chunk deltas.

Control lane:

- partition window refresh;
- subscription diff;
- lease validation;
- migration invalidation.

Bulk lane:

- chunk snapshot;
- recovery/resync;
- halo prewarm;
- far LOD.

The low-latency lane must not block on control or bulk work. Control results are
fenced by authoritative tick/generation. Bulk output is budgeted and droppable
when stale.

Performance targets for the first production-shaped baseline:

- same-chunk movement emits no World or Chat calls;
- movement ACK p95 is independent from partition refresh work;
- chunk-boundary partition refresh p95 is measured separately;
- Gate debug output shows current chunk, region, lease, pressure, and last
  partition refresh result;
- observe logs expose route-index stats, sync pressure, skipped chunks, chat
  recipient counts, and migration cutover events.

Control-plane scaling must be measured separately from gameplay latency:

- `route_window_with_leases/4` p50/p95/p99 by region count and interest shape;
- `MapLedger` mailbox length during boundary movement bursts;
- `RouteIndex` rebuild time during split/merge or migration geometry changes;
- Gate per-connection pending bytes and socket send latency;
- chat presence update lag and region/local wrong-delivery count.

If region split/merge becomes common, `RouteIndex` needs an incremental update
path. Until measurement proves that need, it remains rebuildable and simple, but
large-world benchmarks must make rebuild spikes visible.

## Implementation Phases

### Phase 1: Region Context Integration

Create the shared Gate region-context runtime and connect movement ACK boundary
events to World partition windows, Chat presence refresh, and subscription diff
planning. Add CLI/debug output for current region/chunk and last refresh result.

Acceptance:

- same-chunk movement is a no-op for World/Chat;
- movement ACK delivery is not delayed by partition refresh calls;
- chunk/region boundary movement refreshes Chat presence from World truth;
- failed route preserves previous context and emits an observable reason;
- TCP and WebSocket use the same runtime module.

Current implementation note:

- `SceneServer.Aoi.PartitionInterest` is the first AOI-side bridge to the
  shared partition-window contract. It is a pure policy module: near assigned
  chunks become authoritative AOI queries, halo assigned chunks become boundary
  ghost/prewarm queries, and missing or unleased chunks are skipped with
  explicit reasons. `mix scene_server.aoi_partition_observe` emits
  `scene_aoi_partition_interest_planned` so this can be verified without a GUI.
- Live AOI now consumes the same server-authoritative partition-window DTO.
  `PlayerCharacter` holds the latest window across AOI adapter recovery;
  `AoiItem` derives the partition-interest plan locally, filters octree
  candidates by routed chunk, and emits `aoi_partition_interest_applied` /
  `aoi_refresh` counts for headless verification. `AoiManager` remains only the
  CID/location index and does not learn World/Gate ownership semantics.
  Routes assigned to another Scene node are fenced out of local AOI until an
  explicit mirrored ghost/prewarm channel exists, and failed `nil` refreshes
  preserve the previous authoritative window instead of reopening radius-only
  visibility. Applying a new window also prunes stale subscribers immediately,
  so a local-to-remote owner flip cannot leak movement events through a cached
  subscription list while waiting for the next AOI timer.
- Remote halo demand now has a first worker boundary:
  `SceneServer.Worker.Aoi.RemoteMirrorRunner` consumes
  `RemoteMirrorLedger.request_groups` in a bounded one-pass run, calls injected
  ghost/prewarm fetch adapters once per `{logical_scene_id, request_mode,
  owner_scene_node, lease_id, chunk_coord}` group, and emits
  `scene_remote_mirror_runner_*` observe events. The runner reports
  `live_fanout_count: 0` by contract, so mirrored halo summaries are observable
  without becoming local AOI subscription truth.

### Phase 2: Voxel Subscription Runtime

Extract subscription application from TCP/WS into a shared runtime. Apply
subscribe/unsubscribe diffs from the region context through World leases and
Scene chunk processes. Track known chunk versions and per-client budget usage.

Acceptance:

- subscription diff application is transport-agnostic;
- near/halo/missing/unleased chunks are observable;
- recovery pressure changes planning output;
- live snapshot/delta/field sends are throttled by the same budget ledger;
- CLI smoke can show a player crossing a chunk boundary and rebinding streams.

Current implementation note:

- `GateServer.Voxel.SubscriptionRuntime` now owns transport-neutral
  subscribe/unsubscribe diff application, newly-created subscription rollback,
  and `voxel_subscription_diff_*` observe events.
- TCP, WebSocket, and `GateServer.PartitionRuntime` share this executor for
  explicit `ChunkSubscribe` and movement-boundary stream rebinding.
- Subscribe failure rolls back only bindings created by the current apply; it
  does not roll back server-authoritative movement, partition context, or Chat
  presence.
- `mix gate_server.partition_subscription_observe` shows a chunk-boundary
  movement applying the diff to a local Scene chunk directory.
- Known-version ledgers are implemented for forwarded TCP/WebSocket
  snapshot/delta payloads. Live send throttling is implemented for
  snapshot/delta/invalidate; field stream throttling and explicit client ACK
  windows remain later work.
- `GateServer.Voxel.SubscriptionRebind` now handles migration-cutover
  invalidates for TCP/WebSocket subscriptions. The invalidate still reaches the
  client as control traffic, then the affected subscribed chunk is re-routed via
  World and resubscribed against the current lease without waiting for another
  movement ACK. When that rebound chunk is also the connection's current
  `partition_context` chunk, Gate updates the local routing identity from the
  new subscription lease/epoch/owner and marks the context as
  `boundary_kind: :authority_cutover`, so a stationary player is no longer left
  on stale authority until the next movement boundary. If the Scene subscribe
  fails after the old stream has been invalidated, the chunk moves to
  `voxel_subscription_rebind_pending`; manual/debug rebind retries that pending
  entry through World routing and restores the active subscription when Scene is
  healthy again.

### Phase 3: Chat Presence Indexes

Make Chat runtime maintain world/region/local presence indexes and route
messages from those indexes. Region/local chat must follow authoritative
partition refreshes, not client positions.

Acceptance:

- world, region, local, and system channels are independently testable;
- local scope uses chunk/radius presence with explicit recipient/skipped counts;
- region movement changes delivery membership without Scene AOI involvement;
- Chat observe logs are enough to debug headless delivery.

### Phase 4: Migration And Prewarm

Wire World migration cutover events to Gate subscription invalidation and Scene
prewarm/catch-up. Keep old subscriptions only as a fenced fallback until the new
lease is active.

Acceptance:

- region migration can be driven from CLI;
- cutover changes lease and `assigned_scene_node` as one routing identity;
- Gate rebinds subscriptions after cutover;
- writes validate against current lease;
- migration events include prewarm, catch-up, cutover, invalidation, and client
  rebind evidence.

Current implementation note:

- `mix gate_server.migration_cutover_observe` now drives the canonical staged
  migration path instead of the World convenience `migrate_region/4` shortcut.
  The CLI seeds a real source hot chunk, uses separate source and target
  `ChunkDirectory` instances, submits `MigrationPrewarm.prewarm_slices/2` ACKs
  to World, runs `MigrationPrewarm.final_catchup_slices/2`, then cuts over and
  proves the old lease is stale in both World and DataService before Gate
  rebinds the affected subscription and exposes the refreshed
  `partition_context` lease/epoch/owner/Scene node in stdout plus observe logs.
- World rejects cutover when the captured source lease drifts before cutover and
  does not emit Scene invalidation in that failure mode. Scene final catch-up
  rejects source persistence failures rather than producing a synthetic ACK.
- This v1 covers voxel chunk prewarm/final catch-up and Gate subscription
  rebind. Actor, field-state, combat-state, and chat-presence migration
  handoffs are still later slices on the same staged protocol.

### Phase 5: Native Hot Kernels

Move only measured CPU-hot deterministic kernels into Rustler NIFs. Start with
benchmarked voxel diff/compression and AOI broad-phase. Keep all ownership and
runtime lifecycle in OTP.

Acceptance:

- NIF calls are DTO-in/DTO-out and bounded;
- dirty scheduler use is documented for heavy kernels;
- Elixir fallback or test fixture coverage exists for correctness;
- benchmarks show the latency/CPU gain before the NIF becomes mandatory.

## Validation Snapshot

2026-05-26 local verification covered the current Phase 1-4 CLI spine in
`MIX_ENV=test`:

- `world_server.partition_observe`
- `gate_server.sync_budget_observe`
- `scene_server.aoi_partition_observe`
- `scene_server.remote_mirror_observe`
- `chat_server.observe`
- `chat_server.shard_observe`
- `gate_server.chat_scope_observe`
- `gate_server.chat_boundary_observe`
- `gate_server.partition_presence_observe`
- `gate_server.partition_subscription_observe`
- `gate_server.chunk_version_observe`
- `gate_server.client_ack_observe`
- `gate_server.delivery_scheduler_observe`
- `gate_server.partition_failure_observe` for `unroutable`, `chat-refresh`,
  and `subscription-apply`
- `gate_server.migration_cutover_observe`

The smoke matrix confirmed that World, Gate, Scene, and Chat expose the shared
region context through stdout plus observe logs, including route failures,
budget pressure, chat recipient selection, AOI halo intent, stream rebinding,
client ACK state, delivery scheduling, and migration cutover rebind evidence.

## Near-Term Direction

The Phase 1-4 baseline now has a CLI-observable spine: World partition windows,
Gate partition context, Chat routing, voxel stream planning/throttling, Scene
AOI partition interest, remote halo mirror requests, and migration cutover
rebind all share one server-authoritative regional context.

Near-term closure should focus on production reliability around that spine:

- actor, field-state, combat-state, and chat-presence migration handoffs;
- explicit object-state recovery after dropped or invalid delivery envelopes;
- large-world control-plane measurements for route-window lookup and route-index
  rebuild spikes;
- durable/asynchronous chat history and channel policy.
