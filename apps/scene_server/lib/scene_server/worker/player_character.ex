defmodule SceneServer.PlayerCharacter do
  use GenServer, restart: :temporary

  require Logger

  alias SceneServer.AoiManager

  @default_dev_attrs %{"mmr" => 20, "cph" => 20, "cct" => 20, "pct" => 20, "rsl" => 20}

  @movement_tick_interval 100

  def start_link(params, opts \\ []) do
    GenServer.start_link(__MODULE__, params, opts)
  end

  @impl true
  def init({cid, connection_pid, client_timestamp}) do
    # :pg.start_link(@scope)
    # :pg.join(@scope, @topic, self())
    Logger.debug("New player created.")

    {:ok,
     %{
       cid: cid,
       connection_pid: connection_pid,
       aoi_ref: nil,
       character_data_ref: nil,
       status: :in_scene,
       old_timestamp: nil,
       net_delay: 0,
       #  Timers
       movement_timer: nil
     }, {:continue, {:load, client_timestamp}}}
  end

  @impl true
  def handle_continue(
        {:load, client_timestamp},
        %{cid: cid, connection_pid: connection_pid} = state
      ) do
    pmin = 400
    pmax = 3000
    x = Enum.random(pmin..pmax) * 1.0
    y = Enum.random(pmin..pmax) * 1.0
    z = 90.0
    location = {x, y, z}

    {:ok, cd_ref} =
      SceneServer.Native.SceneOps.new_character_data(cid, "demo1", location, @default_dev_attrs)

    {:ok, aoi_ref} = enter_scene(cid, client_timestamp, location, connection_pid)

    movement_timer = make_movement_timer()

    {:noreply,
     %{state | aoi_ref: aoi_ref, character_data_ref: cd_ref, movement_timer: movement_timer}}
  end

  @impl true
  def handle_call(:exit, _from, state) do
    {:stop, :normal, {:ok, ""}, state}
  end

  @impl true
  def handle_call(:get_location, _from, %{character_data_ref: cd_ref} = state) do
    {:ok, location} = SceneServer.Native.SceneOps.get_character_location(cd_ref)

    {:reply, {:ok, location}, state}
  end

  @impl true
  def handle_call(
        :time_sync,
        _from,
        %{old_timestamp: old_timestamp, net_delay: old_delay} = state
      ) do
    new_timestamp = :os.system_time(:millisecond)

    case old_timestamp do
      nil ->
        {true, %{state | old_timestamp: new_timestamp}}
        {:reply, {:ok, new_timestamp}, %{state | old_timestamp: new_timestamp}}

      _ ->
        Logger.debug("CS延迟: #{div(new_timestamp - old_timestamp, 2)}")

        temp_delay = div(new_timestamp - old_timestamp, 2)

        new_delay =
          if old_delay != 0 do
            div(temp_delay + old_delay, 2)
            # ((new_timestamp - old_timestamp) / 2 + old_delay) / 2
          else
            temp_delay
          end

        {false, %{state | old_timestamp: nil, net_delay: new_delay}}

        {:reply, {:ok, :end}, %{state | old_timestamp: nil, net_delay: new_delay}}
    end
  end

  @impl true
  def handle_call(
        {:movement, _client_timestamp, location, velocity, acceleration},
        _from,
        %{aoi_ref: _aoi, character_data_ref: cd_ref} = state
      ) do
    {x, y, z} = location
    {:ok, {ox, oy, oz}} = SceneServer.Native.SceneOps.get_character_location(cd_ref)
    Logger.debug("位置误差：(#{ox - x}, #{oy - y}, #{oz - z})")
    # GenServer.cast(aoi, {:movement, client_timestamp, location, velocity, acceleration})
    {:ok, _} = SceneServer.Native.SceneOps.update_character_movement(cd_ref, location, velocity, acceleration)
    # Logger.debug("Velocity: #{inspect(velocity, pretty: true)}")

    {:reply, {:ok, ""}, state}
  end

  @impl true
  def terminate(reason, %{aoi_ref: aoi_item, cid: cid}) do
    {:ok, _} = GenServer.call(aoi_item, :exit)
    Logger.debug("AOI item removed.")
    {:ok, _} = GenServer.call(SceneServer.PlayerManager, {:remove_player_index, cid})
    Logger.debug("Player index removed.")

    Logger.warn(
      "PlayerCharacter process #{inspect(self(), pretty: true)} exited successfully. Reason: #{inspect(reason, pretty: true)}",
      ansi_color: :green
    )
  end

  # Tick functions ##########################################################

  @impl true
  def handle_info(
        :movement_tick,
        %{
          character_data_ref: cd_ref,
          aoi_ref: aoi_ref
        } = state
      ) do

    with {:ok, location} when location != nil <- SceneServer.Native.SceneOps.movement_tick(cd_ref) do
      # Logger.debug("Location update: #{inspect(location, pretty: true)}")
      GenServer.cast(aoi_ref, {:self_move, location})
    end

    {:noreply, %{state | movement_timer: make_movement_timer()}}
  end

  defp enter_scene(cid, client_timestamp, location, connection_pid) do
    {:ok, aoi_ref} =
      AoiManager.add_aoi_item(cid, client_timestamp, location, connection_pid, self())

    Logger.debug("Character added to Coordinate System: #{inspect(aoi_ref, pretty: true)}")

    {:ok, aoi_ref}
  end

  defp make_movement_timer() do
    Process.send_after(self(), :movement_tick, @movement_tick_interval)
  end
end
