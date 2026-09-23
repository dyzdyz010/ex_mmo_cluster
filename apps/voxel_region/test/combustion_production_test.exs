defmodule VoxelRegion.CombustionProductionTest do
  @moduledoc """
  只测试：正式发布的生产目录与生产热环境下的燃烧行为。

  目录夹具 `fixtures/combustion/<digest>.json` 必须与 UE 发布的 DA_MaterialCoverageV1 字节一致
  （文件名即 sha256）；热环境为 Saved/Gameplay/Server/environment.json 的副本。
  材料只经 material_supply 入账，炉体经 publish_prefabs + prefab_intent 付费建造，
  点火经 tool_intent 工具 9，时间只经 :thermal_commit 推进。
  期望值全部来自目录算术或设计阈值（Docs：combustion retune design §4），不取自内核输出。
  """
  use ExUnit.Case, async: false
  @moduletag :combustion_production
  alias VoxelRegion.{World, Damage}
  alias VoxelRegion.TestSupport.{Source, Actor, Log}

  @digest "fbd4f30106f1cecbd5ea73cb361b7e19058a531420fbaf86998ad89f43f6ba70"
  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @wood 19
  @stone 11
  @coal 15
  @clay 8

  # 只测试：炉体 4×3×3 石壳（相对宏格 x 0..3, y 0..2, z 0..2），木芯 (1,1,1)(2,1,1)，
  # 前方开口 (3,1,1) 为空气；从 +x 侧经开口点燃前芯 (2,1,1)。
  @front {2, 1, 1}
  @rear {1, 1, 1}
  @opening {3, 1, 1}
  @furnace (for x <- 0..3, y <- 0..2, z <- 0..2, {x, y, z} != @opening, into: %{} do
              {{x, y, z}, if({x, y, z} in [@front, @rear], do: @wood, else: @stone)}
            end)

  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [1001], {{-1, -1, -1}, {1, 1, 1}})

  defp start(root, catalog_path) do
    catalog = Path.join(root, "properties.json")
    File.cp!(catalog_path, catalog)
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment.json"), env)
    prefabs = Path.join(root, "prefabs")
    File.mkdir_p!(prefabs)
    opts = [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env, prefab_catalog_path: prefabs,
      production_materials: [@clay, @stone, @coal, @wood]]
    {start_supervised!({World, opts}), prefabs}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "combustion_production_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(@fixtures, @digest <> ".json")
    data = Jason.decode!(File.read!(path))
    materials = Map.new(data["materials"], &{&1["material_id"], &1})
    tools = Map.new(data["tools"], &{&1["tool_id"], &1})
    env = Jason.decode!(File.read!(Path.join(@fixtures, "environment.json")))
    # 一宏格 = 512 微格；余额单位为 material_units_per_micro 量子。
    macro_units = data["attachments"]["material_units_per_micro"] * 512
    %{root: root, path: path, data: data, materials: materials, tools: tools,
      ambient: env["ambient_kelvin"], macro_units: macro_units}
  end

  defp actor(eye) do
    actor = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: eye, tick_us: 16_667}
    Map.put(actor, :player, start_supervised!({Actor, actor}, id: make_ref()))
  end

  defp build(w, prefabs, actor, macros, anchor, seq) do
    cells = for {{x, y, z}, m} <- Enum.sort(macros), into: <<>>,
      do: <<x::signed-little-32, y::signed-little-32, z::signed-little-32, m::16-little>>
    bytes = <<"VXPD", 3::32-little, 0::32-little, 0::32-little, 0::32-little,
      map_size(macros)::32-little, cells::binary>>
    id = :crypto.hash(:sha256, bytes)
    File.write!(Path.join(prefabs, Base.encode16(id) <> ".vxpd"), bytes)
    :ok = World.publish_prefabs(w, prefabs)
    {:ok, _} = World.prefab_intent(w, actor, :voxel_prefab_place_v1,
      %{definition_id: id, anchor: anchor, orientation: 0, client_intent_seq: seq})
  end

  defp operate(w, actor, direction, tool, seq) do
    query = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: tool,
      direction: direction, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, target} = World.tool_intent(w, actor, query)
    request = Map.merge(query, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
    World.tool_intent(w, Map.merge(actor, %{received_us: seq * 1_000_000, clock_node: node()}),
      %{request | action: 1})
  end

  defp micro({x, y, z}), do: {x * 8, y * 8, z * 8}
  defp macro_row?(row, macro), do: row.granularity == 0 and row.micro == micro(macro)
  defp at(rows, macro), do: Enum.find(Map.values(rows), &macro_row?(&1, macro))
  defp balance(w, m), do: Enum.find(World.material_balances(w, 1001), &(&1.material == m)).balance

  # 每次推进后按正式事务历史重建行状态；后台 500 ms 定时器可能插入额外提交，历史不遗漏任何一笔。
  defp run_until(w, stop?) do
    send(w, :thermal_commit)
    state = observe(w)
    if stop?.(state), do: state, else: run_until(w, stop?)
  end

  # 事务无热账时沿用上一笔的模拟时刻。
  defp history(w, from_seq, rows, elapsed) do
    World.entries_after(w, from_seq)
    |> Enum.map_reduce({rows, elapsed}, fn txn, {rows, elapsed} ->
      rows = Enum.reduce(Map.get(txn, :property_states, []), rows, fn t, rows ->
        if t.flags == 1, do: Map.delete(rows, Damage.key(t)), else: Map.put(rows, Damage.key(t), t)
      end)
      elapsed = if txn[:thermal], do: txn.thermal.elapsed_s, else: elapsed
      {{elapsed, rows}, {rows, elapsed}}
    end)
    |> elem(0)
  end

  test "炉芯点火：燃满 fuel/P 秒后同笔移除，热账与燃料账闭合，邻石升温且不超热阻", c do
    {w, prefabs} = start(c.root, c.path)
    wood = c.materials[@wood]
    stone_count = map_size(@furnace) - 2
    ignite = c.tools[9]
    ignite_units = ignite["fuel_units"] * c.data["attachments"]["material_units_per_micro"]
    assert {:ok, _} = World.material_supply(w, 1001, "furnace",
      %{@stone => stone_count * c.macro_units, @wood => 2 * c.macro_units, @coal => ignite_units})
    builder = actor({-3.0, 1.5, 1.5})
    build(w, prefabs, builder, @furnace, {0, 0, 0}, 1)
    assert balance(w, @stone) == 0 and balance(w, @wood) == 0

    # 眼睛在开口正前方，沿 -x 穿过空气开口命中前芯。
    lighter = actor({6.0, 1.5, 1.5})
    assert {:ok, _} = operate(w, lighter, {-1.0, 0.0, 0.0}, 9, 1)
    lit = observe(w)
    front = at(lit.damage, @front)
    t0 = c.ambient + ignite["heat_energy_j"] / wood["heat_capacity_per_macro"]
    assert_in_delta front.temperature_kelvin, t0, 1.0e-9
    assert_in_delta t0, 797.19, 0.01
    assert front.burning and front.hp == 100.0
    fuel = wood["fuel_energy_per_macro_j"]
    power = wood["burn_power_per_macro_w"]
    assert front.remaining_fuel_j == fuel and front.power_w == power
    assert balance(w, @coal) == 0
    burn_s = fuel / power
    assert burn_s == 120.0

    final = run_until(w, &(at(&1.damage, @front) == nil))
    e0 = lit.thermal.elapsed_s
    timeline = history(w, lit.seq, lit.damage, e0)
    t_res = fn row -> c.materials[row.material]["heat_resistance_kelvin"] end

    for {elapsed, rows} <- timeline do
      for {_, row} <- rows, Map.has_key?(row, :temperature_kelvin),
        do: assert(row.temperature_kelvin < t_res.(row), "#{inspect(row.micro)} at #{elapsed}")

      case at(rows, @front) do
        %{} = row ->
          # 前芯存在即满血燃烧，余量 = fuel − P·t。
          assert row.hp == 100.0
          assert_in_delta row.remaining_fuel_j, fuel - power * (elapsed - e0), 1.0e-3
          assert elapsed - e0 < burn_s

        nil ->
          # 燃料在 fuel/P = 120 s 恰好耗尽；移除落在 ≥ 120 s 的第一个 0.5 s 提交。
          assert elapsed - e0 >= burn_s
      end
    end

    {removed_at, _} = Enum.find(timeline, fn {_, rows} -> at(rows, @front) == nil end)
    assert removed_at - e0 == burn_s

    # 后芯只受传导加热（设计 §3：峰值约 475 K < 573.15 K 点火），全程只烧前芯一格燃料。
    refute Enum.any?(timeline, fn {_, rows} -> Map.get(at(rows, @rear) || %{}, :burning, false) end)
    assert_in_delta final.thermal.fuel_initialized_j, fuel, 1.0e-6
    assert_in_delta final.thermal.combustion_j, fuel, 1.0e-3
    assert Map.get(final.thermal, :discarded_fuel_j, 0.0) == 0.0

    # 邻接前芯的四块石头在 120 s 前至少一块 ≥ 343.15 K（设计阈值 +50 K）。
    neighbours = for {dx, dy, dz} <- [{0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}],
      do: {elem(@front, 0) + dx, elem(@front, 1) + dy, elem(@front, 2) + dz}
    hottest = for {elapsed, rows} <- timeline, elapsed - e0 <= burn_s, k <- neighbours,
      row = at(rows, k), row != nil, do: row.temperature_kelvin
    assert Enum.max(hottest) >= 343.15

    # 供热账 = 点火热 + 燃烧放热（燃烧是供热的子账）；
    # 显热账：世界所有带温度宏格的 C·(T − 环境) = 供热 + 环境交换（负为散失）+ 重标 − 移除。
    assert_in_delta final.thermal.supplied_j, ignite["heat_energy_j"] + final.thermal.combustion_j, 1.0e-3
    sensible = for {_, row} <- final.damage, Map.has_key?(row, :temperature_kelvin), reduce: 0.0 do
      sum -> sum + c.materials[row.material]["heat_capacity_per_macro"] * (row.temperature_kelvin - c.ambient)
    end
    ledger = final.thermal.supplied_j + final.thermal.environment_j +
      Map.get(final.thermal, :parameter_rebase_j, 0.0) - final.thermal.removed_j
    assert_in_delta sensible, ledger, 1.0e-6 * final.thermal.supplied_j
  end

  test "露天相邻两块木头：点燃一块，另一块 60 s 内被引燃", c do
    {w, prefabs} = start(c.root, c.path)
    ignite_units = c.tools[9]["fuel_units"] * c.data["attachments"]["material_units_per_micro"]
    assert {:ok, _} = World.material_supply(w, 1001, "pair", %{@wood => 2 * c.macro_units, @coal => ignite_units})
    player = actor({-3.0, 0.5, 0.5})
    build(w, prefabs, player, %{{0, 0, 0} => @wood, {1, 0, 0} => @wood}, {0, 0, 0}, 1)
    assert {:ok, _} = operate(w, player, {1.0, 0.0, 0.0}, 9, 1)
    lit = observe(w)
    assert at(lit.damage, {0, 0, 0}).burning
    run_until(w, &(&1.thermal.elapsed_s - lit.thermal.elapsed_s >= 60.0))
    ignited = World.entries_after(w, lit.seq)
      |> Enum.find(fn txn -> Enum.any?(Map.get(txn, :property_states, []), &(macro_row?(&1, {1, 0, 0}) and Map.get(&1, :burning, false))) end)
    assert ignited != nil
    assert ignited.thermal.elapsed_s - lit.thermal.elapsed_s <= 60.0
  end

  test "旧目录下部分燃烧的木块经参数发布重标，拆回不超过原料量", c do
    # 旧目录 = 本次调参前的木材行（k 12、热阻 873.15、100 MJ、300 kW），其余字节同新目录。
    old_data = Map.update!(c.data, "materials", &Enum.map(&1, fn m ->
      if m["material_id"] == @wood,
        do: Map.merge(m, %{"thermal_conductivity" => 12.0, "heat_resistance_kelvin" => 873.15,
          "fuel_energy_per_macro_j" => 1.0e8, "burn_power_per_macro_w" => 3.0e5}),
        else: m
    end))
    old_path = Path.join(c.root, "old.json")
    File.write!(old_path, Jason.encode!(old_data))
    {w, prefabs} = start(c.root, old_path)
    per_use = c.data["attachments"]["material_units_per_micro"]
    assert {:ok, _} = World.material_supply(w, 1001, "partial",
      %{@wood => c.macro_units, @coal => c.tools[9]["fuel_units"] * per_use,
        @clay => c.tools[10]["fuel_units"] * per_use})
    player = actor({-3.0, 0.5, 0.5})
    build(w, prefabs, player, %{{0, 0, 0} => @wood}, {0, 0, 0}, 1)
    assert balance(w, @wood) == 0
    assert {:ok, _} = operate(w, player, {1.0, 0.0, 0.0}, 9, 1)
    lit = observe(w)
    burnt = run_until(w, &(&1.thermal.elapsed_s - lit.thermal.elapsed_s >= 1.0))

    assert :ok = World.publish_parameters(w, c.path, burnt.property_digest)
    new_digest = Base.decode16!(@digest, case: :lower)
    # 发布事务之前的最后一行与发布事务中的同一行对照（后台定时提交不影响这一对）。
    {previous, published} =
      World.entries_after(w, lit.seq)
      |> Enum.reduce_while(at(lit.damage, {0, 0, 0}), fn txn, row ->
        case Enum.find(txn.property_states, &(macro_row?(&1, {0, 0, 0}))) do
          nil -> {:cont, row}
          %{digest: ^new_digest} = next -> {:halt, {row, next}}
          next -> {:cont, next}
        end
      end)
    assert previous.burning and previous.remaining_fuel_j < 1.0e8 and previous.power_w == 3.0e5
    # 已烧比例不变：余量 × 12 MJ / 100 MJ；燃烧中功率取新目录 100 kW。
    assert_in_delta published.remaining_fuel_j, previous.remaining_fuel_j * 0.12, 1.0e-6
    assert published.power_w == 1.0e5 and published.burning
    assert_in_delta observe(w).thermal.fuel_rebase_j,
      published.remaining_fuel_j - previous.remaining_fuel_j, 1.0e-6

    assert {:ok, _} = operate(w, player, {1.0, 0.0, 0.0}, 10, 2)
    cooled = at(observe(w).damage, {0, 0, 0})
    refute cooled.burning
    Enum.reduce_while(3..40, nil, fn seq, _ ->
      [%{material: material}] = World.material_snapshot(w, [1001], [{0, 0, 0}]).probe_occupancy
      if material == 0 do
        {:halt, nil}
      else
        assert {:ok, _} = operate(w, player, {1.0, 0.0, 0.0}, 1, seq)
        {:cont, nil}
      end
    end)
    recovered = balance(w, @wood)
    assert recovered == floor(c.macro_units * cooled.remaining_fuel_j / c.materials[@wood]["fuel_energy_per_macro_j"])
    assert recovered <= c.macro_units
  end

  test "夹具即 UE 发布字节：文件名等于内容 sha256", c do
    assert Base.encode16(:crypto.hash(:sha256, File.read!(c.path)), case: :lower) == @digest
    assert Damage.load(c.path).digest == Base.decode16!(@digest, case: :lower)
  end
end
