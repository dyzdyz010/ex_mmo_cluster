defmodule GateServer.TcpConnection do
  @moduledoc """
  Client connection.

  Responsible for message delivering/decrypting/encrypting.
  """

  use GenServer
  require Logger

  @topic {:gate, __MODULE__}
  @scope :connection

  def start_link(socket, opts \\ []) do
    GenServer.start_link(__MODULE__, socket, opts)
  end

  def init(socket) do
    :pg.start_link(@scope)
    :pg.join(@scope, @topic, self())
    Logger.debug("New client connected.")
    {:ok, %{socket: socket, agent: nil, status: :waiting_auth}}
  end

  def handle_info({:tcp, _socket, data}, state) do
    Logger.debug(data)
    msg = GateServer.Message.parse(data, state)
    GateServer.Message.handle(msg, state, self())

    Logger.debug("#{inspect(msg, pretty: true)}")
    # result = "You've typed: #{data}"
    # :gen_tcp.send(socket, result)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _conn}, state) do
    Logger.error("Socket #{inspect(state.socket, pretty: true)} closed unexpectly.")
    DynamicSupervisor.terminate_child(GateServer.TcpConnectionSup, self())

    {:stop, :normal, state}
  end

  def handle_cast({:send, data}, state) do
    :gen_tcp.send(state.socket, data)

    {:noreply, state}
  end
end
