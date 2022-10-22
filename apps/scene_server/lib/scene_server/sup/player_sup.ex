defmodule SceneServer.PlayerSup do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    children = [
      {SceneServer.PlayerCharacterSup, name: SceneServer.PlayerCharacterSup},
      {SceneServer.PlayerManager, name: SceneServer.PlayerManager}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
