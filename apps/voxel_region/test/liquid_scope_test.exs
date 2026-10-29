defmodule VoxelRegion.LiquidScopeTest do
  @moduledoc "只测试：真实World液体活动前沿与窗口解耦、无人恢复与自然休眠；空气/静水来源及文件日志替身。"
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport
  alias MmoContracts.Voxel.{Payload, Skins}

  @capacity 2_097_152
  @gravity div(@capacity, 4)
  @side div(@capacity, 16)
  @window {{0, 0, 0}, {1, 1, 1}}

  defmodule WaterSource do
    @moduledoc "只测试：发布一格有限静水的合法 canonical 来源，接纳静水本身不创建活动前沿。"
    def open(opts) do
      {:ok, state} = TestSupport.Source.open(opts)
      {:ok, Map.put(state, :water, Keyword.get(opts, :water))}
    end

    defdelegate content_version(state), to: TestSupport.Source
    defdelegate world_dir(state), to: TestSupport.Source
    defdelegate generated(state), to: TestSupport.Source
    defdelegate ensure(state, level, region), to: TestSupport.Source

    def read(state, level, region) do
      {:ok, bytes, _} = TestSupport.Source.read(state, level, region)
      {:ok, payload} = Payload.decode(bytes)
      local = if state.water, do: Payload.local(region, state.water)

      edits =
        if (level == 0 and local) && Payload.in_span?(local),
          do: %{local => {21, Skins.uniform(21)}},
          else: %{}

      bytes = Payload.encode(payload, edits, 0, 123)
      {:ok, header} = MmoContracts.Voxel.Codec.decode_payload_header(bytes)
      {:ok, bytes, header}
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "liquid_scope_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    catalog =
      Jason.decode!(File.read!(TestSupport.catalog()))
      |> Map.put("liquid", %{
        "step_seconds" => 3600,
        "gravity_units_per_step" => @gravity,
        "side_units_per_step" => @side,
        "side_threshold_units" => 0
      })

    path = Path.join(root, "catalog.json")
    File.write!(path, Jason.encode!(catalog))
    prefabs = Path.join(root, "prefabs")
    File.mkdir_p!(prefabs)

    opts = [
      source: WaterSource,
      log: TestSupport.Log,
      root: root,
      observer: self(),
      name: nil,
      property_catalog_path: path,
      prefab_catalog_path: prefabs,
      production_materials: [19, 21]
    ]

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, opts: opts}
  end

  defp world(c, bounds, extra \\ []) do
    opts = Keyword.merge(c.opts, [liquid_bounds: bounds] ++ extra)
    {start_supervised!({World, opts}), opts}
  end

  defp author(c, world, cell) do
    path = Path.join(c.root, "water.json")

    File.write!(
      path,
      Jason.encode!(%{
        classification: "Test-only",
        deposits: [%{macro: Tuple.to_list(cell), material: 21}]
      })
    )

    assert {:ok, _} = World.liquid_experiment(world, path)
  end

  defp tick(world),
    do:
      (
        send(world, :liquid_commit)
        World.seq(world)
      )

  defp quantities(world),
    do: World.simulation_snapshot(world, [], {{-3, -3, -3}, {4, 4, 4}}).liquid_quantities

  for {name, from, to, bounds, moved} <- [
        {"X 正页边界", {127, 0, 0}, {128, 0, 0}, {{127, 0, 0}, {129, 1, 1}}, @side},
        {"Z 负页边界", {0, 0, -65}, {0, 0, -64}, {{0, 0, -65}, {1, 1, -63}}, @side},
        {"Y 正页边界", {0, 128, 0}, {0, 127, 0}, {{0, 127, 0}, {1, 129, 1}}, @gravity},
        {"Y 负页边界", {0, -64, 0}, {0, -65, 0}, {{0, -65, 0}, {1, -63, 1}}, @gravity}
      ] do
    @tag :continuous_world
    test "零窗口液体跨#{name}继续搬运且守恒", c do
      from = unquote(Macro.escape(from))
      to = unquote(Macro.escape(to))
      {world, _} = world(c, unquote(Macro.escape(bounds)))
      author(c, world, from)
      assert World.simulation_windows(world).source_count == 0
      assert World.liquid_activity(world).scheduled
      tick(world)
      assert quantities(world) == %{from => @capacity - unquote(moved), to => unquote(moved)}
    end
  end

  @tag :continuous_world
  test "持久活动前沿真实重启后无窗继续，并保留总量", c do
    {world, opts} = world(c, {{0, 0, 0}, {1, 2, 1}})
    author(c, world, {0, 1, 0})
    assert :ok = World.compact(world)
    stop_supervised!(World)
    restored = start_supervised!({World, opts})
    assert World.simulation_windows(restored).source_count == 0
    assert World.liquid_activity(restored).scheduled
    tick(restored)
    assert quantities(restored) == %{{0, 1, 0} => @capacity - @gravity, {0, 0, 0} => @gravity}
  end

  @tag :continuous_world
  test "窗口退出继续下落，自然达稳态后清帧并休眠", c do
    {world, _} = world(c, {{0, 0, 0}, {1, 2, 1}})
    assert :ok = World.set_simulation_windows(world, [@window])
    author(c, world, {0, 1, 0})
    assert :ok = World.canonical_snapshot_and_subscribe(world, @window, self(), :fall, false)
    assert_receive {:canonical_snapshot, :fall, _}, 5_000
    tick(world)
    assert_receive {:canonical_delta,
      %{transaction: %{liquid_falls: %{transfers: [{{0, 0, 0}, @gravity}]}}}}, 5_000
    assert :ok = World.set_simulation_windows(world, [])
    tick(world)
    assert quantities(world) == %{{0, 1, 0} => @capacity - 2 * @gravity, {0, 0, 0} => 2 * @gravity}
    tick(world)
    tick(world)
    assert quantities(world) == %{{0, 0, 0} => @capacity}
    tick(world)
    assert_receive {:canonical_delta, %{transaction: %{liquid_falls: %{transfers: []}}}}, 5_000
    refute World.liquid_activity(world).scheduled
    seq = World.seq(world)
    assert tick(world) == seq
  end

  @tag :continuous_world
  test "自然静水不因读取或换窗重复激活，真实编辑由owner唤醒", c do
    {world, _} = world(c, {{127, 0, 0}, {129, 1, 1}}, water: {127, 0, 0})
    TestSupport.payload(world, 0, {1, 0, 0})
    assert quantities(world) == %{{127, 0, 0} => @capacity}
    assert World.liquid_activity(world) == %{active_cells: 0, scheduled: false}
    assert :ok = World.set_simulation_windows(world, [@window])
    assert :ok = World.set_simulation_windows(world, [])
    refute World.liquid_activity(world).scheduled
    assert {:ok, _} = World.apply_edit(world, {128, 0, 0}, 19)
    assert {:ok, _} = World.apply_edit(world, {128, 0, 0}, 0)
    assert World.liquid_activity(world).scheduled
    tick(world)
    assert quantities(world) == %{{127, 0, 0} => @capacity - @side, {128, 0, 0} => @side}
  end
end
