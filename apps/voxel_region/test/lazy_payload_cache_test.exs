defmodule VoxelRegion.LazyPayloadCacheTest do
  use ExUnit.Case, async: false
  alias MmoContracts.Voxel.{Codec, Payload}
  alias VoxelRegion.{Replica, World}
  alias VoxelRegion.TestSupport.{Log, Source}

  defmodule FailingSource do
    @moduledoc "只测试：来源错误接缝，不启动额外 World 或持久化系统。"
    def read(_, _, _), do: {:error, :test_unavailable}
  end

  # 只测试：每例独占小 World；来源是全空气，持久化保留真实文件日志，不启动数据库或物理演化。
  setup do
    root = Path.join(System.tmp_dir!(), "lazy_payload_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(%{schema_version: 1, tags: [%{id: "damage"}], tools: [], definitions: [],
      materials: for(id <- 0..23, do: %{material_id: id, max_hp_per_macro: if(id == 0, do: 0, else: 100),
        defense: 0, tags: [], responses: [%{action: "damage", multiplier: 1}]})}))
    prefabs = Path.join(root, "prefabs")
    File.mkdir_p!(prefabs)
    bytes = <<"VXPD", 1::32-little, 2::32-little,
      0::signed-little-32, 0::signed-little-32, 0::signed-little-32, 11::16-little,
      1::signed-little-32, 0::signed-little-32, 0::signed-little-32, 19::16-little, 0::32-little>>
    File.write!(Path.join(prefabs, "test.vxpd"), bytes)
    opts = [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, prefab_catalog_path: prefabs]
    world = start_supervised!({World, opts})
    on_exit(fn -> File.rm_rf!(root) end)
    %{world: world, id: :crypto.hash(:sha256, bytes), opts: opts}
  end

  test "a warmed sparse macro commit invalidates payload without eagerly rewriting it", %{world: world} do
    prior = serve(world, 0, {0, 0, 0})
    assert World.stats(world).shared_cache.namespaces.payload.entries > 0
    hits = World.stats(world).shared_cache.hits
    assert serve(world, 0, {0, 0, 0}) == prior
    assert World.stats(world).shared_cache.hits == hits + 1
    assert World.seq(world) == 0

    {{:ok, 1}, calls} = count_rewrites(world, fn -> World.apply_edits(world, [{{2, 2, 2}, 11}]) end)
    assert World.seq(world) == 1
    assert [%{seq: 1, entries: entries}] = World.entries_after(world, 0)
    assert Enum.any?(entries, &(Map.get(&1, :coord) == {2, 2, 2} and Map.get(&1, :material) == 11))
    refute Enum.any?(entries, &Map.has_key?(&1, :payload))
    assert calls == 0
    assert {:ok, current} = Payload.decode(serve(world, 0, {0, 0, 0}))
    assert Payload.material(current, Payload.local(current.region, {2, 2, 2})) == 11
  end

  test "Replica receives the current full region and unchanged prefab suffix at the commit sequence", c do
    assert {:ok, 1} = World.place_prefab(c.world, c.id, {8, 8, 16}, 0)
    assert {:ok, before} = Payload.decode(serve(c.world, 0, {0, 0, 0}))
    assert map_size(before.refined) == 1
    assert Map.keys(before.instances) == [{1, 0}]
    box = {{0, 0, 0}, {1, 1, 1}}
    replica = start_supervised!({Replica, authority_ref: c.world, l0_box: box, name: nil})
    assert :ok = Replica.canonical_snapshot_and_subscribe(replica, box, self(), :before, false)
    assert_receive {:canonical_snapshot, :before, %{transaction_seq: 1}}

    assert {:ok, 2} = World.apply_edits(c.world, [{{1, 1, 3}, 11}])
    assert_receive {:canonical_delta, %{transaction_seq: 2, transaction: txn}}
    assert Enum.any?(txn.entries, &Map.has_key?(&1, :structure))
    assert :ok = Replica.canonical_snapshot_and_subscribe(replica, box, self(), :after, false)
    assert_receive {:canonical_snapshot, :after, %{transaction_seq: 2, regions: [{{0, 0, 0}, bytes}]}}
    assert {:ok, %{seq: 2}} = Codec.decode_payload_header(bytes)
    assert bytes == serve(c.world, 0, {0, 0, 0})
    assert {:ok, current} = Payload.decode(bytes)
    assert Payload.material(current, Payload.local(current.region, {1, 1, 3})) == 11
    assert current.refined == before.refined
    assert current.instances == before.instances
  end

  test "full materialization records scalar stages while source and hits do not", c do
    region = {-1, 1, 2}
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    {source, source_log} = ExUnit.CaptureLog.with_log(fn -> serve(c.world, 0, region) end)
    refute source_log =~ "voxel_payload_materialize "
    refute source_log =~ "voxel_payload_details "
    {^source, hit_log} = ExUnit.CaptureLog.with_log(fn -> serve(c.world, 0, region) end)
    refute hit_log =~ "voxel_payload_materialize "
    refute hit_log =~ "voxel_payload_details "

    assert {:ok, 1} = World.place_prefab(c.world, c.id, {-504, 520, 1040}, 0)
    assert {:ok, 2} = World.apply_edits(c.world, [{{-63, 65, 131}, 11}])
    {bytes, log} = ExUnit.CaptureLog.with_log(fn -> serve(c.world, 0, region) end)
    assert {:ok, header} = Codec.decode_payload_header(bytes)
    assert {:ok, payload} = Payload.decode(bytes)
    assert header.seq == 2
    assert header.content_version == 123
    assert map_size(payload.refined) == 1
    assert Map.keys(payload.instances) == [{1, 0}]
    assert Payload.material(payload, Payload.local(payload.region, {-63, 65, 131})) == 11
    # 改前有效 miss 的完整字节摘要；只测试取证，不在生产路径重新 hash。
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
      "8036ab306af370a1cec2ec20496322e1fe7d382f6eb9c365c85cd738f47a1d73"
    assert log =~ ~r/voxel_serve_item .*hit=false/

    [details] = scalar_events(log, "voxel_payload_details")
    [full] = scalar_events(log, "voxel_payload_materialize")
    identity = ~w(pid seq cv level x y z)
    assert Map.take(details, identity) == Map.take(full, identity)
    assert full["pid"] == List.to_string(:erlang.pid_to_list(c.world))
    assert Map.take(full, ~w(seq cv level x y z)) == %{
      "seq" => "2", "cv" => "123", "level" => "0", "x" => "-1", "y" => "1", "z" => "2"}
    assert details["source"] == "with_refined"
    assert full["source"] == "materialize"
    times = [full["start_us"], full["terrain_end_us"], details["details_start_us"],
      details["details_end_us"], details["canopy_end_us"], full["encode_start_us"],
      full["encode_end_us"], full["cache_start_us"], full["cache_end_us"]]
      |> Enum.map(&String.to_integer/1)
    assert times == Enum.sort(times)
    for {event, duration, from, to} <- [
      {full, "terrain_us", "start_us", "terrain_end_us"},
      {details, "details_us", "details_start_us", "details_end_us"},
      {details, "canopy_us", "details_end_us", "canopy_end_us"},
      {full, "encode_us", "encode_start_us", "encode_end_us"},
      {full, "cache_us", "cache_start_us", "cache_end_us"},
      {full, "elapsed_us", "start_us", "cache_end_us"}] do
      assert String.to_integer(event[duration]) == String.to_integer(event[to]) - String.to_integer(event[from])
    end
    for {field, expected} <- [cells_bytes: 574_992, fmi_bytes: 0, maps_bytes: 0,
      records_entries: 0, refined_entries: 1, refined_records_entries: 1, instances_entries: 1,
      structure_entries: 0, attachments_entries: 0, liquid_units_entries: 0, canopy_entries: 0,
      canopy_instances_entries: 0, canopy_residual_entries: 0, canopy_residual_structure_entries: 0] do
      assert details[Atom.to_string(field)] == Integer.to_string(expected)
    end
    assert full["raw_bytes"] == Integer.to_string(header.raw_bytes)
    assert full["body_bytes"] == Integer.to_string(header.body_bytes)
    assert full["payload_bytes"] == Integer.to_string(byte_size(bytes))
    {^bytes, warmed_log} = ExUnit.CaptureLog.with_log(fn -> serve(c.world, 0, region) end)
    refute warmed_log =~ "voxel_payload_materialize "
    refute warmed_log =~ "voxel_payload_details "

    # 只测试：离线来源失败接缝；不回填运行中的 authority，也不把失败写成物化成功。
    for snapshots <- [MapSet.new(), MapSet.new([{0, {0, 1, -1}}])] do
      probe = %{cache: VoxelRegion.World.Cache.new(1_000_000), overlay_regions: %{}, decoded: %{},
        region_bases: %{}, snapshots: snapshots, source: FailingSource, source_state: nil}
      {failure, failure_log} = ExUnit.CaptureLog.with_log(fn ->
        VoxelRegion.World.Payloads.payload_bytes(probe, 0, {0, 1, -1})
      end)
      assert {:error, :test_unavailable, _} = failure
      refute failure_log =~ "voxel_payload_materialize "
      refute failure_log =~ "voxel_payload_details "
    end
  end

  test "record observations preserve cold replay and unchanged slots after payload invalidation", c do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    region = {-1, 1, 2}
    assert {:ok, 1} = World.place_prefab(c.world, c.id, {-504, 520, 1040}, 0)
    assert {:ok, 2} = World.apply_edits(c.world, [{{-63, 65, 131}, 11}])
    before = serve(c.world, 0, region)
    assert :ok = stop_supervised(World)
    cold = start_supervised!({World, c.opts})

    {bytes, cold_log} = ExUnit.CaptureLog.with_log(fn -> serve(cold, 0, region) end)
    assert bytes == before
    assert cold_log =~ ~r/voxel_serve_item .*hit=false/
    [cold_records] = scalar_events(cold_log, "voxel_payload_records")
    assert_record_observation(cold_records, cold_log, cold, 2)

    # 正常非refined宏格编辑只失效完整载荷；未变槽仍从合法值直接投影同一记录字节。
    assert {:ok, 3} = World.apply_edits(cold, [{{-63, 65, 131}, 19}])
    {changed, warm_log} = ExUnit.CaptureLog.with_log(fn -> serve(cold, 0, region) end)
    assert warm_log =~ ~r/voxel_serve_item .*hit=false/
    [warm_records] = scalar_events(warm_log, "voxel_payload_records")
    assert_record_observation(warm_records, warm_log, cold, 3)
    assert {:ok, prior} = Payload.decode(bytes)
    assert {:ok, current} = Payload.decode(changed)
    assert current.refined == prior.refined
    assert current.instances == prior.instances
    assert Payload.material(current, Payload.local(region, {-63, 65, 131})) == 19
  end

  defp assert_record_observation(records, log, world, seq) do
    [details] = scalar_events(log, "voxel_payload_details")
    assert Map.take(records, ~w(pid seq cv level x y z)) == Map.take(details, ~w(pid seq cv level x y z))
    assert records["pid"] == List.to_string(:erlang.pid_to_list(world))
    assert records["seq"] == Integer.to_string(seq)
    assert records["source"] == "with_existing_details"
    refute Map.has_key?(records, "memo_hits")
    refute Map.has_key?(records, "memo_misses")
    assert details["refined_entries"] == "1"
    # VXPD 夹具同一宏格有两个槽，每槽 u16+u16+u64+u32，共 16B。
    assert records["slots"] == "2"
    assert records["record_bytes"] == "32"
    times = [details["details_start_us"], records["record_start_us"], records["record_end_us"],
      records["owners_start_us"], records["owners_end_us"], details["details_end_us"]]
      |> Enum.map(&String.to_integer/1)
    assert times == Enum.sort(times)
    assert String.to_integer(records["record_loop_us"]) ==
      String.to_integer(records["record_end_us"]) - String.to_integer(records["record_start_us"])
    assert String.to_integer(records["owners_us"]) ==
      String.to_integer(records["owners_end_us"]) - String.to_integer(records["owners_start_us"])
  end

  defp scalar_events(log, name) do
    for [fields] <- Regex.scan(~r/#{name} ([^\r\n]+)/, log, capture: :all_but_first) do
      for [key, value] <- Regex.scan(~r/(\w+)=([^ ]+)/, fields, capture: :all_but_first), into: %{},
        do: {key, value}
    end
  end

  defp serve(world, level, region) do
    request = Codec.encode_request(0, [%{level: level, region: region, have_seq: 0, have_hash: 0}])
      |> IO.iodata_to_binary()
    assert {:ok, reply} = World.serve(world, request)
    assert {:ok, 123, [{:payload, ^level, ^region, bytes}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    bytes
  end

  # 只测试：精确 World PID 与单个 MFA 的 arity-only 调用；不取参数、返回值、GC 或私有状态。
  defp count_rewrites(world, action) do
    mfa = {Payload, :replace_uniform_cells, 4}
    assert {:module, Payload} = Code.ensure_loaded(Payload)
    sessions = :trace.session_info(:all)
    assert :trace.session_info(world) == []
    session = :trace.session_create(:lazy_payload_rewrites, self(), [])

    try do
      assert :trace.function(session, mfa, true, [:global]) == 1
      assert :trace.process(session, world, true, [:call, :arity]) == 1
      result = action.()
      marker = :trace.delivered(session, world)
      {result, drain_calls(world, mfa, marker, 0)}
    after
      assert :trace.process(session, world, false, [:call, :arity]) == 1
      assert :trace.function(session, mfa, false, [:global]) == 1
      assert :trace.info(session, world, :flags) == {:flags, []}
      assert :trace.info(session, mfa, :traced) == {:traced, false}
      marker = :trace.delivered(session, world)
      assert drain_calls(world, mfa, marker, 0) == 0
      assert :trace.session_destroy(session) == true
      assert :trace.session_info(world) == []
      assert :trace.session_info(:all) == sessions
    end
  end

  defp drain_calls(world, mfa, marker, calls) do
    receive do
      {:trace, ^world, :call, ^mfa} -> drain_calls(world, mfa, marker, calls + 1)
      {:trace_delivered, ^world, ^marker} -> calls
    after
      1_000 -> flunk("单 MFA 调用 trace 的投递屏障未完成")
    end
  end
end
