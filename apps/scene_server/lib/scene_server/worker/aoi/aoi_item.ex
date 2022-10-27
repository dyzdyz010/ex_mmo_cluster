defmodule SceneServer.Aoi.AoiItem do
  use GenServer, restart: :transient

  require Logger

  alias SceneServer.Native.CoordinateSystem

  @type vector :: {float(), float(), float()}

  @aoi_tick_interval 1000
  @coord_tick_interval 1000

  def start_link(params, opts \\ []) do
    GenServer.start_link(__MODULE__, params, opts)
  end

  @impl true
  def init({cid, client_timestamp, location, cpid, system}) do
    {:ok,
     %{
       cid: cid,
       character_pid: cpid,
       system_ref: system,
       item_ref: nil,
       movement: %{
         client_timestamp: client_timestamp,
         server_timestamp: :os.system_time(:millisecond),
         location: location,
         velocity: {0.0, 0.0, 0.0},
         acceleration:  {0.0, 0.0, 0.0}
       },
       subscribers: [],
       interest_radius: 500,
       aoi_timer: nil,
       coord_timer: nil
     }, {:continue, {:load, location}}}
  end

  @impl true
  def handle_continue({:load, location}, %{cid: cid, system_ref: system} = state) do
    Logger.debug("aoi_item continue load")
    {:ok, item_ref} = add_item(cid, location, system)
    Logger.debug("Item added to the system.")

    aoi_timer = make_aoi_timer()
    coord_timer = make_coord_timer()

    {:noreply, %{state | item_ref: item_ref, aoi_timer: aoi_timer, coord_timer: coord_timer}}
  end

  @impl true
  def handle_cast(
        {:movement, timestamp, location, velocity, acceleration},
        state
      ) do
    Logger.debug("AOI movement")
    new_state = cast_movement(timestamp, location, velocity, acceleration, state)

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:exit, _from, state) do
    {:stop, :normal, {:ok, ""}, state}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, state}
  end

  ############### Tick Functions ##############################################################################

  @impl true
  def handle_info(:get_aoi_tick, %{system_ref: system, item_ref: item} = state) do
    {:ok, cids} = CoordinateSystem.get_items_within_distance_from_system(system, item, 50000.0)
    items = SceneServer.AoiManager.get_items_with_cids(cids)

    Logger.debug("Coordinate System: #{inspect(CoordinateSystem.get_system_raw(system), pretty: true)}", ansi_color: :yellow)
    Logger.debug("Coordinate System: #{inspect(cids, pretty: true)}", ansi_color: :yellow)

    {:noreply, %{state | aoi_timer: make_aoi_timer()}}
    # {:noreply, state}
  end

  @impl true
  def handle_info(
        :update_coord_tick,
        %{system_ref: system, item_ref: item, movement: movement} = state
      ) do

    new_location = if movement.velocity != {0.0, 0.0, 0.0} do
      # Logger.debug("Coord tick.", ansi_color: :yellow)
      new_location = CoordinateSystem.calculate_coordinate(movement.server_timestamp, :os.system_time(:millisecond), movement.location, movement.velocity)
      CoordinateSystem.update_item_from_system(system, item, new_location)
      new_location
    else
      movement.location
    end

    {:noreply, %{state | coord_timer: make_coord_timer(), movement: %{movement | location: new_location}}}
  end

  @impl true
  def terminate(reason, %{cid: cid, system_ref: system, item_ref: item, aoi_timer: aoi_timer, coord_timer: coord_timer}) do
    {:ok, _} = CoordinateSystem.remove_item_from_system(system, item)
    Logger.debug("AOI system item removed.")
    {:ok, _} = GenServer.call(SceneServer.AoiManager, {:remove_aoi_item, cid})
    Logger.debug("Aoi index removed.")
    Process.cancel_timer(aoi_timer)
    Process.cancel_timer(coord_timer)
    Logger.debug("Timer canceled.")

    Logger.warn(
      "AoiItem process #{inspect(self(), pretty: true)} exited successfully. Reason: #{inspect(reason, pretty: true)}",
      ansi_color: :green
    )
  end

  ################ Private Functions #######################################################################

  defp add_item(cid, location, system) do
    {:ok, item_ref} = CoordinateSystem.add_item_to_system(system, cid, location)

    {:ok, item_ref}
  end

  defp make_aoi_timer() do
    Process.send_after(self(), :get_aoi_tick, @aoi_tick_interval)
  end

  defp make_coord_timer() do
    Process.send_after(self(), :update_coord_tick, @coord_tick_interval)
  end

  # Handle `:movement` casts
  @spec cast_movement(integer(), vector(), vector(), vector(), map()) :: map()
  defp cast_movement(
         timestamp,
         location,
         velocity,
         acceleration,
         %{system_ref: system, item_ref: item} = state
       ) do
    {:ok, _} = CoordinateSystem.update_item_from_system(system, item, location)

    %{
      state
      | movement: %{
          client_timestamp: timestamp,
          server_timestamp: :os.system_time(:millisecond),
          location: location,
          velocity: velocity,
          acceleration: acceleration
        }
    }
  end
end
