defmodule VoxelRegion.CollisionStream do
  @moduledoc "角色连接的有序 canonical 来源；跨 Scene 移交只切换接收者，不重建订阅。"
  use GenServer
  require Logger
  alias VoxelRegion.World

  @doc "建立随 Gate 存活的 canonical 来源，异步准备首次窗口。"
  def start(authority, gate, owner, box),
    do: GenServer.start(__MODULE__, {authority, gate, owner, box})
  @doc "当前 Player 请求新窗口，同时携带其当前／未来／请求中的完整窗口集合。"
  def window(stream, box, windows), do: GenServer.cast(stream, {:window, self(), box, windows})
  @doc "Player 实际消费窗口后发布剩余集合；消息接收 ACK 不承担此语义。"
  def set_simulation_windows(stream, windows), do: GenServer.cast(stream, {:simulation_windows, self(), windows})
  @doc "移交 cut 导出前排空同一 Player 已发送的请求；只等流接纳，不等待 World 或快照。"
  def synchronize(stream), do: GenServer.call(stream, :synchronize, 300_000)
  @doc "接收者接纳事件后释放已交付的消息缓冲。"
  def acknowledge(stream, cursor), do: GenServer.cast(stream, {:ack, cursor})
  @doc "切换角色 owner，由同一来源按序重放切点后的事件。"
  def attach(stream, owner, cursor, windows), do: GenServer.call(stream, {:attach, owner, cursor, windows})

  @doc "按 canonical 米坐标计算完整三维 L0 tile 窗口。"
  def box(position, radius) do
    extent = MmoContracts.Voxel.Payload.extent() - 2
    center = position |> Tuple.to_list() |> Enum.map(&floor(&1 / extent))
    {List.to_tuple(Enum.map(center, &(&1 - radius))),
     List.to_tuple(Enum.map(center, &(&1 + radius + 1)))}
  end

  @doc "沿用当前中心 tile 外扩四分之一 tile 的滞回带，避免边界往返触发全量快照。"
  def box(position, radius, {min, _max} = current) do
    extent = MmoContracts.Voxel.Payload.extent() - 2

    inside = Enum.all?(0..2, fn axis ->
      center_min = (elem(min, axis) + radius) * extent
      value = elem(position, axis)
      value >= center_min - extent / 4 and value < center_min + extent * 5 / 4
    end)

    if inside, do: current, else: box(position, radius)
  end

  @impl true
  def init({authority, gate, owner, box}) do
    gate_monitor = Process.monitor(gate)
    lifetime = [gate_monitor, Process.monitor(authority)]
    state = %{authority: authority, owner: owner, cursor: 0, pending: :queue.new(),
      box: box, worker: nil, lifetime: lifetime, gate_monitor: gate_monitor, simulation_windows: []}
    {:ok, request(state, box, [box])}
  end

  @impl true
  def handle_call(:synchronize, _, state), do: {:reply, :ok, state}
  def handle_call({:attach, owner, cursor, windows}, _, state) do
    pending = :queue.to_list(state.pending) |> Enum.filter(fn {id, _} -> id > cursor end)
    for {id, event} <- pending, do: send(owner, {:collision_stream, self(), id, event})
    {:reply, :ok, publish_windows(%{state | owner: owner}, windows)}
  end

  @impl true
  def handle_cast({:ack, cursor}, state) do
    pending = state.pending |> :queue.to_list() |> Enum.drop_while(fn {id, _} -> id <= cursor end) |> :queue.from_list()
    {:noreply, %{state | pending: pending}}
  end
  def handle_cast({:window, owner, box, windows}, %{owner: owner} = state), do: {:noreply, request(state, box, windows)}
  def handle_cast({:simulation_windows, owner, windows}, %{owner: owner} = state), do: {:noreply, publish_windows(state, windows)}
  def handle_cast(message, state) when elem(message, 0) in [:window, :simulation_windows] do
    Logger.warning("voxel_simulation_windows stream=#{inspect(self())} reason=stale_owner sender=#{inspect(elem(message,1))} owner=#{inspect(state.owner)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:simulation_windows_result, ref, :ok}, %{worker: {ref, :simulation}} = state),
    do: {:noreply, begin_snapshot(state, ref)}
  def handle_info({:simulation_windows_result, _ref, :ok}, state), do: {:noreply, state}
  def handle_info({:simulation_windows_result, _ref, error}, state), do: {:stop, {:simulation_windows, error}, state}
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
  def handle_info({:canonical_source_error, error}, state), do: {:stop, {:canonical_source, error}, state}
  def handle_info({:DOWN, monitor, :process, _, _}, %{gate_monitor: monitor} = state), do: {:stop, :normal, state}
  def handle_info({:DOWN, monitor, :process, _, reason}, state) do
    if monitor in state.lifetime or reason != :normal,
      do: {:stop, {:canonical_source, reason}, state}, else: {:noreply, state}
  end

  defp request(state, box, windows) do
    nil = state.worker
    ref = make_ref()
    Logger.info("voxel_window_stage stage=stream_request request=#{inspect(ref)} pid=#{inspect(self())} owner=#{inspect(state.owner)} box=#{inspect(box)} at_us=#{System.system_time(:microsecond)}")
    # 登记回执到达才启动读取，但本进程不阻塞等待 World：seal 的接纳屏障仍可及时完成。
    World.request_simulation_windows(state.authority, windows, ref)
    %{state | box: box, worker: {ref, :simulation}, simulation_windows: windows}
  end

  defp publish_windows(%{simulation_windows: windows} = state, windows), do: state
  defp publish_windows(state, windows) do
    World.request_simulation_windows(state.authority, windows, make_ref())
    %{state | simulation_windows: windows}
  end

  defp begin_snapshot(state, ref) do
    receiver = self()
    authority = state.authority
    box = state.box
    {_, monitor} = Node.spawn_monitor(node(authority), fn ->
      result = World.canonical_snapshot_and_subscribe(authority, box, receiver, ref)
      send(receiver, {:source_result, result})
    end)
    %{state | worker: {ref, monitor}}
  end

  defp emit(state, event) do
    id = state.cursor + 1
    send(state.owner, {:collision_stream, self(), id, event})
    %{state | cursor: id, pending: :queue.in({id, event}, state.pending)}
  end
end
