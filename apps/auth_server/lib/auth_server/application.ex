defmodule AuthServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: AuthServer.Worker.start_link(arg)
      # {AuthServer.Worker, arg}
      {AuthServer.AuthWorker, name: AuthServer.AuthWorker},
      {AuthServer.InterfaceSup, name: AuthServer.InterfaceSup}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AuthServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
