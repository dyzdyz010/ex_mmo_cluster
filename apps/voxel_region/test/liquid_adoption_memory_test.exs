defmodule VoxelRegion.LiquidAdoptionMemoryTest do
  @moduledoc "只测试：合法 refined 场景的液体准备路径，不以完整载荷投影代替材料读取。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, TestSupport}
  alias VoxelRegion.World.Payloads
  alias MmoContracts.Voxel.{Codec, Payload, Skins}

  defmodule NaturalSource do
    def open(opts) do
      {:ok, source} = TestSupport.Source.open(opts)
      {:ok, Map.put(source, :natural, Keyword.fetch!(opts, :natural))}
    end
    defdelegate content_version(s), to: TestSupport.Source
    defdelegate world_dir(s), to: TestSupport.Source
    defdelegate generated(s), to: TestSupport.Source
    defdelegate ensure(s, level, region), to: TestSupport.Source
    def read(s, level, region) do
      {:ok, bytes, _} = TestSupport.Source.read(s, level, region)
      {:ok, p} = Payload.decode(bytes)
      overrides = for {cell, material} <- s.natural, level == 0,
        local = Payload.local(region, cell), Payload.in_span?(local), into: %{},
        do: {local, {material, Skins.uniform(material)}}
      bytes = Payload.encode(p, overrides, 0, 123)
      {:ok, header} = Codec.decode_payload_header(bytes)
      {:ok, bytes, header}
    end
  end

  setup tags do
    root = Path.join(System.tmp_dir!(), "liquid_adoption_#{System.unique_integer([:positive])}")
    catalog = Path.join(root, "prefabs")
    File.mkdir_p!(catalog)
    on_exit(fn -> File.rm_rf!(root) end)
    cells = for x <- 0..15, y <- 0..3, z <- 0..3, do: {x, y, z}
    body = for {x, y, z} <- cells, into: <<>>,
      do: <<x::signed-little-32, y::signed-little-32, z::signed-little-32, 19::16-little>>
    bytes = <<"VXPD", 1::32-little, length(cells)::32-little, body::binary, 0::32-little>>
    File.write!(Path.join(catalog, "dense.vxpd"), bytes)
    id = :crypto.hash(:sha256, bytes)
    properties = Path.join(root, "properties.json")
    data = TestSupport.catalog() |> File.read!() |> Jason.decode!()
      |> Map.put("liquid", %{"step_seconds" => 0.2, "gravity_units_per_step" => 524_288,
        "side_units_per_step" => 131_072, "side_threshold_units" => 0})
    File.write!(properties, Jason.encode!(data))
    natural = %{{1, 65, -63} => 21, {2, 66, -62} => 22,
      {0, 65, -63} => 21, {1, 64, -63} => 22, {1, 65, -64} => 21,
      {3, 65, -63} => 22, {1, 67, -63} => 21, {1, 65, -61} => 22}
    opts = [source: if(tags[:natural], do: NaturalSource, else: TestSupport.Source), log: TestSupport.Log,
      root: root, observer: self(), name: nil, property_catalog_path: properties,
      prefab_catalog_path: catalog, payload_cache_bytes: if(tags[:warm_cache], do: 64 * 1024 * 1024, else: 0), natural: natural,
      liquid_bounds: if(tags[:natural], do: {{1, 65, -63}, {3, 67, -61}}, else: {{0, 0, 0}, {16, 16, 16}})]
    opts = if tags[:fixed_clock], do: Keyword.put(opts, :clock,
      {TestSupport.WorldClock, start_supervised!({TestSupport.WorldClock, 10_000})}), else: opts
    world = if tags[:natural] || tags[:dry_source] do
      start_supervised!({World, opts})
    else
      # 只测试：作者 World 须容纳 prefab 原字节（P2 共享缓存零预算显式拒绝定义）；被测 World 按标签预算冷重启。
      world = start_supervised!({World, Keyword.put(opts, :payload_cache_bytes, 64 * 1024 * 1024)})
      assert {:ok, _} = World.place_prefab(world, id, {64, 64, 64}, 0)
      assert :ok = World.compact(world)
      stop_supervised!(World)
      start_supervised!({World, opts})
    end
    %{world: world, root: root}
  end

  @tag :warm_cache
  @tag :fixed_clock
  test "暖条目后合法水体内容变化会重新检查且不重复接纳数量", %{world: world, root: root} do
    request = Codec.encode_request(0, [%{level: 0, region: {0,0,0}, have_seq: 0, have_hash: 0}])
      |> IO.iodata_to_binary()
    assert {:ok, _} = World.serve(world, request)
    World.material_snapshot(world, [], [{10,10,10}])
    supply = Path.join(root, "new-water.json")
    File.write!(supply, Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [10,10,10], material: 21}]}))
    assert {:ok, _} = World.liquid_experiment(world, supply)
    # 液体材料指纹按 OTP 分段摘要计算（hash_init/update/final），每次重算恰经一次 hash_final/1。
    :erlang.trace_pattern({:crypto, :hash_final, 1}, true, [:local])
    :erlang.trace(world, true, [:call, :arity])
    try do
      snapshot = World.material_snapshot(world, [], [{10,10,10}])
      marker = :erlang.trace_delivered(world)
      assert_receive {:trace_delivered, ^world, ^marker}
      changed_calls = traced_calls(world, %{})
      IO.inspect(changed_calls, label: "LIQUID_ADOPTION_CHANGED")
      assert Map.get(changed_calls, {:crypto, :hash_final, 1}, 0) > 0
      seq = snapshot.seq
      assert World.material_snapshot(world, [], [{10,10,10}]).seq == seq
      marker = :erlang.trace_delivered(world)
      assert_receive {:trace_delivered, ^world, ^marker}
      assert traced_calls(world, %{}) == %{}
      assert World.simulation_snapshot(world, [], {{0,0,0},{1,1,1}}).liquid_quantities == %{{10,10,10} => snapshot.capacity_units}
    after
      :erlang.trace(world, false, [:call])
      :erlang.trace_pattern({:crypto, :hash_final, 1}, false, [:local])
    end
  end

  @tag :warm_cache
  test "合法暖payload及邻区基底未变时重复prepare不重建ring或重算材料指纹", %{world: world} do
    # 正常编辑产生邻区基底；缓存由公开serve创建，不回填缓存或authority。
    edits = for x <- 64..71, y <- 8..15, z <- 8..15, do: {{x,y,z}, 19}
    assert {:ok, _} = World.apply_edits(world, edits)
    assert World.stats(world).region_bases > 0
    request = Codec.encode_request(0, [%{level: 0, region: {0,0,0}, have_seq: 0, have_hash: 0}])
      |> IO.iodata_to_binary()
    assert {:ok, _} = World.serve(world, request)
    assert World.stats(world).entries > 0
    World.material_snapshot(world, [], [{8,8,8}])

    functions = [{Payloads, :ring_overrides, 2}, {:crypto, :hash_final, 1}, {Payload, :decode_cells, 1}]
    for function <- functions, do: :erlang.trace_pattern(function, true, [:local])
    :erlang.trace(world, true, [:call, :arity])
    try do
      {:reductions, before} = Process.info(world, :reductions)
      started = System.monotonic_time(:microsecond)
      for _ <- 1..4, do: World.material_snapshot(world, [], [{8,8,8}])
      elapsed = System.monotonic_time(:microsecond) - started
      {:reductions, after_read} = Process.info(world, :reductions)
      marker = :erlang.trace_delivered(world)
      assert_receive {:trace_delivered, ^world, ^marker}
      calls = traced_calls(world, %{})
      IO.inspect(%{calls: calls, elapsed_us: elapsed, reductions: after_read - before}, label: "LIQUID_ADOPTION_WARM")
      assert calls == %{}
    after
      :erlang.trace(world, false, [:call])
      for function <- functions, do: :erlang.trace_pattern(function, false, [:local])
    end
  end

  @tag :dry_source
  test "纯source干区公开准备不为查液体新增常驻decoded", %{world: world} do
    before = World.stats(world).decoded_regions
    request = Codec.encode_request(0, [%{level: 0, region: {0,0,0}, have_seq: 0, have_hash: 0}])
      |> IO.iodata_to_binary()
    assert {:ok, _} = World.serve(world, request)
    assert World.simulation_snapshot(world, [], {{0,0,0},{1,1,1}}).liquid_quantities == %{}
    assert World.stats(world).decoded_regions == before
  end

  @tag :natural
  test "天然水与熔岩按完整XYZ半开边界各接纳一格且重复准备不增量", %{world: world} do
    assert World.simulation_snapshot(world, [], {{0, 1, -1}, {1, 2, 0}}).liquid_quantities == %{}
    snapshot = World.material_snapshot(world, [], [{1, 65, -63}, {2, 66, -62}])
    capacity = snapshot.capacity_units
    expected = %{{1, 65, -63} => capacity, {2, 66, -62} => capacity}
    assert World.simulation_snapshot(world, [], {{0, 1, -1}, {1, 2, 0}}).liquid_quantities == expected
    seq = snapshot.seq
    assert World.material_snapshot(world, [], [{1, 65, -63}]).seq == seq
    assert World.simulation_snapshot(world, [], {{0, 1, -1}, {1, 2, 0}}).liquid_quantities == expected
  end

  test "无水refined区域的公开材料准备不物化完整细节载荷", %{world: world} do
    # 只跟踪 MFA，不复制实参中的 World state；调用计数用于证伪不必要的细节物化。
    :erlang.trace_pattern({Payloads, :with_refined, 2}, true, [:local])
    :erlang.trace(world, true, [:call, :arity])
    try do
      before = Process.info(world, [:memory, :reductions, :total_heap_size]) |> Map.new()
      started = System.monotonic_time(:microsecond)
      snapshot = World.material_snapshot(world, [], [{8, 8, 8}, {9, 8, 8}])
      elapsed = System.monotonic_time(:microsecond) - started
      after_read = Process.info(world, [:memory, :reductions, :total_heap_size]) |> Map.new()
      assert Enum.all?(snapshot.probe_occupancy, & &1.refined)
      assert World.simulation_snapshot(world, [], {{0, 0, 0}, {1, 1, 1}}).liquid_quantities == %{}
      marker = :erlang.trace_delivered(world)
      assert_receive {:trace_delivered, ^world, ^marker}
      expansions = expansions(world, 0)
      IO.inspect(%{elapsed_us: elapsed, before: before, after_read: after_read,
        detail_expansions: expansions}, label: "LIQUID_ADOPTION_READ")
      assert expansions == 0
    after
      :erlang.trace(world, false, [:call])
      :erlang.trace_pattern({Payloads, :with_refined, 2}, false, [:local])
    end
  end

  defp expansions(world, count) do
    receive do
      {:trace, ^world, :call, {Payloads, :with_refined, 2}} -> expansions(world, count + 1)
    after
      0 -> count
    end
  end

  defp traced_calls(world, calls) do
    receive do
      {:trace, ^world, :call, mfa} -> traced_calls(world, Map.update(calls, mfa, 1, &(&1 + 1)))
    after
      0 -> calls
    end
  end
end
