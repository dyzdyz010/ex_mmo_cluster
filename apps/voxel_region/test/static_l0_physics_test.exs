defmodule VoxelRegion.StaticL0PhysicsTest do
  @moduledoc """
  只测试：真实 GeneratedStore 的天然木跨页受热，off/on 独立 File 世界使用相同发布物性和自然热步。
  天然目标不经作者入口改写；有限源及遮挡在目标退休后安装于邻页。此矩阵对应设计 §7.2.2 的邻接受扰，
  halo 外装置长期传播另由雪冰／液体场景覆盖，不以这里替代。
  """
  use ExUnit.Case, async: false
  @moduletag timeout: 240_000
  alias VoxelRegion.{GeneratedStore, World, Damage}
  alias VoxelRegion.World.Pages
  alias VoxelRegion.TestSupport
  alias VoxelRegion.TestSupport.WorldClock
  alias VoxelRegion.TestSupport.{StaticL0Audit, StaticL0Check}

  @fixtures Path.expand("fixtures/static_l0", __DIR__)
  @digest "e63744e26fd94896713eb7722901c1e0c92544df9b4d0fb325b75a2c0a042f8c"
  @page {0, {10, 8, -7}}
  @box {{10, 8, -7}, {11, 9, -6}}
  @radiation_target {642, 573, -416}
  @conduction_target {642, 575, -416}

  setup_all do
    # 可选复用的只是可校验、无 overlay 的生成缓存；所有可变 World 仍在独立临时目录。
    template = System.get_env("STATIC_L0_BASELINE_CACHE") || new_root("template")
    opts = options(template, false, nil)
    assert Base.encode16(:crypto.hash(:sha256, File.read!(opts[:property_catalog_path])), case: :lower) == @digest
    {:ok, source} = GeneratedStore.open(opts)
    # 只烘焙本矩阵正常入口要读取的祖页及同级邻域，不运行全世界 Bake。
    seeds = [@page, {0, {9, 8, -7}}, {0, {10, 9, -7}}]
    for {level, region} <- seeds |> Pages.with_ancestors() |> Pages.expand(), level > 0,
        GeneratedStore.classify(source, level, region) == :mixed do
      assert :ok = GeneratedStore.bake_region(source, level, region)
    end
    %{template: template, cv: GeneratedStore.hex(source.content_version)}
  end

  @tag :conduction
  test "跨 Y 页导热令天然木点燃，退休与常驻的每个自然步一致", c do
    off = run_case(c, :conduction, false, 80)
    assert off.ignited, "有限源未点燃天然木，不能用两个都未触发的样本证明等价"
    on = run_case(c, :conduction, true, length(off.steps))
    assert on.ignited
    assert_steps_equal(off.steps, on.steps)
  end

  @tag :radiation
  test "跨页空气视线加热天然木，真实遮挡削弱辐射；off/on 逐步一致", c do
    visible_off = run_case(c, :visible, false, 20)
    visible_on = run_case(c, :visible, true, 20)
    blocked_off = run_case(c, :blocked, false, 20)
    blocked_on = run_case(c, :blocked, true, 20)
    assert_steps_equal(visible_off.steps, visible_on.steps)
    assert_steps_equal(blocked_off.steps, blocked_on.steps)
    visible = List.last(visible_on.steps).temperature - 293.15
    blocked = List.last(blocked_on.steps).temperature - 293.15
    assert visible > 1.0, "目标必须实际受热"
    assert blocked < visible / 5, "移除遮挡或把遮挡视为空气必须使判定失败"
  end

  defp run_case(c, kind, enabled, limit) do
    root = new_root("#{kind}_#{enabled}")
    File.cp_r!(Path.join(c.template, c.cv), Path.join(root, c.cv))
    clock = start_supervised!({WorldClock, 0})
    opts = options(root, enabled, clock)
    world = start_supervised!({World, opts})
    assert {:ok, _} = World.apply_edit(world, {0, 64_000, 0}, 19)
    assert :ok = World.compact(world)
    stop_supervised!(World)
    world = start_supervised!({World, opts})
    assert :ok = World.set_simulation_windows(world, [@box])
    payload = TestSupport.payload(world, 0, elem(@page, 1))
    target = if kind == :conduction, do: @conduction_target, else: @radiation_target
    assert MmoContracts.Voxel.Payload.material(payload, MmoContracts.Voxel.Payload.local(elem(@page, 1), target)) == 19
    if enabled, do: assert(MapSet.member?(:sys.get_state(world).static_l0.eligible, @page))
    {steps, events} = StaticL0Audit.capture(world, [@page], fn ->
    assert :ok = World.set_simulation_windows(world, [])
    assert Pages.resident?(:sys.get_state(world), @page) == not enabled
    emitter = if kind == :conduction, do: {642, 576, -416}, else: {638, 573, -416}
    # 铜的高导热连接由现有物性决定；遮挡石始终在相邻页，天然目标几何保持原样。
    assert {:ok, _} = World.apply_edit(world, emitter, 24)
    if kind == :blocked, do: assert({:ok, _} = World.apply_edit(world, {639, 573, -416}, 11))
    assert Pages.resident?(:sys.get_state(world), @page)
    assert :sys.get_state(world).simulation_windows == %{}
    heat = Path.join(root, "finite-heat.json")
    File.write!(heat, Jason.encode!(%{classification: "Test-only", source_macro: Tuple.to_list(emitter),
      power_w: 1_500_000.0, energy_j: 60_000_000.0}))
    assert :ok = World.thermal_experiment(world, heat)
    steps = Enum.reduce_while(1..limit, [], fn step, steps ->
      send(world, :thermal_commit)
      # 同一发送者的查询先确保该显式自然步已接纳，再等待真实任务／热 run 完成。
      World.seq(world)
      await_settled(world, 20_000)
      snapshot = World.simulation_snapshot(world, [], @box)
      row = Enum.find(snapshot.property_states, &(Damage.macro(&1) == target))
      value = %{step: step, material: row && row.material || 19,
        temperature: row && Map.get(row, :temperature_kelvin, 293.15) || 293.15,
        burning: row && Map.get(row, :burning, false) || false,
        fuel: row && Map.get(row, :remaining_fuel_j),
        supplied_j: snapshot.thermal_accounting.supplied_j,
        elapsed_s: snapshot.thermal_accounting.elapsed_s}
      steps = [value | steps]
      if kind == :conduction and value.burning, do: {:halt, steps}, else: {:cont, steps}
    end) |> Enum.reverse()
    end)
    assert :ok = StaticL0Check.verify_reads(events, [@page])
    StaticL0Check.write_evidence("physics-#{kind}-#{enabled}", %{identity: %{cv: World.content_version(world), page: @page},
      steps: steps, initially_loaded: [@page], events: events, time_unit: :nanosecond})
    stop_supervised!(World)
    stop_supervised!(WorldClock)
    %{steps: steps, ignited: List.last(steps).burning}
  end

  defp assert_steps_equal(a, b) do
    assert :ok = StaticL0Check.compare_steps(a, b)
    assert length(a) == length(b)
    for {left, right} <- Enum.zip(a, b) do
      assert Map.take(left, [:step, :material, :burning]) == Map.take(right, [:step, :material, :burning])
      for key <- [:temperature, :supplied_j, :elapsed_s] do
        assert_in_delta Map.fetch!(left, key), Map.fetch!(right, key), 1.0e-6
      end
      if left.fuel == nil, do: assert(right.fuel == nil), else: assert_in_delta(left.fuel, right.fuel, 1.0e-6)
    end
  end

  defp await_settled(world, attempts) do
    unless TestSupport.simulation_settled?(world) do
      assert attempts > 0, "有限热步未完成"
      Process.sleep(1)
      await_settled(world, attempts - 1)
    end
  end

  defp options(root, enabled, clock) do
    File.mkdir_p!(Path.join(root, "prefabs"))
    opts = [source: GeneratedStore, root: root, name: nil,
      manifest_path: Path.join(@fixtures, "worldgen.json"),
      property_catalog_path: Path.join(@fixtures, @digest <> ".json"),
      thermal_environment_path: Path.join(@fixtures, "environment.json"),
      prefab_catalog_path: Path.join(root, "prefabs"), static_l0_retirement: enabled]
    if clock, do: Keyword.put(opts, :clock, {WorldClock, clock}), else: opts
  end

  defp new_root(label) do
    root = Path.join(System.tmp_dir!(), "static_l0_physics_#{System.pid()}_#{label}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn ->
      assert Path.dirname(Path.expand(root)) == Path.expand(System.tmp_dir!())
      File.rm_rf!(root)
    end)
    root
  end
end
