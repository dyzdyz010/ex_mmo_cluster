defmodule SceneServer.NpcActorSup do
  @moduledoc """
  Dynamic supervisor for active `SceneServer.Npc.Actor` processes.

  This stays separate from `Npc.Manager` so manager failures do not imply actor
  failures and vice versa.
  """

  @behaviour DynamicSupervisor

  @doc "Standard child spec used by the scene application tree."
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc "Starts the dynamic supervisor."
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, [], opts)
  end

  @doc false
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
