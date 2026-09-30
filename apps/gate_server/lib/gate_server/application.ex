defmodule GateServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc """
  Boots the gateway/control-plane runtime.

  The gate owns:

  - the Voxim QUIC listener and per-connection supervision
  - Gate-owned authenticated session identities
  - the NPC body supervisor

  It does **not** own authoritative gameplay simulation; instead it forwards
  authenticated requests to scene/auth services and encodes their replies for
  clients.

  See `apps/gate_server/lib/gate_server/README.md` for the current supervisor
  tree and worker relationships.
  """

  use Application

  # Capture the build-time env so the release (where `Mix` is not loaded) can
  # still answer "are we in :test?" — module attributes are evaluated at compile
  # time, so this becomes a literal `false` in the prod release.
  @is_test_build Mix.env() == :test

  @impl true
  def start(_type, _args) do
    children =
      if @is_test_build do
        []
      else
        [
          {GateServer.Session.Claims, name: GateServer.Session.Claims},
          {GateServer.Transport.QuicListener,
           [claims: GateServer.Session.Claims] ++ Application.fetch_env!(:gate_server, :quic)},
          {DynamicSupervisor, name: GateServer.NpcSup, strategy: :one_for_one}
        ]
      end

    opts = [strategy: :one_for_one, name: GateServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
