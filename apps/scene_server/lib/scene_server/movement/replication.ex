defmodule SceneServer.Movement.Replication do
  @moduledoc "复制帧分发者；独立消费不可变 Player 结果，观察者关系由固定 worker 组分别独占。"
  use GenServer
  alias SceneServer.Movement.{AOI, ReplicationWorker}
  @worker_count 4

  @doc "随 Scene 启动，Scene 退出时丢弃全部派生关系。"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @doc "Scene 发布成员生命周期，旧 epoch 的迟到结果不能重新入场。"
  def join(pid, identity, id, epoch, player, gate),
    do: GenServer.cast(pid, {:join, identity, id, epoch, player, gate})

  @doc "消费当前 Player 发布的只读事实。"
  def result(pid, value), do: GenServer.cast(pid, {:result, value})
  @doc "公共20Hz复制机会；不要求所有玩家到达相同 tick。"
  def publish(pid, tick), do: GenServer.cast(pid, {:publish, tick})
  @doc "立即清理成员及关系。"
  def leave(pid, identity, id, epoch, tick),
    do: GenServer.cast(pid, {:leave, identity, id, epoch, tick})

  @doc "显式诊断才读取完整关系；常态指标不调用此入口。"
  def observe(pid) do
    pid |> workers() |> Enum.flat_map(&ReplicationWorker.observe/1) |> Enum.sort_by(& &1.identity)
  end

  @doc "轻量公开 worker 引用；不读取 AOI 关系或等待 worker。"
  def workers(pid), do: GenServer.call(pid, :workers)
  @doc "采集分发者和各 worker 的即时 mailbox 长度，不向 worker 发同步调用。"
  def metrics(pid) do
    project = fn ref ->
      ref
      |> Process.info([:message_queue_len, :memory, :reductions])
      |> Map.new()
      |> Map.put(:pid, ref)
    end

    %{dispatcher: project.(pid), workers: Enum.map(workers(pid), project)}
  end

  @impl true
  def init(opts) do
    workers =
      for _ <- 1..@worker_count do
        {:ok, pid} = ReplicationWorker.start_link(sink: Keyword.fetch!(opts, :sink))
        pid
      end

    {:ok, %{members: %{}, workers: List.to_tuple(workers)}}
  end

  @impl true
  def handle_call(:workers, _, state), do: {:reply, Tuple.to_list(state.workers), state}

  @impl true
  def terminate(_, state) do
    for pid <- Tuple.to_list(state.workers), Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end

  @impl true
  def handle_cast({:join, identity, id, epoch, player, gate}, state) do
    member = %{entity_id: id, entity_epoch: epoch, player: player, gate: gate, value: nil}

    ReplicationWorker.join(
      elem(state.workers, rem(epoch, tuple_size(state.workers))),
      identity,
      gate
    )

    {:noreply, %{state | members: Map.put(state.members, identity, member)}}
  end

  def handle_cast({:result, value}, state) do
    case state.members[value.identity] do
      %{player: pid} = member when pid == value.player_pid ->
        if member.value == nil or value.simulation_tick >= member.value.simulation_tick do
          {:noreply,
           %{state | members: Map.put(state.members, value.identity, %{member | value: value})}}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:publish, tick}, state) do
    entities = for {_, %{value: value}} <- state.members, value != nil and value.active, do: value
    frame = AOI.frame(entities)
    for worker <- Tuple.to_list(state.workers), do: ReplicationWorker.publish(worker, frame, tick)
    {:noreply, state}
  end

  def handle_cast({:leave, identity, id, epoch, tick}, state) do
    for worker <- Tuple.to_list(state.workers),
        do: ReplicationWorker.leave(worker, identity, id, epoch, tick)

    {:noreply, %{state | members: Map.delete(state.members, identity)}}
  end
end
