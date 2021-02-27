defmodule GateServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: GateServer.Worker.start_link(arg)
      # {GateServer.Worker, arg}
      {GateServer.TcpAcceptorSup, name: GateServer.TcpAcceptorSup},
      {GateServer.TcpConnectionSup, name: GateServer.TcpConnectionSup}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GateServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
