defmodule GateServer.InterfaceSup do
  @moduledoc """
  Minimal supervisor wrapper for `GateServer.Interface`.
  """

  use Supervisor

  @doc "Starts the gate interface supervisor."
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    children = [
      {GateServer.Interface, name: GateServer.Interface}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
