defmodule SceneServer.Voxel.Field.SimRuntime do
  @moduledoc """
  节点级局部场仿真调度器(梯队2 step2.6,NIF-1/5,消除 ANTI-15)。

  取代每个 `FieldTickWorker` 各自 `Process.send_after` 自调度的旧模型:本进程是节点级单例,持
  **单一 tick clock** + **统一 CPU 预算**(`max_concurrency`),驱动所有订阅的 FieldTickWorker。

  - **统一 clock**:`Process.send_after(self(), :sim_tick, interval_ms)`(默认 100ms),消除 per-region
    调度抖动,所有场 tick 同拍。
  - **CPU 预算**:每 `:sim_tick` 用 `Task.async_stream(.., max_concurrency: 预算)` bounded 同步驱动
    所有 worker 的 `:run_tick`,使**并发场 NIF 工作 ≤ 预算**(默认 `System.schedulers_online()`)。
    一批工作若长于 interval,下一拍自然顺延 = 背压(不堆积)。
  - **订阅生命周期**:worker `subscribe/2`(call)登记并被 `Process.monitor`;worker 停机(到 max_ticks /
    chunk DOWN)由 monitor 的 `:DOWN` 自动摘除,无需显式 unsubscribe。

  worker 的 tick **编排逻辑仍在 FieldTickWorker**(读 storage → 跑 kernel → 编 snapshot → 投 chunk →
  分发 effect);SimRuntime 只负责**何时驱动 + 并发预算**。
  """

  use GenServer

  alias SceneServer.CliObserve

  @default_tick_interval_ms 100
  @run_tick_timeout_ms 5_000

  @type opts :: [
          name: GenServer.name(),
          tick_interval_ms: pos_integer(),
          max_concurrency: pos_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "订阅:登记一个 FieldTickWorker,使其每拍被驱动。call,SimRuntime 缺失即显式 crash。"
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server \\ __MODULE__, worker_pid) when is_pid(worker_pid) do
    GenServer.call(server, {:subscribe, worker_pid})
  end

  @doc "退订(显式;通常由 worker 停机的 monitor DOWN 自动完成)。"
  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(server \\ __MODULE__, worker_pid) when is_pid(worker_pid) do
    GenServer.call(server, {:unsubscribe, worker_pid})
  end

  @doc "CLI / 调试用快照。"
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :tick_interval_ms, @default_tick_interval_ms)
    max_concurrency = Keyword.get(opts, :max_concurrency) || default_budget()

    schedule(interval_ms)

    {:ok,
     %{
       interval_ms: interval_ms,
       max_concurrency: max_concurrency,
       # %{worker_pid => monitor_ref}
       workers: %{},
       tick_count: 0
     }}
  end

  defp default_budget, do: max(1, System.schedulers_online())

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    if Map.has_key?(state.workers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)

      # 新订阅 worker 立即异步 prompt-drive 一次,保留旧"首 tick 即时"语义(订阅 call 已返回,
      # 不在 init 链路内,无死锁)。后续由统一 clock 驱动。
      send(self(), {:prompt_tick, pid})
      {:reply, :ok, put_in(state.workers[pid], ref)}
    end
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, remove_worker(state, pid)}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       worker_count: map_size(state.workers),
       tick_count: state.tick_count,
       interval_ms: state.interval_ms,
       max_concurrency: state.max_concurrency
     }, state}
  end

  @impl true
  def handle_info(:sim_tick, state) do
    started_us = System.monotonic_time(:microsecond)
    worker_pids = Map.keys(state.workers)
    drive(worker_pids, state.max_concurrency)
    schedule(state.interval_ms)

    next_state = %{state | tick_count: state.tick_count + 1}

    if rem(next_state.tick_count, 50) == 0 do
      duration_us = System.monotonic_time(:microsecond) - started_us

      CliObserve.emit("voxel_sim_runtime_tick", fn ->
        %{
          tick_count: next_state.tick_count,
          worker_count: length(worker_pids),
          max_concurrency: state.max_concurrency,
          batch_duration_us: duration_us
        }
      end)
    end

    {:noreply, next_state}
  end

  def handle_info({:prompt_tick, pid}, state) do
    if Map.has_key?(state.workers, pid), do: drive([pid], state.max_concurrency)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.workers, pid) do
      ^ref -> {:noreply, %{state | workers: Map.delete(state.workers, pid)}}
      _ -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp drive([], _budget), do: :ok

  defp drive(worker_pids, budget) do
    worker_pids
    |> Task.async_stream(&run_tick_safe/1,
      max_concurrency: budget,
      timeout: @run_tick_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.run()
  end

  # worker 可能已停机(到 max_ticks 自停);call 退出由本函数兜住,DOWN 异步摘除订阅。
  defp run_tick_safe(pid) do
    GenServer.call(pid, :run_tick, @run_tick_timeout_ms)
  catch
    :exit, _reason -> :ok
  end

  defp remove_worker(state, pid) do
    case Map.pop(state.workers, pid) do
      {ref, workers} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        %{state | workers: workers}

      {_nil, _workers} ->
        state
    end
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :sim_tick, interval_ms)
end
