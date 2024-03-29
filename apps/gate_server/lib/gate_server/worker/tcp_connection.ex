defmodule GateServer.TcpConnection do
  @moduledoc """
  Client connection.

  Responsible for message delivering/decrypting/encrypting.
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
       packet_id: 0,
       agent: nil,
       scene_ref: nil,
       token: nil,
       status: :waiting_auth
     }}
  end

  @impl true
  def handle_cast({:send_data, data}, %{socket: socket, packet_id: packet_id} = state) do
    send_data(data, socket, packet_id)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_enter, cid, location}, state) do
    GateServer.Message.send_player_enter(cid, location, self())

    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_leave, cid}, state) do
    GateServer.Message.send_player_leave(cid, self())

    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_move, cid, location}, state) do
    GateServer.Message.send_player_move(cid, location, self())

    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    {:ok, msg} = GateServer.Message.decode(data)
    {:ok, new_state} = GateServer.Message.dispatch(msg, state, self())

    # Logger.debug(data)
    # result = "You've typed: #{data}"
    # :ok = :gen_tcp.send(socket, result)
    # hb = %Heartbeat{timestamp: "200"}
    # packet = %Packet{id: 1, payload: {:heartbeat, hb}}
    # {:ok, senddata} = GateServer.Message.encode(packet)
    # send_data(senddata, socket)

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

  defp send_data(payload, socket, packet_id) do
    packet = %Packet{id: packet_id, timestamp: :os.system_time(:millisecond), payload: payload}
    {:ok, packet_data} = GateServer.Message.encode(packet)
    Logger.debug("数据：#{inspect(packet, pretty: true)}")
    _result = :gen_tcp.send(socket, packet_data)

    # Logger.debug(
    #   "TCP 发送数据结果：#{inspect(result, pretty: true)}, socket: #{inspect(socket, pretty: true)}"
    # )
  end
end
