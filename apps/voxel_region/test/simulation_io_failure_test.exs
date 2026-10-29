defmodule VoxelRegion.SimulationIoFailureTest do
  @moduledoc """
  只测试：模拟的真实冷邻页读取持续失败时显式停止自动重试；依赖修复后由公共入口启动一次恢复。
  内容通过作者液体入口、compact、重启建立。故障只注入 File.read_pages 边界，不写入活动集、due 或驻留真值。
  后端屏障由共享 SimulationIoLog 提供，测试和显式CLI probe消费同一依赖边界。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{TestSupport, World}
  alias VoxelRegion.World.Pages

  @capacity 2_097_152

  alias VoxelRegion.TestSupport.SimulationIoLog, as: ControlledRead

  test "已消费热域的历史邻格不触发无用冷页读取，原自然步继续推进" do
    {world, _root} = heat_world(100.0, 1.0)
    key = {0, {4, 0, 0}}
    refute Pages.resident?(:sys.get_state(world), key)
    ControlledRead.mode(:fail, self(), key)
    # 原100W/1K样本的页3邻格尚非热活动；第二自然步不能因历史缓存再多扩一环至页4。
    await(fn -> World.stats(world).simulation_progress.thermal.model_elapsed_s >= 1.0 end, 250)
    refute_receive {:simulation_io_read, _, ^key}, 100
    assert World.stats(world).simulation_io.status == :idle
    assert World.stats(world).simulation_progress.thermal.wait_reason != :page_io_failed
    assert Process.alive?(world)
  end

  test "纯owner失败闸在无run和有run时均原样返回，不能由通用request绕过" do
    failure = %{status: :failed, reason: :test_only_unavailable}
    for run <- [nil, %{remaining: 0.5}] do
      state = %{page_load: %{sim: failure}, thermal_run: run}
      assert {:failed, ^failure, ^state} =
        VoxelRegion.World.PageLoad.request(state, fn _ -> flunk("失败闸不应重新求读取需求") end)
    end
  end

  test "进行中热run读失败保留原ref与段剩余，显式恢复只结算原自然步一次" do
    {world, root} = heat_world(2_000.0, 0.001)
    key = {0, {4, 0, 0}}
    refute Pages.resident?(:sys.get_state(world), key)
    ControlledRead.mode(:fail, self(), key)
    assert_receive {:simulation_io_read, _reader, ^key}, 2_500
    await(fn -> World.stats(world).simulation_io.status == :failed end)
    run = :sys.get_state(world).thermal_run
    assert %{ref: ref, scheduled_due: due, segment: segment, remaining: remaining} = run
    assert segment > 0.0 and segment < remaining
    assert_in_delta remaining, 0.5, 1.0e-9
    failed = World.stats(world).simulation_progress.thermal
    assert failed.next_due_ms == due
    assert_in_delta failed.remaining_s, segment, 1.0e-9
    before = World.simulation_snapshot(world, [], {{2, 0, 0}, {4, 1, 1}}).thermal_accounting
    assert_in_delta before.elapsed_s, 0.5 - segment, 1.0e-9
    assert_in_delta before.supplied_j, 2_000.0 * before.elapsed_s, 1.0e-6
    refute_receive {:simulation_io_read, _, ^key}, 600
    assert :sys.get_state(world).thermal_run.ref == ref
    assert World.stats(world).simulation_progress.thermal.next_due_ms == due

    ControlledRead.mode(:hold, self(), key)
    assert {:loading, _attempt} = World.retry_simulation_io(world)
    assert_receive {:simulation_io_read, reader, ^key}, 1_000
    assert :sys.get_state(world).thermal_run.ref == ref
    assert World.stats(world).simulation_progress.thermal.next_due_ms == due
    assert_in_delta World.stats(world).simulation_progress.thermal.remaining_s, segment, 1.0e-9
    send(reader, :continue)
    await(fn -> World.stats(world).simulation_progress.thermal.model_elapsed_s >= 0.5 end)
    # 读取实际提交日志的第一个完整自然步，避免回复后又处理下一到期步导致取证切点漂移。
    complete = VoxelRegion.OverlayLog.File.replay(Path.join(root, "overlay.log"))
      |> Enum.find(fn txn ->
        case Map.get(txn, :thermal) do
          %{elapsed_s: elapsed} -> elapsed > before.elapsed_s
          _ -> false
        end
      end)
    assert complete != nil
    assert_in_delta complete.thermal.elapsed_s, 0.5, 1.0e-9
    assert_in_delta complete.thermal.supplied_j, 1_000.0, 1.0e-6
    assert_in_delta complete.thermal.supplied_j + complete.thermal.sources[{191, 0, 0}].remaining_j,
      100_000.0, 1.0e-6
    progressed = World.stats(world).simulation_progress.thermal
    assert progressed.next_due_ms > due
    assert rem(progressed.next_due_ms - due, 500) == 0
  end

  test "持续读失败不自动再读，明确修复后只启动一次读取并续原液体步" do
    root = Path.join(System.tmp_dir!(), "simulation_io_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> ControlledRead.clear(); File.rm_rf!(root) end)
    catalog = Path.join(root, "catalog.json")
    data = Jason.decode!(File.read!(TestSupport.catalog()))
      |> Map.put("liquid", %{"step_seconds" => 1.0, "gravity_units_per_step" => @capacity,
        "side_units_per_step" => div(@capacity, 16), "side_threshold_units" => 0})
    File.write!(catalog, Jason.encode!(data))
    opts = [source: TestSupport.Source, root: root, observer: self(), name: nil, log: ControlledRead,
      production_materials: [19, 21], property_catalog_path: catalog,
      prefab_catalog_path: Path.join(root, "prefabs"), liquid_bounds: {{64, 0, 2}, {65, 196, 3}}]
    world = start_supervised!({World, opts})
    water = Path.join(root, "water.json")
    File.write!(water, Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [64, 193, 2], material: 21}]}))
    assert {:ok, _} = World.liquid_experiment(world, water)
    assert :ok = World.compact(world)
    stop_supervised!(World)
    world = start_supervised!({World, opts})
    key = {0, {1, 1, 0}}
    refute Pages.resident?(:sys.get_state(world), key)
    assert World.simulation_windows(world).source_count == 0
    ControlledRead.mode(:fail, self(), key)

    # 下一步实际两层邻域含Y=2页，步前必须先准备其尚冷Y=1邻页；缺页前不得先让水下落。
    assert_receive {:simulation_io_read, _reader, ^key}, 3_000
    # 原500ms无限重试会在这里再次读；观察窗覆盖两个旧重试间隔，不用盲睡后只数最终seq。
    refute_receive {:simulation_io_read, _, ^key}, 1_100
    failed = World.stats(world)
    assert failed.simulation_io.status == :failed
    assert is_binary(failed.simulation_io.reason) and failed.simulation_io.reason != ""
    assert failed.simulation_progress.liquid.wait_reason == :page_io_failed
    due = failed.simulation_progress.liquid.next_due_ms
    assert is_integer(due)
    seq = World.seq(world)
    before = World.simulation_snapshot(world, [], {{1, 2, 0}, {2, 4, 1}})
    assert before.liquid_quantities[{64, 193, 2}] == @capacity

    # 同一World故障明确拒绝未接纳物理输入；不能把caller或无from消息无限积在ready/held。
    for cid <- 1001..1003 do
      assert {:error, {:simulation_input_failed, _}} = World.apply_edits(world, [{{64, 194, 2}, 19}])
      send(world, {:body_detach, cid, self(), make_ref()})
    end
    assert World.admission_status(world).ready_count == 0
    assert World.stats(world).page_waiters == 0
    assert :sys.get_state(world).page_load.held == %{}

    # Scene/Player边界替身只验证失败回执与等待资源，不声称施法物理已经执行。
    cast_key = {:io_failure_cast, 1}
    reply_ref = make_ref()
    send(world, {:prepare_cast, cast_key, %{player: self()}, %{action: 1}, {self(), reply_ref}})
    assert_receive {:cast_failed, ^cast_key}, 1_000
    assert_receive {^reply_ref, {:error, {:simulation_input_failed, _}}}, 1_000
    assert World.admission_status(world).ready_count == 0
    assert World.stats(world).page_waiters == 0

    # 已确认死亡后果是唯一例外：保留一个context，同key新拒绝不能释放它的held。
    send(world, {:body_death, 700, {64.5, 193.0, 2.5}})
    await(fn -> World.admission_status(world).ready_count == 1 end)
    pending = :queue.get(:sys.get_state(world).input_ready)
    # 只注入同一真实运输消息的重复投递，不创建或改写物理真值。
    send(world, {:retry_death_drop, pending})
    send(world, {:body_detach, 700, self(), make_ref()})
    World.seq(world)
    assert %{ready_count: 1, held_sequences: 1} = World.admission_status(world)

    # 修复依赖本身不偷偷触发重试；显式动作返回loading，只表示这一次读取已开始。
    ControlledRead.mode(:hold, self(), key)
    refute_receive {:simulation_io_read, _, ^key}, 600
    assert World.stats(world).simulation_io.status == :failed
    assert World.seq(world) == seq
    assert {:loading, attempt} = World.retry_simulation_io(world)
    assert_receive {:simulation_io_read, reader, ^key}, 1_000
    assert {:loading, ^attempt} = World.retry_simulation_io(world)
    refute_receive {:simulation_io_read, _, ^key}, 100
    assert World.stats(world).simulation_progress.liquid.next_due_ms == due
    send(reader, :continue)

    await(fn ->
      stats = World.stats(world)
      next_due = stats.simulation_progress.liquid.next_due_ms
      stats.simulation_io.status == :idle and is_integer(next_due) and next_due > due and
        World.admission_status(world).ready_count == 0
    end)
    snapshot = World.simulation_snapshot(world, [], {{1, 2, 0}, {2, 4, 1}})
    assert Enum.sum(Map.values(snapshot.liquid_quantities)) == @capacity
    assert Enum.all?(snapshot.liquid_quantities, fn {{64, y, 2}, units} -> y <= 192 and units > 0 end)
    assert World.seq(world) > seq
    assert World.stats(world).simulation_progress.liquid.wait_reason != :page_io_failed
    assert World.admission_status(world).held_sequences == 0
  end

  defp heat_world(power, tolerance) do
    root = Path.join(System.tmp_dir!(), "thermal_io_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> ControlledRead.clear(); File.rm_rf!(root) end)
    opts = [source: TestSupport.Source, root: root, observer: self(), name: nil, log: ControlledRead,
      production_materials: [19], property_catalog_path: TestSupport.catalog(),
      prefab_catalog_path: Path.join(root, "prefabs")]
    world = start_supervised!({World, opts})
    assert {:ok, _} = World.apply_edits(world, [{{191, 0, 0}, 19}, {{192, 0, 0}, 19}])
    assert :ok = World.compact(world)
    heat = Path.join(root, "heat.json")
    File.write!(heat, Jason.encode!(%{classification: "Test-only", source_macro: [191, 0, 0],
      ambient_kelvin: 293.15, environment_w_per_m2_k: 0.01, tolerance_kelvin: tolerance,
      emissivity: 0.0, view_range_cells: 8, power_w: power, energy_j: 100_000.0}))
    assert :ok = World.thermal_experiment(world, heat)
    stop_supervised!(World)
    world = start_supervised!({World, opts})
    {world, root}
  end

  defp await(fun, left \\ 100) do
    cond do
      fun.() -> :ok
      left == 0 -> flunk("显式恢复后未完成原来等待的模拟步")
      true -> Process.sleep(10); await(fun, left - 1)
    end
  end
end
