defmodule VoxelRegion.CollisionStream do
  @moduledoc "角色连接的有序 canonical 来源；跨 Scene 移交只切换接收者，不重建订阅。"
  use GenServer
  require Logger
  alias VoxelRegion.World

  @doc "建立随 Gate 存活的 canonical 来源，异步准备首次窗口。"
  def start(authority, gate, owner, box),
    do: GenServer.start(__MODULE__, {authority, gate, owner, box})
  @doc "上次窗口已安装后，请求新的完整 XYZ 窗口。"
  def window(stream, box), do: GenServer.cast(stream, {:window, box})
  @doc "接收者接纳事件后释放已交付的消息缓冲。"
  def acknowledge(stream, cursor), do: GenServer.cast(stream, {:ack, cursor})
  @doc "切换角色 owner，由同一来源按序重放切点后的事件。"
  def attach(stream, owner, cursor), do: GenServer.call(stream, {:attach, owner, cursor})

  @doc "按 canonical 米坐标计算完整三维 L0 tile 窗口。"
  def box(position, radius) do
    extent = MmoContracts.Voxel.Payload.extent() - 2
    center = position |> Tuple.to_list() |> Enum.map(&floor(&1 / extent))
    {List.to_tuple(Enum.map(center, &(&1 - radius))),
     List.to_tuple(Enum.map(center, &(&1 + radius + 1)))}
  end

  @impl true
  def init({authority, gate, owner, box}) do
    gate_monitor = Process.monitor(gate)
    lifetime = [gate_monitor, Process.monitor(authority)]
    state = %{authority: authority, owner: owner, cursor: 0, pending: :queue.new(),
      box: box, worker: nil, lifetime: lifetime, gate_monitor: gate_monitor}
    {:ok, request(state, box)}
  end

  @impl true
  def handle_call({:attach, owner, cursor}, _, state) do
    pending = :queue.to_list(state.pending) |> Enum.filter(fn {id, _} -> id > cursor end)
    for {id, event} <- pending, do: send(owner, {:collision_stream, self(), id, event})
    {:reply, :ok, %{state | owner: owner}}
  end

  @impl true
  def handle_cast({:ack, cursor}, state) do
    pending = state.pending |> :queue.to_list() |> Enum.drop_while(fn {id, _} -> id <= cursor end) |> :queue.from_list()
    {:noreply, %{state | pending: pending}}
  end
  def handle_cast({:window, box}, state), do: {:noreply, request(state, box)}

  @impl true
  def handle_info({:canonical_snapshot, ref, snapshot}, %{worker: {ref, _}} = state) do
    started = System.monotonic_time(:microsecond)
    Logger.info("voxel_window_stage stage=stream_receive request=#{inspect(ref)} pid=#{inspect(self())} owner=#{inspect(state.owner)} cursor=#{state.cursor+1} at_us=#{System.system_time(:microsecond)}")
    state = emit(%{state | worker: nil}, {:window, snapshot})
    Logger.info("voxel_window_stage stage=stream_sent request=#{inspect(ref)} pid=#{inspect(self())} cursor=#{state.cursor} at_us=#{System.system_time(:microsecond)} elapsed_us=#{System.monotonic_time(:microsecond)-started}")
    {:noreply, state}
  end
  def handle_info({:canonical_delta, delta}, state), do: {:noreply, emit(state, delta)}
  def handle_info({:source_result, :ok}, state), do: {:noreply, state}
  def handle_info({:source_result, error}, state), do: {:stop, {:canonical_source, error}, state}
  def handle_info({:DOWN, monitor, :process, _, _}, %{gate_monitor: monitor} = state), do: {:stop, :normal, state}
  def handle_info({:DOWN, monitor, :process, _, reason}, state) do
    if monitor in state.lifetime or reason != :normal,
      do: {:stop, {:canonical_source, reason}, state}, else: {:noreply, state}
  end

  defp request(state, box) do
    nil = state.worker
    ref = make_ref()
    Logger.info("voxel_window_stage stage=stream_request request=#{inspect(ref)} pid=#{inspect(self())} owner=#{inspect(state.owner)} box=#{inspect(box)} at_us=#{System.system_time(:microsecond)}")
    receiver = self()
    authority = state.authority
    {_, monitor} = Node.spawn_monitor(node(authority), fn ->
      result = World.canonical_snapshot_and_subscribe(authority, box, receiver, ref)
      send(receiver, {:source_result, result})
    end)
    %{state | box: box, worker: {ref, monitor}}
  end

  defp emit(state, event) do
    id = state.cursor + 1
    send(state.owner, {:collision_stream, self(), id, event})
    %{state | cursor: id, pending: :queue.in({id, event}, state.pending)}
  end
end
