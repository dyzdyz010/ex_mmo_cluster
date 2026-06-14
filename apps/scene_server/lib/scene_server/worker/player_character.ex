defmodule SceneServer.PlayerCharacter do
  # PERS-5:runtime_authoritative(玩家移动权威态,固定 tick 积分;恢复声明见梯队1)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :runtime_authoritative

  @moduledoc """
  Authoritative runtime process for one active player character.

  `PlayerCharacter` is the player-side aggregate root. It owns:

  - authoritative movement state and fixed-tick input consumption
  - authoritative combat state and skill cooldowns
  - AOI registration/broadcast integration
  - respawn lifecycle

  Compared with `SceneServer.Npc.Actor`, this module also mediates network-origin
  input and time sync concerns because player actors are driven by a remote
  client.
  """

  use GenServer, restart: :temporary

  require Logger

  alias SceneServer.AoiManager
  alias SceneServer.Combat.CastRequest
  alias SceneServer.Combat.Executor, as: CombatExecutor
  alias SceneServer.Combat.Profile, as: CombatProfile
  alias SceneServer.Combat.Skill
  alias SceneServer.Combat.State, as: CombatState
  alias SceneServer.Combat.VoxelDamageRouter
  alias SceneServer.Movement.{Engine, InputFrame, Profile, RemoteSnapshot, State, VoxelCollision}

  @default_dev_attrs %{"mmr" => 20, "cph" => 20, "cct" => 20, "pct" => 20, "rsl" => 20}
  # Default spawn over the DevSeed 16×16 stone platform on chunk (0,0,0).
  #
  # Movement world coords use server Z as vertical. The browser maps this
  # spawn to x=750,y=185,z=750, above DevSeed's voxel y=0 platform centered at
  # x/z = 750 in renderer units.
  # Movement positions are avatar centers. DevSeed's y=0 platform tops out at
  # z=100 cm, so the 170 cm avatar starts at 100 + half-height.
  @default_location {750.0, 750.0, 185.0}
  @legacy_dev_seed_center_location {750.0, 750.0, 100.0}

  @lock_retry_attempts 5
  @lock_retry_sleep_ms 5
  # Hold the last direction for up to 2s of silence before assuming the client
  # really wants to stop. The client sends an explicit stop frame on key release
  # (see bevy_client movement_sender + should_send_stop_sync), so the only
  # reason to zero-direction here is a connection that quietly dropped.
  @input_hold_timeout_multiplier 20
  @stopped_speed_epsilon 1.0
  # Cap on how many client input frames we replay in one wall-clock tick. In
  # normal play the client sends at 10Hz matching our fixed_dt, so the queue is
  # expected to hold 0-2 frames. Burst handling and minor jitter are expected
  # to produce up to ~4 frames.
  @max_input_queue 8

  @doc """
  Starts one authoritative player character process.
  """
  def start_link(params, opts \\ []) do
    GenServer.start_link(__MODULE__, params, opts)
  end

  @doc false
  def connection_monitor_ref(connection_pid, node_fun \\ &:erlang.node/1)

  def connection_monitor_ref(connection_pid, node_fun) when is_pid(connection_pid) do
    if node_fun.(connection_pid) == node() do
      if Process.alive?(connection_pid), do: Process.monitor(connection_pid), else: nil
    else
      Process.monitor(connection_pid)
    end
  end

  def connection_monitor_ref(_connection_pid, _node_fun), do: nil

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

    # Phase A4-bis follow-up: monitor the gate connection_pid so we
    # tear down promptly when the player disconnects (browser refresh,
    # tab close, ws drop). Without this the PlayerCharacter outlives
    # the connection, keeps occupying its AoiManager entry, and shows
    # up to other players as a stationary "ghost" stuck at spawn —
    # which is exactly the "remote cube doesn't follow you, then
    # appears to follow because you walked back" optical illusion.
    connection_monitor_ref = connection_monitor_ref(connection_pid)
    character_profile = normalize_character_profile(cid, character_profile)

    {:ok,
     %{
       cid: cid,
       character_profile: character_profile,
       connection_pid: connection_pid,
       connection_monitor_ref: connection_monitor_ref,
       last_location: character_profile.position,
       physys_ref: nil,
       aoi_ref: nil,
       character_data_ref: nil,
       spawn_location: character_profile.position,
       movement_state: State.idle(character_profile.position),
       movement_profile: Profile.default(),
       combat_profile: CombatProfile.default(),
       combat_state: CombatState.new(CombatProfile.default()),
       latched_input: idle_input_frame(Profile.default().fixed_dt_ms),
       input_queue: [],
       last_input_seq: 0,
       last_ack_seq: 0,
       last_client_tick: 0,
       last_input_received_at_ms: System.monotonic_time(:millisecond),
       status: :in_scene,
       old_timestamp: nil,
       net_delay: 0,
       skill_casts: %{},
       movement_timer: nil,
       aoi_monitor_ref: nil,
       respawn_timer: nil,
       # Phase A1-5:scene_id 用于把 skill cast 的 target_position lookup
       # 进 ChunkSnapshotStore → ObjectRegistry.accumulate_damage(voxel
       # damage 路由)。Demo 阶段 default 1;follow-up:从 enter_scene
       # wire 或 character_profile 读真实 logical_scene_id。
       logical_scene_id: 1
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
         {:ok, aoi_ref} <-
           enter_scene(cid, client_timestamp, location, connection_pid, character_profile.name) do
      movement_timer = make_movement_timer(movement_profile.fixed_dt_ms)
      aoi_monitor_ref = Process.monitor(aoi_ref)
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
           aoi_monitor_ref: aoi_monitor_ref,
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
  def handle_call(:get_next_input_seq, _from, state) do
    # Audit B-S1 / B-SRV1: report the seq the server is going to expect for
    # the *next* movement input. Initial state has last_input_seq = 0, so a
    # fresh PlayerCharacter (every reconnect — PlayerManager rebuilds the
    # process) yields next = 1, matching the client's reset_to_seq(1) on
    # cold start. If sessions ever start being recycled, this handler is
    # the single point where the contract is upheld.
    {:reply, {:ok, state.last_input_seq + 1}, state}
  end

  @impl true
  def handle_call(:get_state_summary, _from, state) do
    summary = %{
      kind: :player,
      cid: state.cid,
      name: state.character_profile.name,
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
          input_queue: input_queue,
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
           input_queue: enqueue_input(input_queue, sanitized_frame),
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
        from,
        state
      )
      when is_integer(skill_id) do
    handle_call({:cast_skill, CastRequest.auto(skill_id)}, from, state)
  end

  @impl true
  def handle_call(
        {:cast_skill, %CastRequest{} = cast_request},
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
         {:ok, skill} <- Skill.fetch(cast_request.skill_id),
         :ok <- cooldown_ready?(skill_casts, skill, now),
         {:ok, location} <- get_character_location_with_retry(cd_ref, physys_ref, last_location),
         {:ok, execution} <-
           CombatExecutor.prepare_cast(%{cid: cid, position: location}, cast_request, skill) do
      SceneServer.CliObserve.emit("player_skill", %{
        cid: cid,
        skill_id: cast_request.skill_id,
        location: location
      })

      GenServer.cast(aoi_ref, {:skill_cast, cid, cast_request.skill_id, location})
      broadcast_effect_events(aoi_ref, execution.initial_cues)
      schedule_skill_resolution(execution.delayed_cast)

      {:reply, {:ok, location},
       %{
         state
         | skill_casts: Map.put(skill_casts, cast_request.skill_id, now),
           last_location: location
       }}
    else
      {:error, reason} ->
        SceneServer.CliObserve.emit("player_skill_error", %{
          cid: cid,
          skill_id: Map.get(cast_request, :skill_id),
          reason: reason
        })

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(
        {:apply_damage_effect, source_cid, skill_id, damage, _impact_location},
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
         {:ok, location} <- get_character_location_with_retry(cd_ref, physys_ref, last_location) do
      case CombatState.apply_damage(combat_state, damage) do
        {:ignored, next_combat_state} ->
          {:reply, {:ok, next_combat_state.hp},
           %{state | combat_state: next_combat_state, last_location: location}}

        {result, next_combat_state, dealt_damage} ->
          GenServer.cast(
            aoi_ref,
            {:combat_resolved, source_cid, cid, skill_id, dealt_damage, next_combat_state.hp,
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
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(
        {:resolve_skill_cast, cast},
        %{aoi_ref: aoi_ref, logical_scene_id: scene_id} = state
      ) do
    resolution = CombatExecutor.resolve_cast(cast)
    broadcast_effect_events(aoi_ref, resolution.cues)
    # Phase A1-5:并行尝试 voxel damage(actor damage 已经 fan-out 走
    # CombatExecutor.resolve_cast)。target_position 单位是 world cm;
    # 1 macro = 100 cm = 8 micro,所以 cm × 8 / 100 = micro_unit_index。
    try_voxel_damage(scene_id, cast)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, conn_pid, reason},
        %{connection_monitor_ref: monitor_ref, connection_pid: conn_pid} = state
      ) do
    SceneServer.CliObserve.emit("player_connection_down", %{
      cid: state.cid,
      connection_pid: conn_pid,
      reason: inspect(reason)
    })

    # Stop normally so terminate/2 runs the AOI / PlayerManager cleanup
    # path. Returning :normal keeps DynamicSupervisor from logging this
    # as a crash — disconnect is the expected end-of-session signal.
    {:stop, :normal, %{state | connection_monitor_ref: nil}}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, aoi_ref, reason},
        %{aoi_monitor_ref: monitor_ref, aoi_ref: aoi_ref} = state
      ) do
    case recover_aoi_adapter(state, reason) do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:error, recover_reason} ->
        SceneServer.CliObserve.emit("player_aoi_recover_error", %{
          cid: state.cid,
          down_reason: reason,
          recover_reason: recover_reason
        })

        Process.send_after(self(), :recover_aoi, 250)
        {:noreply, %{state | aoi_monitor_ref: nil}}
    end
  end

  @impl true
  def handle_info({:DOWN, _monitor_ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_info(:recover_aoi, state) do
    case ensure_aoi_runtime(state) do
      {:ok, next_state} -> {:noreply, next_state}
      {:error, _reason} -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        :movement_tick,
        %{
          cid: cid,
          connection_pid: connection_pid,
          aoi_ref: _aoi_ref,
          character_data_ref: cd_ref,
          physys_ref: physys_ref,
          combat_state: combat_state,
          movement_state: movement_state,
          movement_profile: movement_profile,
          latched_input: latched_input,
          input_queue: input_queue,
          last_ack_seq: last_ack_seq,
          last_input_received_at_ms: last_input_received_at_ms
        } = state
      ) do
    state =
      case ensure_aoi_runtime(state) do
        {:ok, next_state} -> next_state
        {:error, _reason} -> state
      end

    aoi_ref = state.aoi_ref
    movement_timer = make_movement_timer(movement_profile.fixed_dt_ms)
    now_ms = System.monotonic_time(:millisecond)

    case input_queue do
      [_ | _] = queued ->
        replay_queued_inputs(
          queued,
          %{state | movement_timer: movement_timer, input_queue: []},
          cid,
          connection_pid,
          aoi_ref,
          cd_ref,
          physys_ref,
          movement_state,
          movement_profile,
          now_ms - last_input_received_at_ms
        )

      [] ->
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
            step_and_broadcast(
              effective_input,
              %{state | movement_timer: movement_timer},
              cid,
              connection_pid,
              aoi_ref,
              cd_ref,
              physys_ref,
              movement_state,
              movement_profile,
              now_ms - last_input_received_at_ms
            )

          effective_input.seq > last_ack_seq ->
            ack =
              Engine.build_ack(
                cid,
                movement_state,
                effective_input.seq,
                movement_profile.fixed_dt_ms
              )

            SceneServer.CliObserve.emit("player_movement_idle_ack", %{
              cid: cid,
              input_seq: effective_input.seq,
              input_tick: effective_input.client_tick,
              input_dir: effective_input.input_dir,
              input_age_ms: now_ms - last_input_received_at_ms,
              authoritative_tick: movement_state.tick,
              authoritative_position: movement_state.position,
              authoritative_velocity: movement_state.velocity
            })

            GenServer.cast(connection_pid, {:movement_ack, ack})

            {:noreply,
             %{
               state
               | last_ack_seq: effective_input.seq,
                 movement_timer: movement_timer,
                 latched_input: effective_input
             }}

          true ->
            flush_stop_snapshot_if_needed(
              aoi_ref,
              cd_ref,
              physys_ref,
              cid,
              movement_state,
              %{state | movement_timer: movement_timer}
            )
        end
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

  defp step_and_broadcast(
         %InputFrame{} = effective_input,
         state,
         cid,
         connection_pid,
         aoi_ref,
         cd_ref,
         physys_ref,
         movement_state,
         movement_profile,
         input_age_ms
       ) do
    {next_state, _ack} = Engine.step(cid, movement_state, effective_input, movement_profile)

    {next_state, correction_flags, collision_summary} =
      resolve_voxel_collision(movement_state, next_state, state)

    finalize_and_broadcast(
      next_state,
      effective_input.seq,
      state,
      cid,
      connection_pid,
      aoi_ref,
      cd_ref,
      physys_ref,
      effective_input,
      input_age_ms,
      :single,
      movement_profile,
      correction_flags,
      collision_summary
    )
  end

  defp replay_queued_inputs(
         queued,
         state,
         cid,
         connection_pid,
         aoi_ref,
         cd_ref,
         physys_ref,
         movement_state,
         movement_profile,
         input_age_ms
       ) do
    renumbered = renumber_input_frames(queued, movement_state.tick, movement_profile.fixed_dt_ms)

    {next_state, correction_flags, collision_summaries} =
      replay_queued_inputs_with_collision(
        movement_state,
        renumbered,
        movement_profile,
        state,
        cid
      )

    last_frame = List.last(renumbered)

    finalize_and_broadcast(
      next_state,
      last_frame.seq,
      state,
      cid,
      connection_pid,
      aoi_ref,
      cd_ref,
      physys_ref,
      last_frame,
      input_age_ms,
      {:replayed, length(renumbered)},
      movement_profile,
      correction_flags,
      summarize_replay_collision(collision_summaries)
    )
  end

  defp finalize_and_broadcast(
         next_state,
         ack_seq,
         state,
         cid,
         connection_pid,
         aoi_ref,
         cd_ref,
         physys_ref,
         last_frame,
         input_age_ms,
         mode,
         movement_profile,
         correction_flags,
         collision_summary
       ) do
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
      authoritative_state = %{next_state | position: authoritative_location} |> refresh_ground_z()

      ack =
        Engine.build_ack_with_intent(
          cid,
          authoritative_state,
          last_frame,
          correction_flags,
          movement_profile.fixed_dt_ms
        )

      snapshot = RemoteSnapshot.from_state(cid, authoritative_state)

      SceneServer.CliObserve.emit("player_movement_tick", %{
        cid: cid,
        mode: mode,
        input_seq: ack_seq,
        input_tick: last_frame.client_tick,
        input_dir: last_frame.input_dir,
        input_age_ms: input_age_ms,
        authoritative_tick: authoritative_state.tick,
        authoritative_position: authoritative_state.position,
        authoritative_velocity: authoritative_state.velocity,
        authoritative_acceleration: authoritative_state.acceleration,
        movement_mode: authoritative_state.movement_mode,
        correction_flags: ack.correction_flags,
        collision_status: Map.get(collision_summary, :status),
        collision_blocked_axes: Map.get(collision_summary, :blocked_axes, []),
        collision_occupied_count: Map.get(collision_summary, :occupied_count, 0)
      })

      emit_collision_observe(cid, state.logical_scene_id, authoritative_state, collision_summary)

      GenServer.cast(aoi_ref, {:self_move, snapshot})
      GenServer.cast(connection_pid, {:movement_ack, ack})

      {:noreply,
       %{
         state
         | movement_state: authoritative_state,
           last_location: authoritative_location,
           last_ack_seq: ack_seq,
           latched_input: clear_one_shot_flags(last_frame)
       }}
    else
      {:error, reason} ->
        SceneServer.CliObserve.emit("player_movement_error", %{
          cid: cid,
          mode: mode,
          reason: reason
        })

        {:noreply, state}
    end
  end

  defp replay_queued_inputs_with_collision(
         anchor_state,
         frames,
         movement_profile,
         player_state,
         cid
       ) do
    Enum.reduce(frames, {anchor_state, 0, []}, fn %InputFrame{} = frame,
                                                  {current_state, flags_acc, summaries} ->
      {proposed_state, _ack} = Engine.step(cid, current_state, frame, movement_profile)

      {resolved_state, flags, summary} =
        resolve_voxel_collision(current_state, proposed_state, player_state)

      {resolved_state, Bitwise.bor(flags_acc, flags), [summary | summaries]}
    end)
    |> case do
      {state, flags, summaries} -> {state, flags, Enum.reverse(summaries)}
    end
  end

  defp resolve_voxel_collision(%State{} = previous_state, %State{} = proposed_state, state) do
    VoxelCollision.resolve(previous_state, proposed_state,
      logical_scene_id: Map.get(state, :logical_scene_id, 1)
    )
  end

  defp summarize_replay_collision([]) do
    %{
      status: :skipped,
      blocked_axes: [],
      occupied_count: 0,
      sample_count: 0,
      correction_flags: 0,
      replay_count: 0
    }
  end

  defp summarize_replay_collision(summaries) do
    last_summary = List.last(summaries)

    blocked_axes =
      summaries
      |> Enum.flat_map(&Map.get(&1, :blocked_axes, []))
      |> Enum.uniq()

    status =
      cond do
        Enum.any?(summaries, &(Map.get(&1, :status) == :resolved)) -> :resolved
        Enum.any?(summaries, &(Map.get(&1, :status) == :unavailable)) -> :unavailable
        true -> Map.get(last_summary, :status, :clear)
      end

    last_summary
    |> Map.put(:status, status)
    |> Map.put(:blocked_axes, blocked_axes)
    |> Map.put(:occupied_count, Enum.sum(Enum.map(summaries, &Map.get(&1, :occupied_count, 0))))
    |> Map.put(:sample_count, Enum.sum(Enum.map(summaries, &Map.get(&1, :sample_count, 0))))
    |> Map.put(
      :correction_flags,
      Enum.reduce(summaries, 0, fn summary, acc ->
        Bitwise.bor(acc, Map.get(summary, :correction_flags, 0))
      end)
    )
    |> Map.put(:replay_count, length(summaries))
  end

  defp emit_collision_observe(_cid, _logical_scene_id, _state, %{status: :clear}), do: :ok
  defp emit_collision_observe(_cid, _logical_scene_id, _state, %{status: :skipped}), do: :ok

  defp emit_collision_observe(cid, logical_scene_id, authoritative_state, summary) do
    SceneServer.CliObserve.emit("player_movement_collision", %{
      cid: cid,
      logical_scene_id: logical_scene_id,
      authoritative_tick: authoritative_state.tick,
      authoritative_position: authoritative_state.position,
      status: Map.get(summary, :status),
      reason: Map.get(summary, :reason),
      previous_position: Map.get(summary, :previous_position),
      proposed_position: Map.get(summary, :proposed_position),
      resolved_position: Map.get(summary, :resolved_position),
      blocked_axes: Map.get(summary, :blocked_axes, []),
      queried_chunks: Map.get(summary, :queried_chunks, []),
      sample_count: Map.get(summary, :sample_count, 0),
      occupied_count: Map.get(summary, :occupied_count, 0),
      correction_flags: Map.get(summary, :correction_flags, 0),
      replay_count: Map.get(summary, :replay_count, 1)
    })
  end

  defp renumber_input_frames(frames, base_tick, fixed_dt_ms) do
    frames
    |> Enum.with_index(1)
    |> Enum.map(fn {%InputFrame{} = frame, idx} ->
      %InputFrame{frame | client_tick: base_tick + idx, dt_ms: fixed_dt_ms}
    end)
  end

  defp clear_one_shot_flags(%InputFrame{} = frame) do
    %InputFrame{
      frame
      | movement_flags: Bitwise.band(frame.movement_flags, Bitwise.bnot(InputFrame.jump_flag()))
    }
  end

  defp ensure_aoi_runtime(%{aoi_ref: aoi_ref} = state) when is_pid(aoi_ref) do
    if Process.alive?(aoi_ref) do
      {:ok, state}
    else
      recover_aoi_adapter(state, :dead_aoi_ref)
    end
  end

  defp ensure_aoi_runtime(state), do: recover_aoi_adapter(state, :missing_aoi_ref)

  defp recover_aoi_adapter(state, reason) do
    if is_reference(Map.get(state, :aoi_monitor_ref)) do
      Process.demonitor(state.aoi_monitor_ref, [:flush])
    end

    location = Map.get(state, :last_location) || state.movement_state.position

    SceneServer.CliObserve.emit("player_aoi_recover", %{
      cid: state.cid,
      reason: reason,
      location: location
    })

    case enter_scene(
           state.cid,
           :os.system_time(:millisecond),
           location,
           state.connection_pid,
           character_name(state)
         ) do
      {:ok, aoi_ref} ->
        monitor_ref = Process.monitor(aoi_ref)
        send(aoi_ref, :get_aoi_tick)
        broadcast_current_aoi_state(aoi_ref, state)
        {:ok, %{state | aoi_ref: aoi_ref, aoi_monitor_ref: monitor_ref}}

      {:error, recover_reason} ->
        {:error, recover_reason}
    end
  end

  defp broadcast_current_aoi_state(aoi_ref, state) do
    GenServer.cast(
      aoi_ref,
      {:player_state, state.cid, state.combat_state.hp, state.combat_state.max_hp,
       state.combat_state.alive}
    )

    GenServer.cast(
      aoi_ref,
      {:self_move, RemoteSnapshot.from_state(state.cid, state.movement_state)}
    )
  end

  defp character_name(%{character_profile: %{name: name}}) when is_binary(name), do: name
  defp character_name(%{character_profile: %{"name" => name}}) when is_binary(name), do: name
  defp character_name(%{cid: cid}), do: "player-#{cid}"

  defp enqueue_input(queue, %InputFrame{} = frame) do
    case queue ++ [frame] do
      list when length(list) > @max_input_queue ->
        Enum.take(list, -@max_input_queue)

      list ->
        list
    end
  end

  @impl true
  def terminate(reason, state) do
    %{
      aoi_ref: aoi_item,
      cid: cid,
      movement_timer: movement_timer,
      aoi_monitor_ref: aoi_monitor_ref,
      respawn_timer: respawn_timer
    } = state

    connection_monitor_ref = Map.get(state, :connection_monitor_ref)

    SceneServer.CliObserve.emit("player_terminate", %{cid: cid, reason: reason})

    if movement_timer != nil do
      Process.cancel_timer(movement_timer)
    end

    if respawn_timer != nil do
      Process.cancel_timer(respawn_timer)
    end

    if is_reference(connection_monitor_ref) do
      Process.demonitor(connection_monitor_ref, [:flush])
    end

    if is_reference(aoi_monitor_ref) do
      Process.demonitor(aoi_monitor_ref, [:flush])
    end

    if is_pid(aoi_item) and Process.alive?(aoi_item) do
      {:ok, _} = GenServer.call(aoi_item, :exit)
      Logger.debug("AOI item removed.")
    end

    if Process.whereis(SceneServer.PlayerManager) do
      GenServer.cast(SceneServer.PlayerManager, {:remove_player_index, cid, self()})
      Logger.debug("Player index removed.")
    end

    Logger.warning(
      "PlayerCharacter process #{inspect(self(), pretty: true)} exited successfully. Reason: #{inspect(reason, pretty: true)}",
      ansi_color: :green
    )
  end

  defp enter_scene(cid, client_timestamp, location, connection_pid, character_name) do
    case AoiManager.add_aoi_item(
           cid,
           client_timestamp,
           location,
           connection_pid,
           self(),
           %{kind: :player, name: character_name}
         ) do
      {:ok, aoi_ref} ->
        Logger.debug("Character added to Coordinate System: #{inspect(aoi_ref, pretty: true)}")
        {:ok, aoi_ref}

      {:err, reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
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

  defp flush_stop_snapshot_if_needed(
         aoi_ref,
         cd_ref,
         physys_ref,
         cid,
         %State{velocity: {vx, vy, vz}, acceleration: {ax, ay, az}} = movement_state,
         state
       )
       when vx != 0.0 or vy != 0.0 or vz != 0.0 or ax != 0.0 or ay != 0.0 or az != 0.0 do
    zeroed_state = %State{
      movement_state
      | velocity: {0.0, 0.0, 0.0},
        acceleration: {0.0, 0.0, 0.0},
        ground_z: elem(movement_state.position, 2)
    }

    _ =
      update_character_movement_with_retry(
        cd_ref,
        zeroed_state.position,
        zeroed_state.velocity,
        zeroed_state.acceleration,
        physys_ref
      )

    snapshot = RemoteSnapshot.from_state(cid, zeroed_state)
    GenServer.cast(aoi_ref, {:self_move, snapshot})

    {:noreply, %{state | movement_state: zeroed_state, last_location: zeroed_state.position}}
  end

  defp flush_stop_snapshot_if_needed(_aoi_ref, _cd_ref, _physys_ref, _cid, _movement_state, state) do
    {:noreply, state}
  end

  defp movement_active?(%State{velocity: velocity}) do
    vector_magnitude(velocity) > @stopped_speed_epsilon
  end

  defp input_active?(%InputFrame{input_dir: {x, y}} = frame) do
    abs(x) > 1.0e-6 or abs(y) > 1.0e-6 or InputFrame.jumping?(frame)
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

  defp schedule_skill_resolution(%{travel_ms: 0} = cast) do
    send(self(), {:resolve_skill_cast, cast})
  end

  defp schedule_skill_resolution(%{travel_ms: travel_ms} = cast) when travel_ms > 0 do
    Process.send_after(self(), {:resolve_skill_cast, cast}, travel_ms)
  end

  # Phase A1-5:把 cast.target_position(cm)转 world micro index 并调
  # VoxelDamageRouter。:cascade / :applied / :no_voxel / :error 全部 emit
  # observe(让 CLI 调试可见命中链路),但**不**短路 actor damage 路径
  # (那条已经在 resolve_cast → broadcast_effect_events 走完)。
  defp try_voxel_damage(scene_id, %{target_position: target_position, skill: skill}) do
    damage = primary_damage_from_skill(skill)

    cond do
      damage <= 0 ->
        :ok

      not is_tuple(target_position) ->
        :ok

      true ->
        world_micro = world_cm_to_micro(target_position)

        outcome = VoxelDamageRouter.try_apply_damage(scene_id, world_micro, damage)

        SceneServer.CliObserve.emit("voxel_skill_damage_attempt", fn ->
          %{
            logical_scene_id: scene_id,
            skill_id: skill.id,
            target_position: inspect(target_position),
            world_micro: inspect(world_micro),
            damage: damage,
            outcome: inspect(outcome, limit: 4)
          }
        end)

        :ok
    end
  end

  defp world_cm_to_micro({wx, wy, wz}) do
    {floor_to_int(wx * 8.0 / 100.0), floor_to_int(wy * 8.0 / 100.0),
     floor_to_int(wz * 8.0 / 100.0)}
  end

  defp floor_to_int(value) when is_float(value), do: :erlang.floor(value)
  defp floor_to_int(value) when is_integer(value), do: value

  # Picks the first effect's damage as the canonical "skill damage" for voxel
  # path。Multi-effect skills(circle / chain)在 actor 路径仍按 effects 列表
  # 走;voxel 路径只取首个 effect 的 damage 让 demo 形为可控。
  defp primary_damage_from_skill(%Skill{effects: [%{damage: damage} | _]}) when damage > 0,
    do: damage

  defp primary_damage_from_skill(_skill), do: 0

  defp broadcast_effect_events(aoi_ref, effect_events) when is_list(effect_events) do
    Enum.each(effect_events, fn effect_event ->
      GenServer.cast(aoi_ref, {:effect_event, effect_event})
    end)
  end

  defp reset_movement_after_death(cd_ref, physys_ref, movement_profile, movement_state, state) do
    zero_state = %{
      movement_state
      | velocity: {0.0, 0.0, 0.0},
        acceleration: {0.0, 0.0, 0.0},
        movement_mode: :grounded,
        ground_z: elem(movement_state.position, 2)
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
        acceleration: {0.0, 0.0, 0.0},
        movement_mode: :grounded,
        ground_z: elem(spawn_location, 2)
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

  defp refresh_ground_z(%State{movement_mode: :grounded, position: position} = movement_state) do
    %{movement_state | ground_z: elem(position, 2)}
  end

  defp refresh_ground_z(%State{} = movement_state), do: movement_state

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
    |> maybe_migrate_legacy_dev_seed_location()
  end

  defp normalize_position(%{} = position) do
    x = map_float(position, ["x", :x], elem(@default_location, 0))
    y = map_float(position, ["y", :y], elem(@default_location, 1))
    z = map_float(position, ["z", :z], elem(@default_location, 2))

    {x, y, z}
    |> maybe_migrate_legacy_dev_seed_location()
  end

  defp normalize_position(_position), do: @default_location

  defp maybe_migrate_legacy_dev_seed_location(@legacy_dev_seed_center_location) do
    SceneServer.CliObserve.emit("player_spawn_position_migrated", %{
      from: inspect(@legacy_dev_seed_center_location),
      to: inspect(@default_location),
      reason: :center_anchor_height
    })

    @default_location
  end

  defp maybe_migrate_legacy_dev_seed_location(position), do: position

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
    case new_character_data_once(cid, name, location, dev_attrs, physys_ref) do
      {:ok, cd_ref} ->
        {:ok, cd_ref}

      {:error, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)
        new_character_data_with_retry(cid, name, location, dev_attrs, physys_ref, attempts - 1)

      {:err, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)
        new_character_data_with_retry(cid, name, location, dev_attrs, physys_ref, attempts - 1)

      {:error, :native_badarg} ->
        SceneServer.CliObserve.emit("player_native_physics_reset", %{cid: cid, reason: :badarg})

        with {:ok, refreshed_physys_ref} <- reset_physics_system_ref() do
          new_character_data_with_retry(
            cid,
            name,
            location,
            dev_attrs,
            refreshed_physys_ref,
            attempts - 1
          )
        end

      {:error, reason} ->
        {:error, reason}

      {:err, reason} ->
        {:error, reason}
    end
  end

  defp new_character_data_once(cid, name, location, dev_attrs, physys_ref) do
    try do
      SceneServer.Native.SceneOps.new_character_data(
        cid,
        name,
        location,
        dev_attrs,
        physys_ref
      )
    catch
      :error, :badarg -> {:error, :native_badarg}
    end
  end

  defp reset_physics_system_ref do
    if Process.whereis(SceneServer.PhysicsManager) do
      SceneServer.PhysicsManager.reset_physics_system_ref()
    else
      SceneServer.Native.SceneOps.new_physics_system()
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
