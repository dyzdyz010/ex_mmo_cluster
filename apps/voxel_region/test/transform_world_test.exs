defmodule VoxelRegion.TransformWorldTest do
  @moduledoc """
  只测试：R8 单向转化（铜矿石 16 + 接触的煤 15 → 铜 24）经真实 World 热提交、几何事务与回放。

  目录夹具 = 已发布 fbd4f301 字节，另给 16 加转化字段（X 400 K、反应热 1e5 J/m³、每单位矿耗 0.25 单位煤），
  并把 11/16/24 的热损伤阈值提到 1e5 K，使场景只观察转化。场景由作者编辑入口 / place_prefab 与 Test-only
  热源实验一次建立；时间只经 :thermal_commit 推进。期望值来自目录算术与账目恒等式，不取自内核输出。
  """
  use ExUnit.Case, async: false
  @moduletag :transform
  alias VoxelRegion.{World, Damage}
  alias MmoContracts.Voxel.{Codec, Payload}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @digest "fbd4f30106f1cecbd5ea73cb361b7e19058a531420fbaf86998ad89f43f6ba70"
  @ambient 293.15
  @stone 11
  @coal 15
  @ore 16
  @copper 24
  @x 400.0
  @heat 1.0e5
  @ratio 0.25
  @ore_cell {2, 1, 2}
  @coal_cell {3, 1, 2}

  setup do
    root = Path.join(System.tmp_dir!(), "transform_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @digest <> ".json")))
    data = Map.update!(data, "materials", &Enum.map(&1, fn m ->
      m = if m["material_id"] in [@stone, @ore, @copper], do: Map.put(m, "heat_resistance_kelvin", 1.0e5), else: m
      if m["material_id"] == @ore,
        do: Map.merge(m, %{"transform_material_id" => @copper, "transform_kelvin" => @x,
          "transform_heat_per_macro_j" => @heat, "transform_reductant_material_id" => @coal,
          "transform_reductant_units_per_unit" => @ratio}),
        else: m
    end))
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(data))
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment.json"), env)
    prefabs = Path.join(root, "prefabs")
    File.mkdir_p!(prefabs)
    materials = Map.new(data["materials"], &{&1["material_id"], &1})
    opts = [source: VoxelRegion.TestSupport.Source, log: VoxelRegion.TestSupport.Log, root: root,
      observer: self(), name: nil, property_catalog_path: catalog, thermal_environment_path: env,
      prefab_catalog_path: prefabs, production_materials: [@stone, @coal, @ore, @copper]]
    macro_units = data["attachments"]["material_units_per_micro"] * 512
    %{root: root, opts: opts, prefabs: prefabs, materials: materials, macro_units: macro_units, data: data}
  end

  defp start(c), do: start_supervised!({World, c.opts})

  defp heat(c, w, cell, power, energy) do
    path = Path.join(c.root, "thermal.json")
    File.write!(path, Jason.encode!(%{classification: "Test-only", source_macro: Tuple.to_list(cell),
      ambient_kelvin: @ambient, environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.0,
      view_range_cells: 8, power_w: power, energy_j: energy}))
    :ok = World.thermal_experiment(w, path)
  end

  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [1001], {{-1, -1, -1}, {8, 8, 8}})
  defp occupancy(w, cell), do: hd(World.material_snapshot(w, [], [cell], :micro).probe_occupancy)

  # 每次手动提交推进 0.5 s；最慢的炼铜场景约 2800 s 才平息。固定节拍之前每次手动提交还会多排一条后台定时链，
  # 旧上限 4000 次靠那些额外提交才够用。
  defp run_until(w, stop?, left \\ 8000) do
    send(w, :thermal_commit)
    s = observe(w)
    cond do
      stop?.(s) -> s
      left == 0 -> flunk("condition not reached; elapsed #{s.thermal.elapsed_s}")
      true -> run_until(w, stop?, left - 1)
    end
  end

  defp settle(w), do: run_until(w, &(not &1.thermal.active))
  defp micro({x, y, z}), do: {x * 8, y * 8, z * 8}
  defp node(s, micro), do: Enum.find(Map.values(s.damage), &(&1.micro == micro and &1.granularity in [0, 1]))

  # 只看同一快照，避免与后台 500 ms 提交交错。
  defp copper?(s, micro), do: match?(%{material: @copper}, node(s, micro))

  defp volume(row), do: Damage.volume(row.granularity)

  # 显热账：世界全部带温度节点 C·V·(T−Ta) = 供热 + 环境交换 + 重标 − 移除 − 转化吸热。
  defp assert_energy_closes(c, s) do
    sensible = for {_, row} <- s.damage, row.granularity in [0, 1], Map.has_key?(row, :temperature_kelvin), reduce: 0.0,
      do: (sum -> sum + c.materials[row.material]["heat_capacity_per_macro"] * volume(row) * (row.temperature_kelvin - @ambient))
    ledger = s.thermal.supplied_j + s.thermal.environment_j + Map.get(s.thermal, :parameter_rebase_j, 0.0) -
      Map.get(s.thermal, :removed_j, 0.0) - Map.get(s.thermal, :transform_j, 0.0)
    assert_in_delta sensible, ledger, 1.0e-6 * max(1.0, s.thermal.supplied_j)
  end

  # 燃料账：初始化 = 燃烧放热 + 弃置 + 作还原剂消耗 + 行上余量。
  defp assert_fuel_closes(s) do
    left = for {_, row} <- s.damage, reduce: 0.0, do: (sum -> sum + Map.get(row, :remaining_fuel_j, 0.0))
    assert_in_delta Map.get(s.thermal, :fuel_initialized_j, 0.0),
      Map.get(s.thermal, :combustion_j, 0.0) + Map.get(s.thermal, :discarded_fuel_j, 0.0) +
        Map.get(s.thermal, :transform_reductant_fuel_j, 0.0) + left, 1.0e-3
  end

  defp transform_txn(w, from) do
    Enum.filter(World.entries_after(w, from), &Enum.any?(Map.get(&1, :property_states, []),
      fn t -> t.material == @copper and t.flags == 0 end)) |> List.first()
  end

  defp payloads(txn), do: for(%{payload: bytes} <- txn.entries, do: elem(Payload.decode(bytes), 1))

  test "宏格矿石达到 X 且接触煤：同体积换成铜一次，煤按比例扣减，热账与燃料账闭合，事务与冷恢复可见", c do
    w = start(c)
    {:ok, _} = World.apply_edits(w, [{@ore_cell, @ore}, {@coal_cell, @coal}])
    heat(c, w, @ore_cell, 20_000.0, 4.0e6)
    from = observe(w).seq
    converted = run_until(w, &copper?(&1, micro(@ore_cell)))

    # 事务：同一笔里旧矿行删除、铜行以新纪元建立并带 L0 载荷，编码可往返（客户端同一路径）。
    txn = transform_txn(w, from)
    assert Map.fetch!(txn.epochs, @ore_cell) == txn.seq
    assert Enum.any?(txn.property_states, &(&1.material == @ore and &1.flags == 1))
    [p] = Enum.filter(payloads(txn), &(&1.level == 0))
    assert Payload.material(p, Payload.local(p.region, @ore_cell)) == @copper
    assert {:ok, decoded} = Codec.decode_transaction(IO.iodata_to_binary(Codec.encode_transaction(txn)))
    assert decoded.entries == txn.entries

    # 转化前一笔提交的矿温 T：铜温 = Ta + (C矿(T−Ta) − H)/C铜。
    [previous] = World.entries_after(w, txn.seq - 2) |> Enum.take(1)
    ore_t = Enum.find(previous.property_states, &(&1.material == @ore and &1.granularity == 0)).temperature_kelvin
    assert ore_t >= @x
    copper = Enum.find(txn.property_states, &(&1.material == @copper))
    c_ore = c.materials[@ore]["heat_capacity_per_macro"]
    c_cu = c.materials[@copper]["heat_capacity_per_macro"]
    assert_in_delta copper.temperature_kelvin, @ambient + (c_ore * (ore_t - @ambient) - @heat) / c_cu, 1.0e-9
    assert copper.hp == copper.max_hp

    # 数量：1 m³ 矿 = 512×4096 量子换成等量铜；煤化学燃料少 0.25×800 MJ。
    fuel = c.materials[@coal]["fuel_energy_per_macro_j"]
    assert converted.thermal.transform_units == c.macro_units
    assert_in_delta converted.thermal.transform_j, @heat, 1.0e-9
    assert_in_delta converted.thermal.transform_reductant_fuel_j, @ratio * fuel, 1.0e-3
    assert_in_delta node(converted, micro(@coal_cell)).remaining_fuel_j, (1 - @ratio) * fuel, 1.0e-3
    assert_energy_closes(c, converted)
    assert_fuel_closes(converted)

    # 不可逆：冷却到静止仍是铜，且只转化一次。
    settled = settle(w)
    assert occupancy(w, @ore_cell).material == @copper
    assert settled.thermal.transform_units == c.macro_units
    assert_energy_closes(c, settled)

    stop_supervised!(World)
    w = start(c)
    assert observe(w).damage == settled.damage
    assert observe(w).thermal == settled.thermal
    assert occupancy(w, @ore_cell).material == @copper

    # 正常采挖回收：铜得整格 512×4096，煤得 floor(512×4096×0.75)。
    :ok = VoxelRegion.TestSupport.mine_authored(w, 1001, @ore_cell)
    :ok = VoxelRegion.TestSupport.mine_authored(w, 1001, @coal_cell)
    balances = observe(w).material_balances
    assert balances[{1001, @copper}] == c.macro_units
    assert balances[{1001, @coal}] == floor(c.macro_units * (1 - @ratio))
  end

  test "低于 X 或无接触还原剂时不转化", c do
    # 热源总能量 1 MJ：绝热上限 Ta + 1e6/21360 = 339.97 K < X。
    w = start(c)
    {:ok, _} = World.apply_edits(w, [{@ore_cell, @ore}, {@coal_cell, @coal}])
    heat(c, w, @ore_cell, 20_000.0, 1.0e6)
    s = settle(w)
    assert occupancy(w, @ore_cell).material == @ore
    refute Map.has_key?(s.thermal, :transform_units)

    # 无煤：另一格孤立矿石越过 X 仍保持矿石，只是热。
    lone = {6, 1, 6}
    {:ok, _} = World.apply_edits(w, [{lone, @ore}])
    heat(c, w, lone, 20_000.0, 4.0e6)
    hot = run_until(w, &(node(&1, micro(lone)).temperature_kelvin >= @x + 20))
    assert occupancy(w, lone).material == @ore
    assert occupancy(w, @ore_cell).material == @ore
    refute Map.has_key?(hot.thermal, :transform_units)
  end

  test "精确微格矿石按体积转化，prefab 归属与出生不变，删除实例一并删除铜", c do
    # 只测试：一个 prefab 两个微格：矿 (0,0,0) 与煤 (1,0,0)，锚在石热源宏格 +x 面外。
    bytes = <<"VXPD", 1::32-little, 2::32-little,
      0::signed-little-32, 0::signed-little-32, 0::signed-little-32, @ore::16-little,
      1::signed-little-32, 0::signed-little-32, 0::signed-little-32, @coal::16-little, 0::32-little>>
    id = :crypto.hash(:sha256, bytes)
    File.write!(Path.join(c.prefabs, Base.encode16(id) <> ".vxpd"), bytes)
    w = start(c)
    :ok = World.publish_prefabs(w, c.prefabs)
    {:ok, _} = World.apply_edits(w, [{@ore_cell, @stone}])
    anchor = {24, 8, 16}
    {:ok, birth} = World.place_prefab(w, id, anchor, 0)
    heat(c, w, @ore_cell, 50_000.0, 1.2e7)
    from = observe(w).seq
    cell = @coal_cell
    converted = run_until(w, &copper?(&1, anchor))

    micro_cells = occupancy(w, cell).micro_cells
    assert Enum.find(micro_cells, &(&1.micro == anchor)).instance == {birth, 0}
    assert Enum.find(micro_cells, &(&1.micro == {25, 8, 16})).material == @coal
    copper = node(converted, anchor)
    assert copper.material == @copper and copper.owner == {birth, 0} and copper.incarnation == birth

    # 体积 1/512 m³：4096 量子；煤燃料少 0.25×800 MJ/512。
    fuel = c.materials[@coal]["fuel_energy_per_macro_j"]
    assert converted.thermal.transform_units == div(c.macro_units, 512)
    assert_in_delta converted.thermal.transform_j, @heat / 512, 1.0e-9
    assert_in_delta node(converted, {25, 8, 16}).remaining_fuel_j, fuel / 512 * (1 - @ratio), 1.0e-6
    assert_energy_closes(c, converted)
    assert_fuel_closes(converted)

    txn = transform_txn(w, from)
    [p] = Enum.filter(payloads(txn), &(&1.level == 0))
    slots = Map.fetch!(p.refined, Payload.cell_index(Payload.local(p.region, cell)))
    assert Enum.sort(Map.values(slots)) == [{@coal, {birth, 0}}, {@copper, {birth, 0}}]

    {:ok, _} = World.remove_prefab(w, {birth, 0})
    assert occupancy(w, cell).refined == false
  end

  test "prefab 拥有的宏格矿石转化后仍归该实例", c do
    cells = %{{0, 0, 0} => @ore, {1, 0, 0} => @coal}
    body = for {{x, y, z}, m} <- Enum.sort(cells), into: <<>>,
      do: <<x::signed-little-32, y::signed-little-32, z::signed-little-32, m::16-little>>
    bytes = <<"VXPD", 3::32-little, 0::32-little, 0::32-little, 0::32-little, map_size(cells)::32-little, body::binary>>
    id = :crypto.hash(:sha256, bytes)
    File.write!(Path.join(c.prefabs, Base.encode16(id) <> ".vxpd"), bytes)
    w = start(c)
    :ok = World.publish_prefabs(w, c.prefabs)
    {:ok, birth} = World.place_prefab(w, id, micro(@ore_cell), 0)
    heat(c, w, @ore_cell, 20_000.0, 4.0e6)
    converted = run_until(w, &copper?(&1, micro(@ore_cell)))
    copper = node(converted, micro(@ore_cell))
    assert copper.owner == {birth, 0}
    assert {:ok, owned} = World.instance_cells(w, {birth, 0})
    assert Enum.sort(owned) == [@ore_cell, @coal_cell]
    assert_energy_closes(c, converted)

    {:ok, _} = World.remove_prefab(w, {birth, 0})
    assert occupancy(w, @ore_cell).material == 0
    assert occupancy(w, @coal_cell).material == 0
  end

  test "目录：转化字段须成组且还原剂可燃；可经参数发布在线加入", c do
    base = Jason.decode!(File.read!(Path.join(@fixtures, @digest <> ".json")))
    broken = Map.update!(base, "materials", &Enum.map(&1, fn m ->
      if m["material_id"] == @ore, do: Map.merge(m, %{"transform_material_id" => @copper, "transform_kelvin" => @x}), else: m
    end))
    path = Path.join(c.root, "broken.json")
    File.write!(path, Jason.encode!(broken))
    assert_raise KeyError, fn -> Damage.load(path) end

    stone_reductant = put_in(Jason.decode!(File.read!(c.opts[:property_catalog_path])),
      ["materials", Access.at(@ore), "transform_reductant_material_id"], @stone)
    File.write!(path, Jason.encode!(stone_reductant))
    assert_raise MatchError, fn -> Damage.load(path) end

    # 旧目录（无转化字段）的世界已有热矿行，参数发布加入转化字段被接纳，下一次热提交即转化。
    plain = Path.join(c.root, "plain.json")
    File.cp!(Path.join(@fixtures, @digest <> ".json"), plain)
    w = start_supervised!({World, Keyword.put(c.opts, :property_catalog_path, plain)})
    {:ok, _} = World.apply_edits(w, [{@ore_cell, @ore}, {@coal_cell, @coal}])
    heat(c, w, @ore_cell, 20_000.0, 4.0e6)
    run_until(w, &(node(&1, micro(@ore_cell)).temperature_kelvin >= @x + 5))
    assert occupancy(w, @ore_cell).material == @ore
    :ok = World.publish_parameters(w, c.opts[:property_catalog_path], :crypto.hash(:sha256, File.read!(plain)))
    run_until(w, &copper?(&1, micro(@ore_cell)), 4)
  end
end
