defmodule SceneServer.Aoi.AoiWorker do
  use GenServer

  require Logger

  alias SceneServer.Native.CoordinateSystem

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_args) do
    {:ok, %{}}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call({:add_player, cid, {x, y, z}, system}, _from, state) do
    # Logger.debug("Adding player to CoordinateSystem: #{inspect(cid, pretty: true)}")
    result = CoordinateSystem.add_item_to_system(system, cid, {x, y, z})

    {:reply, result, state}
  end
end
