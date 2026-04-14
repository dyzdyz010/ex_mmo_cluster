defmodule GateServer.TcpAcceptor do
  @moduledoc """
  TCP listening worker for the gate runtime.

  This worker owns the listening socket only. Each accepted client socket is
  immediately handed off to a fresh `GateServer.TcpConnection` process under
  `GateServer.TcpConnectionSup`.
  """

  @behaviour GenServer

  require Logger

  @port 29000

  @doc "Standard child spec for the TCP acceptor worker."
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc "Starts the TCP acceptor."
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
    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: 4, active: true, reuseaddr: true])

    Logger.debug("Accepting connections on port #{port}")
    GateServer.CliObserve.emit("tcp_listen", %{port: port})
    loop_acceptor(socket)
  end

  defp loop_acceptor(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    GateServer.CliObserve.emit("tcp_accept", %{socket: client})

    {:ok, pid} =
      DynamicSupervisor.start_child(
        GateServer.TcpConnectionSup,
        {GateServer.TcpConnection, client}
      )

    :ok = :gen_tcp.controlling_process(client, pid)

    loop_acceptor(socket)
  end
end
