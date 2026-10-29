defmodule VoxelRegion.PageLoadContextTest do
  @moduledoc """
  只测试：PageLoad 的输入运输与唯一 caller 生命周期；不建立或断言世界物理真值。
  测试进程充当页任务的回复 owner，仅在 :page_need 边界回复 :ready，验证真实任务与 monitor 信号。
  实际 World ready 队列、输入生效和物理次序由 CW2 公共入口集成测试负责。
  """
  use ExUnit.Case, async: true
  alias VoxelRegion.World.{PageLoad, Pages}

  defp state do
    %{page_load: PageLoad.new(), resident: MapSet.new(), page_generation: %{},
      log: {VoxelRegion.OverlayLog.File, System.tmp_dir!()}}
  end

  defp context(request) do
    %{id: make_ref(), arrival_ms: 123, request_ref: request, ready_round: 2, ready_cutoff_ms: 456, page_dependencies: []}
  end

  defp caller do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp finish_task(state) do
    assert_receive {:"$gen_call", {pid, _} = from, {:page_need, _, _, _, pid}}, 1_000
    ref = Enum.find_value(state.page_load.tasks, fn {ref, task} -> task.pid == pid and ref end)
    GenServer.reply(from, :ready)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    PageLoad.finish(state, ref, :normal)
  end

  test "ready等待反复登记复用同一monitor，空重放身份不擦掉原timeout身份" do
    pid = caller()
    from = {pid, make_ref()}
    request = make_ref()
    state = PageLoad.track(state(), from, request)
    monitor = state.page_load.callers[from].monitor
    state = state |> PageLoad.track(from, request) |> PageLoad.track(from, nil)
    assert state.page_load.callers[from].monitor == monitor
    assert PageLoad.request_id(state, from) == request
    assert {:monitors, monitors} = Process.info(self(), :monitors)
    assert Enum.count(monitors, &(&1 == {:process, pid})) == 1
    # 没有PageLoad任务的ready等待也必须能取消，并把from交回World删其ready队列。
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
    assert PageLoad.caller?(state, monitor)
    assert {^from, [], state} = PageLoad.cancel(state, monitor)
    assert state.page_load.callers == %{}
    assert {nil, [], ^state} = PageLoad.cancel(state, request)
    assert {:monitors, monitors} = Process.info(self(), :monitors)
    refute {:process, pid} in monitors
  end

  test "context经装页完成与二次defer原样运输，同body held直到接纳owner显式release" do
    context = context(nil)
    entry = {:input, context, {:info, {:body_death, 7, {0.0, 0.0, 0.0}}}}
    next = {:input, context(nil), {:info, {:body_detach, 7, self(), make_ref()}}}
    {:deferred, state} = PageLoad.gate(state(), entry, 0)
    state = state |> PageLoad.hold({:body, 7}) |> PageLoad.enqueue({:body, 7}, next)
    assert PageLoad.order_key(entry) == {:body, 7}
    {[returned], 0, state} = finish_task(state)
    assert returned == entry
    assert PageLoad.held?(state, {:body, 7})

    # 新准备轮次由World更新；PageLoad不能据当前时间或任务attempt重写它。
    next_context = %{context | ready_round: 3, ready_cutoff_ms: nil}
    deferred = {:input, next_context, elem(entry, 2)}
    state = PageLoad.defer(state, deferred, [{0, {2, 0, 0}}])
    {[returned], 1, state} = finish_task(state)
    assert returned == {:input, %{next_context | page_dependencies: [{0, {2, 0, 0}}]}, elem(entry, 2)}
    assert PageLoad.held?(state, {:body, 7})
    assert {[^next], state} = PageLoad.release(state, {:body, 7})
    refute PageLoad.held?(state, {:body, 7})
  end

  test "wrapped caller取消返回from且只删该entry，共享模拟任务和wake继续" do
    pid = caller()
    from = {pid, make_ref()}
    request = make_ref()
    key = {0, {0, 0, 0}}
    entry = {:input, context(request), {:call, {:material_snapshot, [], [{1, 1, 1}]}, from}}
    state = PageLoad.track(state(), from, request)
    monitor = state.page_load.callers[from].monitor
    {:deferred, state} = PageLoad.gate(state, entry, 0)
    assert state.page_load.callers[from].monitor == monitor
    assert_receive {:"$gen_call", {reader, _} = load_from, {:page_need, keys, exact, ids, reader}}, 1_000
    reply = PageLoad.need(state, keys, exact, ids, reader)
    state = PageLoad.reserve(state, reader, reply)
    {:loading, state} = PageLoad.request(state, [key])
    attempt = state.page_load.sim.attempt_id
    assert {^from, [], state} = PageLoad.cancel(state, request)
    assert state.page_load.callers == %{}
    assert Process.alive?(reader)
    [{ref, task}] = Map.to_list(state.page_load.tasks)
    assert task.entries == [:wake]
    assert state.page_load.pending[key] == ref
    GenServer.reply(load_from, :ready)
    assert_receive {:DOWN, ^ref, :process, ^reader, :normal}, 1_000
    # 此reader只接到了相交的本页；纯transport夹具按owner回复声明该页已驻留，其余闭包仍须继续。
    state = Pages.mark_resident(state, [key])
    assert {[], 0, state} = PageLoad.finish(state, ref, :normal)
    assert state.page_load.sim.attempt_id == attempt
    assert state.page_load.sim.status == :loading
    # 第二个owner回合完成剩余依赖，只有完整原请求满足才能交回wake。
    state = Pages.mark_resident(state, Pages.expand([key]))
    assert {[:wake], 0, state} = finish_task(state)
    assert state.page_load.sim == nil
    assert state.page_load.pending == %{}
  end
end
