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
    token_store = start_supervised!(WriteTokenStore)
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
    token_store = start_supervised!(WriteTokenStore)
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

  test "seeds the 16x16 starter platform through chunk_directory.apply_intent" do
    token_store = start_supervised!(WriteTokenStore)
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
    assert terrain.chunk_coord == [0, 0, 0]
    assert terrain.attempted == 256
    assert terrain.written == 256
    assert terrain.errors == 0

    calls = FakeChunkDirectory.calls(fake_dir)
    assert length(calls) == 256

    macros = calls |> Enum.map(& &1.macro) |> MapSet.new()

    expected_macros =
      for mx <- 0..15, mz <- 0..15, into: MapSet.new(), do: {mx, 0, mz}

    assert macros == expected_macros

    Enum.each(calls, fn attrs ->
      assert attrs.logical_scene_id == 91
      assert attrs.chunk_coord == {0, 0, 0}
      assert attrs.operation == :put_solid_block
      assert attrs.lease.lease_id == created.lease_id
      assert attrs.block.material_id == 1
    end)
  end

  test "returns a JSON-safe terrain error when the scene chunk directory is unavailable" do
    token_store = start_supervised!(WriteTokenStore)
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

    assert created.terrain.errors == 1
    assert is_binary(created.terrain.error)
    assert created.terrain.error =~ "scene_unavailable"
    assert {:ok, _json} = Jason.encode(created)
  end
end
