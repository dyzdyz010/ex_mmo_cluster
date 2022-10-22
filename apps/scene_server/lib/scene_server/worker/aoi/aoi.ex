defmodule SceneServer.Aoi do
  use GenServer

  require Logger

  alias SceneServer.Native.CoordinateSystem

  # APIs

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @spec add_aoi_item(number(), {float(), float(), float()}, pid()) ::
          {:ok, CoordinateSystem.Types.item()} | {:err, any()}
  def add_aoi_item(cid, location, cpid) do
    GenServer.call(__MODULE__, {:add_aoi_item, cid, location, cpid})
  end

  @spec remove_aoi_item(CoordinateSystem.Types.item()) :: {:ok, any()} | {:err, any()}
  def remove_aoi_item(aoi_item) do
    GenServer.call(__MODULE__, {:remove_aoi_item, aoi_item})
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
        {:add_aoi_item, cid, location, cpid},
        _from,
        %{coordinate_system: system, aois: aois} = state
      ) do
    {:ok, apid} =
      DynamicSupervisor.start_child(
        SceneServer.PlayerCharacterSup,
        {SceneServer.Aoi.AoiItem, {cid, location, cpid, system}}
      )

    new_aois = aois |> Map.put_new(cid, apid)

    {:reply, {:ok, apid}, %{state | aois: new_aois}}
  end

  @impl true
  def handle_call({:remove_aoi_item, cid}, _from, %{aois: aois} = state) do
    new_aois = aois |> Map.delete(cid)
    {:reply, {:ok, ""}, %{state | aois: new_aois}}
  end

  # Internal functions

  @spec create_system() :: SceneServer.Native.CoordinateSystem.Types.coordinate_system()
  defp create_system() do
    {:ok, system} = SceneServer.Native.CoordinateSystem.new_system(10000, 5)

    system
  end
end
