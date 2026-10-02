defmodule VoxelRegion.ThermalSettleCostTest do
  @moduledoc """
  只测试（默认排除，`--only benchmark`）：R8-05 热提交结算成本与改前改后物理逐提交对照（Voxim Docs/R8/plan.md §R8-05）。

  场景（大世界持续发热）：`furnace_generator_world_test` 的双热壁炉灯回路（作者编辑装置、记账供煤、倾倒 1 m³、K 点燃、盖石），
  远处一个石槽装满水（Test-only `liquid_experiment` 一次装入，BENCH_CELLS 格，默认 30³ = 27 000 条属性记录，
  对应 Demo 实测约 2.7 万条记录量级）。只经 `:thermal_commit` 推进（每笔 0.5 模拟秒），BENCH_COMMITS 笔（默认 600）。

  每笔提交后（World 空闲、无进行中的提交）把全部属性行（去掉事务号、请求号）与热账（去掉模拟时钟）哈希，
  按模拟时刻打印 `SETTLE_DIGEST`，写入 BENCH_OUT（可选）供改前／改后两份输出逐行 diff；成本取 World 自己的日志
  （`voxel_thermal_callback elapsed_us`：整笔热提交含写事务；`voxel_thermal_sim scan_us`：结算扫描段）。
  """
  use ExUnit.Case, async: false
  @moduletag :benchmark
  @moduletag timeout: :infinity
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @catalog "b4d8bf35d98ca527df900e049878795ffc6428f51a71f7a14ca2b0a55158607f"
  @cap 2_097_152
  @quarter div(@cap, 4)
  @stone 11
  @coal 15
  @copper 24
  @alloy 40
  @battery 42
  @te 43
  @water 21
  @opening {3, 2, 2}

  defmodule Capture do
    @moduledoc "Test-only logger handler: forwards the World's own thermal timing lines."
    def log(%{msg: {:string, text}}, %{config: %{pid: pid}}) do
      text = IO.chardata_to_string(text)
      if String.starts_with?(text, ["voxel_thermal_callback", "voxel_thermal_sim"]), do: send(pid, {:bench, text})
      :ok
    end

    def log(_, _), do: :ok
  end

  defp next, do: System.unique_integer([:positive, :monotonic])

  defp tool_down(w, a, tool) do
    query = %{request_id: next(), client_intent_seq: next(), logical_scene_id: 1, action: 0, tool_id: tool,
      direction: {0.0, -1.0, 0.0}, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, target} = World.tool_intent(w, a, query)
    seq = next()
    request = Map.merge(query, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
      |> Map.merge(%{action: 1, request_id: seq, client_intent_seq: seq})
    World.tool_intent(w, Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()}), request)
  end

  defp intent(w, a, action, material, coord, tool) do
    seq = next()
    World.production_intent(w, Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()}),
      %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: action, material: material, tool_id: tool, coord: coord})
  end

  defp settle(w, left \\ 2000) do
    send(w, :liquid_commit)
    cond do
      World.liquid_activity(w).active_cells == 0 -> :ok
      left == 0 -> flunk("loose cells did not come to rest")
      true -> settle(w, left - 1)
    end
  end

  # 等热调度休眠（无待到期节拍、无进行中的提交），使点燃与盖石落在同一模拟时刻（同 furnace_generator_world_test）。
  defp rested(w, left \\ 300) do
    s = :sys.get_state(w)
    cond do
      s.thermal_timer == nil and s.thermal_run == nil -> :ok
      left == 0 -> flunk("thermal scheduler did not rest")
      true -> (Process.sleep(10); rested(w, left - 1))
    end
  end

  # World 空闲（没有进行中的提交）时的原始状态。
  defp idle(w) do
    s = :sys.get_state(w)
    if s.thermal_run == nil, do: s, else: idle(w)
  end

  defp digest(s) do
    rows = Map.new(s.damage, fn {k, r} -> {k, Map.drop(r, [:seq, :request_id])} end)
    :crypto.hash(:sha256, :erlang.term_to_binary({rows, Map.drop(s.thermal, [:elapsed_s])}, [:deterministic]))
    |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp drain(acc) do
    receive do
      {:bench, "voxel_thermal_callback" <> rest} -> drain(Map.update!(acc, :callback, &[field(rest, "elapsed_us") | &1]))
      {:bench, "voxel_thermal_sim" <> rest} -> drain(Map.update!(acc, :scan, &[field(rest, "scan_us") | &1]))
    after 0 -> acc
    end
  end

  defp field(text, key), do: String.to_integer(hd(Regex.run(~r/#{key}=(\d+)/, text, capture: :all_but_first)))

  defp stats(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    at = fn q -> Enum.at(sorted, min(n - 1, trunc(q * n))) end
    "n=#{n} median=#{at.(0.5)} p95=#{at.(0.95)} max=#{List.last(sorted)} mean=#{div(Enum.sum(sorted), max(n, 1))}"
  end

  test "持续发热的大世界：每笔热提交成本与逐提交物理指纹" do
    cells = String.to_integer(System.get_env("BENCH_CELLS", "27000"))
    commits = String.to_integer(System.get_env("BENCH_COMMITS", "600"))
    side = round(:math.pow(cells, 1 / 3))
    root = Path.join(System.tmp_dir!(), "settle_cost_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @catalog <> ".json"))) |> put_in(["liquid", "step_seconds"], 3600)
    File.write!(Path.join(root, "properties.json"), Jason.encode!(data))
    File.cp!(Path.join(@fixtures, "environment-radiation.json"), Path.join(root, "environment.json"))
    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: Path.join(root, "properties.json"), thermal_environment_path: Path.join(root, "environment.json"),
      prefab_catalog_path: Path.join(root, "prefabs"), production_materials: [@stone, @coal, @copper, @alloy, @battery, @te, @water],
      liquid_bounds: {{-3, 0, -1}, {20 + side + 2, max(side, 4) + 2, 20 + side + 2}}]})
    a = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: {3.5, 4.5, 2.5}, tick_us: 16_667}
    a = Map.put(a, :player, start_supervised!({Actor, a}))

    # 炉（同 furnace_generator_world_test 用例 1 的装置与灯回路）。
    ground = for x <- -2..8, z <- 0..5, do: {{x, 0, z}, @stone}
    row = [{{0, 1, 2}, @copper}, {{1, 1, 2}, @te}, {{2, 1, 2}, @copper}, {{4, 1, 2}, @copper}, {{5, 1, 2}, @te}, {{6, 1, 2}, @copper},
      {{3, 1, 1}, @stone}, {{3, 1, 3}, @stone}]
    front = [{{6, 1, 1}, @copper}, {{2, 1, 1}, @alloy}] ++ for(x <- 2..6, do: {{x, 1, 0}, @copper})
    fins = for {x, y, z} <- [{7, 1, 2}, {8, 1, 2}, {7, 2, 2}, {6, 2, 2}, {7, 1, 3}, {7, 1, 1},
                             {-1, 1, 2}, {-2, 1, 2}, {-1, 2, 2}, {0, 2, 2}, {-1, 1, 3}, {-1, 1, 1}], do: {{x, y, z}, @copper}
    lamp = [{{0, 1, 3}, @copper}, {{4, 1, 3}, @alloy}] ++ for(x <- 0..4, do: {{x, 1, 4}, @copper})
    {:ok, _} = World.apply_edits(w, ground ++ row ++ front ++ fins ++ lamp)
    {:ok, _} = World.material_supply(w, 1001, "settle-cost", %{@coal => 4 * @quarter + @cap, @stone => 2 * @cap})
    for _ <- 1..4, do: ({:ok, _} = intent(w, a, 3, @coal, @opening, 12); settle(w))

    # 远处装满水的石槽（内腔 side³，四壁与底为石）。
    {x0, z0} = {20, 20}
    tub = for x <- (x0 - 1)..(x0 + side), y <- 0..side, z <- (z0 - 1)..(z0 + side),
              y == 0 or x in [x0 - 1, x0 + side] or z in [z0 - 1, z0 + side], do: {{x, y, z}, @stone}
    if cells > 0 do
      {:ok, _} = World.apply_edits(w, tub)
      path = Path.join(root, "basin.json")
      File.write!(path, Jason.encode!(%{classification: "Test-only",
        deposits: for(x <- x0..(x0 + side - 1), y <- 1..side, z <- z0..(z0 + side - 1), do: %{macro: [x, y, z], material: @water})}))
      {:ok, _} = World.liquid_experiment(w, path)
      settle(w)
    end

    # K 点到燃烧为止（同 furnace_generator_world_test）、盖石；先等搭建事务唤醒的确认拍休眠，K 的唤醒拍 500 ms 后才到。
    rested(w)
    clicks = Enum.reduce_while(1..10, 0, fn _, n ->
      case tool_down(w, a, 9) do
        {:ok, _} -> {:cont, n + 1}
        {:error, :already_burning} -> {:halt, n}
      end
    end)
    assert clicks >= 1
    {:ok, _} = intent(w, a, 1, @stone, @opening, 1)
    s0 = idle(w)
    IO.puts("SETTLE_COST setup clicks=#{clicks} rows=#{map_size(s0.damage)} water_cells=#{side * side * side * min(cells, 1)} sim_s=#{s0.thermal.elapsed_s}")

    Logger.configure(level: :info)
    :ok = :logger.set_handler_config(:default, :level, :warning)
    :ok = :logger.add_handler(:settle_cost, Capture, %{level: :info, config: %{pid: self()}})
    out = System.get_env("BENCH_OUT")

    try do
      drain(%{callback: [], scan: []})
      {lines, acc} =
        Enum.map_reduce(1..commits, %{callback: [], scan: []}, fn _, acc ->
          send(w, :thermal_commit)
          s = idle(w)
          line = "SETTLE_DIGEST sim_s=#{s.thermal.elapsed_s} rows=#{map_size(s.damage)} #{digest(s)}"
          {line, drain(acc)}
        end)
      s = idle(w)
      if out, do: File.write!(out, Enum.join(Enum.uniq(lines), "\n") <> "\n")
      burning = Enum.count(s.damage, fn {_, r} -> Map.get(r, :burning, false) end)
      IO.puts("SETTLE_COST rows=#{map_size(s.damage)} burning_rows=#{burning} hot_rows=#{map_size(s.thermal_work.hot_rows)} " <>
        "sim_s=#{s.thermal.elapsed_s} commits=#{commits}")
      IO.puts("SETTLE_COST callback_us #{stats(acc.callback)}")
      IO.puts("SETTLE_COST scan_us #{stats(acc.scan)}")
      IO.puts(List.last(lines))
      assert length(acc.callback) >= commits
    after
      :logger.remove_handler(:settle_cost)
      :logger.set_handler_config(:default, :level, :all)
      Logger.configure(level: :warning)
    end
  end
end
