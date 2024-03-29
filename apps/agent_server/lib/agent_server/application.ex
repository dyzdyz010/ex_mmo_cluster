defmodule AgentServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: AgentServer.Worker.start_link(arg)
      # {AgentServer.Worker, arg}
      {AgentServer.InterfaceSup, name: AgentServer.InterfaceSup},
      {AgentServer.AgentSup, name: AgentServer.AgentSup}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AgentServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
