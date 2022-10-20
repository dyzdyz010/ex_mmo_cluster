defmodule SceneServer.Aoi do
  use GenServer

  require Logger

  alias SceneServer.Native.CoordinateSystem

  # APIs

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @spec add_player(number(), {float(), float(), float()}) :: {:ok, CoordinateSystem.Types.item()} | {:err, any()}
  def add_player(cid, position) do
    GenServer.call(__MODULE__, {:add_player, cid, position})
  end

  @spec remove_player(CoordinateSystem.Types.item()) :: {:ok, any()} | {:err, any()}
  def remove_player(aoi_item) do
    GenServer.call(__MODULE__, {:remove_player, aoi_item})
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{coordinate_system: nil}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.debug("Aoi process created.")
    system = create_system()
    {:noreply, %{state | coordinate_system: system}}
  end

  @impl true
  def handle_call({:add_player, cid, {x, y, z}}, _from, %{coordinate_system: system} = state) do
    # Logger.debug("Adding player to CoordinateSystem: #{inspect(cid, pretty: true)}")
    result = CoordinateSystem.add_item_to_system(system, cid, {x, y, z})

    {:reply, result, state}
  end

  @impl true
  def handle_call({:remove_player, aoi_item}, _from, %{coordinate_system: system} = state) do
    Logger.debug("Removing player from CoordinateSystem: #{inspect(aoi_item, pretty: true)}")
    result = CoordinateSystem.remove_item_from_system(system, aoi_item)

    {:reply, result, state}
  end

  # Internal functions

  @spec create_system() :: SceneServer.Native.CoordinateSystem.Types.coordinate_system()
  defp create_system() do
    # {:ok, item} = SceneServer.Native.CoordinateSystem.new_item(123, self(), {1.0, 2.0, 3.0})
    # {:ok, bucket} = SceneServer.Native.CoordinateSystem.new_bucket()
    # {:ok, set} = SceneServer.Native.CoordinateSystem.new_set(10000, 4)
    # Logger.debug("Set ref: #{inspect(set, pretty: true)}")

    {:ok, system} = SceneServer.Native.CoordinateSystem.new_system(10000, 5)

    system
  end
end
