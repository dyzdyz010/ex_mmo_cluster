defmodule GateServer.TcpConnection do
  @moduledoc """
  Client connection.

  Responsible for message delivering/decrypting/encrypting.
  Supports both custom binary codec (new) and protobuf (legacy) protocols.
  The first byte of each message determines the protocol:
  - 0x01–0x7F: custom binary codec (GateServer.Codec)
  - Otherwise: legacy protobuf (GateServer.Message)
  """

  use GenServer, restart: :temporary
  require Logger

  @topic {:gate, __MODULE__}
  @scope :connection

  # Custom codec message type range (client → server)
  @codec_range_start 0x01
  @codec_range_end 0x7F

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
       packet_id: 0,
       agent: nil,
       scene_ref: nil,
       token: nil,
       status: :waiting_auth
     }}
  end

  # ── Outbound: send binary-encoded data to client ──

  @impl true
  def handle_cast({:send_binary, bin_data}, %{socket: socket} = state) do
    :gen_tcp.send(socket, bin_data)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_data, data}, %{socket: socket, packet_id: packet_id} = state) do
    send_data_legacy(data, socket, packet_id)
    {:noreply, state}
  end

  # ── Outbound: broadcast events from scene_server (use new codec) ──

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
  def handle_info({:tcp, _socket, <<type::8, _rest::binary>> = data}, state)
      when type >= @codec_range_start and type <= @codec_range_end do
    # Custom binary codec path
    case GateServer.Codec.decode(data) do
      {:ok, msg} ->
        {:ok, new_state} = dispatch_codec(msg, state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Codec decode error: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    # Legacy protobuf path
    {:ok, msg} = GateServer.Message.decode(data)
    {:ok, new_state} = GateServer.Message.dispatch(msg, state, self())
    {:noreply, new_state}
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

  # ── Codec dispatch: handle decoded custom messages ──

  defp dispatch_codec(
         {:movement, _cid, timestamp, location, velocity, acceleration},
         %{scene_ref: spid, cid: cid, socket: socket} = state
       ) do
    {:ok, _} = GenServer.call(spid, {:movement, timestamp, location, velocity, acceleration})

    {:ok, bin} = GateServer.Codec.encode({:movement_result, :ok, 0, cid, location})
    :gen_tcp.send(socket, bin)

    {:ok, state}
  end

  defp dispatch_codec(
         {:enter_scene, cid},
         %{socket: socket} = state
       ) do
    timestamp = :os.system_time(:millisecond)

    case GenServer.call(
           {SceneServer.PlayerManager, :"scene1@127.0.0.1"},
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

  defp dispatch_codec(:time_sync, %{scene_ref: spid, socket: socket} = state) do
    {:ok, new_timestamp} = GenServer.call(spid, :time_sync)

    if new_timestamp != :end do
      {:ok, bin} = GateServer.Codec.encode(:time_sync_reply)
      :gen_tcp.send(socket, bin)
    end

    {:ok, state}
  end

  defp dispatch_codec({:heartbeat, _timestamp}, %{socket: socket} = state) do
    {:ok, bin} = GateServer.Codec.encode({:heartbeat_reply, :os.system_time(:millisecond)})
    :gen_tcp.send(socket, bin)
    {:ok, state}
  end

  defp dispatch_codec(msg, state) do
    Logger.warning("Unhandled codec message: #{inspect(msg)}")
    {:ok, state}
  end

  # ── Auth (unchanged) ──

  @doc """
  Verify client token from auth_server
  """
  @spec verify_token(any()) :: any
  def verify_token(token) do
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

  # ── Legacy protobuf send (used during transition) ──

  defp send_data_legacy(payload, socket, packet_id) do
    packet = %Packet{id: packet_id, timestamp: :os.system_time(:millisecond), payload: payload}
    {:ok, packet_data} = GateServer.Message.encode(packet)
    Logger.debug("数据：#{inspect(packet, pretty: true)}")
    :gen_tcp.send(socket, packet_data)
  end
end
