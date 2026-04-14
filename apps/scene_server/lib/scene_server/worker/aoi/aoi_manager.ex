defmodule SceneServer.AoiManager do
  @moduledoc """
  Central AOI index and lookup service for active actors.

  `AoiManager` owns the octree plus the mapping from CID to AOI item/actor PID.
  Player and NPC actors both register through this module, which is why combat
  targeting can stay actor-agnostic.
  """

  use GenServer

  require Logger

  alias SceneServer.Native.CoordinateSystem
  alias SceneServer.Native.Octree

  # APIs

  @doc "Starts the shared AOI index process."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @spec add_aoi_item(
          integer(),
          integer(),
          {float(), float(), float()},
          pid(),
          pid(),
          %{kind: atom(), name: String.t()}
        ) ::
          {:ok, pid()} | {:err, any()}
  @doc "Registers one actor in the AOI system and returns its dedicated AOI item PID."
  def add_aoi_item(cid, client_timestamp, location, connection_pid, actor_pid, actor_meta) do
    GenServer.call(
      __MODULE__,
      {:add_aoi_item, cid, client_timestamp, location, connection_pid, actor_pid, actor_meta}
    )
  end

  @spec remove_aoi_item(CoordinateSystem.Types.item()) :: {:ok, any()} | {:err, any()}
  @doc "Removes an actor from the AOI index by CID."
  def remove_aoi_item(cid) do
    GenServer.call(__MODULE__, {:remove_aoi_item, cid})
  end

  @spec get_items_with_cids([integer()]) :: [pid()]
  @doc "Resolves AOI item PIDs for the provided CIDs."
  def get_items_with_cids(cids) do
    GenServer.call(__MODULE__, {:get_items_with_cids, cids})
  end

  @spec get_nearby_actor_pids({float(), float(), float()}, float(), [integer()]) :: [pid()]
  @doc "Returns nearby actor PIDs around a location, excluding specified CIDs."
  def get_nearby_actor_pids(location, radius, exclude_cids \\ []) do
    GenServer.call(__MODULE__, {:get_nearby_actor_pids, location, radius, exclude_cids})
  end

  @spec get_actor_pid(integer()) :: pid() | nil
  @doc "Resolves an authoritative actor PID by CID."
  def get_actor_pid(cid) do
    GenServer.call(__MODULE__, {:get_actor_pid, cid})
  end

  @impl true
  def init(_init_arg) do
    Logger.debug("Aoi process created.")
    system = create_system()
    {:ok, %{coordinate_system: system, aois: %{}}}
  end

  @impl true
      def handle_call(
        {:add_aoi_item, cid, client_timestamp, location, connection_pid, actor_pid, actor_meta},
        _from,
        %{coordinate_system: system, aois: aois} = state
      ) do
    {:ok, apid} =
      DynamicSupervisor.start_child(
        SceneServer.AoiItemSup,
        {SceneServer.Aoi.AoiItem,
         {cid, client_timestamp, location, connection_pid, actor_pid, actor_meta, system}}
      )

    new_aois =
      aois
      |> Map.put_new(cid, %{aoi_pid: apid, actor_pid: actor_pid, actor_meta: actor_meta})

    {:reply, {:ok, apid}, %{state | aois: new_aois}}
  end

  @impl true
  def handle_call({:remove_aoi_item, cid}, _from, %{aois: aois} = state) do
    new_aois = aois |> Map.delete(cid)
    {:reply, {:ok, ""}, %{state | aois: new_aois}}
  end

  @impl true
  def handle_call({:get_items_with_cids, cids}, _from, %{aois: aois} = state) do
    items =
      for {k, %{aoi_pid: aoi_pid}} <- aois, cid <- cids, k == cid, do: aoi_pid

    {:reply, items, state}
  end

  @impl true
  def handle_call({:get_actor_pid, cid}, _from, %{aois: aois} = state) do
    actor_pid =
      case Map.get(aois, cid) do
        %{actor_pid: pid} -> pid
        _ -> nil
      end

    {:reply, actor_pid, state}
  end

  @impl true
  def handle_call(
        {:get_nearby_actor_pids, location, radius, exclude_cids},
        _from,
        %{coordinate_system: system, aois: aois} = state
      ) do
    cids = Octree.get_in_bound(system, location, {radius, radius, radius})

    actor_pids =
      cids
      |> Enum.reject(&(&1 in exclude_cids))
      |> Enum.map(fn cid ->
        case Map.get(aois, cid) do
          %{actor_pid: actor_pid} -> actor_pid
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:reply, actor_pids, state}
  end

  # Internal functions

  @spec create_system() :: SceneServer.Native.CoordinateSystem.Types.coordinate_system()
  defp create_system() do
    # {:ok, system} = SceneServer.Native.CoordinateSystem.new_system(10000, 5)
    system = Octree.new_tree({0.0, 0.0, 0.0}, {5000.0, 5000.0, 5000.0})

    system
  end
end
