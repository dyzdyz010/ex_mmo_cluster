defmodule VoxelRegion.ThermalEditWorldTest do
  @moduledoc "只测试：正式 GM、液体搬运、热提交的逐笔真值与日志冻结对照；空世界来源替身，不替代 World。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, TestSupport}
  alias VoxelRegion.TestSupport.{Source, Log}

  test "清填与水体沉降不改变既有温度、热量账和事务", do: exercise(false)
  test "深水中转的净数量未变格不丢弃几何", do: exercise(true)

  defp exercise(bulk) do
    root = Path.join(System.tmp_dir!(), "thermal_edit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    catalog = Path.join(root, "properties.json")
    fixture = Path.expand("fixtures/combustion/b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec.json", __DIR__)
    data = Jason.decode!(File.read!(fixture))
      |> Map.put("liquid", %{"step_seconds" => 3600, "gravity_units_per_step" => 524288,
        "side_units_per_step" => 131072, "side_threshold_units" => 262144})
    File.write!(catalog, Jason.encode!(data))
    env = Path.expand("fixtures/combustion/environment-radiation.json", __DIR__)
    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env, gm_tools: true,
      liquid_bounds: {{0, 0, 0}, {8, 8, 8}}]})
    pause_clock(w)
    {:ok, _} = World.gm(w, "floor", :fill, %{box: {{0, 0, 0}, {7, 0, 7}}, material: 19})
    pause_clock(w)
    {:ok, _} = World.gm(w, "source", :fill, %{box: {{2, 1, 2}, {2, 1, 2}}, material: 19})
    pause_clock(w)
    experiment = Path.join(root, "heat.json")
    File.write!(experiment, Jason.encode!(%{classification: "Test-only", source_macro: [2, 1, 2],
      ambient_kelvin: 293.15, environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0,
      emissivity: 0.9, view_range_cells: 8, power_w: 1000.0, energy_j: 1.0e6}))
    :ok = World.thermal_experiment(w, experiment)
    pause_clock(w)
    water_box = if bulk, do: {{1, 2, 1}, {5, 5, 5}}, else: {{3, 2, 2}, {5, 2, 4}}
    {:ok, _} = World.gm(w, "water", :fill, %{box: water_box, material: 21})
    pause_clock(w)
    trace = for i <- 1..if(bulk, do: 8, else: 48) do
      prior = :sys.get_state(w)
      send(w, :liquid_commit)
      pause_clock(w)
      moved = :sys.get_state(w)
      quantity_changed = Enum.filter(Enum.uniq(Map.keys(prior.liquid_units) ++ Map.keys(moved.liquid_units)),
        &(Map.get(prior.liquid_units, &1) != Map.get(moved.liquid_units, &1)))
      new_rows = for {key, row} <- moved.damage, not Map.has_key?(prior.damage, key), do: VoxelRegion.Damage.macro(row)
      occupied = for {cell, epoch} <- moved.epochs, Map.get(prior.epochs, cell) != epoch, do: cell
      affected = Enum.flat_map(quantity_changed ++ new_rows ++ occupied, &[&1 | VoxelRegion.Thermal.neighbors(&1)])
      reusable = Map.drop(prior.thermal_work.geometry, affected)
      assert Map.take(moved.thermal_work.geometry, Map.keys(reusable)) == reusable
      before = TestSupport.observe(w, [], {{-1, -1, -1}, {1, 1, 1}})
      send(w, :thermal_commit)
      pause_clock(w)
      after_step = TestSupport.observe(w, [], {{-1, -1, -1}, {1, 1, 1}})
      assert_in_delta after_step.thermal.elapsed_s - before.thermal.elapsed_s, 0.5, 1.0e-9
      if not bulk and i in [3, 6] do
        {:ok, _} = World.gm(w, "edit-#{i}", if(i == 3, do: :fill, else: :clear),
          %{box: {{6, 1, 6}, {6, 1, 6}}, material: 19})
        pause_clock(w)
      end
      work = :sys.get_state(w).thermal_work
      IO.puts("THERMAL_EDIT step=#{i} cells=#{MapSet.size(work.cells)} builds=#{work.builds} cached=#{map_size(work.geometry)}")
      if i <= 12, do: {after_step, World.entries_after(w, 0)}
    end
    trace = Enum.reject(trace, &is_nil/1)
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(canonical(trace))) |> Base.encode16(case: :lower)
    IO.puts("THERMAL_EDIT_DIGEST #{digest}")
    if path = System.get_env("THERMAL_CAPTURE"), do: File.write!(path, :erlang.term_to_binary(trace))
    # 改前真实 World 冻结：12 笔水体沉降及热提交，包含每笔完整属性、热量账和历史事务。
    expected = if bulk, do: "cef0864e58adfe0c02a08f93fe837dc60b9d7c44945e4a0829af3a697dda696e",
      else: "20a98193177c67b6198642ad7351aaec6e9767fb20c2ab8a4c63e94ba7d6a086"
    assert digest == expected
  end

  # 大 map 的 ETF 输出顺序不是值契约；递归排序后冻结完整值，避免将内部存储次序当成物理差异。
  defp canonical(value) when is_map(value), do: {:map, value |> Enum.map(fn {k, v} -> {canonical(k), canonical(v)} end) |> Enum.sort()}
  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&canonical/1) |> List.to_tuple()
  defp canonical(value), do: value

  # 只测试：取消自动调度，手动投递正式提交消息；不改 authority 字段或热内核状态。
  defp pause_clock(w) do
    World.seq(w)
    s = :sys.get_state(w)
    if s.thermal_timer, do: Process.cancel_timer(s.thermal_timer)
    assert s.thermal_run == nil
  end
end
