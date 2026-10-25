defmodule VoxelRegion.ParcelWorldTest do
  @moduledoc """
  只测试：地块导出与维护安装（`World.parcel_export/2`、`World.parcel_install/4`）经两个真实 World 的提交、日志与冷启动回放。
  两个世界的基底都是全空气替身，内容用 GM 与作者放置建立；期望全部手算：
  源盒 x 62..65 × y 1..3 × z 1..2（24 格，跨 x=64 区域界），Δ = {-128, -5, -4}，目标盒 x -66..-63（跨 x=-64 界）× y -4..-2 × z -3..-2。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Source, Log}

  @cap 2_097_152
  @box {{62, 1, 1}, {66, 4, 3}}
  @delta {-128, -5, -4}

  setup do
    catalog_source = Path.expand("../Playable/Published/7175e287796154282593c925ee8b787c5d0ddce50ceba41925973d3612543d20.json",
      Path.dirname(VoxelRegion.TestSupport.catalog()))
    data = Jason.decode!(File.read!(catalog_source))
      |> Map.put("liquid", %{"step_seconds" => 3600, "gravity_units_per_step" => div(@cap, 4),
        "side_units_per_step" => div(@cap, 16), "side_threshold_units" => div(@cap, 8)})

    worlds = for {name, ambient, bounds} <- [source: {293.15, {{60, 0, 0}, {70, 8, 8}}}, target: {283.15, {{-70, -8, -8}, {-60, 0, 0}}}]
                 |> Enum.map(fn {n, {a, b}} -> {n, a, b} end), into: %{} do
      root = Path.join(System.tmp_dir!(), "parcel_#{name}_#{System.pid()}_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "prefabs"))
      on_exit(fn -> File.rm_rf!(root) end)
      File.write!(Path.join(root, "catalog.json"), Jason.encode!(data))
      File.write!(Path.join(root, "environment.json"), Jason.encode!(%{ambient_kelvin: ambient, environment_w_per_m2_k: 0.0,
        tolerance_kelvin: 0.00001, emissivity: 0.0, view_range_cells: 8, circuit_min_power_w: 1.0}))
      opts = [source: Source, log: Log, root: root, observer: self(), name: nil,
        property_catalog_path: Path.join(root, "catalog.json"), thermal_environment_path: Path.join(root, "environment.json"),
        prefab_catalog_path: Path.join(root, "prefabs"), production_materials: [11, 19, 21], liquid_bounds: bounds, gm_tools: true]
      {name, %{w: start_supervised!({World, opts}, id: name), opts: opts, root: root}}
    end

    %{s: worlds.source, t: worlds.target}
  end

  defp material(w, cell), do: hd(World.material_snapshot(w, [], [cell]).probe_occupancy).material
  defp micros(w, cell),
    do: hd(World.material_snapshot(w, [], [cell], :micro).probe_occupancy) |> Map.get(:micro_cells, []) |> Enum.map(&{&1.micro, &1.material})
  # 观察窗口是 chunk 坐标；覆盖两个测试世界的全部内容。
  @everywhere {{-100, -100, -100}, {100, 100, 100}}
  defp quantities(w), do: World.simulation_snapshot(w, [], @everywhere).liquid_quantities
  defp restart(world, id), do: (stop_supervised!(id); start_supervised!({World, world.opts}, id: id))

  # 只测试 VXPD：两微格木（19）；一宏格木加顶面 8×8 石（11）附件。
  defp publish(world, name, definition) do
    bytes = VoxelRegion.Prefab.encode(definition)
    File.write!(Path.join([world.root, "prefabs", name <> ".vxpd"]), bytes)
    :ok = World.publish_prefabs(world.w, Path.join(world.root, "prefabs"))
    :crypto.hash(:sha256, bytes)
  end

  defp pair(world), do: publish(world, "pair", %{cells: [{{0, 0, 0}, 19}, {{1, 0, 0}, 19}], children: []})
  defp post(world), do: publish(world, "post", %{cells: [], macro_cells: [{{0, 0, 0}, 19}], children: [],
    attachments: [%{slot: 1, kind: 0, axis: 1, anchor: {0, 8, 0}, size: 8, material: 11}]})

  # 源：x 62..65 y1 z1 石；{62,2,1} 满格水；{63,2,1} 两微格木实例被 GM 削去一格；{64,2,1} 宏格木实例带顶面石附件。
  defp build_source(s) do
    {:ok, _} = World.gm(s.w, "rock", :fill, %{box: {{62, 1, 1}, {65, 1, 1}}, material: 11})
    {:ok, _} = World.gm(s.w, "water", :fill, %{box: {{62, 2, 1}, {62, 2, 1}}, material: 21})
    {:ok, a} = World.place_prefab(s.w, pair(s), {504, 16, 8}, 0)
    {:ok, %{cells: 1}} = World.gm(s.w, "cut", :clear, %{box: {{505, 16, 8}, {505, 16, 8}}, precision: :micro, instances: true})
    {:ok, b} = World.place_prefab(s.w, post(s), {512, 16, 8}, 0)
    {a, b}
  end

  # 目标：原山体石 x -67..-62 × y -4..-2 × z -3..-2，盒内 {-64,-3,-3} 与盒外 {-61,-3,-3} 各有一个两微格实例。
  defp build_target(t) do
    id = pair(t)
    {:ok, inside} = World.place_prefab(t.w, id, {-512, -24, -24}, 0)
    {:ok, outside} = World.place_prefab(t.w, id, {-488, -24, -24}, 0)
    {:ok, _} = World.gm(t.w, "mountain", :fill, %{box: {{-67, -4, -3}, {-62, -2, -2}}, material: 11})
    {inside, outside}
  end

  test "a parcel replaces exactly the shifted box, carries content with new identities and replays", %{s: s, t: t} do
    build_source(s)
    {_, outside} = build_target(t)
    assert {:ok, parcel} = World.parcel_export(s.w, @box)
    assert map_size(parcel.cells) == 24 and map_size(parcel.instances) == 2 and map_size(parcel.attachment_owners) == 1

    before_seq = World.seq(t.w)
    assert {:ok, receipt} = World.parcel_install(t.w, "ruyuan-slice", parcel, @delta)
    assert %{seq: seq, cells: 24, instances: 2, removed_instances: 1, attachments: 1, liquid_cells: 1,
      box: {{-66, -4, -3}, {-62, -1, -1}}} = receipt
    assert seq == before_seq + 1 and World.seq(t.w) == seq
    # 石：新 4 格＋顶面附件 64 槽（面厚 1/512 m × (1/8 m)² × 每 m³ @cap = 每槽 64 单位），原山体盒内 24 格去掉实例占的 1 格 = 23 格。
    # 木：新 1 微格＋1 宏格，减原盒内实例 2 微格（每微格 @cap/512）。水 +1 满格。
    assert receipt.units == %{11 => (4 - 23) * @cap + 64 * 64, 19 => @cap + div(@cap, 512) - 2 * div(@cap, 512), 21 => @cap}

    check = fn w ->
      assert Enum.map(-66..-63, &material(w, {&1, -4, -3})) == [11, 11, 11, 11]
      # 源空气挖穿原山体；盒外同区域的山体不变。
      assert Enum.map(-66..-63, &material(w, {&1, -4, -2})) == [0, 0, 0, 0]
      assert material(w, {-67, -4, -2}) == 11 and material(w, {-62, -4, -2}) == 11
      assert material(w, {-66, -3, -3}) == 21
      assert quantities(w) == %{{-66, -3, -3} => @cap}
      # 削过的实例只剩存活的那一格：微格 504-1024, 16-40, 8-32；新身份出生于安装事务，放置者归作者。
      assert [{{-520, -24, -24}, 19}] = micros(w, {-65, -3, -3})
      assert [%{instance: [^seq, _], placed_by: nil}] = hd(World.material_snapshot(w, [], [{-65, -3, -3}]).probe_occupancy).slots
      assert material(w, {-64, -3, -3}) == 19
      # 原盒内实例已清，盒外实例原样。
      assert micros(w, {-61, -3, -3}) == [{{-488, -24, -24}, 19}, {{-487, -24, -24}, 19}]
      outside = [outside, 0]
      assert [%{instance: ^outside}] = hd(World.material_snapshot(w, [], [{-61, -3, -3}]).probe_occupancy).slots
      # 附件：顶面 64 槽（源微格 x 512..519, y 24, z 8..15）平移 8Δ，新附件身份。
      observed = VoxelRegion.TestSupport.observe(w, [], @everywhere)
      assert [{{x, -16, z}, id}] = for {{3, _}, row} <- observed.damage, do: {row.micro, row.incarnation}
      assert x in -512..-505 and z in -24..-17 and id >= seq
      # 水的焓按目标环境 283.15 K 重设（源世界 293.15 K）。
      assert [water] = for {{0, _, _, _, 21}, row} <- observed.damage, do: row
      assert_in_delta water.temperature_kelvin, 283.15, 1.0e-6
    end

    check.(t.w)
    check.(restart(t, :target))
  end

  test "same key installs once; a box that cuts an instance tree is refused on both sides", %{s: s, t: t} do
    build_source(s)
    build_target(t)
    {:ok, parcel} = World.parcel_export(s.w, @box)
    {:ok, receipt} = World.parcel_install(t.w, "k", parcel, @delta)
    assert {:ok, ^receipt} = World.parcel_install(t.w, "k", parcel, @delta)
    assert World.seq(t.w) == receipt.seq

    # 源盒只到 y 2：带顶面附件的木柱在盒内，附件槽却落在 y 3 的支撑侧，不能切走。
    assert {:error, :attachment_crosses_boundary} = World.parcel_export(s.w, {{64, 1, 1}, {65, 3, 3}})
    # 目标里横跨盒界的原有实例拒绝整笔安装：微格 -417/-416 落在宏格 -53/-52，Δx=-114 时目标盒 x -52..-49。
    id = pair(t)
    {:ok, wide} = World.place_prefab(t.w, id, {-417, -24, -24}, 0)
    seq = World.seq(t.w)
    assert {:error, {:target_instance_crosses_boundary, {^wide, 0}}} = World.parcel_install(t.w, "k2", parcel, {-114, -5, -4})
    assert World.seq(t.w) == seq
  end

  test "a player-placed attachment inside the box travels with the parcel under a new identity", %{s: s, t: t} do
    build_source(s)
    # 玩家（cid 1001）在 {65,1,1} 石的顶面挂 8×8 石面：锚点微格 (520, 16, 8)，64 槽 × 64 单位。
    actor = %{cid: 1001, gate: self(), identity: :parcel, refresh: &VoxelRegion.TestSupport.Actor.tool_context/2,
      eye: {66.0, 2.5, 1.5}, tick_us: 16667}
    actor = Map.put(actor, :player, start_supervised!({VoxelRegion.TestSupport.Actor, actor}))
    {:ok, _} = World.material_supply(s.w, 1001, "parcel-face", %{11 => 4096})
    {:ok, free} = World.attachment_intent(s.w, actor, %{request_id: 1, client_intent_seq: 1, logical_scene_id: 1, action: 0,
      kind: 0, axis: 1, size: 8, anchor: {520, 16, 8}, id: 0, material: 11, tool_id: 1})

    assert {:ok, parcel} = World.parcel_export(s.w, @box)
    # 实例带的顶面附件与玩家附件各 64 槽；只有前者有主人。
    assert map_size(parcel.attachments) == 128 and map_size(parcel.attachment_owners) == 1
    assert {:ok, %{seq: seq, attachments: 2}} = World.parcel_install(t.w, "with-face", parcel, @delta)

    check = fn w ->
      observed = VoxelRegion.TestSupport.observe(w, [], @everywhere)
      rows = for {{3, _}, row} <- observed.damage, do: {row.micro, row.incarnation}
      # 玩家附件平移 8Δ：微格 x 520..527 → -504..-497，y 16 → -24，z 8..15 → -24..-17；新身份，不沿用源 free。
      assert [{{x, -24, z}, id}] = for {{_, -24, _}, _} = r <- rows, do: r
      assert x in -504..-497 and z in -24..-17 and id >= seq and id != free
      assert length(rows) == 2
    end

    check.(t.w)
    check.(restart(t, :target))
  end

  # 2026-10-24 M0 复现：目标世界里已有无主人的独立附件（玩家附件只在 attachments，不在 attachment_owners）时，
  # 目标盒检查曾对全世界附件取主人而崩溃；盒外附件与本次安装无关，安装应照常提交。
  test "a player attachment outside the target box does not block the install", %{s: s, t: t} do
    build_source(s)
    build_target(t)
    # 玩家（cid 1002）在盒外 {-62,-2,-2} 山体石顶面挂 8×8 石面：锚点微格 (-496, -8, -16)。
    actor = %{cid: 1002, gate: self(), identity: :parcel, refresh: &VoxelRegion.TestSupport.Actor.tool_context/2,
      eye: {-61.0, -0.5, -1.5}, tick_us: 16667}
    actor = Map.put(actor, :player, start_supervised!({VoxelRegion.TestSupport.Actor, actor}))
    {:ok, _} = World.material_supply(t.w, 1002, "outside-face", %{11 => 4096})
    {:ok, _} = World.attachment_intent(t.w, actor, %{request_id: 1, client_intent_seq: 1, logical_scene_id: 1, action: 0,
      kind: 0, axis: 1, size: 8, anchor: {-496, -8, -16}, id: 0, material: 11, tool_id: 1})

    assert {:ok, parcel} = World.parcel_export(s.w, @box)
    assert {:ok, %{cells: 24}} = World.parcel_install(t.w, "beside-face", parcel, @delta)
  end

  test "cells already equal to the target's effective value add no overlay entry", %{s: s, t: t} do
    build_source(s)
    {:ok, parcel} = World.parcel_export(s.w, @box)
    # 只数 L0：安装另会写受影响的粗层格。
    l0 = fn -> Enum.count(:sys.get_state(t.w).overlay, &match?({{0, _}, _}, &1)) end
    overlay = l0.()
    # 目标是全空气替身：盒内 24 格里与空气底图相同的格（源 y 3 层与细化格的宏格值）不写，只有非空气格各一条（旧做法 24 条）。
    solid = Enum.count(parcel.cells, fn {_, {m, _}} -> m != 0 end)
    assert solid < 24
    {:ok, _} = World.parcel_install(t.w, "first", parcel, @delta)
    assert l0.() == overlay + solid
  end

  test "an installed parcel accepts ordinary edits afterwards", %{s: s, t: t} do
    build_source(s)
    {:ok, parcel} = World.parcel_export(s.w, @box)
    {:ok, _} = World.parcel_install(t.w, "k", parcel, @delta)
    assert {:ok, _} = World.apply_edit(t.w, {-63, -4, -3}, 0)
    assert material(restart(t, :target), {-63, -4, -3}) == 0
  end
end
