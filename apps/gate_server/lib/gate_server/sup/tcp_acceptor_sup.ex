defmodule GateServer.TcpAcceptorSup do
  @behaviour Supervisor

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  def init(_opts) do
    children = [
      {GateServer.TcpAcceptor, name: GateServer.TcpAcceptor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
