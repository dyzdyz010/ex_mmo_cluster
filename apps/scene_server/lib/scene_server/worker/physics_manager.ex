defmodule SceneServer.PhysicsManager do
  use GenServer

  def start_link(params, opts \\ []) do
    GenServer.start_link(__MODULE__, params, opts)
  end

  @impl true
  def init(_params) do
    {:ok, %{}, {:continue, :load}}
  end
end
