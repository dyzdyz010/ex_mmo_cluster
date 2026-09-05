defmodule GateServer.TcpConnection do
  @moduledoc """
  Per-client GenServer for one accepted TCP socket.

  The acceptor hands this process an already-accepted socket, and the process
  takes over ownership of that socket for the rest of the connection. It keeps
  a small state machine in process state:

      waiting_auth -> authenticated -> in_scene

  Incoming frames are decoded with `GateServer.Codec.decode/1` and handed to the
  shared session state machine `GateServer.Session.Dispatch`; outbound frames go
  through `GateServer.Session.Sink`, which owns the socket write.

  ## Message flow

      :gen_tcp active message
           ↓
      GateServer.Codec.decode/1
           ↓
      GateServer.Session.Dispatch.handle/2   ← 与 WebSocket 链路共用
           ↓
      auth / scene RPCs
           ↓
      GateServer.Session.Sink（编码 + :gen_tcp.send/2）

  本模块只保留 TCP 特有的部分：socket 接管、`{:tcp, ...}` / `{:tcp_closed, ...}` 语义、
  UDP 快车道（peer 解析、ticket 生命周期）以及 Scene 回推帧的转发。会话语义（鉴权、
  进场、移动、聊天、技能、体素意图）一律不在这里实现。

  ## State notes

  - `status: :waiting_auth` only accepts `{:auth_request, ...}`
  - `status: :authenticated` can answer time sync and enter-scene requests
  - `status: :in_scene` also relays movement updates to the scene process
  - `cid` stays at `-1` until the client successfully enters a scene
  - `fast_lane: :enabled` —— 原生客户端支持 UDP 快车道（浏览器 WS 侧为 `:unsupported`）
  """

  use GenServer, restart: :temporary
  require Logger

  @topic {:gate, __MODULE__}
  @scope :connection

  alias GateServer.Session.{Dispatch, Observe, Scene, Sink}
  alias GateServer.Voxel.{ResultFrame, SubscribeIntent, SubscriptionWorker}
  alias SceneServer.Combat.EffectEvent

  @doc """
  Start the per-socket connection process.

  `socket` is the accepted `:gen_tcp` socket. `opts` are forwarded to
  `GenServer.start_link/3`, which lets the supervisor attach a name or other
  process options when the connection is spawned.
  """
  def start_link(socket, opts \\ []) do
    GenServer.start_link(__MODULE__, socket, opts)
  end

  @impl true
  def init(socket) do
    ensure_pg_scope_started()
    :pg.join(@scope, @topic, self())
    Logger.debug("New client connected. socket: #{inspect(socket, pretty: true)}")

    GateServer.CliObserve.emit("tcp_connection_init", %{
      connection_pid: self(),
      socket: socket
    })

    {:ok, voxel_worker} = SubscriptionWorker.start_link(self())

    {:ok,
     %{
       socket: socket,
       # 出站唯一出口：共享会话层只认 sink，不认 socket。
       sink: Sink.tcp(socket),
       fast_lane: :enabled,
       cid: -1,
       agent: nil,
       auth_claims: nil,
       auth_username: nil,
       auth_session_id: nil,
       scene_ref: nil,
       udp_peer: nil,
       udp_ticket: nil,
       token: nil,
       status: :waiting_auth,
       # 阶段4 step4.3 非阻塞:per-connection 订阅 worker。它是体素订阅集的**唯一所有者**、也是
       # Scene 订阅/退订的**唯一发起者**(单进程串行 → 无退订/重订乱序竞态)。连接只 cast 订阅/退订
       # 意图后立即返回,route+subscribe 慢 I/O 在 worker 进程跑,编辑/移动帧永不被订阅风暴阻塞。
       # 连接不再持订阅 map;introspection/debug 走 worker 同步 call。
       voxel_worker: voxel_worker
     }}
  end

  defp ensure_pg_scope_started do
    case :pg.start_link(@scope) do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  @impl true
  def handle_cast({:player_enter, cid, location}, state) do
    GateServer.CliObserve.emit("tcp_player_enter_push", %{cid: cid, location: location})
    Sink.send_encoded(state.sink, {:player_enter, cid, location})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:actor_identity, cid, actor_kind, actor_name}, state) do
    GateServer.CliObserve.emit("actor_identity_push", %{
      cid: cid,
      actor_kind: actor_kind,
      actor_name: actor_name
    })

    Sink.send_encoded(state.sink, {:actor_identity, cid, actor_kind, actor_name})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_leave, cid}, state) do
    GateServer.CliObserve.emit("tcp_player_leave_push", %{cid: cid})
    Sink.send_encoded(state.sink, {:player_leave, cid})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_move, snapshot}, state) do
    snapshot = Scene.normalize_remote_snapshot(snapshot)
    {udp_peer, state} = resolve_udp_peer(state)

    if udp_peer do
      GateServer.CliObserve.emit("player_move_push_udp", fn ->
        %{
          cid: snapshot.cid,
          server_tick: snapshot.server_tick,
          location: snapshot.position,
          peer: udp_peer,
          priority_band: snapshot.priority_band,
          priority_score: snapshot.priority_score,
          observer_distance: snapshot.observer_distance,
          delivery_interval: snapshot.delivery_interval
        }
      end)

      GateServer.UdpAcceptor.send_to_peer(udp_peer, Scene.player_move_message(snapshot))
    else
      GateServer.CliObserve.emit("player_move_push_tcp", fn ->
        %{
          cid: snapshot.cid,
          server_tick: snapshot.server_tick,
          location: snapshot.position,
          priority_band: snapshot.priority_band,
          priority_score: snapshot.priority_score,
          observer_distance: snapshot.observer_distance,
          delivery_interval: snapshot.delivery_interval
        }
      end)

      Sink.send_encoded(state.sink, Scene.player_move_message(snapshot))
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:movement_ack, ack}, state) do
    {udp_peer, state} = resolve_udp_peer(state)

    GateServer.CliObserve.emit("movement_ack_push", fn ->
      %{
        connection_pid: self(),
        ack_seq: ack.ack_seq,
        auth_tick: ack.auth_tick,
        transport: if(udp_peer, do: :udp, else: :tcp)
      }
    end)

    message =
      {:movement_ack, ack.ack_seq, ack.auth_tick, ack.cid, ack.position, ack.velocity,
       ack.acceleration, ack.movement_mode, ack.correction_flags, ack.fixed_dt_ms, ack.ground_z}

    if udp_peer do
      GateServer.UdpAcceptor.send_to_peer(udp_peer, message)
    else
      Sink.send_encoded(state.sink, message)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:chat_message, cid, username, text}, state) do
    GateServer.CliObserve.emit("chat_push", %{cid: cid, username: username, text: text})
    Sink.send_encoded(state.sink, {:chat_message, cid, username, text})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:skill_event, cid, skill_id, location}, state) do
    GateServer.CliObserve.emit("skill_push", %{cid: cid, skill_id: skill_id, location: location})

    Sink.send_encoded(state.sink, {:skill_event, cid, skill_id, location})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:effect_event, %EffectEvent{} = effect_event}, state) do
    GateServer.CliObserve.emit("effect_event_push", %{
      source_cid: effect_event.source_cid,
      skill_id: effect_event.skill_id,
      cue_kind: effect_event.cue_kind,
      target_cid: effect_event.target_cid
    })

    Sink.send_encoded(
      state.sink,
      {:effect_event, effect_event.source_cid, effect_event.skill_id, effect_event.cue_kind,
       effect_event.origin, effect_event.target_cid, effect_event.target_position,
       effect_event.radius, effect_event.duration_ms}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_state, cid, hp, max_hp, alive}, state) do
    GateServer.CliObserve.emit("player_state_push", %{
      cid: cid,
      hp: hp,
      max_hp: max_hp,
      alive: alive
    })

    Sink.send_encoded(state.sink, {:player_state, cid, hp, max_hp, alive})
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location},
        state
      ) do
    GateServer.CliObserve.emit("combat_hit_push", %{
      source_cid: source_cid,
      target_cid: target_cid,
      skill_id: skill_id,
      damage: damage,
      hp_after: hp_after,
      location: location
    })

    Sink.send_encoded(
      state.sink,
      {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:udp_attached, peer, ticket}, state) do
    GateServer.CliObserve.emit("udp_attached", %{
      connection_pid: self(),
      peer: peer,
      ticket_present?: is_binary(ticket) and ticket != ""
    })

    {:noreply, %{state | udp_peer: peer, udp_ticket: ticket}}
  end

  @impl true
  def handle_cast({:udp_detached, peer, _reason}, %{udp_peer: peer} = state) do
    GateServer.CliObserve.emit("udp_detached", %{
      connection_pid: self(),
      peer: peer
    })

    {:noreply, %{state | udp_peer: nil, udp_ticket: nil}}
  end

  @impl true
  def handle_cast({:udp_detached, _peer, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:voxel_chunk_snapshot_payload, payload}, state)
      when is_binary(payload) do
    GateServer.CliObserve.emit(
      "voxel_chunk_snapshot_forwarded",
      Map.merge(
        %{
          connection_pid: self(),
          cid: state.cid,
          bytes: byte_size(payload)
        },
        Observe.chunk_snapshot_fields(payload)
      )
    )

    Sink.send_encoded(state.sink, {:voxel_chunk_snapshot_payload, payload})
    {:noreply, state}
  end

  def handle_info({:voxel_chunk_delta_payload, payload}, state)
      when is_binary(payload) do
    GateServer.CliObserve.emit(
      "voxel_chunk_delta_forwarded",
      Map.merge(
        %{
          connection_pid: self(),
          cid: state.cid,
          bytes: byte_size(payload)
        },
        Observe.chunk_delta_fields(payload)
      )
    )

    Sink.send_encoded(state.sink, {:voxel_chunk_delta_payload, payload})
    {:noreply, state}
  end

  def handle_info({:voxel_chunk_invalidate_payload, payload}, state)
      when is_binary(payload) do
    GateServer.CliObserve.emit("voxel_chunk_invalidate_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload)
    })

    Sink.send_encoded(state.sink, {:voxel_chunk_invalidate_payload, payload})
    SubscribeIntent.invalidate(state.voxel_worker, payload)
    {:noreply, state}
  end

  # 阶段4 step4.3:订阅 worker 路由/订阅失败回报(首失败一帧 0x68)。成功路径无回报——快照即 ACK,
  # 由 worker 订阅触发经 fan-out 直达本连接 socket;订阅集只存在于 worker(单一所有者)。
  def handle_info({:voxel_subscribe_failed, ctx, reason}, state) do
    GateServer.CliObserve.emit("voxel_chunk_subscribe_error", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: ctx.request_id,
      chunk_coord: Map.get(ctx, :chunk_coord),
      reason: reason
    })

    Sink.send_encoded(state.sink, ResultFrame.error(ctx, reason))
    {:noreply, state}
  end

  # Phase 4-bis (D7):forward 0x6C ObjectStateDelta from ChunkProcess fan-out
  # to the TCP socket. ObjectRegistry encoded the binary once;ChunkProcess
  # cast it into our mailbox via `send/2`;we just prefix the opcode and
  # write to the socket.
  # Voxim R6：VoxelRegion.World 推来的日志条目（0x77），原样下发。
  def handle_info({:voxel_log_transaction_payload, payload}, state) when is_binary(payload) do
    Sink.send_encoded(state.sink, {:voxel_log_transaction_payload, payload})
    {:noreply, state}
  end

  def handle_info({:voxel_log_entry_payload, payload}, state) when is_binary(payload) do
    Sink.send_encoded(state.sink, {:voxel_log_entry_payload, payload})
    {:noreply, state}
  end

  def handle_info({:voxel_object_state_delta_payload, payload}, state)
      when is_binary(payload) do
    GateServer.CliObserve.emit("tcp_voxel_object_state_delta_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload)
    })

    Sink.send_encoded(state.sink, {:voxel_object_state_delta_payload, payload})
    {:noreply, state}
  end

  # Phase 6: forward 0x73 FieldRegionSnapshot from ChunkProcess fan-out
  # to the TCP socket. FieldTickWorker encoded the binary (already including
  # the opcode byte) and ChunkProcess cast it into our mailbox via send/2.
  # The `{packet, 4}` setting on the socket adds the 4-byte length prefix.
  def handle_info({:voxel_field_region_snapshot_payload, payload}, state)
      when is_binary(payload) do
    GateServer.CliObserve.emit("tcp_voxel_field_region_snapshot_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload)
    })

    Sink.send_raw(state.sink, payload)
    {:noreply, state}
  end

  # Phase 6: forward 0x74 FieldRegionDestroyed from ChunkProcess fan-out.
  def handle_info({:voxel_field_region_destroyed_payload, payload}, state)
      when is_binary(payload) do
    GateServer.CliObserve.emit("tcp_voxel_field_region_destroyed_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload)
    })

    Sink.send_raw(state.sink, payload)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    GateServer.CliObserve.emit("tcp_receive", fn ->
      %{connection_pid: self(), bytes: byte_size(data), status: state.status}
    end)

    case GateServer.Codec.decode(data) do
      {:ok, msg} ->
        GateServer.CliObserve.emit("tcp_decoded", fn ->
          %{connection_pid: self(), message: Observe.message_summary(msg)}
        end)

        {:ok, new_state} = Dispatch.handle(msg, state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.debug("TCP codec decode rejected payload: #{inspect(reason)}")
        Dispatch.result_error(state, reason, 0)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tcp_closed, _conn}, state) do
    # Audit (e2e smoke 2026-04-26): client-initiated TCP close is the
    # normal session-end flow (logout / browser tab closed / SIGINT on
    # the bevy headless). Logging it at :error inflated alert volume in
    # the smoke run; an :info line is enough — surrounding scene/fast-lane
    # cleanup metrics still fire through CliObserve.
    Logger.info("Socket #{inspect(state.socket, pretty: true)} closed by peer.")
    GateServer.CliObserve.emit("tcp_closed", %{connection_pid: self(), cid: state.cid})

    # 阶段4:voxel 订阅集在 worker(随本连接退出而停;Scene 侧 subscriber=本连接 pid,
    # ChunkProcess monitor 本连接 down 即自动摘除)——无需在此显式退订。
    Scene.cleanup(state.scene_ref)
    cleanup_fast_lane(self())
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp_error, _conn, err}, state) do
    Logger.info(
      "Socket #{inspect(state.socket, pretty: true)} closed with transport error: #{err}"
    )

    GateServer.CliObserve.emit("tcp_error", %{connection_pid: self(), cid: state.cid, reason: err})

    Scene.cleanup(state.scene_ref)
    cleanup_fast_lane(self())
    {:stop, :normal, state}
  end

  @impl true
  def handle_call(
        {:udp_movement, frame_params},
        _from,
        %{status: :in_scene, scene_ref: spid, cid: active_cid} = state
      ) do
    frame = Scene.build_input_frame(frame_params)

    GateServer.CliObserve.emit("udp_movement_received", fn ->
      %{
        connection_pid: self(),
        cid: frame.seq,
        active_cid: active_cid,
        frame: frame
      }
    end)

    reply =
      cond do
        active_cid == -1 ->
          {:error, :cid_mismatch}

        true ->
          Scene.accept_movement_input(spid, frame)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(
        {:udp_movement, _frame_params},
        _from,
        state
      ) do
    {:reply, {:error, :invalid_state}, state}
  end

  defp cleanup_fast_lane(connection_pid) do
    if Process.whereis(GateServer.FastLaneRegistry) do
      _ = GateServer.FastLaneRegistry.detach_connection(connection_pid, :tcp_closed)
    end

    :ok
  end

  defp resolve_udp_peer(%{udp_peer: nil} = state), do: {nil, state}

  defp resolve_udp_peer(%{udp_peer: udp_peer} = state) do
    active_peer =
      if Process.whereis(GateServer.FastLaneRegistry) do
        case GateServer.FastLaneRegistry.session_for_connection(self()) do
          %{peer: ^udp_peer} -> udp_peer
          _ -> nil
        end
      else
        nil
      end

    case active_peer do
      nil -> {nil, %{state | udp_peer: nil, udp_ticket: nil}}
      peer -> {peer, state}
    end
  end
end
