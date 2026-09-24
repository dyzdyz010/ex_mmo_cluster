defmodule VoxelRegion.LoosePourBenchmarkTest do
  @moduledoc """
  只测试（:benchmark，默认排除）：R8-07 100 m³ 沙从一点倾倒的数量步成本。

  400 次 0.25 m³ 倾倒（工具 12，0.5 s 间隔 = 0.5 m³/s，共 200 s），每次倾倒后投递 5 个数量步（正式 0.1 s 节拍），
  倒完继续步进到活跃集合为空。每步墙钟 = 投递 :liquid_commit 到同一 World 回应下一条调用（含日志追加、区域后像编码）。
  目录 7b69b79f（只把液体步长改为手动投递），热环境 = Voxim 正式资产；文件日志；堆在单一 region 内。
  运行：`mix test test/loose_pour_benchmark_test.exs --only benchmark`。
  """
  use ExUnit.Case, async: false
  @moduletag :benchmark
  @moduletag timeout: :infinity
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Source, Actor, Log}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @environment Path.expand("../../../../Voxim/Content/Voxel/Properties/thermal-environment.json", __DIR__)
  @loose "7b69b79f1786756e857fb8cc0c855e911ce1d015ca2a5efdb25fc76f2a52b45e"
  @cap 2_097_152
  @sand 5
  @pours 400
  @spout {20, 30, 20}
  @bounds {{8, 0, 8}, {33, 40, 33}}

  test "100 m³ sand poured at one point: step cost, active set and time to rest" do
    root = Path.join(System.tmp_dir!(), "loose_bench_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @loose <> ".json"))) |> put_in(["liquid", "step_seconds"], 3600)
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(data))
    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: @environment,
      prefab_catalog_path: Path.join(root, "prefabs"), production_materials: [@sand], liquid_bounds: @bounds]})
    {sx, sy, sz} = @spout
    actor = %{cid: 1001, gate: self(), identity: :bench, refresh: &Actor.tool_context/2,
      eye: {sx + 0.5, sy + 4.5, sz + 0.5}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}))
    {:ok, _} = World.material_supply(w, 1001, "bench", %{@sand => 100 * @cap})

    {samples, active} =
      Enum.reduce(1..@pours, {[], 0}, fn n, {samples, active} ->
        received = n * 1_000_000
        {:ok, _} = World.production_intent(w, Map.merge(actor, %{received_us: received, clock_node: node()}),
          %{request_id: n, client_intent_seq: n, logical_scene_id: 1, action: 3, material: @sand, tool_id: 12, coord: @spout})
        Enum.reduce(1..5, {samples, active}, fn _, {samples, active} ->
          {us, _} = :timer.tc(fn -> send(w, :liquid_commit); World.seq(w) end)
          {[us | samples], max(active, World.liquid_activity(w).active_cells)}
        end)
      end)

    {rest, samples} = rest(w, 0, samples)
    q = World.simulation_snapshot(w, [1001], {{0, 0, 0}, {3, 3, 3}}).liquid_quantities
    assert Enum.sum(Map.values(q)) == 100 * @cap
    radius = q |> Map.keys() |> Enum.map(fn {x, _, z} -> :math.sqrt((x - sx) ** 2 + (z - sz) ** 2) end) |> Enum.max()
    height = q |> Map.keys() |> Enum.map(&elem(&1, 1)) |> Enum.max()
    sorted = Enum.sort(samples)
    at = fn p -> Enum.at(sorted, min(length(sorted) - 1, floor(p * length(sorted)))) end
    assert World.liquid_activity(w) == %{active_cells: 0, scheduled: false}
    IO.puts("bench loose_pour m3=100 steps=#{length(samples)} step_us_mean=#{div(Enum.sum(samples), length(samples))} " <>
      "p50=#{at.(0.5)} p95=#{at.(0.95)} max=#{List.last(sorted)} active_max=#{active} rest_steps_after_pour=#{rest} " <>
      "rest_s=#{rest / 10} entries=#{map_size(q)} radius_m=#{Float.round(radius, 1)} top_layer=#{height}")
  end

  defp rest(w, n, samples) do
    if World.liquid_activity(w).active_cells == 0 do
      {n, samples}
    else
      {us, _} = :timer.tc(fn -> send(w, :liquid_commit); World.seq(w) end)
      rest(w, n + 1, [us | samples])
    end
  end
end
