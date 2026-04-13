defmodule SceneServer.PlayerCharacter do
  use GenServer, restart: :temporary

  require Logger

  alias SceneServer.AoiManager
  alias SceneServer.Combat.Profile, as: CombatProfile
  alias SceneServer.Combat.Skill
  alias SceneServer.Combat.State, as: CombatState
  alias SceneServer.Combat.Targeting
  alias SceneServer.Movement.{Engine, InputFrame, Profile, RemoteSnapshot, State}

  @default_dev_attrs %{"mmr" => 20, "cph" => 20, "cct" => 20, "pct" => 20, "rsl" => 20}
  @default_location {1_000.0, 1_000.0, 90.0}

  @lock_retry_attempts 5
  @lock_retry_sleep_ms 5
  @input_hold_timeout_multiplier 3
  @stopped_speed_epsilon 1.0

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
       spawn_location: normalize_character_profile(cid, character_profile).position,
       movement_state: State.idle(normalize_character_profile(cid, character_profile).position),
       movement_profile: Profile.default(),
       combat_profile: CombatProfile.default(),
       combat_state: CombatState.new(CombatProfile.default()),
       latched_input: idle_input_frame(Profile.default().fixed_dt_ms),
       last_input_seq: 0,
       last_ack_seq: 0,
       last_client_tick: 0,
       last_input_received_at_ms: System.monotonic_time(:millisecond),
       status: :in_scene,
       old_timestamp: nil,
       net_delay: 0,
       skill_casts: %{},
       movement_timer: nil,
       respawn_timer: nil
     }, {:continue, {:load, client_timestamp}}}
  end

  @impl true
  def handle_continue(
        {:load, client_timestamp},
        %{cid: cid, connection_pid: connection_pid, character_profile: character_profile} = state
      ) do
    %{name: name, position: location} = character_profile
    movement_profile = state.movement_profile

    with {:ok, physys_ref} <- SceneServer.PhysicsManager.get_physics_system_ref(),
         {:ok, cd_ref} <-
           new_character_data_with_retry(cid, name, location, @default_dev_attrs, physys_ref),
         {:ok, aoi_ref} <- enter_scene(cid, client_timestamp, location, connection_pid) do
      movement_timer = make_movement_timer(movement_profile.fixed_dt_ms)
      combat_state = state.combat_state

      GenServer.cast(
        aoi_ref,
        {:player_state, cid, combat_state.hp, combat_state.max_hp, combat_state.alive}
      )

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
  def handle_call(:get_state_summary, _from, state) do
    summary = %{
      cid: state.cid,
      position: state.last_location,
      hp: state.combat_state.hp,
      max_hp: state.combat_state.max_hp,
      alive: state.combat_state.alive,
      deaths: state.combat_state.deaths
    }

    {:reply, {:ok, summary}, state}
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
        {:movement_input, %InputFrame{} = frame},
        _from,
        %{
          cid: cid,
          combat_state: combat_state,
          movement_profile: movement_profile,
          latched_input: latched_input,
          last_input_seq: last_input_seq,
          last_client_tick: last_client_tick,
          last_input_received_at_ms: last_input_received_at_ms
        } = state
      ) do
    with :ok <- ensure_alive(combat_state),
         {:ok, sanitized_frame, now_ms} <-
           sanitize_input_frame(
             frame,
             movement_profile,
             last_input_seq,
             last_client_tick,
             last_input_received_at_ms
           ) do
      {:reply, {:ok, :accepted},
       %{
         state
         | latched_input: merge_latched_input(latched_input, sanitized_frame, movement_profile),
           last_input_seq: sanitized_frame.seq,
           last_client_tick: sanitized_frame.client_tick,
           last_input_received_at_ms: now_ms
       }}
    else
      {:error, reason} ->
        SceneServer.CliObserve.emit("player_movement_error", %{cid: cid, reason: reason})
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
          combat_state: combat_state,
          character_data_ref: cd_ref,
          physys_ref: physys_ref,
          last_location: last_location
        } = state
      ) do
    now = :os.system_time(:millisecond)

    with :ok <- ensure_alive(combat_state),
         {:ok, skill} <- Skill.fetch(skill_id),
         :ok <- cooldown_ready?(skill_casts, skill, now),
         {:ok, location} <- get_character_location_with_retry(cd_ref, physys_ref, last_location) do
      SceneServer.CliObserve.emit("player_skill", %{
        cid: cid,
        skill_id: skill_id,
        location: location
      })

      GenServer.cast(aoi_ref, {:skill_cast, cid, skill_id, location})
      apply_skill_hits(cid, skill, location)

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
  def handle_call(
        {:apply_skill_hit, source_cid, %Skill{} = skill, impact_location},
        _from,
        %{
          cid: cid,
          aoi_ref: aoi_ref,
          combat_state: combat_state,
          respawn_timer: respawn_timer,
          movement_profile: movement_profile,
          movement_state: movement_state,
          character_data_ref: cd_ref,
          physys_ref: physys_ref,
          last_location: last_location
        } = state
      ) do
    with :ok <- ensure_alive(combat_state),
         true <- source_cid != cid,
         {:ok, location} <- get_character_location_with_retry(cd_ref, physys_ref, last_location),
         true <- within_skill_radius?(impact_location, location, skill.radius) do
      case CombatState.apply_damage(combat_state, skill.damage) do
        {:ignored, next_combat_state} ->
          {:reply, {:ok, next_combat_state.hp},
           %{state | combat_state: next_combat_state, last_location: location}}

        {result, next_combat_state, dealt_damage} ->
          GenServer.cast(
            aoi_ref,
            {:combat_resolved, source_cid, cid, skill.id, dealt_damage, next_combat_state.hp,
             location}
          )

          GenServer.cast(
            aoi_ref,
            {:health_update, cid, next_combat_state.hp, next_combat_state.max_hp,
             next_combat_state.alive}
          )

          {next_state, next_respawn_timer} =
            case result do
              :killed ->
                if respawn_timer != nil, do: Process.cancel_timer(respawn_timer)

                reset_movement_after_death(
                  cd_ref,
                  physys_ref,
                  movement_profile,
                  movement_state,
                  state
                )

              :damaged ->
                {state, respawn_timer}
            end

          {:reply, {:ok, next_combat_state.hp},
           %{
             next_state
             | combat_state: next_combat_state,
               respawn_timer: next_respawn_timer,
               last_location: location
           }}
      end
    else
      false -> {:reply, {:error, :out_of_range}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(
        :movement_tick,
        %{
          cid: cid,
          connection_pid: connection_pid,
          aoi_ref: aoi_ref,
          character_data_ref: cd_ref,
          physys_ref: physys_ref,
          combat_state: combat_state,
          movement_state: movement_state,
          movement_profile: movement_profile,
          latched_input: latched_input,
          last_ack_seq: last_ack_seq,
          last_input_received_at_ms: last_input_received_at_ms
        } = state
      ) do
    movement_timer = make_movement_timer(movement_profile.fixed_dt_ms)
    now_ms = System.monotonic_time(:millisecond)

    effective_input =
      effective_input_frame(
        latched_input,
        movement_state,
        movement_profile,
        now_ms - last_input_received_at_ms,
        combat_state
      )

    cond do
      should_advance_movement?(movement_state, effective_input) ->
        {next_state, _ack} =
          Engine.step(cid, movement_state, effective_input, movement_profile)

        with :ok <-
               update_character_movement_with_retry(
                 cd_ref,
                 next_state.position,
                 next_state.velocity,
                 next_state.acceleration,
                 physys_ref
               ),
             {:ok, authoritative_location} <-
               get_character_location_with_retry(cd_ref, physys_ref, next_state.position) do
          authoritative_state = %{next_state | position: authoritative_location}
          ack = Engine.build_ack(cid, authoritative_state, effective_input.seq)
          snapshot = RemoteSnapshot.from_state(cid, authoritative_state)
          GenServer.cast(aoi_ref, {:self_move, snapshot})
          GenServer.cast(connection_pid, {:movement_ack, ack})

          {:noreply,
           %{
             state
             | movement_state: authoritative_state,
               last_location: authoritative_location,
               last_ack_seq: effective_input.seq,
               movement_timer: movement_timer,
               latched_input: effective_input
           }}
        else
          {:error, reason} ->
            SceneServer.CliObserve.emit("player_movement_error", %{cid: cid, reason: reason})
            {:noreply, %{state | movement_timer: movement_timer}}
        end

      effective_input.seq > last_ack_seq ->
        ack = Engine.build_ack(cid, movement_state, effective_input.seq)
        GenServer.cast(connection_pid, {:movement_ack, ack})

        {:noreply,
         %{
           state
           | last_ack_seq: effective_input.seq,
             movement_timer: movement_timer,
             latched_input: effective_input
         }}

      true ->
        {:noreply, %{state | movement_timer: movement_timer}}
    end
  end

  @impl true
  def handle_info(:respawn, %{combat_state: combat_state} = state) do
    if combat_state.alive do
      {:noreply, %{state | respawn_timer: nil}}
    else
      handle_respawn(state)
    end
  end

  @impl true
  def terminate(reason, %{
        aoi_ref: aoi_item,
        cid: cid,
        movement_timer: movement_timer,
        respawn_timer: respawn_timer
      }) do
    SceneServer.CliObserve.emit("player_terminate", %{cid: cid, reason: reason})

    if movement_timer != nil do
      Process.cancel_timer(movement_timer)
    end

    if respawn_timer != nil do
      Process.cancel_timer(respawn_timer)
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

  defp enter_scene(cid, client_timestamp, location, connection_pid) do
    {:ok, aoi_ref} =
      AoiManager.add_aoi_item(cid, client_timestamp, location, connection_pid, self())

    Logger.debug("Character added to Coordinate System: #{inspect(aoi_ref, pretty: true)}")

    {:ok, aoi_ref}
  end

  defp make_movement_timer(fixed_dt_ms) do
    Process.send_after(self(), :movement_tick, fixed_dt_ms)
  end

  defp idle_input_frame(fixed_dt_ms) do
    %InputFrame{
      seq: 0,
      client_tick: 0,
      dt_ms: fixed_dt_ms,
      input_dir: {0.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0b10
    }
  end

  defp merge_latched_input(_previous, %InputFrame{} = frame, %Profile{} = profile) do
    %InputFrame{frame | dt_ms: profile.fixed_dt_ms}
  end

  defp effective_input_frame(
         %InputFrame{} = latched_input,
         %State{} = movement_state,
         %Profile{} = profile,
         input_age_ms,
         %CombatState{} = combat_state
       ) do
    timeout_ms = profile.fixed_dt_ms * @input_hold_timeout_multiplier
    next_tick = movement_state.tick + 1

    base_input =
      cond do
        not combat_state.alive ->
          %InputFrame{
            latched_input
            | input_dir: {0.0, 0.0},
              speed_scale: 1.0,
              movement_flags: 0b10
          }

        input_age_ms > timeout_ms ->
          %InputFrame{
            latched_input
            | input_dir: {0.0, 0.0},
              speed_scale: 1.0,
              movement_flags: 0b10
          }

        true ->
          latched_input
      end

    %InputFrame{base_input | client_tick: next_tick, dt_ms: profile.fixed_dt_ms}
  end

  defp should_advance_movement?(%State{} = movement_state, %InputFrame{} = frame) do
    movement_active?(movement_state) or input_active?(frame)
  end

  defp movement_active?(%State{velocity: velocity}) do
    vector_magnitude(velocity) > @stopped_speed_epsilon
  end

  defp input_active?(%InputFrame{input_dir: {x, y}}) do
    abs(x) > 1.0e-6 or abs(y) > 1.0e-6
  end

  defp vector_magnitude({x, y, z}) do
    :math.sqrt(x * x + y * y + z * z)
  end

  defp ensure_alive(%CombatState{alive: true}), do: :ok
  defp ensure_alive(%CombatState{}), do: {:error, :dead}

  defp cooldown_ready?(skill_casts, %Skill{id: skill_id, cooldown_ms: cooldown_ms}, now) do
    case Map.get(skill_casts, skill_id) do
      nil -> :ok
      last_cast when now - last_cast >= cooldown_ms -> :ok
      _last_cast -> {:error, :skill_cooldown}
    end
  end

  defp within_skill_radius?(source, target, radius) do
    vector_distance(source, target) <= radius
  end

  defp vector_distance({ax, ay, az}, {bx, by, bz}) do
    dx = ax - bx
    dy = ay - by
    dz = az - bz
    :math.sqrt(dx * dx + dy * dy + dz * dz)
  end

  defp apply_skill_hits(source_cid, %Skill{} = skill, location) do
    source_cid
    |> Targeting.nearby_player_pids(location, skill.radius)
    |> Enum.each(fn player_pid ->
      _ = safe_player_call(player_pid, {:apply_skill_hit, source_cid, skill, location})
    end)
  end

  defp safe_player_call(player_pid, message) do
    try do
      GenServer.call(player_pid, message)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp reset_movement_after_death(cd_ref, physys_ref, movement_profile, movement_state, state) do
    zero_state = %{
      movement_state
      | velocity: {0.0, 0.0, 0.0},
        acceleration: {0.0, 0.0, 0.0}
    }

    :ok =
      update_character_movement_with_retry(
        cd_ref,
        zero_state.position,
        zero_state.velocity,
        zero_state.acceleration,
        physys_ref
      )

    timer = Process.send_after(self(), :respawn, state.combat_profile.respawn_ms)

    {state
     |> Map.put(:movement_state, zero_state)
     |> Map.put(:latched_input, idle_input_frame(movement_profile.fixed_dt_ms)), timer}
  end

  defp handle_respawn(
         %{
           cid: cid,
           aoi_ref: aoi_ref,
           spawn_location: spawn_location,
           movement_profile: movement_profile,
           movement_state: movement_state,
           combat_state: combat_state,
           character_data_ref: cd_ref,
           physys_ref: physys_ref
         } = state
       ) do
    respawned_combat_state = CombatState.respawn(combat_state)

    respawned_movement_state = %{
      movement_state
      | position: spawn_location,
        velocity: {0.0, 0.0, 0.0},
        acceleration: {0.0, 0.0, 0.0}
    }

    :ok =
      update_character_movement_with_retry(
        cd_ref,
        spawn_location,
        respawned_movement_state.velocity,
        respawned_movement_state.acceleration,
        physys_ref
      )

    snapshot = RemoteSnapshot.from_state(cid, respawned_movement_state)
    GenServer.cast(aoi_ref, {:self_move, snapshot})

    GenServer.cast(
      aoi_ref,
      {:health_update, cid, respawned_combat_state.hp, respawned_combat_state.max_hp,
       respawned_combat_state.alive}
    )

    {:noreply,
     %{
       state
       | combat_state: respawned_combat_state,
         movement_state: respawned_movement_state,
         latched_input: idle_input_frame(movement_profile.fixed_dt_ms),
         last_location: spawn_location,
         skill_casts: %{},
         respawn_timer: nil
     }}
  end

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

  defp sanitize_input_frame(
         %InputFrame{} = frame,
         %Profile{} = profile,
         last_input_seq,
         last_client_tick,
         _last_input_received_at_ms
       ) do
    cond do
      frame.seq <= last_input_seq ->
        {:error, :stale_input_seq}

      frame.client_tick <= last_client_tick ->
        {:error, :stale_client_tick}

      true ->
        now_ms = System.monotonic_time(:millisecond)

        sanitized_frame = %InputFrame{
          frame
          | dt_ms: profile.fixed_dt_ms,
            speed_scale: clamp_speed_scale(frame.speed_scale, profile.max_speed_scale)
        }

        {:ok, sanitized_frame, now_ms}
    end
  end

  defp clamp_speed_scale(scale, _max_scale) when scale < 0.0, do: 0.0
  defp clamp_speed_scale(scale, max_scale) when scale > max_scale, do: max_scale
  defp clamp_speed_scale(scale, _max_scale), do: scale

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
end
