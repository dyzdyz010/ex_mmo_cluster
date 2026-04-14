defmodule GateServer.UdpAcceptorSup do
  @moduledoc """
  Supervisor wrapper around the shared UDP fast-lane listener.
  """

  @behaviour Supervisor

  @doc "Standard child spec for the UDP acceptor supervisor."
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc "Starts the UDP acceptor supervisor."
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  @doc false
  def init(_opts) do
    children = [
      {GateServer.UdpAcceptor, name: GateServer.UdpAcceptor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
