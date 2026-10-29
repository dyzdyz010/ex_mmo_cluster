defmodule VoxelRegion.CircuitPagedWorldTest do
  @moduledoc """
  只测试：公开作者／附件／有限热源入口建立跨冷页回路，真实文件页读等待不消费自然步。
  时钟替身仅控制timer运输；文件后端只在指定页读取边界等待，canonical与求解均为真实模块。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, OverlayLog}
  alias VoxelRegion.World.Pages
  alias VoxelRegion.TestSupport.{Actor, Source, SimulationIoLog, WorldClock}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @digest "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @cold {0, {2, 0, 0}}

  setup do
    root = Path.join(System.tmp_dir!(), "circuit_paged_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    catalog = Path.join(root, "properties.json")
    File.cp!(Path.join(@fixtures, @digest <> ".json"), catalog)
    environment = Path.join(root, "environment.json")
    File.write!(environment, Jason.encode!(%{ambient_kelvin: 293.15, environment_w_per_m2_k: 10.0,
      tolerance_kelvin: 0.01, emissivity: 0.0, view_range_cells: 8, circuit_min_power_w: 1.0}))
    clock = start_supervised!({WorldClock, 0})
    opts = [name: nil, root: root, observer: self(), source: Source, log: SimulationIoLog,
      property_catalog_path: catalog, thermal_environment_path: environment,
      prefab_catalog_path: Path.join(root, "prefabs"), production_materials: [11, 24, 40, 43], clock: {WorldClock, clock}]
    on_exit(fn -> SimulationIoLog.clear(); File.rm_rf!(root) end)
    %{root: root, opts: opts, clock: clock}
  end

  defp await(fun, left \\ 1000)
  defp await(fun, left) when left > 0 do
    if fun.(), do: :ok, else: (Process.sleep(10); await(fun, left - 1))
  end
  defp await(_fun, 0), do: flunk("电路自然步未达到声明的可观察条件")

  defp progress(world), do: World.stats(world).simulation_progress.thermal
  defp commit(world) do
    before = progress(world).model_elapsed_s
    send(world, :thermal_commit)
    await(fn -> progress(world).model_elapsed_s >= before + 0.5 end)
  end

  defp build(c, world) do
    top = for x <- 1..130, do: {{x, 3, 2}, cond do x == 2 -> 43; x == 129 -> 40; true -> 24 end}
    bottom = for x <- 1..130, do: {{x, 1, 2}, 24}
    assert {:ok, _} = World.apply_edits(world, top ++ bottom ++ [{{1, 2, 2}, 24}, {{129, 2, 2}, 11}])
    # 远端铜线跨过y=2空气缺口，背靠石支撑；上下两端接回两条宏格导体。
    assert {:ok, _} = World.material_supply(world, 1001, "circuit-wire", %{24 => 2_097_152})
    actor = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: {130.25, 2.5, 4.0}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}, id: make_ref()))
    request = %{request_id: 1, client_intent_seq: 1, logical_scene_id: 1, action: 0,
      kind: 1, axis: 1, size: 8, anchor: {1040, 16, 16}, id: 0, material: 24, tool_id: 1}
    assert {:ok, _} = World.attachment_intent(world, actor, request)
    assert :ok = World.compact(world)
    stop_supervised!(World)
    # 恢复时降低新接线限额；既有八槽回路仍必须自然推进，不能因当前限额暂停。
    opts = if c[:lower_admission_limit], do: Keyword.put(c.opts, :circuit_component_limit, 1), else: c.opts
    world = start_supervised!({World, opts})
    refute Pages.resident?(:sys.get_state(world), @cold)
    world
  end

  defp heated(c) do
    world = start_supervised!({World, c.opts}) |> then(&build(c, &1))
    experiment = Path.join(c.root, "heat.json")
    File.write!(experiment, Jason.encode!(%{classification: "Test-only", source_macro: [1, 3, 2],
      ambient_kelvin: 293.15, environment_w_per_m2_k: 10.0, tolerance_kelvin: 0.01,
      emissivity: 0.0, view_range_cells: 8, power_w: 2.0e6, energy_j: 1.0e9}))
    assert :ok = World.thermal_experiment(world, experiment)
    # 第一自然提交只在近端加热并产生热电石的真实温度行；电图尚未求解，已持久远端仍可冷退。
    commit(world)
    assert World.maintain_residency(world).status == :ready
    refute Pages.resident?(:sys.get_state(world), @cold)
    before = World.simulation_snapshot(world, [], {{0, 0, 0}, {1, 1, 1}}).thermal_accounting
    old_progress = progress(world)
    assert Map.fetch!(before.sources, {1, 3, 2}).remaining_j > 0.0
    {world, before, old_progress}
  end

  @tag timeout: 120_000
  @tag :lower_admission_limit
  test "首次真实电动势发现冷导体与冷附件，读取等待保持原due剩余时间和有限能量", c do
    {world, before, old_progress} = heated(c)
    SimulationIoLog.mode(:hold, self(), @cold)
    WorldClock.advance(c.clock, 500)
    assert_receive {:simulation_io_read, reader, @cold}, 20_000
    waiting = progress(world)
    assert waiting.wait_reason == :page_io
    assert waiting.remaining_s == 0.5
    assert waiting.next_due_ms == old_progress.next_due_ms
    assert waiting.model_elapsed_s == old_progress.model_elapsed_s
    assert waiting.circuit.status == :preparing
    assert waiting.circuit.seq == World.seq(world)
    assert World.simulation_snapshot(world, [], {{0, 0, 0}, {1, 1, 1}}).thermal_accounting == before

    SimulationIoLog.clear()
    send(reader, :continue)
    await(fn -> progress(world).model_elapsed_s >= old_progress.model_elapsed_s + 0.5 end)
    after_view = World.simulation_snapshot(world, [], {{0, 0, 0}, {3, 1, 1}})
    account = after_view.thermal_accounting
    load = Enum.find(after_view.property_states, &(&1.granularity == 0 and &1.micro == {1032, 24, 16}))
    # 只读失败证据：热端、热电石、冷端的真实温度用于区分夹具驱动力与图缺口。
    temperatures = for row <- after_view.property_states, row.granularity == 0 and row.micro in [{8, 24, 16}, {16, 24, 16}, {24, 24, 16}],
      into: %{}, do: {row.micro, Map.get(row, :temperature_kelvin)}
    assert Map.get(load, :electric_w, 0.0) > 0.0,
      inspect(%{temperatures: temperatures, thermal_accounting: Map.drop(account, [:sources]), circuit: progress(world).circuit})
    assert account.circuit_light_j > Map.get(before, :circuit_light_j, 0.0)
    assert account.sources[{1, 3, 2}].remaining_j < before.sources[{1, 3, 2}].remaining_j
    assert account.supplied_j - before.supplied_j <= 1.0e6
    assert progress(world).next_due_ms == waiting.next_due_ms + 500
    assert :ok = World.compact(world)
    assert OverlayLog.File.prefix(Path.join(c.root, "overlay.log")) == World.seq(world)
  end

  test "电图冷页失败不消费源或时间，显式恢复续同一自然步一次", c do
    {world, before, old_progress} = heated(c)
    SimulationIoLog.mode(:fail, self(), @cold)
    WorldClock.advance(c.clock, 500)
    assert_receive {:simulation_io_read, _, @cold}, 20_000
    await(fn -> World.stats(world).simulation_io.status == :failed end)
    failed = progress(world)
    original = :sys.get_state(world).thermal_run
    assert failed.wait_reason == :page_io_failed
    assert failed.remaining_s == 0.5
    assert failed.model_elapsed_s == old_progress.model_elapsed_s
    assert failed.next_due_ms == old_progress.next_due_ms
    assert World.simulation_snapshot(world, [], {{0, 0, 0}, {1, 1, 1}}).thermal_accounting == before
    refute_receive {:simulation_io_read, _, @cold}, 100

    SimulationIoLog.mode(:hold, self(), @cold)
    assert {:loading, attempt} = World.retry_simulation_io(world)
    assert_receive {:simulation_io_read, reader, @cold}, 1_000
    assert {:loading, ^attempt} = World.retry_simulation_io(world)
    refute_receive {:simulation_io_read, _, @cold}, 100
    assert :sys.get_state(world).thermal_run.ref == original.ref
    assert progress(world).circuit.seq == failed.circuit.seq
    assert progress(world).remaining_s == failed.remaining_s
    assert World.simulation_snapshot(world, [], {{0, 0, 0}, {1, 1, 1}}).thermal_accounting == before

    SimulationIoLog.clear()
    send(reader, :continue)
    await(fn -> progress(world).model_elapsed_s == old_progress.model_elapsed_s + 0.5 end)
    after_view = World.simulation_snapshot(world, [], {{0, 0, 0}, {3, 1, 1}})
    account = after_view.thermal_accounting
    assert progress(world).next_due_ms == failed.next_due_ms + 500
    assert World.stats(world).simulation_io.status == :idle
    assert account.circuit_light_j > Map.get(before, :circuit_light_j, 0.0)
    assert account.supplied_j - before.supplied_j <= 1.0e6
    assert account.sources[{1, 3, 2}].remaining_j < before.sources[{1, 3, 2}].remaining_j
  end

  test "电图等待期间正常断路编辑按Admission排队，原步后接纳且下一步不复用旧图", c do
    {world, _before, old_progress} = heated(c)
    SimulationIoLog.mode(:hold, self(), @cold)
    WorldClock.advance(c.clock, 500)
    assert_receive {:simulation_io_read, reader, @cold}, 20_000
    waiting = progress(world)
    seq = World.seq(world)

    # 公开编辑由接纳owner等正在进行的自然步完成；不回填World私有状态伪造并发seq。
    edit = Task.async(fn -> World.apply_edits(world, [{{10, 1, 2}, 0}]) end)
    await(fn -> World.admission_status(world).ready_count == 1 end)
    assert World.seq(world) == seq
    assert progress(world).circuit.seq == waiting.circuit.seq
    assert progress(world).remaining_s == 0.5

    SimulationIoLog.clear()
    send(reader, :continue)
    assert {:ok, _} = Task.await(edit, 20_000)
    assert progress(world).model_elapsed_s == old_progress.model_elapsed_s + 0.5
    connected = World.simulation_snapshot(world, [], {{0, 0, 0}, {3, 1, 1}}).thermal_accounting
    assert connected.circuit_light_j > 0.0
    assert World.seq(world) > waiting.circuit.seq
    assert World.admission_status(world).ready_count == 0

    commit(world)
    broken = World.simulation_snapshot(world, [], {{0, 0, 0}, {3, 1, 1}})
    assert broken.thermal_accounting.circuit_light_j == connected.circuit_light_j
    load = Enum.find(broken.property_states, &(&1.granularity == 0 and &1.micro == {1032, 24, 16}))
    refute Map.has_key?(load, :electric_w)
  end
end
