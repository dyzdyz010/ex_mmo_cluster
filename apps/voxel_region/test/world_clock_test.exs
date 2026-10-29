defmodule VoxelRegion.WorldClockTest do
  @moduledoc "只测试：真实 World 的时间依赖；空气源、文件日志和独占时钟替身，不替换物理内核。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, TestSupport}
  alias VoxelRegion.TestSupport.WorldClock

  setup do
    root = Path.join(System.tmp_dir!(), "world_clock_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    clock = start_supervised!({WorldClock, 10_000})
    world = start_supervised!({World, [source: TestSupport.Source, log: TestSupport.Log,
      root: root, observer: self(), name: nil, clock: {WorldClock, clock},
      property_catalog_path: TestSupport.catalog(), prefab_catalog_path: Path.join(root, "prefabs")]})
    assert {:ok, _} = World.apply_edit(world, {0, 0, 0}, 19)
    heat = Path.join(root, "heat.json")
    File.write!(heat, Jason.encode!(%{classification: "Test-only", source_macro: [0, 0, 0],
      ambient_kelvin: 293.15, environment_w_per_m2_k: 0.01, tolerance_kelvin: 0.001,
      emissivity: 0.0, view_range_cells: 8, power_w: 2_000.0, energy_j: 100_000.0}))
    assert :ok = World.thermal_experiment(world, heat)
    %{world: world, clock: clock}
  end

  test "依赖时间不变，真实墙钟跨过500毫秒后重复查询仍不额外推进", c do
    # 故意让另一时间域跨过旧生产 deadline；它不是等待模拟完成的手段。
    Process.send_after(self(), :wall_deadline_passed, 600)
    assert_receive :wall_deadline_passed, 1_000
    for _ <- 1..8 do
      World.seq(c.world)
      assert progress(c.world).model_elapsed_s == 0.0
    end
  end

  test "独占时钟推进500毫秒恰好完成一拍，后续查询不再消费未来due", c do
    assert WorldClock.advance(c.clock, 500) == 10_500
    await_step(c.world)
    for _ <- 1..8 do
      assert %{model_elapsed_s: 0.5, next_due_ms: 11_000, pending_steps: 0} = progress(c.world)
    end
  end

  test "取消timer运输后同一时钟到期，查询仍驱动保留的due完成一拍", c do
    :ok = WorldClock.cancel_all(c.clock)
    assert WorldClock.advance(c.clock, 500) == 10_500
    World.seq(c.world)
    await_step(c.world)
    assert %{model_elapsed_s: 0.5, next_due_ms: 11_000, pending_steps: 0} = progress(c.world)
  end

  defp progress(world), do: World.stats(world).simulation_progress.thermal

  defp await_step(world), do: await_step(world, System.monotonic_time(:millisecond) + 250)
  defp await_step(world, deadline) do
    value = progress(world)
    if value.model_elapsed_s == 0.5 and value.remaining_s == 0.0 do
      assert World.admission_status(world).ready_count == 0
    else
      assert System.monotonic_time(:millisecond) < deadline, inspect(value)
      Process.sleep(1)
      await_step(world, deadline)
    end
  end
end
