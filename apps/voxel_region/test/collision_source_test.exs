defmodule VoxelRegion.CollisionSourceTest do
  use ExUnit.Case, async: false

  alias MmoContracts.Voxel.{CanonicalDelta, CanonicalSnapshot, Codec, Payload}
  alias MmoContracts.VoxelMaterialCatalog, as: Catalog
  alias VoxelRegion.{Bake, CollisionSource, GeneratedStore, World}

  @box {{-1, 7, -1}, {1, 9, 1}}

  # Only delays source preparation; all bytes and classification still come from GeneratedStore.
  defmodule PreparingStore do
    defdelegate open(opts), to: GeneratedStore
    defdelegate content_version(store), to: GeneratedStore
    defdelegate world_dir(store), to: GeneratedStore
    defdelegate read(store, level, region), to: GeneratedStore
    defdelegate generated(store), to: GeneratedStore

    def ensure(store, level, region) do
      if Application.get_env(:voxel_region, :w1_prepare_barrier) == {level, region} do
        pid = Application.fetch_env!(:voxel_region, :w1_prepare_observer)
        send(pid, {:preparing, self()})

        receive do
          :continue -> :ok
        end
      end

      GeneratedStore.ensure(store, level, region)
    end
  end

  setup_all do
    template = Path.join(System.tmp_dir!(), "voxim_w1_#{System.unique_integer([:positive])}")
    File.mkdir_p!(template)
    manifest = Path.expand("../../../../Voxim/Docs/R6/runtime/s4_worldgen_manifest.json", __DIR__)
    manifest_path = Path.join(template, "manifest.json")
    data = manifest |> File.read!() |> Jason.decode!() |> Map.put("world_half_extent_m", 64)
    File.write!(manifest_path, Jason.encode!(data))
    {:ok, store} = GeneratedStore.open(root: template, manifest_path: manifest_path)
    {:ok, _, _} = Bake.run(store)
    on_exit(fn -> File.rm_rf!(template) end)
    {:ok, template: template, cv: store.content_version}
  end

  setup %{template: template} do
    root = template <> "_#{System.unique_integer([:positive])}"
    File.cp_r!(template, root)

    world =
      start_supervised!(
        {World,
         source: PreparingStore,
         root: root,
         manifest_path: Path.join(root, "manifest.json"),
         name: :w1_canonical_world}
      )

    on_exit(fn ->
      Application.delete_env(:voxel_region, :w1_prepare_barrier)
      Application.delete_env(:voxel_region, :w1_prepare_observer)
      File.rm_rf!(root)
    end)

    {:ok, world: world, root: root}
  end

  test "eight complete canonical regions and 512 chunks match actual serve cell by cell", %{
    world: world,
    cv: cv
  } do
    assert {:ok, 1} = World.apply_edits(world, [{{40, 558, 40}, 11}, {{-1, 559, -1}, 12}])
    {elapsed, snapshot} = :timer.tc(fn -> snapshot(world) end)

    assert %CanonicalSnapshot{
             transaction_seq: 1,
             content_version: ^cv,
             l0_min: {-1, 7, -1},
             l0_max_exclusive: {1, 9, 1}
           } = snapshot

    assert length(snapshot.regions) == 8
    assert length(snapshot.chunks) == 512
    assert snapshot.chunks == Enum.sort_by(snapshot.chunks, & &1.coord)
    assert Enum.sum(Enum.map(snapshot.chunks, &byte_size(&1.cells))) == 2_097_152

    for {coord, bytes} <- snapshot.regions do
      {:ok, payload} = Payload.decode(bytes)
      assert payload.seq == 1
      served = serve(world, coord)
      assert payload.cells == served.cells
      assert payload.records == served.records
      assert payload.maps == served.maps

      for chunk <- snapshot.chunks, region_of(chunk.origin_m) == coord do
        assert chunk.n == 16 and chunk.scale_m == 1.0
        {ox, oy, oz} = chunk.origin_m

        expected =
          for z <- 0..15, y <- 0..15, x <- 0..15, into: <<>> do
            material =
              Payload.material(
                served,
                Payload.local(coord, {trunc(ox) + x, trunc(oy) + y, trunc(oz) + z})
              )

            <<if(Catalog.blocks_movement?(material), do: 1, else: 0)>>
          end

        assert chunk.cells == expected
      end
    end

    IO.puts(
      "W1_BASELINE " <>
        Jason.encode!(%{
          elapsed_us: elapsed,
          chunks: length(snapshot.chunks),
          occupancy_bytes: 2_097_152,
          payload_bytes: Enum.sum(Enum.map(snapshot.regions, &byte_size(elem(&1, 1)))),
          immutable_term_bytes: :erlang.external_size(snapshot),
          content_version: cv
        })
    )
  end

  test "preparation precedes one World barrier and repeated join preserves ordered subscription",
       %{world: world} do
    assert {:ok, 1} = World.apply_edits(world, [{{40, 558, 40}, 11}])
    snapshot(world)
    Application.put_env(:voxel_region, :w1_prepare_barrier, {0, {-1, 7, -1}})
    Application.put_env(:voxel_region, :w1_prepare_observer, self())
    subscriber = self()
    request = make_ref()

    task =
      Task.async(fn ->
        World.canonical_snapshot_and_subscribe(world, @box, subscriber, request)
      end)

    assert_receive {:preparing, preparing}, 10_000
    assert {:ok, 2} = World.apply_edits(world, [{{40, 558, 40}, 0}])
    send(preparing, :continue)
    assert :ok = Task.await(task, 300_000)
    assert {:ok, 3} = World.apply_edits(world, [{{40, 558, 40}, 11}])
    assert_receive {:canonical_delta, %CanonicalDelta{transaction_seq: 2}}, 10_000

    assert_receive {:canonical_snapshot, ^request,
                    %CanonicalSnapshot{transaction_seq: 2} = baseline}

    assert occupancy_at(baseline.chunks, {40, 558, 40}) == 0
    assert_receive {:canonical_delta, %CanonicalDelta{transaction_seq: 3}}
    refute_receive {:canonical_delta, _}
  end

  test "same-chunk N+1/N+2 and cross-chunk transactions keep full immutable intermediate cores",
       %{world: world} do
    initial = snapshot(world)
    assert {:ok, 1} = World.apply_edits(world, [{{40, 558, 40}, 11}])
    assert {:ok, 2} = World.apply_edits(world, [{{40, 558, 40}, 0}])
    assert {:ok, 3} = World.apply_edits(world, [{{40, 558, 40}, 12}, {{-1, 558, -1}, 11}])
    assert_receive {:canonical_delta, %CanonicalDelta{transaction_seq: 1, chunks: [first]} = d1}
    assert_receive {:canonical_delta, %CanonicalDelta{transaction_seq: 2, chunks: [second]} = d2}
    assert_receive {:canonical_delta, %CanonicalDelta{transaction_seq: 3, chunks: third} = d3}
    assert first.coord == second.coord
    assert byte_size(first.cells) == 4096 and byte_size(second.cells) == 4096
    assert occupancy_at([first], {40, 558, 40}) == 1
    assert occupancy_at([second], {40, 558, 40}) == 0
    assert occupancy_at(initial.chunks, {40, 558, 40}) == 0
    assert Enum.map(third, & &1.coord) == [{-1, 34, -1}, {2, 34, 2}]
    assert occupancy_at(third, {-1, 558, -1}) == 1
    assert Enum.map([d1, d2, d3], & &1.transaction) == World.entries_after(world, 0)
  end

  test "no-op has no sequence, water/air and solid material swaps have no collision update", %{
    world: world
  } do
    snapshot(world)
    assert {:ok, 0} = World.apply_edits(world, [{{40, 558, 40}, 0}])
    refute_receive {:canonical_delta, _}
    water = Catalog.table() |> Enum.find(&(&1["name"] == "water")) |> Map.fetch!("id")
    assert {:ok, 1} = World.apply_edits(world, [{{40, 558, 40}, water}])
    assert_receive {:canonical_delta, %CanonicalDelta{transaction_seq: 1, chunks: []}}
    assert {:ok, 2} = World.apply_edits(world, [{{40, 558, 40}, 0}])
    assert_receive {:canonical_delta, %CanonicalDelta{transaction_seq: 2, chunks: []}}
    assert {:ok, 3} = World.apply_edit(world, {40, 558, 40}, 11)
    assert_receive {:canonical_delta, %CanonicalDelta{transaction_seq: 3, chunks: [_], transaction: txn}}
    assert {:ok, %{seq: 3, entries: [%{coord: {40, 558, 40}, material: 11}]}} =
             txn |> Codec.encode_transaction() |> IO.iodata_to_binary() |> Codec.decode_transaction()
    assert {:ok, 4} = World.apply_edit(world, {40, 558, 40}, 12)
    assert_receive {:canonical_delta, %CanonicalDelta{transaction_seq: 4, chunks: []}}
  end

  test "a dense region replacement captures complete cores and survives compact/reload", %{
    world: world,
    root: root
  } do
    baseline = snapshot(world)
    edits = for x <- 32..47, y <- 544..559, z <- 32..47, do: {{x, y, z}, 11}
    {elapsed, {:ok, 1}} = :timer.tc(fn -> World.apply_edits(world, edits) end)

    assert_receive {:canonical_delta,
                    %CanonicalDelta{transaction_seq: 1, chunks: [chunk], transaction: txn}},
                   10_000

    assert Enum.any?(txn.entries, &Map.has_key?(&1, :payload))
    assert chunk.coord == {2, 34, 2}
    assert chunk.cells == :binary.copy(<<1>>, 4096)
    refute Enum.find(baseline.chunks, &(&1.coord == chunk.coord)).cells == chunk.cells
    assert :ok = World.compact(world)
    :ok = stop_supervised(World)

    restored =
      start_supervised!(
        {World,
         source: GeneratedStore,
         root: root,
         manifest_path: Path.join(root, "manifest.json"),
         name: :w1_canonical_world}
      )

    after_reload = snapshot(restored)
    assert after_reload.transaction_seq == 1
    assert Enum.find(after_reload.chunks, &(&1.coord == chunk.coord)) == chunk
    payload = serve(restored, {0, 8, 0})
    assert CollisionSource.capture(payload, chunk.coord) == chunk

    IO.puts(
      "W1_DENSE " <>
        Jason.encode!(%{
          elapsed_us: elapsed,
          edits: length(edits),
          changed_chunks: 1,
          occupancy_bytes: byte_size(chunk.cells),
          transaction_bytes: IO.iodata_length(Codec.encode_transaction(txn))
        })
    )
  end

  test "out-of-box real commits retain the global transaction with no physical chunks", %{
    world: world
  } do
    snapshot(world)
    assert {:ok, 1} = World.apply_edits(world, [{{64, 10_000, 0}, 11}])

    assert_receive {:canonical_delta,
                    %CanonicalDelta{transaction_seq: 1, chunks: [], transaction: txn}}

    assert [txn] == World.entries_after(world, 0)
  end

  test "skin-only payload differences do not change projected occupancy", %{world: world} do
    payload = serve(world, {0, 8, 0})
    material = Payload.material(payload, {41, 47, 41})
    skins = MmoContracts.Voxel.Skins.uniform(11)

    bytes =
      Payload.encode(payload, %{{41, 47, 41} => {material, skins}}, 1, payload.content_version)

    assert {:ok, skin_changed} = Payload.decode(bytes)
    assert payload.cells == skin_changed.cells
    refute payload.records == skin_changed.records

    assert CollisionSource.capture(payload, {2, 34, 2}) ==
             CollisionSource.capture(skin_changed, {2, 34, 2})
  end

  test "corrupt GeneratedStore source cannot produce a successful partial baseline", %{
    world: world,
    root: root
  } do
    {:ok, store} =
      GeneratedStore.open(root: root, manifest_path: Path.join(root, "manifest.json"))

    coord =
      CollisionSource.regions(@box)
      |> Enum.find(&(GeneratedStore.classify(store, 0, &1) == :mixed))

    assert :ok = GeneratedStore.ensure(store, 0, coord)
    File.write!(GeneratedStore.path(store, 0, coord), "corrupt")
    request = make_ref()

    assert {:error, :canonical_incomplete} =
             World.canonical_snapshot_and_subscribe(world, @box, self(), request)

    refute_receive {:canonical_snapshot, ^request, _}
    assert World.seq(world) == 0
  end

  defp snapshot(world) do
    request = make_ref()
    assert :ok = World.canonical_snapshot_and_subscribe(world, @box, self(), request)
    assert_receive {:canonical_snapshot, ^request, snapshot}, 300_000
    snapshot
  end

  defp serve(world, coord) do
    request =
      Codec.encode_request(0, [%{level: 0, region: coord, have_seq: 0, have_hash: 0}])
      |> IO.iodata_to_binary()

    {:ok, reply} = World.serve(world, request)
    {:ok, _, [{:payload, 0, ^coord, bytes}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    {:ok, payload} = Payload.decode(bytes)
    payload
  end

  defp region_of({x, y, z}),
    do:
      {Integer.floor_div(trunc(x), 64), Integer.floor_div(trunc(y), 64),
       Integer.floor_div(trunc(z), 64)}

  defp occupancy_at(chunks, {x, y, z}) do
    coord = {Integer.floor_div(x, 16), Integer.floor_div(y, 16), Integer.floor_div(z, 16)}
    chunk = Enum.find(chunks, &(&1.coord == coord))

    :binary.at(
      chunk.cells,
      Integer.mod(x, 16) + 16 * (Integer.mod(y, 16) + 16 * Integer.mod(z, 16))
    )
  end
end
