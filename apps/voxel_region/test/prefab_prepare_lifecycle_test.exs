defmodule VoxelRegion.PrefabPrepareLifecycleTest do
  @moduledoc """
  只测试（Test-only）：Definitions 请求资源 owner 与 PageLoad caller 生命周期的直接回调组件测试。

  使用真实 Catalog、typed Cache、PageLoad.call 与 Definitions worker；测试进程仅扮演 World 的
  接收／回复边界，暂留真实 prefab_loaded 调用的回复来确定等待点。不启动 World、数据库或客户端，
  不向运行中的 authority 注入状态；wrapper request 身份取消不等于真实 World 公共超时已验收。
  """
  use ExUnit.Case, async: true

  alias VoxelRegion.Prefab
  alias VoxelRegion.Prefab.Catalog
  alias VoxelRegion.World.{Cache, Definitions, PageLoad}

  setup do
    path = Path.join(System.tmp_dir!(), "prefab_owner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    child = Prefab.encode(%{cells: [{{0, 0, 0}, 19}], children: [], attachments: []})
    child_id = :crypto.hash(:sha256, child)
    root = Prefab.encode(%{cells: [], attachments: [], children: [
      %{slot: 1, definition_id: child_id, anchor: {8, 0, 0}, orientation: 0}
    ]})
    root_id = :crypto.hash(:sha256, root)

    for {id, bytes} <- [{child_id, child}, {root_id, root}] do
      File.write!(Path.join(path, Base.encode16(id, case: :lower) <> ".vxpd"), bytes)
    end

    assert {:ok, catalog} = Catalog.open(path, nil)
    assert {:ok, cache} = Cache.put(Cache.new(16_384), {:prefab, child_id}, child, child_id)

    {:ok, state: %{prefabs: catalog, cache: cache, prefab_requests: %{},
      prefab_source_bytes: 0, page_load: PageLoad.new()}, root_id: root_id, root: root,
      child_id: child_id, source_bytes: byte_size(root) + byte_size(child)}
  end

  test "wrapper request身份取消停止等待worker并退休资源，迟到token不能复活", fixture do
    pending = held_request(fixture)
    worker_monitor = Process.monitor(pending.worker)

    assert {from, [], state} = PageLoad.cancel(pending.state, pending.request)
    assert from == pending.from
    state = Definitions.cancel(state, from)

    assert_receive {:DOWN, ^worker_monitor, :process, worker, :killed}, 1_000
    assert worker == pending.worker
    refute Process.alive?(worker)
    assert_retired(state, pending)
    assert_stale_token(state, pending, fixture)
  end

  test "真实worker异常DOWN显式回复失败并退休资源，迟到token不能复活", fixture do
    pending = held_request(fixture)
    worker = pending.worker
    monitor = pending.worker_monitor
    caller = elem(pending.from, 0)

    Process.exit(worker, :prefab_lifecycle_failure)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :prefab_lifecycle_failure}, 1_000
    assert {:handled, state} = Definitions.down(pending.state, monitor, :prefab_lifecycle_failure)
    assert_receive {:prefab_result, ^caller,
      {:error, {:definition_prepare_exit, :prefab_lifecycle_failure}}}, 1_000

    refute Process.alive?(worker)
    assert_retired(state, pending)
    assert_stale_token(state, pending, fixture)
  end

  defp held_request(fixture) do
    owner = self()
    operation = {:geometry, fixture.root_id}
    caller = spawn(fn ->
      result = PageLoad.call(owner, {:prefab_request, operation}, :infinity)
      send(owner, {:prefab_result, self(), result})
      receive do: (:stop -> :ok)
    end)
    on_exit(fn -> Process.exit(caller, :kill) end)

    assert_receive {:"$gen_call", {^caller, _} = from,
      {:page_request, request, {:prefab_request, ^operation}}}, 1_000

    # 模拟 World 的 ready 等待边界已登记 caller；Definitions 必须复用该唯一 monitor。
    state = PageLoad.track(fixture.state, from, request)
    caller_monitor = state.page_load.callers[from].monitor
    assert {:deferred, state} = Definitions.start(state, from, request, operation)
    assert state.page_load.callers[from].monitor == caller_monitor
    assert PageLoad.request_id(state, from) == request
    assert {:monitors, monitors} = Process.info(self(), :monitors)
    assert Enum.count(monitors, &(&1 == {:process, caller})) == 1

    [{token, row}] = Map.to_list(state.prefab_requests)
    worker = row.pid
    on_exit(fn -> Process.exit(worker, :kill) end)
    root_id = fixture.root_id

    assert_receive {:"$gen_call", {^worker, _} = inputs_from,
      {:prefab_inputs, ^token, {:closure, [^root_id]}}}, 1_000
    assert {{:ok, descriptors, cached} = reply, state} =
      Definitions.inputs(state, token, worker, {:closure, [root_id]})
    assert map_size(descriptors) == 2
    assert Map.keys(cached) == [fixture.child_id]
    assert state.prefab_source_bytes == fixture.source_bytes
    assert state.prefab_source_bytes > 0
    assert Cache.stats(state.cache).pins == 1
    GenServer.reply(inputs_from, reply)

    assert_receive {:"$gen_call", {^worker, _},
      {:prefab_loaded, ^token, ^root_id, root}}, 1_000
    assert root == fixture.root
    assert {:ok, state} = Definitions.loaded(state, token, worker, root_id, root)

    # 只暂留这个真实调用的回复；worker 仍在产品代码的 GenServer.call 内等待。
    assert Process.alive?(worker)
    assert state.prefab_source_bytes == fixture.source_bytes
    assert state.prefab_requests[token].source_bytes == fixture.source_bytes
    assert Cache.stats(state.cache).pins == 2
    assert Cache.stats(state.cache).owners == 1
    assert Cache.stats(state.cache).pinned_entries == 2
    assert map_size(state.page_load.callers) == 1

    %{state: state, token: token, worker: worker, worker_monitor: row.monitor,
      caller_monitor: caller_monitor, from: from, request: request}
  end

  defp assert_retired(state, pending) do
    assert state.prefab_requests == %{}
    assert state.prefab_source_bytes == 0
    assert state.page_load.callers == %{}
    assert Cache.stats(state.cache).pins == 0
    assert Cache.stats(state.cache).owners == 0
    assert Cache.stats(state.cache).pinned_entries == 0
    # 退休请求释放 pin，但不把合法可丢缓存误当成请求资源删除。
    assert Cache.stats(state.cache).namespaces.prefab.entries == 2
    assert {:monitors, monitors} = Process.info(self(), :monitors)
    refute {:process, elem(pending.from, 0)} in monitors
    refute {:process, pending.worker} in monitors
  end

  defp assert_stale_token(state, pending, fixture) do
    # 故障注入仅向已退休的控制边界送迟到消息，不建立或修改世界 truth。
    assert Definitions.finish(state, pending.token, {:ok, :late_completion}) == state
    assert {{:error, :definition_request_expired}, ^state} =
      Definitions.loaded(state, pending.token, pending.worker, fixture.root_id, fixture.root)
    assert {{:error, :definition_request_expired}, ^state} =
      Definitions.inputs(state, pending.token, pending.worker, {:closure, [fixture.root_id]})
    assert Definitions.down(state, pending.worker_monitor, :normal) == :unknown
    assert {nil, [], ^state} = PageLoad.cancel(state, pending.request)
  end
end
