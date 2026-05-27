# GateServer Voxel Runtime Boundary

This directory contains Gate-side voxel adapters and per-client planning
helpers. Gate owns transport/session state and turns client intent plus World
routing decisions into protocol behavior. It does not own chunk truth and does
not decide region ownership.

- `PrefabLocalTransaction` keeps the local transaction adapter used by prefab
  placement tests and smoke flows.
- `SyncBudget` is a pure per-client voxel stream budget planner. It consumes a
  World partition window plus Gate-local counters/backlogs and returns
  deterministic chunk plans, pressure, and stream usage. It owns no process
  state and does not call World, Scene, DataService, or Rust. The consumed
  World window can use independent horizontal and vertical near/halo radii, so
  Gate budgets only the relevant open-world layers instead of assuming every
  player needs a full cube of voxel chunks.
- `SubscriptionPlanner` converts that window plus known client versions into
  executable subscribe/skip entries and a `SyncBudget` plan.
- `SubscriptionRuntime` applies a planner result to one Gate connection state.
  It subscribes new Scene chunks, keeps retained bindings, idempotently removes
  dropped bindings, rolls back only newly-created bindings if a later subscribe
  fails, and emits transport-neutral observe logs. It stores only connection
  subscription handles; it does not own partition, lease, chunk, snapshot, or
  delta truth.
- `SubscriptionRebind` refreshes existing connection subscription handles after
  a migration-cutover invalidate. It re-routes only the affected subscribed
  chunk through World, subscribes the new Scene lease before dropping the old
  Scene binding, preserves delivery tier/envelope metadata, and emits the
  shared `voxel_subscription_rebind_*` observe events used by TCP and
  WebSocket.
- `ChunkVersionLedger` tracks the chunk versions already forwarded by one
  reliable Gate connection. It is a send-boundary diagnostic and a validation
  source for later client ACKs; it is not used as proof that the client can
  reuse a retained chunk version.
- `ClientAckLedger` tracks chunk versions the client explicitly ACKed after
  Gate forwarded them. It is the only retained-version source used for
  cross-unsubscribe reuse; ahead-of-forwarded ACKs are rejected and logged.
- `DeliveryEnvelope` validates metadata-complete Scene-to-Gate live delivery
  envelopes. Scene still creates the payload and owns chunk/field/object truth;
  Gate validates the routing, lease, epoch, version, stream, and byte-size
  contract once before handing the frame to the per-connection scheduler. TCP
  and WebSocket workers then fence each valid envelope against their active
  `voxel_subscriptions`; stale or mismatched lease/epoch/region metadata is
  dropped before it can prune, queue, or forward data.
- `DeliveryScheduler` gates live Scene-to-Gate `ChunkSnapshot`, `ChunkDelta`,
  and `FieldRegionSnapshot` pushes at the per-connection transport boundary.
  It also marks `ObjectStateDelta` as an immediate event lane so field backlog
  cannot starve object lifecycle events. It owns a bounded local queue, a data
  send window, event/control counters, and control-lane pruning for
  `ChunkInvalidate` / `FieldRegionDestroyed`; it does not own chunk truth,
  object truth, field truth, or client ACK truth.
  New Scene-to-Gate envelope messages schedule and prune from envelope metadata,
  so Gate does not decode hot field/chunk payloads just to make a transport
  decision. The older raw payload entry points remain as a compatibility adapter
  and still decode the minimal fixed headers needed to preserve legacy behavior.

Ownership rules:

- Gate owns per-connection budget state, known chunk versions, pending byte
  counters, recovery/resync counters, and CLI-visible transport diagnostics.
- World owns partition windows, region assignments, leases, migrations, and
  route truth.
- Scene owns hot chunk state, chunk versions, snapshot/delta payload creation,
  field/object fan-out, and chunk-local simulation.
- DataService owns durable snapshots and recovery storage, not per-client
  runtime budget counters.

`mix gate_server.sync_budget_observe` is the non-GUI smoke entry for this
boundary. It builds a sample World partition window, plans a Gate sync budget,
prints a compact summary, and writes `gate_sync_budget_window` observe logs with
chunk-level budget decisions. It accepts `--near-vertical-radius` and
`--halo-vertical-radius` to reproduce the open-world interest-shape budget from
CLI/logs without a browser.

`mix gate_server.chunk_version_observe` is the non-GUI smoke entry for the
per-connection version ledger. It records a sample `ChunkSnapshot` and
`ChunkDelta`, prints `forwarded_chunk_versions`, and writes
`gate_chunk_version_observe` so sync behavior can be checked without a browser.

`mix gate_server.migration_cutover_observe` is the non-GUI smoke entry for the
migration-cutover rebind path. It performs a World route/lease cutover, captures
the authoritative `migration_cutover` invalidate pushed by Scene
`ChunkDirectory`, re-routes the affected existing Gate-shaped subscription,
subscribes the new Scene lease, and verifies that a fresh Scene snapshot reaches
the subscriber process. The same observe log contains World
`voxel_migration_cutover*`, Scene `voxel_chunk_invalidate_pushed`, and Gate
`voxel_subscription_rebind_*` events, so the path stays server-authoritative and
debuggable without a browser. This CLI does not open a real socket; TCP and
WebSocket worker tests cover the connection-level auto-rebind path. Failed
cutover rebinds remove the old handle from active `voxel_subscriptions` and
record it under `voxel_subscription_rebind_pending` for diagnostics/recovery;
`--simulate-rebind-failure` exercises that CLI reporting branch.

`mix gate_server.delivery_scheduler_observe` is the non-GUI smoke entry for
live voxel send scheduling. It demonstrates one immediate snapshot, deferred
chunk/object/field data frames, one chunk invalidate that bypasses the data
budget and prunes same-chunk data, and one field destroyed control frame that
prunes the deferred same-region field snapshot. It also demonstrates a
metadata-complete delivery envelope and logs `tier`, `stream_class`, `lease_id`,
`owner_epoch`, `server_version`, `metadata_source`, and `payload_decode_used` so
Scene-to-Gate delivery decisions can be checked without inspecting payload
headers.

V1 now plans live subscribe requests before Scene subscription. It admits
assigned near/halo chunks, skips missing or unleased chunks with explicit
reasons, and emits `voxel_subscription_window_planned` plus
`voxel_transport` debug fields.

V2 applies those plans through `SubscriptionRuntime`. Explicit TCP/WebSocket
`ChunkSubscribe` and movement-boundary partition refreshes now use the same
Scene subscribe/unsubscribe executor, rollback policy, and
`voxel_subscription_diff_*` observe events. Explicit `ChunkSubscribe` keeps
additive debug semantics and does not implicitly drop existing bindings; movement
boundary refreshes use replacement diff semantics so the connection follows the
authoritative partition window. `voxel_subscription_plan` remains a diagnostic
summary, not authority; the connection's active binding table is
`voxel_subscriptions`, while World and Scene remain the authoritative owners.
Client-supplied voxel targets are admitted only after Gate compares their
logical scene and chunk window with the server-held partition/chat context; a
connection without an authoritative context fails closed outside legacy test
fixtures.
At V2 this did not throttle live snapshot/delta sends or enforce byte caps.
V4 closes the first live-send gap for chunk snapshot/delta traffic; halo
degradation and resync/recovery enforcement remain later extensions.

V3 records versions when TCP/WebSocket connections forward Scene
`ChunkSnapshot` and `ChunkDelta` payloads. This `forwarded_chunk_versions` cache
is a send-boundary diagnostic and validation source for later client ACKs; V5
stops using it as proof that the client has received data. Delta entries only
advance the cache when their `base_chunk_version` matches the previously
forwarded version. `ChunkInvalidate` clears the affected cache entry. Dropped
subscriptions also clear their forwarded cache entry.

V4 extends the delivery boundary to live Scene pushes for `ChunkSnapshot`,
`ChunkDelta`, `ObjectStateDelta`, `FieldRegionSnapshot`, `ChunkInvalidate`, and
`FieldRegionDestroyed`. TCP and WebSocket connections now pass snapshot, delta,
object-state, and field-snapshot payloads through `DeliveryScheduler` before
writing to the client. Chunk/field state data can be queued locally when
over-budget and is visible in `voxel_transport` debug fields; object-state
deltas stay in an immediate event lane and never sit behind field backlog.
`forwarded_chunk_versions` advances only after TCP write success or WebSocket
owner handoff for chunk snapshot/delta payloads, matching the concrete transport
boundary in each worker. `ChunkInvalidate` remains reliable control traffic: it
bypasses the data budget, clears the forwarded-version entry, and prunes queued
same-chunk data before forwarding.
When the invalidate reason is `:migration_cutover`, TCP and WebSocket then call
`SubscriptionRebind` so the next snapshot stream comes from the current World
lease instead of waiting for player movement or a manual debug probe.
`FieldRegionDestroyed` also bypasses the data budget and prunes queued
same-region field snapshots before forwarding. Queue overflow drops the incoming
frame, preserves already-queued order, and marks identified chunk
snapshot/delta streams as needing a future snapshot/invalidate before later
deltas may flow again.

V5 adds the explicit client ACK retention contract. TCP and WebSocket accept
`0x76 VoxelChunkAck` and also validate legacy `ChunkSubscribe.known` entries
through `ClientAckLedger`; both paths reject ACKs ahead of what Gate has
actually forwarded. Subscription planning now passes only validated
`client_ack_versions` to Scene, excluding chunks whose live delivery queue has
marked resync as required. `forwarded_chunk_versions` remains a send-boundary
debug cache, not proof that the client received data. A resync-required marker
survives queue pruning and ordinary unsubscribe, so a missed delta cannot be
converted back into a reusable retained ACK by leaving and re-entering the
subscription. `ChunkInvalidate` clears both forwarded and client-ACK ledgers
only after the control frame crosses the concrete transport boundary; ordinary
unsubscribe clears only the forwarded cache, allowing acknowledged retained
chunks to be reused later when no resync marker blocks that chunk.
`mix gate_server.partition_subscription_observe --known-version-mode
forwarded|acked|acked-resync` exposes this boundary from CLI/logs for movement
refresh: forwarded-only versions are rejected as reuse proof, ACK-backed
versions are passed to Scene, and resync-required ACKs are forced back to a
fresh sync path.

V6 adds the first halo ghost/prewarm contract. `SubscriptionPlanner` still
admits assigned near and halo chunks from the World partition window, but now
marks each entry with `send_snapshot?`, `initial_delivery_mode`, and a
snapshot defer reason. Near chunks stay authoritative and can request the
initial Scene snapshot; halo chunks become `:halo_ghost` subscriptions when the
per-client snapshot budget cannot cover a full initial snapshot. Gate still
subscribes those halo chunks so later live invalidates/deltas have a routed
handle, but it passes `send_snapshot?: false` to Scene to avoid spending a full
voxel snapshot on speculative edge-of-interest data. The CLI smoke path
`mix gate_server.partition_subscription_observe --partition-radius 1
--voxel-snapshot-cap 128` prints `snapshot_subscriptions` and
`ghost_subscriptions` so this behavior can be verified without a browser.
If a retained halo ghost later becomes near, `SubscriptionRuntime` promotes the
existing handle and asks Scene for an authoritative snapshot once, instead of
keeping the client on a ghost-only edge subscription. The same CLI can exercise
that path with `--prewarm-destination-ghost`, which reports
`promoted_subscriptions` and `promotion_snapshots`.

V7 adds the first Scene-to-Gate delivery envelope boundary. TCP and WebSocket
connections now accept `{:voxel_delivery_envelope, map}` from internal Scene
pushes and pass it through `DeliveryEnvelope` before scheduling. Valid envelopes
must match the connection's active subscription lease/epoch/region before Gate
uses metadata as the queue/prune truth. Metadata includes `logical_scene_id`,
`chunk_coord`, `tier`, `stream_class`, `byte_size`, `server_version`,
`lease_id`, and `owner_epoch`; malformed or stale envelopes are dropped with
`status: :invalid_envelope` and an observable reason. `ChunkInvalidate`
envelopes use the same concrete transport side effects as legacy invalidates:
they forward the control frame, clear forwarded/client-ACK ledgers, clear
resync markers, and can trigger cutover rebind. Legacy raw payload tuples
continue to work for callers that do not opt in. Gate subscriptions now opt in
to envelope delivery for Scene chunk `ChunkSnapshot`, `ChunkDelta`, and
`ChunkInvalidate` fan-out, so live chunk scheduling can use authoritative
metadata without decoding hot payloads. Field and object Scene fan-out remain on
the legacy raw tuple path until their own envelope migration slices land.
