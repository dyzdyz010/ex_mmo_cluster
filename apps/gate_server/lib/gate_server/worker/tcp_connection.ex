defmodule GateServer.TcpConnection do
  @moduledoc """
  Client connection.

  Responsible for message delivering/decrypting/encrypting.
  Uses custom binary codec (GateServer.Codec) for all messages.
  """

  use GenServer, restart: :temporary
  require Logger

  @topic {:gate, __MODULE__}
  @scope :connection

  def start_link(socket, opts \\ []) do
    GenServer.start_link(__MODULE__, socket, opts)
  end

  @impl true
  def init(socket) do
    :pg.start_link(@scope)
    :pg.join(@scope, @topic, self())
    Logger.debug("New client connected. socket: #{inspect(socket, pretty: true)}")

    {:ok,
     %{
       socket: socket,
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
  def handle_cast({:player_enter, cid, location}, %{socket: socket} = state) do
    send_encoded(socket, {:player_enter, cid, location})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_leave, cid}, %{socket: socket} = state) do
    send_encoded(socket, {:player_leave, cid})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_move, cid, location}, %{socket: socket} = state) do
    send_encoded(socket, {:player_move, cid, location})
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, %{socket: socket} = state) do
    case GateServer.Codec.decode(data) do
      {:ok, msg} ->
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
    cleanup_scene(state.scene_ref)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp_error, _conn, err}, state) do
    Logger.error("Socket #{inspect(state.socket, pretty: true)} error: #{err}")
    cleanup_scene(state.scene_ref)
    {:stop, :normal, state}
  end

  defp dispatch(
         {:movement, _cid, timestamp, location, velocity, acceleration, request_id},
         %{status: :in_scene, scene_ref: spid, cid: cid, socket: socket} = state
       ) do
    case safe_call(spid, {:movement, timestamp, location, velocity, acceleration}) do
      {:ok, _} -> send_encoded(socket, {:movement_result, :ok, request_id, cid, location})
      {:error, reason} -> send_result_error(socket, reason, request_id)
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
         {:enter_scene, cid, request_id},
         %{status: :authenticated, auth_claims: claims, socket: socket} = state
       ) do
    timestamp = :os.system_time(:millisecond)

    with :ok <- authorize_cid(claims, cid),
         {:ok, scene_node} <- fetch_scene_node(),
         {:ok, ppid} <- add_player(scene_node, cid, timestamp),
         {:ok, {x, y, z}} <- fetch_player_location(ppid) do
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

  defp dispatch({:heartbeat, _timestamp}, %{socket: socket} = state) do
    send_encoded(socket, {:heartbeat_reply, :os.system_time(:millisecond)})
    {:ok, state}
  end

  defp dispatch(
         {:auth_request, username, code, request_id},
         %{status: :waiting_auth, socket: socket} = state
       ) do
    with {:ok, claims} <- verify_token(code),
         :ok <- validate_username_claim(claims, username) do
      auth_context = build_auth_context(username, code, claims)
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

  defp add_player(scene_node, cid, timestamp) do
    case safe_call({SceneServer.PlayerManager, scene_node}, {:add_player, cid, self(), timestamp}) do
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

  defp authorize_cid(nil, _cid), do: {:error, :invalid_state}

  defp authorize_cid(claims, cid) do
    case apply(AuthServer.AuthWorker, :validate_cid, [claims, cid]) do
      :ok -> :ok
      {:error, :cid_mismatch} -> {:error, :cid_mismatch}
      {:error, _reason} -> {:error, :server_error}
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
    send_encoded(socket, {:result, :error, request_id})
  end

  defp send_enter_scene_error(socket, reason, request_id) do
    Logger.warning("Sending enter-scene error: #{inspect(reason)}")
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

  defp send_encoded(socket, message) do
    {:ok, bin} = GateServer.Codec.encode(message)
    :gen_tcp.send(socket, bin)
  end
end
