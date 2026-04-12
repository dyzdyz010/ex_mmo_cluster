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
    :pg.start_link(@scope)
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
       status: :waiting_auth
     }}
  end

  @impl true
  def handle_cast({:player_enter, cid, location}, %{socket: socket} = state) do
    GateServer.CliObserve.emit("tcp_player_enter_push", %{cid: cid, location: location})
    send_encoded(socket, {:player_enter, cid, location})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_leave, cid}, %{socket: socket} = state) do
    GateServer.CliObserve.emit("tcp_player_leave_push", %{cid: cid})
    send_encoded(socket, {:player_leave, cid})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_move, cid, location, sequence}, %{socket: socket} = state) do
    {udp_peer, state} = resolve_udp_peer(state)

    if udp_peer do
      GateServer.CliObserve.emit("player_move_push_udp", fn ->
        %{cid: cid, sequence: sequence, location: location, peer: udp_peer}
      end)

      GateServer.UdpAcceptor.send_to_peer(udp_peer, {:player_move, cid, sequence, location})
    else
      GateServer.CliObserve.emit("player_move_push_tcp", fn ->
        %{cid: cid, sequence: sequence, location: location}
      end)

      send_encoded(socket, {:player_move, cid, sequence, location})
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
    Logger.error("Socket #{inspect(state.socket, pretty: true)} closed.")
    GateServer.CliObserve.emit("tcp_closed", %{connection_pid: self(), cid: state.cid})
    cleanup_scene(state.scene_ref)
    cleanup_fast_lane(self())
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp_error, _conn, err}, state) do
    Logger.error("Socket #{inspect(state.socket, pretty: true)} error: #{err}")

    GateServer.CliObserve.emit("tcp_error", %{connection_pid: self(), cid: state.cid, reason: err})

    cleanup_scene(state.scene_ref)
    cleanup_fast_lane(self())
    {:stop, :normal, state}
  end

  @impl true
  def handle_call(
        {:udp_movement, _request_id, cid, timestamp, location, velocity, acceleration},
        _from,
        %{status: :in_scene, scene_ref: spid, cid: active_cid} = state
      ) do
    GateServer.CliObserve.emit("udp_movement_received", fn ->
      %{
        connection_pid: self(),
        cid: cid,
        active_cid: active_cid,
        timestamp: timestamp,
        location: location,
        velocity: velocity,
        acceleration: acceleration
      }
    end)

    reply =
      cond do
        cid != active_cid ->
          {:error, :cid_mismatch}

        true ->
          acknowledge_movement(spid, active_cid, timestamp, location, velocity, acceleration)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(
        {:udp_movement, _request_id, _cid, _timestamp, _location, _velocity, _acceleration},
        _from,
        state
      ) do
    {:reply, {:error, :invalid_state}, state}
  end

  defp dispatch(
         {:movement, _cid, timestamp, location, velocity, acceleration, request_id},
         %{status: :in_scene, scene_ref: spid, cid: cid, socket: socket} = state
       ) do
    GateServer.CliObserve.emit("tcp_movement_received", fn ->
      %{
        connection_pid: self(),
        cid: cid,
        request_id: request_id,
        timestamp: timestamp,
        location: location,
        velocity: velocity
      }
    end)

    case acknowledge_movement(spid, cid, timestamp, location, velocity, acceleration) do
      {:ok, ack_cid, authoritative_location} ->
        GateServer.CliObserve.emit("tcp_movement_ack", fn ->
          %{
            connection_pid: self(),
            cid: ack_cid,
            request_id: request_id,
            authoritative_location: authoritative_location
          }
        end)

        send_encoded(
          socket,
          {:movement_result, :ok, request_id, ack_cid, authoritative_location}
        )

      {:error, reason} ->
        GateServer.CliObserve.emit("tcp_movement_error", fn ->
          %{connection_pid: self(), cid: cid, request_id: request_id, reason: reason}
        end)

        send_result_error(socket, reason, request_id)
    end

    {:ok, state}
  end

  defp dispatch(
         {:movement, _cid, _timestamp, _location, _velocity, _acceleration, request_id},
         state
       ) do
    send_result_error(state.socket, :invalid_state, request_id)
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

    case safe_call(spid, {:chat_say, cid, username || "anonymous", text}) do
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
         {:skill_cast, skill_id, request_id},
         %{status: :in_scene, scene_ref: spid, socket: socket} = state
       ) do
    GateServer.CliObserve.emit("skill_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request_id,
      skill_id: skill_id
    })

    case safe_call(spid, {:cast_skill, skill_id}) do
      {:ok, {:ok, _location}} -> send_encoded(socket, {:result, :ok, request_id})
      {:ok, {:error, reason}} -> send_result_error(socket, reason, request_id)
      {:ok, _} -> send_result_error(socket, :server_error, request_id)
      {:error, reason} -> send_result_error(socket, reason, request_id)
    end

    {:ok, state}
  end

  defp dispatch({:skill_cast, _skill_id, request_id}, state) do
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
         {:ok, ppid} <- add_player(scene_node, cid, timestamp, build_character_profile(character)),
         {:ok, {x, y, z}} <- fetch_player_location(ppid) do
      GateServer.CliObserve.emit("enter_scene_ok", %{
        connection_pid: self(),
        cid: cid,
        request_id: request_id,
        scene_ref: ppid,
        location: {x, y, z}
      })

      send_encoded(socket, {:enter_scene_result, :ok, request_id, {x, y, z}})

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

  defp add_player(scene_node, cid, timestamp, character_profile) do
    case safe_call(
           {SceneServer.PlayerManager, scene_node},
           {:add_player, cid, self(), timestamp, character_profile}
         ) do
      {:ok, {:ok, ppid}} -> {:ok, ppid}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  defp fetch_player_location(player_pid) do
    case safe_call(player_pid, :get_location) do
      {:ok, {:ok, location}} -> {:ok, location}
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

  defp safe_call(nil, _message), do: {:error, :unavailable}

  defp safe_call(server, message) do
    try do
      {:ok, GenServer.call(server, message)}
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

  defp acknowledge_movement(spid, cid, timestamp, location, velocity, acceleration) do
    with {:ok, {:ok, _movement_applied}} <-
           safe_call(spid, {:movement, timestamp, location, velocity, acceleration}),
         {:ok, authoritative_location} <- fetch_player_location(spid) do
      {:ok, cid, authoritative_location}
    else
      {:error, reason} -> {:error, reason}
      {:ok, _other} -> {:error, :scene_unavailable}
    end
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

  defp send_encoded(socket, message) do
    {:ok, bin} = GateServer.Codec.encode(message)
    :gen_tcp.send(socket, bin)
  end

  defp observe_message_summary({:auth_request, username, _token, request_id}) do
    %{type: :auth_request, username: username, request_id: request_id, token_redacted?: true}
  end

  defp observe_message_summary(message), do: message
end
