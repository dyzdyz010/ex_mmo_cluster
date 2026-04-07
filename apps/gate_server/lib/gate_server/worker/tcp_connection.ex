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

  # Public APIs

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
       scene_ref: nil,
       token: nil,
       status: :waiting_auth
     }}
  end

  # ── Outbound: broadcast events from scene_server ──

  @impl true
  def handle_cast({:player_enter, cid, location}, %{socket: socket} = state) do
    {:ok, bin} = GateServer.Codec.encode({:player_enter, cid, location})
    :gen_tcp.send(socket, bin)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_leave, cid}, %{socket: socket} = state) do
    {:ok, bin} = GateServer.Codec.encode({:player_leave, cid})
    :gen_tcp.send(socket, bin)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_move, cid, location}, %{socket: socket} = state) do
    {:ok, bin} = GateServer.Codec.encode({:player_move, cid, location})
    :gen_tcp.send(socket, bin)
    {:noreply, state}
  end

  # ── Inbound: TCP message dispatch ──

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    case GateServer.Codec.decode(data) do
      {:ok, msg} ->
        {:ok, new_state} = dispatch(msg, state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Codec decode error: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tcp_closed, _conn}, %{scene_ref: spid} = state) do
    Logger.error("Socket #{inspect(state.socket, pretty: true)} closed.")

    if spid != nil do
      GenServer.call(spid, :exit)
    end

    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp_error, _conn, err}, %{scene_ref: spid} = state) do
    Logger.error("Socket #{inspect(state.socket, pretty: true)} error: #{err}")
    {:ok, _} = GenServer.call(spid, :exit)

    {:stop, :normal, state}
  end

  # ── Message dispatch ──

  defp dispatch(
         {:movement, _cid, timestamp, location, velocity, acceleration},
         %{scene_ref: spid, cid: cid, socket: socket} = state
       ) do
    {:ok, _} = GenServer.call(spid, {:movement, timestamp, location, velocity, acceleration})

    {:ok, bin} = GateServer.Codec.encode({:movement_result, :ok, 0, cid, location})
    :gen_tcp.send(socket, bin)

    {:ok, state}
  end

  defp dispatch(
         {:enter_scene, cid},
         %{socket: socket} = state
       ) do
    timestamp = :os.system_time(:millisecond)
    scene_node = GenServer.call(GateServer.Interface, :scene_server)

    case GenServer.call(
           {SceneServer.PlayerManager, scene_node},
           {:add_player, cid, self(), timestamp}
         ) do
      {:ok, ppid} ->
        {:ok, {x, y, z}} = GenServer.call(ppid, :get_location)
        {:ok, bin} = GateServer.Codec.encode({:enter_scene_result, :ok, 0, {x, y, z}})
        :gen_tcp.send(socket, bin)
        {:ok, %{state | scene_ref: ppid, cid: cid}}

      _ ->
        {:ok, bin} = GateServer.Codec.encode({:enter_scene_result, :error, 0})
        :gen_tcp.send(socket, bin)
        {:ok, state}
    end
  end

  defp dispatch(:time_sync, %{scene_ref: spid, socket: socket} = state) do
    {:ok, new_timestamp} = GenServer.call(spid, :time_sync)

    if new_timestamp != :end do
      {:ok, bin} = GateServer.Codec.encode(:time_sync_reply)
      :gen_tcp.send(socket, bin)
    end

    {:ok, state}
  end

  defp dispatch({:heartbeat, _timestamp}, %{socket: socket} = state) do
    {:ok, bin} = GateServer.Codec.encode({:heartbeat_reply, :os.system_time(:millisecond)})
    :gen_tcp.send(socket, bin)
    {:ok, state}
  end

  defp dispatch({:auth_request, _username, code}, %{socket: socket} = state) do
    case verify_token(code) do
      {:ok, %{agent: agent}} ->
        {:ok, bin} = GateServer.Codec.encode({:result, :ok, 0})
        :gen_tcp.send(socket, bin)
        {:ok, %{state | agent: agent, status: :authenticated}}

      {:error, _reason} ->
        {:ok, bin} = GateServer.Codec.encode({:result, :error, 0})
        :gen_tcp.send(socket, bin)
        {:ok, state}
    end
  end

  defp dispatch(msg, state) do
    Logger.warning("Unhandled message: #{inspect(msg)}")
    {:ok, state}
  end

  # ── Auth ──

  @spec verify_token(any()) :: any
  defp verify_token(token) do
    auth_server = GenServer.call(GateServer.Interface, :auth_server)

    case GenServer.call({AuthServer.AuthWorker, auth_server.node}, {:verify_token, token}) do
      {:ok, agent} ->
        {:ok, %{agent: agent}}

      {:error, :mismatch} ->
        {:error, :mismatch}

      _ ->
        {:error, :server_error}
    end
  end
end
