defmodule SceneServer.PlayerCharacter do
  use GenServer, restart: :temporary

  require Logger

  alias SceneServer.AoiManager

  @default_dev_attrs %{"mmr" => 20, "cph" => 20, "cct" => 20, "pct" => 20, "rsl" => 20}
  @default_location {1_000.0, 1_000.0, 90.0}

  @movement_tick_interval 100
  @pulse_skill_id 1
  @skill_cooldown_ms 750
  @lock_retry_attempts 5
  @lock_retry_sleep_ms 5

  def start_link(params, opts \\ []) do
    GenServer.start_link(__MODULE__, params, opts)
  end

  @impl true
  def init({cid, connection_pid, client_timestamp, character_profile}) do
    # :pg.start_link(@scope)
    # :pg.join(@scope, @topic, self())
    Logger.debug("New player created.")

    SceneServer.CliObserve.emit("player_init", %{
      cid: cid,
      connection_pid: connection_pid,
      client_timestamp: client_timestamp,
      profile: character_profile
    })

    {:ok,
     %{
       cid: cid,
       character_profile: normalize_character_profile(cid, character_profile),
       connection_pid: connection_pid,
       last_location: normalize_character_profile(cid, character_profile).position,
       physys_ref: nil,
       aoi_ref: nil,
       character_data_ref: nil,
       status: :in_scene,
       old_timestamp: nil,
       net_delay: 0,
       skill_casts: %{},
       #  Timers
       movement_timer: nil
     }, {:continue, {:load, client_timestamp}}}
  end

  @impl true
  def handle_continue(
        {:load, client_timestamp},
        %{cid: cid, connection_pid: connection_pid, character_profile: character_profile} = state
      ) do
    %{name: name, position: location} = character_profile

    with {:ok, physys_ref} <- SceneServer.PhysicsManager.get_physics_system_ref(),
         {:ok, cd_ref} <-
           new_character_data_with_retry(cid, name, location, @default_dev_attrs, physys_ref),
         {:ok, aoi_ref} <- enter_scene(cid, client_timestamp, location, connection_pid) do
      movement_timer = make_movement_timer()

      {:noreply,
       %{
         state
         | physys_ref: physys_ref,
           aoi_ref: aoi_ref,
           character_data_ref: cd_ref,
           movement_timer: movement_timer
       }}
    else
      {:error, reason} ->
        SceneServer.CliObserve.emit("player_load_error", %{cid: cid, reason: reason})
        {:stop, {:load_failed, reason}, state}
    end
  end

  @impl true
  def handle_call(:exit, _from, state) do
    {:stop, :normal, {:ok, ""}, state}
  end

  @impl true
  def handle_call(:await_ready, _from, state) do
    if state.character_data_ref != nil and state.physys_ref != nil and state.aoi_ref != nil do
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_ready}, state}
    end
  end

  @impl true
  def handle_call(
        :get_location,
        _from,
        %{character_data_ref: nil, last_location: last_location} = state
      ) do
    {:reply, {:ok, last_location}, state}
  end

  @impl true
  def handle_call(
        :get_location,
        _from,
        %{character_data_ref: cd_ref, physys_ref: physys_ref, last_location: last_location} =
          state
      ) do
    case get_character_location_with_retry(cd_ref, physys_ref, last_location) do
      {:ok, location} ->
        {:reply, {:ok, location}, %{state | last_location: location}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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
        %{
          aoi_ref: aoi_ref,
          character_data_ref: cd_ref,
          physys_ref: physys_ref,
          last_location: last_location
        } = state
      ) do
    with {:ok, current_location} <-
           get_character_location_with_retry(cd_ref, physys_ref, last_location),
         :ok <-
           update_character_movement_with_retry(
             cd_ref,
             location,
             velocity,
             acceleration,
             physys_ref
           ),
         {:ok, authoritative_location} <-
           get_character_location_with_retry(cd_ref, physys_ref, location) do
      SceneServer.CliObserve.emit("player_movement_received", fn ->
        %{
          cid: state.cid,
          current_location: current_location,
          requested_location: location,
          velocity: velocity,
          acceleration: acceleration,
          authoritative_location: authoritative_location
        }
      end)

      {x, y, z} = location
      {ox, oy, oz} = current_location
      Logger.debug("位置误差：(#{ox - x}, #{oy - y}, #{oz - z})")

      maybe_broadcast_stop(aoi_ref, authoritative_location, velocity)

      {:reply, {:ok, ""}, %{state | last_location: authoritative_location}}
    else
      {:error, reason} ->
        SceneServer.CliObserve.emit("player_movement_error", %{cid: state.cid, reason: reason})
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:chat_say, cid, username, text}, _from, %{aoi_ref: aoi_ref} = state) do
    SceneServer.CliObserve.emit("player_chat", %{cid: cid, username: username, text: text})
    GenServer.cast(aoi_ref, {:chat_say, cid, username, text})
    {:reply, {:ok, :sent}, state}
  end

  @impl true
  def handle_call(
        {:cast_skill, skill_id},
        _from,
        %{
          cid: cid,
          aoi_ref: aoi_ref,
          skill_casts: skill_casts,
          character_data_ref: cd_ref,
          physys_ref: physys_ref,
          last_location: last_location
        } = state
      ) do
    now = :os.system_time(:millisecond)

    with :ok <- validate_skill(skill_id),
         :ok <- cooldown_ready?(skill_casts, skill_id, now),
         {:ok, location} <- get_character_location_with_retry(cd_ref, physys_ref, last_location) do
      SceneServer.CliObserve.emit("player_skill", %{
        cid: cid,
        skill_id: skill_id,
        location: location
      })

      GenServer.cast(aoi_ref, {:skill_cast, cid, skill_id, location})

      {:reply, {:ok, location},
       %{state | skill_casts: Map.put(skill_casts, skill_id, now), last_location: location}}
    else
      {:error, reason} ->
        SceneServer.CliObserve.emit("player_skill_error", %{
          cid: cid,
          skill_id: skill_id,
          reason: reason
        })

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(reason, %{aoi_ref: aoi_item, cid: cid, movement_timer: movement_timer}) do
    SceneServer.CliObserve.emit("player_terminate", %{cid: cid, reason: reason})

    if movement_timer != nil do
      Process.cancel_timer(movement_timer)
    end

    if is_pid(aoi_item) and Process.alive?(aoi_item) do
      {:ok, _} = GenServer.call(aoi_item, :exit)
      Logger.debug("AOI item removed.")
    end

    if Process.whereis(SceneServer.PlayerManager) do
      {:ok, _} = GenServer.call(SceneServer.PlayerManager, {:remove_player_index, cid})
      Logger.debug("Player index removed.")
    end

    Logger.warning(
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
          aoi_ref: aoi_ref,
          physys_ref: physys_ref,
          last_location: last_location
        } = state
      ) do
    new_state =
      case movement_tick_with_retry(cd_ref, physys_ref) do
        {:ok, location} when location != nil ->
          SceneServer.CliObserve.emit("player_movement_tick", fn ->
            %{cid: state.cid, location: location}
          end)

          GenServer.cast(aoi_ref, {:self_move, location})
          %{state | last_location: location}

        {:ok, nil} ->
          state

        {:error, :lock_fail} ->
          Logger.debug(
            "movement_tick lock contention for cid=#{state.cid}, keeping cached location"
          )

          %{state | last_location: last_location}

        {:error, reason} ->
          Logger.warning("movement_tick failed for cid=#{state.cid}: #{inspect(reason)}")
          state
      end

    {:noreply, %{new_state | movement_timer: make_movement_timer()}}
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

  defp validate_skill(@pulse_skill_id), do: :ok
  defp validate_skill(_skill_id), do: {:error, :invalid_skill}

  defp cooldown_ready?(skill_casts, skill_id, now) do
    case Map.get(skill_casts, skill_id) do
      nil -> :ok
      last_cast when now - last_cast >= @skill_cooldown_ms -> :ok
      _last_cast -> {:error, :skill_cooldown}
    end
  end

  defp maybe_broadcast_stop(aoi_ref, location, velocity) do
    if zero_velocity?(velocity) do
      GenServer.cast(aoi_ref, {:self_move, location})
    end
  end

  defp zero_velocity?({x, y, z}) when x == 0.0 and y == 0.0 and z == 0.0, do: true
  defp zero_velocity?(_velocity), do: false

  defp normalize_character_profile(cid, %{} = profile) do
    %{
      cid: cid,
      name:
        Map.get(profile, :name) || Map.get(profile, "name") ||
          "character-#{cid}",
      position: normalize_position(Map.get(profile, :position) || Map.get(profile, "position"))
    }
  end

  defp normalize_character_profile(cid, _profile) do
    %{cid: cid, name: "character-#{cid}", position: @default_location}
  end

  defp normalize_position({x, y, z})
       when (is_integer(x) or is_float(x)) and (is_integer(y) or is_float(y)) and
              (is_integer(z) or is_float(z)) do
    {x * 1.0, y * 1.0, z * 1.0}
  end

  defp normalize_position(%{} = position) do
    x = map_float(position, ["x", :x], elem(@default_location, 0))
    y = map_float(position, ["y", :y], elem(@default_location, 1))
    z = map_float(position, ["z", :z], elem(@default_location, 2))
    {x, y, z}
  end

  defp normalize_position(_position), do: @default_location

  defp map_float(map, keys, default) do
    keys
    |> Enum.find_value(fn key -> Map.get(map, key) end)
    |> case do
      value when is_integer(value) ->
        value * 1.0

      value when is_float(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp new_character_data_with_retry(
         cid,
         name,
         location,
         dev_attrs,
         physys_ref,
         attempts \\ @lock_retry_attempts
       )

  defp new_character_data_with_retry(
         _cid,
         _name,
         _location,
         _dev_attrs,
         _physys_ref,
         0
       ),
       do: {:error, :lock_fail}

  defp new_character_data_with_retry(cid, name, location, dev_attrs, physys_ref, attempts) do
    case SceneServer.Native.SceneOps.new_character_data(
           cid,
           name,
           location,
           dev_attrs,
           physys_ref
         ) do
      {:ok, cd_ref} ->
        {:ok, cd_ref}

      {:error, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)
        new_character_data_with_retry(cid, name, location, dev_attrs, physys_ref, attempts - 1)

      {:err, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)
        new_character_data_with_retry(cid, name, location, dev_attrs, physys_ref, attempts - 1)

      {:error, reason} ->
        {:error, reason}

      {:err, reason} ->
        {:error, reason}
    end
  end

  defp get_character_location_with_retry(
         cd_ref,
         physys_ref,
         fallback_location,
         attempts \\ @lock_retry_attempts
       )

  defp get_character_location_with_retry(_cd_ref, _physys_ref, fallback_location, 0) do
    Logger.debug("location fetch exhausted retries, using cached location")
    {:ok, fallback_location}
  end

  defp get_character_location_with_retry(cd_ref, physys_ref, fallback_location, attempts) do
    case SceneServer.Native.SceneOps.get_character_location(cd_ref, physys_ref) do
      {:ok, location} ->
        {:ok, location}

      {:error, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)
        get_character_location_with_retry(cd_ref, physys_ref, fallback_location, attempts - 1)

      {:err, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)
        get_character_location_with_retry(cd_ref, physys_ref, fallback_location, attempts - 1)

      {:error, reason} ->
        {:error, reason}

      {:err, reason} ->
        {:error, reason}
    end
  end

  defp update_character_movement_with_retry(
         cd_ref,
         location,
         velocity,
         acceleration,
         physys_ref,
         attempts \\ @lock_retry_attempts
       )

  defp update_character_movement_with_retry(
         _cd_ref,
         _location,
         _velocity,
         _acceleration,
         _physys_ref,
         0
       ),
       do: {:error, :lock_fail}

  defp update_character_movement_with_retry(
         cd_ref,
         location,
         velocity,
         acceleration,
         physys_ref,
         attempts
       ) do
    case SceneServer.Native.SceneOps.update_character_movement(
           cd_ref,
           location,
           velocity,
           acceleration,
           physys_ref
         ) do
      {:ok, _} ->
        :ok

      {:error, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)

        update_character_movement_with_retry(
          cd_ref,
          location,
          velocity,
          acceleration,
          physys_ref,
          attempts - 1
        )

      {:err, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)

        update_character_movement_with_retry(
          cd_ref,
          location,
          velocity,
          acceleration,
          physys_ref,
          attempts - 1
        )

      {:error, reason} ->
        {:error, reason}

      {:err, reason} ->
        {:error, reason}
    end
  end

  defp movement_tick_with_retry(cd_ref, physys_ref, attempts \\ @lock_retry_attempts)

  defp movement_tick_with_retry(_cd_ref, _physys_ref, 0), do: {:error, :lock_fail}

  defp movement_tick_with_retry(cd_ref, physys_ref, attempts) do
    case SceneServer.Native.SceneOps.movement_tick(cd_ref, physys_ref) do
      {:ok, location} ->
        {:ok, location}

      {:error, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)
        movement_tick_with_retry(cd_ref, physys_ref, attempts - 1)

      {:err, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)
        movement_tick_with_retry(cd_ref, physys_ref, attempts - 1)

      {:error, reason} ->
        {:error, reason}

      {:err, reason} ->
        {:error, reason}
    end
  end
end
