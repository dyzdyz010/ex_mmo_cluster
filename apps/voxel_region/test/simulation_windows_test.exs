defmodule VoxelRegion.SimulationWindowsTest do
  @moduledoc "只测试：真实 World／CollisionStream 的窗口贡献与生命周期；空气来源和文件日志，不启动 PG，不代表物理或客户端验收。"
  use ExUnit.Case, async: false
  @moduletag :simulation_windows
  alias VoxelRegion.{World, CollisionStream}

  @a {{0, 0, 0}, {1, 1, 1}}
  @b {{4, 0, 0}, {5, 1, 1}}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "voxim_sim_windows_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    world =
      start_supervised!(
        {World, source: VoxelRegion.TestSupport.Source, root: root, observer: self(), name: nil}
      )

    on_exit(fn -> File.rm_rf!(root) end)
    %{world: world}
  end

  test "完整 XYZ 外圈、重叠去重及独立来源替换／退出", %{world: world} do
    a = {{-1, -1, -1}, {2, 2, 2}}
    b = {{0, -1, -1}, {3, 2, 2}}
    assert :ok = World.set_simulation_windows(world, [a, a])

    assert %{source_count: 1, window_page_count: 125, window_pages: pages} =
             World.simulation_windows(world)

    assert [-2, -2, -2] in pages and [2, 2, 2] in pages
    refute [3, 2, 2] in pages
    parent = self()

    other =
      spawn(fn ->
        send(parent, {:registered, World.set_simulation_windows(world, [b])})
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> send(other, :stop) end)
    assert_receive {:registered, :ok}
    assert World.simulation_windows(world).window_page_count == 150
    assert :ok = World.set_simulation_windows(world, [])
    assert %{source_count: 1, window_page_count: 125} = World.simulation_windows(world)
    send(other, :stop)
    await(fn -> World.simulation_windows(world).source_count == 0 end)
    assert World.seq(world) == 0
  end

  test "只读装页和普通 canonical 观察不授予窗口资格；非法盒显式拒绝", %{world: world} do
    World.material_snapshot(world, [], [{0, 0, 0}])
    assert :ok = World.canonical_snapshot_and_subscribe(world, @a, self(), :read_only, false)
    assert_receive {:canonical_snapshot, :read_only, _}
    assert %{source_count: 0, window_page_count: 0} = World.simulation_windows(world)

    assert {:error, :invalid_simulation_windows} =
             World.set_simulation_windows(world, [{{0, 0, 0}, {0, 1, 1}}])

    assert {:error, :invalid_simulation_windows} =
             World.set_simulation_windows(world, [{{0, 0, 0}, {1, 1, 1.0}}])

    assert World.simulation_windows(world).source_count == 0
  end

  test "ACK 不退休旧窗；移交屏障只等接纳，旧 owner 的迟到发布不能覆盖新 owner", %{world: world} do
    gate = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(gate, :stop) end)
    {:ok, stream} = CollisionStream.start(world, gate, self(), @a)
    monitor = Process.monitor(stream)
    assert_receive {:collision_stream, ^stream, 1, {:window, _}}, 10_000
    assert World.simulation_windows(world).window_page_count == 27
    parent = self()
    owner = spawn(fn -> owner_loop(parent) end)
    on_exit(fn -> send(owner, :stop) end)

    # 只测试调度：World 暂停时，旧 Player 的 seal 屏障仍能完成，不能形成 Player→流→World→Player 的等待环。
    :sys.suspend(world)

    try do
      CollisionStream.window(stream, @b, [@a, @b])
      assert :ok = CollisionStream.synchronize(stream)
      assert :ok = CollisionStream.attach(stream, owner, 1, [@a, @b])
      CollisionStream.set_simulation_windows(stream, [@a])
      assert :ok = CollisionStream.synchronize(stream)
    after
      :sys.resume(world)
    end

    assert_receive {:forwarded, {:collision_stream, ^stream, cursor, {:window, snapshot}}}, 10_000
    assert snapshot.l0_min == {4, 0, 0}
    CollisionStream.acknowledge(stream, cursor)
    assert :ok = CollisionStream.synchronize(stream)
    assert World.simulation_windows(world).window_page_count == 54
    send(owner, {:windows, stream, [@b]})
    await(fn -> World.simulation_windows(world).window_page_count == 27 end)
    assert [5, 1, 1] in World.simulation_windows(world).window_pages
    refute [-1, 0, 0] in World.simulation_windows(world).window_pages
    send(gate, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^stream, :normal}, 10_000
    await(fn -> World.simulation_windows(world).source_count == 0 end)
  end

  defp owner_loop(parent) do
    receive do
      :stop ->
        :ok

      {:windows, stream, boxes} ->
        CollisionStream.set_simulation_windows(stream, boxes)
        owner_loop(parent)

      message ->
        send(parent, {:forwarded, message})
        owner_loop(parent)
    end
  end

  defp await(fun, left \\ 2_000)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, left) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(1)
          await(fun, left - 1)
        )
  end
end
