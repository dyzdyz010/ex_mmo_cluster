defmodule SceneServer.PhysicsManager do
  @moduledoc """
  Owner of the shared native physics/scene reference.

  Player and NPC actors do not create native physics systems directly. They ask
  `PhysicsManager` for the shared reference so the native scene layer remains
  centrally owned and supervised.
  """

  use GenServer

  require Logger

  @doc "Starts the shared physics manager."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_params) do
    {:ok, physys_ref} = SceneServer.Native.SceneOps.new_physics_system()

    Logger.debug("Physics system started.")

    {:ok, %{physys_ref: physys_ref}}
  end

  @doc "Returns the shared native physics system reference."
  @spec get_physics_system_ref :: {:ok, reference()}
  def get_physics_system_ref() do
    GenServer.call(__MODULE__, :get_physics_system_ref)
  end

  @impl true
  def handle_call(:get_physics_system_ref, _from, %{physys_ref: physys_ref} = state) do
    {:reply, {:ok, physys_ref}, state}
  end
end
