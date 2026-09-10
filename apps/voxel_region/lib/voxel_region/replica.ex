defmodule VoxelRegion.Replica do
  @moduledoc """
  Scene 节点的只读区域物化视图。所有 payload、chunk 和事务都来自唯一 World；
  本地只替换不可变结果并提供快照/订阅，不生成、规约、持久化或接纳编辑。
  上游结束时退出，已订阅的 Scene 通过既有 monitor 停止使用失效视图。
  """
  use GenServer, restart: :temporary
  require Logger
  alias MmoContracts.Voxel.{CanonicalSnapshot, Codec}
  alias VoxelRegion.{CollisionSource, World}

  @doc "从唯一上游完整加载显式 L0 区域，完成后才返回。"
  def start_link(opts),
    do:
      GenServer.start_link(__MODULE__, opts,
        name: Keyword.get(opts, :name, __MODULE__),
        timeout: 300_000
      )

  @doc "唯一 canonical World 的 PID，与区域进程身份分开。"
  def authority_ref(server), do: GenServer.call(server, :authority_ref)
  @doc "上游内容版本。"
  def content_version(server), do: GenServer.call(server, :content_version)
  @doc "本地已消费的事务前缀。"
  def seq(server), do: GenServer.call(server, :seq)
  @doc "本地驻留规模、前缀及累计增量 payload 字节。"
  def stats(server), do: GenServer.call(server, :stats)

  @doc "返回初始快照以来 N 之后的有序不可变 delta；更旧前缀显式拒绝。"
  def canonical_deltas_after(server, seq),
    do: GenServer.call(server, {:canonical_deltas_after, seq})

  @doc "原子发送本地快照标记并订阅其后的事务；签名与 World 一致。"
  def canonical_snapshot_and_subscribe(server, box, pid, request, include_chunks \\ true),
    do: GenServer.call(server, {:canonical_snapshot, box, pid, request, include_chunks}, 300_000)

  @impl true
  def init(opts) do
    authority = World.authority_ref(Keyword.fetch!(opts, :authority_ref))
    monitor = Process.monitor(authority)
    box = Keyword.fetch!(opts, :l0_box)
    # GeneratedStore 的 ETS 与生成任务留在 authority 节点；只传不可变 artifact。
    case :rpc.call(
           node(authority),
           World,
           :replica_snapshot_and_subscribe,
           [authority, box, self()],
           300_000
         ) do
      {:ok, snapshot} ->
        state = %{
          authority: authority,
          monitor: monitor,
          box: box,
          cv: snapshot.content_version,
          seq: snapshot.transaction_seq,
          baseline_seq: snapshot.transaction_seq,
          regions: Map.new(snapshot.regions),
          chunks: Map.new(snapshot.chunks, &{&1.coord, &1}),
          subscribers: %{},
          deltas: [],
          update_payload_bytes: 0
        }

        Logger.info(
          "voxel_region replica_ready authority=#{inspect(authority)} seq=#{state.seq} regions=#{map_size(state.regions)} chunks=#{map_size(state.chunks)}"
        )

        {:ok, state}

      error ->
        {:stop, {:replica_snapshot_failed, error}}
    end
  end

  @impl true
  def handle_call(:authority_ref, _from, state), do: {:reply, state.authority, state}
  def handle_call(:content_version, _from, state), do: {:reply, state.cv, state}
  def handle_call(:seq, _from, state), do: {:reply, state.seq, state}

  def handle_call(:stats, _from, state) do
    stats = %{
      authority_ref: state.authority,
      transaction_seq: state.seq,
      baseline_seq: state.baseline_seq,
      regions: map_size(state.regions),
      chunks: map_size(state.chunks),
      retained_deltas: length(state.deltas),
      payload_bytes: Enum.sum(Enum.map(state.regions, &byte_size(elem(&1, 1)))),
      occupancy_bytes: Enum.sum(Enum.map(state.chunks, &byte_size(elem(&1, 1).cells))),
      update_payload_bytes: state.update_payload_bytes
    }

    {:reply, stats, state}
  end

  def handle_call({:canonical_deltas_after, seq}, _from, state) do
    reply =
      if seq < state.baseline_seq,
        do: {:error, :before_replica_snapshot},
        else: state.deltas |> Enum.take_while(&(&1.transaction_seq > seq)) |> Enum.reverse()

    {:reply, reply, state}
  end

  def handle_call(
        {:canonical_snapshot, {min, max} = box, pid, request, include_chunks},
        _from,
        state
      ) do
    coords = CollisionSource.regions(box)

    if Enum.all?(coords, &Map.has_key?(state.regions, &1)) do
      regions =
        Enum.map(coords, &{&1, Codec.stamp_payload_seq(Map.fetch!(state.regions, &1), state.seq)})

      chunks =
        if include_chunks,
          do:
            state.chunks
            |> Map.values()
            |> Enum.filter(&CollisionSource.in_box?(&1.coord, box))
            |> Enum.sort_by(& &1.coord),
          else: []

      snapshot = %CanonicalSnapshot{
        content_version: state.cv,
        transaction_seq: state.seq,
        l0_min: min,
        l0_max_exclusive: max,
        regions: regions,
        chunks: chunks
      }

      unless Map.has_key?(state.subscribers, pid), do: Process.monitor(pid)
      send(pid, {:canonical_snapshot, request, snapshot})
      {:reply, :ok, %{state | subscribers: Map.put_new(state.subscribers, pid, box)}}
    else
      {:reply, {:error, :outside_replica_region}, state}
    end
  end

  def handle_call({:apply_edits, _}, _from, state),
    do: {:reply, {:error, :read_only_replica}, state}

  @impl true
  def handle_info({:canonical_replica_delta, delta, regions}, state) do
    state = %{
      state
      | seq: delta.transaction_seq,
        regions: Map.merge(state.regions, Map.new(regions)),
        chunks: Map.merge(state.chunks, Map.new(delta.chunks, &{&1.coord, &1})),
        deltas: [delta | state.deltas],
        update_payload_bytes:
          state.update_payload_bytes + Enum.sum(Enum.map(regions, &byte_size(elem(&1, 1))))
    }

    Enum.each(state.subscribers, fn {pid, box} ->
      send(
        pid,
        {:canonical_delta,
         %{delta | chunks: Enum.filter(delta.chunks, &CollisionSource.in_box?(&1.coord, box))}}
      )
    end)

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{monitor: monitor} = state),
    do: {:stop, {:authority_down, reason}, state}

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
end
