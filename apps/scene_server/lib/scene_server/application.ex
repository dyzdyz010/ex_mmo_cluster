defmodule SceneServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc """
  Boots the scene-side authority runtime.

  `SceneServer.Application` wires together the supervision roots for:

  - scene registration and lookup (`SceneServer.InterfaceSup`)
  - physics/native scene integration (`SceneServer.PhysicsSup`)
  - voxel chunk authority and directory processes (`SceneServer.VoxelSup`)
  - AOI indexing and fan-out (`SceneServer.AoiSup`)
  - authoritative player actors (`SceneServer.PlayerSup`)
  - authoritative NPC actors (`SceneServer.NpcSup`)

  See `apps/scene_server/lib/scene_server/README.md` for the current supervisor
  tree and how movement/combat/NPC responsibilities are split underneath it.
  """

  use Application

  @is_test_build Mix.env() == :test

  @impl true
  def start(_type, _args) do
    children =
      [
        # Starts a worker by calling: SceneServer.Worker.start_link(arg)
        # {SceneServer.Worker, arg}
        {SceneServer.CliObserve.Manager, []},
        interface_child(),
        {SceneServer.PhysicsSup, name: SceneServer.PhysicsSup},
        {SceneServer.VoxelSup, name: SceneServer.VoxelSup},
        {SceneServer.AoiSup, name: SceneServer.AoiSup},
        {SceneServer.PlayerSup, name: SceneServer.PlayerManagerSup},
        {SceneServer.NpcSup, name: SceneServer.NpcManagerSup}
      ]
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SceneServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp interface_child do
    if @is_test_build do
      nil
    else
      {SceneServer.InterfaceSup, name: SceneServer.InterfaceSup}
    end
  end
end
