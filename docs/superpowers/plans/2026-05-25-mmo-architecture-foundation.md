# MMO Architecture Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first server-authoritative MMO partition primitive that future seamless movement, voxel sync budgets, and chat routing can share.

**Architecture:** Keep World as the control-plane owner. Add a pure partition-window builder and a read-only `MapLedger` API, then expose it through a CLI observe task. Do not move chunk truth, actor truth, or chat state into World.

**Tech Stack:** Elixir/OTP umbrella, ExUnit, existing `WorldServer.CliObserve`, existing `WorldServer.Voxel.MapLedger`, existing voxel region assignment and lease structs.

**Boundary constraints:**
- `partition_window` is a read-only projection over existing `MapLedger`,
  `RegionAssignment`, `SceneLease`, and `MigrationPlan` data. It is not a new
  routing source of truth.
- The first implementation is control-plane and CLI/debug only. It may reuse the
  current partition-window shape, but World routing reads now use a derived
  `RouteIndex` so Gate hot-path subscription planning does not have to fall back
  to scanning every region assignment.
- Gate consumes World partition decisions; it does not invent partition tiers.
- Scene owns hot chunk and actor truth, but not world chat truth.
- DataService writes and Rust acceleration stay outside the live routing
  decision path.

---

## File Structure

- Create `apps/world_server/lib/world_server/voxel/partition_window.ex`
  - Pure functions for chunk-window geometry, route classification, and summary formatting.
- Modify `apps/world_server/lib/world_server/voxel/map_ledger.ex`
  - Add a read-only `partition_window/4` public API and route reads through a
    derived index.
- Create `apps/world_server/lib/world_server/voxel/route_index.ex`
  - Derived bucket-grid route index over active region assignments.
- Create `apps/world_server/lib/mix/tasks/world_server.partition_observe.ex`
  - CLI smoke task that builds a sample partition ledger and writes observe logs.
- Modify `apps/world_server/lib/world_server/voxel/README.md`
  - Document the partition window boundary and why it is read-only.
- Test `apps/world_server/test/world_server/voxel/partition_window_test.exs`
  - Pure geometry and classification tests.
- Test `apps/world_server/test/world_server/voxel/route_index_test.exs`
  - Index routing, scene isolation, overlap rejection, and stats tests.
- Modify `apps/world_server/test/world_server/voxel/map_ledger_test.exs`
  - Integration coverage for `MapLedger.partition_window/4`.
- Test `apps/world_server/test/mix/tasks/world_server_partition_observe_test.exs`
  - CLI task smoke output and observe log checks.

## Task 1: Pure Partition Window

**Files:**
- Create: `apps/world_server/lib/world_server/voxel/partition_window.ex`
- Test: `apps/world_server/test/world_server/voxel/partition_window_test.exs`

- [x] **Step 1: Write the failing pure geometry test**

Create `apps/world_server/test/world_server/voxel/partition_window_test.exs`:

```elixir
defmodule WorldServer.Voxel.PartitionWindowTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.PartitionWindow

  test "builds near and halo chunk sets around a center chunk" do
    window =
      PartitionWindow.build(%{
        logical_scene_id: 1,
        center_chunk: {10, 0, 10},
        near_radius: 1,
        halo_radius: 2,
        routes: %{}
      })

    assert window.logical_scene_id == 1
    assert window.center_chunk == {10, 0, 10}
    assert length(window.near_chunks) == 27
    assert length(window.halo_chunks) == 98
    assert {10, 0, 10} in window.near_chunks
    assert {12, 0, 10} in window.halo_chunks
    refute {12, 0, 10} in window.near_chunks
  end
end
```

- [x] **Step 2: Run the test and verify RED**

Run:

```bat
cmd /c mix.bat test apps/world_server/test/world_server/voxel/partition_window_test.exs
```

Expected: failure because `WorldServer.Voxel.PartitionWindow` is not defined.

- [x] **Step 3: Implement minimal geometry**

Create `apps/world_server/lib/world_server/voxel/partition_window.ex` with:

```elixir
defmodule WorldServer.Voxel.PartitionWindow do
  @moduledoc """
  Pure read-only builder for MMO world-partition interest windows.

  The module owns no process state. WorldServer uses it to turn region routes
  and lease summaries into near/halo/missing chunk plans for CLI, Gate, AOI,
  and future sync-budget scheduling.
  """

  @type chunk_coord :: {integer(), integer(), integer()}

  @doc "Builds a partition interest window from precomputed route data."
  def build(attrs) when is_map(attrs) do
    logical_scene_id = Map.fetch!(attrs, :logical_scene_id)
    center_chunk = coord!(Map.fetch!(attrs, :center_chunk))
    near_radius = non_negative_int!(Map.get(attrs, :near_radius, 1), :near_radius)
    halo_radius = non_negative_int!(Map.get(attrs, :halo_radius, near_radius), :halo_radius)

    if halo_radius < near_radius do
      raise ArgumentError, "halo_radius must be greater than or equal to near_radius"
    end

    near_chunks = cube(center_chunk, near_radius)
    all_chunks = cube(center_chunk, halo_radius)
    halo_chunks = all_chunks -- near_chunks

    %{
      logical_scene_id: logical_scene_id,
      center_chunk: center_chunk,
      near_radius: near_radius,
      halo_radius: halo_radius,
      near_chunks: near_chunks,
      halo_chunks: halo_chunks,
      routes: Map.get(attrs, :routes, %{}),
      region_summaries: [],
      missing_chunks: []
    }
  end

  defp cube({cx, cy, cz}, radius) do
    for x <- (cx - radius)..(cx + radius),
        y <- (cy - radius)..(cy + radius),
        z <- (cz - radius)..(cz + radius),
        do: {x, y, z}
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end

  defp non_negative_int!(value, name) when is_integer(value) and value >= 0, do: value

  defp non_negative_int!(value, name) do
    raise ArgumentError, "#{name} must be a non-negative integer, got: #{inspect(value)}"
  end
end
```

- [x] **Step 4: Run the pure test and verify GREEN**

Run the same command. Expected: `1 test, 0 failures`.

## Task 2: Route Classification and MapLedger API

**Files:**
- Modify: `apps/world_server/lib/world_server/voxel/partition_window.ex`
- Modify: `apps/world_server/lib/world_server/voxel/map_ledger.ex`
- Modify: `apps/world_server/test/world_server/voxel/partition_window_test.exs`
- Modify: `apps/world_server/test/world_server/voxel/map_ledger_test.exs`

- [x] **Step 1: Write failing classification tests**

Append this test to `apps/world_server/test/world_server/voxel/partition_window_test.exs`:

```elixir
test "classifies routed and missing chunks by tier and summarizes regions" do
  routes = %{
    {0, 0, 0} => %{
      assignment: %{
        region_id: 10,
        assigned_scene_node: :scene_a@local
      },
      lease: %{lease_id: 100}
    },
    {1, 0, 0} => %{
      assignment: %{
        region_id: 20,
        assigned_scene_node: :scene_b@local
      },
      lease: %{lease_id: 200}
    }
  }

  window =
    PartitionWindow.build(%{
      logical_scene_id: 1,
      center_chunk: {0, 0, 0},
      near_radius: 0,
      halo_radius: 1,
      routes: routes
    })

  assert [%{chunk_coord: {0, 0, 0}, tier: :near, status: :routed, region_id: 10}] =
           Enum.filter(window.route_entries, &(&1.tier == :near))

  assert %{chunk_coord: {1, 0, 0}, tier: :halo, status: :routed, region_id: 20} in window.route_entries
  assert %{chunk_coord: {-1, -1, -1}, tier: :halo, status: :missing, region_id: nil} in window.route_entries
  assert {-1, -1, -1} in window.missing_chunks

  assert %{region_id: 10, lease_id: 100, near_count: 1, halo_count: 0} in window.region_summaries
  assert %{region_id: 20, lease_id: 200, near_count: 0, halo_count: 1} in window.region_summaries
end
```

- [x] **Step 2: Verify RED**

Run:

```bat
cmd /c mix.bat test apps/world_server/test/world_server/voxel/partition_window_test.exs
```

Expected: failure because classification is not implemented.

- [x] **Step 3: Implement classification in `PartitionWindow.build/1`**

Add route classification without side effects. Implement helpers equivalent to:

```elixir
route_entries =
  (Enum.map(near_chunks, &entry_for(&1, :near, routes)) ++
     Enum.map(halo_chunks, &entry_for(&1, :halo, routes)))
  |> Enum.sort_by(fn %{chunk_coord: {x, y, z}, tier: tier} -> {tier_sort(tier), x, y, z} end)

missing_chunks =
  route_entries
  |> Enum.filter(&(&1.status == :missing))
  |> Enum.map(& &1.chunk_coord)

region_summaries =
  route_entries
  |> Enum.filter(&(&1.status == :routed))
  |> Enum.group_by(& &1.region_id)
  |> Enum.map(fn {region_id, entries} ->
    first = hd(entries)

    %{
      region_id: region_id,
      lease_id: first.lease_id,
      assigned_scene_node: first.assigned_scene_node,
      near_count: Enum.count(entries, &(&1.tier == :near)),
      halo_count: Enum.count(entries, &(&1.tier == :halo))
    }
  end)
  |> Enum.sort_by(& &1.region_id)
```

`entry_for/3` must tolerate both struct and plain-map route data from
`MapLedger`, because unit tests can pass lightweight maps while integration
tests pass real `RegionAssignment` and `SceneLease` structs.

- [x] **Step 4: Add failing `MapLedger.partition_window/4` test**

Add a test to `map_ledger_test.exs` that starts a ledger, puts two adjacent
regions, issues leases, then calls:

```elixir
MapLedger.partition_window(ledger, 1, {1, 0, 0}, near_radius: 0, halo_radius: 1)
```

Assert the center chunk is near, adjacent chunks include both region IDs, and
unassigned chunks are listed as missing. Also call `MapLedger.snapshot/1`
before and after and assert assignments, leases, and migrations are unchanged.

- [x] **Step 5: Implement `MapLedger.partition_window/4`**

Add public function:

```elixir
def partition_window(server \\ __MODULE__, logical_scene_id, center_chunk, opts \\ []) do
  GenServer.call(server, {:partition_window, logical_scene_id, center_chunk, opts})
end
```

In the handler, call a new pure helper such as
`PartitionWindow.candidate_chunks(center_chunk, halo_radius)` to get all chunks
that need route metadata. For each candidate chunk:

```elixir
case route_chunk_in_state(state, logical_scene_id, chunk_coord) do
  {:ok, assignment} ->
    lease =
      case fetch_region_lease(state, assignment.region_id) do
        {:ok, lease} -> lease
        {:error, _reason} -> nil
      end

    Map.put(acc, chunk_coord, %{assignment: assignment, lease: lease})

  {:error, :unassigned_chunk} ->
    acc
end
```

Unknown logical scenes and unassigned chunks should become missing entries
inside the window, not hard errors. This handler must return `{:reply, {:ok,
window}, state}` and must not call `maybe_persist_state/1` with changed state.
Do not add persistence, DataService reads, subscription writes, or Scene calls
to this path. This API is a World read model only.

- [x] **Step 6: Verify World tests**

Run:

```bat
cmd /c mix.bat test apps/world_server/test/world_server/voxel/partition_window_test.exs apps/world_server/test/world_server/voxel/map_ledger_test.exs
```

Expected: all tests pass.

## Task 3: CLI Observe Smoke

**Files:**
- Create: `apps/world_server/lib/mix/tasks/world_server.partition_observe.ex`
- Test: `apps/world_server/test/mix/tasks/world_server_partition_observe_test.exs`

- [x] **Step 1: Write failing CLI smoke test**

The test should call:

```elixir
Mix.Tasks.WorldServer.PartitionObserve.run([
  "--observe-log",
  observe_log,
  "--logical-scene-id",
  "1",
  "--center",
  "1,0,0",
  "--near-radius",
  "0",
  "--halo-radius",
  "1"
])
```

Assert stdout contains `partition_window`, and `observe_log` contains a
structured `world_partition_window` event with near/halo/missing counts.

- [x] **Step 2: Verify RED**

Run:

```bat
cmd /c mix.bat test apps/world_server/test/mix/tasks/world_server_partition_observe_test.exs
```

Expected: failure because the task is not defined.

- [x] **Step 3: Implement the Mix task**

The task should start an isolated in-memory `MapLedger`, seed two sample
regions and leases, call `MapLedger.partition_window/4`, emit
`WorldServer.CliObserve` event `world_partition_window`, and print a compact
summary.

- [x] **Step 4: Verify CLI smoke**

Run the test file again. Expected: pass.

Also run manually:

```bat
cmd /c mix.bat world_server.partition_observe --observe-dir .demo/observe
```

Expected: console summary and a `.demo/observe/world-partition-window-*.log`
file.

## Task 4: Documentation and Focused Verification

**Files:**
- Modify: `apps/world_server/lib/world_server/voxel/README.md`
- Modify: `docs/superpowers/specs/2026-05-25-mmo-architecture-foundation-design.md`

- [x] **Step 1: Document runtime boundary**

Add a short section explaining that partition windows are World control-plane
read models. They may drive Gate subscription planning, AOI halo queries, and
sync budgets, but they must not mutate Scene chunks or actor state.

- [x] **Step 2: Run focused tests**

```bat
cmd /c mix.bat test apps/world_server/test/world_server/voxel/partition_window_test.exs apps/world_server/test/world_server/voxel/map_ledger_test.exs apps/world_server/test/mix/tasks/world_server_partition_observe_test.exs
```

- [x] **Step 3: Compile with warnings as errors**

```bat
cmd /c mix.bat compile --warnings-as-errors
```

- [x] **Step 4: Check diff hygiene**

```bat
git diff --check
```

## Later Plans

Separate follow-up plans should cover:

- Sync Budget v1: per-client stream budget, near/mid/far voxel tiers, and
  recovery counters. Do not call geometry tiers a real sync budget until Gate
  has sequence, snapshot/resync, and recovery counters.
- Chat v1: world/local/system channels with durable append log and CLI smoke.
  Chat truth belongs in a dedicated runtime, not Scene AOI loops.
- Cross-region gameplay reliability matrix: classify damage, field effects,
  prefab placement, magic effects, and movement handoff as transactional,
  replayable/idempotent, or best-effort with observable drop reasons.
- Gate integration: use partition windows to plan chunk subscriptions and halo
  rebinding.
- Scene integration: boundary AOI plus target-scene halo/prewarm ownership.
