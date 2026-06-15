defmodule WorldServer.Voxel.DevSeedTest do
  use ExUnit.Case, async: true

  alias DataService.Voxel.WriteTokenStore
  alias WorldServer.Voxel.DevSeed
  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.SceneNodeRegistry

  defmodule FakeChunkDirectory do
    @moduledoc false
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, [])

    def calls(pid), do: GenServer.call(pid, :calls)

    @impl true
    def init(_opts), do: {:ok, %{calls: []}}

    @impl true
    def handle_call({:apply_intent, attrs}, _from, state) do
      reply =
        {:ok,
         %{
           logical_scene_id: attrs.logical_scene_id,
           chunk_coord: attrs.chunk_coord,
           chunk_version: length(state.calls) + 1,
           operation: attrs.operation,
           macro: attrs.macro
         }}

      {:reply, reply, %{state | calls: [attrs | state.calls]}}
    end

    def handle_call({:apply_intents, attrs_list}, _from, state) do
      next_calls = Enum.reverse(attrs_list) ++ state.calls

      reply =
        {:ok,
         %{
           logical_scene_id: hd(attrs_list).logical_scene_id,
           chunk_coord: hd(attrs_list).chunk_coord,
           chunk_version: length(state.calls) + length(attrs_list),
           changed_count: length(attrs_list),
           skipped_count: 0,
           changed?: attrs_list != []
         }}

      {:reply, reply, %{state | calls: next_calls}}
    end

    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}
  end

  test "creates an idempotent browser dev region and publishes its lease" do
    token_store = WriteTokenStore
    ledger_name = :"dev_seed_ledger_#{System.unique_integer([:positive])}"
    ledger = start_supervised!({MapLedger, name: ledger_name, write_token_store: token_store})

    assert {:ok, created} =
             DevSeed.ensure_default_region(
               ledger: ledger,
               logical_scene_id: 88,
               region_id: 880_001,
               center_chunk: {0, 0, 0},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    assert created.status == :created
    assert created.logical_scene_id == 88
    assert created.region_id == 880_001
    assert created.bounds_chunk_min == [-2, -2, -2]
    assert created.bounds_chunk_max == [3, 3, 3]

    assert {:ok, route} = MapLedger.route_chunk_with_lease(ledger, 88, {0, 0, 0})
    assert route.assignment.region_id == 880_001
    assert route.lease.lease_id == created.lease_id

    assert {:ok, renewed} =
             DevSeed.ensure_default_region(
               ledger: ledger,
               logical_scene_id: 88,
               region_id: 880_001,
               center_chunk: {0, 0, 0},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    assert renewed.status == :renewed
    assert renewed.lease_id != created.lease_id
    assert renewed.owner_epoch > created.owner_epoch

    assert {:ok, renewed_route} = MapLedger.route_chunk_with_lease(ledger, 88, {0, 0, 0})
    assert renewed_route.lease.lease_id == renewed.lease_id
  end

  test "uses the ledger scene node registry when no explicit owner is supplied" do
    token_store = WriteTokenStore
    registry_name = :"dev_seed_scene_registry_#{System.unique_integer([:positive])}"
    registry = start_supervised!({SceneNodeRegistry, name: registry_name})
    scene_node = :"scene_dev_seed_#{System.unique_integer([:positive])}@example"
    :ok = SceneNodeRegistry.register_scene_node(registry, scene_node)

    ledger_name = :"dev_seed_registry_ledger_#{System.unique_integer([:positive])}"

    ledger =
      start_supervised!(
        {MapLedger,
         name: ledger_name, write_token_store: token_store, scene_node_registry: registry}
      )

    assert {:ok, created} =
             DevSeed.ensure_default_region(
               ledger: ledger,
               logical_scene_id: 89,
               region_id: 890_001,
               center_chunk: {0, 0, 0},
               seed_terrain?: false
             )

    assert created.status == :created
    assert {:ok, route} = MapLedger.route_chunk_with_lease(ledger, 89, {0, 0, 0})
    assert route.assignment.assigned_scene_node == scene_node
    assert SceneNodeRegistry.lookup_assignment(registry, 890_001) == {:ok, scene_node}
  end

  test "seeds the multi-chunk starter platform and demo circuit through chunk_directory.apply_intents" do
    token_store = WriteTokenStore
    ledger_name = :"dev_seed_terrain_ledger_#{System.unique_integer([:positive])}"
    ledger = start_supervised!({MapLedger, name: ledger_name, write_token_store: token_store})
    {:ok, fake_dir} = FakeChunkDirectory.start_link()

    assert {:ok, created} =
             DevSeed.ensure_default_region(
               ledger: ledger,
               logical_scene_id: 91,
               region_id: 910_001,
               center_chunk: {0, 0, 0},
               assigned_scene_node: node(),
               chunk_directory: fake_dir
             )

    assert created.status == :created
    terrain = created.terrain
    assert terrain != nil
    # Default platform footprint = 5×5 horizontal chunks (x,z ∈ -2..2, y = 0).
    expected_platform_chunks =
      for cx <- -2..2, cz <- -2..2, into: MapSet.new(), do: {cx, 0, cz}

    assert terrain.chunk_count == 25
    # chunk_coord stays the center chunk for back-compat.
    assert terrain.chunk_coord == [0, 0, 0]
    assert terrain.platform_attempted == 25 * 256
    assert terrain.demo_circuit_attempted == 10
    # 25 chunks × 256 platform cells + 10 circuit cells (center only) = 6410.
    assert terrain.attempted == 25 * 256 + 10
    assert terrain.written == 25 * 256 + 10
    assert terrain.errors == 0
    assert terrain.chunk_errors == []

    calls = FakeChunkDirectory.calls(fake_dir)
    assert length(calls) == 25 * 256 + 10

    # Every platform chunk was seeded, all under the region lease.
    seeded_chunks = calls |> Enum.map(& &1.chunk_coord) |> MapSet.new()
    assert seeded_chunks == expected_platform_chunks

    Enum.each(calls, fn attrs ->
      assert attrs.logical_scene_id == 91
      assert attrs.operation == :put_solid_block
      assert attrs.lease.lease_id == created.lease_id
    end)

    # Each chunk gets the full 16×16 bottom-slab platform (material 1, y-macro 0).
    expected_platform_macros =
      for mx <- 0..15, mz <- 0..15, into: MapSet.new(), do: {mx, 0, mz}

    calls_by_chunk = Enum.group_by(calls, & &1.chunk_coord)

    Enum.each(expected_platform_chunks, fn chunk_coord ->
      chunk_calls = Map.fetch!(calls_by_chunk, chunk_coord)
      platform_macros = chunk_calls |> Enum.map(& &1.macro) |> MapSet.new()
      assert MapSet.subset?(expected_platform_macros, platform_macros)

      Enum.each(chunk_calls, fn attrs ->
        if attrs.macro in expected_platform_macros do
          assert attrs.block.material_id == 1
        end
      end)
    end)

    # The demo circuit is only on the center chunk (one macro above the slab).
    expected_circuit_materials = %{
      {6, 1, 6} => 6,
      {7, 1, 6} => 5,
      {8, 1, 6} => 7,
      {9, 1, 6} => 5,
      {9, 1, 7} => 5,
      {9, 1, 8} => 5,
      {8, 1, 8} => 5,
      {7, 1, 8} => 5,
      {6, 1, 8} => 5,
      {6, 1, 7} => 5
    }

    center_by_macro =
      calls_by_chunk
      |> Map.fetch!({0, 0, 0})
      |> Map.new(fn attrs -> {attrs.macro, attrs.block.material_id} end)

    Enum.each(expected_circuit_materials, fn {macro, material_id} ->
      assert center_by_macro[macro] == material_id
    end)

    # Non-center chunks carry no circuit (only y-macro 0 platform cells).
    Enum.each(MapSet.delete(expected_platform_chunks, {0, 0, 0}), fn chunk_coord ->
      ys = calls_by_chunk |> Map.fetch!(chunk_coord) |> Enum.map(fn a -> elem(a.macro, 1) end)
      assert Enum.all?(ys, &(&1 == 0))
    end)
  end

  test "returns a JSON-safe terrain error when the scene chunk directory is unavailable" do
    token_store = WriteTokenStore
    ledger_name = :"dev_seed_unavailable_ledger_#{System.unique_integer([:positive])}"
    ledger = start_supervised!({MapLedger, name: ledger_name, write_token_store: token_store})

    assert {:ok, created} =
             DevSeed.ensure_default_region(
               ledger: ledger,
               logical_scene_id: 92,
               region_id: 920_001,
               center_chunk: {0, 0, 0},
               assigned_scene_node: node(),
               chunk_directory: :missing_dev_seed_chunk_directory
             )

    # Every platform chunk's apply_intents exits (no such directory); each is
    # isolated into a per-chunk error so the summary stays JSON-safe.
    assert created.terrain.errors == 25
    assert created.terrain.written == 0
    assert length(created.terrain.chunk_errors) == 25

    assert Enum.all?(created.terrain.chunk_errors, fn entry ->
             is_list(entry.chunk_coord) and is_binary(entry.error) and
               entry.error =~ "scene_unavailable"
           end)

    assert {:ok, _json} = Jason.encode(created)
  end
end
