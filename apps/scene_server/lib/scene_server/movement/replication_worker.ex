defmodule SceneServer.Movement.ReplicationWorker do
  @moduledoc "独占一组观察者的 AOI 关系和输出；只消费 Replication 有序发布的不可变帧与生命周期。"
  use GenServer
  alias SceneServer.Movement.AOI

  @doc "随复制分发者启动，关系不跨分发者生命周期保存。"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @doc "接管一个观察者的唯一输出路由。"
  def join(pid, identity, gate), do: GenServer.cast(pid, {:join, identity, gate})
  @doc "消费一次公共 20 Hz 机会；每个目标保持自己的实际模拟 tick。"
  def publish(pid, frame, tick), do: GenServer.cast(pid, {:publish, frame, tick})
  @doc "清理离场目标和本组观察者，可靠 Leave 不被快照替换。"
  def leave(pid, identity, id, epoch, tick),
    do: GenServer.cast(pid, {:leave, identity, id, epoch, tick})

  @doc "仅显式诊断读取本组完整关系。"
  def observe(pid), do: GenServer.call(pid, :observe)

  @impl true
  def init(opts), do: {:ok, %{sink: Keyword.fetch!(opts, :sink), gates: %{}, aoi: AOI.new()}}
  @impl true
  def handle_call(:observe, _, state), do: {:reply, AOI.observe(state.aoi), state}

  @impl true
  def handle_cast({:join, identity, gate}, state),
    do: {:noreply, %{state | gates: Map.put(state.gates, identity, gate)}}

  def handle_cast({:publish, frame, tick}, state) do
    {aoi, lifecycle, snapshots} = AOI.update_frame(state.aoi, frame, tick, state.gates)
    emit(state, lifecycle)

    for message <- snapshots,
        do:
          state.sink.datagram(
            Map.fetch!(state.gates, message.identity),
            message.identity,
            message
          )

    {:noreply, %{state | aoi: aoi}}
  end

  def handle_cast({:leave, identity, id, epoch, tick}, state) do
    {aoi, lifecycle} = AOI.remove(state.aoi, identity, id, epoch, tick)
    state = %{state | aoi: aoi, gates: Map.delete(state.gates, identity)}
    emit(state, lifecycle)
    {:noreply, state}
  end

  defp emit(state, lifecycle) do
    for event <- lifecycle,
        do:
          state.sink.reliable(
            Map.fetch!(state.gates, event.identity),
            event.identity,
            :control,
            event
          )
  end
end
