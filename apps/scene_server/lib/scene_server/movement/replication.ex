defmodule SceneServer.Movement.Replication do
  @moduledoc "复制帧分发者；独立消费不可变 Player 结果，观察者关系由固定 worker 组分别独占。"
  use GenServer
  alias SceneServer.Movement.{AOI, ReplicationWorker, Clock}
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
  @doc "在最近公共 tick 立即补发已收到的结果，供目标激活后的首帧使用。"
  def flush(pid), do: GenServer.cast(pid, :flush)
  @doc "立即清理成员及关系。"
  def leave(pid, identity, id, epoch, tick),
    do: GenServer.cast(pid, {:leave, identity, id, epoch, tick})

  @doc "从所属 worker 取出并删除观察者关系，不发送 Leave；须先于 handoff。"
  def take_observer(pid, identity), do: GenServer.call(pid, {:take_observer, identity})
  @doc "为已 join 的新成员恢复观察者缓存，保留实体关系 generation。"
  def put_observer(pid, identity, gate, observer),
    do: GenServer.call(pid, {:put_observer, identity, gate, observer})
  @doc "删除源成员，保留本地产生的旧身份切点只读显示，直到目标邻区确认新身份首帧。"
  def handoff(pid, old, fresh, target_scene_id),
    do: GenServer.call(pid, {:handoff, old, fresh, target_scene_id})

  @doc "显式诊断才读取完整关系；常态指标不调用此入口。"
  def observe(pid) do
    pid |> workers() |> Enum.flat_map(&ReplicationWorker.observe/1) |> Enum.sort_by(& &1.identity)
  end

  @doc "轻量公开 worker 引用；不读取 AOI 关系或等待 worker。"
  def workers(pid), do: GenServer.call(pid, :workers)

  @doc "由显式 Scene 路由接纳邻区端点；时间偏移为邻区 tick 零点减本区零点。"
  def neighbour(pid, peer, origin_offset_us, scene_id \\ nil),
    do: GenServer.call(pid, {:neighbour, peer, origin_offset_us, scene_id})

  @doc "Scene 停止公共时间线时显式结束邻区通道，清理不能依赖下一次 publish。"
  def close_neighbours(pid), do: GenServer.cast(pid, :close_neighbours)
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

    {:ok, %{members: %{}, workers: List.to_tuple(workers), neighbours: %{}, bridges: %{}, tick: 0}}
  end

  @impl true
  def handle_call(:workers, _, state), do: {:reply, Tuple.to_list(state.workers), state}

  def handle_call({:neighbour, peer, offset, scene_id}, _, state) do
    neighbours = Map.put_new_lazy(state.neighbours, peer, fn ->
      %{monitor: Process.monitor(peer), offset: offset, tick: -1, entities: [], scene_id: scene_id}
    end)
    {:reply, :ok, %{state | neighbours: neighbours}}
  end

  def handle_call({:take_observer, identity}, _, state) do
    worker = observer_worker(state, identity)
    {:reply, ReplicationWorker.take_observer(worker, identity), state}
  end

  def handle_call({:put_observer, identity, gate, observer}, _, state) do
    ReplicationWorker.put_observer(observer_worker(state, identity), identity, gate, observer)
    {:reply, :ok, state}
  end

  def handle_call({:handoff, old, fresh, target_scene_id}, _, state) do
    {member, members} = Map.pop!(state.members, old)
    bridge = %{value: member.value, target_scene_id: target_scene_id}
    {:reply, :ok, %{state | members: members, bridges: Map.put(state.bridges, fresh, bridge)}}
  end

  @impl true
  def handle_info({:neighbour_frame, peer, tick, entities}, state) do
    case state.neighbours[peer] do
      # 同一端点信号有序；同 tick 的目标激活补帧必须能替换此前空帧。
      %{tick: previous} = neighbour when tick >= previous ->
        values = Enum.flat_map(entities, fn value ->
          mapped = Clock.translate_tick(value.simulation_tick, neighbour.offset)
          if mapped >= 0, do: [%{value | simulation_tick: mapped}], else: []
        end)
        next = %{neighbour | tick: tick, entities: values}
        bridges = Enum.reduce(values, state.bridges, fn value, bridges ->
          case bridges[value.identity] do
            %{target_scene_id: scene_id} when scene_id == neighbour.scene_id ->
              Map.delete(bridges, value.identity)
            _ -> bridges
          end
        end)
        {:noreply, %{state | neighbours: Map.put(state.neighbours, peer, next), bridges: bridges}}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, peer, _reason}, state) do
    case state.neighbours[peer] do
      %{monitor: ^ref} = neighbour ->
        {:noreply, drop_neighbour(state, peer, neighbour.scene_id)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:neighbour_closed, peer}, state) do
    case state.neighbours[peer] do
      nil -> {:noreply, state}
      neighbour ->
        Process.demonitor(neighbour.monitor, [:flush])
        {:noreply, drop_neighbour(state, peer, neighbour.scene_id)}
    end
  end

  @impl true
  def terminate(_, state) do
    for pid <- Tuple.to_list(state.workers), Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end

  @impl true
  def handle_cast(:close_neighbours, state) do
    for {peer, neighbour} <- state.neighbours do
      send(peer, {:neighbour_closed, self()})
      Process.demonitor(neighbour.monitor, [:flush])
    end
    {:noreply, %{state | neighbours: %{}, bridges: %{}}}
  end

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
    {:noreply, publish_frame(%{state | tick: tick})}
  end

  def handle_cast(:flush, state), do: {:noreply, publish_frame(state)}

  def handle_cast({:leave, identity, id, epoch, tick}, state) do
    for worker <- Tuple.to_list(state.workers),
        do: ReplicationWorker.leave(worker, identity, id, epoch, tick)

    {:noreply, %{state | members: Map.delete(state.members, identity)}}
  end

  defp publish_frame(state) do
    tick = state.tick
    entities = for {_, %{value: value}} <- state.members, value != nil and value.active, do: value
    bridges = Enum.map(state.bridges, fn {_, bridge} -> bridge.value end)
    # 本地产生的切点桥继续导出到目标确认首帧，填补 detach/activate 间隙；邻区事实不再转发。
    if map_size(state.neighbours) > 0 do
      exported = Enum.map(entities ++ bridges, &Map.take(&1,
        [:identity, :entity_id, :entity_epoch, :state, :simulation_tick, :collision_revision]))
      for {peer, _} <- state.neighbours, do: send(peer, {:neighbour_frame, self(), tick, exported})
    end
    remote = Enum.flat_map(state.neighbours, fn {_, neighbour} -> neighbour.entities end)
    frame = AOI.frame(entities ++ remote ++ bridges)
    for worker <- Tuple.to_list(state.workers), do: ReplicationWorker.publish(worker, frame, tick)
    state
  end

  defp observer_worker(state, identity) do
    member = Map.fetch!(state.members, identity)
    elem(state.workers, rem(member.entity_epoch, tuple_size(state.workers)))
  end

  defp drop_neighbour(state, peer, scene_id) do
    bridges = Map.reject(state.bridges, fn {_, bridge} -> bridge.target_scene_id == scene_id end)
    %{state | neighbours: Map.delete(state.neighbours, peer), bridges: bridges}
  end
end
