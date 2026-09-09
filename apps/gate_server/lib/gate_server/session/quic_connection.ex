defmodule GateServer.Session.QuicConnection do
  @moduledoc "单个已接管的 QUIC 连接；唯一处理分帧、鉴权、身份路由与异步传输，不推进 Scene 时间。"
  use GenServer, restart: :temporary
  alias MmoContracts.{Session, Movement}
  alias GateServer.Session.Auth

  @doc "在 listener 转交连接 owner 之前创建邮箱。"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {:ok, %{conn: Keyword.fetch!(opts, :conn), listener: Keyword.fetch!(opts, :listener),
      hello: Keyword.fetch!(opts, :hello), hello_seen: false, identity: nil, route: nil, player: nil,
      bounds: Keyword.get(opts, :bounds), voxim_overlay: false,
      scene: Keyword.get(opts, :scene_module, SceneServer.Movement.Scene),
      auth: Keyword.get(opts, :auth_module, Auth),
      router: Keyword.get(opts, :route_module, WorldServer.Movement),
      streams: %{}, purposes: %{}, max_datagram: 0, closing: false,
      stale_identity: 0, bytes_in: 0, bytes_out: 0,
      reliable: %{1 => :queue.new(), 2 => :queue.new()}, busy: MapSet.new(),
      queue_age_us: 0, reliable_completed: 0,
      pending_datagrams: :gb_trees.empty(), snapshot_keys: %{}, snapshot_order: 0, datagram_busy: false,
      datagrams_replaced: 0, datagrams_sent: 0, snapshot_records_sent: 0,
      snapshot_datagrams_sent: 0, snapshot_bytes_sent: 0}}
  end

  @impl true
  def format_status(status) do
    # OTP 异常报告不得打印携带 Join token 的原始收包或分帧缓冲。
    status |> Map.put(:message, :redacted) |> Map.put(:state, Map.take(status.state, [:identity, :closing]))
  end

  @impl true
  def handle_cast(:activate, state) do
    {:ok, _} = :quicer.async_accept_stream(state.conn, %{active: true})
    :ok = :quicer.async_handshake(state.conn)
    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = Map.take(state, [:identity, :max_datagram, :stale_identity, :bytes_in, :bytes_out,
      :closing, :queue_age_us, :reliable_completed, :datagrams_replaced, :datagrams_sent,
      :snapshot_records_sent, :snapshot_datagrams_sent, :snapshot_bytes_sent])
    stats = Map.put(stats, :reliable_queued, Enum.sum(Enum.map(state.reliable, fn {_, q} -> :queue.len(q) end)))
    {:reply, Map.put(stats, :quic, :quicer.getopt(state.conn, :statistics)), state}
  end

  @impl true
  def handle_info({:quic, :new_stream, stream, %{flags: flags}}, state) do
    if flags == 0 and map_size(state.streams) < 2 do
      :ok = :quicer.setopt(stream, :active, true)
      {:ok, _} = :quicer.async_accept_stream(state.conn, %{active: true})
      {:noreply, put_in(state.streams[stream], %{purpose: nil, buffer: <<>>, started: false})}
    else
      {:noreply, close(state, 8)}
    end
  end

  def handle_info({:quic, :dgram_state_changed, conn, props}, %{conn: conn} = state) do
    if props.dgram_send_enabled do
      {:noreply, %{state | max_datagram: props.dgram_max_len}}
    else
      {:noreply, close(state, 8)}
    end
  end

  def handle_info({:quic, bytes, conn, _flags}, %{conn: conn} = state) when is_binary(bytes) do
    state = %{state | bytes_in: state.bytes_in + byte_size(bytes)}
    cond do
      state.closing -> {:noreply, state}
      state.identity == nil -> {:noreply, close(state, 13)}
      true ->
        case Movement.Codec.decode(bytes) do
          {:ok, %Movement.InputBatch{identity: identity} = message} ->
            if identity == state.identity do
              SceneServer.Movement.Player.input(state.player, identity, message)
              {:noreply, state}
            else
              {:noreply, %{state | stale_identity: state.stale_identity + 1}}
            end
          _ -> {:noreply, close(state, 8)}
        end
    end
  end

  def handle_info({:quic, bytes, stream, _props}, state) when is_binary(bytes) do
    if state.closing do
      {:noreply, state}
    else
      entry = Map.fetch!(state.streams, stream)
      state = put_in(state.streams[stream].buffer, entry.buffer <> bytes)
      state = %{state | bytes_in: state.bytes_in + byte_size(bytes)}
      {:noreply, consume(state, stream)}
    end
  end

  def handle_info({:mmo_close, identity, reason}, %{identity: identity} = state),
    do: {:noreply, close(state, reason)}

  def handle_info({:mmo_reliable, identity, purpose, message}, %{identity: identity, closing: false} = state)
      when identity != nil do
    {:noreply, send_message(state, purpose, message)}
  end

  def handle_info({:mmo_voxel_bytes, identity, bytes}, %{identity: identity, closing: false} = state),
    do: {:noreply, send_bytes(state, 2, bytes, 0)}
  def handle_info({:mmo_voxel_bytes, _, _}, state), do: {:noreply, state}

  def handle_info({:quic, :send_shutdown_complete, stream, true}, %{closing: true} = state) do
    if state.purposes[1] == stream, do: :quicer.async_shutdown_connection(state.conn, 0, 0)
    {:noreply, state}
  end

  def handle_info({:quic, :send_complete, stream, false}, state) do
    purpose = state.streams[stream].purpose
    state = %{state | busy: MapSet.delete(state.busy, purpose), reliable_completed: state.reliable_completed + 1}
    {:noreply, flush_reliable(state, purpose)}
  end

  def handle_info({:mmo_datagram, identity, message}, %{identity: identity, closing: false} = state)
      when identity != nil do
    state = queue_datagram(state, message, System.monotonic_time(:microsecond))
    send(self(), :flush_datagrams)
    {:noreply, state}
  end

  def handle_info(:flush_datagrams, %{datagram_busy: false, closing: false} = state) do
    case :gb_trees.next(:gb_trees.iterator(state.pending_datagrams)) do
      :none -> {:noreply, state}
      {key, {message, queued_at}, iterator} ->
        bytes = datagram_bytes(message)
        if byte_size(bytes) <= state.max_datagram do
          state = delete_datagram(state, key)
          {state, bytes, queued_at, records} =
            pack_datagram(state, message, bytes, queued_at, iterator)
          {:ok, count} = :quicer.async_send_dgram(state.conn, bytes)
          {:noreply, %{state | datagram_busy: true,
            datagrams_sent: state.datagrams_sent + 1, bytes_out: state.bytes_out + count,
            snapshot_records_sent: state.snapshot_records_sent + records,
            snapshot_datagrams_sent: state.snapshot_datagrams_sent + if(records > 0, do: 1, else: 0),
            snapshot_bytes_sent: state.snapshot_bytes_sent + if(records > 0, do: count, else: 0),
            queue_age_us: max(state.queue_age_us, System.monotonic_time(:microsecond) - queued_at)}}
        else
          {:noreply, close(state, 8)}
        end
    end
  end
  def handle_info(:flush_datagrams, state), do: {:noreply, state}

  def handle_info({:quic, :dgram_send_state, conn, %{state: phase}}, %{conn: conn} = state)
      when phase == :dgram_send_sent do
    send(self(), :flush_datagrams)
    {:noreply, %{state | datagram_busy: false}}
  end

  # Terminal loss/cancel notifications can belong to an earlier, already-sent
  # datagram. They must never release a newer send's slot (quicer has no send ID).
  def handle_info({:quic, :dgram_send_state, conn, %{state: :dgram_send_canceled}}, %{conn: conn} = state),
    do: {:noreply, close(state, 3)}

  def handle_info({:quic, :closed, conn, _}, %{conn: conn} = state), do: {:stop, :normal, state}
  def handle_info({:quic, event, conn, _}, %{conn: conn} = state)
      when event in [:shutdown, :transport_shutdown], do: {:noreply, %{state | closing: true}}
  def handle_info({:quic, :peer_send_shutdown, _stream, _}, %{closing: false} = state),
    do: {:noreply, close(state, 3)}
  def handle_info({:quic, event, _stream, _}, state)
      when event in [:peer_send_aborted, :peer_receive_aborted], do: {:noreply, close(state, 3)}
  def handle_info({:quic, _, _, _}, state), do: {:noreply, state}
  def handle_info({:mmo_reliable, _, _, _}, state), do: {:noreply, state}
  def handle_info({:mmo_close, _, _}, state), do: {:noreply, state}
  def handle_info({:mmo_datagram, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.identity, do: state.scene.leave(state.route.scene_ref, state.identity)
    :quicer.async_shutdown_connection(state.conn, 0, 0)
  end

  defp queue_datagram(state, %Movement.OwnerAck{} = message, queued_at) do
    replaced = if :gb_trees.is_defined(:owner, state.pending_datagrams), do: 1, else: 0
    %{state | pending_datagrams: :gb_trees.enter(:owner, {message, queued_at}, state.pending_datagrams),
      datagrams_replaced: state.datagrams_replaced + replaced}
  end

  defp queue_datagram(state, %Movement.Snapshot{records: records} = message, queued_at) do
    Enum.reduce(records, state, fn record, acc ->
      # Replacing a payload must retain its waiting turn. Sorting by the new tick
      # and ID lets the low IDs jump ahead again on every 20 Hz producer update.
      {key, at, order, replaced} = case Map.fetch(acc.snapshot_keys, record.entity_id) do
        {:ok, key} ->
          {_, at} = :gb_trees.get(key, acc.pending_datagrams)
          {key, at, acc.snapshot_order, 1}
        :error -> {{acc.snapshot_order, record.entity_id}, queued_at, acc.snapshot_order + 1, 0}
      end
      value = {%{message | records: [record]}, at}
      %{acc | pending_datagrams: :gb_trees.enter(key, value, acc.pending_datagrams),
        snapshot_keys: Map.put(acc.snapshot_keys, record.entity_id, key), snapshot_order: order,
        datagrams_replaced: acc.datagrams_replaced + replaced}
    end)
  end

  defp delete_datagram(state, :owner) do
    %{state | pending_datagrams: :gb_trees.delete(:owner, state.pending_datagrams)}
  end

  defp delete_datagram(state, {_, entity_id} = key) do
    %{state | pending_datagrams: :gb_trees.delete(key, state.pending_datagrams),
      snapshot_keys: Map.delete(state.snapshot_keys, entity_id)}
  end

  defp pack_datagram(state, %Movement.OwnerAck{}, bytes, queued_at, _iterator),
    do: {state, bytes, queued_at, 0}

  defp pack_datagram(state, %Movement.Snapshot{} = message, bytes, queued_at, iterator) do
    case :gb_trees.next(iterator) do
      {key, {%Movement.Snapshot{identity: identity, server_tick: tick, records: [record]}, at}, next}
          when identity == message.identity and tick == message.server_tick ->
        # Service order is FIFO; codec order applies only inside the bounded packet.
        candidate = %{message | records: Enum.sort_by([record | message.records], & &1.entity_id)}
        encoded = datagram_bytes(candidate)
        # 上限按 codec 完整 envelope 字节计算；放不下的记录仍留在原队列，不改时间或代际。
        if byte_size(encoded) <= state.max_datagram do
          pack_datagram(delete_datagram(state, key), candidate, encoded, min(queued_at, at), next)
        else
          {state, bytes, queued_at, length(message.records)}
        end
      _ -> {state, bytes, queued_at, length(message.records)}
    end
  end

  defp datagram_bytes(message) do
    {:ok, bytes} = Movement.Codec.encode(message)
    IO.iodata_to_binary(bytes)
  end

  defp consume(%{closing: true} = state, _stream), do: state
  defp consume(state, stream) do
    case state.streams[stream] do
      %{purpose: nil, buffer: <<purpose, tail::binary>>} ->
        if purpose in [1, 2] and not Map.has_key?(state.purposes, purpose) and
             (purpose == 1 or state.identity != nil) do
          state = put_in(state.streams[stream].purpose, purpose)
          state = put_in(state.streams[stream].buffer, tail)
          state = put_in(state.purposes[purpose], stream)
          consume(flush_reliable(state, purpose), stream)
        else
          close(state, 8)
        end
      %{purpose: purpose, buffer: <<length::32, payload::binary-size(length), tail::binary>>}
          when purpose != nil ->
        state = put_in(state.streams[stream].buffer, tail)
        consume(frame(state, purpose, payload), stream)
      _ -> state
    end
  end

  defp frame(%{identity: identity} = state, 1, <<255, 1::16, 2, _::binary>> = bytes) when identity != nil do
    case Movement.Codec.decode(bytes) do
      {:ok, %Movement.InputBatch{identity: ^identity} = message} ->
        SceneServer.Movement.Player.input(state.player, identity, message)
        state
      _ -> close(state, 8)
    end
  end
  defp frame(state, 1, bytes) do
    case Session.Codec.decode(bytes) do
      {:ok, message} -> control(state, message)
      _ -> close(state, 8)
    end
  end
  defp frame(%{identity: identity} = state, 2, bytes) when identity != nil do
    case MmoContracts.Voxel.Codec.decode(bytes) do
      {:ok, {:voxel_overlay_subscribe, _sub}} ->
        # Scene owns the single ordered world subscription, including reconnect
        # bootstrap. This admission never creates an independent Gate log sender.
        %{state | voxim_overlay: true}
      {:ok,{kind,request}=message} when kind in [:voxel_prefab_place_v1,:voxel_prefab_remove_v1] and state.voxim_overlay ->
        if request.logical_scene_id == identity.scene_id do
          coords = case kind do
            :voxel_prefab_place_v1 ->
              case VoxelRegion.World.prefab_cells(state.route.world_ref,request.definition_id,request.anchor,request.orientation) do
                {:ok,cells} -> {:ok,Enum.map(cells,fn {micro,_} -> elem(VoxelRegion.Prefab.macro_slot(micro),0) end)}
                error -> error
              end
            :voxel_prefab_remove_v1 -> VoxelRegion.World.instance_cells(state.route.world_ref,request.instance_id)
          end
          ctx = %{status: :in_scene,voxim_overlay: true,world_ref: state.route.world_ref,
            sink: GateServer.Session.Sink.quic(self(),identity)}
          case coords do
            {:ok,cells} ->
              if Enum.all?(cells,&within?(&1,state.bounds)) do
                {:ok,_} = GateServer.Session.Dispatch.handle(message,ctx)
                state
              else
                close(state,4)
              end
            {:error,_} ->
              {:ok,_} = GateServer.Session.Dispatch.handle(message,ctx)
              state
          end
        else
          close(state,4)
        end
      {:ok, {kind, request} = message}
          when kind in [:voxel_edit_intent, :voxel_batch_edit_intent] and state.voxim_overlay ->
        coords = GateServer.Session.Dispatch.voxim_edit_coords(message)
        if request.logical_scene_id == identity.scene_id and Enum.all?(coords, &within?(&1, state.bounds)) do
          ctx = %{status: :in_scene, voxim_overlay: true, world_ref: state.route.world_ref,
            sink: GateServer.Session.Sink.quic(self(), identity)}
          {:ok, _} = GateServer.Session.Dispatch.handle(message, ctx)
          state
        else
          close(state, 4)
        end
      _ -> close(state, 8)
    end
  end
  defp frame(state, _purpose, _bytes), do: close(state, 8)

  defp within?({x, y, z}, {{a, b, c}, {d, e, f}}),
    do: x >= a and y >= b and z >= c and x < d and y < e and z < f

  defp control(%{hello_seen: false} = state, %Session.Hello{} = hello) do
    if hello == state.hello do
      send_message(%{state | hello_seen: true}, 1, hello)
    else
      close(state, 9)
    end
  end

  defp control(%{hello_seen: true, identity: nil} = state, %Session.Join{} = join) do
    with {:ok, claims} <- state.auth.verify_token(join.token),
         :ok <- state.auth.validate_username(claims, join.username),
         :ok <- state.auth.authorize_cid(claims, join.cid),
         {:ok, character} <- state.auth.fetch_authorized_character(claims, join.cid) do
      case state.router.route(join.scene_id) do
        {:ok, route} ->
          {identity, result} = GenServer.call(state.listener, {:claim, state.scene, Map.put(route, :scene_id, join.scene_id), character})
          state = %{state | identity: identity, route: route}
          case result do
            {:ok, player} -> %{state | player: player}
            {:error, :closed} -> state
          end
        _ -> close(state, 11)
      end
    else
      _ -> close(state, 13)
    end
  end

  defp control(%{identity: identity} = state, %Session.Ready{identity: identity} = ready)
      when identity != nil do
    SceneServer.Movement.Player.ready(state.player, identity, ready.baseline_transaction_seq, ready.collision_revision)
    state
  end

  defp control(%{identity: identity} = state, %Session.TimeProbe{} = probe) when identity != nil do
    SceneServer.Movement.Player.time_probe(state.player, identity, probe)
    state
  end

  defp control(%{identity: identity} = state, %Session.SessionEnd{identity: identity, reason: 1})
      when identity != nil, do: close(state, 1)
  defp control(state, _), do: close(state, 8)

  defp send_message(state, purpose, message) do
    {:ok, bytes} = case {purpose, message} do
      {1, _} -> Session.Codec.encode(message)
      {2, %{__struct__: _}} -> MmoContracts.Voxel.Codec.encode_m1(message)
      {2, _} -> MmoContracts.Voxel.Codec.encode(message)
    end
    send_bytes(state, purpose, IO.iodata_to_binary(bytes), 0)
  end

  defp send_bytes(state, purpose, bytes, flags) do
    queue = :queue.in({bytes, flags, System.monotonic_time(:microsecond)}, state.reliable[purpose])
    flush_reliable(put_in(state.reliable[purpose], queue), purpose)
  end

  defp flush_reliable(state, purpose) do
    if Map.has_key?(state.purposes, purpose) and not MapSet.member?(state.busy, purpose) do
      case :queue.out(state.reliable[purpose]) do
        {:empty, _} -> state
        {{:value, {bytes, flags, queued_at}}, queue} ->
          state = put_in(state.reliable[purpose], queue)
          submit_reliable(state, purpose, bytes, flags, queued_at)
      end
    else
      state
    end
  end

  defp submit_reliable(state, purpose, bytes, flags, queued_at) do
    stream = Map.fetch!(state.purposes, purpose)
    prefix = if state.streams[stream].started, do: <<>>, else: <<purpose>>
    # 0x1000 只请求完成事件；调用仍是 async_send，不等待接收者释放流控额度。
    case :quicer.async_send(stream, [prefix, <<byte_size(bytes)::32>>, bytes], Bitwise.bor(flags, 0x1000)) do
      {:ok, count} ->
        state = put_in(state.streams[stream].started, true)
        %{state | bytes_out: state.bytes_out + count, busy: MapSet.put(state.busy, purpose),
          queue_age_us: max(state.queue_age_us, System.monotonic_time(:microsecond) - queued_at)}
      {:error, :closed} ->
        # Observed when the peer closes after receiving a malformed test frame
        # while a prior SEND_COMPLETE is already queued in this mailbox.
        %{state | closing: true}
    end
  end

  defp close(%{closing: true} = state, _reason), do: state
  defp close(%{identity: nil} = state, reason) do
    :ok = :quicer.async_shutdown_connection(state.conn, 0, Session.Codec.pre_auth_close(reason))
    %{state | closing: true}
  end
  defp close(state, reason) do
    {:ok, bytes} = Session.Codec.encode(%Session.SessionEnd{identity: state.identity, reason: reason})
    state = send_bytes(state, 1, IO.iodata_to_binary(bytes), 4)
    %{state | closing: true}
  end
end
