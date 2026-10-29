defmodule VoxelRegion.SimulationProgressTest do
  @moduledoc "只测试：真实World在受控CPU/IO等待后保留自然步欠账；空气来源与文件日志替身，不启动PG。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, TestSupport}
  alias VoxelRegion.World.Thermal

  @capacity 2_097_152

  alias VoxelRegion.TestSupport.HeldPageLog, as: HeldRead
  alias VoxelRegion.TestSupport.WorldClock

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "simulation_progress_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "prefabs"))
    catalog = Path.join(root, "catalog.json")

    data =
      TestSupport.catalog()
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("liquid", %{
        "step_seconds" => 0.2,
        "gravity_units_per_step" => div(@capacity, 4),
        "side_units_per_step" => div(@capacity, 16),
        "side_threshold_units" => 0
      })

    File.write!(catalog, Jason.encode!(data))

    opts = [
      source: TestSupport.Source,
      log: TestSupport.Log,
      root: root,
      observer: self(),
      name: nil,
      property_catalog_path: catalog,
      prefab_catalog_path: Path.join(root, "prefabs"),
      production_materials: [19, 21],
      liquid_bounds: {{0, 0, 0}, {1, 10, 1}}
    ]

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, opts: opts}
  end

  test "调度一个已到期热步不推进due或把欠账锚点改到现在" do
    due = System.monotonic_time(:millisecond) - 2_000
    scheduled = Thermal.schedule(%{clock: {VoxelRegion.World.Clock, nil}, thermal_timer: nil, thermal_due: due})
    Process.cancel_timer(scheduled.thermal_timer)
    assert scheduled.thermal_due == due
  end

  defp start_heat(c) do
    world = start_supervised!({World, c.opts})
    assert {:ok, _} = World.apply_edit(world, {127, 0, 0}, 19)
    heat = Path.join(c.root, "heat.json")

    File.write!(
      heat,
      Jason.encode!(%{
        classification: "Test-only",
        source_macro: [127, 0, 0],
        ambient_kelvin: 293.15,
        environment_w_per_m2_k: 0.01,
        tolerance_kelvin: 0.001,
        emissivity: 0.0,
        view_range_cells: 8,
        power_w: 2_000.0,
        energy_j: 100_000.0
      })
    )

    assert :ok = World.thermal_experiment(world, heat)
    world
  end

  test "显式强制步不推远未来timer，到期后仅消费该到期事件", c do
    world = start_heat(c)
    due = :sys.get_state(world).thermal_due

    # 热域随传热跨入冷页时，强制步按 P1 驻留暂停在步前、装页后续完同一步；暂停期间再到的强制提交挂闸后重放为下一步。
    # 故逐步等待本次强制步完成（运行清空）再投下一次，不以 seq 回复推断同步完成；等待窗口须在自然 due 之前。
    for _ <- 1..3 do
      send(world, :thermal_commit)
      World.seq(world)
      await(fn -> TestSupport.simulation_settled?(world) end, max(due - System.monotonic_time(:millisecond), 0))
    end

    forced = :sys.get_state(world)
    assert forced.thermal.elapsed_s == 1.5
    assert forced.thermal_due == due
    await(fn -> :sys.get_state(world).thermal.elapsed_s >= 2.0 end, 800)
    timed = :sys.get_state(world)
    assert timed.thermal.elapsed_s == 2.0
    assert timed.thermal_due == due + 500
  end

  test "World暂停超过三热步后逐步追上，液体并行前沿不丢步且查询不饥饿", c do
    world = start_heat(c)
    water = Path.join(c.root, "water.json")

    File.write!(
      water,
      Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [0, 7, 0], material: 21}]})
    )

    assert {:ok, _} = World.liquid_experiment(world, water)
    due = :sys.get_state(world).thermal_due
    :ok = :sys.suspend(world)

    try do
      # 只控制CPU可运行时刻；不注入任何温度、余量、活动集或due真值。
      Process.send_after(
        self(),
        :release_cpu,
        max(due + 1_100 - System.monotonic_time(:millisecond), 0)
      )

      assert_receive :release_cpu, 3_000

      query =
        Task.async(fn -> World.simulation_snapshot(world, [], {{-1, -1, -1}, {3, 1, 1}}) end)

      await(
        fn ->
          {:messages, messages} = Process.info(world, :messages)
          Enum.any?(messages, &match?({:"$gen_call", _, _}, &1))
        end,
        1_000
      )

      :ok = :sys.resume(world)
      early = Task.await(query, 1_000)
      assert early.thermal_accounting.elapsed_s <= 0.5

      await(
        fn ->
          snapshot = World.simulation_snapshot(world, [], {{-1, -1, -1}, {3, 1, 1}})

          snapshot.thermal_accounting.elapsed_s >= 1.5 and
            Map.get(snapshot.liquid_quantities, {0, 7, 0}, 0) == 0
        end,
        250
      )

      snapshot = World.simulation_snapshot(world, [], {{-1, -1, -1}, {3, 1, 1}})
      assert Enum.sum(Map.values(snapshot.liquid_quantities)) == @capacity

      assert_in_delta snapshot.thermal_accounting.supplied_j,
                      2_000.0 * snapshot.thermal_accounting.elapsed_s,
                      1.0e-6

      clock = :sys.get_state(world)
      assert clock.thermal_run == nil
      assert clock.thermal_due == due + round(clock.thermal.elapsed_s * 1_000)
    after
      :sys.resume(world)
    end
  end

  test "装页等待保留同一due，IO放行后完成全部已到期热步且账不重放", c do
    c = %{c | opts: Keyword.put(c.opts, :log, HeldRead)}
    world = start_heat(c)
    assert :ok = World.compact(world)
    stop_supervised!(World)
    world = start_supervised!({World, c.opts})
    initial = World.simulation_snapshot(world, [], {{1, 0, 0}, {3, 1, 1}}).thermal_accounting
    path = Path.join(c.root, "overlay.log")
    :persistent_term.put({HeldRead, path}, self())
    on_exit(fn -> :persistent_term.erase({HeldRead, path}) end)

    # 只测试缓存接缝：页的canonical内容保持原样，仅撤销已恢复邻页的派生驻留标记。
    :sys.replace_state(world, fn state ->
      %{state | resident: MapSet.delete(state.resident, {0, {2, 0, 0}})}
    end)

    due = :sys.get_state(world).thermal_due
    assert_receive {:holding_read, reader}, 2_000

    try do
      waiting = World.stats(world).simulation_progress.thermal
      assert waiting.next_due_ms == due
      assert waiting.wait_reason == :page_io

      Process.send_after(
        self(),
        :release_page_io,
        max(due + 1_100 - System.monotonic_time(:millisecond), 0)
      )

      assert_receive :release_page_io, 2_000
      delayed = World.stats(world).simulation_progress.thermal
      assert delayed.next_due_ms == due
      assert delayed.lag_ms >= 1_500
      assert delayed.pending_steps >= 3
    after
      send(reader, :continue_read)
    end

    await(
      fn ->
        World.stats(world).simulation_progress.thermal.model_elapsed_s >= initial.elapsed_s + 1.5
      end,
      300
    )

    progressed = World.stats(world).simulation_progress.thermal
    assert progressed.pending_steps == 0

    assert progressed.next_due_ms ==
             due + round((progressed.model_elapsed_s - initial.elapsed_s) * 1_000)

    accounting = World.simulation_snapshot(world, [], {{1, 0, 0}, {3, 1, 1}}).thermal_accounting

    assert_in_delta accounting.supplied_j - initial.supplied_j,
                    2_000.0 * (accounting.elapsed_s - initial.elapsed_s),
                    1.0e-6

    assert_in_delta accounting.supplied_j + accounting.sources[{127, 0, 0}].remaining_j,
                    100_000.0,
                    1.0e-6
  end

  test "装页期间到达的显式强制热步挂闸重放，每个到达的强制步都执行", c do
    # 只测试时钟：定时步不到期，模型时间只由两次显式强制步推进。
    clock = start_supervised!({WorldClock, 0})
    c = %{c | opts: c.opts |> Keyword.put(:log, HeldRead) |> Keyword.put(:clock, {WorldClock, clock})}
    world = start_heat(c)
    assert :ok = World.compact(world)
    stop_supervised!(World)
    world = start_supervised!({World, c.opts})
    initial = World.simulation_snapshot(world, [], {{1, 0, 0}, {3, 1, 1}}).thermal_accounting
    path = Path.join(c.root, "overlay.log")
    :persistent_term.put({HeldRead, path}, self())
    on_exit(fn -> :persistent_term.erase({HeldRead, path}) end)

    # 只测试缓存接缝：页的canonical内容保持原样，仅撤销已恢复邻页的派生驻留标记，使热步前读取集缺页。
    :sys.replace_state(world, fn state ->
      %{state | resident: MapSet.delete(state.resident, {0, {2, 0, 0}})}
    end)

    send(world, :thermal_commit)
    assert_receive {:holding_read, reader}, 2_000
    # 第二个强制步在同一装页未完成时到达，不能被并入或丢弃。
    send(world, :thermal_commit)
    World.seq(world)
    send(reader, :continue_read)

    await(fn -> TestSupport.simulation_settled?(world) end, 2_000)

    done = World.simulation_snapshot(world, [], {{1, 0, 0}, {3, 1, 1}}).thermal_accounting
    assert_in_delta done.elapsed_s, initial.elapsed_s + 1.0, 1.0e-12
    assert_in_delta done.supplied_j - initial.supplied_j, 2_000.0, 1.0e-6
  end

  test "持续热活动保有已装计算域页：连续强制步不退休重装，每步在本回调内执行", c do
    # 只测试时钟：定时步不到期，模型时间只由显式强制步推进。
    clock = start_supervised!({WorldClock, 0})
    world = start_heat(%{c | opts: Keyword.put(c.opts, :clock, {WorldClock, clock})})

    # 前两步让热域扩进跨页计算域并装入其页；此后热源持续，计算域不自然结束。
    for _ <- 1..2 do
      send(world, :thermal_commit)
      await(fn -> TestSupport.simulation_settled?(world) end, 2_000)
    end

    retired = World.residency_status(world).retired_pages
    initial = :sys.get_state(world).thermal.elapsed_s

    for i <- 1..4 do
      send(world, :thermal_commit)
      state = :sys.get_state(world)
      # 依赖页一直驻留：强制步在本回调内完整执行，不起模拟装页、不挂闸。
      assert state.page_load.sim == nil
      assert state.thermal_run == nil and map_size(state.page_load.tasks) == 0
      assert_in_delta state.thermal.elapsed_s, initial + 0.5 * i, 1.0e-12
    end

    assert World.residency_status(world).retired_pages == retired
  end

  defp await(check, left) do
    if check.() do
      :ok
    else
      assert left > 0, "未在声明窗口内观察到保留自然步欠账后的推进"
      Process.sleep(5)
      await(check, left - 5)
    end
  end
end
