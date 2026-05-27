# Sync Budget v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first Gate-owned, CLI-observable sync budget planner for voxel streaming.

**Architecture:** Gate owns per-client stream budget and recovery counters. World partition windows remain routing truth. Scene remains hot chunk/version truth. This slice is pure planning plus CLI observe, not live throttling.

**Tech Stack:** Elixir/OTP umbrella, ExUnit, existing `GateServer.CliObserve`, existing `WorldServer.Voxel.PartitionWindow`/`MapLedger`.

---

## File Structure

- Create `apps/gate_server/lib/gate_server/voxel/sync_budget.ex`
  - Pure sync budget planner.
- Create `apps/gate_server/lib/gate_server/voxel/subscription_planner.ex`
  - Pure bridge from partition-window route status to executable subscribe/skip entries.
- Create `apps/gate_server/test/gate_server/voxel/sync_budget_test.exs`
  - Unit and regression tests for allocation, recovery pressure, ordering, and validation.
- Create `apps/gate_server/test/gate_server/voxel/subscription_planner_test.exs`
  - Unit tests for subscribe/skip planning.
- Create `apps/gate_server/lib/mix/tasks/gate_server.sync_budget_observe.ex`
  - CLI observe smoke task.
- Create `apps/gate_server/test/mix/tasks/gate_server_sync_budget_observe_test.exs`
  - CLI and observe log assertions.
- Create `apps/gate_server/lib/gate_server/voxel/README.md`
  - Gate-side voxel adapter and budget boundary documentation.
- Update architecture docs with the Sync Budget v1 boundary and follow-on work.

## Task 1: Pure Budget Planner

- [x] Write failing tests for:
  - near chunks are planned before halo chunks;
  - missing and unleased chunks receive zero bytes;
  - recovery pressure is derived from sequence gap/recovery counters;
  - stream usage never exceeds caps;
  - invalid caps/counters raise `ArgumentError`.
- [x] Implement `GateServer.Voxel.SyncBudget.plan/1`.
- [x] Verify:

```bat
cmd /c mix.bat test apps/gate_server/test/gate_server/voxel/sync_budget_test.exs
```

## Task 2: CLI Observe Smoke

- [x] Write failing `gate_server.sync_budget_observe` test.
- [x] Implement the Mix task:
  - seed an isolated World `MapLedger`;
  - request a partition window;
  - build a sample Gate budget with recovery counters and chunk backlogs;
  - emit `gate_sync_budget_window`;
  - print a compact summary.
- [x] Verify:

```bat
cmd /c mix.bat test apps/gate_server/test/mix/tasks/gate_server_sync_budget_observe_test.exs
cmd /c mix.bat gate_server.sync_budget_observe --observe-dir .demo/observe
```

## Task 3: Docs and Regression

- [x] Add Gate voxel README explaining:
  - Gate owns per-client budget state;
  - World owns routing/lease truth;
  - Scene owns payload/version truth;
  - this v1 planner does not enforce throttling yet.
- [x] Integrate the shared planner into `WsConnection` and `TcpConnection`
  subscribe paths without adding protocol frames:
  - Gate fetches one best-effort `MapLedger.route_window_with_leases/4` result per subscribe request;
  - missing / unleased halo chunks are skipped with observable reasons;
  - assigned near/halo chunks still subscribe through Scene;
  - `voxel_subscription_window_planned` logs and `voxel_transport` debug fields expose plan state.
- [x] Run focused regression:

```bat
cmd /c mix.bat test apps/gate_server/test/gate_server/voxel/sync_budget_test.exs apps/gate_server/test/mix/tasks/gate_server_sync_budget_observe_test.exs apps/world_server/test/mix/tasks/world_server_partition_observe_test.exs apps/world_server/test/world_server/voxel/partition_window_test.exs apps/world_server/test/world_server/voxel/map_ledger_test.exs
cmd /c mix.bat compile --warnings-as-errors
git diff --check
```

## Follow-On Work

- Track confirmed chunk versions instead of the current debug placeholder.
- Add live throttling and resync/fallback behavior once budget plans are visible.
- Replace the current O(N) `route_window_with_leases/4` implementation with a World indexed route table.
- Feed Chat v1 `region_id` / `chunk_coord` from World partition and
  server-authoritative movement boundary events instead of the current v1
  session registration placeholder.
