defmodule VoxelRegion.ThermalScopeTest do
  @moduledoc "只测试：真实World持续演化与窗口解耦；空气源、文件日志替身，不启动PG或客户端。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, TestSupport}
  @ambient 293.15
  @window {{0, 0, 0}, {1, 1, 1}}
  @opened {{0, 0, 0}, {2, 1, 1}}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "thermal_scope_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "prefabs"))

    materials =
      for id <- 0..23 do
        base = %{
          material_id: id,
          max_hp_per_macro: if(id == 0, do: 0.0, else: 100.0),
          defense: 2.0,
          tags: [],
          responses: [%{action: "damage", multiplier: 1.0}]
        }

        if id == 19,
          do:
            Map.merge(base, %{
              heat_capacity_per_macro: 1000.0,
              thermal_conductivity: 10.0,
              heat_resistance_kelvin: 1.0e5
            }),
          else: base
      end

    catalog = Path.join(root, "catalog.json")

    File.write!(
      catalog,
      Jason.encode!(%{
        schema_version: 1,
        tags: [%{id: "damage"}],
        materials: materials,
        tools: [],
        definitions: []
      })
    )

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, catalog: catalog}
  end

  defp start(c, cells, source, emissivity \\ 0.0, power \\ 20_000.0) do
    environment = %{
      ambient_kelvin: @ambient,
      environment_w_per_m2_k: 1.0e-9,
      tolerance_kelvin: 0.001,
      emissivity: emissivity,
      view_range_cells: 8,
      circuit_min_power_w: 1.0
    }

    path = Path.join(c.root, "environment.json")
    File.write!(path, Jason.encode!(environment))

    world =
      start_supervised!(
        {World,
         source: TestSupport.Source,
         log: TestSupport.Log,
         root: c.root,
         observer: self(),
         name: nil,
         property_catalog_path: c.catalog,
         thermal_environment_path: path,
         prefab_catalog_path: Path.join(c.root, "prefabs"),
         production_materials: [19]}
      )

    pause_clock(world)
    assert {:ok, _} = World.apply_edits(world, Enum.map(cells, &{&1, 19}))
    pause_clock(world)
    experiment = Path.join(c.root, "heat.json")

    File.write!(
      experiment,
      Jason.encode!(
        Map.merge(
          environment,
          %{
            classification: "Test-only",
            source_macro: Tuple.to_list(source),
            power_w: power,
            energy_j: 10_000.0
          }
        )
      )
    )

    assert :ok = World.thermal_experiment(world, experiment)
    pause_clock(world)
    world
  end

  # 只测试时钟：沿既有热测试入口取消墙钟定时器，随后只投递正式热提交消息，不改世界真值。
  defp pause_clock(world) do
    state = :sys.get_state(world)
    if state.thermal_timer, do: Process.cancel_timer(state.thermal_timer)
    assert state.thermal_run == nil
  end

  # 直接提交的步前读取集缺页时挂闸、装齐后重放；开始后遇热域新扩进的未驻留页时暂停、装齐后续完同一笔提交（world.ex drain_thermal）。
  # 只测试等这笔提交自然结束，不代推进、不改调度。装页反复不完成即 await 显式失败。
  defp tick(world) do
    send(world, :thermal_commit)
    await(fn -> TestSupport.simulation_settled?(world) end)
    pause_clock(world)
    observe(world)
  end

  defp observe(world), do: TestSupport.observe(world, [], {{0, -1, -1}, {3, 1, 1}})

  defp temperature(snapshot, {x, y, z}) do
    Enum.find_value(snapshot.damage, @ambient, fn {_, row} ->
      if row.micro == {x * 8, y * 8, z * 8}, do: Map.get(row, :temperature_kelvin, @ambient)
    end)
  end

  defp sky_area(world) do
    for {_, rows} <- :sys.get_state(world).thermal_work.sights,
        {_, :sky, area} <- rows,
        reduce: 0.0,
        do: (sum -> sum + area)
  end

  @tag :continuous_world
  test "零窗口有限热源继续供能，窗口增减不改变进度与热账", c do
    world = start(c, [{128, 0, 0}], {128, 0, 0}, 0.0, 2_000.0)
    assert World.simulation_windows(world).source_count == 0
    first = tick(world)
    assert_in_delta first.thermal.supplied_j, 1_000.0, 1.0e-9
    assert :ok = World.set_simulation_windows(world, [@opened])
    second = tick(world)
    assert :ok = World.set_simulation_windows(world, [])
    third = tick(world)
    assert_in_delta second.thermal.supplied_j, 2_000.0, 1.0e-9
    assert_in_delta third.thermal.supplied_j, 3_000.0, 1.0e-9
    assert_in_delta third.thermal.elapsed_s, 1.5, 1.0e-12
    assert_in_delta third.thermal.sources[{128, 0, 0}].remaining_j, 7_000.0, 1.0e-9
    assert_in_delta 1000.0 * (temperature(third, {128, 0, 0}) - @ambient),
      third.thermal.supplied_j + third.thermal.environment_j, 1.0e-6
  end

  @tag :continuous_world
  test "跨原窗口页边界导热，关闭全部窗口后仍持续交换且守恒", c do
    world = start(c, [{127, 0, 0}, {128, 0, 0}], {127, 0, 0})
    assert :ok = World.set_simulation_windows(world, [@window])
    tick(world)
    first = tick(world)
    assert temperature(first, {128, 0, 0}) > @ambient
    assert :ok = World.set_simulation_windows(world, [])
    second = tick(world)
    assert temperature(second, {128, 0, 0}) > temperature(first, {128, 0, 0})
    assert_in_delta 1000.0 * (temperature(second, {127, 0, 0}) + temperature(second, {128, 0, 0}) - 2 * @ambient),
      second.thermal.supplied_j + second.thermal.environment_j, 1.0e-6
  end

  @tag :continuous_world
  test "窗口变更不遮挡辐射，真实几何的天空面保持六面", c do
    world = start(c, [{127, 0, 0}], {127, 0, 0}, 0.9)
    assert :ok = World.set_simulation_windows(world, [@window])
    first = tick(world)
    assert sky_area(world) == 6.0
    assert :ok = World.set_simulation_windows(world, [@opened])
    second = tick(world)
    assert sky_area(world) == 6.0
    assert :ok = World.set_simulation_windows(world, [])
    third = tick(world)
    assert sky_area(world) == 6.0
    assert third.thermal.environment_j < second.thermal.environment_j
    for snapshot <- [first, second, third] do
      assert_in_delta 1000.0 * (temperature(snapshot, {127, 0, 0}) - @ambient),
        snapshot.thermal.supplied_j + snapshot.thermal.environment_j, 1.0e-6
    end
  end

  @tag :continuous_world
  test "身体接触不依赖玩家窗口登记", c do
    world = start(c, [{128, 0, 0}], {128, 0, 0})
    tick(world)
    body = %{feet: {128.5, 1.0, 0.5}, height: 1.8, radius: 0.3, skin_k: @ambient,
      capacity: 24_430.0, area: 1.8, tissue_k: @ambient, tissue_capacity: 209.4,
      tissue_g: 0.378207}
    send(world, {:body_contact, 1001, self(), body})
    tick(world)
    assert_receive {:body_heat, %{q_j: heat}}
    assert heat > 0.0
  end

  @tag :continuous_world
  @tag :thermal_scope_inflight
  test "进行中 run 换窗不改变物理，保留已算热量且不重放有限源", c do
    cells = [{126, 0, 0}, {127, 0, 0}, {128, 0, 0}]
    world = start(c, cells, {127, 0, 0}, 0.0, 100_000.0)

    # 两个有限源分别在 0.1／0.2 s 耗尽，保证一笔 0.5 s 提交里存在真实消息接缝。
    path = Path.join(c.root, "second-heat.json")

    File.write!(
      path,
      Jason.encode!(%{
        classification: "Test-only",
        source_macro: [126, 0, 0],
        power_w: 100_000.0,
        energy_j: 20_000.0
      })
    )

    assert :ok = World.thermal_experiment(world, path)
    pause_clock(world)
    assert :ok = World.set_simulation_windows(world, [@window])
    parent = self()

    hook = fn debug, event, _ ->
      if match?({:in, {:thermal_step, _}}, event) and
           not Process.get(:thermal_scope_paused, false) do
        Process.put(:thermal_scope_paused, true)
        send(parent, {:thermal_step_paused, self()})
        receive do: (:continue_thermal_scope -> :ok)
      end

      debug
    end

    assert :ok = :sys.install(world, {hook, nil})
    send(world, :thermal_tick)
    assert_receive {:thermal_step_paused, ^world}, 2_000
    update = Task.async(fn -> World.set_simulation_windows(world, [@opened]) end)

    try do
      await(fn ->
        {:messages, messages} = Process.info(world, :messages)
        Enum.any?(messages, &match?({:"$gen_call", _, {:page_request, _, {:simulation_windows, [@opened]}}}, &1))
      end)
    after
      send(world, :continue_thermal_scope)
    end

    assert :ok = Task.await(update, 2_000)
    await(fn -> observe(world).thermal.elapsed_s >= 0.5 end)
    pause_clock(world)
    snapshot = observe(world)
    assert_in_delta snapshot.thermal.elapsed_s, 0.5, 1.0e-12
    assert_in_delta snapshot.thermal.supplied_j, 30_000.0, 1.0e-9
    assert temperature(snapshot, {128, 0, 0}) > @ambient
    stored = Enum.sum(for cell <- cells, do: 1000.0 * (temperature(snapshot, cell) - @ambient))
    assert_in_delta stored, snapshot.thermal.supplied_j + snapshot.thermal.environment_j, 1.0e-6
  end

  defp await(check, left \\ 2_000)

  defp await(check, left) do
    if check.(), do: :ok, else: wait_again(check, left)
  end

  defp wait_again(check, left) when left > 0 do
    Process.sleep(1)
    await(check, left - 1)
  end

  defp wait_again(_check, _left), do: flunk("未观察到声明的热步／窗口接纳条件")
end
