defmodule SceneServer.NpcSup do
  use Supervisor

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
