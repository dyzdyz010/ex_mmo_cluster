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

  alias SceneServer.Combat.CastRequest
  alias SceneServer.Combat.{EffectEvent, Skill}
  alias SceneServer.Movement.{InputFrame, RemoteSnapshot}
  alias SceneServer.Voxel.{NormalBlockData, PrefabRaster, Types}

  @scene_call_timeout 15_000
  @max_voxel_subscribe_radius 4

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
       voxel_subscriptions: %{}
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

      GateServer.UdpAcceptor.send_to_peer(udp_peer, player_move_message(snapshot))
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

      send_encoded(socket, player_move_message(snapshot))
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

    message =
      {:movement_ack, ack.ack_seq, ack.auth_tick, ack.cid, ack.position, ack.velocity,
       ack.acceleration, ack.movement_mode, ack.correction_flags, ack.fixed_dt_ms}

    if udp_peer do
      GateServer.UdpAcceptor.send_to_peer(udp_peer, message)
    else
      send_encoded(socket, message)
    end

    {:noreply, state}
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
  def handle_info({:voxel_chunk_snapshot_payload, payload}, %{socket: socket} = state)
      when is_binary(payload) do
    GateServer.CliObserve.emit("voxel_chunk_snapshot_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload),
      subscription_count: map_size(state.voxel_subscriptions)
    })

    send_encoded(socket, {:voxel_chunk_snapshot_payload, payload})
    {:noreply, state}
  end

  def handle_info({:voxel_chunk_delta_payload, payload}, %{socket: socket} = state)
      when is_binary(payload) do
    GateServer.CliObserve.emit("voxel_chunk_delta_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload),
      subscription_count: map_size(state.voxel_subscriptions)
    })

    send_encoded(socket, {:voxel_chunk_delta_payload, payload})
    {:noreply, state}
  end

  def handle_info({:voxel_chunk_invalidate_payload, payload}, %{socket: socket} = state)
      when is_binary(payload) do
    GateServer.CliObserve.emit("voxel_chunk_invalidate_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload),
      subscription_count: map_size(state.voxel_subscriptions)
    })

    send_encoded(socket, {:voxel_chunk_invalidate_payload, payload})
    {:noreply, state}
  end

  # Phase 4-bis (D7):forward 0x6C ObjectStateDelta from ChunkProcess fan-out
  # to the TCP socket. ObjectRegistry encoded the binary once;ChunkProcess
  # cast it into our mailbox via `send/2`;we just prefix the opcode and
  # write to the socket.
  def handle_info({:voxel_object_state_delta_payload, payload}, %{socket: socket} = state)
      when is_binary(payload) do
    GateServer.CliObserve.emit("tcp_voxel_object_state_delta_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload),
      subscription_count: map_size(state.voxel_subscriptions)
    })

    send_encoded(socket, {:voxel_object_state_delta_payload, payload})
    {:noreply, state}
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
        Logger.error("Codec decode error: #{inspect(reason)}")
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
    cleanup_scene(state.scene_ref)
    cleanup_fast_lane(self())
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp_error, _conn, err}, state) do
    Logger.error("Socket #{inspect(state.socket, pretty: true)} error: #{err}")

    GateServer.CliObserve.emit("tcp_error", %{connection_pid: self(), cid: state.cid, reason: err})

    cleanup_voxel_subscriptions(state)
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
         %{status: :in_scene, scene_ref: spid, cid: cid, auth_username: username, socket: socket} =
           state
       ) do
    GateServer.CliObserve.emit("chat_received", %{
      connection_pid: self(),
      cid: cid,
      username: username,
      request_id: request_id,
      text: text
    })

    case safe_call(spid, {:chat_say, cid, username || "anonymous", text}, @scene_call_timeout) do
      {:ok, {:ok, _}} -> send_encoded(socket, {:result, :ok, request_id})
      {:ok, _} -> send_result_error(socket, :server_error, request_id)
      {:error, reason} -> send_result_error(socket, reason, request_id)
    end

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

      {:ok,
       %{
         state
         | scene_ref: ppid,
           cid: cid,
           status: :in_scene,
           agent: with_active_cid(state.agent, cid)
       }}
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

  defp fetch_scene_node_for_owner(owner_scene_instance_ref) do
    case safe_call(GateServer.Interface, {:scene_server_for_owner, owner_scene_instance_ref}) do
      {:ok, nil} -> {:error, :scene_unavailable}
      {:ok, scene_node} -> {:ok, scene_node}
      {:error, _reason} -> fetch_scene_node()
    end
  end

  defp fetch_world_node do
    case safe_call(GateServer.Interface, :world_server) do
      {:ok, nil} -> {:error, :world_unavailable}
      {:ok, world_node} -> {:ok, world_node}
      {:error, _reason} -> {:error, :world_unavailable}
    end
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
    do: %{name: "unknown", position: {750.0, 750.0, 100.0}}

  # Default spawn over the DevSeed 16×16 stone platform on chunk (0,0,0).
  # See `ws_connection.ex` for the browser-axis derivation; kept duplicated here so
  # the legacy TCP path stays in lock-step with the WebSocket path without
  # introducing a new shared module.
  defp normalize_position(%{} = position) do
    x = map_float(position, ["x", :x], 750.0)
    y = map_float(position, ["y", :y], 750.0)
    z = map_float(position, ["z", :z], 100.0)
    {x, y, z}
  end

  defp normalize_position(_position), do: {750.0, 750.0, 100.0}

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
    Logger.warning("Sending generic result error: #{inspect(reason)}")

    GateServer.CliObserve.emit("send_result_error", %{
      socket: socket,
      request_id: request_id,
      reason: reason
    })

    send_encoded(socket, {:result, :error, request_id})
  end

  defp send_enter_scene_error(socket, reason, request_id) do
    Logger.warning("Sending enter-scene error: #{inspect(reason)}")

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

  defp apply_voxel_impact_intent(request, state) do
    with :ok <- authorize_voxel_impact_intent(request, state),
         {:ok, target} <- voxel_impact_target(request),
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

  defp fetch_scene_node_for_route(route) do
    route
    |> Map.fetch!(:lease)
    |> Map.fetch!(:owner_scene_instance_ref)
    |> fetch_scene_node_for_owner()
  end

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
         {:ok, cells} <-
           PrefabRaster.rasterize(
             request.blueprint_id,
             request.blueprint_version,
             request.anchor_world_micro,
             request.rotation
           ) do
      run_prefab_transaction(cells, request, state)
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

  # Phase 3: 0x67 prefab now goes through World's TransactionCoordinator +
  # TransactionExecutor. Cells are grouped by chunk_coord into one batch per
  # chunk; the whole prefab commits atomically (any chunk's prepare or apply
  # failure rolls back every fence) or aborts atomically (no partial writes).
  defp run_prefab_transaction([], _request, _state) do
    {:ok, %{cell_count: 0, chunk_count: 0, max_chunk_version: 0}}
  end

  defp run_prefab_transaction(cells, request, state) do
    total = length(cells)

    with {:ok, plan} <- build_prefab_plan(cells, request, state),
         {:ok, coordinator_ref} <- locate_voxel_transaction_coordinator(),
         {:ok, transaction} <-
           coordinator_begin_transaction(coordinator_ref, plan, request),
         {:ok, executor_result} <-
           executor_execute(coordinator_ref, transaction, plan) do
      finalize_prefab_outcome(executor_result, plan, total)
    else
      {:error, reason} ->
        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: total}}
    end
  end

  # Group cells by chunk_coord, resolve route on the FIRST chunk, then reuse
  # that lease + scene_node for every other chunk. Phase 3 D6 limits prefabs
  # to one region / one lease per dispatch, so a uniform lease is the only
  # valid case; if a chunk actually belongs to a different lease the
  # downstream BuildTransactionApplier.prepare rejects it during the
  # transaction and the executor aborts the whole prefab.
  defp build_prefab_plan(cells, request, state) do
    cells_by_chunk = Enum.group_by(cells, & &1.chunk_coord)
    chunk_coords = Map.keys(cells_by_chunk)

    case chunk_coords do
      [first_chunk | _] ->
        with {:ok, route} <- route_voxel_chunk(request.logical_scene_id, first_chunk),
             {:ok, scene_node} <- fetch_scene_node_for_route(route) do
          lease = Map.fetch!(route, :lease)

          GateServer.CliObserve.emit("voxel_prefab_routed", fn ->
            %{
              connection_pid: self(),
              cid: state.cid,
              request_id: request.request_id,
              logical_scene_id: request.logical_scene_id,
              blueprint_id: request.blueprint_id,
              chunk_count: length(chunk_coords),
              cell_count: length(cells),
              region_id: lease.region_id,
              lease_id: lease.lease_id,
              owner_scene_instance_ref: lease.owner_scene_instance_ref,
              owner_epoch: lease.owner_epoch,
              scene_node: scene_node
            }
          end)

          intents_by_chunk = build_prefab_intents_by_chunk(cells_by_chunk, request, lease)

          {:ok,
           %{
             lease: lease,
             scene_node: scene_node,
             intents_by_chunk: intents_by_chunk,
             chunk_coords: chunk_coords
           }}
        end

      [] ->
        {:error, :empty_prefab}
    end
  end

  defp build_prefab_intents_by_chunk(cells_by_chunk, request, lease) do
    Map.new(cells_by_chunk, fn {chunk_coord, cells_in_chunk} ->
      intents =
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
            opts: []
          }
        end)

      {chunk_coord, intents}
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
    lease = plan.lease

    attrs = %{
      logical_scene_id: request.logical_scene_id,
      parcel_id: Map.get(request, :parcel_id, 0),
      reservation_id: prefab_reservation_id(request),
      decision_version: 1,
      participants: [
        %{
          region_id: lease.region_id,
          lease_id: lease.lease_id,
          owner_scene_instance_ref: lease.owner_scene_instance_ref,
          owner_epoch: lease.owner_epoch,
          affected_chunks: plan.chunk_coords
        }
      ]
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

  defp executor_execute(coordinator_ref, transaction, plan) do
    intents_by_participant = %{
      {plan.lease.region_id, plan.lease.lease_id} => plan.intents_by_chunk
    }

    scene_opts = [
      chunk_directory: {SceneServer.Voxel.ChunkDirectory, plan.scene_node}
    ]

    try do
      WorldServer.Voxel.TransactionExecutor.execute(
        coordinator_ref,
        transaction,
        intents_by_participant,
        scene_opts: scene_opts
      )
    catch
      :exit, _reason -> {:error, :executor_crashed}
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
    Enum.find_value(prepare_results, fn
      {_participant, {:error, reason}} -> reason
      _ -> nil
    end)
  end

  defp unique_prefab_transaction_id(request) do
    unique = System.unique_integer([:positive, :monotonic])
    "prefab-#{request.request_id}-#{unique}"
  end

  defp prefab_reservation_id(request) do
    "prefab-reservation-#{request.request_id}"
  end

  defp emit_voxel_chunk_subscribe_routed(request, state, route) do
    assignment = Map.fetch!(route, :assignment)
    lease = Map.fetch!(route, :lease)

    GateServer.CliObserve.emit("voxel_chunk_subscribe_routed", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      center_chunk: request.center_chunk,
      region_id: assignment.region_id,
      lease_id: lease.lease_id,
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch
    })
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
    with :ok <- validate_voxel_subscribe_radius(request.radius_l_inf) do
      coords = voxel_subscription_coords(request.center_chunk, request.radius_l_inf)
      known_versions = voxel_known_versions(Map.get(request, :known, []))

      Enum.reduce_while(coords, {:ok, state, []}, fn chunk_coord, {:ok, acc_state, new_keys} ->
        case subscribe_voxel_chunk(request, chunk_coord, known_versions, acc_state) do
          {:ok, next_state, subscription} when is_map(subscription) ->
            {:cont, {:ok, next_state, [subscription | new_keys]}}

          {:ok, next_state, nil} ->
            {:cont, {:ok, next_state, new_keys}}

          {:error, reason} ->
            rollback_voxel_subscriptions(new_keys)
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, next_state, _new_keys} ->
          {:ok, next_state, %{chunk_count: length(coords)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp subscribe_voxel_chunk(request, chunk_coord, known_versions, state) do
    with {:ok, route} <- route_voxel_chunk(request.logical_scene_id, chunk_coord),
         {:ok, scene_node} <- fetch_scene_node_for_route(route) do
      emit_voxel_chunk_subscribe_routed(%{request | center_chunk: chunk_coord}, state, route)
      lease = Map.fetch!(route, :lease)

      attrs = %{
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        chunk_coord: chunk_coord,
        subscriber: self(),
        lease: lease,
        send_snapshot?: request.want_snapshot,
        known_version: Map.get(known_versions, chunk_coord)
      }

      case safe_call(
             {SceneServer.Voxel.ChunkDirectory, scene_node},
             {:subscribe, attrs},
             @scene_call_timeout
           ) do
        {:ok, {:ok, _payload}} ->
          key = voxel_subscription_key(request.logical_scene_id, chunk_coord)
          already_subscribed? = Map.has_key?(state.voxel_subscriptions, key)

          subscription = %{
            logical_scene_id: request.logical_scene_id,
            chunk_coord: chunk_coord,
            request_id: request.request_id,
            scene_node: scene_node,
            region_id: lease.region_id,
            lease_id: lease.lease_id,
            owner_scene_instance_ref: lease.owner_scene_instance_ref,
            owner_epoch: lease.owner_epoch
          }

          next_state = put_in(state.voxel_subscriptions[key], subscription)
          {:ok, next_state, if(already_subscribed?, do: nil, else: subscription)}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:ok, _other} ->
          {:error, :scene_unavailable}

        {:error, _reason} ->
          {:error, :scene_unavailable}
      end
    end
  end

  defp unsubscribe_voxel_chunks(request, state) do
    Enum.reduce(request.chunks, {0, state}, fn chunk_coord, {count, acc_state} ->
      case unsubscribe_voxel_chunk(request.logical_scene_id, chunk_coord, acc_state) do
        {:ok, next_state} -> {count + 1, next_state}
        :not_subscribed -> {count, acc_state}
      end
    end)
  end

  defp unsubscribe_voxel_chunk(logical_scene_id, chunk_coord, state) do
    key = voxel_subscription_key(logical_scene_id, chunk_coord)

    case Map.pop(state.voxel_subscriptions, key) do
      {nil, _subscriptions} ->
        :not_subscribed

      {subscription, subscriptions} ->
        scene_unsubscribe(subscription)
        {:ok, %{state | voxel_subscriptions: subscriptions}}
    end
  end

  defp cleanup_voxel_subscriptions(%{voxel_subscriptions: subscriptions}) do
    Enum.each(subscriptions, fn {_key, subscription} -> scene_unsubscribe(subscription) end)
    :ok
  end

  defp rollback_voxel_subscriptions(subscriptions) do
    Enum.each(subscriptions, &scene_unsubscribe/1)
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

  defp voxel_subscription_coords({cx, cy, cz}, radius) do
    for x <- (cx - radius)..(cx + radius),
        y <- (cy - radius)..(cy + radius),
        z <- (cz - radius)..(cz + radius) do
      {x, y, z}
    end
  end

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
    {:ok, bin} = GateServer.Codec.encode(message)
    :gen_tcp.send(socket, bin)
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
    [
      "voxel_sync=server-authoritative",
      "voxel_truth_source=server",
      "connection_status=#{state.status}",
      "cid=#{state.cid}",
      "scene_attached=#{not is_nil(state.scene_ref)}",
      "voxel_subscription_count=#{map_size(state.voxel_subscriptions)}",
      "voxel_subscriptions=#{inspect(state.voxel_subscriptions |> Map.keys() |> Enum.take(16))}",
      "voxel_subscription_routes=#{inspect(voxel_subscription_debug(state.voxel_subscriptions))}",
      "confirmed_chunk_versions={}",
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
         } = snapshot
       ) do
    {:player_move, snapshot.cid, snapshot.server_tick, snapshot.position, snapshot.velocity,
     snapshot.acceleration, snapshot.movement_mode}
  end

  defp player_move_message(%RemoteSnapshot{} = snapshot) do
    {:player_move, snapshot.cid, snapshot.server_tick, snapshot.position, snapshot.velocity,
     snapshot.acceleration, snapshot.movement_mode, snapshot.priority_band,
     snapshot.priority_score, snapshot.observer_distance, snapshot.delivery_interval}
  end
end
