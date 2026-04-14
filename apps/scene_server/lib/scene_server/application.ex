defmodule SceneServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc """
  Boots the scene-side authority runtime.

  `SceneServer.Application` wires together the supervision roots for:

  - scene registration and lookup (`SceneServer.InterfaceSup`)
  - physics/native scene integration (`SceneServer.PhysicsSup`)
  - AOI indexing and fan-out (`SceneServer.AoiSup`)
  - authoritative player actors (`SceneServer.PlayerSup`)
  - authoritative NPC actors (`SceneServer.NpcSup`)

  See `apps/scene_server/lib/scene_server/README.md` for the current supervisor
  tree and how movement/combat/NPC responsibilities are split underneath it.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: SceneServer.Worker.start_link(arg)
      # {SceneServer.Worker, arg}
      {SceneServer.InterfaceSup, name: SceneServer.InterfaceSup},
      {SceneServer.PhysicsSup, name: SceneServer.PhysicsSup},
      {SceneServer.AoiSup, name: SceneServer.AoiSup},
      {SceneServer.PlayerSup, name: SceneServer.PlayerManagerSup},
      {SceneServer.NpcSup, name: SceneServer.NpcManagerSup}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SceneServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
