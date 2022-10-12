defmodule GateServer.TcpConnection do
  @moduledoc """
  Client connection.

  Responsible for message delivering/decrypting/encrypting.
  """

  use GenServer
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
    Logger.debug("New client connected.")
    {:ok, %{socket: socket, agent: nil, token: nil, status: :waiting_auth}}
  end

  @impl true
  def handle_cast({:send_data, data}, %{socket: socket} = state) do
    send_data(data, socket)

    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, %{socket: socket} = state) do
    Logger.debug(data)
    {:ok, _msg} = GateServer.Message.decode(data)
    # result = GateServer.Message.handle(msg, state, self())
    # result = "You've typed: #{data}"
    # :ok = :gen_tcp.send(socket, data)
    hb = %Heartbeat{timestamp: "200"}
    packet = %Packet{id: 1, payload: {:heartbeat, hb}}
    {:ok, senddata} = GateServer.Message.encode(packet)
    send_data(senddata, socket)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_closed, _conn}, state) do
    Logger.error("Socket #{inspect(state.socket, pretty: true)} closed unexpectly.")
    DynamicSupervisor.terminate_child(GateServer.TcpConnectionSup, self())

    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp_error, _conn, err}, state) do
    Logger.error("Socket #{inspect(state.socket, pretty: true)} error: #{err}")
    DynamicSupervisor.terminate_child(GateServer.TcpConnectionSup, self())

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
      _ -> {:error, :server_error}
    end
  end

  defp send_data(data, socket) do
    :gen_tcp.send(socket, data)
  end
end
