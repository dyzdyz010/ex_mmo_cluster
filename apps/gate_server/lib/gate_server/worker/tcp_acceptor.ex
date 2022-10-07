defmodule GateServer.TcpAcceptor do
  @moduledoc """
  Listen to port and accept connections.
  """

  @behaviour GenServer

  require Logger

  @port 29000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  def init(_opts) do
    {:ok, %{}, 0}
  end

  def handle_info(:timeout, state) do
    GenServer.cast(__MODULE__, :listen)
    {:noreply, state}
  end

  def handle_cast(:listen, _state) do
    listen(@port)
  end

  defp listen(port) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: 0, active: true, reuseaddr: true])

    Logger.debug("Accepting connections on port #{port}")
    loop_acceptor(socket)
  end

  defp loop_acceptor(socket) do
    {:ok, client} = :gen_tcp.accept(socket)

    {:ok, pid} =
      DynamicSupervisor.start_child(
        GateServer.TcpConnectionSup,
        {GateServer.TcpConnection, client}
      )

    :ok = :gen_tcp.controlling_process(client, pid)

    loop_acceptor(socket)
  end
end
