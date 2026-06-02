defmodule GateServer.TcpConnection do
  @moduledoc """
  Per-client GenServer for one accepted TCP socket.

  The acceptor hands this process an already-accepted socket, and the process
  takes over ownership of that socket for the rest of the connection. It keeps
  a small state machine in process state:

      waiting_auth -> authenticated -> in_scene

  Incoming frames are decoded with `GateServer.Codec.decode/1`, dispatched by
  phase, and then encoded back to the same socket with `GateServer.Codec.encode/1`.

  ## Message flow

      :gen_tcp active message
           ↓
      GateServer.Codec.decode/1
           ↓
      dispatch/2
           ↓
      auth / scene RPCs
           ↓
      GateServer.Codec.encode/1
           ↓
      :gen_tcp.send/2

  ## State notes

  - `status: :waiting_auth` only accepts `{:auth_request, ...}`
  - `status: :authenticated` can answer time sync and enter-scene requests
  - `status: :in_scene` also relays movement updates to the scene process
  - `cid` stays at `-1` until the client successfully enters a scene
  """

  use GenServer, restart: :temporary
  require Logger

  @topic {:gate, __MODULE__}
  @scope :connection

  alias GateServer.{ChatAdapter, ChatScope}
  alias GateServer.{PartitionRefresh, PartitionRuntime}

  alias GateServer.Voxel.{
    ChunkVersionLedger,
    ClientAckLedger,
    DeliveryEnvelope,
    DeliveryScheduler,
    PrefabLocalTransaction,
    SubscriptionPlanner,
    SubscriptionRebind,
    SubscriptionRuntime
  }

  alias SceneServer.Combat.CastRequest
  alias SceneServer.Combat.{EffectEvent, Skill}
  alias SceneServer.Movement.{InputFrame, RemoteSnapshot}
  alias SceneServer.Voxel.{NormalBlockData, PrefabRaster, Types}

  @scene_call_timeout 15_000
  @max_voxel_subscribe_radius 4
  @prefab_owner_part_id 1
  @max_prefab_owner_object_id 0x7FFF_FFFF_FFFF_FFFF

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

    {:ok,
     %{
       socket: socket,
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
       chat_session_joined?: false,
       chat_context: nil,
       partition_context: nil,
       last_partition_refresh: nil,
       voxel_subscriptions: %{},
       forwarded_chunk_versions: ChunkVersionLedger.new(),
       client_ack_versions: ClientAckLedger.new(),
       voxel_subscription_plan: nil,
       voxel_delivery: DeliveryScheduler.new(),
       voxel_delivery_timer_ref: nil,
       partition_refresh_generation: 0,
       partition_refresh_pending: nil
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
  def handle_cast({:player_enter, cid, location}, %{socket: socket} = state) do
    GateServer.CliObserve.emit("tcp_player_enter_push", %{cid: cid, location: location})
    send_encoded(socket, {:player_enter, cid, location})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:actor_identity, cid, actor_kind, actor_name}, %{socket: socket} = state) do
    GateServer.CliObserve.emit("actor_identity_push", %{
      cid: cid,
      actor_kind: actor_kind,
      actor_name: actor_name
    })

    send_encoded(socket, {:actor_identity, cid, actor_kind, actor_name})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_leave, cid}, %{socket: socket} = state) do
    GateServer.CliObserve.emit("tcp_player_leave_push", %{cid: cid})
    send_encoded(socket, {:player_leave, cid})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_move, snapshot}, %{socket: socket} = state) do
    snapshot = normalize_remote_snapshot(snapshot)
    {udp_peer, state} = resolve_udp_peer(state)
    server_send_ms = :os.system_time(:millisecond)

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

      GateServer.UdpAcceptor.send_to_peer(udp_peer, player_move_message(snapshot, server_send_ms))
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

      send_encoded(socket, player_move_message(snapshot, server_send_ms))
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:movement_ack, ack}, %{socket: socket} = state) do
    {udp_peer, state} = resolve_udp_peer(state)

    GateServer.CliObserve.emit("movement_ack_push", fn ->
      %{
        connection_pid: self(),
        ack_seq: ack.ack_seq,
        auth_tick: ack.auth_tick,
        transport: if(udp_peer, do: :udp, else: :tcp)
      }
    end)

    server_send_ms = :os.system_time(:millisecond)
    server_state_ms = movement_state_ms(ack)

    message =
      {:movement_ack, ack.ack_seq, ack.auth_tick, server_state_ms, server_send_ms, ack.cid,
       ack.position, ack.velocity, ack.acceleration, ack.movement_mode, ack.correction_flags,
       ack.fixed_dt_ms, ack.ground_z}

    if udp_peer do
      GateServer.UdpAcceptor.send_to_peer(udp_peer, message)
    else
      send_encoded(socket, message)
    end

    {:noreply, schedule_partition_refresh_after_movement_ack(state, ack)}
  end

  @impl true
  def handle_cast({:chat_message, cid, username, text}, %{socket: socket} = state) do
    GateServer.CliObserve.emit("chat_push", %{cid: cid, username: username, text: text})
    send_encoded(socket, {:chat_message, cid, username, text})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:skill_event, cid, skill_id, location}, %{socket: socket} = state) do
    GateServer.CliObserve.emit("skill_push", %{cid: cid, skill_id: skill_id, location: location})

    send_encoded(socket, {:skill_event, cid, skill_id, location})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:effect_event, %EffectEvent{} = effect_event}, %{socket: socket} = state) do
    GateServer.CliObserve.emit("effect_event_push", %{
      source_cid: effect_event.source_cid,
      skill_id: effect_event.skill_id,
      cue_kind: effect_event.cue_kind,
      target_cid: effect_event.target_cid
    })

    send_encoded(
      socket,
      {:effect_event, effect_event.source_cid, effect_event.skill_id, effect_event.cue_kind,
       effect_event.origin, effect_event.target_cid, effect_event.target_position,
       effect_event.radius, effect_event.duration_ms}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_state, cid, hp, max_hp, alive}, %{socket: socket} = state) do
    GateServer.CliObserve.emit("player_state_push", %{
      cid: cid,
      hp: hp,
      max_hp: max_hp,
      alive: alive
    })

    send_encoded(socket, {:player_state, cid, hp, max_hp, alive})
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location},
        %{socket: socket} = state
      ) do
    GateServer.CliObserve.emit("combat_hit_push", %{
      source_cid: source_cid,
      target_cid: target_cid,
      skill_id: skill_id,
      damage: damage,
      hp_after: hp_after,
      location: location
    })

    send_encoded(
      socket,
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
    {:noreply, handle_live_voxel_data(state, :snapshot, payload)}
  end

  def handle_info({:voxel_chunk_delta_payload, payload}, state)
      when is_binary(payload) do
    {:noreply, handle_live_voxel_data(state, :delta, payload)}
  end

  def handle_info({:voxel_chunk_invalidate_payload, payload}, state)
      when is_binary(payload) do
    {:noreply, handle_live_voxel_invalidate(state, payload)}
  end

  def handle_info(:voxel_delivery_window, state) do
    scheduler =
      state
      |> Map.get(:voxel_delivery)
      |> DeliveryScheduler.ensure()
      |> DeliveryScheduler.reset_window()

    {scheduler, actions} = DeliveryScheduler.drain(scheduler)

    state =
      state
      |> Map.put(:voxel_delivery, scheduler)
      |> Map.put(:voxel_delivery_timer_ref, nil)
      |> send_live_voxel_actions(actions)
      |> maybe_schedule_voxel_delivery_window()

    {:noreply, state}
  end

  def handle_info({:voxel_object_state_delta_payload, payload}, state)
      when is_binary(payload) do
    {:noreply, handle_live_voxel_data(state, :object_state_delta, payload)}
  end

  def handle_info({:voxel_field_region_snapshot_payload, payload}, state)
      when is_binary(payload) do
    {:noreply, handle_live_voxel_data(state, :field_region_snapshot, payload)}
  end

  def handle_info({:voxel_field_region_destroyed_payload, payload}, state)
      when is_binary(payload) do
    {:noreply, handle_live_voxel_data(state, :field_region_destroyed, payload)}
  end

  def handle_info({:voxel_delivery_envelope, envelope}, state) when is_map(envelope) do
    {:noreply, handle_live_voxel_envelope(state, envelope)}
  end

  def handle_info({:partition_refresh_completed, generation, auth_tick, result}, state) do
    case PartitionRefresh.apply_completed(state, generation, auth_tick, result) do
      {:applied, next_state, event} ->
        GateServer.CliObserve.emit("gate_partition_refresh_applied", event)
        {:noreply, next_state}

      {:ignored, next_state, event} ->
        GateServer.CliObserve.emit("gate_partition_refresh_dropped", event)
        {:noreply, next_state}
    end
  end

  @impl true
  def handle_info({:tcp, _socket, data}, %{socket: socket} = state) do
    GateServer.CliObserve.emit("tcp_receive", fn ->
      %{connection_pid: self(), bytes: byte_size(data), status: state.status}
    end)

    case GateServer.Codec.decode(data) do
      {:ok, msg} ->
        GateServer.CliObserve.emit("tcp_decoded", fn ->
          %{connection_pid: self(), message: observe_message_summary(msg)}
        end)

        {:ok, new_state} = dispatch(msg, state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.debug("TCP codec decode rejected payload: #{inspect(reason)}")
        send_result_error(socket, reason, 0)
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
    cleanup_voxel_subscriptions(state)
    cleanup_chat_session(state)
    cleanup_scene(state.scene_ref)
    cleanup_fast_lane(self())
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp_error, _conn, err}, state) do
    Logger.info(
      "Socket #{inspect(state.socket, pretty: true)} closed with transport error: #{err}"
    )

    GateServer.CliObserve.emit("tcp_error", %{connection_pid: self(), cid: state.cid, reason: err})

    cleanup_voxel_subscriptions(state)
    cleanup_chat_session(state)
    cleanup_scene(state.scene_ref)
    cleanup_fast_lane(self())
    {:stop, :normal, state}
  end

  @impl true
  def handle_call(
        {:udp_movement, frame_params},
        _from,
        %{status: :in_scene, scene_ref: spid, cid: active_cid} = state
      ) do
    frame = build_input_frame(frame_params)

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
          accept_movement_input(spid, frame)
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

  defp dispatch(
         {:movement_input, frame_params},
         %{status: :in_scene, scene_ref: spid, socket: socket} = state
       ) do
    frame = build_input_frame(frame_params)

    GateServer.CliObserve.emit("tcp_movement_received", fn ->
      %{
        connection_pid: self(),
        seq: frame.seq,
        client_tick: frame.client_tick,
        input_dir: frame.input_dir
      }
    end)

    case accept_movement_input(spid, frame) do
      {:ok, ack} ->
        GenServer.cast(self(), {:movement_ack, ack})

      :accepted ->
        GateServer.CliObserve.emit("tcp_movement_accepted", fn ->
          %{connection_pid: self(), seq: frame.seq, client_tick: frame.client_tick}
        end)

      {:error, reason} ->
        GateServer.CliObserve.emit("tcp_movement_error", fn ->
          %{connection_pid: self(), seq: frame.seq, reason: reason}
        end)

        send_result_error(socket, reason, frame.seq)
    end

    {:ok, state}
  end

  defp dispatch({:movement_input, frame_params}, state) do
    frame = build_input_frame(frame_params)
    send_result_error(state.socket, :invalid_state, frame.seq)
    {:ok, state}
  end

  defp dispatch(
         {:chat_say, text, request_id},
         %{status: :in_scene, cid: cid, auth_username: username, socket: socket} =
           state
       ) do
    publish_chat(:world, text, request_id, state, cid, username, socket)
  end

  defp dispatch(
         {:chat_say_scoped, scope, text, request_id},
         %{status: :in_scene, cid: cid, auth_username: username, socket: socket} =
           state
       ) do
    publish_chat(scope, text, request_id, state, cid, username, socket)
  end

  defp dispatch({:chat_say_scoped, _scope, _text, request_id}, state) do
    send_result_error(state.socket, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch({:chat_say, _text, request_id}, state) do
    send_result_error(state.socket, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch(
         {:skill_cast,
          %{
            skill_id: skill_id,
            request_id: request_id,
            target_kind: target_kind,
            target_cid: target_cid,
            target_position: target_position
          }},
         %{status: :in_scene, scene_ref: spid, socket: socket} = state
       ) do
    GateServer.CliObserve.emit("skill_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request_id,
      skill_id: skill_id
    })

    cast_request =
      case target_kind do
        :actor when is_integer(target_cid) -> CastRequest.actor(skill_id, target_cid)
        :point -> CastRequest.point(skill_id, target_position)
        _ -> CastRequest.auto(skill_id)
      end

    case safe_call(spid, {:cast_skill, cast_request}, @scene_call_timeout) do
      {:ok, {:ok, _location}} -> send_encoded(socket, {:result, :ok, request_id})
      {:ok, {:error, reason}} -> send_result_error(socket, reason, request_id)
      {:ok, _} -> send_result_error(socket, :server_error, request_id)
      {:error, reason} -> send_result_error(socket, reason, request_id)
    end

    {:ok, state}
  end

  defp dispatch({:skill_cast, %{request_id: request_id}}, state) do
    send_result_error(state.socket, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch(
         {:enter_scene, cid, request_id},
         %{status: :authenticated, auth_claims: claims, socket: socket} = state
       ) do
    timestamp = :os.system_time(:millisecond)

    GateServer.CliObserve.emit("enter_scene_received", %{
      connection_pid: self(),
      cid: cid,
      request_id: request_id
    })

    with :ok <- authorize_cid(claims, cid),
         {:ok, character} <- fetch_authorized_character(claims, cid),
         {:ok, scene_node} <- fetch_scene_node(),
         {:ok, ppid} <-
           add_player(scene_node, cid, timestamp, build_character_profile(character)),
         {:ok, {x, y, z}} <- fetch_player_location(ppid),
         {:ok, expected_seq} <- fetch_next_input_seq(ppid) do
      GateServer.CliObserve.emit("enter_scene_ok", %{
        connection_pid: self(),
        cid: cid,
        request_id: request_id,
        scene_ref: ppid,
        location: {x, y, z},
        expected_seq: expected_seq
      })

      send_encoded(socket, {:enter_scene_result, :ok, request_id, {x, y, z}, expected_seq})

      bootstrap_context = ChatAdapter.context_from_character(character, {x, y, z})

      chat_context =
        join_chat_session(
          cid,
          state.auth_username || "anonymous",
          bootstrap_context
        )

      next_state =
        %{
          state
          | scene_ref: ppid,
            cid: cid,
            status: :in_scene,
            chat_session_joined?: not is_nil(chat_context),
            chat_context: chat_context,
            partition_context: initial_partition_context(bootstrap_context),
            agent: with_active_cid(state.agent, cid)
        }
        |> refresh_partition_after_movement_ack(partition_bootstrap_ack(cid, {x, y, z}))

      {:ok, next_state}
    else
      {:error, reason} ->
        GateServer.CliObserve.emit("enter_scene_error", %{
          connection_pid: self(),
          cid: cid,
          request_id: request_id,
          reason: reason
        })

        send_enter_scene_error(socket, reason, request_id)
        {:ok, state}
    end
  end

  defp dispatch({:enter_scene, _cid, request_id}, state) do
    send_enter_scene_error(state.socket, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch(
         {:time_sync, request_id, client_send_ts},
         %{status: status, socket: socket} = state
       )
       when status in [:authenticated, :in_scene] do
    server_recv_ts = :os.system_time(:millisecond)
    server_send_ts = :os.system_time(:millisecond)

    send_encoded(
      socket,
      {:time_sync_reply, request_id, client_send_ts, server_recv_ts, server_send_ts}
    )

    {:ok, state}
  end

  defp dispatch({:time_sync, request_id, _client_send_ts}, state) do
    send_result_error(state.socket, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch(
         {:fast_lane_request, request_id},
         %{status: status, socket: socket} = state
       )
       when status in [:authenticated, :in_scene] do
    GateServer.CliObserve.emit("fast_lane_request_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request_id,
      status: status
    })

    session_context = %{
      auth_claims: state.auth_claims,
      auth_username: state.auth_username,
      auth_session_id: state.auth_session_id,
      cid: state.cid,
      status: status
    }

    case GateServer.FastLaneRegistry.issue_ticket(self(), session_context) do
      {:ok, ticket} ->
        GateServer.CliObserve.emit("fast_lane_ticket_sent", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request_id
        })

        send_encoded(
          socket,
          {:fast_lane_result, :ok, request_id, GateServer.UdpAcceptor.port(), ticket}
        )

        {:ok, %{state | udp_ticket: ticket}}

      {:error, reason} ->
        Logger.warning("Fast-lane ticket issuance failed: #{inspect(reason)}")

        GateServer.CliObserve.emit("fast_lane_ticket_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request_id,
          reason: reason
        })

        send_encoded(socket, {:fast_lane_result, :error, request_id})
        {:ok, state}
    end
  end

  defp dispatch({:fast_lane_request, request_id}, state) do
    send_encoded(state.socket, {:fast_lane_result, :error, request_id})
    {:ok, state}
  end

  defp dispatch({:heartbeat, _timestamp}, %{socket: socket} = state) do
    send_encoded(socket, {:heartbeat_reply, :os.system_time(:millisecond)})
    {:ok, state}
  end

  defp dispatch({:voxel_chunk_subscribe, request}, %{status: :in_scene, socket: socket} = state) do
    GateServer.CliObserve.emit("voxel_chunk_subscribe_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      center_chunk: request.center_chunk
    })

    case subscribe_voxel_chunks(request, state) do
      {:ok, next_state, result} ->
        GateServer.CliObserve.emit("voxel_chunk_subscribe_ok", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          logical_scene_id: request.logical_scene_id,
          chunk_count: result.chunk_count,
          subscribed_chunk_count: result.subscribed_chunk_count,
          subscription_count: map_size(next_state.voxel_subscriptions)
        })

        {:ok, next_state}

      {:error, reason} ->
        GateServer.CliObserve.emit("voxel_chunk_subscribe_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          reason: reason
        })

        send_encoded(socket, voxel_result_error(request, reason))
        {:ok, state}
    end
  end

  defp dispatch({:voxel_chunk_subscribe, request}, state) do
    send_encoded(state.socket, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  defp dispatch({:voxel_chunk_unsubscribe, request}, %{status: :in_scene, socket: socket} = state) do
    {unsubscribed_count, next_state} = unsubscribe_voxel_chunks(request, state)

    GateServer.CliObserve.emit("voxel_chunk_unsubscribe_ok", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      requested_count: length(request.chunks),
      unsubscribed_count: unsubscribed_count,
      subscription_count: map_size(next_state.voxel_subscriptions)
    })

    send_encoded(socket, {:result, :ok, request.request_id})
    {:ok, next_state}
  end

  defp dispatch({:voxel_chunk_unsubscribe, request}, state) do
    send_result_error(state.socket, :invalid_state, request.request_id)
    {:ok, state}
  end

  defp dispatch({:voxel_chunk_ack, request}, %{status: :in_scene, socket: socket} = state) do
    {next_state, summary} = record_client_ack_versions(state, request)

    GateServer.CliObserve.emit("voxel_chunk_ack_recorded", fn ->
      Map.merge(summary, %{
        connection_pid: self(),
        cid: state.cid,
        transport: :tcp,
        request_id: request.request_id
      })
    end)

    if summary.rejected_count == 0 do
      send_encoded(socket, {:result, :ok, request.request_id})
    else
      send_result_error(socket, :client_ack_rejected, request.request_id)
    end

    {:ok, next_state}
  end

  defp dispatch({:voxel_chunk_ack, request}, state) do
    send_result_error(state.socket, :invalid_state, request.request_id)
    {:ok, state}
  end

  # DEPRECATED for client-side direct edit; protocol §13.6 / §13.6.1.
  # Use VoxelEditIntent (0x70) for typed client edits. Kept for the
  # skill/tool-system flow until 1c removes it.
  defp dispatch({:voxel_impact_intent, request}, %{status: :in_scene, socket: socket} = state) do
    GateServer.CliObserve.emit("voxel_impact_intent_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      source_skill_id: request.source_skill_id,
      target_world_micro: request.target_world_micro,
      impact_kind: request.impact_kind
    })

    case apply_voxel_impact_intent(request, state) do
      {:ok, result} ->
        GateServer.CliObserve.emit("voxel_impact_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          chunk_coord: result.chunk_coord,
          chunk_version: result.chunk_version,
          macro: result.macro
        })

        send_encoded(socket, voxel_result_ok(request, result))

      {:error, reason} ->
        GateServer.CliObserve.emit("voxel_impact_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          reason: reason
        })

        send_encoded(socket, voxel_result_error(request, reason))
    end

    {:ok, state}
  end

  defp dispatch({:voxel_impact_intent, request}, state) do
    send_encoded(state.socket, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  # VoxelEditIntent (0x70) — typed client edit channel; protocol §13.6.1.
  # Phase 1c routing: dispatch the typed request to ChunkDirectory.apply_intent
  # via the standard World map-ledger lease path, then reply with the
  # `VoxelIntentResult` (0x68) frame.
  defp dispatch(
         {:voxel_edit_intent, request},
         %{status: :in_scene, socket: socket} = state
       ) do
    emit_voxel_edit_intent_received(request, state)

    case apply_voxel_edit_intent(request, state) do
      {:ok, result} ->
        GateServer.CliObserve.emit("voxel_edit_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          chunk_coord: result.chunk_coord,
          chunk_version: result.chunk_version,
          macro: result.macro,
          operation: result.operation
        })

        send_encoded(socket, voxel_edit_intent_result_ok(request, result))

      {:error, reason} ->
        GateServer.CliObserve.emit("voxel_edit_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          reason: reason
        })

        send_encoded(socket, voxel_edit_intent_result_error(request, reason))
    end

    {:ok, state}
  end

  defp dispatch({:voxel_edit_intent, request}, state) do
    GateServer.CliObserve.emit("voxel_edit_intent_dropped_invalid_state", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      status: state.status
    })

    send_encoded(state.socket, voxel_edit_intent_result_error(request, :invalid_state))

    {:ok, state}
  end

  defp dispatch(
         {:voxel_build_reservation_intent, request},
         %{status: :in_scene, socket: socket} = state
       ) do
    GateServer.CliObserve.emit("voxel_build_reservation_intent_received", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        client_intent_seq: request.client_intent_seq,
        logical_scene_id: request.logical_scene_id,
        parcel_id: request.parcel_id,
        ttl_ms: request.ttl_ms
      }
    end)

    send_encoded(socket, voxel_intent_stub_accepted(request))
    {:ok, state}
  end

  defp dispatch({:voxel_build_reservation_intent, request}, state) do
    send_encoded(state.socket, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  # Real `0x67 PrefabPlaceIntent` dispatch.
  #
  # See `GateServer.WsConnection` for the canonical doc. Briefly: resolve
  # blueprint geometry through `SceneServer.Voxel.PrefabRaster`, then loop the
  # macro-cell list through `route_chunk_with_lease` + `apply_intent`, the
  # same pipeline `0x64 VoxelImpactIntent` uses.
  #
  # v1 has no cross-chunk atomicity. Partial writes that occur before a
  # later cell fails are NOT rolled back; the dispatch logs the partial-write
  # summary and returns `:rejected` to the client.
  defp dispatch(
         {:voxel_prefab_place_intent, request},
         %{status: :in_scene, socket: socket} = state
       ) do
    GateServer.CliObserve.emit("voxel_prefab_place_intent_received", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        client_intent_seq: request.client_intent_seq,
        logical_scene_id: request.logical_scene_id,
        parcel_id: request.parcel_id,
        blueprint_id: request.blueprint_id,
        blueprint_version: request.blueprint_version,
        rotation: request.rotation
      }
    end)

    case apply_voxel_prefab_place_intent(request, state) do
      {:ok, summary} ->
        GateServer.CliObserve.emit("voxel_prefab_place_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          blueprint_id: request.blueprint_id,
          cell_count: summary.cell_count,
          chunk_count: summary.chunk_count,
          max_chunk_version: summary.max_chunk_version
        })

        send_encoded(socket, voxel_prefab_result_ok(request, summary))

      {:error, %{reason: reason} = failure} ->
        GateServer.CliObserve.emit("voxel_prefab_place_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          blueprint_id: request.blueprint_id,
          reason: reason,
          applied_cell_count: failure.applied_cell_count,
          total_cell_count: failure.total_cell_count
        })

        send_encoded(socket, voxel_result_error(request, reason))
    end

    {:ok, state}
  end

  defp dispatch({:voxel_prefab_place_intent, request}, state) do
    send_encoded(state.socket, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  defp dispatch({:voxel_debug_probe, %{request_id: request_id, command: command}}, state) do
    GateServer.CliObserve.emit("voxel_debug_probe_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request_id,
      command: command,
      status: state.status
    })

    send_encoded(
      state.socket,
      {:voxel_debug_probe, %{request_id: request_id, result: voxel_debug_result(command, state)}}
    )

    {:ok, state}
  end

  defp dispatch(
         {:auth_request, username, code, request_id},
         %{status: :waiting_auth, socket: socket} = state
       ) do
    GateServer.CliObserve.emit("auth_received", %{
      connection_pid: self(),
      username: username,
      request_id: request_id
    })

    with {:ok, claims} <- verify_token(code),
         :ok <- validate_username_claim(claims, username) do
      auth_context = build_auth_context(username, code, claims)

      GateServer.CliObserve.emit("auth_ok", %{
        connection_pid: self(),
        username: username,
        request_id: request_id
      })

      send_encoded(socket, {:result, :ok, request_id})

      {:ok,
       %{
         state
         | agent: auth_context,
           auth_claims: claims,
           auth_username: username,
           auth_session_id: Map.get(auth_context, "session_id"),
           token: code,
           status: :authenticated
       }}
    else
      {:error, reason} ->
        GateServer.CliObserve.emit("auth_error", %{
          connection_pid: self(),
          username: username,
          request_id: request_id,
          reason: reason
        })

        send_result_error(socket, reason, request_id)
        {:ok, state}
    end
  end

  defp dispatch({:auth_request, _username, _code, request_id}, state) do
    send_result_error(state.socket, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch(msg, state) do
    Logger.warning("Unhandled message: #{inspect(msg)}")
    send_result_error(state.socket, :unknown_message, 0)
    {:ok, state}
  end

  defp publish_chat(scope, text, request_id, state, cid, username, socket) do
    case ChatScope.derive(scope, state) do
      {:ok, chat_target} ->
        publish_chat_to_target(chat_target, text, request_id, state, cid, username, socket)

      {:error, reason} ->
        GateServer.CliObserve.emit("chat_error", %{
          connection_pid: self(),
          cid: cid,
          request_id: request_id,
          scope: scope,
          reason: reason
        })

        send_result_error(socket, reason, request_id)
        {:ok, state}
    end
  end

  defp publish_chat_to_target(chat_target, text, request_id, state, cid, username, socket) do
    GateServer.CliObserve.emit("chat_received", %{
      connection_pid: self(),
      cid: cid,
      username: username,
      request_id: request_id,
      scope: chat_target.scope,
      channel: inspect(chat_target.channel),
      text: text
    })

    case ChatAdapter.publish(%{
           cid: state.cid,
           username: state.auth_username,
           logical_scene_id: chat_target.logical_scene_id,
           channel: chat_target.channel,
           text: text
         }) do
      {:ok, summary} ->
        GateServer.CliObserve.emit("chat_forwarded", %{
          connection_pid: self(),
          cid: cid,
          request_id: request_id,
          message_id: summary.message_id,
          scope: chat_target.scope,
          channel: inspect(summary.channel),
          recipient_count: summary.recipient_count
        })

        send_encoded(socket, {:result, :ok, request_id})

      {:error, reason} ->
        GateServer.CliObserve.emit("chat_error", %{
          connection_pid: self(),
          cid: cid,
          request_id: request_id,
          reason: reason
        })

        send_result_error(socket, reason, request_id)
    end

    {:ok, state}
  end

  @spec verify_token(any()) :: any
  defp verify_token(token) do
    case fetch_auth_node() do
      {:error, _reason} = error ->
        error

      {:ok, auth_node} ->
        case :rpc.call(auth_node, AuthServer.AuthWorker, :verify_token, [token]) do
          {:ok, claims} when is_map(claims) -> {:ok, claims}
          {:error, :mismatch} -> {:error, :mismatch}
          {:badrpc, _reason} -> {:error, :auth_unavailable}
          _ -> {:error, :server_error}
        end
    end
  end

  defp fetch_auth_node do
    case safe_call(GateServer.Interface, :auth_server) do
      {:ok, nil} -> {:error, :auth_unavailable}
      {:ok, auth_node} -> {:ok, auth_node}
      {:error, _reason} -> {:error, :auth_unavailable}
    end
  end

  defp fetch_scene_node do
    case safe_call(GateServer.Interface, :scene_server) do
      {:ok, nil} -> {:error, :scene_unavailable}
      {:ok, scene_node} -> {:ok, scene_node}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  defp fetch_world_node do
    case safe_call(GateServer.Interface, :world_server) do
      {:ok, nil} -> {:error, :world_unavailable}
      {:ok, world_node} -> {:ok, world_node}
      {:error, _reason} -> {:error, :world_unavailable}
    end
  end

  defp join_chat_session(cid, username, context) do
    case ChatAdapter.join(%{
           cid: cid,
           username: username,
           connection_pid: self(),
           logical_scene_id: context.logical_scene_id,
           region_id: context.region_id,
           chunk_coord: context.chunk_coord,
           location: context.location
         }) do
      {:ok, session} ->
        GateServer.CliObserve.emit("chat_session_joined", %{
          connection_pid: self(),
          cid: cid,
          logical_scene_id: session.logical_scene_id,
          region_id: session.region_id,
          chunk_coord: session.chunk_coord
        })

        Map.take(session, [:logical_scene_id, :region_id, :chunk_coord])

      {:error, reason} ->
        emit_chat_session_join_failed(cid, reason)
        nil
    end
  end

  defp initial_partition_context(context) do
    Map.take(context, [:logical_scene_id, :region_id, :chunk_coord])
  end

  defp partition_bootstrap_ack(cid, location) do
    %{
      cid: cid,
      ack_seq: 0,
      auth_tick: 0,
      position: location
    }
  end

  defp emit_chat_session_join_failed(cid, reason) do
    GateServer.CliObserve.emit("chat_session_join_failed", %{
      connection_pid: self(),
      cid: cid,
      reason: reason
    })
  end

  defp add_player(scene_node, cid, timestamp, character_profile) do
    case safe_call(
           {SceneServer.PlayerManager, scene_node},
           {:add_player, cid, self(), timestamp, character_profile},
           @scene_call_timeout
         ) do
      {:ok, {:ok, ppid}} -> {:ok, ppid}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  defp fetch_player_location(player_pid) do
    case safe_call(player_pid, :get_location, @scene_call_timeout) do
      {:ok, {:ok, location}} -> {:ok, location}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  # Audit B-S1 / B-SRV1: fetch the next-expected movement input seq from
  # the freshly-spawned PlayerCharacter so we can plumb it through
  # EnterSceneResult to the client. See codec.ex for layout.
  defp fetch_next_input_seq(player_pid) do
    case safe_call(player_pid, :get_next_input_seq, @scene_call_timeout) do
      {:ok, {:ok, seq}} -> {:ok, seq}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  defp cleanup_scene(nil), do: :ok

  defp cleanup_scene(scene_ref) do
    _ = safe_call(scene_ref, :exit)
    :ok
  end

  defp cleanup_chat_session(%{chat_session_joined?: true, cid: cid})
       when is_integer(cid) and cid >= 0 do
    ChatAdapter.leave(cid)
  end

  defp cleanup_chat_session(_state), do: :ok

  defp cleanup_fast_lane(connection_pid) do
    if Process.whereis(GateServer.FastLaneRegistry) do
      _ = GateServer.FastLaneRegistry.detach_connection(connection_pid, :tcp_closed)
    end

    :ok
  end

  defp authorize_cid(nil, _cid), do: {:error, :invalid_state}

  defp authorize_cid(claims, cid) do
    case apply(AuthServer.AuthWorker, :validate_cid, [claims, cid]) do
      :ok -> :ok
      {:error, :cid_mismatch} -> {:error, :cid_mismatch}
      {:error, _reason} -> {:error, :server_error}
    end
  end

  defp fetch_authorized_character(claims, cid) do
    with {:ok, auth_node} <- fetch_auth_node() do
      case :rpc.call(auth_node, AuthServer.AuthWorker, :fetch_authorized_character, [claims, cid]) do
        {:ok, character} when is_map(character) -> {:ok, character}
        {:error, :account_not_found} -> {:error, :cid_mismatch}
        {:error, :cid_mismatch} -> {:error, :cid_mismatch}
        {:error, :data_service_unavailable} -> {:error, :auth_unavailable}
        {:badrpc, _reason} -> {:error, :auth_unavailable}
        _ -> {:error, :server_error}
      end
    end
  end

  defp build_character_profile(character) when is_map(character) do
    %{
      cid: Map.get(character, :id) || Map.get(character, "id"),
      name:
        Map.get(character, :name) || Map.get(character, "name") ||
          "character-#{Map.get(character, :id) || Map.get(character, "id")}",
      position:
        normalize_position(Map.get(character, :position) || Map.get(character, "position"))
    }
  end

  defp build_character_profile(_character),
    do: %{name: "unknown", position: {750.0, 750.0, 185.0}}

  # Default spawn over the DevSeed 16×16 stone platform on chunk (0,0,0).
  # See `ws_connection.ex` for the browser-axis derivation; kept duplicated here so
  # the legacy TCP path stays in lock-step with the WebSocket path without
  # introducing a new shared module.
  defp normalize_position(%{} = position) do
    x = map_float(position, ["x", :x], 750.0)
    y = map_float(position, ["y", :y], 750.0)
    z = map_float(position, ["z", :z], 185.0)
    {x, y, z}
  end

  defp normalize_position(_position), do: {750.0, 750.0, 185.0}

  defp map_float(map, keys, default) do
    keys
    |> Enum.find_value(fn key -> Map.get(map, key) end)
    |> case do
      value when is_integer(value) ->
        value * 1.0

      value when is_float(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp validate_username_claim(claims, username) do
    apply(AuthServer.AuthWorker, :validate_username, [claims, username])
  end

  defp safe_call(server, message, timeout \\ @scene_call_timeout)
  defp safe_call(nil, _message, _timeout), do: {:error, :unavailable}

  defp safe_call(server, message, timeout) do
    try do
      {:ok, GenServer.call(server, message, timeout)}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp send_result_error(socket, reason, request_id) do
    Logger.debug("Sending generic result error: #{inspect(reason)}")

    GateServer.CliObserve.emit("send_result_error", %{
      socket: socket,
      request_id: request_id,
      reason: reason
    })

    send_encoded(socket, {:result, :error, request_id})
  end

  defp send_enter_scene_error(socket, reason, request_id) do
    Logger.debug("Sending enter-scene error: #{inspect(reason)}")

    GateServer.CliObserve.emit("send_enter_scene_error", %{
      socket: socket,
      request_id: request_id,
      reason: reason
    })

    send_encoded(socket, {:enter_scene_result, :error, request_id})
  end

  defp build_auth_context(username, token, claims) do
    %{
      "username" => username,
      "token" => token,
      "session_id" => Map.get(claims, "session_id") || Map.get(claims, :session_id),
      "source" => Map.get(claims, "source") || Map.get(claims, :source),
      "claims" => claims
    }
  end

  defp with_active_cid(auth_context, cid) when is_map(auth_context) do
    Map.put(auth_context, "active_cid", cid)
  end

  defp with_active_cid(auth_context, _cid), do: auth_context

  defp accept_movement_input(spid, frame) do
    case safe_call(spid, {:movement_input, frame}) do
      {:ok, {:ok, :accepted}} -> :accepted
      {:ok, {:ok, ack}} -> {:ok, ack}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      {:ok, _other} -> {:error, :scene_unavailable}
    end
  end

  defp route_voxel_chunk(logical_scene_id, chunk_coord) do
    with {:ok, world_node} <- fetch_world_node() do
      case safe_call(
             {WorldServer.Voxel.MapLedger, world_node},
             {:route_chunk_with_lease, logical_scene_id, chunk_coord},
             @scene_call_timeout
           ) do
        {:ok, {:ok, route}} -> {:ok, route}
        {:ok, {:error, reason}} -> {:error, reason}
        {:ok, _other} -> {:error, :world_unavailable}
        {:error, _reason} -> {:error, :world_unavailable}
      end
    end
  end

  defp route_voxel_chunks(logical_scene_id, chunk_coords) do
    with {:ok, world_node} <- fetch_world_node() do
      case safe_call(
             {WorldServer.Voxel.MapLedger, world_node},
             {:route_chunks_with_leases, logical_scene_id, chunk_coords},
             @scene_call_timeout
           ) do
        {:ok, {:ok, routes}} -> {:ok, routes}
        {:ok, {:error, _reason}} -> {:error, :no_route_for_chunk}
        {:ok, _other} -> {:error, :world_unavailable}
        {:error, _reason} -> {:error, :world_unavailable}
      end
    end
  end

  defp route_voxel_partition_window(logical_scene_id, center_chunk, radius) do
    with {:ok, world_node} <- fetch_world_node() do
      case safe_call(
             {WorldServer.Voxel.MapLedger, world_node},
             {:route_window_with_leases, logical_scene_id, center_chunk,
              [near_radius: 0, halo_radius: radius]},
             @scene_call_timeout
           ) do
        {:ok, %{route_entries: _route_entries} = window} -> {:ok, window}
        {:ok, _other} -> {:error, :world_unavailable}
        {:error, _reason} -> {:error, :world_unavailable}
      end
    end
  end

  defp apply_voxel_impact_intent(request, state) do
    with :ok <- authorize_voxel_impact_intent(request, state),
         {:ok, target} <- voxel_impact_target(request),
         :ok <- authorize_voxel_target(state, request.logical_scene_id, target.chunk_coord),
         {:ok, route} <- route_voxel_chunk(request.logical_scene_id, target.chunk_coord),
         {:ok, scene_node} <- fetch_scene_node_for_route(route) do
      lease = Map.fetch!(route, :lease)

      GateServer.CliObserve.emit("voxel_impact_intent_routed", %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        chunk_coord: target.chunk_coord,
        region_id: lease.region_id,
        lease_id: lease.lease_id,
        owner_scene_instance_ref: lease.owner_scene_instance_ref,
        owner_epoch: lease.owner_epoch,
        scene_node: scene_node
      })

      attrs =
        %{
          request_id: request.request_id,
          logical_scene_id: request.logical_scene_id,
          chunk_coord: target.chunk_coord,
          lease: lease,
          macro: target.local_macro
        }
        |> Map.merge(voxel_impact_op_attrs(request))

      case safe_call(
             {SceneServer.Voxel.ChunkDirectory, scene_node},
             {:apply_intent, attrs},
             @scene_call_timeout
           ) do
        {:ok, {:ok, reply}} ->
          {:ok, Map.merge(reply, %{macro: target.local_macro})}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:ok, _other} ->
          {:error, :scene_unavailable}

        {:error, _reason} ->
          {:error, :scene_unavailable}
      end
    end
  end

  defp fetch_scene_node_for_route(%{assignment: %{assigned_scene_node: scene_node}})
       when not is_nil(scene_node),
       do: {:ok, scene_node}

  defp fetch_scene_node_for_route(_route), do: {:error, :scene_node_unassigned}

  defp authorize_voxel_impact_intent(request, state) do
    cond do
      not is_integer(state.cid) or state.cid <= 0 ->
        {:error, :cid_mismatch}

      true ->
        case Skill.fetch(request.source_skill_id) do
          {:ok, _skill} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp voxel_impact_target(%{target_world_micro: {wx, wy, wz}}) do
    micro_resolution = Types.micro_resolution()

    world_macro = {
      Types.floor_div(wx, micro_resolution),
      Types.floor_div(wy, micro_resolution),
      Types.floor_div(wz, micro_resolution)
    }

    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
    {:ok, %{chunk_coord: chunk_coord, local_macro: local_macro}}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_target_world_micro}
  end

  defp voxel_impact_block(request) do
    NormalBlockData.new(request.impact_kind,
      health: 100,
      state_flags: request.source_skill_id
    )
  end

  # Wire convention: `impact_kind == 0` is the break sentinel — the cell
  # gets cleared back to empty mode (delta_kind 0 CellEmpty on the wire).
  defp voxel_impact_op_attrs(%{impact_kind: 0}), do: %{operation: :break_block}

  defp voxel_impact_op_attrs(request) do
    %{operation: :put_solid_block, block: voxel_impact_block(request)}
  end

  defp emit_voxel_edit_intent_received(request, state) do
    GateServer.CliObserve.emit("voxel_edit_intent_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      action: request.action,
      target_granularity: request.target_granularity,
      target_world_micro: request.target_world_micro,
      face_normal: request.face_normal,
      material_id: request.material_id,
      blueprint_ref: request.blueprint_ref,
      object_ref: request.object_ref,
      part_ref: request.part_ref,
      attribute_patch_ref: request.attribute_patch_ref,
      expected_chunk_version: request.expected_chunk_version,
      expected_cell_hash: request.expected_cell_hash,
      client_hint_hash: request.client_hint_hash
    })
  end

  defp apply_voxel_edit_intent(request, state) do
    with :ok <- authorize_voxel_edit_intent(state),
         {:ok, op} <- voxel_edit_intent_op(request),
         {:ok, target} <- voxel_edit_intent_target(request, op),
         :ok <- authorize_voxel_target(state, request.logical_scene_id, target.chunk_coord),
         {:ok, route} <- route_voxel_chunk(request.logical_scene_id, target.chunk_coord),
         {:ok, scene_node} <- fetch_scene_node_for_route(route) do
      lease = Map.fetch!(route, :lease)

      GateServer.CliObserve.emit("voxel_edit_intent_routed", %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        action: request.action,
        target_granularity: request.target_granularity,
        operation: op.operation,
        chunk_coord: target.chunk_coord,
        local_macro: target.local_macro,
        adjusted_world_micro: target.adjusted_world_micro,
        region_id: lease.region_id,
        lease_id: lease.lease_id,
        owner_scene_instance_ref: lease.owner_scene_instance_ref,
        owner_epoch: lease.owner_epoch,
        scene_node: scene_node
      })

      attrs = build_voxel_edit_intent_attrs(request, op, target, lease)

      case safe_call(
             {SceneServer.Voxel.ChunkDirectory, scene_node},
             {:apply_intent, attrs},
             @scene_call_timeout
           ) do
        {:ok, {:ok, reply}} ->
          {:ok, Map.merge(reply, %{macro: target.local_macro, operation: op.operation})}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:ok, _other} ->
          {:error, :scene_unavailable}

        {:error, _reason} ->
          {:error, :scene_unavailable}
      end
    end
  end

  defp authorize_voxel_edit_intent(state) do
    if is_integer(state.cid) and state.cid > 0 do
      :ok
    else
      {:error, :cid_mismatch}
    end
  end

  # Decision 3 / Phase 1c: action × target_granularity → Scene operation.
  # ObjectPart granularity is rejected for the supported actions; Damage /
  # Replace / AttributePatch are rejected wholesale until the Phase 5 attribute
  # catalog work lands.
  defp voxel_edit_intent_op(%{action: action}) when action in [2, 3, 4] do
    {:error, :action_not_implemented}
  end

  defp voxel_edit_intent_op(%{action: action, target_granularity: 2}) when action in [0, 1] do
    {:error, :granularity_object_part_not_implemented}
  end

  defp voxel_edit_intent_op(%{action: 0, target_granularity: 0} = request) do
    {:ok, %{operation: :put_solid_block, block: voxel_edit_intent_block(request)}}
  end

  defp voxel_edit_intent_op(%{action: 0, target_granularity: 1} = request) do
    case voxel_edit_intent_micro_layer(request) do
      {:ok, micro_layer} ->
        {:ok, %{operation: :put_micro_block, micro_layer: micro_layer}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp voxel_edit_intent_op(%{action: 1, target_granularity: 0}) do
    {:ok, %{operation: :break_block}}
  end

  defp voxel_edit_intent_op(%{action: 1, target_granularity: 1}) do
    {:ok, %{operation: :clear_micro_block}}
  end

  defp voxel_edit_intent_op(_request), do: {:error, :invalid_voxel_edit_intent}

  defp voxel_edit_intent_block(request) do
    NormalBlockData.new(request.material_id,
      attribute_set_ref: request.attribute_patch_ref
    )
  end

  defp voxel_edit_intent_micro_layer(request) do
    with {:ok, owner_object_id} <- voxel_edit_owner_object_id(request.object_ref) do
      {:ok,
       %{
         material_id: request.material_id,
         attribute_set_ref: request.attribute_patch_ref,
         owner_object_id: owner_object_id,
         owner_part_id: request.part_ref
       }}
    end
  end

  # owner_object_id is a u63 (`MicroLayer.@type`); the wire field is u64. The
  # high bit is reserved for future use, so reject values that don't fit.
  defp voxel_edit_owner_object_id(value)
       when is_integer(value) and value >= 0 and value <= 0x7FFF_FFFF_FFFF_FFFF,
       do: {:ok, value}

  defp voxel_edit_owner_object_id(_value), do: {:error, :invalid_object_ref}

  # Decision 6 / Phase 1c: Place actions consume `face_normal` here at the Gate
  # by offsetting `target_world_micro` by one micro slot in the direction of
  # the hit face. Break actions ignore `face_normal` — the resolved cell is
  # the one the client clicked.
  defp voxel_edit_intent_target(request, %{operation: operation}) do
    {wx, wy, wz} = request.target_world_micro
    {fnx, fny, fnz} = request.face_normal

    {ax, ay, az} =
      case operation do
        :put_solid_block -> {wx + fnx, wy + fny, wz + fnz}
        :put_micro_block -> {wx + fnx, wy + fny, wz + fnz}
        _other -> {wx, wy, wz}
      end

    micro_resolution = Types.micro_resolution()

    world_macro = {
      Types.floor_div(ax, micro_resolution),
      Types.floor_div(ay, micro_resolution),
      Types.floor_div(az, micro_resolution)
    }

    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)

    local_micro = {
      Types.floor_mod(ax, micro_resolution),
      Types.floor_mod(ay, micro_resolution),
      Types.floor_mod(az, micro_resolution)
    }

    {:ok,
     %{
       chunk_coord: chunk_coord,
       local_macro: local_macro,
       local_micro: local_micro,
       adjusted_world_micro: {ax, ay, az}
     }}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_target_world_micro}
  end

  defp build_voxel_edit_intent_attrs(request, op, target, lease) do
    base = %{
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      chunk_coord: target.chunk_coord,
      lease: lease,
      operation: op.operation,
      macro: target.local_macro,
      expected_chunk_version: request.expected_chunk_version,
      expected_cell_hash: request.expected_cell_hash
    }

    base
    |> maybe_put_voxel_edit(:block, Map.get(op, :block))
    |> maybe_put_voxel_edit(:micro_layer, Map.get(op, :micro_layer))
    |> maybe_put_voxel_edit_micro_slot(op, target)
  end

  defp maybe_put_voxel_edit(map, _key, nil), do: map
  defp maybe_put_voxel_edit(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_voxel_edit_micro_slot(map, %{operation: op}, target)
       when op in [:put_micro_block, :clear_micro_block] do
    Map.put(map, :micro_slot, Types.micro_index!(target.local_micro))
  end

  defp maybe_put_voxel_edit_micro_slot(map, _op, _target), do: map

  # `:stale_chunk_version` and `:stale_cell_hash` come back from
  # `ChunkProcess.validate_intent_preconditions/2` and map to the protocol
  # `Stale` (3) `VoxelIntentResult` code. Everything else is a generic
  # `Rejected` (2). Successful applies use `:accepted` (0).
  defp voxel_edit_intent_result_code(:stale_chunk_version), do: :stale
  defp voxel_edit_intent_result_code(:stale_cell_hash), do: :stale
  defp voxel_edit_intent_result_code(_reason), do: :rejected

  defp voxel_edit_intent_result_error(request, reason) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: Map.get(request, :client_intent_seq, 0),
       logical_scene_id: request.logical_scene_id,
       result_code: voxel_edit_intent_result_code(reason),
       result_ref: 0,
       authoritative: [],
       reason: inspect(reason)
     }}
  end

  defp voxel_edit_intent_result_ok(request, result) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: result.chunk_version,
       authoritative: [],
       reason: "ok"
     }}
  end

  defp apply_voxel_prefab_place_intent(request, state) do
    with :ok <- authorize_voxel_prefab_place_intent(state),
         {:ok, owner_object_id} <- allocate_prefab_owner_object_id(),
         {:ok, cells} <-
           PrefabRaster.rasterize(
             request.blueprint_id,
             request.blueprint_version,
             request.anchor_world_micro,
             request.rotation,
             owner_object_id: owner_object_id,
             owner_part_id: @prefab_owner_part_id
           ) do
      run_prefab_transaction(cells, request, state, owner_object_id)
    else
      {:error, reason} ->
        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: 0}}
    end
  end

  defp authorize_voxel_prefab_place_intent(state) do
    if is_integer(state.cid) and state.cid > 0 do
      :ok
    else
      {:error, :cid_mismatch}
    end
  end

  defp allocate_prefab_owner_object_id do
    case DataService.Voxel.SceneObjectStore.next_object_id() do
      {:ok, object_id}
      when is_integer(object_id) and object_id > 0 and object_id <= @max_prefab_owner_object_id ->
        {:ok, object_id}

      {:ok, _object_id} ->
        {:error, :invalid_allocated_object_id}

      {:error, _reason} ->
        {:error, :object_id_unavailable}
    end
  rescue
    _exception -> {:error, :object_id_unavailable}
  catch
    :exit, _reason -> {:error, :object_id_unavailable}
  end

  # Single-chunk prefabs stay on the Scene hot path and call
  # ChunkDirectory.apply_intents/2 directly. Multi-chunk prefabs that still
  # resolve to one concrete Scene chunk-directory owner use a local
  # prepare/commit/abort runner. Split-owner prefabs still go through World's
  # TransactionCoordinator + TransactionExecutor so the whole prefab commits
  # atomically across every participant.
  defp run_prefab_transaction([], _request, _state, _owner_object_id) do
    {:ok, %{cell_count: 0, chunk_count: 0, max_chunk_version: 0}}
  end

  defp run_prefab_transaction(cells, request, state, owner_object_id) do
    total = length(cells)

    with {:ok, plan} <- build_prefab_plan(cells, request, state, owner_object_id) do
      case single_chunk_prefab_plan(plan) do
        {:ok, participant, chunk_coord, intents} ->
          apply_single_chunk_prefab_fast_path(
            participant,
            plan,
            chunk_coord,
            intents,
            request,
            state,
            total
          )

        :error ->
          case same_owner_prefab_plan(plan) do
            {:ok, participants} ->
              apply_same_owner_prefab_fast_path(participants, plan, request, state, total)

            :error ->
              with {:ok, coordinator_ref} <- locate_voxel_transaction_coordinator(),
                   {:ok, transaction} <-
                     coordinator_begin_transaction(coordinator_ref, plan, request),
                   {:ok, executor_result} <-
                     executor_execute(coordinator_ref, transaction, plan) do
                finalize_prefab_outcome(executor_result, plan, total)
              end
          end
      end
    else
      {:error, reason} ->
        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: total}}
    end
  end

  # Bulk route chunks through World, then group by concrete Scene owner
  # `{chunk_directory, assigned_scene_node}`. Each participant still carries
  # `chunk_owners` so the real `{region_id, lease_id}` owner of every chunk is
  # preserved for object-owner metadata.
  defp build_prefab_plan(cells, request, state, owner_object_id) do
    cells_by_chunk = Enum.group_by(cells, & &1.chunk_coord)
    chunk_coords = Map.keys(cells_by_chunk)

    case chunk_coords do
      [] ->
        {:error, :empty_prefab}

      coords ->
        with :ok <- authorize_voxel_chunks(state, request.logical_scene_id, coords),
             {:ok, routes_by_chunk} <- route_all_chunks(request.logical_scene_id, coords),
             {:ok, participants} <-
               build_prefab_participants(routes_by_chunk, cells_by_chunk, request),
             {:ok, scene_object} <-
               build_prefab_scene_object(
                 request,
                 state,
                 owner_object_id,
                 coords,
                 cells,
                 participants
               ) do
          emit_prefab_routed_observe(request, state, participants, length(cells))

          {:ok,
           %{
             participants: participants,
             chunk_coords: Enum.sort(coords),
             scene_object: scene_object,
             scene_objects: [scene_object]
           }}
        end
    end
  end

  defp build_prefab_scene_object(
         request,
         state,
         owner_object_id,
         chunk_coords,
         cells,
         participants
       ) do
    covered_chunks = Enum.sort(chunk_coords)

    with {:ok, owner} <- prefab_scene_object_owner(covered_chunks, participants),
         {:ok, covered_by_region} <- prefab_covered_chunks_by_region(covered_chunks, participants) do
      {:ok,
       %{
         object_id: owner_object_id,
         logical_scene_id: request.logical_scene_id,
         parcel_id: Map.get(request, :parcel_id, 0),
         blueprint_id: request.blueprint_id,
         blueprint_version: request.blueprint_version,
         anchor_world_micro: request.anchor_world_micro,
         rotation: request.rotation,
         owner_actor_id: state.cid,
         state_flags: 0,
         object_attribute_ref: 0,
         object_tag_set_ref: 0,
         covered_chunks: covered_chunks,
         covered_chunks_by_region: covered_by_region,
         part_states: [
           %{part_id: @prefab_owner_part_id, health: length(cells), state_flags: 0}
         ],
         object_version: 1,
         owner_region_id: owner.region_id,
         owner_lease_id: owner.lease_id
       }}
    end
  end

  defp prefab_scene_object_owner([], _participants), do: {:error, :invalid_covered_chunks}

  defp prefab_scene_object_owner(covered_chunks, participants) do
    first_chunk = covered_chunks |> Enum.sort() |> List.first()

    case Enum.find(participants, fn participant -> first_chunk in participant.chunk_coords end) do
      nil ->
        {:error, :scene_object_owner_undeterminable}

      participant ->
        case Map.fetch(participant.chunk_owners, first_chunk) do
          {:ok, {region_id, lease_id}} -> {:ok, %{region_id: region_id, lease_id: lease_id}}
          :error -> {:error, {:missing_chunk_owner, first_chunk}}
        end
    end
  end

  defp prefab_covered_chunks_by_region(covered_chunks, participants) do
    chunk_to_owner =
      participants
      |> Enum.flat_map(fn participant ->
        Enum.map(participant.chunk_coords, fn coord ->
          {coord, Map.fetch!(participant.chunk_owners, coord)}
        end)
      end)
      |> Map.new()

    covered_chunks
    |> Enum.reduce_while({:ok, []}, fn coord, {:ok, acc} ->
      case Map.fetch(chunk_to_owner, coord) do
        {:ok, owner} -> {:cont, {:ok, [{coord, owner} | acc]}}
        :error -> {:halt, {:error, {:missing_chunk_owner, coord}}}
      end
    end)
    |> case do
      {:ok, pairs} ->
        {:ok,
         pairs
         |> Enum.reverse()
         |> Enum.group_by(fn {_coord, owner} -> owner end, fn {coord, _owner} -> coord end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route_all_chunks(logical_scene_id, chunk_coords) do
    route_voxel_chunks(logical_scene_id, chunk_coords)
  end

  defp build_prefab_participants(routes_by_chunk, cells_by_chunk, request) do
    routed_chunks =
      Enum.reduce_while(routes_by_chunk, {:ok, []}, fn {coord, route}, {:ok, acc} ->
        case fetch_scene_node_for_route(route) do
          {:ok, scene_node} ->
            lease = Map.fetch!(route, :lease)
            directory = voxel_chunk_directory_module_for({lease.region_id, lease.lease_id})
            {:cont, {:ok, [{coord, route, scene_node, directory} | acc]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    with {:ok, routed_chunks} <- routed_chunks do
      chunks_by_owner =
        Enum.group_by(
          routed_chunks,
          fn {_coord, _route, scene_node, directory} -> {directory, scene_node} end,
          fn {coord, route, _scene_node, _directory} -> {coord, route} end
        )

      chunks_by_owner
      |> Enum.reduce_while({:ok, []}, fn {{directory, scene_node}, entries}, {:ok, acc} ->
        chunks = entries |> Enum.map(fn {coord, _route} -> coord end) |> Enum.sort()

        first_route =
          entries
          |> Enum.sort_by(fn {coord, _route} -> coord end)
          |> List.first()
          |> elem(1)

        case build_prefab_participant(
               {directory, scene_node},
               chunks,
               first_route,
               routes_by_chunk,
               cells_by_chunk,
               request
             ) do
          {:ok, participant} -> {:cont, {:ok, [participant | acc]}}
        end
      end)
      |> case do
        {:ok, participants} -> {:ok, Enum.reverse(participants)}
        {:error, _} = err -> err
      end
    end
  end

  defp build_prefab_participant(
         {directory, scene_node},
         chunks,
         first_route,
         routes_by_chunk,
         cells_by_chunk,
         request
       ) do
    lease = Map.fetch!(first_route, :lease)
    chunks_sorted = Enum.sort(chunks)

    chunk_owners =
      Map.new(chunks_sorted, fn chunk_coord ->
        chunk_lease = routes_by_chunk |> Map.fetch!(chunk_coord) |> Map.fetch!(:lease)
        {chunk_coord, {chunk_lease.region_id, chunk_lease.lease_id}}
      end)

    intents_by_chunk =
      chunks_sorted
      |> Enum.map(fn chunk_coord ->
        cells_in_chunk = Map.fetch!(cells_by_chunk, chunk_coord)
        chunk_lease = routes_by_chunk |> Map.fetch!(chunk_coord) |> Map.fetch!(:lease)

        {chunk_coord, prefab_intents_for_chunk(cells_in_chunk, request, chunk_coord, chunk_lease)}
      end)
      |> Map.new()

    participant = %{
      participant_key: {:scene_owner, directory, scene_node},
      lease: lease,
      scene_node: scene_node,
      assigned_scene_node: scene_node,
      chunk_directory_module: directory,
      chunk_coords: chunks_sorted,
      chunk_owners: chunk_owners,
      intents_by_chunk: intents_by_chunk
    }

    {:ok, participant}
  end

  defp prefab_intents_for_chunk(cells_in_chunk, request, chunk_coord, lease) do
    Enum.map(cells_in_chunk, fn cell ->
      %{
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        chunk_coord: chunk_coord,
        lease: lease,
        operation: :put_micro_block,
        macro: cell.local_macro,
        micro_slot: cell.micro_slot,
        micro_layer: cell.layer_attrs,
        opts: [reject_occupied: true, return_snapshot_payload: false]
      }
    end)
  end

  defp single_chunk_prefab_plan(%{participants: [participant], chunk_coords: [chunk_coord]}) do
    case Map.fetch(participant.intents_by_chunk, chunk_coord) do
      {:ok, intents} -> {:ok, participant, chunk_coord, intents}
      :error -> :error
    end
  end

  defp single_chunk_prefab_plan(_plan), do: :error

  defp same_owner_prefab_plan(%{participants: [_ | _] = participants, chunk_coords: chunk_coords})
       when length(chunk_coords) > 1 do
    case participants |> Enum.map(&prefab_chunk_directory_ref/1) |> Enum.uniq() do
      [_single_owner] -> {:ok, participants}
      _multiple_owners -> :error
    end
  end

  defp same_owner_prefab_plan(_plan), do: :error

  defp apply_single_chunk_prefab_fast_path(
         participant,
         plan,
         chunk_coord,
         intents,
         request,
         state,
         total
       ) do
    started_at = System.monotonic_time(:millisecond)
    chunk_directory = single_chunk_prefab_directory(participant)

    GateServer.CliObserve.emit("voxel_prefab_single_chunk_fast_path_started", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        blueprint_id: request.blueprint_id,
        chunk_coord: chunk_coord,
        cell_count: total,
        region_id: participant.lease.region_id,
        lease_id: participant.lease.lease_id,
        scene_node: participant.scene_node
      }
    end)

    case SceneServer.Voxel.ChunkDirectory.apply_intents(chunk_directory, intents) do
      {:ok, summary} ->
        register_prefab_scene_object(plan, participant)

        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        GateServer.CliObserve.emit("voxel_prefab_single_chunk_fast_path_applied", fn ->
          %{
            connection_pid: self(),
            cid: state.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_coord: chunk_coord,
            cell_count: total,
            changed_count: Map.get(summary, :changed_count, 0),
            skipped_count: Map.get(summary, :skipped_count, 0),
            chunk_version: Map.get(summary, :chunk_version, 0),
            persist_result: Map.get(summary, :persist_result),
            elapsed_ms: elapsed_ms
          }
        end)

        {:ok,
         %{
           cell_count: total,
           chunk_count: 1,
           max_chunk_version: Map.get(summary, :chunk_version, 0)
         }}

      {:error, reason} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        GateServer.CliObserve.emit("voxel_prefab_single_chunk_fast_path_failed", fn ->
          %{
            connection_pid: self(),
            cid: state.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_coord: chunk_coord,
            cell_count: total,
            reason: inspect(reason),
            elapsed_ms: elapsed_ms
          }
        end)

        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: total}}
    end
  end

  defp single_chunk_prefab_directory(participant) do
    prefab_chunk_directory_ref(participant)
  end

  defp apply_same_owner_prefab_fast_path(participants, plan, request, state, total) do
    started_at = System.monotonic_time(:millisecond)
    transaction_id = unique_prefab_transaction_id(request)
    chunk_directory = prefab_chunk_directory_ref(List.first(participants))

    GateServer.CliObserve.emit("voxel_prefab_same_owner_fast_path_started", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        blueprint_id: request.blueprint_id,
        chunk_count: length(plan.chunk_coords),
        participant_count: length(participants),
        cell_count: total,
        chunk_directory: inspect(chunk_directory)
      }
    end)

    case PrefabLocalTransaction.execute(
           participants,
           transaction_id,
           request.logical_scene_id,
           &prefab_chunk_directory_ref/1
         ) do
      {:ok, %{participant_results: participant_results}} ->
        register_prefab_scene_object(plan, List.first(participants))

        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        max_version = max_chunk_version_from_results(participant_results)

        GateServer.CliObserve.emit("voxel_prefab_same_owner_fast_path_applied", fn ->
          %{
            connection_pid: self(),
            cid: state.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_count: length(plan.chunk_coords),
            participant_count: length(participants),
            cell_count: total,
            max_chunk_version: max_version,
            elapsed_ms: elapsed_ms
          }
        end)

        {:ok,
         %{
           cell_count: total,
           chunk_count: length(plan.chunk_coords),
           max_chunk_version: max_version
         }}

      {:error, %{reason: raw_reason} = error} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        reason = unwrap_prepare_reason(raw_reason)

        GateServer.CliObserve.emit("voxel_prefab_same_owner_fast_path_failed", fn ->
          %{
            connection_pid: self(),
            cid: state.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_count: length(plan.chunk_coords),
            participant_count: length(participants),
            cell_count: total,
            reason: inspect(reason),
            elapsed_ms: elapsed_ms
          }
        end)

        {:error,
         %{
           reason: reason || Map.get(error, :reason, :prefab_same_owner_fast_path_failed),
           applied_cell_count: 0,
           total_cell_count: total
         }}
    end
  end

  defp register_prefab_scene_object(%{scene_object: scene_object}, %{scene_node: scene_node}) do
    case :rpc.call(
           scene_node,
           SceneServer.Voxel.BuildTransactionApplier,
           :register_scene_objects,
           [[scene_object], []],
           5_000
         ) do
      :ok ->
        :ok

      other ->
        GateServer.CliObserve.emit("voxel_prefab_scene_object_register_failed", fn ->
          %{
            object_id: Map.get(scene_object, :object_id),
            logical_scene_id: Map.get(scene_object, :logical_scene_id),
            reason: inspect(other)
          }
        end)

        :ok
    end
  end

  defp register_prefab_scene_object(_plan, _participant), do: :ok

  defp prefab_chunk_directory_ref(%{chunk_directory_module: module, scene_node: scene_node}) do
    {module, scene_node}
  end

  defp prefab_chunk_directory_ref(%{participant_key: participant_key, scene_node: scene_node}) do
    module = voxel_chunk_directory_module_for(participant_key)
    {module, scene_node}
  end

  defp emit_prefab_routed_observe(request, state, participants, cell_count) do
    GateServer.CliObserve.emit("voxel_prefab_routed", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        blueprint_id: request.blueprint_id,
        chunk_count: Enum.reduce(participants, 0, fn p, acc -> acc + length(p.chunk_coords) end),
        cell_count: cell_count,
        participant_count: length(participants),
        participants:
          Enum.map(participants, fn p ->
            %{
              participant_key: inspect(p.participant_key),
              region_id: p.lease.region_id,
              lease_id: p.lease.lease_id,
              owner_scene_instance_ref: p.lease.owner_scene_instance_ref,
              owner_epoch: p.lease.owner_epoch,
              scene_node: p.scene_node,
              chunk_owner_count: map_size(p.chunk_owners),
              chunk_count: length(p.chunk_coords)
            }
          end)
      }
    end)
  end

  # See ws_connection's matching helper for the rationale on going through
  # `fetch_world_node/0` instead of calling `BeaconServer.Client.lookup/1`
  # directly.
  defp locate_voxel_transaction_coordinator do
    case fetch_world_node() do
      {:ok, world_node} ->
        {:ok, {WorldServer.Voxel.TransactionCoordinator, world_node}}

      {:error, _reason} ->
        {:error, :voxel_transaction_coordinator_unavailable}
    end
  end

  defp coordinator_begin_transaction(coordinator_ref, plan, request) do
    transaction_id = unique_prefab_transaction_id(request)

    attrs = %{
      logical_scene_id: request.logical_scene_id,
      parcel_id: Map.get(request, :parcel_id, 0),
      reservation_id: prefab_reservation_id(request),
      decision_version: 1,
      participants:
        Enum.map(plan.participants, fn p ->
          %{
            participant_key: p.participant_key,
            region_id: p.lease.region_id,
            lease_id: p.lease.lease_id,
            owner_scene_instance_ref: p.lease.owner_scene_instance_ref,
            owner_epoch: p.lease.owner_epoch,
            assigned_scene_node: p.assigned_scene_node,
            chunk_owners: p.chunk_owners,
            affected_chunks: p.chunk_coords
          }
        end),
      scene_objects: Map.get(plan, :scene_objects, [])
    }

    try do
      case WorldServer.Voxel.TransactionCoordinator.begin_transaction(
             coordinator_ref,
             transaction_id,
             attrs
           ) do
        {:ok, transaction} -> {:ok, transaction}
        {:error, reason} -> {:error, {:coordinator_begin_failed, reason}}
      end
    catch
      :exit, _reason -> {:error, :coordinator_unavailable}
    end
  end

  # plan.participants 已经按 Scene owner 分组,这里直接把每个 participant 的
  # intents_by_chunk + scene_node 摊成 by-participant 两份 map 喂给 executor。
  # 单 Scene-owner participant 可以包含多个 region/lease;chunk_owners 保留
  # 真实 owner。
  defp executor_execute(coordinator_ref, transaction, plan) do
    intents_by_participant =
      plan.participants
      |> Enum.map(fn p -> {p.participant_key, p.intents_by_chunk} end)
      |> Map.new()

    scene_opts_by_participant =
      plan.participants
      |> Enum.map(fn p ->
        {p.participant_key, [chunk_directory: prefab_chunk_directory_ref(p)]}
      end)
      |> Map.new()

    try do
      WorldServer.Voxel.TransactionExecutor.execute(
        coordinator_ref,
        transaction,
        intents_by_participant,
        scene_opts_by_participant: scene_opts_by_participant
      )
    catch
      :exit, _reason -> {:error, :executor_crashed}
    end
  end

  # Phase A4-5:per-participant chunk_directory module 解析。生产 default
  # `SceneServer.Voxel.ChunkDirectory`;test 注入 `:voxel_chunk_directory_resolver`
  # env fn 让不同 participant 路由到不同 named instance(单 BEAM 模拟多 scene_node)。
  # A4-bis-cluster 落地后 default 改为走 `RegionRouting.resolve_chunk_directory/1`。
  defp voxel_chunk_directory_module_for(participant_key) do
    case Application.get_env(:gate_server, :voxel_chunk_directory_resolver) do
      nil -> SceneServer.Voxel.ChunkDirectory
      fun when is_function(fun, 1) -> fun.(participant_key)
    end
  end

  defp finalize_prefab_outcome(executor_result, plan, total) do
    case executor_result do
      %{decision: :commit, participant_results: results} ->
        max_version = max_chunk_version_from_results(results)

        {:ok,
         %{
           cell_count: total,
           chunk_count: length(plan.chunk_coords),
           max_chunk_version: max_version
         }}

      %{decision: :abort, prepare_results: prepare_results} ->
        reason = first_prepare_failure_reason(prepare_results) || :prefab_transaction_aborted

        {:error,
         %{
           reason: reason,
           applied_cell_count: 0,
           total_cell_count: total
         }}
    end
  end

  defp max_chunk_version_from_results(results) do
    Enum.reduce(results, 0, fn
      {_participant, {:ok, summary}}, acc ->
        committed = Map.get(summary, :committed_chunks, [])

        Enum.reduce(committed, acc, fn {_chunk, chunk_summary}, inner ->
          max(inner, Map.get(chunk_summary, :chunk_version, 0))
        end)

      _, acc ->
        acc
    end)
  end

  defp first_prepare_failure_reason(prepare_results) do
    prepare_results
    |> Enum.find_value(fn
      {_participant, {:error, reason}} -> reason
      _ -> nil
    end)
    |> unwrap_prepare_reason()
  end

  # Phase A1-2:跟 ws_connection 同 unwrap 逻辑(见同名函数注释)。
  defp unwrap_prepare_reason({:prepare_failed, _chunk_coord, inner_reason}), do: inner_reason
  defp unwrap_prepare_reason(other), do: other

  defp unique_prefab_transaction_id(request) do
    unique = System.unique_integer([:positive, :monotonic])
    "prefab-#{request.request_id}-#{unique}"
  end

  defp prefab_reservation_id(request) do
    "prefab-reservation-#{request.request_id}"
  end

  defp emit_voxel_subscription_window_planned(plan, state) do
    GateServer.CliObserve.emit("voxel_subscription_window_planned", fn ->
      Map.merge(plan.summary, %{
        connection_pid: self(),
        cid: state.cid,
        subscribe_entries:
          Enum.map(plan.subscribe_entries, fn entry ->
            Map.take(entry, [:chunk_coord, :tier, :priority, :region_id, :lease_id])
          end),
        skipped_entries:
          Enum.map(plan.skipped_entries, fn entry ->
            Map.take(entry, [:chunk_coord, :tier, :status, :reason, :region_id, :lease_id])
          end)
      })
    end)
  end

  defp voxel_result_error(request, reason) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: Map.get(request, :client_intent_seq, 0),
       logical_scene_id: request.logical_scene_id,
       result_code: :rejected,
       result_ref: 0,
       authoritative: [],
       reason: inspect(reason)
     }}
  end

  defp voxel_result_ok(request, result) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: result.chunk_version,
       authoritative: [],
       reason: "ok"
     }}
  end

  defp voxel_prefab_result_ok(request, summary) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: summary.max_chunk_version,
       authoritative: [],
       reason: "ok"
     }}
  end

  # Stub accept used by build-reservation / prefab-place intents until the
  # real reservation and rasterisation pipeline lands. The wire shape matches
  # the eventual spec so clients can round-trip the result frame today.
  defp voxel_intent_stub_accepted(request) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: Map.get(request, :client_intent_seq, 0),
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: 0,
       authoritative: [],
       reason: ""
     }}
  end

  defp subscribe_voxel_chunks(request, state) do
    with :ok <- validate_voxel_subscribe_radius(request.radius_l_inf),
         :ok <-
           authorize_voxel_subscribe_window(
             state,
             request.logical_scene_id,
             request.center_chunk,
             request.radius_l_inf
           ),
         {:ok, window} <-
           route_voxel_partition_window(
             request.logical_scene_id,
             request.center_chunk,
             request.radius_l_inf
           ),
         {:ok, plan_state, plan} <- build_voxel_subscription_plan(request, state, window) do
      emit_voxel_subscription_window_planned(plan, plan_state)

      with :ok <- validate_subscription_plan_has_center(plan, request.center_chunk) do
        case SubscriptionRuntime.apply_plan(plan_state, plan,
               subscriber: self(),
               send_snapshot?: request.want_snapshot,
               diff_mode: :additive,
               reason: :client_chunk_subscribe
             ) do
          {:ok, next_state, summary} ->
            {:ok, next_state,
             %{
               chunk_count: plan.summary.requested_chunk_count,
               subscribed_chunk_count: summary.subscribe_count
             }}

          {:error, _next_state, summary} ->
            {:error, Map.get(summary, :reason, :voxel_subscription_failed)}
        end
      end
    end
  end

  defp authorize_voxel_subscribe_window(state, logical_scene_id, center_chunk, radius_l_inf) do
    case authoritative_voxel_context(state) do
      %{logical_scene_id: ^logical_scene_id, chunk_coord: authority_chunk} ->
        if chunk_linf_distance(authority_chunk, center_chunk) + radius_l_inf <=
             @max_voxel_subscribe_radius do
          :ok
        else
          {:error, :unauthorized_voxel_target}
        end

      %{logical_scene_id: _other_scene_id} ->
        {:error, :unauthorized_voxel_target}

      nil ->
        authorize_legacy_voxel_target_without_partition_context()
    end
  end

  defp authorize_voxel_target(state, logical_scene_id, chunk_coord) do
    authorize_voxel_chunks(state, logical_scene_id, [chunk_coord])
  end

  defp authorize_voxel_chunks(state, logical_scene_id, chunk_coords) do
    case authoritative_voxel_context(state) do
      %{logical_scene_id: ^logical_scene_id, chunk_coord: authority_chunk} ->
        if Enum.all?(
             chunk_coords,
             &authorized_voxel_chunk?(state, logical_scene_id, authority_chunk, &1)
           ) do
          :ok
        else
          {:error, :unauthorized_voxel_target}
        end

      %{logical_scene_id: _other_scene_id} ->
        {:error, :unauthorized_voxel_target}

      nil ->
        authorize_legacy_voxel_target_without_partition_context()
    end
  end

  defp authoritative_voxel_context(%{
         partition_context: %{
           logical_scene_id: logical_scene_id,
           chunk_coord: {_, _, _} = chunk_coord
         }
       })
       when is_integer(logical_scene_id) do
    %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord}
  end

  defp authoritative_voxel_context(%{
         chat_context: %{logical_scene_id: logical_scene_id, chunk_coord: {_, _, _} = chunk_coord}
       })
       when is_integer(logical_scene_id) do
    %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord}
  end

  defp authoritative_voxel_context(_state), do: nil

  defp authorized_voxel_chunk?(state, logical_scene_id, authority_chunk, chunk_coord) do
    subscribed_voxel_chunk?(state, logical_scene_id, chunk_coord) or
      chunk_linf_distance(authority_chunk, chunk_coord) <= @max_voxel_subscribe_radius
  end

  defp subscribed_voxel_chunk?(state, logical_scene_id, chunk_coord) do
    state
    |> Map.get(:voxel_subscriptions, %{})
    |> Map.has_key?({logical_scene_id, chunk_coord})
  end

  defp chunk_linf_distance({ax, ay, az}, {bx, by, bz}) do
    Enum.max([abs(ax - bx), abs(ay - by), abs(az - bz)])
  end

  defp authorize_legacy_voxel_target_without_partition_context do
    if Application.get_env(
         :gate_server,
         :allow_legacy_voxel_target_without_partition_context,
         false
       ) do
      :ok
    else
      {:error, :unauthorized_voxel_target}
    end
  end

  defp build_voxel_subscription_plan(request, state, window) do
    {state, _summary} = record_client_known_versions(state, request)
    known_versions = client_ack_known_versions_for_subscription(state, request.logical_scene_id)

    {:ok, state,
     SubscriptionPlanner.plan(%{
       cid: state.cid,
       request_id: request.request_id,
       partition_window: window,
       known_versions: known_versions
     })}
  rescue
    _exception in [ArgumentError, KeyError] -> {:error, :invalid_subscription_window}
  end

  defp validate_subscription_plan_has_center(plan, center_chunk) do
    if Enum.any?(plan.subscribe_entries, &(&1.chunk_coord == center_chunk)) do
      :ok
    else
      plan.skipped_entries
      |> Enum.find(&(&1.chunk_coord == center_chunk))
      |> case do
        %{reason: :missing_lease} -> {:error, :region_without_lease}
        %{reason: :missing_route} -> {:error, :unassigned_chunk}
        _other -> {:error, :unassigned_chunk}
      end
    end
  end

  defp record_client_known_versions(state, request) do
    known = Map.get(request, :known, [])

    if known == [] do
      {state, empty_client_ack_summary(request.logical_scene_id)}
    else
      {next_state, summary} =
        record_client_ack_versions(state, Map.put(request, :acks, voxel_known_versions(known)))

      GateServer.CliObserve.emit("voxel_client_known_versions_recorded", fn ->
        Map.merge(summary, %{
          connection_pid: self(),
          cid: state.cid,
          transport: :tcp,
          request_id: request.request_id
        })
      end)

      {next_state, summary}
    end
  end

  defp record_client_ack_versions(state, request) do
    ledger = Map.get(state, :client_ack_versions, ClientAckLedger.new())
    forwarded = Map.get(state, :forwarded_chunk_versions, ChunkVersionLedger.new())

    {next_ledger, summary} =
      ClientAckLedger.record_known_versions(
        ledger,
        forwarded,
        request.logical_scene_id,
        Map.get(request, :acks, [])
      )

    {Map.put(state, :client_ack_versions, next_ledger), summary}
  end

  defp client_ack_known_versions_for_subscription(state, logical_scene_id) do
    state
    |> Map.get(:client_ack_versions, ClientAckLedger.new())
    |> ClientAckLedger.known_versions(logical_scene_id)
    |> Map.drop(
      DeliveryScheduler.resync_required_chunks(Map.get(state, :voxel_delivery), logical_scene_id)
    )
  end

  defp empty_client_ack_summary(logical_scene_id) do
    %{
      status: :empty,
      logical_scene_id: logical_scene_id,
      accepted_count: 0,
      ignored_count: 0,
      rejected_count: 0,
      ack_count: 0,
      events: []
    }
  end

  defp unsubscribe_voxel_chunks(request, state) do
    Enum.reduce(request.chunks, {0, state}, fn chunk_coord, {count, acc_state} ->
      case unsubscribe_voxel_chunk(request.logical_scene_id, chunk_coord, acc_state) do
        {:ok, next_state} -> {count + 1, next_state}
        {:purged, next_state} -> {count, next_state}
      end
    end)
  end

  defp unsubscribe_voxel_chunk(logical_scene_id, chunk_coord, state) do
    key = voxel_subscription_key(logical_scene_id, chunk_coord)

    case Map.pop(state.voxel_subscriptions, key) do
      {nil, _subscriptions} ->
        {:purged,
         state
         |> clear_queued_voxel_delivery(logical_scene_id, chunk_coord)
         |> clear_forwarded_chunk_version(logical_scene_id, chunk_coord)}

      {subscription, subscriptions} ->
        scene_unsubscribe(subscription)

        {:ok,
         state
         |> Map.put(:voxel_subscriptions, subscriptions)
         |> clear_queued_voxel_delivery(logical_scene_id, chunk_coord)
         |> clear_forwarded_chunk_version(logical_scene_id, chunk_coord)}
    end
  end

  defp cleanup_voxel_subscriptions(%{voxel_subscriptions: subscriptions}) do
    Enum.each(subscriptions, fn {_key, subscription} -> scene_unsubscribe(subscription) end)
    :ok
  end

  defp scene_unsubscribe(%{
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         scene_node: scene_node
       }) do
    _ =
      safe_call(
        {SceneServer.Voxel.ChunkDirectory, scene_node},
        {:unsubscribe,
         %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord, subscriber: self()}},
        @scene_call_timeout
      )

    :ok
  end

  defp validate_voxel_subscribe_radius(radius)
       when is_integer(radius) and radius >= 0 and radius <= @max_voxel_subscribe_radius,
       do: :ok

  defp validate_voxel_subscribe_radius(_radius), do: {:error, :voxel_subscribe_radius_too_large}

  defp voxel_known_versions(known) do
    Map.new(known, fn %{chunk_coord: chunk_coord, chunk_version: chunk_version} ->
      {chunk_coord, chunk_version}
    end)
  end

  defp voxel_subscription_key(logical_scene_id, chunk_coord), do: {logical_scene_id, chunk_coord}

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

  defp send_encoded(socket, message) do
    case GateServer.Codec.encode(message) do
      {:ok, bin} -> safe_tcp_send(socket, bin)
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_tcp_send(socket, iodata) do
    :gen_tcp.send(socket, iodata)
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # Phase 6: forward a pre-encoded payload (opcode byte already prefixed by
  # the producer) directly. The `{packet, 4}` socket option still adds the
  # 4-byte big-endian length prefix at the gen_tcp layer.
  defp send_frame(socket, payload) when is_binary(payload) do
    safe_tcp_send(socket, payload)
  end

  defp observe_message_summary({:auth_request, username, _token, request_id}) do
    %{type: :auth_request, username: username, request_id: request_id, token_redacted?: true}
  end

  defp observe_message_summary({:movement_input, frame}) do
    %{type: :movement_input, seq: frame.seq, client_tick: frame.client_tick}
  end

  defp observe_message_summary({:voxel_debug_probe, %{request_id: request_id, command: command}}) do
    %{type: :voxel_debug_probe, request_id: request_id, command: command}
  end

  defp observe_message_summary({:voxel_impact_intent, request}) do
    %{
      type: :voxel_impact_intent,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      impact_kind: request.impact_kind
    }
  end

  defp observe_message_summary(message), do: message

  defp voxel_debug_result("voxel_transport", state) do
    plan = state.voxel_subscription_plan || %{}
    partition_context = Map.get(state, :partition_context) || %{}
    chat_context = Map.get(state, :chat_context) || %{}
    last_partition_refresh = Map.get(state, :last_partition_refresh) || %{}

    [
      "voxel_sync=server-authoritative",
      "voxel_truth_source=server",
      "connection_status=#{state.status}",
      "cid=#{state.cid}",
      "scene_attached=#{not is_nil(state.scene_ref)}",
      "partition_context_region_id=#{Map.get(partition_context, :region_id, :none)}",
      "partition_context_chunk_coord=#{inspect(Map.get(partition_context, :chunk_coord))}",
      "chat_context_region_id=#{Map.get(chat_context, :region_id, :none)}",
      "chat_context_chunk_coord=#{inspect(Map.get(chat_context, :chunk_coord))}",
      "last_partition_refresh_status=#{Map.get(last_partition_refresh, :status, :none)}",
      "last_partition_refresh_boundary=#{Map.get(last_partition_refresh, :boundary_kind, :none)}",
      "last_partition_refresh_reason=#{inspect(Map.get(last_partition_refresh, :reason))}",
      "last_partition_refresh_auth_tick=#{Map.get(last_partition_refresh, :auth_tick, :none)}",
      "partition_refresh_generation=#{Map.get(state, :partition_refresh_generation, 0)}",
      "partition_refresh_pending_status=#{Map.get(Map.get(state, :partition_refresh_pending) || %{}, :status, :none)}",
      "partition_refresh_pending_generation=#{Map.get(Map.get(state, :partition_refresh_pending) || %{}, :generation, :none)}",
      "partition_refresh_pending_auth_tick=#{Map.get(Map.get(state, :partition_refresh_pending) || %{}, :auth_tick, :none)}",
      "voxel_subscription_count=#{map_size(state.voxel_subscriptions)}",
      "voxel_subscriptions=#{inspect(state.voxel_subscriptions |> Map.keys() |> Enum.take(16))}",
      "voxel_subscription_routes=#{inspect(voxel_subscription_debug(state.voxel_subscriptions))}",
      "voxel_subscription_plan_pressure=#{Map.get(plan, :pressure, :none)}",
      "voxel_subscription_plan_center_chunk=#{inspect(Map.get(plan, :center_chunk))}",
      "voxel_subscription_plan_near_radius=#{Map.get(plan, :near_radius, :none)}",
      "voxel_subscription_plan_halo_radius=#{Map.get(plan, :halo_radius, :none)}",
      "voxel_subscription_plan_near_vertical_radius=#{Map.get(plan, :near_vertical_radius, :none)}",
      "voxel_subscription_plan_halo_vertical_radius=#{Map.get(plan, :halo_vertical_radius, :none)}",
      "voxel_subscription_plan_subscribe_count=#{Map.get(plan, :subscribe_count, 0)}",
      "voxel_subscription_plan_skipped_count=#{Map.get(plan, :skipped_count, 0)}",
      "voxel_subscription_plan_missing_count=#{Map.get(plan, :missing_chunk_count, 0)}",
      "voxel_subscription_plan_unleased_count=#{Map.get(plan, :unleased_chunk_count, 0)}",
      "forwarded_chunk_versions=#{ChunkVersionLedger.format_debug(Map.get(state, :forwarded_chunk_versions))}",
      "client_ack_versions=#{ClientAckLedger.format_debug(Map.get(state, :client_ack_versions))}",
      voxel_delivery_debug(Map.get(state, :voxel_delivery)),
      "inflight_intent_count=0",
      "voxel_codec_endian=big",
      "micro_resolution=8"
    ]
    |> Enum.join("\n")
  end

  defp voxel_debug_result(command, state) do
    [
      "command=#{command}",
      "connection_status=#{state.status}",
      "voxel_debug=unknown_command"
    ]
    |> Enum.join("\n")
  end

  defp refresh_partition_after_movement_ack(state, ack) do
    case PartitionRuntime.refresh_after_movement_ack(state, ack) do
      {:ok, next_state, _outcome} -> next_state
      {:error, next_state, _outcome} -> next_state
    end
  end

  defp schedule_partition_refresh_after_movement_ack(state, ack) do
    {:ok, next_state, event} = PartitionRefresh.schedule(state, ack, owner: self())
    GateServer.CliObserve.emit("gate_partition_refresh_scheduled", event)
    next_state
  end

  defp voxel_subscription_debug(subscriptions) do
    subscriptions
    |> Map.values()
    |> Enum.take(16)
    |> Enum.map(fn subscription ->
      Map.take(subscription, [
        :logical_scene_id,
        :chunk_coord,
        :region_id,
        :lease_id,
        :owner_scene_instance_ref,
        :owner_epoch,
        :scene_node
      ])
    end)
  end

  defp build_input_frame(%{} = frame) do
    if Map.get(frame, :__struct__) == InputFrame do
      frame
    else
      struct(
        InputFrame,
        %{
          seq: Map.fetch!(frame, :seq),
          client_tick: Map.fetch!(frame, :client_tick),
          dt_ms: Map.fetch!(frame, :dt_ms),
          input_dir: Map.fetch!(frame, :input_dir),
          speed_scale: Map.fetch!(frame, :speed_scale),
          movement_flags: Map.fetch!(frame, :movement_flags)
        }
      )
    end
  end

  defp normalize_remote_snapshot(%{} = snapshot) do
    if Map.get(snapshot, :__struct__) == RemoteSnapshot do
      snapshot
    else
      raise ArgumentError, "expected remote snapshot map, got: #{inspect(snapshot)}"
    end
  end

  defp player_move_message(
         %RemoteSnapshot{
           priority_band: nil,
           priority_score: nil,
           observer_distance: nil,
           delivery_interval: nil
         } = snapshot,
         server_send_ms
       ) do
    {:player_move, snapshot.cid, snapshot.server_tick, movement_state_ms(snapshot),
     server_send_ms, snapshot.position, snapshot.velocity, snapshot.acceleration,
     snapshot.movement_mode}
  end

  defp player_move_message(%RemoteSnapshot{} = snapshot, server_send_ms) do
    {:player_move, snapshot.cid, snapshot.server_tick, movement_state_ms(snapshot),
     server_send_ms, snapshot.position, snapshot.velocity, snapshot.acceleration,
     snapshot.movement_mode, snapshot.priority_band, snapshot.priority_score,
     snapshot.observer_distance, snapshot.delivery_interval}
  end

  defp movement_state_ms(%{} = movement_payload) do
    case Map.get(movement_payload, :server_state_ms, 0) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp voxel_delivery_debug(scheduler) do
    summary = DeliveryScheduler.summary(scheduler)

    [
      "voxel_delivery_window_bytes_used=#{summary.window_bytes_used}",
      "voxel_delivery_window_items_used=#{summary.window_items_used}",
      "voxel_delivery_max_window_bytes=#{summary.max_window_bytes}",
      "voxel_delivery_max_window_items=#{summary.max_window_items}",
      "voxel_delivery_queue_count=#{summary.queued_count}",
      "voxel_delivery_queued_bytes=#{summary.queued_bytes}",
      "voxel_delivery_deferred_count=#{summary.deferred_count}",
      "voxel_delivery_sent_count=#{summary.sent_count}",
      "voxel_delivery_control_sent_count=#{summary.control_sent_count}",
      "voxel_delivery_event_sent_count=#{summary.event_sent_count}",
      "voxel_delivery_dropped_count=#{summary.dropped_count}",
      "voxel_delivery_pruned_count=#{summary.pruned_count}",
      "voxel_delivery_resync_required_count=#{summary.resync_required_count}"
    ]
    |> Enum.join("\n")
  end

  defp handle_live_voxel_data(state, frame_kind, payload) do
    scheduler = DeliveryScheduler.ensure(Map.get(state, :voxel_delivery))
    {scheduler, action} = DeliveryScheduler.offer(scheduler, frame_kind, payload)

    state =
      state
      |> Map.put(:voxel_delivery, scheduler)
      |> emit_voxel_delivery_scheduled(action)

    case action.action do
      :send_now ->
        state
        |> send_live_voxel_action(action)
        |> maybe_schedule_voxel_delivery_window()

      _queued_or_dropped ->
        maybe_schedule_voxel_delivery_window(state)
    end
  end

  defp handle_live_voxel_envelope(state, envelope) do
    scheduler = DeliveryScheduler.ensure(Map.get(state, :voxel_delivery))

    {scheduler, action} =
      offer_live_voxel_envelope_with_connection_guard(state, scheduler, envelope)

    state =
      state
      |> Map.put(:voxel_delivery, scheduler)
      |> emit_voxel_delivery_scheduled(action)

    case action.action do
      :send_now ->
        state
        |> send_live_voxel_action(action)
        |> maybe_schedule_voxel_delivery_window()

      _queued_or_dropped ->
        maybe_schedule_voxel_delivery_window(state)
    end
  end

  defp offer_live_voxel_envelope_with_connection_guard(state, scheduler, envelope) do
    case DeliveryEnvelope.normalize(envelope) do
      {:ok, frame} ->
        case validate_live_voxel_envelope_for_connection(state, frame) do
          :ok ->
            DeliveryScheduler.offer_frame(scheduler, frame)

          {:error, reason, attrs} ->
            DeliveryScheduler.reject_envelope(
              scheduler,
              frame
              |> Map.put(:reason, reason)
              |> Map.merge(attrs)
            )
        end

      {:error, frame} ->
        DeliveryScheduler.reject_envelope(scheduler, frame)
    end
  end

  defp validate_live_voxel_envelope_for_connection(
         state,
         %{frame_kind: :object_state_delta} = frame
       ) do
    active_subscriptions =
      frame.affected_chunks
      |> Enum.map(fn chunk_coord ->
        subscription_for_envelope_chunk(state, frame.logical_scene_id, chunk_coord)
      end)
      |> Enum.reject(&is_nil/1)

    case active_subscriptions do
      [] ->
        {:error, :subscription_not_found, %{affected_chunks: frame.affected_chunks}}

      subscriptions ->
        validate_envelope_subscription_set(frame, subscriptions)
    end
  end

  defp validate_live_voxel_envelope_for_connection(state, frame) do
    subscription =
      subscription_for_envelope_chunk(state, frame.logical_scene_id, frame.chunk_coord)

    if is_nil(subscription) do
      {:error, :subscription_not_found, %{}}
    else
      validate_envelope_subscription(frame, subscription)
    end
  end

  defp validate_envelope_subscription_set(frame, subscriptions) do
    Enum.reduce_while(subscriptions, :ok, fn subscription, :ok ->
      case validate_envelope_subscription(frame, subscription) do
        :ok -> {:cont, :ok}
        {:error, reason, attrs} -> {:halt, {:error, reason, attrs}}
      end
    end)
  end

  defp validate_envelope_subscription(frame, subscription) do
    cond do
      Map.get(subscription, :lease_id) != frame.lease_id ->
        {:error, :lease_id_mismatch,
         %{expected_lease_id: Map.get(subscription, :lease_id), envelope_lease_id: frame.lease_id}}

      Map.get(subscription, :owner_epoch) != frame.owner_epoch ->
        {:error, :owner_epoch_mismatch,
         %{
           expected_owner_epoch: Map.get(subscription, :owner_epoch),
           envelope_owner_epoch: frame.owner_epoch
         }}

      Map.has_key?(frame, :region_id) and not envelope_region_matches?(subscription, frame) ->
        {:error, :region_id_mismatch,
         %{
           expected_region_id: Map.get(subscription, :region_id),
           envelope_region_id: frame.region_id
         }}

      envelope_requires_tier_match?(frame) and not envelope_tier_matches?(subscription, frame) ->
        {:error, :tier_mismatch,
         %{expected_tier: Map.get(subscription, :tier), envelope_tier: frame.tier}}

      true ->
        :ok
    end
  end

  defp subscription_for_envelope_chunk(state, logical_scene_id, chunk_coord) do
    state
    |> Map.get(:voxel_subscriptions, %{})
    |> Map.get({logical_scene_id, chunk_coord})
  end

  defp envelope_region_matches?(subscription, frame) do
    region_id = Map.get(subscription, :region_id)
    is_nil(region_id) or region_id == frame.region_id
  end

  defp envelope_requires_tier_match?(%{frame_kind: frame_kind})
       when frame_kind in [:invalidate, :field_region_destroyed],
       do: false

  defp envelope_requires_tier_match?(_frame), do: true

  defp envelope_tier_matches?(subscription, frame) do
    tier = Map.get(subscription, :tier)
    is_nil(tier) or tier == frame.tier
  end

  defp handle_live_voxel_invalidate(state, payload) do
    scheduler = DeliveryScheduler.ensure(Map.get(state, :voxel_delivery))
    {scheduler, action} = DeliveryScheduler.offer(scheduler, :invalidate, payload)

    state =
      state
      |> Map.put(:voxel_delivery, scheduler)
      |> emit_voxel_delivery_scheduled(action)

    case send_encoded(state.socket, {:voxel_chunk_invalidate_payload, payload}) do
      :ok ->
        {state, invalidate_event} = clear_forwarded_chunk_version(state, payload)
        {state, ack_event} = clear_client_ack_version(state, payload)
        state = clear_delivered_invalidate_resync(state, action)

        GateServer.CliObserve.emit(
          "voxel_chunk_invalidate_forwarded",
          Map.merge(
            %{
              connection_pid: self(),
              cid: state.cid,
              bytes: byte_size(payload),
              subscription_count: map_size(state.voxel_subscriptions),
              pruned_delivery_count: Map.get(action, :pruned_count, 0)
            },
            chunk_version_observe(invalidate_event)
          )
        )

        GateServer.CliObserve.emit(
          "voxel_client_ack_invalidate_cleared",
          Map.merge(
            %{
              connection_pid: self(),
              cid: state.cid,
              transport: :tcp
            },
            client_ack_observe(ack_event)
          )
        )

        state
        |> maybe_rebind_cutover_invalidate(invalidate_event)
        |> maybe_schedule_voxel_delivery_window()

      {:error, reason} ->
        emit_voxel_delivery_send_failed(state, :invalidate, payload, reason)
        maybe_schedule_voxel_delivery_window(state)
    end
  end

  defp clear_delivered_invalidate_resync(
         state,
         %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord}
       ) do
    scheduler =
      state
      |> Map.get(:voxel_delivery)
      |> DeliveryScheduler.ensure()
      |> DeliveryScheduler.clear_resync_required(logical_scene_id, chunk_coord)

    Map.put(state, :voxel_delivery, scheduler)
  end

  defp clear_delivered_invalidate_resync(state, _action), do: state

  defp maybe_rebind_cutover_invalidate(state, invalidate_event) do
    case SubscriptionRebind.apply_cutover_invalidation(state, invalidate_event,
           route_fun: &route_voxel_chunk/2,
           subscriber: self(),
           connection_pid: self()
         ) do
      {:ok, next_state, _summary} -> next_state
      {:error, next_state, _summary} -> next_state
    end
  end

  defp send_live_voxel_actions(state, actions) do
    Enum.reduce(actions, state, fn action, acc_state ->
      acc_state
      |> emit_voxel_delivery_scheduled(action)
      |> send_live_voxel_action(action)
    end)
  end

  defp send_live_voxel_action(state, %{frame_kind: :invalidate, payload: payload} = action) do
    case send_encoded(state.socket, {:voxel_chunk_invalidate_payload, payload}) do
      :ok ->
        {state, invalidate_event} = clear_forwarded_chunk_version_from_action(state, action)
        {state, ack_event} = clear_client_ack_version_from_action(state, action)
        state = clear_delivered_invalidate_resync(state, action)

        GateServer.CliObserve.emit(
          "voxel_chunk_invalidate_forwarded",
          Map.merge(
            %{
              connection_pid: self(),
              cid: state.cid,
              bytes: byte_size(payload),
              subscription_count: map_size(state.voxel_subscriptions),
              pruned_delivery_count: Map.get(action, :pruned_count, 0)
            },
            chunk_version_observe(invalidate_event)
          )
        )

        GateServer.CliObserve.emit(
          "voxel_client_ack_invalidate_cleared",
          Map.merge(
            %{
              connection_pid: self(),
              cid: state.cid,
              transport: :tcp
            },
            client_ack_observe(ack_event)
          )
        )

        maybe_rebind_cutover_invalidate(state, invalidate_event)

      {:error, reason} ->
        emit_voxel_delivery_send_failed(state, :invalidate, payload, reason)
        state
    end
  end

  defp send_live_voxel_action(state, %{frame_kind: :snapshot, payload: payload}) do
    case send_encoded(state.socket, {:voxel_chunk_snapshot_payload, payload}) do
      :ok ->
        {state, version_event} = record_forwarded_chunk_version(state, :snapshot, payload)

        GateServer.CliObserve.emit(
          "voxel_chunk_snapshot_forwarded",
          Map.merge(
            %{
              connection_pid: self(),
              cid: state.cid,
              bytes: byte_size(payload),
              subscription_count: map_size(state.voxel_subscriptions)
            },
            chunk_version_observe(version_event)
          )
        )

        state

      {:error, reason} ->
        emit_voxel_delivery_send_failed(state, :snapshot, payload, reason)
        state
    end
  end

  defp send_live_voxel_action(state, %{frame_kind: :delta, payload: payload}) do
    case send_encoded(state.socket, {:voxel_chunk_delta_payload, payload}) do
      :ok ->
        {state, version_event} = record_forwarded_chunk_version(state, :delta, payload)

        GateServer.CliObserve.emit(
          "voxel_chunk_delta_forwarded",
          Map.merge(
            %{
              connection_pid: self(),
              cid: state.cid,
              bytes: byte_size(payload),
              subscription_count: map_size(state.voxel_subscriptions)
            },
            chunk_version_observe(version_event)
          )
        )

        state

      {:error, reason} ->
        emit_voxel_delivery_send_failed(state, :delta, payload, reason)
        state
    end
  end

  defp send_live_voxel_action(state, %{frame_kind: :object_state_delta, payload: payload}) do
    case send_encoded(state.socket, {:voxel_object_state_delta_payload, payload}) do
      :ok ->
        GateServer.CliObserve.emit("tcp_voxel_object_state_delta_forwarded", %{
          connection_pid: self(),
          cid: state.cid,
          bytes: byte_size(payload),
          subscription_count: map_size(state.voxel_subscriptions)
        })

        state

      {:error, reason} ->
        emit_voxel_delivery_send_failed(state, :object_state_delta, payload, reason)
        state
    end
  end

  defp send_live_voxel_action(state, %{frame_kind: :field_region_snapshot, payload: payload}) do
    case send_frame(state.socket, payload) do
      :ok ->
        GateServer.CliObserve.emit("tcp_voxel_field_region_snapshot_forwarded", %{
          connection_pid: self(),
          cid: state.cid,
          bytes: byte_size(payload),
          subscription_count: map_size(state.voxel_subscriptions)
        })

        state

      {:error, reason} ->
        emit_voxel_delivery_send_failed(state, :field_region_snapshot, payload, reason)
        state
    end
  end

  defp send_live_voxel_action(
         state,
         %{frame_kind: :field_region_destroyed, payload: payload} = action
       ) do
    case send_frame(state.socket, payload) do
      :ok ->
        GateServer.CliObserve.emit("tcp_voxel_field_region_destroyed_forwarded", %{
          connection_pid: self(),
          cid: state.cid,
          bytes: byte_size(payload),
          subscription_count: map_size(state.voxel_subscriptions),
          pruned_delivery_count: Map.get(action, :pruned_count, 0)
        })

        state

      {:error, reason} ->
        emit_voxel_delivery_send_failed(state, :field_region_destroyed, payload, reason)
        state
    end
  end

  defp send_live_voxel_action(state, _action), do: state

  defp maybe_schedule_voxel_delivery_window(state) do
    scheduler = DeliveryScheduler.ensure(Map.get(state, :voxel_delivery))
    state = Map.put(state, :voxel_delivery, scheduler)

    if DeliveryScheduler.queued?(scheduler) and is_nil(Map.get(state, :voxel_delivery_timer_ref)) do
      ref =
        Process.send_after(
          self(),
          :voxel_delivery_window,
          DeliveryScheduler.window_interval_ms(scheduler)
        )

      Map.put(state, :voxel_delivery_timer_ref, ref)
    else
      state
    end
  end

  defp clear_queued_voxel_delivery(state, logical_scene_id, chunk_coord) do
    scheduler =
      state
      |> Map.get(:voxel_delivery)
      |> DeliveryScheduler.ensure()
      |> DeliveryScheduler.prune_chunks(logical_scene_id, [chunk_coord])

    Map.put(state, :voxel_delivery, scheduler)
  end

  defp emit_voxel_delivery_scheduled(state, action) do
    GateServer.CliObserve.emit("voxel_live_delivery_scheduled", fn ->
      action
      |> voxel_delivery_action_observe()
      |> Map.merge(%{
        connection_pid: self(),
        cid: state.cid,
        transport: :tcp,
        subscription_count: map_size(state.voxel_subscriptions),
        delivery_summary: DeliveryScheduler.summary(Map.get(state, :voxel_delivery))
      })
    end)

    state
  end

  defp emit_voxel_delivery_send_failed(state, frame_kind, payload, reason) do
    GateServer.CliObserve.emit("voxel_live_delivery_send_failed", %{
      connection_pid: self(),
      cid: state.cid,
      transport: :tcp,
      frame_kind: frame_kind,
      bytes: byte_size(payload),
      reason: reason
    })
  end

  defp voxel_delivery_action_observe(action) do
    Map.take(action, [
      :action,
      :status,
      :frame_kind,
      :logical_scene_id,
      :chunk_coord,
      :object_id,
      :object_version,
      :affected_chunks,
      :region_id,
      :tick_count,
      :destroy_reason,
      :base_chunk_version,
      :chunk_version,
      :tier,
      :stream_class,
      :byte_size,
      :server_version,
      :lease_id,
      :owner_epoch,
      :metadata_source,
      :payload_decode_used,
      :bytes,
      :reason,
      :reason_name,
      :expected_byte_size,
      :actual_byte_size,
      :dropped_count,
      :pruned_count
    ])
  end

  defp record_forwarded_chunk_version(state, frame_kind, payload) do
    ledger = Map.get(state, :forwarded_chunk_versions, ChunkVersionLedger.new())

    case ChunkVersionLedger.record_payload(ledger, frame_kind, payload) do
      {:ok, next_ledger, event} ->
        {Map.put(state, :forwarded_chunk_versions, next_ledger), event}

      {:error, next_ledger, event} ->
        {Map.put(state, :forwarded_chunk_versions, next_ledger), event}
    end
  end

  defp clear_forwarded_chunk_version(state, payload) do
    ledger = Map.get(state, :forwarded_chunk_versions, ChunkVersionLedger.new())

    case ChunkVersionLedger.clear_invalidate_payload(ledger, payload) do
      {:ok, next_ledger, event} ->
        {Map.put(state, :forwarded_chunk_versions, next_ledger), event}

      {:error, next_ledger, event} ->
        {Map.put(state, :forwarded_chunk_versions, next_ledger), event}
    end
  end

  defp clear_forwarded_chunk_version(state, logical_scene_id, chunk_coord) do
    ledger = Map.get(state, :forwarded_chunk_versions, ChunkVersionLedger.new())

    Map.put(
      state,
      :forwarded_chunk_versions,
      ChunkVersionLedger.clear_chunk(ledger, logical_scene_id, chunk_coord)
    )
  end

  defp clear_forwarded_chunk_version_from_action(
         state,
         %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord} = action
       ) do
    ledger = Map.get(state, :forwarded_chunk_versions, ChunkVersionLedger.new())

    previous_version =
      Map.get(ChunkVersionLedger.known_versions(ledger, logical_scene_id), chunk_coord)

    event = %{
      status: if(is_nil(previous_version), do: :not_cached, else: :cleared),
      frame_kind: :invalidate,
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      previous_version: previous_version,
      reason: Map.get(action, :reason),
      reason_name: Map.get(action, :reason_name)
    }

    {Map.put(
       state,
       :forwarded_chunk_versions,
       ChunkVersionLedger.clear_chunk(ledger, logical_scene_id, chunk_coord)
     ), event}
  end

  defp clear_client_ack_version(state, payload) do
    ledger = Map.get(state, :client_ack_versions, ClientAckLedger.new())

    case ClientAckLedger.clear_invalidate_payload(ledger, payload) do
      {:ok, next_ledger, event} ->
        {Map.put(state, :client_ack_versions, next_ledger), event}

      {:error, next_ledger, event} ->
        {Map.put(state, :client_ack_versions, next_ledger), event}
    end
  end

  defp clear_client_ack_version_from_action(
         state,
         %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord} = action
       ) do
    ledger = Map.get(state, :client_ack_versions, ClientAckLedger.new())

    previous_ack_version =
      Map.get(ClientAckLedger.known_versions(ledger, logical_scene_id), chunk_coord)

    event = %{
      status: if(is_nil(previous_ack_version), do: :not_acked, else: :cleared),
      frame_kind: :invalidate,
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      previous_ack_version: previous_ack_version,
      reason: Map.get(action, :reason),
      reason_name: Map.get(action, :reason_name)
    }

    {Map.put(
       state,
       :client_ack_versions,
       ClientAckLedger.clear_chunk(ledger, logical_scene_id, chunk_coord)
     ), event}
  end

  defp client_ack_observe(%{status: :decode_failed} = event) do
    Map.take(event, [:status, :frame_kind, :reason])
  end

  defp client_ack_observe(event) when is_map(event) do
    Map.take(event, [
      :status,
      :frame_kind,
      :logical_scene_id,
      :chunk_coord,
      :previous_ack_version,
      :reason,
      :reason_name
    ])
  end

  defp chunk_version_observe(%{status: :decode_failed} = event) do
    Map.take(event, [:status, :frame_kind, :reason])
  end

  defp chunk_version_observe(event) when is_map(event) do
    Map.take(event, [
      :status,
      :frame_kind,
      :logical_scene_id,
      :chunk_coord,
      :previous_version,
      :base_chunk_version,
      :chunk_version,
      :reason,
      :reason_name
    ])
  end
end
