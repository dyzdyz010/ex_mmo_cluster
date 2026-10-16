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
    data = Jason.decode!(File.read!(VoxelRegion.TestSupport.catalog()))
      |> Map.put("liquid", %{"step_seconds" => 3600, "gravity_units_per_step" => div(@cap, 4),
        "side_units_per_step" => div(@cap, 16), "side_threshold_units" => div(@cap, 8)})
    File.write!(catalog, Jason.encode!(data))
    opts = [source: Source, log: Log, root: root, observer: self(), name: nil, property_catalog_path: catalog,
      prefab_catalog_path: Path.join(root, "prefabs"), production_materials: [11, 19, 21],
      liquid_bounds: {{0, 0, 0}, {8, 8, 8}}, gm_tools: Map.get(context, :gm, true)]
    w = start_supervised!({World, opts})
    %{w: w, opts: opts, root: root}
  end

  defp material(w, cell), do: hd(World.material_snapshot(w, [], [cell]).probe_occupancy).material
  defp micros(w, cell),
    do: hd(World.material_snapshot(w, [], [cell], :micro).probe_occupancy) |> Map.get(:micro_cells, []) |> Enum.map(&{&1.micro, &1.material})
  defp quantities(w), do: World.simulation_snapshot(w, [], {{0, 0, 0}, {1, 1, 1}}).liquid_quantities
  defp restart(c), do: (stop_supervised!(World); start_supervised!({World, c.opts}))

  # 只测试：两个微格（11 号）的 VXPD v3 定义，锚点微格坐标。
  defp define(c) do
    cells = for {{x, y, z}, m} <- [{{0, 0, 0}, 11}, {{1, 0, 0}, 11}], into: <<>>,
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
    id = define(c)
    {:ok, birth} = World.place_prefab(c.w, id, {40, 8, 8}, 0)
    assert micros(c.w, {5, 1, 1}) == [{{40, 8, 8}, 11}, {{41, 8, 8}, 11}]
    assert {:error, :gm_noop} = World.gm(c.w, "keep", :clear, %{box: {{5, 1, 1}, {5, 1, 1}}})
    seq = World.seq(c.w)
    assert {:ok, %{instance: moved, from: {40, 8, 8}}} =
      World.gm(c.w, "mv1", :move_instance, %{instance: {birth, 0}, anchor: {48, 8, 8}, orientation: 0})
    assert moved == {seq + 1, 0} and World.seq(c.w) == seq + 1
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
end
