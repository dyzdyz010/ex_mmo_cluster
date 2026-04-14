defmodule SceneServer.InterfaceSup do
  @moduledoc """
  Minimal supervisor wrapper for `SceneServer.Interface`.
  """

  use Supervisor

  @doc "Starts the scene interface supervisor."
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    children = [
      {SceneServer.Interface, name: SceneServer.Interface}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
