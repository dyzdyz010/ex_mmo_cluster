defmodule SceneServer.PlayerCharacterSup do
  @moduledoc """
  Dynamic supervisor for active `SceneServer.PlayerCharacter` processes.
  """

  @behaviour DynamicSupervisor

  @doc "Standard child spec used by the player subtree."
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc "Starts the player character dynamic supervisor."
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, [], opts)
  end

  @doc false
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
