defmodule GateServer.TcpAcceptor do
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

  def start_link(_opts) do
    Task.start_link(__MODULE__, :accept, [8888])
  end

  def accept(port) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, active: true, reuseaddr: true])

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
