# Prefab Same Scene Fast Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make multi-chunk prefab placement avoid the full World transaction path when every routed chunk is owned by the same Scene hot authority.

**Architecture:** World remains the routing and lease source of truth. Gate bulk-routes all prefab chunks, requires every route to carry `assigned_scene_node`, resolves each participant to a concrete chunk-directory owner, and runs a Scene-local prepare/commit/abort flow only when every participant shares that owner. Split-owner prefabs continue through World `TransactionCoordinator` / `TransactionExecutor`, but participants are grouped by Scene owner and keep per-chunk lease owners in complete `chunk_owners`. Missing `assigned_scene_node`, `participant_key`, or chunk owner metadata is a hard error.

**Tech Stack:** Elixir umbrella, GateServer WebSocket/TCP workers, WorldServer `MapLedger`, SceneServer `BuildTransactionApplier`, ExUnit.

---

### Task 1: Lock Routing And Fast-Path Behavior

**Files:**
- Modify: `apps/world_server/test/world_server/voxel/map_ledger_test.exs`
- Modify: `apps/gate_server/test/gate_server/ws_connection_voxel_test.exs`

- [x] **Step 1: Add a bulk-route regression test**

Add an ExUnit case proving `MapLedger.route_chunks_with_leases/3` routes all requested chunks in one call and preserves the region assignment on each route.

- [x] **Step 2: Add a same-Scene multi-chunk WS regression test**

Add a WebSocket prefab placement test where a sphere crosses chunk `{0,0,0}` and `{1,0,0}` inside one region. Do not start a transaction coordinator; the old implementation must reject with coordinator unavailable, while the desired behavior accepts and writes both chunks through the Scene-local path.

### Task 2: Add Bulk Route API

**Files:**
- Modify: `apps/world_server/lib/world_server/voxel/map_ledger.ex`

- [x] **Step 1: Add `route_chunks_with_leases/3`**

Expose a read-only GenServer call that returns `%{chunk_coord => %{assignment: assignment, lease: lease}}`, failing fast with the first route or lease error.

- [x] **Step 2: Keep single-chunk API unchanged**

Leave `route_chunk_with_lease/3` behavior intact so existing callers and tests do not move.

### Task 3: Add Scene-Local Prefab Transaction Helper

**Files:**
- Create: `apps/gate_server/lib/gate_server/voxel/prefab_local_transaction.ex`

- [x] **Step 1: Implement local prepare/commit/abort**

Use `SceneServer.Voxel.BuildTransactionApplier` for every participant. Abort already-prepared participants when a later prepare fails.

- [x] **Step 2: Return executor-shaped results**

Return `participant_results` and `prepare_results` in the same shape Gate already uses for World executor summaries.

### Task 4: Wire WS/TCP Fast Path

**Files:**
- Modify: `apps/gate_server/lib/gate_server/worker/ws_connection.ex`
- Modify: `apps/gate_server/lib/gate_server/worker/tcp_connection.ex`

- [x] **Step 1: Require `assignment.assigned_scene_node`**

Resolve Scene node directly from World assignment. Missing `assigned_scene_node` is a routing error; do not infer a Scene server from `owner_scene_instance_ref`.

- [x] **Step 2: Route chunks in bulk**

Replace Gate's per-chunk route loop with the new bulk ledger call.

- [x] **Step 3: Add same-owner multi-chunk path**

After the existing single-chunk direct path, detect whether every participant resolves to the same `{chunk_directory_module, scene_node}`. If yes, run `PrefabLocalTransaction`; otherwise keep the World transaction path.

### Task 5: Document And Verify

**Files:**
- Modify: `apps/gate_server/lib/gate_server/README.md`
- Modify: `docs/docs/20-archive/voxel-authority/2026-05-11-prefab-hot-path-implementation-status.md`

- [x] **Step 1: Update the route contract docs**

Record that single-chunk and same-owner multi-chunk prefabs stay Scene-local, while split-owner prefabs still use World transactions.

- [x] **Step 2: Run verification**

Run focused MapLedger/Gate tests when PostgreSQL is available. Always run `mix compile`, strict no-DB scene-owner smoke, `clients/web_client` typecheck, and `clients/web_client` tests to catch cross-language regressions.

Current verification: `mix compile` passed; a `mix run --no-start` strict scene-owner transaction smoke passed; `clients/web_client` `npm run typecheck` passed; `clients/web_client` `npm test` passed. Focused Elixir tests are blocked on local PostgreSQL `127.0.0.1:5432` refusing connections in `test_helper.exs`.

### Task 6: Close Split-Owner Contract Risk

**Files:**
- Modify: `apps/world_server/lib/world_server/voxel/transaction_participant.ex`
- Modify: `apps/world_server/lib/world_server/voxel/transaction_coordinator.ex`
- Modify: `apps/world_server/lib/world_server/voxel/transaction_executor.ex`
- Modify: `apps/world_server/lib/world_server/sup/world_sup.ex`
- Modify: `apps/world_server/lib/world_server/voxel/map_ledger.ex`
- Modify: `apps/gate_server/lib/gate_server/worker/ws_connection.ex`
- Modify: `apps/gate_server/lib/gate_server/worker/tcp_connection.ex`

- [x] **Step 1: Make participant identity explicit**

Require `participant_key`, `assigned_scene_node`, and complete `chunk_owners` for transaction participants. Prepare ACKs, executor inputs, and recovery scene opts are keyed only by `participant_key`.

- [x] **Step 2: Group split-owner plans by Scene owner**

Gate groups by `{chunk_directory, assigned_scene_node}` and carries `chunk_owners` for exact per-chunk lease ownership. World `MapLedger.transaction_participants/3` follows the same Scene-owner grouping.

- [x] **Step 3: Remove route compatibility paths**

Gate no longer calls `scene_server_for_owner`; `GateServer.Interface` no longer exposes that lookup. `MapLedger` rejects `put_region` unless a SceneNodeRegistry assigns a node or the caller explicitly pins `assigned_scene_node`; the old region-to-scene lookup API was removed.

- [x] **Step 4: Keep object registration owner-correct**

`TransactionExecutor.register_scene_objects_after_commit/3` dispatches by Scene-owner `participant_key` while inflating `covered_chunks_by_region` from `chunk_owners`; missing chunk-owner metadata is a hard failure, not a lease fallback.
