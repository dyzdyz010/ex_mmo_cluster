defmodule WorldServer.Voxel.DevSeedTest do
  # 阶段1:DevSeed 改隐式 grid 物化 + 写 voxel_write_tokens/voxel_region_epochs(共享表)。
  # 各 test 用互不相同的 logical_scene_id,region 行(键含 logical_scene_id)天然隔离,
  # 故仍可 async。
  use ExUnit.Case, async: true

  alias DataService.Voxel.WriteTokenStore
  alias WorldServer.Voxel.DevSeed
  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.SceneNodeRegistry
  alias WorldServer.Voxel.TerrainNoise

  @noise_opts [seed: 1337, min_height: 2, max_height: 8]

  defmodule FakeChunkDirectory do
    @moduledoc false
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, [])

    def calls(pid), do: GenServer.call(pid, :calls)

    @impl true
    def init(_opts), do: {:ok, %{calls: []}}

    @impl true
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

  # Starts a SceneNodeRegistry (with this node registered) + a MapLedger wired to
  # it, so the ensuring route can materialize grid regions.
  defp start_ledger_with_registry do
    registry =
      start_supervised!(
        {SceneNodeRegistry, name: :"dev_seed_registry_#{System.unique_integer([:positive])}"}
      )

    :ok = SceneNodeRegistry.register_scene_node(registry, node())

    ledger =
      start_supervised!(
        {MapLedger,
         name: :"dev_seed_ledger_#{System.unique_integer([:positive])}",
         write_token_store: WriteTokenStore,
         scene_node_registry: registry}
      )

    {ledger, registry}
  end

  defp region_for(regions, {cx, cy, cz}) do
    Enum.find(regions, fn r ->
      [minx, miny, minz] = r.bounds_chunk_min
      [maxx, maxy, maxz] = r.bounds_chunk_max
      cx >= minx and cx < maxx and cy >= miny and cy < maxy and cz >= minz and cz < maxz
    end)
  end

  test "materializes the spawn footprint on the implicit grid and is idempotent" do
    {ledger, _registry} = start_ledger_with_registry()

    assert {:ok, created} =
             DevSeed.ensure_default_region(
               ledger: ledger,
               logical_scene_id: 88,
               seed_terrain?: false
             )

    assert created.status == :ready
    assert created.logical_scene_id == 88
    # 5×5 footprint (x,z ∈ -2..2) straddles 2×2 = 4 grid regions under Sx=Sz=8.
    assert created.chunk_count == 25
    assert created.region_count == 4

    # Every footprint region is materialized, leased, and owned by this node.
    assert Enum.all?(created.regions, &(&1.assigned_scene_node == Atom.to_string(node())))
    assert Enum.all?(created.regions, &(&1.lease_id != nil))

    # Each footprint chunk now routes to its materialized region.
    assert {:ok, route} = MapLedger.route_chunk_with_lease(ledger, 88, {0, 0, 0})
    assert route.assignment.bounds_chunk_min == {0, 0, 0}
    assert route.assignment.bounds_chunk_max == {8, 64, 8}

    # Re-running reuses the same regions (idempotent, no churn).
    assert {:ok, again} =
             DevSeed.ensure_default_region(
               ledger: ledger,
               logical_scene_id: 88,
               seed_terrain?: false
             )

    assert again.region_count == 4

    assert Enum.map(again.regions, & &1.region_id) |> Enum.sort() ==
             Enum.map(created.regions, & &1.region_id) |> Enum.sort()
  end

  test "picks the region owner from the ledger's scene node registry" do
    registry =
      start_supervised!(
        {SceneNodeRegistry, name: :"dev_seed_owner_registry_#{System.unique_integer([:positive])}"}
      )

    scene_node = :"scene_dev_seed_#{System.unique_integer([:positive])}@example"
    :ok = SceneNodeRegistry.register_scene_node(registry, scene_node)

    ledger =
      start_supervised!(
        {MapLedger,
         name: :"dev_seed_owner_ledger_#{System.unique_integer([:positive])}",
         write_token_store: WriteTokenStore,
         scene_node_registry: registry}
      )

    assert {:ok, created} =
             DevSeed.ensure_default_region(
               ledger: ledger,
               logical_scene_id: 89,
               seed_terrain?: false
             )

    assert Enum.all?(created.regions, &(&1.assigned_scene_node == Atom.to_string(scene_node)))
    assert {:ok, route} = MapLedger.route_chunk_with_lease(ledger, 89, {0, 0, 0})
    assert route.assignment.assigned_scene_node == scene_node
  end

  test "fails (and seeds nothing) when no Scene node is registered to host a region" do
    registry =
      start_supervised!(
        {SceneNodeRegistry, name: :"dev_seed_empty_registry_#{System.unique_integer([:positive])}"}
      )

    ledger =
      start_supervised!(
        {MapLedger,
         name: :"dev_seed_empty_ledger_#{System.unique_integer([:positive])}",
         write_token_store: WriteTokenStore,
         scene_node_registry: registry}
      )

    assert {:error, :scene_node_unassigned} =
             DevSeed.ensure_default_region(ledger: ledger, logical_scene_id: 90)

    assert MapLedger.snapshot(ledger).assignments == %{}
  end

  test "seeds the multi-chunk noise-terrain heightmap through chunk_directory.apply_intents" do
    {ledger, _registry} = start_ledger_with_registry()
    {:ok, fake_dir} = FakeChunkDirectory.start_link()

    assert {:ok, created} =
             DevSeed.ensure_default_region(
               ledger: ledger,
               logical_scene_id: 91,
               chunk_directory: fake_dir
             )

    assert created.status == :ready
    terrain = created.terrain
    assert terrain != nil
    # Default footprint = 5×5 horizontal chunks (x,z ∈ -2..2, y = 0).
    expected_chunks = for cx <- -2..2, cz <- -2..2, into: MapSet.new(), do: {cx, 0, cz}

    # Total cells = sum of every column's noise height across all 25 chunks.
    expected_total =
      Enum.reduce(expected_chunks, 0, fn {cx, _cy, cz}, acc ->
        Enum.reduce(0..15, acc, fn mx, acc_mx ->
          Enum.reduce(0..15, acc_mx, fn mz, acc_mz ->
            acc_mz + TerrainNoise.height(cx * 16 + mx, cz * 16 + mz, @noise_opts)
          end)
        end)
      end)

    assert terrain.chunk_count == 25
    assert terrain.chunk_coord == [0, 0, 0]
    assert terrain.attempted == expected_total
    assert terrain.written == expected_total
    assert terrain.errors == 0
    assert terrain.chunk_errors == []

    calls = FakeChunkDirectory.calls(fake_dir)
    assert length(calls) == expected_total

    # Every terrain chunk was seeded.
    seeded_chunks = calls |> Enum.map(& &1.chunk_coord) |> MapSet.new()
    assert seeded_chunks == expected_chunks

    # Each chunk is written under ITS region's lease (the footprint spans 4 regions).
    Enum.each(calls, fn attrs ->
      assert attrs.logical_scene_id == 91
      assert attrs.operation == :put_solid_block
      region = region_for(created.regions, attrs.chunk_coord)
      assert region != nil
      assert attrs.lease.lease_id == region.lease_id
    end)

    # Sample chunk: every column is filled contiguously y=0..H-1, surface dirt
    # (material 1), everything below stone (material 2).
    sample = {0, 0, 0}
    sample_calls = Enum.filter(calls, &(&1.chunk_coord == sample))

    sample_calls
    |> Enum.group_by(fn a -> {elem(a.macro, 0), elem(a.macro, 2)} end)
    |> Enum.each(fn {{mx, mz}, col_calls} ->
      height = TerrainNoise.height(mx, mz, @noise_opts)
      ys = col_calls |> Enum.map(fn a -> elem(a.macro, 1) end) |> Enum.sort()
      assert ys == Enum.to_list(0..(height - 1))

      Enum.each(col_calls, fn a ->
        {_x, y, _z} = a.macro
        expected_material = if y == height - 1, do: 1, else: 2
        assert a.block.material_id == expected_material
      end)
    end)
  end

  test "returns a JSON-safe terrain error when the scene chunk directory is unavailable" do
    {ledger, _registry} = start_ledger_with_registry()

    assert {:ok, created} =
             DevSeed.ensure_default_region(
               ledger: ledger,
               logical_scene_id: 92,
               chunk_directory: :missing_dev_seed_chunk_directory
             )

    # Every footprint chunk's apply_intents exits (no such directory); each is
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
