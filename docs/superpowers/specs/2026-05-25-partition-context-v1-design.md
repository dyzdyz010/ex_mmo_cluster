# Gate Authoritative Partition Context v1 Design

## Goal

Create the first executable bridge between server-authoritative movement,
World partition routing, Gate voxel subscription planning, and Chat presence.

## Boundary

- Scene owns authoritative movement positions.
- World owns partition windows, region assignments, and leases.
- Gate owns per-connection context and decides when a chunk boundary requires a
  refresh.
- Chat owns session presence and channel delivery.

`GateServer.PartitionContext` is pure. It does not call World, Scene, Chat, or
DataService. It turns an authoritative location plus a World window into:

- current chunk and region;
- boundary kind: `:none`, `:chunk`, `:region`, or `:unroutable`;
- subscription diff for connection workers to apply;
- Chat presence payload for `ChatServer.Runtime.refresh_presence/2`.

## Coordinate Rule

Movement positions are centimeters. One macro voxel is 100 cm and one chunk is
16 macro voxels, so a chunk edge is 1600 cm. `SceneServer.Voxel.Types` is the
canonical helper for this conversion; Gate and Chat must not maintain their own
ad hoc `/16` location logic.

## CLI Evidence

`mix gate_server.partition_presence_observe` seeds a local World ledger and Chat
runtime, simulates one authoritative movement boundary, prints a compact summary,
and emits `gate_partition_presence_resolved`. This gives headless automation a
single command to verify the cross-system context chain.

## Follow-On

`GateServer.PartitionRuntime` now consumes this planner from TCP and WebSocket
movement ACK paths. The connection sends the ACK first, then refreshes the
partition context. Same-chunk ACKs do not call World or Chat. Chunk/region
boundary ACKs request a World partition window, refresh Chat presence, and then
apply the subscription diff through `GateServer.Voxel.SubscriptionRuntime`.

If Chat is temporarily missing or the session was not joined yet, Gate keeps the
authoritative partition context, stores pending Chat presence, and retries Chat
on later same-chunk ACKs without re-querying World. If subscription application
fails after Chat succeeds, Gate keeps the authoritative partition/chat context,
preserves the last known subscription table, and records
`subscription_apply_status` for CLI/observe diagnostics instead of rolling back
movement truth.

The runtime also passes Gate's per-connection forwarded-version cache into
`PartitionContext` when a movement boundary needs a new subscription plan. This
lets retained or previously forwarded chunks use `known_version` instead of
requesting a redundant full snapshot. Dropping an active subscription clears
the affected cache entry, as does `ChunkInvalidate`; future move-away /
move-back reuse must be backed by an explicit client ACK/retention contract so
Gate does not become voxel authority by implication.
