defmodule GateServer.TcpConnection do
  @behaviour GenServer
  require Logger

  @topic {:gate, __MODULE__}
  @scope :connection

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(socket, opts \\ []) do
    GenServer.start_link(__MODULE__, socket, opts)
  end

  def init(socket) do
    :pg.start_link(@scope)
    :pg.join(@scope, @topic, self())
    Logger.debug("New client connected.")
    {:ok, %{socket: socket}}
  end

  def handle_info({:tcp, socket, data}, state) do
    Logger.debug(data)
    result = "You've typed: #{data}"
    :gen_tcp.send(socket, result)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _conn}, state) do
    Logger.error("Socket #{inspect(state.socket, pretty: true)} closed unexpectly.")
    DynamicSupervisor.terminate_child(GateServer.TcpConnectionSup, self())

    {:stop, :normal, state}
  end
end
