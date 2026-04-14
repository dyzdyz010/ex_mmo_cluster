defmodule SceneServer.PhysicsSup do
  @moduledoc """
  Supervisor subtree for shared native physics integration.
  """

  use Supervisor

  @doc "Starts the physics subtree root."
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    children = [
      {SceneServer.PhysicsManager, name: SceneServer.PhysicsManager}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
