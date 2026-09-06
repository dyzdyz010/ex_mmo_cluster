defmodule VoxelRegion.GeneratedStoreTest do
  use ExUnit.Case, async: false

  alias VoxelRegion.{Codec, GeneratedStore, Native, Payload, World}

  @manifest %{
    "schema" => "voxim-worldgen-v1",
    "kernel" => "worldgen_density_v3@1",
    "materials" => "voxim-palette-v1",
    "seed" => 1337,
    "min_height" => -200,
    "sea_level" => 326,
    "max_height" => 586,
    "soil_depth" => 4,
    "lowland_amplitude" => 381.77066,
    "mountain_amplitude" => 1223.743774,
    "cave_max_depth" => 96
  }

  setup do
    root =
      Path.join(System.tmp_dir!(), "voxel_region_generated_#{System.unique_integer([:positive])}")

    manifest_path = Path.join(root, "worldgen.json")
    File.mkdir_p!(root)
    File.write!(manifest_path, Jason.encode!(@manifest))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, manifest_path: manifest_path}
  end

  test "native returns the existing raw payload body", _context do
    assert Native.kernel_identity() ==
             "worldgen_density_v3@1+sha256:458c90dee61690c27ba0b1bfd4510414f65bf5bf8d7224bf2b4d12ba0961018e"

    raw = Native.generate_region(0, {0, 0, 0}, config())

    assert {:ok, payload} = Payload.decode_body(raw)
    assert byte_size(payload.cells) == 66 * 66 * 66 * 2
    assert Enum.all?(for <<material::16-little <- payload.cells>>, do: material in 0..23)
    assert raw == Native.generate_region(0, {0, 0, 0}, config())
  end

  test "manifest identity is deterministic and includes kernel, materials, and generation config",
       %{root: root, manifest_path: manifest_path} do
    {:ok, store} = GeneratedStore.open(root: root, manifest_path: manifest_path)

    assert GeneratedStore.content_version(store) == 0x9031_6F77_8095_9A9C

    for field <- [
          "materials",
          "seed",
          "min_height",
          "sea_level",
          "max_height",
          "soil_depth",
          "lowland_amplitude",
          "mountain_amplitude",
          "cave_max_depth"
        ] do
      changed = Map.update!(@manifest, field, &different/1)
      changed_path = Path.join(root, "#{field}.json")
      File.write!(changed_path, Jason.encode!(changed))
      {:ok, changed_store} = GeneratedStore.open(root: root, manifest_path: changed_path)

      refute GeneratedStore.content_version(changed_store) ==
               GeneratedStore.content_version(store)
    end

    refute GeneratedStore.content_version(
             "worldgen_density_v3@1+sha256:" <> String.duplicate("0", 64),
             @manifest["materials"],
             config()
           ) ==
             GeneratedStore.content_version(store)
  end

  test "invalid generation levels and overflowing canonical coordinates do not kill World", %{
    root: root,
    manifest_path: manifest_path
  } do
    {:ok, world} =
      World.start_link(
        source: GeneratedStore,
        root: root,
        manifest_path: manifest_path,
        name: :validated_world
      )

    for {level, region} <- [
          {6, {0, 0, 0}},
          {255, {0, 0, 0}},
          {5, {2_147_483_647, 0, 0}},
          {5, {-2_147_483_648, 0, 0}}
        ] do
      item = %{level: level, region: region, have_seq: 0, have_hash: 0}
      assert {:error, :invalid_request} = World.serve(:validated_world, request([item], 0))
      assert Process.alive?(world)
    end

    for coord <- [{2_147_483_647, 0, 0}, {-2_147_483_648, 0, 0}] do
      assert {:error, :invalid_coordinate} = World.apply_edit(:validated_world, coord, 1)

      assert {:error, :invalid_coordinate} =
               World.apply_edits(:validated_world, [{{0, 0, 0}, 1}, {coord, 1}])

      assert Process.alive?(world)
      assert World.seq(:validated_world) == 0
    end
  end

  test "a corrupt generated cache is rejected instead of published", %{
    root: root,
    manifest_path: manifest_path
  } do
    {:ok, store} = GeneratedStore.open(root: root, manifest_path: manifest_path)
    assert {:ok, bytes, _header} = GeneratedStore.read(store, 0, {0, 7, 0})
    path = GeneratedStore.path(store, 0, {0, 7, 0})
    prefix_size = byte_size(bytes) - 1
    <<prefix::binary-size(^prefix_size), last>> = bytes
    File.write!(path, prefix <> <<Bitwise.bxor(last, 1)>>)

    assert {:error, :invalid_cache} = GeneratedStore.read(store, 0, {0, 7, 0})
  end

  test "concurrent generators publish one complete cache without temporary files", %{
    root: root,
    manifest_path: manifest_path
  } do
    {:ok, store} = GeneratedStore.open(root: root, manifest_path: manifest_path)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :generate -> GeneratedStore.read(store, 0, {1, 7, 1})
          end
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :generate))
    results = Enum.map(tasks, &Task.await(&1, 30_000))
    assert [{:ok, bytes1, _header1}, {:ok, bytes2, _header2}] = results
    assert bytes1 == bytes2
    assert {:ok, _header, _raw} = Codec.decode_payload_body(bytes1)

    cache_dir = store |> GeneratedStore.path(0, {1, 7, 1}) |> Path.dirname()
    assert cache_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".tmp")) == []
  end

  test "a corrupt coarse cache aborts an edit without committing or broadcasting", %{
    root: root,
    manifest_path: manifest_path
  } do
    {:ok, world} =
      World.start_link(
        source: GeneratedStore,
        root: root,
        manifest_path: manifest_path,
        name: :corrupt_coarse_world
      )

    cv = World.content_version(:corrupt_coarse_world)
    region = {0, 7, 0}
    bytes = fetch_payload(:corrupt_coarse_world, cv, 0, region)
    {:ok, payload} = Payload.decode(bytes)

    surface_y =
      Enum.find(0..64, fn local_y ->
        Payload.material(payload, {33, local_y, 33}) != 0 and
          Payload.material(payload, {33, local_y + 1, 33}) == 0
      end)

    assert is_integer(surface_y)
    {origin_x, origin_y, origin_z} = Payload.origin(region)
    coord = {origin_x + 33, origin_y + surface_y, origin_z + 33}
    old_material = Payload.material(payload, {33, surface_y, 33})
    new_material = if old_material == 23, do: 22, else: 23
    l1_region = {div(elem(coord, 0), 128), div(elem(coord, 1), 128), div(elem(coord, 2), 128)}
    store = :sys.get_state(:corrupt_coarse_world).source_state
    assert {:ok, coarse, _header} = GeneratedStore.read(store, 1, l1_region)
    coarse_path = GeneratedStore.path(store, 1, l1_region)
    prefix_size = byte_size(coarse) - 1
    <<prefix::binary-size(^prefix_size), last>> = coarse
    File.write!(coarse_path, prefix <> <<Bitwise.bxor(last, 1)>>)

    :ok = World.subscribe(:corrupt_coarse_world, self(), 0, {{0, 0, 0}, {0, 7, 0}}, 0)
    assert {:error, :invalid_cache} = World.apply_edit(:corrupt_coarse_world, coord, new_material)
    assert Process.alive?(world)
    assert World.seq(:corrupt_coarse_world) == 0
    assert World.entries_after(:corrupt_coarse_world, 0) == []
    refute_receive {:voxel_log_entry_payload, _}, 100
  end

  test "an empty generated root serves, edits, restarts, and confirms unchanged", %{
    root: root,
    manifest_path: manifest_path
  } do
    opts = [source: GeneratedStore, root: root, manifest_path: manifest_path]
    {:ok, world} = World.start_link(Keyword.put(opts, :name, :generated_world))
    cv = World.content_version(:generated_world)

    region = {0, 7, 0}
    bytes0 = fetch_payload(:generated_world, cv, 0, region)
    assert {:ok, header0, raw0} = Codec.decode_payload_body(bytes0)
    assert {:ok, payload0} = Payload.decode_body(raw0)
    assert header0.seq == 0

    store = :sys.get_state(:generated_world).source_state
    cache_path = GeneratedStore.path(store, 0, region)
    File.rm!(cache_path)
    assert {:ok, ^bytes0, _header} = GeneratedStore.read(store, 0, region)

    surface_y =
      Enum.find(0..64, fn local_y ->
        Payload.material(payload0, {33, local_y, 33}) != 0 and
          Payload.material(payload0, {33, local_y + 1, 33}) == 0
      end)

    assert is_integer(surface_y)
    local = {33, surface_y, 33}
    {origin_x, origin_y, origin_z} = Payload.origin(region)
    coord = {origin_x + 33, origin_y + surface_y, origin_z + 33}
    old_material = Payload.material(payload0, local)
    new_material = if old_material == 23, do: 22, else: 23
    assert {:ok, 1} = World.apply_edit(:generated_world, coord, new_material)

    bytes1 = fetch_payload(:generated_world, cv, 0, region)
    assert {:ok, payload1} = Payload.decode(bytes1)
    assert Payload.material(payload1, local) == new_material

    GenServer.stop(world)
    {:ok, _world} = World.start_link(Keyword.put(opts, :name, :generated_world_restarted))
    assert World.seq(:generated_world_restarted) == 1

    request =
      request([%{level: 0, region: region, have_seq: 1, have_hash: payload_hash(bytes1)}], cv)

    assert {:ok, reply} = World.serve(:generated_world_restarted, request)
    assert {:ok, ^cv, [{:unchanged, 0, ^region}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
  end

  test "cold generation runs outside World, is shared by concurrent requesters, and warm serves hit the memory cache", %{
    root: root,
    manifest_path: manifest_path
  } do
    {:ok, _world} =
      World.start_link(source: GeneratedStore, root: root, manifest_path: manifest_path, name: :cold_world)

    cv = World.content_version(:cold_world)
    # L3 冷生成需要几百毫秒；两个请求者同时要同一块 + 各自一块。
    shared = %{level: 3, region: {0, 0, 0}, have_seq: 0, have_hash: 0}
    own = fn x -> %{level: 3, region: {x, 0, 0}, have_seq: 0, have_hash: 0} end

    tasks =
      for x <- [1, 2] do
        Task.async(fn -> World.serve(:cold_world, request([shared, own.(x)], cv)) end)
      end

    # 生成期间 World 本身不被阻塞：seq 调用在毫秒级返回。
    Process.sleep(50)
    {seq_us, 0} = :timer.tc(fn -> World.seq(:cold_world) end)
    assert seq_us < 100_000

    [{:ok, reply1}, {:ok, reply2}] = Enum.map(tasks, &Task.await(&1, 120_000))
    {:ok, ^cv, [{:payload, 3, {0, 0, 0}, bytes1}, {:payload, 3, {1, 0, 0}, _}]} = Codec.decode_reply(IO.iodata_to_binary(reply1))
    {:ok, ^cv, [{:payload, 3, {0, 0, 0}, bytes2}, {:payload, 3, {2, 0, 0}, _}]} = Codec.decode_reply(IO.iodata_to_binary(reply2))
    assert bytes1 == bytes2

    # 共享的那块只生成一次：三块三次 NIF 调用；World 串行应答时第二份请求的共享块已在缓存里。
    assert %{generated: 3, misses: 3, hits: 1, evictions: 0, entries: 3} = World.stats(:cold_world)

    # 暖请求：不再读盘、不再生成。
    {:ok, reply} = World.serve(:cold_world, request([shared, own.(1), own.(2)], cv))
    {:ok, ^cv, [{:payload, 3, {0, 0, 0}, ^bytes1}, {:payload, 3, {1, 0, 0}, _}, {:payload, 3, {2, 0, 0}, _}]} =
      Codec.decode_reply(IO.iodata_to_binary(reply))

    assert %{generated: 3, misses: 3, hits: 4} = World.stats(:cold_world)
  end

  @tag :oracle
  @tag timeout: 600_000
  test "native cells and logical skins match the independent UE oracle" do
    oracle_dir = System.fetch_env!("VOXIM_ORACLE_DIR")
    manifest = oracle_dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    fixtures = Map.fetch!(manifest, "fixtures")
    assert fixtures != []

    for fixture <- fixtures do
      [seed, min, sea, max, soil, lowland, mountain, cave] = Map.fetch!(fixture, "config")
      [x, y, z] = Map.fetch!(fixture, "coord")
      level = Map.fetch!(fixture, "level")
      config = {seed, min, sea, max, soil, lowland * 1.0, mountain * 1.0, cave}

      generated_raw = Native.generate_region(level, {x, y, z}, config)
      {:ok, generated} = Payload.decode_body(generated_raw)

      if output_dir = System.get_env("VOXIM_SERVER_PAYLOAD_DIR") do
        File.mkdir_p!(output_dir)

        File.write!(
          Path.join(output_dir, Map.fetch!(fixture, "file")),
          Codec.encode_payload(level, {x, y, z}, 0, 0, generated_raw)
        )
      end

      oracle_bytes = File.read!(Path.join(oracle_dir, Map.fetch!(fixture, "file")))
      {:ok, _header, oracle_raw} = Codec.decode_payload_body(oracle_bytes)
      {:ok, oracle} = Payload.decode_body(oracle_raw)

      assert generated.cells == oracle.cells, Map.fetch!(fixture, "file")

      for local <-
            Map.keys(generated.records) |> Enum.concat(Map.keys(oracle.records)) |> Enum.uniq() do
        material = Payload.material(generated, local)

        assert Payload.skins(generated, local, material) ==
                 Payload.skins(oracle, local, material),
               "#{Map.fetch!(fixture, "file")} at #{inspect(local)}"
      end
    end
  end

  defp config do
    {1337, -200, 326, 586, 4, 381.77066, 1223.743774, 96}
  end

  defp fetch_payload(server, cv, level, region) do
    item = %{level: level, region: region, have_seq: 0, have_hash: 0}
    {:ok, reply} = World.serve(server, request([item], cv))

    {:ok, ^cv, [{:payload, ^level, ^region, bytes}]} =
      Codec.decode_reply(IO.iodata_to_binary(reply))

    bytes
  end

  defp request(items, cv), do: IO.iodata_to_binary(Codec.encode_request(cv, items))

  defp payload_hash(bytes) do
    {:ok, header} = Codec.decode_payload_header(bytes)
    header.hash
  end

  defp different(value) when is_binary(value), do: value <> "-changed"
  defp different(value) when is_integer(value), do: value + 1
  defp different(value) when is_float(value), do: value + 0.5
end
