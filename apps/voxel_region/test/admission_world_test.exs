defmodule VoxelRegion.AdmissionWorldTest do
  @moduledoc "只测试：真实World公共输入在ready切点之前不能改写已到期旧步；文件日志为顺序证据，不注入物理真值。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, TestSupport}
  alias VoxelRegion.OverlayLog.File, as: FileLog

  @capacity 2_097_152

  setup context do
    root =
      Path.join(
        System.tmp_dir!(),
        "admission_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "prefabs"))
    catalog = Path.join(root, "catalog.json")

    data =
      TestSupport.catalog()
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("liquid", %{
        "step_seconds" => 0.5,
        "gravity_units_per_step" => @capacity,
        "side_units_per_step" => div(@capacity, 16),
        "side_threshold_units" => 0
      })

    File.write!(catalog, Jason.encode!(data))

    opts = [
      source: TestSupport.Source,
      log: if(context[:held_read], do: TestSupport.HeldPageLog, else: TestSupport.Log),
      root: root,
      observer: self(),
      name: nil,
      property_catalog_path: catalog,
      prefab_catalog_path: Path.join(root, "prefabs"),
      production_materials: [19, 21],
      liquid_bounds: {{0, 0, 0}, {1, 7, 1}}
    ]

    world = start_supervised!({World, opts})
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, world: world, opts: opts, log: Path.join(root, "overlay.log")}
  end

  defp heat(c, name, cell, power) do
    path = Path.join(c.root, name <> ".json")

    File.write!(
      path,
      Jason.encode!(%{
        classification: "Test-only",
        source_macro: Tuple.to_list(cell),
        ambient_kelvin: 293.15,
        environment_w_per_m2_k: 0.01,
        tolerance_kelvin: 0.001,
        emissivity: 0.0,
        view_range_cells: 8,
        power_w: power,
        energy_j: 100_000.0
      })
    )

    path
  end

  test "新热源真正接纳前先完成旧欠账，创建事务不含倒填的供能", c do
    old = {127, 1, 0}
    fresh = {191, 1, 0}
    assert {:ok, _} = World.apply_edits(c.world, [{old, 19}, {fresh, 19}])
    assert :ok = World.thermal_experiment(c.world, heat(c, "old", old, 2_000.0))
    water = Path.join(c.root, "mixed-water.json")

    File.write!(
      water,
      Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [0, 5, 0], material: 21}]})
    )

    assert {:ok, _} = World.liquid_experiment(c.world, water)
    before = :sys.get_state(c.world)
    due = before.thermal_due
    path = heat(c, "fresh", fresh, 8_000.0)

    captured =
      try do
        Logger.configure(level: :info)

        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   after_backlog(c.world, due, fn -> World.thermal_experiment(c.world, path) end)
        end)
      after
        Logger.configure(level: :warning)
      end

    created =
      Enum.find(FileLog.replay(c.log), fn txn ->
        Map.has_key?(Map.get(Map.get(txn, :thermal, %{}), :sources, %{}), fresh)
      end)

    assert created != nil
    assert created.thermal.elapsed_s >= 1.5
    assert_in_delta created.thermal.supplied_j, 2_000.0 * created.thermal.elapsed_s, 1.0e-6
    assert created.thermal.sources[fresh].remaining_j == 100_000.0

    [_, cutoff] =
      Regex.run(~r/voxel_input_ready .*kind=thermal_experiment .*cutoff_ms=(-?\d+)/, captured)

    old_steps = div(String.to_integer(cutoff) - due, 500) + 1
    assert_in_delta created.thermal.elapsed_s - before.thermal.elapsed_s, old_steps * 0.5, 1.0e-9
    [prefix | _] = String.split(captured, "voxel_input_accepted")

    order =
      for [_, owner, due] <-
            Regex.scan(~r/voxel_physics_step owner=(thermal|liquid) due_ms=(-?\d+)/, prefix),
          do: {String.to_integer(due), if(owner == "thermal", do: 0, else: 1)}

    assert length(order) >= 4
    assert order == Enum.sort(order)
  end

  test "后来放置的固体不能回溯阻挡三个旧下落步", c do
    path = Path.join(c.root, "water.json")

    File.write!(
      path,
      Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [0, 5, 0], material: 21}]})
    )

    assert {:ok, _} = World.liquid_experiment(c.world, path)
    due = :sys.get_state(c.world).liquid_due

    assert {:ok, wall_seq} =
             after_backlog(c.world, due, fn -> World.apply_edit(c.world, {0, 3, 0}, 19) end)

    quantities =
      c.log
      |> FileLog.replay()
      |> Enum.take_while(&(&1.seq < wall_seq))
      |> Enum.reduce(%{}, fn txn, values ->
        Enum.reduce(Map.get(txn, :liquid_units, %{}), values, fn
          {cell, 0}, values -> Map.delete(values, cell)
          {cell, units}, values -> Map.put(values, cell, units)
        end)
      end)

    assert Enum.sum(Map.values(quantities)) == @capacity
    assert Enum.all?(quantities, fn {{0, y, 0}, _} -> y <= 2 end)
    assert [%{material: 19}] = World.material_snapshot(c.world, [], [{0, 3, 0}]).probe_occupancy
  end

  @tag :body_effective_time
  test "身体报告在旧自然步有效时仍换热，不能按CPU晚到时刻提前过期", c do
    cell = {127, 1, 0}
    assert {:ok, _} = World.apply_edit(c.world, cell, 19)
    assert :ok = World.thermal_experiment(c.world, heat(c, "body-heat", cell, 2_000.0))

    body = %{
      feet: {127.5, 2.0, 0.5},
      height: 1.8,
      radius: 0.3,
      skin_k: 307.15,
      capacity: 24_430.0,
      area: 1.8,
      tissue_k: 330.0,
      tissue_capacity: 209.4,
      tissue_g: 0.378207
    }

    send(c.world, {:body_contact, 1001, self(), body})
    World.seq(c.world)
    due = :sys.get_state(c.world).thermal_due
    :ok = :sys.suspend(c.world)

    try do
      Process.send_after(
        self(),
        :resume_body_owner,
        max(due + 2_600 - System.monotonic_time(:millisecond), 0)
      )

      assert_receive :resume_body_owner, 4_000
    after
      :sys.resume(c.world)
    end

    assert_receive {:body_heat, %{tissue_j: exchanged}}, 500
    assert exchanged < 0
    await(fn -> World.stats(c.world).simulation_progress.thermal.model_elapsed_s >= 3.0 end)
    drain_body_heat()
    after_expiry = World.stats(c.world).simulation_progress.thermal.model_elapsed_s

    await(
      fn ->
        World.stats(c.world).simulation_progress.thermal.model_elapsed_s >= after_expiry + 0.5
      end,
      1_000
    )

    refute_receive {:body_heat, _}, 0
  end

  test "取消ready但未接纳的新源只删输入，旧物理欠账仍继续", c do
    old = {127, 1, 0}
    fresh = {191, 1, 0}
    assert {:ok, _} = World.apply_edits(c.world, [{old, 19}, {fresh, 19}])
    assert :ok = World.thermal_experiment(c.world, heat(c, "cancel-old", old, 2_000.0))
    due = :sys.get_state(c.world).thermal_due
    fresh_path = heat(c, "cancel-fresh", fresh, 8_000.0)
    parent = self()

    hook = fn debug, event, _ ->
      if event == {:in, :input_continue} and not Process.get(:admission_held_once, false) do
        Process.put(:admission_held_once, true)
        send(parent, {:ready_held, self()})
        receive do: (:continue_ready_test -> :ok)
      end

      debug
    end

    :ok = :sys.install(c.world, {hook, nil})
    :ok = :sys.suspend(c.world)
    caller = spawn(fn -> World.thermal_experiment(c.world, fresh_path) end)
    monitor = Process.monitor(caller)

    try do
      await(fn -> queued_call?(c.world) end)

      Process.send_after(
        self(),
        :resume_cancel_owner,
        max(due + 1_100 - System.monotonic_time(:millisecond), 0)
      )

      assert_receive :resume_cancel_owner, 3_000
    after
      :sys.resume(c.world)
    end

    assert_receive {:ready_held, world}, 1_000

    try do
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}

      await(fn ->
        {:messages, messages} = Process.info(world, :messages)
        Enum.any?(messages, &match?({:DOWN, _, :process, ^caller, _}, &1))
      end)
    after
      send(world, :continue_ready_test)
    end

    await(fn -> World.stats(world).simulation_progress.thermal.model_elapsed_s >= 1.5 end)
    assert World.admission_status(world).ready_count == 0

    refute Enum.any?(FileLog.replay(c.log), fn txn ->
             Map.has_key?(Map.get(Map.get(txn, :thermal, %{}), :sources, %{}), fresh)
           end)
  end

  test "同due只按稳定热先液体后顺序选择，较早due优先" do
    state = %{thermal_run: nil, thermal_due: 100, liquid_due: 100}
    assert VoxelRegion.World.Admission.next_step(state, 100) == :thermal
    assert VoxelRegion.World.Admission.next_step(%{state | thermal_due: 600}, 100) == :liquid
    assert VoxelRegion.World.Admission.next_step(%{state | liquid_due: 99}, 100) == :liquid
    assert VoxelRegion.World.Admission.next_step(state, 99) == nil
  end

  @tag :ready_body_order
  test "同body新报告在ready等旧步时，摘离不能先确认再让报告复活", c do
    assert {:ok, _} = World.apply_edit(c.world, {127, 1, 0}, 19)
    assert :ok = World.thermal_experiment(c.world, heat(c, "ordered-source", {127, 1, 0}, 2_000.0))
    due = :sys.get_state(c.world).thermal_due
    body = %{feet: {127.5, 2.0, 0.5}, height: 1.8, radius: 0.3, skin_k: 307.15,
      capacity: 24_430.0, area: 1.8, tissue_k: 330.0, tissue_capacity: 209.4, tissue_g: 0.378207}
    detached = make_ref()
    :ok = :sys.suspend(c.world)
    send(c.world, {:body_contact, 1001, self(), body})
    World.body_detach(c.world, 1001, self(), detached)
    try do
      Process.send_after(self(), :resume_body_order, max(due + 1_100 - System.monotonic_time(:millisecond), 0))
      assert_receive :resume_body_order, 3_000
    after
      :sys.resume(c.world)
    end
    assert_receive {:body_detached, ^detached}, 1_000
    accepted_after = World.stats(c.world).simulation_progress.thermal.model_elapsed_s
    assert accepted_after >= 1.5
    refute_receive {:body_heat, _}, 0
    await(fn -> World.stats(c.world).simulation_progress.thermal.model_elapsed_s >= accepted_after + 0.5 end)
    refute_receive {:body_heat, _}, 0
  end

  @tag :held_read
  test "冷身体报告等页不冻结别处热源，晚ready不能刷新原样本寿命", c do
    assert {:ok, _} = World.apply_edits(c.world, [{{127, 1, 0}, 19}, {{320, 0, 0}, 19}])
    assert :ok = World.thermal_experiment(c.world, heat(c, "live-source", {127, 1, 0}, 2_000.0))
    assert :ok = World.compact(c.world)
    stop_supervised!(World)
    world = start_supervised!({World, c.opts})
    refute VoxelRegion.World.Pages.resident?(:sys.get_state(world), {0, {5, 0, 0}})
    :persistent_term.put({TestSupport.HeldPageLog, c.log}, self())
    on_exit(fn -> :persistent_term.erase({TestSupport.HeldPageLog, c.log}) end)

    body = %{
      feet: {320.5, 1.0, 0.5},
      height: 1.8,
      radius: 0.3,
      skin_k: 307.15,
      capacity: 24_430.0,
      area: 1.8,
      tissue_k: 330.0,
      tissue_capacity: 209.4,
      tissue_g: 0.378207
    }

    send(world, {:body_contact, 1001, self(), body})
    assert_receive {:holding_read, reader}, 1_000
    before = World.stats(world).simulation_progress.thermal.model_elapsed_s

    try do
      Process.send_after(self(), :release_body_read, 2_600)
      assert_receive :release_body_read, 3_000
      assert World.stats(world).simulation_progress.thermal.model_elapsed_s >= before + 2.0
    after
      send(reader, :continue_read)
    end

    await(fn ->
      World.stats(world).page_loads == 0 and World.admission_status(world).ready_count == 0
    end)

    accepted = World.stats(world).simulation_progress.thermal.model_elapsed_s

    await(
      fn -> World.stats(world).simulation_progress.thermal.model_elapsed_s >= accepted + 1.0 end,
      1_500
    )

    refute_receive {:body_heat, _}, 0
  end

  defp after_backlog(world, due, action) do
    :ok = :sys.suspend(world)
    task = Task.async(action)

    try do
      await(fn ->
        {:messages, messages} = Process.info(world, :messages)
        Enum.any?(messages, &match?({:"$gen_call", _, {:page_request, _, _}}, &1))
      end)

      # 请求已排入邮箱，但World尚未接收；只控制CPU放行，不伪造输入或修改due。
      Process.send_after(
        self(),
        :resume_owner,
        max(due + 1_100 - System.monotonic_time(:millisecond), 0)
      )

      assert_receive :resume_owner, 3_000
    after
      :sys.resume(world)
    end

    Task.await(task, 5_000)
  end

  defp queued_call?(world) do
    {:messages, messages} = Process.info(world, :messages)
    Enum.any?(messages, &match?({:"$gen_call", _, {:page_request, _, _}}, &1))
  end

  defp drain_body_heat do
    receive do
      {:body_heat, _} -> drain_body_heat()
    after
      0 -> :ok
    end
  end

  defp await(check, left \\ 1_000) do
    if check.() do
      :ok
    else
      assert left > 0
      Process.sleep(5)
      await(check, left - 5)
    end
  end
end
