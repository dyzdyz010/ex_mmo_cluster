defmodule VoxelRegion.LooseFurnaceSimTest do
  @moduledoc """
  只测试（:sim，默认排除）：R8-07 从零冶炼实跑前的本地服务端模拟——散体炉布局能否把四种矿炼成产物、各要多久。

  布局：5×4×5 石壳（地板 y=0、墙 y=1..2、顶 y=3），门为墙上 1 m 宏格开口 {2,2,0}（门在煤层之上，煤不从门漏出）；
  炉内 3×3 底层 y=1 每次往最浅的格倒煤，直到每格数量 > 7/8 格（顶层微格有料，矿才接触）；再在四个角各倒 0.25 m³
  铜矿 16、铁矿 17、荧光石 23、砂岩 9；K 点燃中心煤两次后封顶。热环境 = Voxim 正式资产（ε 0.9、视距 8）；
  目录 = 7b69b79f（发布 b1aca503 + 散体字段），只把液体步长改为手动投递（每 0.5 s 热提交补 5 个数量步）。
  运行：`mix test test/loose_furnace_sim_test.exs --only sim`。输出一行一个事件，末尾一行汇总。
  """
  use ExUnit.Case, async: false
  @moduletag :sim
  @moduletag timeout: :infinity
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Source, Actor, Log}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @environment Path.expand("../../../../Voxim/Content/Voxel/Properties/thermal-environment.json", __DIR__)
  @loose "7b69b79f1786756e857fb8cc0c855e911ce1d015ca2a5efdb25fc76f2a52b45e"
  @cap 2_097_152
  @stone 11
  @coal 15
  @ores [{16, {1, 2, 1}}, {17, {3, 2, 1}}, {23, {1, 2, 3}}, {9, {3, 2, 3}}]
  @limit_s 3600.0
  @after_s 300.0

  test "loose furnace: coal floor above 7/8, four 0.25 m³ ore piles, ignition, sealed" do
    root = Path.join(System.tmp_dir!(), "loose_furnace_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @loose <> ".json"))) |> put_in(["liquid", "step_seconds"], 3600)
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(data))
    env = Jason.decode!(File.read!(@environment))
    assert env["emissivity"] == 0.9
    materials = Map.new(data["materials"], &{&1["material_id"], &1})
    ores = for {m, _} <- @ores, do: m
    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: @environment,
      prefab_catalog_path: Path.join(root, "prefabs"), production_materials: [@stone, @coal | ores],
      liquid_bounds: {{-4, 0, -4}, {9, 8, 9}}]})
    actor = %{cid: 1001, gate: self(), identity: :furnace, refresh: &Actor.tool_context/2, eye: {2.5, 6.5, 2.5}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}))
    {:ok, _} = World.material_supply(w, 1001, "furnace", Map.new([{@stone, 90 * @cap}, {@coal, 14 * @cap} | Enum.map(ores, &{&1, @cap})]))
    c = %{w: w, actor: actor}

    shell = for x <- 0..4, z <- 0..4, y <- 0..2, y == 0 or x in [0, 4] or z in [0, 4], {x, y, z} != {2, 2, 0}, do: {x, y, z}
    for cell <- shell, do: {:ok, _} = intent(c, 1, @stone, cell, 1)

    floor = for x <- 1..3, z <- 1..3, do: {x, 1, z}
    pours = pour_floor(c, floor, 0)
    q = quantities(w)
    IO.puts("sim floor pours=#{pours} coal_m3=#{pours / 4} floor_min=#{Enum.min(Enum.map(floor, &q[&1])) / @cap} " <>
      "upper=#{inspect(for {{_, 2, _} = cell, u} <- q, do: {cell, u / @cap})}")

    for {m, cell} <- @ores, do: {:ok, _} = intent(c, 3, m, cell, 12)
    settle(w)
    q = quantities(w)
    for {m, cell} <- @ores, do: assert(q[cell] == div(@cap, 4) and material(w, cell) == m)

    lit = ignite(c, 0)
    IO.puts("sim ignite clicks=#{lit}")
    for x <- 0..4, z <- 0..4, do: {:ok, _} = intent(c, 1, @stone, {x, 3, z}, 1)

    started = System.monotonic_time(:millisecond)
    result = run(w, materials, %{}, 0)
    wall = System.monotonic_time(:millisecond) - started
    IO.puts("sim summary sim_s=#{result.elapsed} wall_ms=#{wall} commits=#{result.commits} converted=#{inspect(result.done)} " <>
      "peak_k=#{inspect(result.peak)} stone_lost=#{result.stone_lost} coal_cells=#{result.coal_cells} " <>
      "combustion_mj=#{Float.round(result.combustion / 1.0e6, 1)} discarded_fuel_mj=#{Float.round(result.discarded / 1.0e6, 1)} " <>
      "coal_left_m3=#{Float.round(result.coal_m3, 3)} transform_j=#{result.transform}")
  end

  defp next, do: System.unique_integer([:positive, :monotonic])

  defp intent(c, action, material, coord, tool) do
    seq = next()
    World.production_intent(c.w, Map.merge(c.actor, %{received_us: seq * 1_000_000, clock_node: node()}),
      %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: action, material: material,
        tool_id: tool, coord: coord})
  end

  defp tick(w), do: (send(w, :liquid_commit); World.seq(w))
  defp settle(w), do: (tick(w); if(World.liquid_activity(w).active_cells > 0, do: settle(w), else: :ok))
  defp quantities(w), do: World.simulation_snapshot(w, [1001], {{-4, 0, -4}, {9, 8, 9}}).liquid_quantities
  defp material(w, cell), do: hd(World.material_snapshot(w, [], [cell]).probe_occupancy).material

  # 像玩家对准最低处那样：每次往当前最浅的底层格倒 0.25 m³，倒后等静止，直到九格都 > 7/8 格
  # （休止角 5/8 格下从中心一点倒，角格会停在约 3/8 格而中心上层已满）。
  defp pour_floor(c, floor, n) do
    q = quantities(c.w)
    if Enum.all?(floor, &(Map.get(q, &1, 0) * 8 > 7 * @cap)) do
      n
    else
      {:ok, _} = intent(c, 3, @coal, Enum.min_by(floor, &Map.get(q, &1, 0)), 12)
      settle(c.w)
      pour_floor(c, floor, n + 1)
    end
  end

  # K：从正上方命中中心列最上面的煤，点到燃烧为止。
  defp ignite(c, n) do
    query = %{request_id: next(), client_intent_seq: next(), logical_scene_id: 1, action: 0, tool_id: 9,
      direction: {0.0, -1.0, 0.0}, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, target} = World.tool_intent(c.w, c.actor, query)
    seq = next()
    request = Map.merge(query, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
      |> Map.merge(%{action: 1, request_id: seq, client_intent_seq: seq})
    case World.tool_intent(c.w, Map.merge(c.actor, %{received_us: seq * 1_000_000, clock_node: node()}), request) do
      {:ok, _} -> ignite(c, n + 1)
      {:error, :already_burning} -> n
    end
  end

  defp run(w, materials, done, commits) do
    send(w, :thermal_commit)
    for _ <- 1..5, do: tick(w)
    s = VoxelRegion.TestSupport.observe(w, [1001], {{-1, -1, -1}, {6, 5, 6}})
    rows = Map.values(s.damage)
    done =
      Enum.reduce(@ores, done, fn {m, {x, y, z}}, done ->
        product = materials[m]["transform_material_id"]
        if Map.has_key?(done, m) or not Enum.any?(rows, &(&1.material == product and &1.micro == {x * 8, y * 8, z * 8})),
          do: done,
          else: (IO.puts("sim converted ore=#{m} -> #{product} at_s=#{s.thermal.elapsed_s}"); Map.put(done, m, s.thermal.elapsed_s))
      end)
    now = Map.new(@ores, fn {m, {x, y, z}} ->
      row = Enum.find(rows, &(&1.micro == {x * 8, y * 8, z * 8} and &1.granularity == 0))
      {m, if(row, do: Float.round(Map.get(row, :temperature_kelvin, 0.0), 0), else: 0.0)}
    end)
    peak = Map.merge(Map.get(done, :peak, %{}), now, fn _, a, b -> max(a, b) end)
    done = Map.put(done, :peak, peak)
    if rem(commits, 200) == 0,
      do: IO.puts("sim t=#{s.thermal.elapsed_s} ore_k=#{inspect(now)} burning=#{Enum.count(rows, &Map.get(&1, :burning, false))} " <>
        "coal_k_max=#{Enum.max(for(r <- rows, r.material == @coal, do: round(r.temperature_kelvin)), fn -> 0 end)}")
    coal = Enum.count(rows, &(&1.material == @coal and &1.granularity == 0 and Map.get(&1, :remaining_fuel_j, 1.0) > 0))
    # 全部转化后再烧 @after_s，看产物与炉壳在持续炉温下的完整度（玩家要多快舀出产物）。
    finished = map_size(done) == length(@ores) + 1 and s.thermal.elapsed_s >= Enum.max(Map.values(Map.delete(done, :peak))) + @after_s
    if finished or s.thermal.elapsed_s >= @limit_s or not s.thermal.active do
      products = for {m, {x, y, z}} <- @ores, row = Enum.find(rows, &(&1.micro == {x * 8, y * 8, z * 8} and &1.granularity == 0)),
        do: {materials[m]["transform_material_id"], row && Float.round(row.hp / row.max_hp, 3), row && round(row.temperature_kelvin)}
      coal_k = for r <- rows, r.material == @coal, r.granularity == 0, do: round(r.temperature_kelvin)
      shell_k = for r <- rows, r.material == @stone, r.granularity == 0, do: round(r.temperature_kelvin)
      IO.puts("sim after sim_s=#{s.thermal.elapsed_s} products(hp_ratio,k)=#{inspect(products)} " <>
        "coal_k=#{Enum.min(coal_k, fn -> 0 end)}..#{Enum.max(coal_k, fn -> 0 end)} shell_k_max=#{Enum.max(shell_k, fn -> 0 end)}")
      stone = for x <- 0..4, y <- 0..3, z <- 0..4, x in [0, 4] or z in [0, 4] or y in [0, 3], {x, y, z} != {2, 2, 0}, do: {x, y, z}
      lost = Enum.count(World.material_snapshot(w, [], stone).probe_occupancy, &(&1.material != @stone))
      %{elapsed: s.thermal.elapsed_s, commits: commits + 1, done: Map.delete(done, :peak), peak: peak, stone_lost: lost, coal_cells: coal,
        combustion: Map.get(s.thermal, :combustion_j, 0.0), transform: Map.get(s.thermal, :transform_j, 0.0),
        discarded: Map.get(s.thermal, :discarded_fuel_j, 0.0),
        coal_m3: Enum.sum(for({{_, 1, _}, u} <- s.liquid_units, do: u)) / @cap}
    else
      run(w, materials, done, commits + 1)
    end
  end
end
