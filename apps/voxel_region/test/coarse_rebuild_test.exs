defmodule VoxelRegion.CoarseRebuildTest do
  @moduledoc "只测试：离线旧派生日志迁移；真实 World/PG/checkpoint，空气 baseline 为显式数据源夹具。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, OverlayLog, TestSupport}
  alias MmoContracts.Voxel.{Codec, Payload, Skins}

  defmodule MissingCoarse do
    @moduledoc "只测试：模拟尚未烘齐的 coarse source，拒绝真实读取前的 ensure。"
    defdelegate open(opts), to: TestSupport.Source
    defdelegate content_version(s), to: TestSupport.Source
    defdelegate world_dir(s), to: TestSupport.Source
    def read(_s, 1, _region), do: {:error, :missing}
    def read(s, level, region), do: TestSupport.Source.read(s, level, region)
    def ensure(_s, 1, _region), do: {:error, :not_baked}
    def ensure(s, level, region), do: TestSupport.Source.ensure(s, level, region)
  end

  test "新粗 baseline 缺失时失败，原持久前缀不被部分重建覆盖" do
    MmoTest.Database.start!()
    :ok = DataService.Voxel.OverlayLogStore.replace(123, [])
    root = Path.join(System.tmp_dir!(), "coarse_missing_#{System.pid()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    opts = [source: TestSupport.Source, observer: self(), root: root, name: nil, log: OverlayLog.Db]
    world = start_supervised!({World, opts})
    assert {:ok, _} = World.apply_edits(world, for(x <- 2..3, z <- 2..3, do: {{x, 2, z}, 1}))
    stop_supervised!(World)
    before = OverlayLog.Db.replay(123)
    {pid, monitor} = spawn_monitor(fn -> World.rebuild_coarse(Keyword.put(opts, :source, MissingCoarse)) end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 30_000
    assert match?({{:badmatch, {:error, :not_baked}}, _}, reason)
    assert OverlayLog.Db.replay(123) === before
  end

  @tag timeout: 300_000
  test "离线重建覆盖压实 L0、负坐标稀疏格、refined/附件，冷恢复不复活旧粗条目" do
    MmoTest.Database.start!()
    :ok = DataService.Voxel.OverlayLogStore.replace(123, [])
    root = Path.join(System.tmp_dir!(), "coarse_rebuild_#{System.pid()}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)

    # 有限作者定义：一个宏格、一微格和宏格顶面的木附件，全部经正式发布/放置入口。
    bytes = <<"VXPD", 3::32-little, 1::32-little,
      8::signed-little-32, 0::signed-little-32, 0::signed-little-32, 11::16-little,
      0::32-little, 1::32-little, 1::32-little, 0, 1,
      0::signed-little-32, 8::signed-little-32, 0::signed-little-32, 8, 19::16-little,
      1::32-little, 0::signed-little-32, 0::signed-little-32, 0::signed-little-32, 11::16-little>>
    File.write!(Path.join([root, "prefabs", "sample.vxpd"]), bytes)
    id = :crypto.hash(:sha256, bytes)
    properties = Path.join(root, "properties.json")
    catalog = TestSupport.catalog() |> File.read!() |> Jason.decode!()
    # 只测试时钟：本例只检查持久化，不触发液体演化；单格实验边界封闭。
    File.write!(properties, Jason.encode!(Map.put(catalog, "liquid", %{
      "step_seconds" => 3600, "gravity_units_per_step" => 524_288,
      "side_units_per_step" => 131_072, "side_threshold_units" => 0})))
    opts = [source: TestSupport.Source, observer: self(), root: root, name: nil,
      log: OverlayLog.Db, production_materials: [11, 19], property_catalog_path: properties,
      liquid_bounds: {{40, 40, 40}, {41, 41, 41}},
      prefab_catalog_path: Path.join(root, "prefabs")]
    world = start_supervised!({World, opts})
    water = Path.join(root, "water.json")
    File.write!(water, Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [40, 40, 40], material: 21}]}))
    assert {:ok, _} = World.liquid_experiment(world, water)
    assert {:ok, _} = World.material_supply(world, 1001, "coarse-rebuild", %{11 => 1024})
    assert {:ok, _} = World.apply_edits(world, for(x <- 20..23, z <- 20..23, do: {{x, 20, z}, 1}))
    assert {:ok, _} = World.place_prefab(world, id, {80, 80, 80}, 0)
    assert :ok = World.compact(world)
    assert {:ok, _} = World.apply_edits(world, for(x <- -4..-1, z <- -4..-1, do: {{x, -4, z}, 1}))
    seq = World.seq(world)
    before = :sys.get_state(world)
    # 只读白盒核验：本测试的反例确实含完整 L0 base 和不同 region 的稀疏 L0。
    assert Map.has_key?(before.region_bases, {0, {0, 0, 0}})
    assert Map.has_key?(before.overlay, {0, {-4, -4, -4}})
    assert map_size(before.refined) > 0 and map_size(before.attachments) == 64
    assert map_size(before.macro_owners) > 0
    assert before.liquid_units[{40, 40, 40}] == 2_097_152
    l0 = for region <- [{0, 0, 0}, {-1, -1, -1}], into: %{}, do: {region, fetch(world, 0, region)}
    stop_supervised!(World)

    # 冻结旧版本持久格式；仅离线替换派生物，不给在线 authority 注入真值。
    log = OverlayLog.Db.replay(123)
    stale = %Payload{level: 1, region: {0, 0, 0}, cells: :binary.copy(<<0, 0>>, 66 * 66 * 66)}
    old_bytes = Payload.encode(stale, %{}, seq, 123)
    {:ok, old_header} = Codec.decode_payload_header(old_bytes)
    legacy = Enum.map(log, fn txn ->
      if txn.seq == seq do
        %{txn | entries: txn.entries ++ [%{seq: seq, payload: old_bytes}],
          coarse: txn.coarse ++ [%{level: 1, cell: {-2, -2, -2}, material: 0, skins: Skins.uniform(0)},
            %{level: 5, cell: {40, 40, 40}, material: 11, skins: Skins.uniform(11)}]}
      else
        txn
      end
    end)
    :ok = DataService.Voxel.OverlayLogStore.replace(123,
      Enum.flat_map(legacy, &OverlayLog.rows/1))

    assert {:ok, report} = World.rebuild_coarse(opts)
    assert report.seq == seq
    assert report.canonical_equal
    assert report.coarse_cells > 0 and report.l0_regions >= 2

    for restart <- 1..2 do
      world = start_supervised!({World, opts})
      assert World.seq(world) == seq
      after_state = :sys.get_state(world)
      for field <- [:refined, :attachments, :attachment_owners, :attachment_serial, :instances,
        :macro_owners, :material_balances, :material_supplies, :placed_by, :damage, :epochs,
        :liquid_units, :phase_inventory, :thermal, :caster_energy, :craft_ledger, :food_ledger] do
        assert Map.fetch!(after_state, field) == Map.fetch!(before, field), "changed #{field} on restart #{restart}"
      end
      for {region, expected} <- l0, do: assert(fetch(world, 0, region) == expected)
      for {level, cell} <- [{1, {10, 10, 10}}, {2, {5, 5, 5}}, {1, {-2, -2, -2}}, {2, {-1, -1, -1}}] do
        region = VoxelRegion.World.Canonical.region_of(cell)
        {:ok, p} = Payload.decode(fetch(world, level, region))
        assert Payload.material(p, Payload.local(region, cell)) == 1
      end
      {:ok, p} = Payload.decode(fetch(world, 5, {0, 0, 0}))
      assert Payload.material(p, Payload.local({0, 0, 0}, {40, 40, 40})) == 0
      request = Codec.encode_request(123, [%{level: 1, region: {0, 0, 0}, have_seq: seq, have_hash: old_header.hash}])
        |> IO.iodata_to_binary()
      assert {:ok, reply} = World.serve(world, request)
      assert {:ok, 123, [{:payload, 1, {0, 0, 0}, new}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
      {:ok, h} = Codec.decode_payload_header(new)
      refute h.hash == old_header.hash
      assert after_state.structure == before.structure
      stop_supervised!(World)
    end
  end

  defp fetch(world, level, region) do
    req = Codec.encode_request(0, [%{level: level, region: region, have_seq: 0, have_hash: 0}]) |> IO.iodata_to_binary()
    {:ok, reply} = World.serve(world, req)
    {:ok, _, [{:payload, ^level, ^region, bytes}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    bytes
  end
end
