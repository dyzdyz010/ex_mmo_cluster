defmodule DataContact.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: DataContact.Worker.start_link(arg)
      # {DataContact.Worker, arg}
      {DataContact.InterfaceSup, name: DataContact.InterfaceSup},
      {DataContact.NodeManager, name: DataContact.NodeManager}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DataContact.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
