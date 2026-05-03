defmodule GateServer.WsConnection do
  @moduledoc """
  Per-client GenServer for one browser WebSocket session.

  This mirrors the TCP connection state machine (`waiting_auth -> authenticated -> in_scene`)
  but emits encoded payloads back to the WebSocket owner process instead of writing to a TCP socket.
  """

  use GenServer, restart: :temporary
  require Logger

  @topic {:gate, __MODULE__}
  @scope :connection

  alias SceneServer.Combat.{EffectEvent, Skill}
  alias SceneServer.Movement.{InputFrame, RemoteSnapshot}
  alias SceneServer.Voxel.{NormalBlockData, Types}

  @scene_call_timeout 15_000
  @max_voxel_subscribe_radius 4

  @doc "Starts a browser WebSocket-backed gate session."
  def start_link(owner_pid, opts \\ []) do
    GenServer.start_link(__MODULE__, owner_pid, opts)
  end

  @doc "Forward one binary frame received from the browser WebSocket."
  def receive_frame(connection_pid, payload) when is_pid(connection_pid) and is_binary(payload) do
    GenServer.cast(connection_pid, {:ws_frame, payload})
  end

  @doc "Notify the gate session that the browser WebSocket closed."
  def close(connection_pid, reason \\ :normal) when is_pid(connection_pid) do
    GenServer.cast(connection_pid, {:ws_closed, reason})
  end

  @impl true
  def init(owner_pid) when is_pid(owner_pid) do
    :pg.start_link(@scope)
    :pg.join(@scope, @topic, self())

    GateServer.CliObserve.emit("ws_connection_init", %{
      connection_pid: self(),
      owner_pid: owner_pid
    })

    {:ok,
     %{
       owner_pid: owner_pid,
       cid: -1,
       agent: nil,
       auth_claims: nil,
       auth_username: nil,
       auth_session_id: nil,
       scene_ref: nil,
       token: nil,
       status: :waiting_auth,
       voxel_subscriptions: %{}
     }}
  end

  @impl true
  def handle_cast({:ws_frame, data}, state) do
    GateServer.CliObserve.emit("ws_receive", fn ->
      %{connection_pid: self(), bytes: byte_size(data), status: state.status}
    end)

    case GateServer.Codec.decode(data) do
      {:ok, msg} ->
        GateServer.CliObserve.emit("ws_decoded", fn ->
          %{connection_pid: self(), message: observe_message_summary(msg)}
        end)

        {:ok, new_state} = dispatch(msg, state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("WS codec decode error: #{inspect(reason)}")
        send_result_error(state, reason, 0)
        {:noreply, state}
    end
  end

  def handle_cast({:ws_closed, reason}, state) do
    stop_reason = normalize_close_reason(reason)

    GateServer.CliObserve.emit("ws_closed", %{
      connection_pid: self(),
      cid: state.cid,
      reason: stop_reason
    })

    {:stop, stop_reason, state}
  end

  def handle_cast({:player_enter, cid, location}, state) do
    send_encoded(state, {:player_enter, cid, location})
    {:noreply, state}
  end

  def handle_cast({:player_leave, cid}, state) do
    send_encoded(state, {:player_leave, cid})
    {:noreply, state}
  end

  def handle_cast({:actor_identity, cid, actor_kind, actor_name}, state) do
    send_encoded(state, {:actor_identity, cid, actor_kind, actor_name})
    {:noreply, state}
  end

  def handle_cast({:player_move, snapshot}, state) do
    snapshot = normalize_remote_snapshot(snapshot)

    GateServer.CliObserve.emit("ws_player_move_push", fn ->
      %{
        cid: snapshot.cid,
        server_tick: snapshot.server_tick,
        priority_band: snapshot.priority_band,
        priority_score: snapshot.priority_score,
        observer_distance: snapshot.observer_distance,
        delivery_interval: snapshot.delivery_interval
      }
    end)

    send_encoded(state, player_move_message(snapshot))

    {:noreply, state}
  end

  def handle_cast({:movement_ack, ack}, state) do
    send_encoded(
      state,
      {:movement_ack, ack.ack_seq, ack.auth_tick, ack.cid, ack.position, ack.velocity,
       ack.acceleration, ack.movement_mode, ack.correction_flags, ack.fixed_dt_ms}
    )

    {:noreply, state}
  end

  def handle_cast({:chat_message, cid, username, text}, state) do
    send_encoded(state, {:chat_message, cid, username, text})
    {:noreply, state}
  end

  def handle_cast({:skill_event, cid, skill_id, location}, state) do
    send_encoded(state, {:skill_event, cid, skill_id, location})
    {:noreply, state}
  end

  def handle_cast({:player_state, cid, hp, max_hp, alive}, state) do
    send_encoded(state, {:player_state, cid, hp, max_hp, alive})
    {:noreply, state}
  end

  def handle_cast(
        {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location},
        state
      ) do
    send_encoded(
      state,
      {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location}
    )

    {:noreply, state}
  end

  def handle_cast({:effect_event, %EffectEvent{} = effect_event}, state) do
    send_encoded(
      state,
      {:effect_event, effect_event.source_cid, effect_event.skill_id, effect_event.cue_kind,
       effect_event.origin, effect_event.target_cid, effect_event.target_position,
       effect_event.radius, effect_event.duration_ms}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:voxel_chunk_snapshot_payload, payload}, state) when is_binary(payload) do
    GateServer.CliObserve.emit("ws_voxel_chunk_snapshot_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload),
      subscription_count: map_size(state.voxel_subscriptions)
    })

    send_encoded(state, {:voxel_chunk_snapshot_payload, payload})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_voxel_subscriptions(state)
    cleanup_scene(state.scene_ref)
    :ok
  end

  defp dispatch(
         {:movement_input, frame_params},
         %{status: :in_scene, scene_ref: spid} = state
       ) do
    frame = build_input_frame(frame_params)

    case accept_movement_input(spid, frame) do
      {:ok, ack} -> GenServer.cast(self(), {:movement_ack, ack})
      :accepted -> :ok
      {:error, reason} -> send_result_error(state, reason, frame.seq)
    end

    {:ok, state}
  end

  defp dispatch({:movement_input, frame_params}, state) do
    frame = build_input_frame(frame_params)
    send_result_error(state, :invalid_state, frame.seq)
    {:ok, state}
  end

  defp dispatch(
         {:enter_scene, cid, request_id},
         %{status: :authenticated, auth_claims: claims} = state
       ) do
    timestamp = :os.system_time(:millisecond)

    with :ok <- authorize_cid(claims, cid),
         {:ok, character} <- fetch_authorized_character(claims, cid),
         {:ok, scene_node} <- fetch_scene_node(),
         {:ok, ppid} <- add_player(scene_node, cid, timestamp, build_character_profile(character)),
         {:ok, {x, y, z}} <- fetch_player_location(ppid),
         {:ok, expected_seq} <- fetch_next_input_seq(ppid) do
      send_encoded(state, {:enter_scene_result, :ok, request_id, {x, y, z}, expected_seq})

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
        send_enter_scene_error(state, reason, request_id)
        {:ok, state}
    end
  end

  defp dispatch({:enter_scene, _cid, request_id}, state) do
    send_enter_scene_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch(
         {:time_sync, request_id, client_send_ts},
         %{status: status} = state
       )
       when status in [:authenticated, :in_scene] do
    server_recv_ts = :os.system_time(:millisecond)
    server_send_ts = :os.system_time(:millisecond)

    send_encoded(
      state,
      {:time_sync_reply, request_id, client_send_ts, server_recv_ts, server_send_ts}
    )

    {:ok, state}
  end

  defp dispatch({:time_sync, request_id, _client_send_ts}, state) do
    send_result_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch({:fast_lane_request, request_id}, state) do
    send_encoded(state, {:fast_lane_result, :error, request_id})
    {:ok, state}
  end

  defp dispatch({:heartbeat, _timestamp}, state) do
    send_encoded(state, {:heartbeat_reply, :os.system_time(:millisecond)})
    {:ok, state}
  end

  defp dispatch({:voxel_chunk_subscribe, request}, %{status: :in_scene} = state) do
    GateServer.CliObserve.emit("ws_voxel_chunk_subscribe_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      center_chunk: request.center_chunk
    })

    case subscribe_voxel_chunks(request, state) do
      {:ok, next_state, result} ->
        GateServer.CliObserve.emit("ws_voxel_chunk_subscribe_ok", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          logical_scene_id: request.logical_scene_id,
          chunk_count: result.chunk_count,
          subscription_count: map_size(next_state.voxel_subscriptions)
        })

        {:ok, next_state}

      {:error, reason} ->
        GateServer.CliObserve.emit("ws_voxel_chunk_subscribe_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          reason: reason
        })

        send_encoded(state, voxel_result_error(request, reason))
        {:ok, state}
    end
  end

  defp dispatch({:voxel_chunk_subscribe, request}, state) do
    send_encoded(state, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  defp dispatch({:voxel_chunk_unsubscribe, request}, %{status: :in_scene} = state) do
    {unsubscribed_count, next_state} = unsubscribe_voxel_chunks(request, state)

    GateServer.CliObserve.emit("ws_voxel_chunk_unsubscribe_ok", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      requested_count: length(request.chunks),
      unsubscribed_count: unsubscribed_count,
      subscription_count: map_size(next_state.voxel_subscriptions)
    })

    send_encoded(state, {:result, :ok, request.request_id})
    {:ok, next_state}
  end

  defp dispatch({:voxel_chunk_unsubscribe, request}, state) do
    send_result_error(state, :invalid_state, request.request_id)
    {:ok, state}
  end

  defp dispatch({:voxel_impact_intent, request}, %{status: :in_scene} = state) do
    GateServer.CliObserve.emit("ws_voxel_impact_intent_received", %{
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
        GateServer.CliObserve.emit("ws_voxel_impact_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          chunk_coord: result.chunk_coord,
          chunk_version: result.chunk_version,
          macro: result.macro
        })

        send_encoded(state, voxel_result_ok(request, result))

      {:error, reason} ->
        GateServer.CliObserve.emit("ws_voxel_impact_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          reason: reason
        })

        send_encoded(state, voxel_result_error(request, reason))
    end

    {:ok, state}
  end

  defp dispatch({:voxel_impact_intent, request}, state) do
    send_encoded(state, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  defp dispatch({:voxel_debug_probe, %{request_id: request_id, command: command}}, state) do
    GateServer.CliObserve.emit("ws_voxel_debug_probe_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request_id,
      command: command,
      status: state.status
    })

    send_encoded(
      state,
      {:voxel_debug_probe, %{request_id: request_id, result: voxel_debug_result(command, state)}}
    )

    {:ok, state}
  end

  defp dispatch(
         {:auth_request, username, code, request_id},
         %{status: :waiting_auth} = state
       ) do
    with {:ok, claims} <- verify_token(code),
         :ok <- validate_username_claim(claims, username) do
      auth_context = build_auth_context(username, code, claims)
      send_encoded(state, {:result, :ok, request_id})

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
        send_result_error(state, reason, request_id)
        {:ok, state}
    end
  end

  defp dispatch({:auth_request, _username, _code, request_id}, state) do
    send_result_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch(_msg, state) do
    send_result_error(state, :unknown_message, 0)
    {:ok, state}
  end

  defp send_encoded(state, message) do
    {:ok, bin} = GateServer.Codec.encode(message)
    send(state.owner_pid, {:gate_ws_send, bin})
  end

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

  # See tcp_connection.fetch_next_input_seq for the audit B-S1 / B-SRV1
  # rationale.
  defp fetch_next_input_seq(player_pid) do
    case safe_call(player_pid, :get_next_input_seq, @scene_call_timeout) do
      {:ok, {:ok, seq}} -> {:ok, seq}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  defp cleanup_scene(nil), do: :ok
  defp cleanup_scene(scene_ref), do: safe_call(scene_ref, :exit)

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
    do: %{name: "unknown", position: {1_000.0, 1_000.0, 90.0}}

  defp normalize_position(%{} = position) do
    x = map_float(position, ["x", :x], 1_000.0)
    y = map_float(position, ["y", :y], 1_000.0)
    z = map_float(position, ["z", :z], 90.0)
    {x, y, z}
  end

  defp normalize_position(_position), do: {1_000.0, 1_000.0, 90.0}

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

  defp send_result_error(state, _reason, request_id) do
    send_encoded(state, {:result, :error, request_id})
  end

  defp send_enter_scene_error(state, _reason, request_id) do
    send_encoded(state, {:enter_scene_result, :error, request_id})
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
         {:ok, scene_node} <- fetch_scene_node() do
      attrs = %{
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        chunk_coord: target.chunk_coord,
        lease: Map.fetch!(route, :lease),
        operation: :put_solid_block,
        macro: target.local_macro,
        block: voxel_impact_block(request)
      }

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
         {:ok, scene_node} <- fetch_scene_node() do
      emit_voxel_chunk_subscribe_routed(%{request | center_chunk: chunk_coord}, state, route)

      attrs = %{
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        chunk_coord: chunk_coord,
        subscriber: self(),
        lease: Map.fetch!(route, :lease),
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
            scene_node: scene_node
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

  defp build_input_frame(%{} = frame) do
    if Map.get(frame, :__struct__) == InputFrame do
      frame
    else
      struct(InputFrame, %{
        seq: Map.fetch!(frame, :seq),
        client_tick: Map.fetch!(frame, :client_tick),
        dt_ms: Map.fetch!(frame, :dt_ms),
        input_dir: Map.fetch!(frame, :input_dir),
        speed_scale: Map.fetch!(frame, :speed_scale),
        movement_flags: Map.fetch!(frame, :movement_flags)
      })
    end
  end

  defp normalize_remote_snapshot(%{} = snapshot) do
    if Map.get(snapshot, :__struct__) == RemoteSnapshot do
      snapshot
    else
      raise ArgumentError, "expected remote snapshot map, got: #{inspect(snapshot)}"
    end
  end

  defp normalize_close_reason({:error, :closed}), do: :normal
  defp normalize_close_reason(reason), do: reason

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
