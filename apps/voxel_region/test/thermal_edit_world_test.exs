defmodule VoxelRegion.ThermalEditWorldTest do
  @moduledoc "只测试：正式 GM、液体搬运、热提交的逐笔不变量（热量账闭合、水量守恒、事务序号连续、液体提交不动热账）；空世界来源替身，不替代 World。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, TestSupport}
  alias VoxelRegion.TestSupport.{Source, Log}
  alias VoxelRegion.TestSupport.WorldClock

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
    bounds = {{0, 0, 0}, {8, 8, 8}}
    clock = start_supervised!({WorldClock, 10_000})
    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env, gm_tools: true,
      liquid_bounds: bounds, clock: {WorldClock, clock}]})
    :ok = TestSupport.activate_simulation(w, bounds)
    settle(w)
    {:ok, _} = World.gm(w, "floor", :fill, %{box: {{0, 0, 0}, {7, 0, 7}}, material: 19})
    settle(w)
    {:ok, _} = World.gm(w, "source", :fill, %{box: {{2, 1, 2}, {2, 1, 2}}, material: 19})
    settle(w)
    experiment = Path.join(root, "heat.json")
    File.write!(experiment, Jason.encode!(%{classification: "Test-only", source_macro: [2, 1, 2],
      ambient_kelvin: 293.15, environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0,
      emissivity: 0.9, view_range_cells: 8, power_w: 1000.0, energy_j: 1.0e6}))
    :ok = World.thermal_experiment(w, experiment)
    settle(w)
    water_box = if bulk, do: {{1, 2, 1}, {5, 5, 5}}, else: {{3, 2, 2}, {5, 2, 4}}
    {:ok, _} = World.gm(w, "water", :fill, %{box: water_box, material: 21})
    settle(w)
    materials = Map.new(data["materials"], &{&1["material_id"], &1})
    ambient = Jason.decode!(File.read!(env))["ambient_kelvin"]
    # 手算水量：每个满宏格 2_097_152 单位；非 bulk 箱 {3,2,2}..{5,2,4} = 3×1×3 = 9 格，bulk 箱 {1,2,1}..{5,5,5} = 5×4×5 = 100 格。
    water_units = (if bulk, do: 100, else: 9) * 2_097_152
    steps = if bulk, do: 8, else: 48
    observe = fn -> TestSupport.observe(w, [], {{-1, -1, -1}, {1, 1, 1}}) end
    start = observe.()
    assert Enum.sum(Map.values(start.liquid_units)) == water_units

    for i <- 1..steps do
      prior = :sys.get_state(w)
      pre_liquid = observe.()
      send(w, :liquid_commit)
      settle(w)
      moved = :sys.get_state(w)
      quantity_changed = Enum.filter(Enum.uniq(Map.keys(prior.liquid_units) ++ Map.keys(moved.liquid_units)),
        &(Map.get(prior.liquid_units, &1) != Map.get(moved.liquid_units, &1)))
      new_rows = for {key, row} <- moved.damage, not Map.has_key?(prior.damage, key), do: VoxelRegion.Damage.macro(row)
      prior_epochs = VoxelRegion.EpochChunk.flat(prior.epochs)
      occupied = for {cell, epoch} <- VoxelRegion.EpochChunk.flat(moved.epochs),
        Map.get(prior_epochs, cell) != epoch, do: cell
      affected = Enum.flat_map(quantity_changed ++ new_rows ++ occupied, &[&1 | VoxelRegion.Thermal.neighbors(&1)])
      reusable = Map.drop(prior.thermal_work.geometry, affected)
      assert Map.take(moved.thermal_work.geometry, Map.keys(reusable)) == reusable
      before = observe.()

      # 液体提交只搬水：不得记任何热账、不改非液体行的温度；水带着焓搬运，热存量守恒；水量守恒（手算总量）。
      assert before.thermal == pre_liquid.thermal, "step #{i}: 液体提交改动了热量账"
      for {key, row} <- pre_liquid.damage, row.material != 21, Map.has_key?(before.damage, key),
          Map.has_key?(row, :temperature_kelvin) do
        assert before.damage[key][:temperature_kelvin] == row.temperature_kelvin,
               "step #{i}: 液体提交改动了 #{inspect(key)} 的温度"
      end
      assert_ledger_closes(pre_liquid, before, materials, ambient, "step #{i} 液体提交")
      assert Enum.sum(Map.values(before.liquid_units)) == water_units, "step #{i}: 液体提交后水量不守恒"

      send(w, :thermal_commit)
      settle(w)
      after_step = observe.()
      assert_in_delta after_step.thermal.elapsed_s - before.thermal.elapsed_s, 0.5, 1.0e-9
      # 手算热源：1000 W × 0.5 s = 500 J（源能量 1e6 J 远未耗尽）。
      assert_in_delta after_step.thermal.supplied_j - before.thermal.supplied_j, 500.0, 1.0e-9
      assert_ledger_closes(before, after_step, materials, ambient, "step #{i} 热提交")
      assert Enum.sum(Map.values(after_step.liquid_units)) == water_units, "step #{i}: 热提交后水量不守恒"

      if not bulk and i in [3, 6] do
        pre_edit = observe.()
        {:ok, _} = World.gm(w, "edit-#{i}", if(i == 3, do: :fill, else: :clear),
          %{box: {{6, 1, 6}, {6, 1, 6}}, material: 19})
        settle(w)
        post_edit = observe.()
        assert_ledger_closes(pre_edit, post_edit, materials, ambient, "step #{i} GM 编辑")
        # 手算：新填的石在环境温度，不带来任何热量；清除时移除账恰为其显热。
        if i == 3 do
          assert post_edit.thermal == pre_edit.thermal
          assert_in_delta stored_energy(post_edit, materials, ambient), stored_energy(pre_edit, materials, ambient), 1.0e-9
        end
      end
      work = :sys.get_state(w).thermal_work
      IO.puts("THERMAL_EDIT step=#{i} cells=#{MapSet.size(work.cells)} builds=#{work.builds} cached=#{map_size(work.geometry)}")
    end

    # 事务序号从 1 连续无空洞，且末笔就是当前 seq。
    seqs = Enum.map(World.entries_after(w, 0), & &1.seq)
    assert seqs == Enum.to_list(1..List.last(seqs))
    assert List.last(seqs) == World.seq(w)
  end

  # 热存量：宏格行（粒度 0）的能量。相态材料（水）按相族焓，其余按相对环境的显热 C·V·(T − Ta)；
  # 液体行体积按液量占满宏格 2^21 单位的比例。账：Δ存量 = Δ供热 + Δ环境 + Δ参数重标 − Δ移除（同 qinglan_migration_test 的口径）。
  defp stored_energy(observed, materials, ambient) do
    for {_, row} <- observed.damage, Map.has_key?(row, :temperature_kelvin), reduce: 0.0 do
      sum ->
        0 = row.granularity
        material = Map.fetch!(materials, row.material)
        fill = if row.material == 21, do: Map.get(observed.liquid_units, VoxelRegion.Damage.macro(row), 0) / 2_097_152, else: 1.0
        sum + VoxelRegion.Phase.finite_energy(row, fill, material, ambient)
    end
  end

  defp assert_ledger_closes(from, to, materials, ambient, label) do
    delta = fn key -> Map.get(to.thermal, key, 0.0) - Map.get(from.thermal, key, 0.0) end
    book = delta.(:supplied_j) + delta.(:environment_j) + delta.(:parameter_rebase_j) - delta.(:removed_j)
    change = stored_energy(to, materials, ambient) - stored_energy(from, materials, ambient)
    # 容差 1e-4 J：存量含 ~3e10 J 的潜热项，f64 相消底噪约 1e-5 J；漏记一项环境／供热至少 ~0.5 J，远大于它。
    assert_in_delta change, book, 1.0e-4, "#{label}：热量账不闭合 Δ存量=#{change} 账=#{book}"
  end

  # 只测试：依赖时钟保持不变，显式提交仍走正式内核；等公开进度完成，不取消或清空 due。
  defp settle(w) do
    World.seq(w)
    await_idle(w, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_idle(w, deadline) do
    progress = World.stats(w).simulation_progress.thermal
    if progress.remaining_s == 0.0 and progress.pending_steps == 0 and World.admission_status(w).ready_count == 0 do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, inspect(progress)
      Process.sleep(1)
      await_idle(w, deadline)
    end
  end
end
