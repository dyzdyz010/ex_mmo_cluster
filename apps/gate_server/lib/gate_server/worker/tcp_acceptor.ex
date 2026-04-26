defmodule GateServer.TcpAcceptor do
  @moduledoc """
  TCP listening worker for the gate runtime.

  This worker owns the listening socket only. Each accepted client socket is
  immediately handed off to a fresh `GateServer.TcpConnection` process under
  `GateServer.TcpConnectionSup`.
  """

  @behaviour GenServer

  require Logger

  @default_port 29000

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
    listen(Application.get_env(:gate_server, :tcp_port, @default_port))
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

    # Audit (e2e smoke 2026-04-26): a client may close the connection in
    # the window between `:gen_tcp.accept/1` returning and us handing the
    # socket to its connection process — `controlling_process/2` then
    # returns `{:error, :closed}` and the prior `:ok = ...` match crashed
    # the acceptor. The supervisor restarts it, so functionality survives,
    # but the noise hides real problems. Handle the race quietly: drop
    # the orphaned connection process (no socket to own) and continue.
    case :gen_tcp.controlling_process(client, pid) do
      :ok ->
        :ok

      {:error, :closed} ->
        # Socket already gone — close our end and tear down the orphaned
        # connection process. DynamicSupervisor terminate is best-effort.
        _ = :gen_tcp.close(client)
        _ = DynamicSupervisor.terminate_child(GateServer.TcpConnectionSup, pid)

        GateServer.CliObserve.emit("tcp_accept_race_closed", %{
          connection_pid: pid
        })

      {:error, reason} ->
        # Genuine controlling_process failure (badarg, eperm, etc.) —
        # surface it. Acceptor still survives via supervisor restart, but
        # we want this to be loud.
        raise "controlling_process failed for socket #{inspect(client)}: #{inspect(reason)}"
    end

    loop_acceptor(socket)
  end
end
