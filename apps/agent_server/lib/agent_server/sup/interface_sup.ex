defmodule AgentServer.InterfaceSup do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    children = [
      {AgentServer.Interface, name: AgentServer.Interface}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
