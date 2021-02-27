defmodule GateServer.TcpConnection do
  @behaviour GenServer
  require Logger

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
    Logger.debug("New client connected: #{socket}")
    {:ok, %{socket: socket}}
  end

  def handle_info({:tcp, socket, data}, state) do
    Logger.debug(data)
    result = "You'v typed: #{data}"
    :gen_tcp.send(socket, result)
    {:noreply, state}
  end
end
