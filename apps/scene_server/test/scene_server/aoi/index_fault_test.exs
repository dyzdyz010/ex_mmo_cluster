defmodule SceneServer.Aoi.IndexFaultTest do
  @moduledoc """
  Fault-injection tests for the S1 去单点 / hydrate 不变式(3.2)。

  覆盖三条验收核心:

  ① `IndexStore`(原 `AoiManager` 单点)崩溃重启后,AOI 视图不错乱——八叉树句柄与 CID
     索引原样 hydrate(同一句柄),存活 `AoiItem` 的邻居查询仍正确,不孤儿化。
  ② 移动热路径(`self_move` → 位置写入)不再经单点同步 call——`IndexStore` 进程被挂起
     时,位置写入与读取照样成功(走 ETS / 八叉树 NIF,与该进程无关)。
  ③ 并发 `self_move` 不串行化到单进程——多进程并发写位置全部落地,且 `IndexStore` 挂起
     不阻塞它们。
  """

  use ExUnit.Case, async: false

  alias SceneServer.Aoi.Index
  alias SceneServer.Aoi.IndexStore
  alias SceneServer.AoiManager
  alias SceneServer.Movement.RemoteSnapshot

  setup do
    SceneServer.TestAoiRuntime.ensure_started!()
    SceneServer.Aoi.RemoteMirrorLedger
    |> ensure_remote_mirror_ledger()

    :ok
  end

  test "AoiManager facade is no longer a process (single-point process removed)" do
    # S1 主张:管理者退化为无状态 facade。它绝不能再是一个被 call 串行的进程。
    assert Process.whereis(SceneServer.AoiManager) == nil
    # 真正持有句柄的是极简稳定的 IndexStore。
    assert is_pid(Process.whereis(SceneServer.Aoi.IndexStore))
    assert is_pid(Process.whereis(SceneServer.Aoi.IndexHeir))
  end

  test "① IndexStore restart preserves octree handle + entries; survivors are not orphaned" do
    observer_cid = unique_cid()
    mover_cid = unique_cid()

    observer = add_aoi_item(observer_cid, {0.0, 0.0, 0.0}, self())
    mover = add_aoi_item(mover_cid, {50.0, 0.0, 0.0}, spawn_sink())

    on_exit(fn ->
      exit_aoi_item(observer)
      exit_aoi_item(mover)
    end)

    octree_before = Index.octree()
    store_before = Process.whereis(IndexStore)

    # Sanity:索引里有这两条 entry,八叉树里能查到邻居。
    assert AoiManager.get_actor_pid(observer_cid) == self()
    assert mover_cid in (Index.fetch_entries([mover_cid]) |> Enum.map(& &1.cid))
    assert mover_cid in nearby_cids({0.0, 0.0, 0.0}, 100.0)

    # 故障注入:杀死 IndexStore(单点)。heir 接管 ETS 表,AoiSup 重启 IndexStore,
    # 它从 heir 认领回同一张表 → 同一八叉树句柄、同一份 entries。
    ref = Process.monitor(store_before)
    Process.exit(store_before, :kill)
    assert_receive {:DOWN, ^ref, :process, ^store_before, :killed}, 2_000

    wait_until(fn ->
      case Process.whereis(IndexStore) do
        pid when is_pid(pid) and pid != store_before -> true
        _ -> false
      end
    end)

    octree_after = Index.octree()

    # hydrate 不变式:同一句柄,索引未被空默认兜底覆盖。
    assert octree_after == octree_before,
           "IndexStore restart must reuse the SAME octree handle, not create an empty new tree"

    assert AoiManager.get_actor_pid(observer_cid) == self()
    assert AoiManager.get_actor_pid(mover_cid) != nil

    # AOI 视图不错乱:存活 AoiItem 的邻居查询仍正确(没有孤儿化到旧空树)。
    assert mover_cid in nearby_cids({0.0, 0.0, 0.0}, 100.0)

    # 存活 mover 继续 self_move,位置写入新八叉树仍被观察到。
    GenServer.cast(mover, {:self_move, snapshot(mover_cid, {500.0, 0.0, 0.0})})

    wait_until(fn -> :sys.get_state(mover).location == {500.0, 0.0, 0.0} end)

    refute mover_cid in nearby_cids({0.0, 0.0, 0.0}, 100.0)
    assert mover_cid in nearby_cids({500.0, 0.0, 0.0}, 100.0)
  end

  test "② self_move hot path does not route through the IndexStore process (no single-point call)" do
    cid = unique_cid()
    aoi = add_aoi_item(cid, {0.0, 0.0, 0.0}, spawn_sink())
    on_exit(fn -> exit_aoi_item(aoi) end)

    store = Process.whereis(IndexStore)

    # 把 IndexStore 进程挂起。如果热路径写位置要同步 call 它,就会阻塞 / 超时。
    :sys.suspend(store)

    try do
      # 直接驱动热路径写:Index.update_location 是原子 ETS 写,与 IndexStore 进程无关。
      assert Index.update_location(cid, {123.0, 0.0, 0.0}) == :ok
      assert [%{location: {123.0, 0.0, 0.0}}] = Index.fetch_entries([cid])

      # facade 入口同样不阻塞(AoiManager.update_item_location 委托给 Index)。
      assert AoiManager.update_item_location(cid, {7.0, 8.0, 9.0}) == :ok
      assert [%{location: {7.0, 8.0, 9.0}}] = Index.fetch_entries([cid])

      # 读路径(邻居查询)同样不经 IndexStore 进程。
      assert is_list(nearby_cids({7.0, 8.0, 9.0}, 50.0))
    after
      :sys.resume(store)
    end
  end

  test "③ concurrent self_move location writes do not serialize through one process" do
    cids = for _ <- 1..50, do: unique_cid()

    items =
      for cid <- cids do
        {cid, add_aoi_item(cid, {0.0, 0.0, 0.0}, spawn_sink())}
      end

    on_exit(fn -> Enum.each(items, fn {_cid, pid} -> exit_aoi_item(pid) end) end)

    store = Process.whereis(IndexStore)
    # 挂起单点进程:若并发写需要串行到它,下面的并发写会全部卡住。
    :sys.suspend(store)

    try do
      tasks =
        for {cid, _pid} <- items do
          Task.async(fn ->
            Index.update_location(cid, {cid * 1.0, 0.0, 0.0})
          end)
        end

      results = Task.await_many(tasks, 2_000)
      assert Enum.all?(results, &(&1 == :ok))

      # 每条写都落地到正确位置(并发无相互覆盖)。
      for {cid, _pid} <- items do
        assert [%{location: {loc_x, 0.0, 0.0}}] = Index.fetch_entries([cid])
        assert loc_x == cid * 1.0
      end
    after
      :sys.resume(store)
    end
  end

  ## Helpers

  defp add_aoi_item(cid, location, connection_pid) do
    {:ok, pid} =
      AoiManager.add_aoi_item(
        cid,
        0,
        location,
        connection_pid,
        self(),
        %{kind: :player, name: "fault-#{cid}"}
      )

    wait_until(fn ->
      match?(%{item_ref: ref} when not is_nil(ref), :sys.get_state(pid))
    end)

    pid
  end

  defp nearby_cids(center, radius) do
    Index.octree()
    |> SceneServer.Native.Octree.get_in_bound(center, {radius, radius, radius})
  end

  defp snapshot(cid, position) do
    %RemoteSnapshot{
      cid: cid,
      server_tick: 1,
      position: position,
      velocity: {0.0, 0.0, 0.0},
      acceleration: {0.0, 0.0, 0.0},
      movement_mode: :grounded
    }
  end

  defp exit_aoi_item(nil), do: :ok

  defp exit_aoi_item(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.call(pid, :exit, 1_000)
      catch
        :exit, _ -> :ok
      end

      wait_until(fn -> not Process.alive?(pid) end)
    end
  end

  defp spawn_sink, do: spawn(fn -> sink_loop() end)

  defp sink_loop do
    receive do
      _ -> sink_loop()
    end
  end

  defp ensure_remote_mirror_ledger(mod) do
    case Process.whereis(mod) do
      nil -> start_supervised!({mod, name: mod})
      pid -> pid
    end
  end

  defp unique_cid, do: System.unique_integer([:positive])

  defp wait_until(fun, attempts \\ 80)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition not met before timeout")
end
