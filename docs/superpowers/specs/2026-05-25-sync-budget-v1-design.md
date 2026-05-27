# Sync Budget v1 Design

## Goal

Add the first observable Gate-side sync budget primitive for a seamless voxel
MMO. The goal is not to introduce a new network protocol yet; it is to make
per-client stream pressure, recovery demand, and partition-window priorities
explicit and testable before Gate starts enforcing live throttles.

## Ownership

- Gate owns per-client sync budget planning, session counters, pending stream
  pressure, known chunk versions, and recovery requests.
- World owns partition truth: logical scene, region assignment, leases,
  migration, and partition windows.
- Scene owns hot chunk truth, chunk versions, snapshot/delta payload creation,
  field/object fan-out, and chunk-local simulation state.
- DataService owns durable snapshots and recovery rows, but is not on the
  budget planning hot path.

`GateServer.Voxel.SyncBudget` is a pure module. It consumes a partition-window
shape plus Gate-side counters and returns a deterministic plan. It must not
call World, Scene, DataService, or Rust. Live Gate subscribe paths fetch that
window shape through `MapLedger.route_window_with_leases/4`, a best-effort
runtime route contract that can later be backed by an indexed World route table.

## Why Gate

The budget is per connected client. It depends on transport backlog, sequence
gap, known versions, recovery requests, and session health. Putting that state
in World would pollute the partition truth source with client-local policy.
Putting it in Scene would couple chunk truth to transport pressure. Gate already
owns WebSocket/TCP sessions and forwards chunk snapshots, deltas, object deltas,
field snapshots, and invalidations, so it is the correct owner for planning.

## Inputs

- `partition_window`: the read-only World partition window around the client.
- `stream_caps`: per-tick byte caps for `reliable_control`, `voxel_snapshot`,
  `voxel_delta`, `field_state`, and `recovery`.
- `counters`: session health values such as `last_server_seq`,
  `last_client_ack_seq`, `reliable_pending_bytes`, `fast_lane_pending_bytes`,
  `recovery_request_count`, and `resync_request_count`.
- `chunk_backlogs`: per chunk backlog hints, including snapshot/delta/field
  bytes, recovery bytes, known version, and server version.

## Outputs

- `pressure`: `:normal`, `:recovery`, or `:congested`.
- `window_summary`: assigned/missing/unleased/near/halo counts.
- `chunk_plans`: one deterministic near-before-halo plan per partition-window
  chunk, including route status, priority, budgets, and skip/recovery reason.
- `budget_usage`: allocated bytes by stream class, never exceeding caps.
- `counters`: normalized counters plus derived `seq_gap`.

## V1 Scope

V1 started as a control-plane and CLI/debug primitive and now also runs on live
subscribe requests. It does not enforce throttling in `WsConnection` /
`TcpConnection` yet and does not alter protocol frames. It admits assigned
chunks, skips missing or unleased chunks with explicit reasons, records rejected
center plans before returning errors, and records the plan so later live send
ordering can consume a tested budget contract instead of ad hoc per-message
decisions.

## Acceptance Criteria

- Pure unit tests prove near chunks are prioritized before halo chunks.
- Missing routes and missing leases receive zero budgets.
- Recovery pressure is visible when sequence gap or recovery counters exist.
- Allocations never exceed stream caps.
- CLI observe emits a `gate_sync_budget_window` event with counters, caps,
  window summary, and chunk-level budget decisions.
- Docs state the Gate/World/Scene/DataService boundary explicitly.
