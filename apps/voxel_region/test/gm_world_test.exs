defmodule VoxelRegion.GmWorldTest do
  @moduledoc """
  只测试：GM 施工工具（`World.gm/4`）经真实 World 提交、日志与冷启动回放。世界基底为空（全空气）替身，
  目录为已发布样本加液体步进参数，prefab 定义按 VXPD v3 手写。期望全部手算：格集合、计数、回执与防重。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Source, Log}

  @cap 2_097_152

  setup context do
    root = Path.join(System.tmp_dir!(), "gm_world_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    catalog = Path.join(root, "catalog.json")
    source_catalog = if context[:recolor],
      do: Path.expand("../Playable/Published/7175e287796154282593c925ee8b787c5d0ddce50ceba41925973d3612543d20.json", Path.dirname(VoxelRegion.TestSupport.catalog())),
      else: VoxelRegion.TestSupport.catalog()
    data = Jason.decode!(File.read!(source_catalog))
      |> Map.put("liquid", %{"step_seconds" => 3600, "gravity_units_per_step" => div(@cap, 4),
        "side_units_per_step" => div(@cap, 16), "side_threshold_units" => div(@cap, 8)})
    File.write!(catalog, Jason.encode!(data))
    opts = [source: Source, log: Log, root: root, observer: self(), name: nil, property_catalog_path: catalog,
      prefab_catalog_path: Path.join(root, "prefabs"), production_materials: [11, 19, 21],
      liquid_bounds: Map.get(context, :bounds, {{0, 0, 0}, {8, 8, 8}}), gm_tools: Map.get(context, :gm, true)]
    opts = if context[:recolor] do
      environment = Path.join(root, "environment.json")
      File.write!(environment, Jason.encode!(%{ambient_kelvin: 293.15, environment_w_per_m2_k: 0.0,
        tolerance_kelvin: 0.00001, emissivity: 0.0, view_range_cells: 8, circuit_min_power_w: 1.0}))
      Keyword.put(opts, :thermal_environment_path, environment)
    else
      opts
    end
    w = start_supervised!({World, opts})
    %{w: w, opts: opts, root: root}
  end

  defp material(w, cell), do: hd(World.material_snapshot(w, [], [cell]).probe_occupancy).material
  defp micros(w, cell),
    do: hd(World.material_snapshot(w, [], [cell], :micro).probe_occupancy) |> Map.get(:micro_cells, []) |> Enum.map(&{&1.micro, &1.material})
  defp quantities(w), do: World.simulation_snapshot(w, [], {{0, 0, 0}, {1, 1, 1}}).liquid_quantities
  defp restart(c), do: (stop_supervised!(World); start_supervised!({World, c.opts}))

  # 只测试：两个微格（11 号）的 VXPD v3 定义，锚点微格坐标。
  defp define(c, material \\ 11) do
    cells = for {{x, y, z}, m} <- [{{0, 0, 0}, material}, {{1, 0, 0}, material}], into: <<>>,
      do: <<x::signed-little-32, y::signed-little-32, z::signed-little-32, m::16-little>>
    bytes = <<"VXPD", 3::32-little, 2::32-little, cells::binary, 0::32-little, 0::32-little, 0::32-little>>
    File.write!(Path.join([c.root, "prefabs", "pair.vxpd"]), bytes)
    :ok = World.publish_prefabs(c.w, Path.join(c.root, "prefabs"))
    :crypto.hash(:sha256, bytes)
  end

  @tag gm: false
  test "every GM operation is refused while the deployment switch is off", c do
    for {op, args} <- [clear: %{box: {{1, 1, 1}, {1, 1, 1}}}, fill: %{box: {{1, 1, 1}, {1, 1, 1}}, material: 11},
                       liquid_fill: %{seed: {0, 0, 0}, level_y: 0, material: 21},
                       drain: %{box: {{0, 0, 0}, {7, 7, 7}}},
                       recolor: %{from: 13, to: 82, cells: [{1, 1, 1}]},
                       move_instance: %{instance: {1, 0}, anchor: {8, 8, 8}, orientation: 0}] do
      assert {:error, :gm_disabled} = World.gm(c.w, "off", op, args)
    end
    assert World.seq(c.w) == 0
  end

  test "macro fill and clear change exactly the box, dedupe by key and replay", c do
    assert {:ok, %{seq: 1, op: :fill, cells: 4}} = World.gm(c.w, "f1", :fill, %{box: {{1, 1, 1}, {2, 1, 2}}, material: 11})
    filled = for x <- 1..2, z <- 1..2, do: {x, 1, z}
    assert Enum.map(filled, &material(c.w, &1)) == [11, 11, 11, 11]
    assert material(c.w, {3, 1, 1}) == 0 and material(c.w, {1, 2, 1}) == 0
    # 同 key 不再执行：原回执，没有新事务；已满的格不再填。
    assert {:ok, %{seq: 1}} = World.gm(c.w, "f1", :fill, %{box: {{1, 1, 1}, {2, 1, 2}}, material: 11})
    assert {:error, :gm_noop} = World.gm(c.w, "f2", :fill, %{box: {{1, 1, 1}, {2, 1, 2}}, material: 19})
    assert World.seq(c.w) == 1
    assert {:ok, %{seq: 2, op: :clear, cells: 2}} = World.gm(c.w, "c1", :clear, %{box: {{1, 1, 1}, {1, 1, 2}}})
    assert Enum.map(filled, &material(c.w, &1)) == [0, 0, 11, 11]
    assert {:error, :gm_too_large} = World.gm(c.w, "big", :clear, %{box: {{0, 0, 0}, {16, 16, 15}}})
    assert {:error, :invalid_gm_args} = World.gm(c.w, "bad", :fill, %{box: {{1, 1, 1}, {1, 1, 1}}, material: 0})
    w = restart(c)
    assert Enum.map(filled, &material(w, &1)) == [0, 0, 11, 11]
    assert {:ok, %{seq: 2}} = World.gm(w, "c1", :clear, %{box: {{1, 1, 1}, {1, 1, 2}}})
    assert World.seq(w) == 2
  end

  test "micro fill takes only wholly covered air macros and reports the partial ones", c do
    # 微格盒 x 24..35 覆盖宏格 x 3 整格、x 4 半格；y/z 恰好一整格。
    assert {:ok, %{cells: 1, partial_skipped: 1}} =
      World.gm(c.w, "m1", :fill, %{box: {{24, 8, 8}, {35, 15, 15}}, material: 11, precision: :micro})
    assert material(c.w, {3, 1, 1}) == 11 and material(c.w, {4, 1, 1}) == 0
  end

  test "instances are left alone by default, moved atomically, refused onto occupied space and micro-cleared on request", c do
    assert {:error, :invalid_gm_args} = World.gm(c.w, "invalid-move", :move_instance, %{})
    id = define(c)
    {:ok, birth} = World.place_prefab(c.w, id, {40, 8, 8}, 0)
    assert micros(c.w, {5, 1, 1}) == [{{40, 8, 8}, 11}, {{41, 8, 8}, 11}]
    assert {:error, :gm_noop} = World.gm(c.w, "keep", :clear, %{box: {{5, 1, 1}, {5, 1, 1}}})
    seq = World.seq(c.w)
    assert {:ok, %{instance: moved, from: {40, 8, 8}} = receipt} =
      World.gm(c.w, "mv1", :move_instance, %{instance: {birth, 0}, anchor: {48, 8, 8}, orientation: 0})
    assert moved == {seq + 1, 0} and World.seq(c.w) == seq + 1
    assert {:ok, ^receipt} = World.gm(c.w, "mv1", :move_instance,
      %{instance: {birth, 0}, anchor: {48, 8, 8}, orientation: 0})
    assert World.seq(c.w) == seq + 1
    assert micros(c.w, {5, 1, 1}) == []
    assert micros(c.w, {6, 1, 1}) == [{{48, 8, 8}, 11}, {{49, 8, 8}, 11}]
    assert {:ok, _} = World.gm(c.w, "wall", :fill, %{box: {{7, 1, 1}, {7, 1, 1}}, material: 19})
    assert {:error, :occupied} = World.gm(c.w, "mv2", :move_instance, %{instance: moved, anchor: {56, 8, 8}, orientation: 0})
    assert micros(c.w, {6, 1, 1}) == [{{48, 8, 8}, 11}, {{49, 8, 8}, 11}]
    assert {:ok, %{cells: 1}} = World.gm(c.w, "cut", :clear,
      %{box: {{49, 8, 8}, {49, 8, 8}}, precision: :micro, instances: true})
    assert micros(c.w, {6, 1, 1}) == [{{48, 8, 8}, 11}]
    w = restart(c)
    assert micros(w, {6, 1, 1}) == [{{48, 8, 8}, 11}]
    assert micros(w, {5, 1, 1}) == [] and material(w, {7, 1, 1}) == 19
  end

  test "GM liquid fill floods the level without inventory and replays", c do
    assert {:ok, _} = World.gm(c.w, "post", :fill, %{box: {{3, 0, 3}, {3, 0, 3}}, material: 19})
    # 计算域底层 8×8 = 64 格，去掉一根实心柱 = 63 格，每格灌满。
    assert {:ok, %{cells: 63, units: units, material: 21}} =
      World.gm(c.w, "lf", :liquid_fill, %{seed: {0, 0, 0}, level_y: 0, material: 21})
    assert units == 63 * @cap
    expected = for x <- 0..7, z <- 0..7, {x, z} != {3, 3}, into: %{}, do: {{x, 0, z}, @cap}
    assert quantities(c.w) == expected
    assert World.material_balances(c.w, 1001) |> Enum.all?(&(&1.balance == 0))
    w = restart(c)
    assert quantities(w) == expected
  end

  # 只测试：真实 World + 文件日志，空基底替身；手算数量和边界，不覆盖在线客户端或性能。
  test "drain removes only boxed water in one commit, preserves structure and replays", c do
    assert {:ok, _} = World.gm(c.w, "water", :fill, %{box: {{1, 1, 1}, {2, 1, 1}}, material: 21})
    assert {:ok, _} = World.gm(c.w, "outside", :fill, %{box: {{1, 2, 1}, {1, 2, 2}}, material: 21})
    assert {:ok, _} = World.gm(c.w, "solid", :fill, %{box: {{3, 1, 1}, {3, 1, 1}}, material: 19})
    assert {:ok, birth} = World.place_prefab(c.w, define(c), {32, 8, 8}, 0)
    # 宏格石台 + 顶面木附件，同盒内必须原样保留。
    bytes = <<"VXPD", 3::32-little, 0::32-little, 0::32-little,
      1::32-little, 1::32-little, 0, 1, 0::signed-little-32, 8::signed-little-32, 0::signed-little-32, 8, 19::16-little,
      1::32-little, 0::signed-little-32, 0::signed-little-32, 0::signed-little-32, 11::16-little>>
    File.write!(Path.join(c.root, "prefabs/platform.vxpd"), bytes)
    assert :ok = World.publish_prefabs(c.w, Path.join(c.root, "prefabs"))
    assert {:ok, platform} = World.place_prefab(c.w, :crypto.hash(:sha256, bytes), {40, 8, 8}, 0)
    structure = VoxelRegion.TestSupport.payload(c.w, 0, {0, 0, 0})
    assert World.stats(c.w).attachment_slots == 64
    kept = World.material_snapshot(c.w, [], [{1, 2, 1}, {1, 2, 2}, {3, 1, 1}, {4, 1, 1}], :micro).probe_occupancy
    seq = World.seq(c.w)
    args = %{box: {{1, 1, 1}, {5, 1, 1}}, material: 21}
    assert {:ok, %{seq: drained, op: :drain, cells: 2, units: 4_194_304} = receipt} = World.gm(c.w, "drain", :drain, args)
    assert drained == seq + 1
    assert Enum.map([{1, 1, 1}, {2, 1, 1}], &material(c.w, &1)) == [0, 0]
    assert quantities(c.w) == %{{1, 2, 1} => @cap, {1, 2, 2} => @cap}
    assert World.material_snapshot(c.w, [], [{1, 2, 1}, {1, 2, 2}, {3, 1, 1}, {4, 1, 1}], :micro).probe_occupancy == kept
    assert {:ok, [{4, 1, 1}]} = World.instance_cells(c.w, {birth, 0})
    assert {:ok, [{5, 1, 1}]} = World.instance_cells(c.w, {platform, 0})
    assert material(c.w, {5, 1, 1}) == 11
    assert World.stats(c.w).instances == 2
    assert World.stats(c.w).attachment_slots == 64
    assert VoxelRegion.TestSupport.payload(c.w, 0, {0, 0, 0}).attachments == structure.attachments
    assert {:ok, ^receipt} = World.gm(c.w, "drain", :drain, args)
    assert World.seq(c.w) == drained
    assert {:error, :gm_noop} = World.gm(c.w, "empty", :drain, args)
    w = restart(c)
    assert {:ok, ^receipt} = World.gm(w, "drain", :drain, args)
    assert World.seq(w) == drained
    assert quantities(w) == %{{1, 2, 1} => @cap, {1, 2, 2} => @cap}
    assert Enum.map([{1, 1, 1}, {2, 1, 1}], &material(w, &1)) == [0, 0]
  end

  @tag bounds: {{-2, -2, -2}, {8, 8, 8}}
  test "drain filters material and accepts a sparse million-cell inclusive box", c do
    assert {:ok, _} = World.gm(c.w, "negative-water", :fill, %{box: {{-1, -1, -1}, {-1, -1, -1}}, material: 21})
    assert {:ok, _} = World.gm(c.w, "lava", :fill, %{box: {{0, 0, 0}, {0, 0, 0}}, material: 22})
    # 128 * 64 * 128 = 1,048,576；闭区间下界有水，另一种液体须保留。
    args = %{box: {{-1, -1, -1}, {126, 62, 126}}, material: 21}
    assert {:ok, %{cells: 1, units: @cap}} = World.gm(c.w, "only-water", :drain, args)
    assert material(c.w, {-1, -1, -1}) == 0
    assert material(c.w, {0, 0, 0}) == 22
    assert {:ok, %{cells: 1, units: @cap}} = World.gm(c.w, "all-liquid", :drain, Map.delete(args, :material))
    assert material(c.w, {0, 0, 0}) == 0
  end

  test "drain rejects oversized boxes and invalid arguments without a transaction", c do
    assert {:error, :gm_too_large} = World.gm(c.w, "big-drain", :drain, %{box: {{0, 0, 0}, {128, 63, 127}}})
    for args <- [%{box: {{2, 0, 0}, {1, 0, 0}}}, %{box: {{0, 0, 0}, {1, 1, 1}}, material: 19},
                 %{box: {{0, 0, 0}, {1, 1, 1}}, precision: :micro}] do
      assert {:error, :invalid_gm_args} = World.gm(c.w, "invalid-drain", :drain, args)
    end
    assert World.seq(c.w) == 0
  end

  test "drain rejects 131073 liquid cells before committing", _c do
    # 纯回调边界测试：构造稀疏输入，不向在线 World 注入真值，也不启动 13 万格集成场景。
    cells = [{0, 32, 0} | for(x <- 0..63, y <- 0..31, z <- 0..63, do: {x, y, z})]
    state = %{gm_tools: true, seq: 0, material_supplies: %{}, liquid_units: Map.new(cells, &{&1, 1}),
      overlay: Map.new(cells, &{{0, &1}, {21, MmoContracts.Voxel.Skins.uniform(21)}}),
      refined: %{}, macro_owners: %{}, placed_by: %{}, region_bases: %{}, decoded: %{{0, {0, 0, 0}} => :unused}}
    assert {:reply, {:error, :gm_too_large}, ^state} = VoxelRegion.World.Gm.run(state, "too-many", :drain,
      %{box: {{0, 0, 0}, {63, 32, 63}}})
  end

  # 只测试：真实 World／文件日志，空基底替身；有限样本经作者入口安装。
  # 契约：固体原位换料，一笔提交；水量、其他格、实例和附件不变；不覆盖客户端、数据库或性能。
  @tag :recolor
  test "recolor box preserves water and excluded structure, commits once and replays", c do
    assert {:ok, _} = World.gm(c.w, "bed", :fill, %{box: {{1, 1, 1}, {2, 1, 1}}, material: 13})
    assert {:ok, _} = World.gm(c.w, "other", :fill, %{box: {{3, 1, 1}, {3, 1, 1}}, material: 19})
    assert {:ok, _} = World.gm(c.w, "water", :fill, %{box: {{1, 2, 1}, {2, 2, 1}}, material: 21})
    assert {:ok, _} = World.gm(c.w, "outside", :fill, %{box: {{1, 1, 2}, {1, 1, 2}}, material: 13})
    assert {:ok, birth} = World.place_prefab(c.w, define(c, 13), {40, 8, 8}, 0)
    # 无微格的实体实例，与目标材料相同，不能仅靠材料筛掉。
    bytes = <<"VXPD", 3::32-little, 0::32-little, 0::32-little, 0::32-little,
      1::32-little, 0::signed-little-32, 0::signed-little-32, 0::signed-little-32, 13::16-little>>
    File.write!(Path.join(c.root, "prefabs/bed.vxpd"), bytes)
    assert :ok = World.publish_prefabs(c.w, Path.join(c.root, "prefabs"))
    assert {:ok, platform} = World.place_prefab(c.w, :crypto.hash(:sha256, bytes), {48, 8, 8}, 0)
    # 实例侧面的附件贴着无 macro_owner 的天然格；附件两侧都须跳过。
    assert {:ok, _} = World.gm(c.w, "support", :fill, %{box: {{7, 1, 1}, {7, 1, 1}}, material: 13})
    face = <<"VXPD", 3::32-little, 0::32-little, 0::32-little,
      1::32-little, 1::32-little, 0, 0, 0::signed-little-32, 0::signed-little-32, 0::signed-little-32, 8, 19::16-little,
      1::32-little, 0::signed-little-32, 0::signed-little-32, 0::signed-little-32, 13::16-little>>
    File.write!(Path.join(c.root, "prefabs/face.vxpd"), face)
    assert :ok = World.publish_prefabs(c.w, Path.join(c.root, "prefabs"))
    assert {:ok, _} = World.place_prefab(c.w, :crypto.hash(:sha256, face), {64, 8, 8}, 0)
    structure = VoxelRegion.TestSupport.payload(c.w, 0, {0, 0, 0})
    kept = [{3, 1, 1}, {4, 1, 1}, {5, 1, 1}, {6, 1, 1}, {7, 1, 1}, {1, 1, 2}, {1, 2, 1}, {2, 2, 1}]
    before = World.material_snapshot(c.w, [], kept, :micro).probe_occupancy
    water = Map.take(quantities(c.w), [{1, 2, 1}, {2, 2, 1}])
    assert water == %{{1, 2, 1} => @cap, {2, 2, 1} => @cap}
    seq = World.seq(c.w)
    args = %{from: 13, to: 82, box: {{1, 1, 1}, {7, 2, 1}}}
    # 7×2×1=14 格：仅两个无归属池底可改，其余 12 格跳过。
    assert {:ok, %{op: :recolor, changed: 2, skipped: 12, seq: changed} = receipt} = World.gm(c.w, "recolor", :recolor, args)
    assert changed == seq + 1
    assert Enum.map([{1, 1, 1}, {2, 1, 1}], &material(c.w, &1)) == [82, 82]
    assert World.material_snapshot(c.w, [], kept, :micro).probe_occupancy == before
    assert Map.take(quantities(c.w), Map.keys(water)) == water
    refute Map.has_key?(quantities(c.w), {1, 1, 1})
    refute Map.has_key?(quantities(c.w), {2, 1, 1})
    assert {:ok, [{5, 1, 1}]} = World.instance_cells(c.w, {birth, 0})
    assert {:ok, [{6, 1, 1}]} = World.instance_cells(c.w, {platform, 0})
    assert World.stats(c.w).instances == 3
    assert World.stats(c.w).attachment_slots == 64
    assert VoxelRegion.TestSupport.payload(c.w, 0, {0, 0, 0}).attachments == structure.attachments
    assert {:ok, ^receipt} = World.gm(c.w, "recolor", :recolor, args)
    assert World.seq(c.w) == changed
    assert {:error, :gm_noop} = World.gm(c.w, "no-match", :recolor, args)
    w = restart(c)
    assert {:ok, ^receipt} = World.gm(w, "recolor", :recolor, args)
    assert World.seq(w) == changed
    assert Enum.map([{1, 1, 1}, {2, 1, 1}], &material(w, &1)) == [82, 82]
    assert World.material_snapshot(w, [], kept, :micro).probe_occupancy == before
    assert Map.take(quantities(w), Map.keys(water)) == water
  end

  @tag :recolor
  test "recolor exact cells deduplicate and update negative XYZ coarse parents", c do
    assert {:ok, _} = World.gm(c.w, "negative", :fill, %{box: {{-2, -2, -2}, {-1, -1, -1}}, material: 19})
    assert {:ok, _} = World.gm(c.w, "outside", :fill, %{box: {{0, -1, -1}, {0, -1, -1}}, material: 19})
    cells = for x <- -2..-1, y <- -2..-1, z <- -2..-1, do: {x, y, z}
    assert {:ok, %{changed: 8, skipped: 1}} = World.gm(c.w, "points", :recolor,
      %{from: 19, to: 82, cells: [{-3, -2, -2} | cells ++ cells]})
    assert Enum.map(cells, &material(c.w, &1)) == List.duplicate(82, 8)
    assert material(c.w, {0, -1, -1}) == 19
    assert material(c.w, {-3, -2, -2}) == 0
    # 八个子格全为 82，因此 L1 父格必须为 82；独立手算期望。
    parent = VoxelRegion.TestSupport.payload(c.w, 1, {-1, -1, -1})
    assert MmoContracts.Voxel.Payload.material(parent, {64, 64, 64}) == 82
  end

  @tag :recolor
  test "recolor rejects non-solid targets, invalid selections and oversized input", c do
    for target <- [0, 21, 22, 32, 999] do
      assert {:error, :invalid_gm_args} = World.gm(c.w, "bad-target", :recolor, %{from: 13, to: target, cells: [{1, 1, 1}]})
    end
    assert {:error, :gm_too_large} = World.gm(c.w, "big-box", :recolor,
      %{from: 13, to: 82, box: {{0, 0, 0}, {16, 16, 15}}})
    assert {:error, :gm_too_large} = World.gm(c.w, "big-points", :recolor,
      %{from: 13, to: 82, cells: for(x <- 0..4096, do: {x, 1, 1})})
    for selection <- [%{cells: [{1.5, 1, 1}]}, %{box: {{2, 1, 1}, {1, 1, 1}}},
                      %{cells: [{1, 1, 1}], box: {{1, 1, 1}, {1, 1, 1}}},
                      %{cells: [{1, 1, 1}], precision: :micro}] do
      assert {:error, :invalid_gm_args} = World.gm(c.w, "bad-selection", :recolor, Map.merge(selection, %{from: 13, to: 82}))
    end
    assert World.seq(c.w) == 0
  end
end
