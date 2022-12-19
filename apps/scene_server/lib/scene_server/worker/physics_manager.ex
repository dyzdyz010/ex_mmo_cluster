defmodule SceneServer.PhysicsManager do
  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_params) do
    {:ok, %{physys_ref: nil}, {:continue, :load}}
  end

  @spec get_physics_system_ref :: {:ok, reference()}
  def get_physics_system_ref() do
    GenServer.call(__MODULE__, :get_physics_system_ref)
  end

  @impl true
  def handle_continue(
        :load,
        state
      ) do
    {:ok, physys_ref} = SceneServer.Native.SceneOps.new_physics_system()

    Logger.debug("Physics system started.")

    {:noreply, %{state | physys_ref: physys_ref}}
  end

  @impl true
  def handle_call(:get_physics_system_ref, _from, %{physys_ref: physys_ref} = state) do
    {:reply, {:ok, physys_ref}, state}
  end
end
