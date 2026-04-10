defmodule GateServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Starts a worker by calling: GateServer.Worker.start_link(arg)
        # {GateServer.Worker, arg}
        {GateServer.InterfaceSup, name: GateServer.InterfaceSup},
        {GateServer.FastLaneRegistry, name: GateServer.FastLaneRegistry},
        {GateServer.TcpAcceptorSup, name: GateServer.TcpAcceptorSup},
        {GateServer.TcpConnectionSup, name: GateServer.TcpConnectionSup}
      ] ++ udp_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GateServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp udp_children do
    if Mix.env() == :test do
      []
    else
      [{GateServer.UdpAcceptorSup, name: GateServer.UdpAcceptorSup}]
    end
  end
end
