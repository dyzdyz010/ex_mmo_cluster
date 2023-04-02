defmodule SceneServer.AoiManager do
  use GenServer

  require Logger

  alias SceneServer.Native.CoordinateSystem
  alias SceneServer.Native.Octree

  # APIs

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @spec add_aoi_item(integer(), integer(), {float(), float(), float()}, pid(), pid()) ::
          {:ok, pid()} | {:err, any()}
  def add_aoi_item(cid, client_timestamp, location, connection_pid, player_pid) do
    GenServer.call(
      __MODULE__,
      {:add_aoi_item, cid, client_timestamp, location, connection_pid, player_pid}
    )
  end

  @spec remove_aoi_item(CoordinateSystem.Types.item()) :: {:ok, any()} | {:err, any()}
  def remove_aoi_item(cid) do
    GenServer.call(__MODULE__, {:remove_aoi_item, cid})
  end

  @spec get_items_with_cids([integer()]) :: [pid()]
  def get_items_with_cids(cids) do
    GenServer.call(__MODULE__, {:get_items_with_cids, cids})
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{coordinate_system: nil, aois: %{}}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.debug("Aoi process created.")
    system = create_system()
    {:noreply, %{state | coordinate_system: system}}
  end

  @impl true
  def handle_call(
        {:add_aoi_item, cid, client_timestamp, location, connection_pid, player_pid},
        _from,
        %{coordinate_system: system, aois: aois} = state
      ) do
    {:ok, apid} =
      DynamicSupervisor.start_child(
        SceneServer.AoiItemSup,
        {SceneServer.Aoi.AoiItem,
         {cid, client_timestamp, location, connection_pid, player_pid, system}}
      )

    new_aois = aois |> Map.put_new(cid, apid)

    {:reply, {:ok, apid}, %{state | aois: new_aois}}
  end

  @impl true
  def handle_call({:remove_aoi_item, cid}, _from, %{aois: aois} = state) do
    new_aois = aois |> Map.delete(cid)
    {:reply, {:ok, ""}, %{state | aois: new_aois}}
  end

  @impl true
  def handle_call({:get_items_with_cids, cids}, _from, %{aois: aois} = state) do
    items = for {k, v} <- aois, cid <- cids, k == cid, do: v
    # Logger.debug("Items: #{inspect(items, pretty: true)}")
    {:reply, items, state}
  end

  # Internal functions

  @spec create_system() :: SceneServer.Native.CoordinateSystem.Types.coordinate_system()
  defp create_system() do
    # {:ok, system} = SceneServer.Native.CoordinateSystem.new_system(10000, 5)
    system = Octree.new_tree({0.0, 0.0, 0.0}, {5000.0, 5000.0, 5000.0})

    system
  end
end
