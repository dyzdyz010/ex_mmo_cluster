defmodule SceneServer.PlayerSup do
  @moduledoc """
  Supervisor subtree for active player infrastructure.

  Layout:

  - `SceneServer.PlayerCharacterSup` — dynamic supervisor for player actors
  - `SceneServer.PlayerManager` — spawn/index facade used by the gate and tests
  """

  use Supervisor

  @doc "Starts the player subtree root."
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
