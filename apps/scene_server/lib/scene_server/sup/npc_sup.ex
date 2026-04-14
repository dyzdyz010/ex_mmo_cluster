defmodule SceneServer.NpcSup do
  @moduledoc """
  Supervisor subtree for active NPC infrastructure.

  Layout:

  - `SceneServer.NpcActorSup` — dynamic supervisor for individual NPC actors
  - `SceneServer.NpcManager` — spawn/index facade used by demo/runtime tooling
  """

  use Supervisor

  @doc "Starts the NPC subtree root."
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    children = [
      {SceneServer.NpcActorSup, name: SceneServer.NpcActorSup},
      {SceneServer.Npc.Manager, name: SceneServer.NpcManager}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
