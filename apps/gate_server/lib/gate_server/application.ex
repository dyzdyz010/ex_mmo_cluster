defmodule GateServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc """
  Boots the gateway/control-plane runtime.

  The gate owns:

  - client-facing TCP accepts
  - optional UDP fast-lane traffic
  - per-connection worker supervision
  - ticket/session tracking for UDP attachment
  - optional stdio inspection hooks for automation

  It does **not** own authoritative gameplay simulation; instead it forwards
  authenticated requests to scene/auth services and encodes their replies for
  clients.

  See `apps/gate_server/lib/gate_server/README.md` for the current supervisor
  tree and worker relationships.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Starts a worker by calling: GateServer.Worker.start_link(arg)
        # {GateServer.Worker, arg}
        {GateServer.InterfaceSup, name: GateServer.InterfaceSup},
        {GateServer.FastLaneRegistry, name: GateServer.FastLaneRegistry},
        stdio_child(),
        {GateServer.TcpAcceptorSup, name: GateServer.TcpAcceptorSup},
        {GateServer.TcpConnectionSup, name: GateServer.TcpConnectionSup}
      ]
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(udp_children())

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

  defp stdio_child do
    enabled? =
      Application.get_env(:gate_server, :stdio_interface, false) ||
        System.get_env("GATE_SERVER_STDIO") in ["1", "true", "TRUE", "yes", "on"]

    if Mix.env() != :test and enabled? do
      {GateServer.StdioInterface, name: GateServer.StdioInterface}
    end
  end
end
