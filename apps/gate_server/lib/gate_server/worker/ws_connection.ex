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

  alias SceneServer.Combat.EffectEvent
  alias SceneServer.Movement.{InputFrame, RemoteSnapshot}

  @scene_call_timeout 15_000

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
       status: :waiting_auth
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
  def terminate(_reason, state) do
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

  defp observe_message_summary({:auth_request, username, _token, request_id}) do
    %{type: :auth_request, username: username, request_id: request_id, token_redacted?: true}
  end

  defp observe_message_summary({:movement_input, frame}) do
    %{type: :movement_input, seq: frame.seq, client_tick: frame.client_tick}
  end

  defp observe_message_summary(message), do: message

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
