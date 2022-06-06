defmodule WorldServer.WorldSup do
  @moduledoc """
  This is the World Supervisor.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    children = [
      # {WorldServer.Worker, name: WorldServer.Worker}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
