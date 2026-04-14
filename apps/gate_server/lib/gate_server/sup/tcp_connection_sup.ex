defmodule GateServer.TcpConnectionSup do
  @moduledoc """
  Dynamic supervisor for per-client `GateServer.TcpConnection` processes.
  """

  @behaviour DynamicSupervisor

  @doc "Standard child spec for the TCP connection supervisor."
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc "Starts the TCP connection dynamic supervisor."
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, [], opts)
  end

  @doc false
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
