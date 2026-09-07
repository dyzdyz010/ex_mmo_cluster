defmodule VoxelRegion.GeneratedStoreTest do
  use ExUnit.Case, async: false

  alias VoxelRegion.{AssetPack, Bake, Codec, GeneratedStore, Native, Payload, World}
  alias MmoContracts.VoxelMaterialCatalog

  # 半边长 64 m：每级 2×2 列，L1–L5 烘一次（setup_all）后每个测试复制 baseline 目录。
  @manifest %{
    "schema" => "voxim-worldgen-v1",
    "kernel" => "worldgen_density_v3@1",
    "materials" => VoxelMaterialCatalog.table(),
    "world_half_extent_m" => 64,
    "seed" => 1337,
    "min_height" => -200,
    "sea_level" => 326,
    "max_height" => 586,
    "soil_depth" => 4,
    "lowland_amplitude" => 381.77066,
    "mountain_amplitude" => 1223.743774,
    "cave_max_depth" => 96
  }

  setup_all do
    template =
      Path.join(System.tmp_dir!(), "voxel_region_baked_#{System.unique_integer([:positive])}")

    manifest_path = Path.join(template, "worldgen.json")
    File.mkdir_p!(template)
    File.write!(manifest_path, Jason.encode!(@manifest))
    {:ok, store} = GeneratedStore.open(root: template, manifest_path: manifest_path)
    {:ok, store, stats} = Bake.run(store)
    on_exit(fn -> File.rm_rf!(template) end)
    {:ok, template: template, baked: store, bake_stats: stats}
  end

  setup %{template: template, baked: baked} do
    root =
      Path.join(System.tmp_dir!(), "voxel_region_generated_#{System.unique_integer([:positive])}")

    manifest_path = Path.join(root, "worldgen.json")
    File.mkdir_p!(root)
    File.write!(manifest_path, Jason.encode!(@manifest))

    File.cp_r!(
      Path.join(template, GeneratedStore.hex(baked.content_version)),
      Path.join(root, GeneratedStore.hex(baked.content_version))
    )

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, manifest_path: manifest_path}
  end

  test "bake enumerates the world's columns, generates only mixed L1+ regions once, and later boots only verify",
       %{
         baked: baked,
         bake_stats: stats,
         root: root,
         manifest_path: manifest_path
       } do
    # 2×2 列 × 5 级；每列至少含地表所在的 mixed 行；索引落盘。
    assert stats.columns == 4 * 5
    assert stats.mixed >= 20 and stats.generated == stats.mixed
    assert File.exists?(baked.index_path)

    mixed =
      for {{level, rx, rz}, bounds} <- baked.index.bounds,
          ry <- Native.mixed_rows(level, bounds, baked.config),
          do: {level, {rx, ry, rz}}

    assert length(mixed) == stats.mixed

    assert Enum.all?(mixed, fn {level, region} ->
             File.exists?(GeneratedStore.path(baked, level, region))
           end)

    refute Enum.any?(mixed, fn {level, _} -> level == 0 end)

    # 复制出来的根：索引已在，第二次 run 只核对、不生成。
    {:ok, store} = GeneratedStore.open(root: root, manifest_path: manifest_path)
    assert store.index.bounds == baked.index.bounds
    {:ok, _store, again} = Bake.run(store)

    assert again.generated == 0 and again.missing == 0 and again.mixed == stats.mixed and
             again.columns == 20
  end

  test "uniform regions are synthesized byte-for-byte like the kernel and never touch the disk",
       %{
         baked: store
       } do
    # L2 列 (0,0)：地表之上为空气、最低地表 deep 之下为岩石；两者都不在 mixed_rows 里、也没有文件。
    bounds = GeneratedStore.bounds(store, 2, {0, 0})
    [lo | _] = rows = Native.mixed_rows(2, bounds, store.config)
    hi = List.last(rows)

    for {ry, kind} <- [{hi + 1, :air}, {lo - 1, :rock}] do
      region = {0, ry, 0}
      assert {:uniform, material} = GeneratedStore.classify(store, 2, region)
      if kind == :air, do: assert(material == 0), else: assert(material in [12, 13])
      refute File.exists?(GeneratedStore.path(store, 2, region))
      assert {:ok, bytes, header} = GeneratedStore.read(store, 2, region)
      assert header.level == 2 and header.region == region
      {:ok, _header, raw} = Codec.decode_payload_body(bytes)
      assert raw == Native.generate_region(2, region, store.config)
    end

    # mixed 的 L1+ 缺文件是硬错误，不在线生成。
    File.rm!(GeneratedStore.path(store, 2, {0, lo, 0}))
    assert {:error, :not_baked} = GeneratedStore.read(store, 2, {0, lo, 0})
    assert {:error, :not_baked} = GeneratedStore.ensure(store, 2, {0, lo, 0})
    assert :ok = GeneratedStore.bake_region(store, 2, {0, lo, 0})
    assert {:ok, _bytes, _header} = GeneratedStore.read(store, 2, {0, lo, 0})
  end

  test "native returns the existing raw payload body", _context do
    assert Native.kernel_identity() ==
             "worldgen_density_v3@1+sha256:72f1d31c81c337daf54e5f700fc07d1efe4dacf9e6e0df6f7f8c377fa7ee22dd"

    raw = Native.generate_region(0, {0, 0, 0}, config())

    assert {:ok, payload} = Payload.decode_body(raw)
    assert byte_size(payload.cells) == 66 * 66 * 66 * 2
    assert Enum.all?(for <<material::16-little <- payload.cells>>, do: material in 0..23)
    assert raw == Native.generate_region(0, {0, 0, 0}, config())
  end

  test "manifest identity is deterministic and includes kernel, materials, and generation config",
       %{root: root, manifest_path: manifest_path} do
    {:ok, store} = GeneratedStore.open(root: root, manifest_path: manifest_path)

    assert GeneratedStore.content_version(store) == 0x256B_3361_0344_964F

    for field <- [
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

    changed_materials = List.update_at(@manifest["materials"], 2, &Map.put(&1, "name", "stone"))

    refute GeneratedStore.content_version(
             Native.kernel_identity(),
             Jason.encode!(Enum.map(changed_materials, &[&1["id"], &1["name"]])),
             config()
           ) == GeneratedStore.content_version(store)

    refute GeneratedStore.content_version(
             "worldgen_density_v3@1+sha256:" <> String.duplicate("0", 64),
             VoxelMaterialCatalog.identity_bytes(),
             config()
           ) ==
             GeneratedStore.content_version(store)
  end

  test "manifest 材质表漂移会在创建版本目录前失败", %{root: parent_root} do
    root = Path.join(parent_root, "invalid_manifest_root")
    File.mkdir_p!(root)

    variants = [
      Map.delete(@manifest, "materials"),
      Map.put(@manifest, "materials", Enum.reverse(@manifest["materials"])),
      put_in(@manifest, ["materials", Access.at(2), "name"], "stone"),
      put_in(@manifest, ["materials", Access.at(2), "id"], 24),
      Map.update!(@manifest, "materials", &(&1 ++ [%{"id" => 24, "name" => "extra"}]))
    ]

    Enum.with_index(variants, fn manifest, index ->
      path = Path.join(root, "invalid_materials_#{index}.json")
      File.write!(path, Jason.encode!(manifest))
      assert catch_error(GeneratedStore.open(root: root, manifest_path: path))
    end)

    refute Enum.any?(File.ls!(root), &Regex.match?(~r/^[0-9a-f]{16}$/, &1))
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

  test "cold L0 generation runs outside World, is shared by concurrent requesters, and warm serves hit the memory cache",
       %{
         root: root,
         manifest_path: manifest_path
       } do
    {:ok, _world} =
      World.start_link(
        source: GeneratedStore,
        root: root,
        manifest_path: manifest_path,
        name: :cold_world
      )

    cv = World.content_version(:cold_world)
    store = :sys.get_state(:cold_world).source_state

    # 地表所在的 L0 行（mixed，需要在线生成）：两个请求者同时要同一块 + 各自一块。
    [ry | _] = Native.mixed_rows(0, GeneratedStore.bounds(store, 0, {0, 0}), store.config)
    shared = %{level: 0, region: {0, ry, 0}, have_seq: 0, have_hash: 0}
    own = fn x -> %{level: 0, region: {x, ry, 0}, have_seq: 0, have_hash: 0} end
    assert :mixed = GeneratedStore.classify(store, 0, {0, ry, 0})

    tasks =
      for x <- [1, 2] do
        Task.async(fn -> World.serve(:cold_world, request([shared, own.(x)], cv)) end)
      end

    # 生成期间 World 本身不被阻塞：seq 调用在毫秒级返回。
    Process.sleep(10)
    {seq_us, 0} = :timer.tc(fn -> World.seq(:cold_world) end)
    assert seq_us < 100_000

    [{:ok, reply1}, {:ok, reply2}] = Enum.map(tasks, &Task.await(&1, 120_000))

    {:ok, ^cv, [{:payload, 0, {0, ^ry, 0}, bytes1}, {:payload, 0, {1, ^ry, 0}, _}]} =
      Codec.decode_reply(IO.iodata_to_binary(reply1))

    {:ok, ^cv, [{:payload, 0, {0, ^ry, 0}, bytes2}, {:payload, 0, {2, ^ry, 0}, _}]} =
      Codec.decode_reply(IO.iodata_to_binary(reply2))

    assert bytes1 == bytes2

    # 共享的那块只生成一次：三块三次 NIF 调用；World 串行应答时第二份请求的共享块已在缓存里。
    assert %{generated: 3, misses: 3, hits: 1, evictions: 0, entries: 3} =
             World.stats(:cold_world)

    # 暖请求：不再读盘、不再生成。
    {:ok, reply} = World.serve(:cold_world, request([shared, own.(1), own.(2)], cv))

    {:ok, ^cv,
     [
       {:payload, 0, {0, ^ry, 0}, ^bytes1},
       {:payload, 0, {1, ^ry, 0}, _},
       {:payload, 0, {2, ^ry, 0}, _}
     ]} =
      Codec.decode_reply(IO.iodata_to_binary(reply))

    assert %{generated: 3, misses: 3, hits: 4} = World.stats(:cold_world)
  end

  test "asset pack holds every L4+ region of the world box as the bytes the store serves", %{
    baked: baked,
    root: root
  } do
    out = Path.join(root, "assets")
    [l4, l5] = AssetPack.build(baked, out, 4, 5)
    assert l4.path == Path.join([out, GeneratedStore.hex(baked.content_version), "L4.vxpack"])
    # 64 m 世界：L4 / L5 各 2×2 列；ry 盒 = mixed 行 ± 1，均匀行也在包里。
    for pack <- [l4, l5] do
      {lo, hi} = pack.ry_range
      regions = AssetPack.regions(baked, pack.level)
      assert pack.regions == 4 * (hi - lo + 1) and length(regions) == pack.regions
      assert File.stat!(pack.path).size == pack.bytes

      for region <- regions do
        {:ok, from_pack} = MmoContracts.WorldPackShard.fetch_file(pack.path, region)
        {:ok, from_store, header} = GeneratedStore.read(baked, pack.level, region)
        assert from_pack == from_store, "L#{pack.level} #{inspect(region)}"
        assert header.level == pack.level and header.region == region
      end

      assert {:error, _} = MmoContracts.WorldPackShard.fetch_file(pack.path, {99, 99, 99})
      mixed = Enum.count(regions, &(GeneratedStore.classify(baked, pack.level, &1) == :mixed))
      assert mixed > 0 and mixed < pack.regions
    end
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

  # T-2（决策稿 §12）：UE `VoximOracle.S4.ExportRandomSample` 抽出的 200 个 (level, region)，逐份用 `GeneratedStore.read`——
  # 就绪门烘出的文件 / 合成的常量载荷 / 在线生成的 L0，即服务端实际会发的字节——与 UE fixture 比较：解压后 body 逐字节相同，
  # 再按 Payload 语义逐格核对（cells 与六向 texel，含 ring）。写出的同名载荷交给 UE `VoximOracle.S4.ImportRandomSample`。
  @tag :oracle
  @tag :t2
  @tag timeout: 1_800_000
  test "served bytes for the random 200-region sample equal the UE oracle byte for byte" do
    oracle_dir = System.fetch_env!("VOXIM_T2_ORACLE_DIR")
    manifest = oracle_dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    fixtures = Map.fetch!(manifest, "fixtures")
    assert length(fixtures) == 200

    {:ok, store} =
      GeneratedStore.open(
        root: System.fetch_env!("VOXIM_STORE_ROOT"),
        manifest_path: System.fetch_env!("VOXIM_STORE_MANIFEST")
      )

    store_config = store.config
    output_dir = System.get_env("VOXIM_SERVER_PAYLOAD_DIR")
    if output_dir, do: File.mkdir_p!(output_dir)

    for fixture <- fixtures do
      [seed, min, sea, max, soil, lowland, mountain, cave] = Map.fetch!(fixture, "config")
      assert {seed, min, sea, max, soil, lowland * 1.0, mountain * 1.0, cave} == store_config
      [x, y, z] = Map.fetch!(fixture, "coord")
      level = Map.fetch!(fixture, "level")
      name = Map.fetch!(fixture, "file")

      {:ok, served, header} = GeneratedStore.read(store, level, {x, y, z})
      assert header.level == level and header.region == {x, y, z}
      assert header.content_version == store.content_version
      if output_dir, do: File.write!(Path.join(output_dir, name), served)

      {:ok, _header, served_raw} = Codec.decode_payload_body(served)

      {:ok, _header, oracle_raw} =
        oracle_dir |> Path.join(name) |> File.read!() |> Codec.decode_payload_body()

      assert byte_size(served_raw) == byte_size(oracle_raw), name
      assert served_raw == oracle_raw, name

      {:ok, generated} = Payload.decode_body(served_raw)
      {:ok, oracle} = Payload.decode_body(oracle_raw)
      assert generated.cells == oracle.cells, name

      for local <-
            Map.keys(generated.records) |> Enum.concat(Map.keys(oracle.records)) |> Enum.uniq() do
        material = Payload.material(generated, local)

        assert Payload.skins(generated, local, material) == Payload.skins(oracle, local, material),
               "#{name} at #{inspect(local)}"
      end
    end

    IO.puts(
      "t2 sample=#{length(fixtures)} generated_l0=#{GeneratedStore.generated(store)} content_version=#{GeneratedStore.hex(store.content_version)}"
    )
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
